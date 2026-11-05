import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_opening_draft.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

InvestmentPortfolio _base({List<StockHolding> holdings = const []}) =>
    InvestmentPortfolio(
      accountId: 'stock-usd',
      bookId: defaultLedgerBookId,
      currencyCode: 'USD',
      openedAt: DateTime(2026, 11, 1),
      openingCash: '5000',
      securities: [avgoFixture],
      openingHoldings: holdings,
      manualPrices: {avgoFixture.id: '20'},
    );

Finder _scroll() => find
    .descendant(
      of: find.byType(StockEditorPage),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _enter(WidgetTester tester, String field, String text) async {
  final finder = find.byKey(ValueKey('stock-$field'));
  await tester.scrollUntilVisible(finder, 220, scrollable: _scroll());
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, '保存');
  await tester.scrollUntilVisible(button, 220, scrollable: _scroll());
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _open(
  WidgetTester tester,
  VeriFinController c,
  StockEditorPage page,
  ValueChanged<InvestmentOpeningHolding?> onResult,
) async {
  await tester.pumpWidget(
    VeriFinScope(
      controller: c,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<InvestmentOpeningHolding>(
                      MaterialPageRoute(builder: (_) => page),
                    );
                onResult(result);
              },
              child: const Text('添加持仓'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('添加持仓'));
  await tester.pumpAndSettle();
}

void main() {
  useTestDatabases();

  testWidgets('股票单条草稿返回精确成本，不启用账户或重复扣现金', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    final before = c.accountBalance(account);
    InvestmentOpeningHolding? result;
    final base = _base();
    await _open(
      tester,
      c,
      StockEditorPage(accountId: account.id, openingPortfolio: base),
      (value) => result = value,
    );
    expect(find.byKey(const ValueKey('stock-cash')), findsNothing);
    expect(find.byKey(const ValueKey('stock-fee')), findsNothing);
    expect(find.byKey(const ValueKey('stock-note')), findsNothing);
    await _enter(tester, 'symbol', 'GOOG');
    await _enter(tester, 'name', '谷歌');
    await _enter(tester, 'quantity', '2.5');
    await _enter(tester, 'cost', '12.34567891');
    await _enter(tester, 'reference', '20');
    await _save(tester);
    expect(result!.security.symbol, 'GOOG');
    expect(result!.holding.quantity, '2.5');
    expect(result!.holding.cost, '30.86');
    expect(result!.referencePrice, '20');
    expect(base.openingHoldings, isEmpty);
    expect(c.investmentFor(account.id), isNull);
    expect(c.accountBalance(account), before);
    expect(tester.takeException(), isNull);
  });

  for (final sample in [
    (quantity: '1.7', cost: '567.60', average: '333.88'),
    (quantity: '1000000', cost: '123456.78', average: '0.12345678'),
  ]) {
    testWidgets('期初草稿再次编辑预填${sample.average}，改参考价不改变总成本', (tester) async {
      final c = await makeController();
      addTearDown(c.dispose);
      final account = investmentAccountFixture();
      c.addAccount(account);
      await c.waitForPendingWrites();
      final holding = StockHolding(
        securityId: avgoFixture.id,
        short: false,
        quantity: sample.quantity,
        cost: sample.cost,
      );
      final original = InvestmentOpeningHolding(
        security: avgoFixture,
        holding: holding,
        referencePrice: '20',
      );
      InvestmentOpeningHolding? result;
      await _open(
        tester,
        c,
        StockEditorPage(
          accountId: account.id,
          openingPortfolio: _base(holdings: [holding]),
          openingHolding: original,
        ),
        (value) => result = value,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('stock-cost')))
            .controller!
            .text,
        sample.average,
      );
      await _enter(tester, 'reference', '21');
      await _save(tester);
      expect(result!.holding.cost, sample.cost);
      expect(result!.holding.quantity, sample.quantity);
      expect(result!.referencePrice, '21');
      expect(c.investmentFor(account.id), isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('编辑期初参考价保留原始总成本，不反乘舍入后的每股均价', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    final holding = StockHolding(
      securityId: avgoFixture.id,
      short: false,
      quantity: '123456789.12345678',
      cost: '1',
    );
    final original = InvestmentOpeningHolding(
      security: avgoFixture,
      holding: holding,
      referencePrice: '20',
    );
    InvestmentOpeningHolding? result;
    await _open(
      tester,
      c,
      StockEditorPage(
        accountId: account.id,
        openingPortfolio: _base(holdings: [holding]),
        openingHolding: original,
      ),
      (value) => result = value,
    );
    await _enter(tester, 'reference', '21');
    await _save(tester);
    expect(result!.holding.cost, '1');
    expect(result!.holding.quantity, holding.quantity);
    expect(result!.referencePrice, '21');
    expect(c.investmentFor(account.id), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同证券同方向拒绝重复，切为空头后保留父草稿的多头', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    final existing = StockHolding(
      securityId: avgoFixture.id,
      short: false,
      quantity: '10',
      cost: '100',
    );
    final base = _base(holdings: [existing]);
    InvestmentOpeningHolding? result;
    await _open(
      tester,
      c,
      StockEditorPage(accountId: account.id, openingPortfolio: base),
      (value) => result = value,
    );
    await _enter(tester, 'symbol', 'AVGO');
    await _enter(tester, 'name', '博通');
    await _enter(tester, 'quantity', '2');
    await _enter(tester, 'reference', '20');
    await _save(tester);
    expect(result, isNull);
    expect(find.textContaining('未保存：'), findsOneWidget);
    final toggle = find.widgetWithText(SwitchListTile, '空头');
    await tester.scrollUntilVisible(toggle, -180, scrollable: _scroll());
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await _save(tester);
    expect(result!.holding.short, isTrue);
    expect(result!.holding.cost, isNull);
    expect(base.openingHoldings.single, same(existing));
    expect(base.openingHoldings.single.quantity, '10');
    expect(c.investmentFor(account.id), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('基金草稿经离页保存返回基金持仓，不写入账户', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    InvestmentOpeningHolding? result;
    var returned = false;
    await _open(
      tester,
      c,
      StockEditorPage(
        accountId: account.id,
        openingPortfolio: _base(),
        openingSecurityType: InvestmentSecurityType.fund,
      ),
      (value) {
        returned = true;
        result = value;
      },
    );
    await _enter(tester, 'symbol', 'FUND');
    await _enter(tester, 'name', '基金');
    await _enter(tester, 'quantity', '3.2');
    await _enter(tester, 'cost', '0');
    await _enter(tester, 'reference', '1.2');
    expect(find.widgetWithText(SwitchListTile, '空头'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '保存'),
      ),
    );
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result!.security.isFund, isTrue);
    expect(result!.holding.quantity, '3.2');
    expect(result!.holding.cost, '0');
    expect(c.investmentFor(account.id), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无效参考价保留草稿，放弃返回不落库', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    InvestmentOpeningHolding? result;
    var returned = false;
    await _open(
      tester,
      c,
      StockEditorPage(accountId: account.id, openingPortfolio: _base()),
      (value) {
        returned = true;
        result = value;
      },
    );
    await _enter(tester, 'symbol', 'GOOG');
    await _enter(tester, 'name', '谷歌');
    await _enter(tester, 'quantity', '3');
    await _enter(tester, 'reference', '-1');
    await _save(tester);
    expect(returned, isFalse);
    expect(find.textContaining('未保存：'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-reference')))
          .controller!
          .text,
      '-1',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('不保存'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
    expect(c.investmentFor(account.id), isNull);
    expect(tester.takeException(), isNull);
  });
}
