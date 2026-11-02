import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/account_detail_page.dart';
import 'package:verifin/pages/account_information_section.dart';
import 'package:verifin/pages/account_navigation.dart';
import 'package:verifin/pages/credit_account_detail_page.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/investment_fixture.dart';
import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

/// 延迟普通资料写入，模拟用户点击保存后数据库尚未完成的窗口。
class _DelayedAccountDetailsRepository extends InMemoryLedgerRepository {
  Completer<void>? pendingSave;
  int delayedAttempts = 0;

  /// 开户及初始化保持原行为，只暂停启用测试闸门后的账户资料保存。
  @override
  Future<void> saveAccounts(List<Account> accounts) async {
    final pending = pendingSave;
    if (pending != null) {
      delayedAttempts++;
      await pending.future;
    }
    await super.saveAccounts(accounts);
  }
}

/// 从真实 Navigator 的按钮发起账户导航，验证返回栈与实际页面类型。
Widget _navigationHome({String? accountId, String? parentId}) => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: FilledButton(
        key: const Key('open-account'),
        onPressed: () => openAccountDetails(
          context: context,
          accountId: accountId,
          parentId: parentId,
        ),
        child: const Text('打开账户'),
      ),
    ),
  ),
);

void main() {
  useTestDatabases();

  testWidgets('空持仓证券账户直达证券详情，未初始化投资类账户保持普通详情', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: _navigationHome(accountId: account.id)),
      ),
    );
    await tester.tap(find.byKey(const Key('open-account')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsOneWidget);
    expect(find.byType(InvestmentPage), findsNothing);
    Navigator.of(tester.element(find.byType(AccountDetailPage))).pop();
    await tester.pumpAndSettle();

    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
    await tester.tap(find.byKey(const Key('open-account')));
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentPage), findsOneWidget);
    expect(find.byType(AccountDetailPage), findsNothing);
    expect(c.investmentFor(account.id)!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('证券主账户先显示币种汇总，点真实币种子账户后直达持仓', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    // 使用生产开户命令建立真实主账户和币种组合，旧 addAccount 不为普通投资类型建父。
    expect(
      await c.createSecuritiesAccount(
        account: account,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
    final current = c.accounts.firstWhere((item) => item.id == account.id);
    final parent = c.parentForAccount(current)!;
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: _navigationHome(parentId: parent.id)),
      ),
    );
    await tester.tap(find.byKey(const Key('open-account')));
    await tester.pumpAndSettle();
    expect(find.byType(CreditAccountDetailPage), findsOneWidget);
    expect(find.byType(InvestmentPage), findsNothing);
    // 首个子账户可与自动创建的主账户同名，只点币种子账户行，避免误命中页头。
    final currencyChild = find.descendant(
      of: find.byType(CreditAccountDetailPage),
      matching: find.widgetWithText(ListTile, current.name),
    );
    expect(currencyChild, findsOneWidget);
    await tester.tap(currencyChild);
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentPage), findsOneWidget);
    expect(find.byType(AccountDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('证券资料编辑复用原字段与保存，取消草稿不改持仓现金', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await c.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
    );
    final originalPortfolio = c.investmentFor(account.id)!.toJson();
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AccountInformationSection(account: account),
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const Key('investment-edit-account-information')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsOneWidget);
    expect(find.text('余额趋势'), findsNothing);
    expect(find.text('当前余额'), findsNothing);
    expect(find.text('证券投资'), findsNothing);
    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '更名后的证券账户');
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(
      c.accounts.firstWhere((item) => item.id == account.id).name,
      account.name,
    );
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不保存'));
    await tester.pumpAndSettle();
    expect(
      c.accounts.firstWhere((item) => item.id == account.id).name,
      account.name,
    );
    expect(c.investmentFor(account.id)!.toJson(), originalPortfolio);

    await tester.tap(
      find.byKey(const Key('investment-edit-account-information')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '更名后的证券账户');
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(
      c.accounts.firstWhere((item) => item.id == account.id).name,
      '更名后的证券账户',
    );
    expect(c.investmentFor(account.id)!.toJson(), originalPortfolio);
    expect(
      c.accountBalance(c.accounts.firstWhere((a) => a.id == account.id)),
      10000,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('证券资料保存期间锁定输入、重复保存和系统返回，完成后现金持仓不变', (tester) async {
    final repo = _DelayedAccountDetailsRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    final account = investmentAccountFixture(id: 'delayed-details');
    expect(
      await c.createSecuritiesAccount(account: account, openingCash: '2000'),
      isTrue,
    );
    final portfolioBefore = c.investmentFor(account.id)!.toJson();
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AccountInformationSection(account: account),
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const Key('investment-edit-account-information')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保存中的证券资料');
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();

    final pending = Completer<void>();
    repo.pendingSave = pending;
    addTearDown(() {
      if (!pending.isCompleted) pending.complete();
    });
    await tester.tap(find.byTooltip('保存'));
    await tester.pump();
    expect(repo.delayedAttempts, 1);
    expect(
      tester.widget<SaveHeaderAction>(find.byType(SaveHeaderAction)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<AbsorbPointer>(
            find.byKey(const Key('account-detail-saving-lock')),
          )
          .absorbing,
      isTrue,
    );
    // 用户在保存中点资料、再次保存或使用系统返回，均不能修改/丢弃正在写入的草稿。
    await tester.tap(find.text('名称'), warnIfMissed: false);
    await tester.tap(find.byTooltip('保存'), warnIfMissed: false);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('保存修改？'), findsNothing);
    expect(repo.delayedAttempts, 1);
    expect(
      c.accounts.singleWhere((value) => value.id == account.id).name,
      account.name,
    );

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsNothing);
    expect(
      c.accounts.singleWhere((value) => value.id == account.id).name,
      '保存中的证券资料',
    );
    expect(c.investmentFor(account.id)!.toJson(), portfolioBefore);
    expect(
      c.accountBalance(c.accounts.singleWhere((a) => a.id == account.id)),
      2000,
    );
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已删除或跨账本账户 ID 不回退打开首个账户', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: _navigationHome(accountId: 'deleted-account'),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-account')));
    await tester.pumpAndSettle();
    expect(find.byType(AccountDetailPage), findsNothing);
    expect(find.byType(InvestmentPage), findsNothing);
    expect(find.byKey(const Key('open-account')), findsOneWidget);
  });
}
