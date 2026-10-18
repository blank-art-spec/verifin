import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_hierarchy.dart';
import 'package:verifin/app/frankfurter_client.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/statistics_currency.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/credit_account_detail_page.dart';
import 'package:verifin/pages/credit_repayment_page.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

Account card(String id, String currency, {String? parent, String? name}) =>
    Account(
      id: id,
      bookId: 'default',
      name: name ?? id,
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      currencyCode: currency,
      creditAccountId: parent,
      statementDay: 25,
      dueDay: 13,
    );
CreditAccount parent(String id, String name) => CreditAccount(
  id: id,
  bookId: 'default',
  name: name,
  institution: '',
  cardLast4: '',
  currencyCode: 'CNY',
  creditLimit: 20000,
  statementDay: 25,
  dueRuleType: CreditDueRuleType.fixedDay,
  dueDay: 13,
  daysAfterStatement: null,
  cycleBudget: null,
);
LedgerEntry expense(
  String id,
  String account,
  String currency,
  double amount, {
  double? reference,
  DateTime? date,
}) => LedgerEntry(
  id: id,
  bookId: 'default',
  type: EntryType.expense,
  amount: amount,
  currencyCode: currency,
  accountAmount: amount,
  baseAmount: currency == 'CNY' ? amount : reference ?? 0,
  referenceBaseAmount: reference,
  categoryId: 'dining',
  accountId: account,
  note: id,
  occurredAt: date ?? DateTime(2026, 9, 10),
);
ExchangeRate rate(
  double amount, {
  ExchangeRateSource source = ExchangeRateSource.online,
}) => ExchangeRate(
  id: 'rate',
  bookId: 'default',
  baseCurrencyCode: 'CNY',
  currencyCode: 'USD',
  effectiveDate: DateTime(2026, 10, 1),
  rateToBase: amount,
  source: source,
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
);

Future<({VeriFinController c, Account cny, Account usd, String parent})> setup({
  InMemoryLedgerRepository? repo,
}) async {
  final c = repo == null
      ? await makeController()
      : await VeriFinController.create(LocalKeyValueStore(), repository: repo);
  addTearDown(c.dispose);
  expect(await c.addAccountDraft(card('cny', 'CNY')), isTrue);
  final first = c.accounts.single;
  expect(
    await c.addAccountDraft(card('usd', 'USD', parent: first.creditAccountId)),
    isTrue,
  );
  final usd = c.accounts.firstWhere((a) => a.id == 'usd');
  for (final e in [
    expense('cny-expense', 'cny', 'CNY', 100),
    expense('usd-expense', 'usd', 'USD', 10),
  ]) {
    expect(
      (await c.saveEntryAggregateDraftResult(entry: e, isNew: true)).isSuccess,
      isTrue,
    );
  }
  for (final a in c.accounts) {
    expect(
      await c.createBillingStatement(
        account: a,
        statementDate: DateTime(2026, 9, 25),
        periodStart: DateTime(2026, 8, 26),
        periodEnd: DateTime(2026, 9, 25),
        statementAmount: a.currencyCode == 'CNY' ? 100 : 10,
        minimumPayment: 0,
        dueDate: DateTime(2026, 10, 13),
        paidAmount: 0,
      ),
      isTrue,
    );
  }
  return (c: c, cny: first, usd: usd, parent: first.creditAccountId!);
}

class FailingCreditRepository extends InMemoryLedgerRepository {
  bool fail = false;
  @override
  Future<void> saveCreditAggregate({
    required List<LedgerEntry> entries,
    required List<BillingStatement> statements,
    required List<StatementRepaymentAllocation> allocations,
  }) async {
    if (fail) throw StateError('simulated failure');
    await super.saveCreditAggregate(
      entries: entries,
      statements: statements,
      allocations: allocations,
    );
  }
}

class FixedRates extends FrankfurterClient {
  FixedRates(this.value, {this.failure = false, this.wait});
  final double value;
  final bool failure;
  final Future<void>? wait;
  @override
  Future<List<({String currency, DateTime date, double rate})>> fetch({
    required String base,
    required Set<String> currencies,
    DateTime? date,
  }) async {
    await wait;
    if (failure) throw StateError('offline');
    return [(currency: 'USD', date: DateTime(2026, 10, 1), rate: value)];
  }
}

class DelayedCreditRepository extends InMemoryLedgerRepository {
  bool hold = false;
  final entered = Completer<void>();
  final released = Completer<void>();
  @override
  Future<void> saveCreditAggregate({
    required List<LedgerEntry> entries,
    required List<BillingStatement> statements,
    required List<StatementRepaymentAllocation> allocations,
  }) async {
    if (hold) {
      if (!entered.isCompleted) entered.complete();
      await released.future;
    }
    await super.saveCreditAggregate(
      entries: entries,
      statements: statements,
      allocations: allocations,
    );
  }
}

void main() {
  useTestDatabases();

  testWidgets('父账户最近与全部互斥，默认最近二十条，新增币种不写流水', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 1200);
    addTearDown(tester.view.reset);
    final f = await setup();
    for (var i = 0; i < 25; i++) {
      expect(
        (await f.c.saveEntryAggregateDraftResult(
          entry: expense(
            'extra-$i',
            'cny',
            'CNY',
            1,
            date: DateTime(2026, 10, 1, 0, i),
          ),
          isNew: true,
        )).isSuccess,
        isTrue,
      );
    }
    await tester.pumpWidget(
      VeriFinScope(
        controller: f.c,
        child: zhMaterialApp(home: CreditAccountDetailPage(parentId: f.parent)),
      ),
    );
    await tester.pumpAndSettle();
    int visibleEntryCount() {
      final list = tester.widget<ListView>(find.byType(ListView).first);
      return (list.childrenDelegate as SliverChildListDelegate).children
          .whereType<TransactionTile>()
          .length;
    }

    expect(visibleEntryCount(), 20);
    await tester.scrollUntilVisible(
      find.byKey(const Key('credit_parent_entry_filter')),
      180,
      scrollable: firstVerticalScrollable(),
    );
    await tester.tap(find.text('全部').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('credit_parent_filter_all')), findsOneWidget);
    expect(find.byKey(const Key('credit_parent_filter_recent')), findsNothing);
    expect(visibleEntryCount(), 27);
    await tester.tap(find.text('最近交易').first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('credit_parent_filter_recent')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('credit_parent_filter_all')), findsNothing);
    expect(visibleEntryCount(), 20);
    tester.state<ScrollableState>(firstVerticalScrollable()).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('新增币种子账户'));
    await tester.tap(find.byTooltip('新增币种子账户'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('currency_option_CNY')), findsNothing);
    expect(find.byKey(const Key('currency_option_USD')), findsNothing);
    await tester.tap(find.byKey(const Key('currency_option_EUR')));
    await tester.pumpAndSettle();
    final eur = f.c
        .accountsForCreditAccount(f.parent)
        .singleWhere((a) => a.currencyCode == 'EUR');
    expect(f.c.accountBalance(eur), 0);
    expect(f.c.entries, hasLength(27));
    await tester.tap(find.byTooltip('新增币种子账户'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('currency_option_EUR')), findsNothing);
    Navigator.of(
      tester.element(find.byKey(const Key('currency_search_field'))),
    ).pop();
    await tester.pumpAndSettle();
    expect(f.c.accountsForCreditAccount(f.parent), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('还款选择日期时分，同批原币记录完整保存，编辑保留时点', (tester) async {
    tester.platformDispatcher.alwaysUse24HourFormatTestValue = true;
    addTearDown(tester.platformDispatcher.clearAlwaysUse24HourTestValue);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 1200);
    addTearDown(tester.view.reset);
    final f = await setup();
    await tester.pumpWidget(
      VeriFinScope(
        controller: f.c,
        child: zhMaterialApp(home: CreditRepaymentPage(account: f.cny)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('repay_time')));
    await tester.tap(find.byKey(const Key('repay_time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final timeFields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(timeFields.at(0), '14');
    await tester.enterText(timeFields.at(1), '37');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('14:37'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repay_date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12').last);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('保存'));
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    final batch = f.c.entries.where((e) => e.repaymentBatchId != null).toList();
    expect(batch, hasLength(2));
    for (final entry in batch) {
      expect(entry.occurredAt.day, 12);
      expect(entry.occurredAt.hour, 14);
      expect(entry.occurredAt.minute, 37);
      expect(entry.occurredAt.second, 0);
      expect(entry.occurredAtPrecision, OccurredAtPrecision.minute);
    }
    final backup = f.c.exportDataJson();
    final restored = await makeController();
    addTearDown(restored.dispose);
    restored.importDataJson(backup);
    await restored.waitForPendingWrites();
    await tester.pumpWidget(
      VeriFinScope(
        controller: restored,
        child: zhMaterialApp(
          home: CreditRepaymentPage(
            key: const Key('edit-time'),
            account: restored.accounts.firstWhere((a) => a.id == 'cny'),
            batchId: batch.first.repaymentBatchId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('repay_time')));
    expect(find.text('14:37'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repay_time')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('14:37'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('旧币种账户按明确名称归并，保留全部账户 ID，重复执行不变', () {
    final old = [
      card('a', 'CNY', parent: 'p1', name: '招行卡.人民币'),
      card('b', 'USD', parent: 'p2', name: '招行卡.美元'),
    ];
    final next = normalizeCreditHierarchy(old, [
      parent('p1', '招行卡.人民币'),
      parent('p2', '招行卡.美元'),
    ]);
    expect(next.parents.single.name, '招行卡');
    expect(next.accounts.map((a) => a.id), ['a', 'b']);
    expect(next.accounts.map((a) => a.creditAccountId).toSet(), {'p1'});
    final again = normalizeCreditHierarchy(next.accounts, next.parents);
    expect(
      jsonEncode(again.accounts.map((a) => a.toJson()).toList()),
      jsonEncode(next.accounts.map((a) => a.toJson()).toList()),
    );
    expect(
      jsonEncode(again.parents.map((a) => a.toJson()).toList()),
      jsonEncode(next.parents.map((a) => a.toJson()).toList()),
    );
  });
  test('冲突卡尾号和重复币种不自动归并', () {
    final old = [
      card(
        'a',
        'CNY',
        parent: 'p1',
        name: '招行卡.人民币',
      ).copyWith(cardLast4: '1234'),
      card(
        'b',
        'USD',
        parent: 'p2',
        name: '招行卡.美元',
      ).copyWith(cardLast4: '5678'),
    ];
    expect(
      normalizeCreditHierarchy(old, [
        parent('p1', '招行卡.人民币'),
        parent('p2', '招行卡.美元'),
      ]).parents.length,
      2,
    );
  });
  test('手填折算固定，未填采用最新汇率且原始金额不变，缺汇率明确返回', () {
    final book = LedgerBook(
      id: 'default',
      name: '账本',
      createdAt: DateTime(2026),
      isDefault: true,
    );
    final entries = [
      expense('fixed', 'usd', 'USD', 100, reference: 720),
      expense('floating', 'usd', 'USD', 100),
    ];
    final projection = projectStatisticsCurrency(
      entries: entries,
      book: book,
      rates: [rate(8)],
      now: DateTime(2026, 10, 18),
    );
    expect(projection.entries.map((e) => e.baseAmount), [720, 800]);
    expect(entries.last.baseAmount, 0);
    expect(entries.last.referenceBaseAmount, isNull);
    final missing = projectStatisticsCurrency(
      entries: entries,
      book: book,
      rates: [],
      now: DateTime(2026, 10, 18),
    );
    expect(missing.missing, {'USD'});
    expect(missing.entries.first.baseAmount, 720);
  });
  test('旧手填折算迁移保留，转账不产生参考额，明确清除后不回填', () {
    final old = expense('old', 'usd', 'USD', 10).toJson()
      ..remove('referenceBaseAmount')
      ..['conversionSource'] = 'manual'
      ..['baseAmount'] = 72;
    expect(LedgerEntry.fromJson(old).referenceBaseAmount, 72);
    old['type'] = 'transfer';
    old['baseAmount'] = 0;
    expect(LedgerEntry.fromJson(old).referenceBaseAmount, isNull);
    final cleared = expense(
      'clear',
      'usd',
      'USD',
      10,
      reference: 72,
    ).copyWith(clearReferenceBaseAmount: true);
    expect(LedgerEntry.fromJson(cleared.toJson()).referenceBaseAmount, isNull);
  });
  test('当前全额结清原币账单，未填折算也允许，未出账保留，整批删除恢复', () async {
    final f = await setup();
    final c = f.c;
    expect(
      (await c.saveEntryAggregateDraftResult(
        entry: expense(
          'unbilled',
          'usd',
          'USD',
          5,
          date: DateTime(2026, 10, 5),
        ),
        isNew: true,
      )).isSuccess,
      isTrue,
    );
    final lines = c.creditRepaymentDefaults(
      f.parent,
      CreditRepaymentScope.current,
    );
    expect(c.repaymentMissingReferences(f.parent, lines), isEmpty);
    final result = await c.recordCreditRepaymentBatch(
      batchId: 'batch',
      parentId: f.parent,
      lines: lines,
      occurredAt: DateTime(2026, 10, 18),
    );
    expect(result.isSuccess, isTrue);
    expect(c.accountBalance(f.cny), 0);
    expect(c.accountBalance(f.usd), -5);
    expect(
      c.billingStatements.every((s) => s.status == BillingStatementStatus.paid),
      isTrue,
    );
    expect(c.entries.where((e) => e.repaymentBatchId == 'batch').length, 2);
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'batch',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
      )).isSuccess,
      isTrue,
    );
    expect(c.entries.where((e) => e.repaymentBatchId == 'batch').length, 2);
    expect(
      await c.deleteEntry(
        c.entries.firstWhere((e) => e.repaymentBatchId == 'batch').id,
      ),
      isTrue,
    );
    expect(c.accountBalance(f.cny), -100);
    expect(c.accountBalance(f.usd), -15);
    expect(c.statementRepaymentAllocations, isEmpty);
  });
  test('部分还款缺折算时阻止全部保存，补齐后按各自原币还款', () async {
    final f = await setup();
    final c = f.c;
    final lines = [
      const CreditRepaymentLine(accountId: 'cny', amount: 50),
      const CreditRepaymentLine(accountId: 'usd', amount: 5),
    ];
    expect(c.repaymentMissingReferences(f.parent, lines).map((e) => e.id), [
      'usd-expense',
    ]);
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'partial',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
      )).isSuccess,
      isFalse,
    );
    expect(c.entries.length, 2);
    expect(
      (await c.confirmReferenceAmount('usd-expense', 72)).isSuccess,
      isTrue,
    );
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'partial',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
      )).isSuccess,
      isTrue,
    );
    expect(c.accountBalance(f.cny), -50);
    expect(c.accountBalance(f.usd), -5);
  });
  test('全部待还涉及未出账外币，必须补齐，当前账单豁免不外溢', () async {
    final f = await setup();
    final c = f.c;
    expect(
      (await c.saveEntryAggregateDraftResult(
        entry: expense('future', 'usd', 'USD', 5, date: DateTime(2026, 10, 5)),
        isNew: true,
      )).isSuccess,
      isTrue,
    );
    final lines = c.creditRepaymentDefaults(f.parent, CreditRepaymentScope.all);
    expect(c.repaymentMissingReferences(f.parent, lines).map((e) => e.id), [
      'future',
    ]);
    expect((await c.confirmReferenceAmount('future', 36)).isSuccess, isTrue);
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'all',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
      )).isSuccess,
      isTrue,
    );
    expect(c.accountBalance(f.usd), 0);
  });
  test('持久化失败无半笔还款，重试仅保存一次，整批编辑一致', () async {
    final repo = FailingCreditRepository();
    final f = await setup(repo: repo);
    final c = f.c;
    final lines = c.creditRepaymentDefaults(
      f.parent,
      CreditRepaymentScope.current,
    );
    repo.fail = true;
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'retry',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
      )).isSuccess,
      isFalse,
    );
    expect(c.entries.length, 2);
    expect(c.accountBalance(f.usd), -10);
    expect(c.statementRepaymentAllocations, isEmpty);
    repo.fail = false;
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'retry',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
      )).isSuccess,
      isTrue,
    );
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'retry',
        parentId: f.parent,
        lines: lines,
        occurredAt: DateTime(2026, 10, 18),
        replace: true,
        note: 'edited',
      )).isSuccess,
      isTrue,
    );
    expect(
      c.entries
          .where((e) => e.repaymentBatchId == 'retry')
          .every((e) => e.note == 'edited'),
      isTrue,
    );
    expect(c.accountBalance(f.usd), 0);
  });
  test('联网汇率保留手填同日值，离线不清缓存，统计与余额分开', () async {
    final f = await setup();
    final c = f.c;
    expect(c.autoExchangeRates, isFalse);
    expect(await c.syncExchangeRates(client: FixedRates(8)), isTrue);
    expect(c.exchangeRates.single.source, ExchangeRateSource.online);
    expect(
      c.statisticsEntries.firstWhere((e) => e.id == 'usd-expense').baseAmount,
      80,
    );
    expect(c.accountBalance(f.usd), -10);
    expect(
      await c.saveExchangeRateDraft(
        currencyCode: 'USD',
        effectiveDate: DateTime(2026, 10, 1),
        rateToBase: 7.2,
      ),
      isTrue,
    );
    expect(await c.syncExchangeRates(client: FixedRates(9)), isTrue);
    expect(c.exchangeRates.single.rateToBase, 7.2);
    expect(
      await c.syncExchangeRates(client: FixedRates(0, failure: true)),
      isFalse,
    );
    expect(c.exchangeRates.single.rateToBase, 7.2);
    expect(c.rateSyncFailed, isTrue);
  });
  test('网络等待期间手填汇率不会被覆盖', () async {
    final f = await setup();
    final gate = Completer<void>();
    final sync = f.c.syncExchangeRates(
      client: FixedRates(8, wait: gate.future),
    );
    expect(
      await f.c.saveExchangeRateDraft(
        currencyCode: 'USD',
        effectiveDate: DateTime(2026, 10, 1),
        rateToBase: 7.1,
      ),
      isTrue,
    );
    gate.complete();
    expect(await sync, isTrue);
    expect(f.c.exchangeRates.single.rateToBase, 7.1);
  });
  test('旧备份自动归并并保留 ID，清除参考额后恢复不会重新固定', () async {
    final f = await setup();
    final root = jsonDecode(f.c.exportDataJson()) as Map<String, dynamic>;
    root['version'] = 8;
    final data = root['data'] as Map<String, dynamic>;
    data['creditAccounts'] = [
      parent('legacy-cny', '招行卡.人民币').toJson(),
      parent('legacy-usd', '招行卡.美元').toJson(),
    ];
    for (final raw in data['accounts'] as List) {
      final a = raw as Map<String, dynamic>;
      a['name'] = a['id'] == 'cny' ? '招行卡.人民币' : '招行卡.美元';
      a['creditAccountId'] = 'legacy-${a['id']}';
    }
    for (final raw in data['entries'] as List) {
      final e = raw as Map<String, dynamic>;
      e.remove('referenceBaseAmount');
      if (e['id'] == 'usd-expense') {
        e['baseAmount'] = 72;
        e['conversionSource'] = 'manual';
      }
    }
    final restored = await makeController();
    addTearDown(restored.dispose);
    restored.importDataJson(jsonEncode(root));
    await restored.waitForPendingWrites();
    expect(restored.creditAccounts.single.name, '招行卡');
    expect(restored.accounts.map((a) => a.id).toSet(), {'cny', 'usd'});
    expect(restored.entries.map((e) => e.id).toSet(), {
      'cny-expense',
      'usd-expense',
    });
    final usd = restored.entries.firstWhere((e) => e.id == 'usd-expense');
    expect(usd.referenceBaseAmount, 72);
    expect(
      (await restored.saveEntryAggregateDraftResult(
        entry: usd.copyWith(baseAmount: 0, clearReferenceBaseAmount: true),
        isNew: false,
      )).isSuccess,
      isTrue,
    );
    final reload = await makeController();
    addTearDown(reload.dispose);
    reload.importDataJson(restored.exportDataJson());
    expect(
      reload.entries
          .firstWhere((e) => e.id == 'usd-expense')
          .referenceBaseAmount,
      isNull,
    );
    expect(reload.creditAccounts.single.name, '招行卡');
  });
  test('无正式账单的外币结转也不能绕过部分还款检查', () async {
    final f = await setup();
    for (final s in List<BillingStatement>.of(f.c.billingStatements)) {
      expect(await f.c.deleteBillingStatement(s.id), isTrue);
    }
    final half = [
      const CreditRepaymentLine(accountId: 'cny', amount: 50),
      const CreditRepaymentLine(accountId: 'usd', amount: 5),
    ];
    expect(f.c.repaymentMissingReferences(f.parent, half).map((e) => e.id), [
      'usd-expense',
    ]);
    expect(
      f.c.repaymentMissingReferences(
        f.parent,
        f.c.creditRepaymentDefaults(f.parent, CreditRepaymentScope.current),
      ),
      isEmpty,
    );
  });
  test('多币种扣款分摊合计一次，修改和删除整批同步恢复', () async {
    final f = await setup();
    final c = f.c;
    expect(
      (await c.confirmReferenceAmount('usd-expense', 72)).isSuccess,
      isTrue,
    );
    expect(
      await c.addAccountDraft(
        card('bank', 'CNY').copyWith(
          type: AccountType.debitCard,
          initialBalance: 1000,
          clearCreditAccountId: true,
        ),
      ),
      isTrue,
    );
    final full = [
      const CreditRepaymentLine(
        accountId: 'cny',
        amount: 100,
        sourceAmount: 100,
      ),
      const CreditRepaymentLine(accountId: 'usd', amount: 10, sourceAmount: 72),
    ];
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'debit',
        parentId: f.parent,
        lines: full,
        occurredAt: DateTime(2026, 10, 18),
        fromAccountId: 'bank',
      )).isSuccess,
      isTrue,
    );
    final bank = c.accounts.firstWhere((a) => a.id == 'bank');
    expect(c.accountBalance(bank), 828);
    final half = [
      const CreditRepaymentLine(
        accountId: 'cny',
        amount: 100,
        sourceAmount: 100,
      ),
      const CreditRepaymentLine(accountId: 'usd', amount: 5, sourceAmount: 36),
    ];
    expect(
      (await c.recordCreditRepaymentBatch(
        batchId: 'debit',
        parentId: f.parent,
        lines: half,
        occurredAt: DateTime(2026, 10, 18),
        fromAccountId: 'bank',
        replace: true,
      )).isSuccess,
      isTrue,
    );
    expect(c.accountBalance(bank), 864);
    expect(c.accountBalance(f.usd), -5);
    expect(
      await c.deleteEntry(
        c.entries.firstWhere((e) => e.repaymentBatchId == 'debit').id,
      ),
      isTrue,
    );
    expect(c.accountBalance(bank), 1000);
    expect(c.accountBalance(f.usd), -10);
  });
  test('联网等待时切换账本，不把旧币对写入新账本', () async {
    final f = await setup();
    final gate = Completer<void>();
    final oldId = f.c.activeBook.id;
    final sync = f.c.syncExchangeRates(
      client: FixedRates(8, wait: gate.future),
    );
    f.c.addLedgerBook('USD账本', baseCurrencyCode: 'USD');
    await f.c.waitForPendingWrites();
    gate.complete();
    expect(await sync, isTrue);
    expect(f.c.exchangeRates, isEmpty);
    f.c.switchLedgerBook(oldId);
    expect(f.c.exchangeRates.single.baseCurrencyCode, 'CNY');
  });
  testWidgets('选择父账户后按美元入账，填写人民币参考额不会改挂人民币子账户', (tester) async {
    final f = await setup();
    await tester.pumpWidget(
      VeriFinScope(
        controller: f.c,
        child: zhMaterialApp(
          home: const EntryDetailPage(
            initialAmount: 10,
            initialAccountId: 'cny',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('account_dropdown')));
    await tester.tap(find.byKey(const Key('account_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cny (父账户)'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('entry_currency_button')));
    await tester.tap(find.byKey(const Key('entry_currency_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('currency_option_USD')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('entry_base_amount')));
    await tester.tap(find.byKey(const Key('entry_base_amount')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number_key_C')));
    for (final digit in ['7', '2']) {
      await tester.tap(find.byKey(Key('number_key_$digit')));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save_entry_button')));
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    final saved = f.c.entries
        .where((e) => e.id != 'cny-expense' && e.id != 'usd-expense')
        .single;
    expect(saved.accountId, 'usd');
    expect(saved.currencyCode, 'USD');
    expect(saved.accountAmount, 10);
    expect(saved.referenceBaseAmount, 72);
    expect(f.c.accountBalance(f.cny), -100);
  });

  test('汇率保存排队时切换账本，仍写入提交时所属账本', () async {
    final repo = DelayedCreditRepository();
    final f = await setup(repo: repo);
    final c = f.c;
    final old = c.activeBook.id;
    repo.hold = true;
    final paying = c.recordCreditRepaymentBatch(
      batchId: 'queued',
      parentId: f.parent,
      lines: c.creditRepaymentDefaults(f.parent, CreditRepaymentScope.current),
      occurredAt: DateTime(2026, 10, 18),
    );
    await repo.entered.future;
    final writing = c.saveExchangeRateDraft(
      currencyCode: 'USD',
      effectiveDate: DateTime(2026, 10, 1),
      rateToBase: 7.2,
    );
    c.addLedgerBook('美元账本', baseCurrencyCode: 'USD');
    repo.released.complete();
    expect((await paying).isSuccess, isTrue);
    expect(await writing, isTrue);
    expect(c.exchangeRates, isEmpty);
    c.switchLedgerBook(old);
    expect(c.exchangeRates.single.baseCurrencyCode, 'CNY');
    expect(c.exchangeRates.single.rateToBase, 7.2);
  });

  test('部分还款校验尊重银行确认归期，不因记账日跨期而漏掉待还外币', () async {
    final f = await setup();
    final original = f.c.entries.firstWhere((e) => e.id == 'usd-expense');
    expect(
      (await f.c.saveEntryAggregateDraftResult(
        entry: original.copyWith(
          occurredAt: DateTime(2026, 10, 1),
          postDate: DateTime(2026, 10, 3),
          billingCycleId: '2026-09-25',
        ),
        isNew: false,
      )).isSuccess,
      isTrue,
    );
    final lines = [
      const CreditRepaymentLine(accountId: 'cny', amount: 50),
      const CreditRepaymentLine(accountId: 'usd', amount: 5),
    ];
    expect(f.c.repaymentMissingReferences(f.parent, lines).map((e) => e.id), [
      'usd-expense',
    ]);
  });

  for (final width in [393.0, 360.0]) {
    testWidgets('父账户和多币种还款窄屏不溢出 $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final f = await setup();
      await tester.pumpWidget(
        VeriFinScope(
          controller: f.c,
          child: zhMaterialApp(
            home: CreditAccountDetailPage(parentId: f.parent),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('币种子账户'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        VeriFinScope(
          controller: f.c,
          child: zhMaterialApp(home: CreditRepaymentPage(account: f.cny)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('repay_scope')), findsOneWidget);
      expect(find.byKey(const Key('repay_amount_USD')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
