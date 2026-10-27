import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/feedback.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/market_quotes_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/research_quote_fixture.dart';
import 'support/test_harness.dart';

const _tencent = StockSecurity(
  symbol: '00700',
  name: '腾讯研究夹具',
  market: StockMarket.hk,
  currencyCode: 'HKD',
);
const _testOption = StockSecurity(
  symbol: 'TEST-TCH-CALL-20261230-440',
  name: '本地腾讯期权夹具',
  market: StockMarket.hk,
  currencyCode: 'HKD',
  option: OptionContract(
    underlyingId: 'hk:stock:00700',
    expiry: '2026-12-30',
    right: OptionRight.call,
    strike: '440',
    premiumMultiplier: '100',
    settlement: OptionSettlement.physical,
    deliverableShares: '100',
    exerciseCash: '44000',
    specification: '本地虚构规格，仅用于研究页面检查',
    confirmed: true,
  ),
);

/// 创建真实 Controller 与内存仓储，账户包含股票成交和一个本地 TEST 期权。
///
/// [adapter] 只返回内存中的固定股票报价，不联网；[locale] 固定测试偏好语言。
/// 期权仅用于确认不支持的证券仍保持手填，调用方负责 dispose 返回的控制器。
Future<({VeriFinController controller, Account account})> _researchController(
  ResearchFixtureQuoteAdapter adapter,
  Locale locale,
) async {
  final controller = await VeriFinController.create(
    LocalKeyValueStore()..write('verifin.locale.v1', locale.languageCode),
    repository: InMemoryLedgerRepository(),
    marketQuoteClient: MarketQuoteClient(
      adapters: [adapter],
      allowResearchSources: true,
    ),
  );
  final account = investmentAccountFixture(id: 'research-hkd', currency: 'HKD');
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
      securities: const [_tencent, _testOption],
      openingHoldings: [
        StockHolding(
          securityId: _testOption.id,
          short: false,
          quantity: '1',
          cost: '100',
        ),
      ],
      manualPrices: {_tencent.id: '40', _testOption.id: '1'},
    ),
    isTrue,
  );
  expect(
    await controller.saveStockEvent(
      accountId: account.id,
      security: _tencent,
      event: StockEvent(
        id: 'research-stock-buy',
        securityId: _tencent.id,
        kind: StockEventKind.buy,
        occurredAt: DateTime(2026, 10, 2, 10),
        sequence: 1,
        quantity: '100',
        price: '40',
        fee: '1',
        note: '本地固定测试成交，不是真实腾讯价格',
      ),
      referencePrice: '40',
    ),
    isTrue,
  );
  return (controller: controller, account: account);
}

/// 按 [width] 和 [locale] 挂载正式参考行情页，并为失败提示提供根级轻提示 Host。
/// [controller] 由调用方持有；页面销毁、测试尺寸和反馈控制器均在测试结束时恢复。
Future<void> _pumpResearchPage(
  WidgetTester tester,
  VeriFinController controller,
  String accountId, {
  required double width,
  required Locale locale,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final feedback = VeriFeedbackController();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => VeriFeedbackHost(
          controller: feedback,
          bottomMargin: 0,
          child: child ?? const SizedBox.shrink(),
        ),
        home: MarketQuotesPage(accountId: accountId),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

/// 将 [target] 滚入当前页视口，既覆盖懒加载，也避免把横向或其他滚动区当作主列表。
/// [tester] 为本次页面测试控制器；每次滚动后立即检查布局异常。
Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    250,
    scrollable: firstVerticalScrollable(),
    maxScrolls: 50,
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 返回 [security] 所属证券卡里的唯一估值开关，避免误点页面上方的总联网开关。
Finder _valuationSwitch(StockSecurity security) => find.descendant(
  of: find
      .ancestor(of: find.text(security.symbol), matching: find.byType(VeriCard))
      .first,
  matching: find.byType(Switch),
);

/// 注册中英文、393/360 宽度的研究页面行为；固定夹具不会发送任何真实网络请求。
void main() {
  useTestDatabases();
  for (final locale in [const Locale('zh'), const Locale('en')]) {
    for (final width in [393.0, 360.0]) {
      testWidgets('研究来源页面 ${locale.languageCode} $width', (tester) async {
        final time = DateTime.now().toUtc();
        final adapter = ResearchFixtureQuoteAdapter(
          (_) async => [
            MarketQuote(
              securityId: _tencent.id,
              source: researchFixtureSourceId,
              currency: 'HKD',
              unit: QuotePriceUnit.share,
              fetchedAt: time,
              last: '50',
              lastAt: time,
            ),
          ],
        );
        final ready = await _researchController(adapter, locale);
        final controller = ready.controller, account = ready.account;
        addTearDown(controller.dispose);
        final before = controller.investmentFor(account.id)!;
        final originalEvents = before.events
            .map((event) => event.toJson())
            .toList();
        final originalManual = Map<String, String>.from(before.manualPrices);
        expect(controller.accountBalance(account), 5999);
        expect(controller.accountAssetValue(account), 10099);

        await _pumpResearchPage(
          tester,
          controller,
          account.id,
          width: width,
          locale: locale,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(MarketQuotesPage)),
        );
        expect(find.text(l.marketResearchConsent), findsOneWidget);
        expect(find.text(l.marketResearchNote), findsOneWidget);
        expect(adapter.capability.approved, isFalse);
        expect(adapter.requests, 0);
        final enableRow = find.widgetWithText(CompactSwitchRow, l.marketEnable);
        expect(tester.widget<CompactSwitchRow>(enableRow).onChanged, isNotNull);
        await tester.tap(enableRow);
        await tester.pumpAndSettle();
        expect(controller.investmentQuoteSync.state.value.enabled, isTrue);
        expect(adapter.requests, 1);
        expect(adapter.lastRequests.map((request) => request.symbol), [
          '00700',
        ]);
        expect(
          adapter.lastRequests.every((request) => !request.option),
          isTrue,
        );

        await _reveal(tester, find.text(l.marketSourceResearch));
        expect(find.text(l.marketSourceResearch), findsOneWidget);
        expect(find.text(researchFixtureSourceId), findsOneWidget);
        // 来源分组只展示已装配项，不再出现已移除的旧验证来源。
        expect(find.text('Yahoo Finance'), findsNothing);
        expect(find.text('Nasdaq'), findsNothing);
        await _reveal(tester, find.text(_testOption.symbol));
        expect(
          tester.widget<Switch>(_valuationSwitch(_testOption)).onChanged,
          isNull,
        );
        await _reveal(tester, find.text(l.marketOptionUnsupported));
        expect(find.text(l.marketOptionUnsupported), findsOneWidget);
        // 滚到末尾检查旧查询入口已移除，避免仍可跳往不用的第三方来源。
        final list = tester.state<ScrollableState>(firstVerticalScrollable());
        list.position.jumpTo(list.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.text('博通行情验证'), findsNothing);
        expect(find.text('Broadcom quote validation'), findsNothing);
        expect(controller.investmentFor(account.id)!.marketPriceIds, isEmpty);
        expect(controller.accountAssetValue(account), 10099);

        await _reveal(tester, find.text(_tencent.symbol));
        final stockSwitch = _valuationSwitch(_tencent);
        await _reveal(tester, stockSwitch);
        expect(tester.widget<Switch>(stockSwitch).onChanged, isNotNull);
        await tester.tap(stockSwitch);
        await tester.pumpAndSettle();
        final after = controller.investmentFor(account.id)!;
        expect(after.marketPriceIds, {_tencent.id});
        expect(
          controller.investmentQuoteSync.quotesFor(after)[_tencent.id]?.last,
          '50',
        );
        expect(controller.accountAssetValue(account), 11099);
        expect(controller.accountBalance(account), 5999);
        expect(after.manualPrices, originalManual);
        expect(
          after.events.map((event) => event.toJson()).toList(),
          originalEvents,
        );
        expect(controller.entries, isEmpty);
        expect(adapter.requests, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
