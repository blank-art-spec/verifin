import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/pages/investment_history_page.dart';
import 'support/test_harness.dart';
import 'support/investment_fixture.dart';

void main() {
  useTestDatabases();
  testWidgets('窄屏保存真实当前观察点，改现价不改历史，缺汇率明确提示', (tester) async {
    final c = await makeController(), a = investmentAccountFixture();
    addTearDown(c.dispose);
    c.addAccount(a);
    await c.waitForPendingWrites();
    await c.enableInvestment(
      accountId: a.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
      securities: [avgoFixture],
      openingHoldings: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '2',
          cost: '600',
        ),
      ],
      manualPrices: {avgoFixture.id: '330'},
    );
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: InvestmentHistoryPage(accountId: a.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('尚无历史'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture_investment_valuation')));
    await tester.pumpAndSettle();
    expect(c.investmentFor(a.id)!.valuationSnapshots, hasLength(1));
    expect(find.textContaining('10660'), findsWidgets);
    expect(find.textContaining('无法绘制完整趋势'), findsOneWidget);
    await c.setStockReferencePrice(a.id, avgoFixture.id, '500');
    await tester.pumpAndSettle();
    expect(find.textContaining('10660'), findsWidgets);
    expect(find.textContaining('11000'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
