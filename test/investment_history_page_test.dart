import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/chart_painters.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/investment_history_page.dart';
import 'support/test_harness.dart';
import 'support/investment_fixture.dart';

void main() {
  useTestDatabases();
  for (final width in [360.0, 393.0]) {
    testWidgets('历史估值 $width 宽单点不画虚构趋势，两点使用简短本地化坐标', (tester) async {
      final c = await makeController(), a = investmentAccountFixture();
      addTearDown(c.dispose);
      c.addAccount(a);
      await c.waitForPendingWrites();
      expect(
        await c.saveExchangeRateDraft(
          currencyCode: 'USD',
          effectiveDate: DateTime(2026, 10, 1),
          rateToBase: 7,
        ),
        isTrue,
      );
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
      expect(await c.captureInvestmentValuation(a.id), isTrue);
      await tester.binding.setSurfaceSize(Size(width, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        VeriFinScope(
          controller: c,
          child: zhMaterialApp(home: InvestmentHistoryPage(accountId: a.id)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveTrendChart), findsNothing);
      expect(find.textContaining('至少保存 2 个有效观察点'), findsOneWidget);
      await c.setStockReferencePrice(a.id, avgoFixture.id, '350');
      expect(await c.captureInvestmentValuation(a.id), isTrue);
      await tester.pumpAndSettle();
      final chart = tester.widget<InteractiveTrendChart>(
        find.byType(InteractiveTrendChart),
      );
      expect(chart.values, [74620, 74900]);
      expect(chart.xLabels.every((label) => label.length < 12), isTrue);
      expect(find.textContaining('至少保存 2 个有效观察点'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
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
    final l = AppLocalizations.of(
      tester.element(find.byType(InvestmentHistoryPage)),
    );
    // 空态描述区分主动保存依据与基金自动参考历史，断言真实本地化文案而非旧片段。
    expect(find.text(l.investHistoryEmpty), findsOneWidget);
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
