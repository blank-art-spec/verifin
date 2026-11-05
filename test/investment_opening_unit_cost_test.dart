import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/investment_setup_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

Finder _formScroll() => find
    .descendant(
      of: find.byType(StockEditorPage),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openEditor(
  WidgetTester tester,
  VeriFinController controller,
  Widget page,
) async {
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push<void>(MaterialPageRoute(builder: (_) => page)),
              child: const Text('打开表单'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开表单'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String field, String value) async {
  final finder = find.byKey(ValueKey('stock-$field'));
  await tester.scrollUntilVisible(finder, 220, scrollable: _formScroll());
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final save = find.widgetWithText(FilledButton, '保存');
  await tester.scrollUntilVisible(save, 220, scrollable: _formScroll());
  await tester.tap(save);
  await tester.pumpAndSettle();
}

/// 通过真实启用列表添加单条草稿；单条返回后仍不能创建账户组合。
Future<void> _startOpening(
  WidgetTester tester,
  VeriFinController controller,
  String accountId,
) async {
  await _openEditor(
    tester,
    controller,
    InvestmentSetupPage(accountId: accountId),
  );
  await tester.enterText(find.byKey(const Key('opening-cash')), '100');
  final add = find.byKey(const Key('opening-add-stock'));
  await tester.scrollUntilVisible(
    add,
    180,
    scrollable: find
        .descendant(
          of: find.byType(InvestmentSetupPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(add);
  await tester.pumpAndSettle();
}

/// 最终保存同时提交现金及全部期初草稿。
Future<void> _saveOpening(WidgetTester tester) async {
  final save = find.byKey(const Key('opening-save'));
  await tester.scrollUntilVisible(
    save,
    220,
    scrollable: find
        .descendant(
          of: find.byType(InvestmentSetupPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  useTestDatabases();

  for (final sample in [
    (
      name: '碎股单位成本保留八位输入，先相乘再按美元分舍入',
      quantity: '2.5',
      unitCost: '12.34567891',
      totalCost: '30.86',
      currency: 'USD',
      short: false,
    ),
    (
      name: '量价乘积只舍入一次，临界分值不被先舍八位抬高',
      quantity: '0.00000001',
      unitCost: '499999.99999999',
      totalCost: '0',
      currency: 'USD',
      short: false,
    ),
    (
      name: '空白单位成本继续表示未知',
      quantity: '3',
      unitCost: '',
      totalCost: null,
      currency: 'USD',
      short: false,
    ),
    (
      name: '明确输入零成本不变为未知',
      quantity: '3',
      unitCost: '0',
      totalCost: '0',
      currency: 'USD',
      short: false,
    ),
    (
      name: '空头按每股净开仓成本换算，现金不重复增加',
      quantity: '2.5',
      unitCost: '10.12',
      totalCost: '25.3',
      currency: 'USD',
      short: true,
    ),
    (
      name: '无小数币种按对应现金精度保存总成本',
      quantity: '2.5',
      unitCost: '12.34567891',
      totalCost: '31',
      currency: 'JPY',
      short: false,
    ),
  ]) {
    testWidgets(sample.name, (tester) async {
      final store = LocalKeyValueStore();
      final c = await makeController(store);
      addTearDown(c.dispose);
      final account = investmentAccountFixture(currency: sample.currency);
      c.addAccount(account);
      await c.waitForPendingWrites();
      await _startOpening(tester, c, account.id);
      await _enter(tester, 'symbol', 'AVGO');
      await _enter(tester, 'name', '博通');
      await _enter(tester, 'quantity', sample.quantity);
      await _enter(tester, 'cost', sample.unitCost);
      expect(find.text('期初单位成本'), findsOneWidget);
      expect(find.text('期初总成本（留空表示未知）'), findsNothing);
      if (sample.short) {
        final toggle = find.widgetWithText(SwitchListTile, '空头');
        await tester.scrollUntilVisible(toggle, 160, scrollable: _formScroll());
        await tester.tap(toggle);
        await tester.pumpAndSettle();
      }
      await _enter(tester, 'reference', '20');
      await _save(tester);
      expect(c.investmentFor(account.id), isNull);
      await _saveOpening(tester);

      final portfolio = c.investmentFor(account.id)!;
      expect(portfolio.openingHoldings.single.cost, sample.totalCost);
      expect(portfolio.openingHoldings.single.quantity, sample.quantity);
      expect(portfolio.openingHoldings.single.short, sample.short);
      expect(portfolio.openingCash, '100');
      expect(portfolio.events, isEmpty);
      expect(c.accountBalance(account), 100);
      expect(
        c.investmentProjection(account.id)!.positions.single.cost?.toString(),
        sample.totalCost,
      );
      // 旧 JSON 仍表示总成本，重新读取时不能把总成本再乘一次数量。
      final restored = InvestmentPortfolio.fromJson(portfolio.toJson());
      expect(restored.openingHoldings.single.cost, sample.totalCost);
      final reloaded = await makeController(store);
      addTearDown(reloaded.dispose);
      expect(
        reloaded.investmentFor(account.id)!.openingHoldings.single.cost,
        sample.totalCost,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('负单位成本在舍入为零之前拒绝，失败后保留草稿', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await _startOpening(tester, c, account.id);
    await _enter(tester, 'symbol', 'AVGO');
    await _enter(tester, 'name', '博通');
    await _enter(tester, 'quantity', '1');
    await _enter(tester, 'cost', '-0.00000001');
    await _enter(tester, 'reference', '20');
    await _save(tester);
    expect(c.investmentFor(account.id), isNull);
    expect(find.textContaining('未保存：'), findsOneWidget);
    final cost = find.byKey(const ValueKey('stock-cost'));
    await tester.scrollUntilVisible(cost, -220, scrollable: _formScroll());
    expect(tester.widget<TextField>(cost).controller!.text, '-0.00000001');
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有交易编辑仍按成交单价往返，旧期初总成本保持原值', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await c.enableInvestment(
      accountId: account.id,
      openingCash: '100',
      openedAt: DateTime(2026, 10, 1),
      securities: [avgoFixture],
      openingHoldings: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '3',
          cost: '100.01',
        ),
      ],
      manualPrices: {avgoFixture.id: '30'},
    );
    final event = stockEventFixture(
      'existing-buy',
      StockEventKind.buy,
      '1.25',
      '4.56789',
    );
    await c.saveStockEvent(
      accountId: account.id,
      security: avgoFixture,
      event: event,
      referencePrice: '30',
    );
    await _openEditor(
      tester,
      c,
      StockEditorPage(accountId: account.id, event: event),
    );
    expect(find.byKey(const ValueKey('stock-cost')), findsNothing);
    await _save(tester);
    final portfolio = c.investmentFor(account.id)!;
    expect(portfolio.events.single.toJson(), event.toJson());
    expect(portfolio.openingHoldings.single.cost, '100.01');
    expect(tester.takeException(), isNull);
  });
}
