import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/report_analysis.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/credit_account_detail_page.dart';
import 'package:verifin/pages/credit_account_editor_page.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'package:verifin/pages/sheets.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 构造测试账户；[type] 决定银行或证券能力，[currency] 与 [balance] 始终是原币。
Account _account(
  String id,
  AccountType type, {
  String currency = 'HKD',
  String bookId = defaultLedgerBookId,
  String? parentId,
  double balance = 0,
}) => Account(
  id: id,
  bookId: bookId,
  name: id,
  type: type,
  groupId: null,
  initialBalance: balance,
  iconCode: 'bank',
  note: '保留备注',
  includeInAssets: true,
  hidden: false,
  currencyCode: currency,
  creditAccountId: parentId,
);

/// 模拟聚合写入失败，用于断言主账户和子账户不会只保存一半。
class _FailingParentRepository extends InMemoryLedgerRepository {
  bool fail = false;

  /// [accounts] 和 [creditAccounts] 是同一批次；失败发生在内存仓储写入之前。
  @override
  Future<void> saveCreditAccountAggregate({
    required List<Account> accounts,
    required List<CreditAccount> creditAccounts,
  }) async {
    if (fail) throw StateError('模拟主账户保存失败');
    await super.saveCreditAccountAggregate(
      accounts: accounts,
      creditAccounts: creditAccounts,
    );
  }
}

/// 验证银行、证券的真实父子关系及其与信用业务的边界。
void main() {
  useTestDatabases();

  for (final type in [AccountType.debitCard, AccountType.investment]) {
    test('${type.name} 创建 HKD 主账户及 HKD/USD/CNY 子账户且不产生信用数据', () async {
      final c = await makeController();
      addTearDown(c.dispose);
      final originalEntries = c.entries.map((e) => e.toJson()).toList();
      expect(await c.addAccountDraft(_account('机构', type)), isTrue);
      final parent = c.accountParents.single;
      expect(parent.currencyCode, 'HKD');
      expect(c.parentForAccount(c.accounts.single)?.id, parent.id);
      for (final currency in ['USD', 'CNY']) {
        final child = await c.ensureCurrencyChild(parent.id, currency);
        expect(child?.currencyCode, currency);
        expect(child?.initialBalance, 0);
        expect(child?.type, type);
      }
      final existing = await c.ensureCurrencyChild(parent.id, 'USD');
      expect(existing?.currencyCode, 'USD');
      expect(c.accountsForParent(parent.id), hasLength(3));
      expect(c.creditAccounts, isEmpty);
      expect(c.creditReminderSnapshots(), isEmpty);
      expect(c.billingStatements, isEmpty);
      expect(c.statementRepaymentAllocations, isEmpty);
      expect(c.entries.map((e) => e.toJson()).toList(), originalEntries);
      expect(c.accountParentsForType(type), [parent]);
      expect(c.accountParentsForType(AccountType.creditCard), isEmpty);
    });
  }

  test('主账户拒绝重复币种、混合账户类型和跨账本挂接', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    expect(
      await c.addAccountDraft(_account('银行', AccountType.debitCard)),
      isTrue,
    );
    final parentId = c.accountParents.single.id;
    expect(
      await c.addAccountDraft(
        _account('重复', AccountType.debitCard, parentId: parentId),
      ),
      isFalse,
    );
    expect(
      await c.addAccountDraft(
        _account(
          '证券',
          AccountType.investment,
          currency: 'USD',
          parentId: parentId,
        ),
      ),
      isFalse,
    );
    expect(
      await c.addAccountDraft(
        _account(
          '信用',
          AccountType.creditCard,
          currency: 'USD',
          parentId: parentId,
        ),
      ),
      isFalse,
    );
    c.addLedgerBook('其他账本', baseCurrencyCode: 'HKD');
    expect(await c.ensureCurrencyChild(parentId, 'USD'), isNull);
    expect(
      await c.addAccountDraft(
        _account(
          '跨账本',
          AccountType.debitCard,
          currency: 'USD',
          bookId: c.activeBook.id,
          parentId: parentId,
        ),
      ),
      isFalse,
    );
  });

  test('旧独立银行账户不自动迁移，显式启用只新增关系，保留原金额和设置', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    final old = _account('旧银行', AccountType.debitCard, balance: 123.45);
    c.addAccount(old);
    await c.waitForPendingWrites();
    expect(c.accountParents, isEmpty);
    expect(c.accounts.single.toJson(), old.toJson());
    final parent = await c.enableCurrencyChildren(old);
    expect(parent?.currencyCode, 'HKD');
    expect(
      c.accounts.single.toJson(),
      old.copyWith(creditAccountId: parent!.id).toJson(),
    );
    expect(await c.enableCurrencyChildren(old), parent);
    expect(c.accountParents, hasLength(1));
    expect(c.entries, isEmpty);
  });

  test('普通主账户按主币种估值，缺率不显示部分总额，修改主币种不修改余额', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    c.addLedgerBook('港澳账本', baseCurrencyCode: 'HKD');
    expect(
      await c.addAccountDraft(
        _account(
          '银行',
          AccountType.debitCard,
          bookId: c.activeBook.id,
          balance: 100,
        ),
      ),
      isTrue,
    );
    final parent = c.accountParents.single;
    final usd = (await c.ensureCurrencyChild(parent.id, 'USD'))!;
    expect(await c.saveAccountDraft(usd.copyWith(initialBalance: 10)), isTrue);
    expect(c.parentAccountBalances(parent).completeTotal, isNull);
    expect(
      await c.saveExchangeRateDraft(
        currencyCode: 'USD',
        effectiveDate: DateTime(2026, 1, 1),
        rateToBase: 8,
      ),
      isTrue,
    );
    expect(c.parentAccountBalances(parent).completeTotal, 180);
    final before = c.accounts.map((a) => a.toJson()).toList();
    expect(
      await c.saveAccountParentDraft(parent.copyWith(currencyCode: 'USD')),
      isTrue,
    );
    expect(
      c.parentAccountBalances(c.accountParents.single).completeTotal,
      22.5,
    );
    expect(c.accounts.map((a) => a.toJson()).toList(), before);
    expect(
      await c.saveAccountParentDraft(
        c.accountParents.single.copyWith(creditLimit: 100),
      ),
      isFalse,
    );
  });

  test('主账户聚合保存失败不改变账户或主体，成功后可重试', () async {
    final repo = _FailingParentRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    final before = c.accounts.map((a) => a.toJson()).toList();
    repo.fail = true;
    expect(
      await c.addAccountDraft(_account('失败银行', AccountType.debitCard)),
      isFalse,
    );
    expect(c.accounts.map((a) => a.toJson()).toList(), before);
    expect(c.accountParents, isEmpty);
    expect(await repo.loadCreditAccounts(), isEmpty);
    repo.fail = false;
    expect(
      await c.addAccountDraft(_account('失败银行', AccountType.debitCard)),
      isTrue,
    );
    expect(c.accountParents, hasLength(1));
  });

  test('银行多币种子账户在账户排行中合并为一个主账户', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    await c.addAccountDraft(_account('汇丰银行', AccountType.debitCard));
    final parent = c.accountParents.single;
    final usd = (await c.ensureCurrencyChild(parent.id, 'USD'))!;
    // 排行接收已经折算到同一统计单位的投影记录，这里验证主体归并和覆盖范围。
    final entries = [
      for (final id in ['汇丰银行', usd.id])
        LedgerEntry(
          id: '流水-$id',
          bookId: defaultLedgerBookId,
          type: EntryType.expense,
          amount: 10,
          categoryId: 'dining',
          accountId: id,
          note: '',
          occurredAt: DateTime(2026, 10, 22),
        ),
    ];
    final stats = reportAccountStats(
      entries,
      c.accounts,
      c.accountParents,
      EntryType.expense,
      noAccountLabel: '无账户',
      deletedAccountLabel: '已删除账户',
    );
    expect(stats.single.label, '汇丰银行');
    expect(stats.single.accountIds.toSet(), {'汇丰银行', usd.id});
    expect(stats.single.amount, 20);
  });

  test('只有普通主账户展示币种不同于账本时也必须保留金额单位', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    await c.addAccountDraft(
      _account('人民币银行', AccountType.debitCard, currency: 'CNY'),
    );
    expect(c.activeBookUsesMultipleCurrencies, isFalse);
    expect(
      await c.saveAccountParentDraft(
        c.accountParents.single.copyWith(currencyCode: 'USD'),
      ),
      isTrue,
    );
    expect(c.activeBookUsesMultipleCurrencies, isTrue);
    expect(c.accounts.single.currencyCode, 'CNY');
  });

  test('信用投影只包含信用主体，普通主体非法备份在预览阶段拒绝且不改状态', () async {
    final c = await makeController();
    addTearDown(c.dispose);
    await c.addAccountDraft(_account('银行', AccountType.debitCard));
    await c.addAccountDraft(_account('信用卡', AccountType.creditCard));
    expect(c.accountParents, hasLength(2));
    expect(c.creditAccounts.single.name, '信用卡');
    final before = (jsonDecode(c.exportDataJson()) as Map)['data'];
    final root = jsonDecode(c.exportDataJson()) as Map<String, dynamic>;
    final data = root['data'] as Map<String, dynamic>;
    final bank = (data['accounts'] as List).first as Map<String, dynamic>;
    (data['accounts'] as List).add({...bank, 'id': '重复币种'});
    expect(
      () => c.importDataJson(jsonEncode(root), dryRun: true),
      throwsFormatException,
    );
    expect((jsonDecode(c.exportDataJson()) as Map)['data'], before);
  });

  testWidgets('银行主账户记账按交易币种匹配美元子账户并按原币扣款', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 1100);
    addTearDown(tester.view.reset);
    final c = await makeController();
    addTearDown(c.dispose);
    await c.addAccountDraft(_account('银行', AccountType.debitCard));
    final parent = c.accountParents.single;
    final usd = (await c.ensureCurrencyChild(parent.id, 'USD'))!;
    await c.saveExchangeRateDraft(
      currencyCode: 'USD',
      effectiveDate: DateTime(2026, 1, 1),
      rateToBase: 7,
    );
    await c.saveExchangeRateDraft(
      currencyCode: 'HKD',
      effectiveDate: DateTime(2026, 1, 1),
      rateToBase: 0.9,
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: EntryDetailPage(
            initialAmount: 10,
            initialAccountId: '银行',
            initialCreditAccountId: parent.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('entry_currency_button')));
    await tester.tap(find.byKey(const Key('entry_currency_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('currency_option_USD')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save_entry_button')));
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    expect(c.entries.single.accountId, usd.id);
    expect(c.entries.single.currencyCode, 'USD');
    expect(c.entries.single.accountAmount, 10);
    expect(c.accountBalance(usd), -10);
    expect(c.accountBalance(c.accounts.first), 0);
    expect(c.billingStatements, isEmpty);
  });

  test('SQLite 冷启动、JSON v11 往返和删除保留普通主账户关系，无结构迁移', () async {
    sqfliteFfiInit();
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final repo = SqliteLedgerRepository(db);
    final store = LocalKeyValueStore();
    var c = await VeriFinController.create(store, repository: repo);
    expect(
      await c.addAccountDraft(_account('银行', AccountType.debitCard)),
      isTrue,
    );
    final parentId = c.accountParents.single.id;
    final usd = (await c.ensureCurrencyChild(parentId, 'USD'))!;
    await c.waitForPendingWrites();
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    addTearDown(c.dispose);
    expect(c.accountsForParent(parentId), hasLength(2));
    expect(c.creditAccounts, isEmpty);
    final raw = c.exportDataJson();
    expect((jsonDecode(raw) as Map)['version'], 15);
    final restored = await makeController();
    addTearDown(restored.dispose);
    restored.importDataJson(raw, dryRun: true);
    expect(restored.accountParents, isEmpty);
    restored.importDataJson(raw);
    await restored.waitForPendingWrites();
    expect(
      restored.accounts.map((a) => a.toJson()).toList(),
      c.accounts.map((a) => a.toJson()).toList(),
    );
    expect(
      restored.accountParents.single.toJson(),
      c.accountParents.single.toJson(),
    );
    expect(await c.deleteAccount(usd.id), isNotNull);
    expect(c.accountParents, hasLength(1));
    expect(await c.deleteAccount('银行'), isNotNull);
    expect(c.accountParents, isEmpty);
    expect(await repo.loadCreditAccounts(), isEmpty);
  });

  for (final width in [393.0, 360.0]) {
    testWidgets('普通主账户详情 ${width}dp 可查看三币种，无还款和额度入口', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 852);
      addTearDown(tester.view.reset);
      final c = await makeController();
      addTearDown(c.dispose);
      await c.addAccountDraft(_account('汇丰银行', AccountType.debitCard));
      final parent = c.accountParents.single;
      await c.ensureCurrencyChild(parent.id, 'USD');
      await c.ensureCurrencyChild(parent.id, 'CNY');
      await tester.pumpWidget(
        VeriFinScope(
          controller: c,
          child: zhMaterialApp(
            home: CreditAccountDetailPage(parentId: parent.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('HKD'), findsOneWidget);
      expect(find.text('USD'), findsOneWidget);
      expect(find.text('CNY'), findsOneWidget);
      expect(find.text('按主账户币种估值'), findsOneWidget);
      expect(find.text('共享额度'), findsNothing);
      expect(find.text('还款'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('普通主账户编辑页不显示信用字段，记账选择器只显示主账户', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    await c.addAccountDraft(_account('老虎证券', AccountType.investment));
    final parent = c.accountParents.single;
    await c.ensureCurrencyChild(parent.id, 'USD');
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: CreditAccountEditorPage(creditAccount: parent),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('主账户设置'), findsOneWidget);
    expect(find.text('主账户币种'), findsOneWidget);
    expect(find.text('账单日'), findsNothing);
    expect(find.text('还款日'), findsNothing);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAccountPickerSheet(
                context: context,
                title: '选择账户',
                accounts: c.accounts,
                selectedId: c.accounts.first.id,
                balanceOf: c.accountBalance,
                includeCreditParents: true,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('$creditParentPickerPrefix${parent.id}')),
      findsOneWidget,
    );
    expect(find.text('老虎证券.USD'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
