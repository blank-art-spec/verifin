import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/chart_painters.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/investments/fund_reference_history.dart';
import 'package:verifin/app/investments/investment_decimal.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/investment_widgets.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/quote_format.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/investment_history_page.dart';
import 'package:verifin/pages/fund_reference_history_section.dart';
import 'package:verifin/pages/market_quotes_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 本文件只使用本地夹具；基金身份与股票身份明确分离，不向官网发送测试交易。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
const _goog = StockSecurity(
  symbol: 'GOOG',
  name: '谷歌测试股票',
  market: StockMarket.us,
  currencyCode: 'USD',
);
const _source = 'CMS Asset Management (HK)';
final _navDate = DateTime.utc(2026, 10, 27);

/// 复用现有请求计数夹具，只接受指定基金，绝不访问真实官网。
class _FundResearchAdapter extends FixtureQuoteAdapter {
  /// [fetchedAt] 固定本次抓取时刻，便于区分只有日精度的净值日期和精确抓取时间。
  _FundResearchAdapter(this.fetchedAt) : super((_) async => const []);

  final DateTime fetchedAt;
  bool offline = false;

  /// 保持未正式批准的研究来源，验证显式研究许可及冷启动门禁确实生效。
  @override
  QuoteSourceCapability get capability => const QuoteSourceCapability(
    _source,
    approved: false,
    researchOnly: true,
    reviewNote: '基金刷新链路的本地离线夹具，不访问官网',
  );

  /// [request] 只允许指定 ISIN、香港、美元及基金品种；同账户 GOOG 不会误发给基金源。
  @override
  bool supports(MarketQuoteRequest request) =>
      request.securityId == _fund.id &&
      request.fund &&
      !request.option &&
      request.market == StockMarket.hk &&
      request.currency == 'USD';

  /// 捕获公开请求并返回精确文本；[requests] 不应包含账户、数量、成本或其他证券。
  /// [offline] 为 true 时模拟有限失败，调用方仍须保留手填后备价和账目事实。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
    this.requests++;
    lastRequests = requests;
    if (offline) throw StateError('本地模拟基金来源离线');
    return [
      MarketQuote(
        securityId: _fund.id,
        source: _source,
        currency: 'USD',
        unit: QuotePriceUnit.fundUnit,
        fetchedAt: fetchedAt,
        last: '109.8150',
        lastAt: _navDate,
        dateOnly: true,
        // 前一点为本地确定性夹具，不宣称是真实官网历史；只验证缓存完整性与账务隔离。
        navHistory: FundNavHistory([
          FundNavPoint(date: DateTime.utc(2026, 10, 26), price: '109.8000'),
          FundNavPoint(date: _navDate, price: '109.8150'),
        ]),
      ),
    ];
  }
}

/// 构造真实 Controller、内存仓储及股票/基金共存账户；[adapter] 仅提供离线报价。
/// 期初现金 8499，基金买入十份花费 1000 后现金为 7499；GOOG 期初十股成本 1500。
/// 返回 store/repository 供同设备冷启动检查，调用方负责释放控制器，不修改共享测试脚手架。
Future<
  ({
    VeriFinController controller,
    Account account,
    LocalKeyValueStore store,
    InMemoryLedgerRepository repository,
  })
>
_fundController(_FundResearchAdapter adapter) async {
  final store = LocalKeyValueStore()..write('verifin.locale.v1', 'zh');
  final repository = InMemoryLedgerRepository();
  final controller = await VeriFinController.create(
    store,
    repository: repository,
    marketQuoteClient: MarketQuoteClient(
      adapters: [adapter],
      allowResearchSources: true,
    ),
  );
  final account = investmentAccountFixture(id: 'cms-refresh-usd');
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '8499',
      openedAt: DateTime(2026, 10, 1),
      securities: const [_goog, _fund],
      openingHoldings: [
        StockHolding(
          securityId: _goog.id,
          short: false,
          quantity: '10',
          cost: '1500',
        ),
      ],
      manualPrices: {_goog.id: '150', _fund.id: '100'},
    ),
    isTrue,
  );
  expect(
    await controller.saveStockEvent(
      accountId: account.id,
      security: _fund,
      event: StockEvent(
        id: 'cms-local-fund-buy',
        securityId: _fund.id,
        kind: StockEventKind.buy,
        occurredAt: DateTime(2026, 10, 2, 10),
        sequence: 1,
        quantity: '10',
        price: '100',
        note: '本地基金买入夹具，不是真实成交',
      ),
      referencePrice: '100',
    ),
    isTrue,
  );
  return (
    controller: controller,
    account: account,
    store: store,
    repository: repository,
  );
}

/// 用户显式开启联网并手动取一次本地报价，再单独选择将指定基金用于参考估值。
/// [controller]/[account] 为真实账户链路；股票没有合格来源，继续使用其独立手填价。
Future<void> _adoptFundQuote(
  VeriFinController controller,
  Account account,
) async {
  final sync = controller.investmentQuoteSync;
  expect(await sync.configure(enabled: true, automatic: false), isTrue);
  final portfolio = controller.investmentFor(account.id)!;
  sync.setVisible(portfolio);
  expect(
    await sync.refresh(
      portfolio,
      isCurrent: () =>
          identical(controller.investmentFor(account.id), portfolio),
    ),
    isTrue,
  );
  expect(
    await controller.setInvestmentMarketPrice(account.id, _fund.id, true),
    isTrue,
  );
}

/// 挂载正式 [page] 并保留真实本地化、主题及轻提示；不创建单独的演示界面。
/// [tester] 固定手机尺寸，销毁页面早于控制器释放，避免残留监听或自动计时。
Future<void> _pumpFundPage(
  WidgetTester tester,
  VeriFinController controller,
  Widget page,
) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: buildVeriFinTheme(Brightness.light),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

/// 把 [target] 滚入正式页面的纵向视口，覆盖真实懒加载而不猜测卡片固定位置。
/// [delta] 为正时找下方内容，为负时找上方内容；从交易表单返回后顶部标题可能已被回收。
Future<void> _reveal(
  WidgetTester tester,
  Finder target, {
  double delta = 220,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: firstVerticalScrollable(),
    maxScrolls: 50,
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

/// 构造纯展示观察点；[day] 为十月合法日号，[missing] 明确模拟其他证券缺少历史价。
/// 本地平价十份和真实现金保持一致，不把未知账户金额伪造为零，亦非官网历史数据。
FundReferenceDay _displayDay(int day, {bool missing = false}) =>
    FundReferenceDay(
      date: DateTime.utc(2026, 10, day),
      nav: InvestmentDecimal.parse('100'),
      quantity: InvestmentDecimal.parse('10'),
      marketValue: InvestmentDecimal.parse('1000'),
      dailyProfit: day == 1 ? null : InvestmentDecimal.zero,
      cumulativeProfit: InvestmentDecimal.zero,
      cash: 7499,
      accountAssets: missing ? null : 8499,
      accountLiabilities: missing ? null : 0,
      accountNetValue: missing ? null : 8499,
      missingSecurityIds: missing ? {_goog.id} : {},
    );

/// 验证基金从研究来源进入既有账务、快照和页面链路；全部来源响应均为内存夹具。
void main() {
  useTestDatabases();

  test('基金刷新只改参考估值，手填离线与冷启动门禁均保留账目', () async {
    final adapter = _FundResearchAdapter(DateTime.now().toUtc());
    final ready = await _fundController(adapter);
    final controller = ready.controller, account = ready.account;
    var disposed = false;
    addTearDown(() {
      if (!disposed) controller.dispose();
    });
    final original = controller.investmentFor(account.id)!;
    final originalEvents = original.events
        .map((event) => event.toJson())
        .toList();
    expect(_fund.id, 'hk:fund:HK0001039582');
    expect(original.securities.where((s) => s.isFund).single.id, _fund.id);
    expect(original.securities.where((s) => s.isStock).single.id, _goog.id);
    expect(controller.accountBalance(account), 7499);
    expect(controller.accountAssetValue(account), 9999);
    expect(original.valuationSnapshots, isEmpty);
    expect(controller.investmentQuoteSync.state.value.enabled, isFalse);
    expect(adapter.requests, 0);

    await _adoptFundQuote(controller, account);
    var portfolio = controller.investmentFor(account.id)!;
    final quote = controller.investmentQuoteSync.quotesFor(
      portfolio,
    )[_fund.id]!;
    expect(adapter.capability.approved, isFalse);
    expect(adapter.capability.researchOnly, isTrue);
    expect(adapter.requests, 1);
    expect(adapter.lastRequests.map((request) => request.securityId), [
      _fund.id,
    ]);
    expect(quote.last, '109.8150');
    expect(quote.unit, QuotePriceUnit.fundUnit);
    expect(quote.dateOnly, isTrue);
    expect(quote.lastAt, _navDate);
    expect(quote.navHistory!.points, hasLength(2));
    expect(quote.navHistory!.points.last.price, '109.8150');
    expect(quote.navHistory!.points.last.date, _navDate);
    final cachedQuote = MarketQuote.fromJson(quote.toJson());
    expect(cachedQuote.navHistory!.points.first.price, '109.8000');
    expect(cachedQuote.navHistory!.points.last.date, _navDate);
    expect(
      controller.accountAssetValue(account) - 7499 - 1500,
      closeTo(1098.15, 0.000001),
    );
    expect(controller.accountBalance(account), 7499);
    expect(portfolio.manualPrices[_fund.id], '100');
    expect(portfolio.manualPrices[_goog.id], '150');
    expect(
      portfolio.events.map((event) => event.toJson()).toList(),
      originalEvents,
    );
    expect(portfolio.valuationSnapshots, isEmpty);
    expect(controller.entries, isEmpty);

    // 只有用户主动保存才新增历史依据，来源的日精度须经过 JSON 映射继续保留。
    expect(await controller.captureInvestmentValuation(account.id), isTrue);
    portfolio = controller.investmentFor(account.id)!;
    final fact = portfolio.valuationSnapshots.single.prices[_fund.id]!;
    expect(fact.dateOnly, isTrue);
    expect(fact.quotedAt, _navDate);
    expect(fact.manual, isFalse);
    expect(fact.source, _source);
    expect(double.parse(fact.price), 109.815);
    final restored = InvestmentPortfolio.fromJson(portfolio.toJson());
    expect(
      restored.valuationSnapshots.single.prices[_fund.id]!.dateOnly,
      isTrue,
    );
    expect(
      restored.valuationSnapshots.single.prices[_fund.id]!.quotedAt,
      _navDate,
    );

    expect(
      await controller.setInvestmentMarketPrice(account.id, _fund.id, false),
      isTrue,
    );
    expect(controller.accountAssetValue(account), 9999);
    expect(controller.investmentFor(account.id)!.manualPrices[_fund.id], '100');

    // 无合格缓存时的断网必须回退手填；已有合格缓存的保留语义由同步器专项覆盖。
    await controller.investmentQuoteSync.clearCache();
    expect(
      await controller.setInvestmentMarketPrice(account.id, _fund.id, true),
      isTrue,
    );
    adapter.offline = true;
    portfolio = controller.investmentFor(account.id)!;
    controller.investmentQuoteSync.setVisible(portfolio);
    expect(
      await controller.investmentQuoteSync.refresh(
        portfolio,
        isCurrent: () =>
            identical(controller.investmentFor(account.id), portfolio),
      ),
      isFalse,
    );
    expect(
      controller.investmentQuoteSync.state.value.status,
      QuoteSyncStatus.failed,
    );
    expect(controller.accountAssetValue(account), 9999);
    expect(controller.accountBalance(account), 7499);
    expect(
      controller
          .investmentFor(account.id)!
          .events
          .map((event) => event.toJson())
          .toList(),
      originalEvents,
    );
    expect(
      controller.investmentFor(account.id)!.valuationSnapshots,
      hasLength(1),
    );

    // 恢复一次合格缓存后，以相同设备偏好/仓储冷启动，但撤销构建中的研究许可。
    adapter.offline = false;
    expect(
      await controller.investmentQuoteSync.refresh(
        portfolio,
        isCurrent: () =>
            identical(controller.investmentFor(account.id), portfolio),
      ),
      isTrue,
    );
    expect(controller.accountAssetValue(account), closeTo(10097.15, 0.000001));
    final requestsBeforeRestart = adapter.requests;
    await controller.waitForPendingWrites();
    controller.dispose();
    disposed = true;
    final formal = await VeriFinController.create(
      ready.store,
      repository: ready.repository,
      marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
    );
    addTearDown(formal.dispose);
    final reloaded = formal.investmentFor(account.id)!;
    formal.investmentQuoteSync.setVisible(reloaded);
    expect(formal.investmentQuoteSync.state.value.enabled, isFalse);
    expect(formal.investmentQuoteSync.quotesFor(reloaded), isEmpty);
    expect(
      await formal.investmentQuoteSync.configure(
        enabled: true,
        automatic: true,
      ),
      isFalse,
    );
    expect(
      await formal.investmentQuoteSync.refresh(reloaded, isCurrent: () => true),
      isFalse,
    );
    expect(adapter.requests, requestsBeforeRestart);
    expect(formal.accountBalance(formal.accounts.single), 7499);
    expect(formal.accountAssetValue(formal.accounts.single), 9999);
    expect(
      reloaded.securities.singleWhere((s) => s.id == _fund.id).type,
      InvestmentSecurityType.fund,
    );
    expect(
      reloaded.valuationSnapshots.single.prices[_fund.id]!.dateOnly,
      isTrue,
    );
    expect(
      reloaded.events.map((event) => event.toJson()).toList(),
      originalEvents,
    );
  });

  testWidgets('正式持仓显示基金份额，净值日期不伪造时刻而抓取时间保留时分秒', (tester) async {
    final adapter = _FundResearchAdapter(DateTime.now().toUtc());
    final ready = await _fundController(adapter);
    final controller = ready.controller, account = ready.account;
    addTearDown(controller.dispose);
    await _adoptFundQuote(controller, account);
    await _pumpFundPage(
      tester,
      controller,
      InvestmentPage(accountId: account.id),
    );
    final details = find.byType(InvestmentQuoteDetails);
    await _reveal(tester, details);
    final l = AppLocalizations.of(tester.element(details));
    expect(find.text(l.investFundQuantity), findsOneWidget);
    expect(find.text(l.investFundMarketHK), findsOneWidget);
    final information = tester.widget<InvestmentQuoteDetails>(details);
    expect(information.dateOnly, isTrue);
    expect(information.quoteTime, contains('2026'));
    expect(information.quoteTime, isNot(matches(RegExp(r'\d{1,2}:\d{2}'))));

    await _pumpFundPage(
      tester,
      controller,
      MarketQuotesPage(accountId: account.id),
    );
    await _reveal(tester, find.text(_fund.symbol));
    final card = find
        .ancestor(of: find.text(_fund.symbol), matching: find.byType(VeriCard))
        .first;
    final navDate = find.descendant(
      of: card,
      matching: find.textContaining('${l.marketNavDate}:'),
    );
    final fetched = find.descendant(
      of: card,
      matching: find.textContaining('${l.investFetchedAt}:'),
    );
    await _reveal(tester, fetched);
    expect(navDate, findsOneWidget);
    final navText = tester.widget<Text>(navDate).data!;
    expect(navText, contains('2026'));
    expect(navText, isNot(matches(RegExp(r'\d{1,2}:\d{2}'))));
    final context = tester.element(fetched);
    expect(
      tester.widget<Text>(fetched).data,
      contains(
        formatQuoteTime(context, adapter.fetchedAt, includeSeconds: true),
      ),
    );
    expect(
      tester.widget<Text>(fetched).data,
      matches(RegExp(r'\d{1,2}:\d{2}:\d{2}')),
    );
    expect(controller.investmentFor(account.id)!.valuationSnapshots, isEmpty);
    expect(controller.accountBalance(account), 7499);
    expect(tester.takeException(), isNull);
  });

  testWidgets('基金全部卖出保留净值采用与历史，明确改后备价才退出采用', (tester) async {
    final adapter = _FundResearchAdapter(DateTime.now().toUtc());
    final ready = await _fundController(adapter);
    final controller = ready.controller, account = ready.account;
    addTearDown(controller.dispose);
    await _adoptFundQuote(controller, account);
    await _pumpFundPage(
      tester,
      controller,
      InvestmentPage(accountId: account.id),
    );
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
    await _reveal(tester, find.text(l.investFundNewTrade));
    await tester.tap(find.text(l.investFundNewTrade));
    await tester.pumpAndSettle();
    expect(find.byType(StockEditorPage), findsOneWidget);
    expect(find.text(l.investFundQuantity), findsOneWidget);
    expect(find.text(l.investFundMarketHK), findsOneWidget);
    await tester.tap(find.text(l.investBuy));
    await tester.pumpAndSettle();
    expect(find.text(l.investShort), findsNothing);
    expect(find.text(l.investCover), findsNothing);
    expect(find.text(l.investSplit), findsNothing);
    expect(find.text(l.investFundDistribution), findsOneWidget);
    await tester.tap(find.text(l.investSell));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stock-quantity')), '10');
    await tester.enterText(find.byKey(const ValueKey('stock-price')), '100');
    await tester.enterText(find.byKey(const ValueKey('stock-fee')), '0');
    await tester.enterText(
      find.byKey(const ValueKey('stock-reference')),
      '100.0000',
    );
    final save = find.widgetWithText(FilledButton, l.commonSave);
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byType(StockEditorPage), findsNothing);
    final portfolio = controller.investmentFor(account.id)!;
    expect(portfolio.events, hasLength(2));
    expect(portfolio.events.last.kind, StockEventKind.sell);
    expect(portfolio.events.last.securityId, _fund.id);
    expect(
      portfolio.securities.singleWhere((s) => s.id == _fund.id).type,
      InvestmentSecurityType.fund,
    );
    expect(
      portfolio.securities.any((s) => s.id == 'hk:stock:HK0001039582'),
      isFalse,
    );
    expect(
      portfolio.securities.singleWhere((s) => s.id == _goog.id).isStock,
      isTrue,
    );
    expect(portfolio.marketPriceIds, contains(_fund.id));
    expect(portfolio.manualPrices[_fund.id], '100');
    expect(controller.accountBalance(account), 8499);
    expect(
      controller.fundReferenceHistoryFor(account.id, _fund.id),
      hasLength(2),
    );

    // 清仓后仍从基金专属入口再次买入，不能退回默认股票类型；取消草稿不新增任何账目。
    final rebuy = find.byKey(ValueKey('fund-trade-${_fund.id}'));
    await _reveal(tester, rebuy);
    await tester.tap(rebuy);
    await tester.pumpAndSettle();
    final rebuyEditor = find.byType(StockEditorPage);
    expect(rebuyEditor, findsOneWidget);
    expect(tester.widget<StockEditorPage>(rebuyEditor).securityId, _fund.id);
    expect(find.text(l.investFundQuantity), findsOneWidget);
    expect(find.text(l.investFundMarketHK), findsOneWidget);
    expect(find.text(l.investBuy), findsOneWidget);
    Navigator.of(tester.element(rebuyEditor)).pop();
    await tester.pumpAndSettle();
    expect(
      controller
          .investmentFor(account.id)!
          .events
          .map((event) => event.toJson())
          .toList(),
      portfolio.events.map((event) => event.toJson()).toList(),
    );
    expect(controller.accountBalance(account), 8499);

    // 清仓后持仓卡消失，历史入口仍能展示这份基金的已缓存公开净值与真实账务推演。
    final historyAction = find.byTooltip(l.investHistory);
    await _reveal(tester, historyAction, delta: -220);
    await tester.tap(historyAction);
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentHistoryPage), findsOneWidget);
    expect(find.byType(FundReferenceHistorySection), findsOneWidget);
    expect(find.text(l.fundReferenceHistoryEmpty), findsNothing);
    Navigator.of(tester.element(find.byType(InvestmentHistoryPage))).pop();
    await tester.pumpAndSettle();

    // 从已发生的卖出事件继续编辑，只有明确更改后备价格才按用户选择改为持续手填。
    final soldEvent = find.text('${l.investSell} · ${_fund.symbol}');
    await _reveal(tester, soldEvent);
    await tester.tap(soldEvent);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('stock-reference')),
      '101',
    );
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final manual = controller.investmentFor(account.id)!;
    expect(manual.events, hasLength(2));
    expect(manual.marketPriceIds, isNot(contains(_fund.id)));
    expect(manual.manualPrices[_fund.id], '101');
    expect(controller.fundReferenceHistoryFor(account.id, _fund.id), isEmpty);
    expect(controller.accountBalance(account), 8499);
    expect(controller.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史页自动读取基金缓存，混合账户缺股票历史价不画完整账户曲线', (tester) async {
    final adapter = _FundResearchAdapter(DateTime.now().toUtc());
    final ready = await _fundController(adapter);
    final controller = ready.controller, account = ready.account;
    addTearDown(controller.dispose);
    await _pumpFundPage(
      tester,
      controller,
      InvestmentHistoryPage(accountId: account.id),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(InvestmentHistoryPage)),
    );
    expect(find.byType(FundReferenceHistorySection), findsOneWidget);
    await _reveal(tester, find.text(l.fundReferenceHistoryEmpty));
    expect(adapter.requests, 0);

    await _adoptFundQuote(controller, account);
    await tester.pumpAndSettle();
    final history = controller.fundReferenceHistoryFor(account.id, _fund.id);
    expect(history, hasLength(2));
    expect(history.last.marketValue.toString(), '1098.15');
    expect(history.last.dailyProfit!.toString(), '0.15');
    expect(history.last.accountNetValue, isNull);
    expect(history.last.missingSecurityIds, contains(_goog.id));
    final fundChart = find.byKey(ValueKey('fund_value_chart_${_fund.id}'));
    await _reveal(tester, fundChart);
    expect(
      find.byKey(ValueKey('fund_account_chart_${_fund.id}')),
      findsNothing,
    );
    expect(find.byType(InteractiveTrendChart), findsOneWidget);
    final semantics = tester.ensureSemantics();
    try {
      await tester.tapAt(tester.getCenter(fundChart));
      await tester.pump();
      expect(
        find.descendant(
          of: fundChart,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                (widget.properties.label ?? '').contains('2026'),
          ),
        ),
        findsOneWidget,
      );
    } finally {
      // Flutter 在测试正文结束时即核对语义句柄，须在该检查前释放，而非等待全局清理。
      semantics.dispose();
    }
    await _reveal(tester, find.text(l.fundReferenceMissingPrices));
    expect(find.text(l.fundReferenceMissingSecurities('GOOG')), findsWidgets);
    expect(controller.accountBalance(account), 7499);
    expect(controller.entries, isEmpty);
    expect(controller.investmentFor(account.id)!.valuationSnapshots, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('基金历史明细默认二十日可展开，单点及任何账户缺价均不伪造完整趋势', (tester) async {
    final adapter = _FundResearchAdapter(DateTime.now().toUtc());
    final ready = await _fundController(adapter);
    addTearDown(ready.controller.dispose);
    final days = [for (var day = 1; day <= 22; day++) _displayDay(day)];
    await _pumpFundPage(
      tester,
      ready.controller,
      Scaffold(
        body: ListView(
          children: [
            FundReferenceHistorySection(
              account: ready.account,
              security: _fund,
              points: days,
            ),
          ],
        ),
      ),
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(FundReferenceHistorySection)),
    );
    expect(find.byType(InteractiveTrendChart), findsNWidgets(2));
    final details = find.byKey(ValueKey('fund_reference_details_${_fund.id}'));
    await _reveal(tester, details);
    final context = tester.element(details);
    final firstDate = formatQuoteTime(context, days.first.date, dateOnly: true);
    final firstRecentDate = formatQuoteTime(
      context,
      days[2].date,
      dateOnly: true,
    );
    final innerScroll = find
        .descendant(of: details, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      find.text(firstRecentDate),
      500,
      scrollable: innerScroll,
      maxScrolls: 80,
    );
    expect(find.text(firstDate), findsNothing);
    final expand = find.byKey(ValueKey('fund_reference_expand_${_fund.id}'));
    await _reveal(tester, expand);
    expect(find.text(l.fundReferenceShowAll(22)), findsOneWidget);
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(find.text(l.fundReferenceShowRecent), findsOneWidget);
    await _reveal(tester, details);
    await tester.scrollUntilVisible(
      find.text(firstDate),
      500,
      scrollable: innerScroll,
      maxScrolls: 80,
    );
    expect(find.text(firstDate), findsOneWidget);

    await _pumpFundPage(
      tester,
      ready.controller,
      Scaffold(
        body: ListView(
          children: [
            FundReferenceHistorySection(
              account: ready.account,
              security: _fund,
              points: [days.last],
            ),
          ],
        ),
      ),
    );
    expect(find.byType(InteractiveTrendChart), findsNothing);
    expect(find.text(l.fundReferenceSinglePoint), findsOneWidget);

    await _pumpFundPage(
      tester,
      ready.controller,
      Scaffold(
        body: ListView(
          children: [
            FundReferenceHistorySection(
              account: ready.account,
              security: _fund,
              points: [
                _displayDay(1),
                _displayDay(2, missing: true),
                _displayDay(3),
              ],
            ),
          ],
        ),
      ),
    );
    expect(find.byType(InteractiveTrendChart), findsOneWidget);
    expect(
      find.byKey(ValueKey('fund_account_chart_${_fund.id}')),
      findsNothing,
    );
    expect(find.text(l.fundReferenceMissingPrices), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('360dp英文大字号基金历史可阅读并点按完整本地化气泡', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final account = investmentAccountFixture(id: 'cms-narrow-display');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildVeriFinTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FundReferenceHistorySection(
                account: account,
                security: _fund,
                points: [_displayDay(1), _displayDay(2), _displayDay(3)],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final section = find.byType(FundReferenceHistorySection);
    final l = AppLocalizations.of(tester.element(section));
    expect(find.text(l.fundReferenceDailyProfit), findsWidgets);
    final chart = find.byKey(ValueKey('fund_value_chart_${_fund.id}'));
    await _reveal(tester, chart);
    final semantics = tester.ensureSemantics();
    try {
      await tester.tapAt(tester.getCenter(chart));
      await tester.pump();
      expect(
        find.descendant(
          of: chart,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                (widget.properties.label ?? '').contains(
                  l.fundReferenceDailyProfit,
                ),
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
