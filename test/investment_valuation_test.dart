import 'dart:ui' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/ai/ai_query_tool.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/home_metrics.dart';
import 'package:verifin/app/widget_config.dart';
import 'package:verifin/app/widget_presentation.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'support/investment_fixture.dart';

void main() {
  final account = investmentAccountFixture(), at = DateTime(2026, 10, 24, 12);
  final call = optionFixture(), put = optionFixture(right: OptionRight.put);
  InvestmentPortfolio combined() => InvestmentPortfolio(
    accountId: account.id,
    bookId: account.bookId,
    currencyCode: 'USD',
    openedAt: DateTime(2026, 10, 1),
    openingCash: '10000',
    securities: [avgoFixture, call, put],
    events: [
      stockEventFixture('stock', StockEventKind.buy, '10', '50'),
      optionEventFixture(
        call,
        StockEventKind.optionBuyOpen,
        id: 'call',
        price: '2',
        sequence: 2,
      ),
      optionEventFixture(
        put,
        StockEventKind.optionSellOpen,
        id: 'put',
        price: '3',
        sequence: 3,
        margin: '1000',
      ),
    ],
    manualPrices: {avgoFixture.id: '55', call.id: '4', put.id: '5'},
  );
  ExchangeRate rate(String currency, double value) => ExchangeRate(
    id: currency,
    bookId: account.bookId,
    baseCurrencyCode: 'CNY',
    currencyCode: currency,
    effectiveDate: DateTime(2026, 10, 1),
    rateToBase: value,
    source: ExchangeRateSource.manual,
    createdAt: at,
    updatedAt: at,
  );
  InvestmentPortfolio recorded(InvestmentPortfolio p) => p.copyWith(
    valuationSnapshots: [
      InvestmentValuationSnapshot(
        capturedAt: at,
        revision: investmentRevision(p, [], [], at),
        baseCurrencyCode: 'CNY',
        rateToBase: 7,
        rateDate: DateTime(2026, 10, 1),
        prices: p.manualPrices.map(
          (id, price) =>
              MapEntry(id, InvestmentPriceFact(price: price, quotedAt: at)),
        ),
      ),
    ],
  );
  ConvertedAccountBalances value(
    InvestmentPortfolio p, {
    DateTime? date,
    bool current = true,
    List<ExchangeRate>? rates,
  }) => valueLedgerAccounts(
    accounts: [account],
    entries: [],
    anchors: [],
    portfolios: [p],
    bookId: account.bookId,
    baseCurrencyCode: 'CNY',
    rates: rates ?? [rate('USD', 7)],
    at: date ?? at,
    current: current,
  );

  test('补充组合：股票、认购多头、认沽空头共用现金；冻结不重复扣减', () {
    final p = combined(),
        cash = accountCashAt(
          account: account,
          entries: [],
          anchors: [],
          at: at,
          portfolio: p,
        );
    expect(cash, 9600);
    final v = valueInvestmentAccount(p, cash);
    expect(v.longValue, 950);
    expect(v.shortObligation, 500);
    expect(v.frozen, 1000);
    expect(v.amounts!.assets, 10550);
    expect(v.amounts!.liabilities, 500);
    expect(v.amounts!.net, 10050);
    expect(v.realized, 0);
    expect(v.unrealized, 50);
    final converted = value(p);
    final home = HomeMetricContext(
      entries: [],
      accounts: [account],
      balanceOf: (_) => cash,
      now: at,
      balanceInBaseOf: (a) => converted.amountsByAccountId[a.id],
      assetAmountsInBaseOf: (a) => AccountAssetAmounts(
        converted.assetsByAccountId[a.id]!,
        converted.liabilitiesByAccountId[a.id]!,
      ),
    );
    expect(computeHomeMetric(HomeMetric.totalAssets, home), 73850);
    expect(computeHomeMetric(HomeMetric.totalLiabilities, home), 3500);
    expect(computeHomeMetric(HomeMetric.netAssets, home), 70350);
    expect(converted.completeAssets, 73850);
    expect(converted.completeLiabilities, 3500);
    expect(converted.completeTotal, 70350);
  });
  test('B07 完整验收原数值：三笔各收 1 手续费，净值 10497、未实现 497', () {
    final p = combined().copyWith(
      events: [
        stockEventFixture('stock', StockEventKind.buy, '10', '300', fee: '1'),
        optionEventFixture(
          call,
          StockEventKind.optionBuyOpen,
          id: 'call',
          price: '2',
          fee: '1',
          sequence: 2,
        ),
        optionEventFixture(
          put,
          StockEventKind.optionSellOpen,
          id: 'put',
          price: '2',
          fee: '1',
          sequence: 3,
          margin: '1000',
        ),
      ],
      manualPrices: {avgoFixture.id: '330', call.id: '3', put.id: '1'},
    );
    final cash = accountCashAt(
          account: account,
          entries: [],
          anchors: [],
          at: at,
          portfolio: p,
        ),
        v = valueInvestmentAccount(
          p,
          accountCashAt(
            account: account,
            entries: [],
            anchors: [],
            at: at,
            portfolio: p,
          ),
        );
    expect(cash, 6997);
    expect(v.longValue, 3600);
    expect(v.shortObligation, 100);
    expect(v.frozen, 1000);
    expect(cash - v.frozen, 5997);
    expect(v.amounts!.net, 10497);
    expect(v.unrealized, 497);
    expect(v.realized, 0);
    final total = value(p);
    expect(total.completeAssets, 74179);
    expect(total.completeLiabilities, 700);
    expect(total.completeTotal, 73479);
  });
  test('融资、未知成本、缺价和零净额不掩盖负债或缺汇率', () {
    final p = portfolioFixture(
      opening: [
        StockHolding(securityId: avgoFixture.id, short: false, quantity: '1'),
      ],
    );
    final v = valueInvestmentAccount(p, -100);
    expect(v.amounts!.assets, 330);
    expect(v.amounts!.liabilities, 100);
    expect(v.amounts!.net, 230);
    expect(v.costComplete, isFalse);
    expect(v.unrealized, isNull);
    expect(
      valueInvestmentAccount(p.copyWith(manualPrices: {}), 0).amounts,
      isNull,
    );
    final missing = convertAccountBalancesToBase(
      accounts: [account],
      balanceOf: (_) => 0,
      valuationOf: (_) => const AccountAssetAmounts(100, 100),
      bookId: account.bookId,
      baseCurrencyCode: 'CNY',
      date: at,
      rates: [],
    );
    expect(missing.completeTotal, isNull);
    expect(missing.missingCurrencyCodes, {'USD'});
  });
  test('当前保留全部已录入期初事实，历史在启用前仍留空', () {
    final p = portfolioFixture(
      opening: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '2',
          cost: '600',
        ),
      ],
    );
    final future = InvestmentPortfolio.fromJson({
      ...p.toJson(),
      'openedAt': DateTime(2027, 1, 1).toIso8601String(),
    });
    expect(value(future).completeTotal, 74620);
    expect(value(future, current: false).completeTotal, isNull);
  });
  test('CNY、USD、HKD 分别折算；不把各子账户原币直接相加', () {
    final hkd = investmentAccountFixture(
      id: 'hkd',
      currency: 'HKD',
    ).copyWith(initialBalance: 100);
    final cny = investmentAccountFixture(
      id: 'cny',
      currency: 'CNY',
    ).copyWith(initialBalance: 20);
    final v = valueLedgerAccounts(
      accounts: [account, hkd, cny],
      entries: [],
      anchors: [],
      portfolios: [combined()],
      bookId: account.bookId,
      baseCurrencyCode: 'CNY',
      rates: [rate('USD', 7), rate('HKD', 0.9)],
      at: at,
    );
    expect(v.completeAssets, 73960);
    expect(v.completeLiabilities, 3500);
    expect(v.completeTotal, 70460);
  });
  test('历史只用当日原价格和原汇率；今日改价、改汇率及未来成交不改旧值', () {
    final p = recorded(combined()), end = DateTime(2026, 10, 24, 23);
    expect(value(p, date: end, current: false).completeTotal, 70350);
    final changed = p.copyWith(
      manualPrices: {for (final id in p.manualPrices.keys) id: '999'},
      events: [
        ...p.events,
        StockEvent(
          id: 'future',
          securityId: avgoFixture.id,
          kind: StockEventKind.buy,
          occurredAt: DateTime(2026, 10, 25),
          sequence: 9,
          quantity: '1',
          price: '20',
        ),
      ],
    );
    expect(
      value(
        changed,
        date: end,
        current: false,
        rates: [rate('USD', 8)],
      ).completeTotal,
      70350,
    );
    expect(
      value(p, date: DateTime(2026, 10, 23, 23), current: false).completeTotal,
      isNull,
    );
    expect(
      value(p, date: DateTime(2026, 10, 25, 23), current: false).completeTotal,
      isNull,
    );
  });
  test('补录或修改历史成交后快照失效，不能沿用旧净值或今日价格补齐', () {
    final p = recorded(combined());
    final changed = p.copyWith(
      events: [
        ...p.events,
        stockEventFixture(
          'backdated',
          StockEventKind.buy,
          '1',
          '30',
          sequence: 10,
        ),
      ],
    );
    final v = value(changed, current: false, date: DateTime(2026, 10, 24, 23));
    expect(v.completeTotal, isNull);
    expect(v.missingValuationAccountIds, {account.id});
    final json = p.toJson();
    json.remove('valuationSnapshots');
    json.remove('marketPriceIds');
    expect(InvestmentPortfolio.fromJson(json).valuationSnapshots, isEmpty);
  });
  test('现金锚点仅影响现金且只在生效时使用；历史仓位不被校准抹除', () {
    final p = combined();
    final anchors = [
      BalanceAnchor(
        id: 'a',
        bookId: account.bookId,
        accountId: account.id,
        effectiveAt: DateTime(2026, 10, 20),
        balance: 8000,
        createdAt: at,
      ),
      BalanceAnchor(
        id: 'future',
        bookId: account.bookId,
        accountId: account.id,
        effectiveAt: DateTime(2026, 10, 30),
        balance: 9999,
        createdAt: at,
      ),
    ];
    expect(
      accountCashAt(
        account: account,
        entries: [],
        anchors: anchors,
        at: DateTime(2026, 10, 10),
        portfolio: p,
      ),
      9600,
    );
    final cash = accountCashAt(
      account: account,
      entries: [],
      anchors: anchors,
      at: at,
      portfolio: p,
    );
    expect(cash, 8000);
    expect(valueInvestmentAccount(p, cash).amounts!.net, 8450);
  });
  test('小组件修订核对使用原始账务，最新统计汇率副本不使历史依据失效', () {
    final raw = LedgerEntry(
      id: 'expense',
      bookId: account.bookId,
      type: EntryType.expense,
      amount: 10,
      baseAmount: 70,
      currencyCode: 'USD',
      categoryId: 'food',
      accountId: account.id,
      note: '验收',
      occurredAt: DateTime(2026, 10, 22),
    );
    final p = combined();
    final saved = p.copyWith(
      valuationSnapshots: [
        InvestmentValuationSnapshot(
          capturedAt: at,
          revision: investmentRevision(p, [raw], [], at),
          baseCurrencyCode: 'CNY',
          rateToBase: 7,
          rateDate: DateTime(2026, 10, 1),
          prices: p.manualPrices.map(
            (id, price) =>
                MapEntry(id, InvestmentPriceFact(price: price, quotedAt: at)),
          ),
        ),
      ],
    );
    final snapshot = WidgetLedgerSnapshot(
      book: LedgerBook(
        id: account.bookId,
        name: '投资',
        isDefault: true,
        createdAt: at,
      ),
      entries: [raw.copyWith(baseAmount: 80)],
      valuationEntries: [raw],
      accounts: [account],
      rates: [rate('USD', 8)],
      investmentPortfolios: [saved],
      budgetWindow: monthWindowFor(at),
      budget: 0,
    );
    final result = buildWidgetPresentation(
      definition: const UserWidgetDefinition(
        id: 'nav',
        name: '净资产',
        template: WidgetTemplate.netWorth,
        chartMetric: WidgetChartMetric.netWorth,
      ),
      snapshot: snapshot,
      now: at,
    );
    expect(result.primary.value, 80320);
    expect(result.series.last, 70280);
  });
  test('同一日观察点之后的成交仍重放；新证券无当日价格不使用今日手填补齐', () {
    final p = recorded(combined()), later = DateTime(2026, 10, 24, 13);
    final event = StockEvent(
      id: 'later',
      securityId: avgoFixture.id,
      kind: StockEventKind.buy,
      occurredAt: later,
      sequence: 10,
      quantity: '1',
      price: '20',
    );
    expect(
      value(
        p.copyWith(events: [...p.events, event]),
        date: DateTime(2026, 10, 24, 23),
        current: false,
      ).completeTotal,
      70595,
    );
    const other = StockSecurity(
      symbol: 'TEST-OTHER',
      name: '新证券验收示例',
      market: StockMarket.us,
      currencyCode: 'USD',
    );
    final added = p.copyWith(
      securities: [...p.securities, other],
      manualPrices: {...p.manualPrices, other.id: '200'},
      events: [
        ...p.events,
        StockEvent(
          id: 'new',
          securityId: other.id,
          kind: StockEventKind.buy,
          occurredAt: later,
          sequence: 10,
          quantity: '1',
          price: '20',
        ),
      ],
    );
    expect(
      value(
        added,
        date: DateTime(2026, 10, 24, 23),
        current: false,
      ).completeTotal,
      isNull,
    );
  });
  test('小组件当前值和只读 AI 与主汇总一致，历史缺日留空；隐藏单位仍生效', () {
    final p = recorded(combined());
    final snapshot = WidgetLedgerSnapshot(
      book: LedgerBook(
        id: account.bookId,
        name: '投资',
        isDefault: true,
        createdAt: at,
        baseCurrencyCode: 'CNY',
      ),
      entries: [],
      accounts: [account],
      rates: [rate('USD', 7)],
      budgetWindow: monthWindowFor(at),
      budget: 0,
      investmentPortfolios: [p],
    );
    final widget = buildWidgetPresentation(
      definition: const UserWidgetDefinition(
        id: 'nav',
        name: '净资产',
        template: WidgetTemplate.netWorth,
        secondaryMetrics: [
          WidgetMetric.totalAssets,
          WidgetMetric.totalLiabilities,
        ],
        chartMetric: WidgetChartMetric.netWorth,
        dateRange: WidgetDateRange.sevenDays,
      ),
      snapshot: snapshot,
      now: at,
    );
    expect(widget.primary.value, 70350);
    expect(widget.secondary.map((m) => m.value), [73850, 3500]);
    expect(widget.series.last, 70350);
    expect(widget.series.first, isNull);
    expect(widget.hasChartData, isFalse);
    for (final display in [MoneyCodeDisplay.code, MoneyCodeDisplay.none]) {
      final ctx = AiToolContext(
        entries: [],
        accounts: [account],
        categories: [],
        tags: [],
        balanceOf: (_) => 9600,
        assetAmounts: {account.id: valueInvestmentAccount(p, 9600).amounts!},
        bookId: account.bookId,
        baseCurrencyCode: 'CNY',
        exchangeRates: [rate('USD', 7)],
        now: at,
        l10n: lookupAppLocalizations(const Locale('zh')),
        currencyDisplay: display,
      );
      final result = const NetWorthTool().run(ctx, {});
      expect((result.display as AiStatDisplay).items.map((m) => m.value), [
        73850,
        3500,
        70350,
      ]);
      expect(result.summary.contains('CNY'), display == MoneyCodeDisplay.code);
      final table =
          const AccountsOverviewTool().run(ctx, {}).display as AiTableDisplay;
      expect(table.rows.single.last, '10050');
      expect(table.headers.last, ctx.l10n.investNetValue);
      expect(table.headers.length, display == MoneyCodeDisplay.code ? 3 : 2);
    }
  });
}
