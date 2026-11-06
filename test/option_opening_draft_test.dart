import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_opening_draft.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/option_editor_page.dart';

import 'support/investment_fixture.dart';
import 'support/option_editor_harness.dart';
import 'support/test_harness.dart';

Finder _scroll() => find
    .descendant(
      of: find.byType(OptionEditorPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 打开真实路由并收集返回的父页面草稿；Controller 始终尚未启用证券。
Future<void> _open(
  WidgetTester tester,
  VeriFinController controller,
  InvestmentOpeningHolding holding,
  ValueChanged<InvestmentOpeningHolding?> onResult, {
  double scale = 1,
}) async {
  final portfolio = composeInvestmentOpening(
    base: optionPortfolioFixture(holding.security),
    holdings: [holding],
  );
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<InvestmentOpeningHolding>(
                      MaterialPageRoute(
                        builder: (context) => MediaQuery(
                          data: MediaQuery.of(
                            context,
                          ).copyWith(textScaler: TextScaler.linear(scale)),
                          child: OptionEditorPage(
                            accountId: portfolio.accountId,
                            openingPortfolio: portfolio,
                            openingHolding: holding,
                          ),
                        ),
                      ),
                    );
                onResult(result);
              },
              child: const Text('打开期初期权'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开期初期权'));
  await tester.pumpAndSettle();
}

/// 展开并填写真实期初字段；[value] 为本用例要验证的原始输入文本。
Future<void> _enter(WidgetTester tester, String field, String value) async {
  final input = await revealOptionEditorField(tester, field);
  await tester.enterText(input, value);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final save = find.widgetWithText(FilledButton, '保存');
  await tester.scrollUntilVisible(save, 240, scrollable: _scroll());
  await tester.pumpAndSettle();
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  expect(save.hitTestable(), findsOneWidget);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

InvestmentOpeningHolding _holding({bool short = false, String? cost = '175'}) {
  final security = optionFixture(multiplier: '10');
  return InvestmentOpeningHolding(
    security: security,
    holding: StockHolding(
      securityId: security.id,
      quantity: '2',
      cost: cost,
      short: short,
    ),
    referencePrice: '3',
    underlying: avgoFixture,
    frozenMargin: '500',
  );
}

void main() {
  useTestDatabases();

  List<InvestmentOpeningHolding> excessiveMarginHoldings() => [
    for (final right in OptionRight.values)
      InvestmentOpeningHolding(
        security: optionFixture(right: right),
        holding: StockHolding(
          securityId: optionFixture(right: right).id,
          quantity: '1',
          cost: '100',
          short: true,
        ),
        referencePrice: '2',
        underlying: avgoFixture,
        frozenMargin: '600000000000',
      ),
  ];

  test('期初组装拒绝各项合法但冻结合计超出显示金额边界', () {
    final holdings = excessiveMarginHoldings();
    expect(
      () => composeInvestmentOpening(
        base: optionPortfolioFixture(holdings.first.security),
        holdings: holdings,
      ),
      throwsFormatException,
    );
  });

  test('原子启用拒绝冻结合计溢出，内存与冷读均不留下期初', () async {
    final store = LocalKeyValueStore();
    final c = await makeController(store), account = investmentAccountFixture();
    addTearDown(c.dispose);
    c.addAccount(account);
    await c.waitForPendingWrites();
    final holdings = excessiveMarginHoldings();
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: [avgoFixture, ...holdings.map((h) => h.security)],
        openingHoldings: holdings.map((h) => h.holding).toList(),
        manualPrices: {
          for (final item in holdings) item.security.id: item.referencePrice,
        },
        openingOptionMargins: {
          for (final item in holdings) item.security.id: item.frozenMargin!,
        },
      ),
      isFalse,
    );
    expect(c.investmentFor(account.id), isNull);
    expect(c.accountBalance(account), 10000);
    final reloaded = await makeController(store);
    addTearDown(reloaded.dispose);
    expect(reloaded.investmentFor(account.id), isNull);
    expect(reloaded.accountBalance(account), 10000);
  });

  for (final short in [false, true]) {
    testWidgets('期初期权${short ? '空头' : '多头'}未修改也可返回，总成本不乘张数或乘数', (tester) async {
      final c = await makeController(), account = investmentAccountFixture();
      addTearDown(c.dispose);
      c.addAccount(account);
      await c.waitForPendingWrites();
      await tester.binding.setSurfaceSize(const Size(360, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      InvestmentOpeningHolding? result;
      await _open(
        tester,
        c,
        _holding(short: short),
        (v) => result = v,
        scale: 1.8,
      );
      expect(find.byKey(const ValueKey('option-price')), findsNothing);
      expect(find.byKey(const ValueKey('option-fee')), findsNothing);
      expect(find.text('预览结算后现金与持仓'), findsNothing);
      await _save(tester);
      expect(result, isNotNull);
      expect(result!.holding.quantity, '2');
      expect(result!.holding.cost, '175');
      expect(result!.holding.short, short);
      expect(result!.frozenMargin, '500');
      final p = composeInvestmentOpening(
        base: optionPortfolioFixture(result!.security),
        holdings: [result!],
      );
      final projection = projectStocks(p);
      expect(
        valueStocks(p, projection).marketValue!.toString(),
        short ? '-60' : '60',
      );
      expect(projection.frozenMargin.toString(), '500');
      expect(projection.cashMovements.values.single.toString(), '0');
      expect(c.investmentFor(account.id), isNull);
      expect(c.accountBalance(account), 10000);
      expect(tester.takeException(), isNull);
    });
  }

  for (final invalid in [
    (field: 'quantity', value: '1.5'),
    (field: 'cost', value: '-0.00000001'),
    (field: 'cost', value: '999999999999.999'),
    (field: 'margin', value: '0.001'),
  ]) {
    testWidgets('期初期权拒绝${invalid.field}=${invalid.value}并保留输入', (tester) async {
      final c = await makeController(), account = investmentAccountFixture();
      addTearDown(c.dispose);
      c.addAccount(account);
      await c.waitForPendingWrites();
      var returned = false;
      await _open(tester, c, _holding(), (_) => returned = true);
      await _enter(tester, invalid.field, invalid.value);
      await _save(tester);
      expect(returned, isFalse);
      expect(find.byType(OptionEditorPage), findsOneWidget);
      final input = find.byKey(ValueKey('option-${invalid.field}'));
      await tester.scrollUntilVisible(input, -240, scrollable: _scroll());
      expect(tester.widget<TextField>(input).controller!.text, invalid.value);
      expect(c.investmentFor(account.id), isNull);
      expect(c.accountBalance(account), 10000);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('期初期权返回确认可保存未知成本草稿，取消及保存都不落库', (tester) async {
    final c = await makeController(), account = investmentAccountFixture();
    addTearDown(c.dispose);
    c.addAccount(account);
    await c.waitForPendingWrites();
    InvestmentOpeningHolding? result;
    await _open(tester, c, _holding(), (v) => result = v);
    await _enter(tester, 'cost', '');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.byType(OptionEditorPage), findsOneWidget);
    expect(c.investmentFor(account.id), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '保存'),
      ),
    );
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.holding.cost, isNull);
    expect(c.investmentFor(account.id), isNull);
    expect(c.accountBalance(account), 10000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换账本后期初期权草稿失效，不返回旧账户资料', (tester) async {
    final c = await makeController(), account = investmentAccountFixture();
    addTearDown(c.dispose);
    c.addAccount(account);
    await c.waitForPendingWrites();
    InvestmentOpeningHolding? result;
    await _open(tester, c, _holding(), (v) => result = v);
    c.addLedgerBook('另一账本');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('option-symbol')), findsNothing);
    expect(find.textContaining('未保存'), findsOneWidget);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
}
