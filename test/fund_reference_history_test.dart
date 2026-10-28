import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_reference_history.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'support/investment_fixture.dart';

/// 注册基金净值日参考推演的边界用例；只使用固定来源点，不联网或写入账目。
void main() {
  test('买入费、部分卖出、现金分红与费用均计入参考收益，不把本金当收益', () {
    final portfolio = _portfolio(
      events: [
        _event('buy', StockEventKind.buy, 1, fee: '1'),
        _event(
          'sell',
          StockEventKind.sell,
          2,
          sequence: 2,
          quantity: '4',
          price: '103',
          fee: '1',
        ),
        _event(
          'distribution',
          StockEventKind.dividend,
          3,
          sequence: 3,
          quantity: '0',
          price: '5',
          fee: '1',
        ),
        _event(
          'management-fee',
          StockEventKind.fee,
          3,
          sequence: 4,
          quantity: '0',
          price: '2',
        ),
      ],
    );
    final before = jsonEncode(portfolio.toJson());
    final days = _build(portfolio, {1: '101', 2: '102', 3: '103'});
    expect(days.map((point) => point.quantity.toString()), ['10', '6', '6']);
    expect(days.map((point) => point.marketValue.toString()), [
      '1010',
      '612',
      '618',
    ]);
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '13',
      '8',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '9',
      '22',
      '30',
    ]);
    expect(days.map((point) => point.cash), [8999, 9410, 9412]);
    expect(days.map((point) => point.accountNetValue), [10009, 10022, 10030]);
    expect(days.every((point) => point.accountLiabilities == 0), isTrue);
    expect(jsonEncode(portfolio.toJson()), before);
  });

  test('净值日缺口仅计算跨发布日区间，不补周末或推算自然日价格', () {
    final portfolio = _portfolio(
      openedAt: _hongKongTime(5, 12),
      events: [_event('buy', StockEventKind.buy, 5, at: _hongKongTime(5, 13))],
    );
    final days = _build(portfolio, {4: '99', 5: '100', 8: '101'});
    expect(days.map((point) => point.date), [_date(5), _date(8)]);
    expect(days.first.dailyProfit, isNull);
    expect(days.last.dailyProfit?.toString(), '10');
    expect(days.last.cumulativeProfit?.toString(), '10');
    expect(_build(portfolio, {1: '98', 4: '99'}), isEmpty);
  });

  test('基金转入转出区间收益未知，后续正常区间恢复且现金不伪增', () {
    final portfolio = _portfolio(
      events: [
        _event(
          'transfer-in',
          StockEventKind.transferIn,
          2,
          carriedCost: '1000',
          batchId: 'incoming-batch',
          price: '0',
        ),
        _event(
          'transfer-out',
          StockEventKind.transferOut,
          4,
          sequence: 2,
          quantity: '4',
          carriedCost: '400',
          batchId: 'outgoing-batch',
          price: '0',
        ),
      ],
    );
    final days = _build(portfolio, {
      1: '100',
      2: '101',
      3: '102',
      4: '103',
      5: '104',
    });
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      null,
      '10',
      null,
      '6',
    ]);
    expect(days.map((point) => point.quantity.toString()), [
      '0',
      '10',
      '10',
      '6',
      '6',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '0',
      '10',
      '20',
      '18',
      '24',
    ]);
    expect(days.every((point) => point.cash == 10000), isTrue);
  });

  test('期初成本未知仍可算跨净值日变动，累计盈亏保持未知', () {
    final portfolio = _portfolio(
      openingHoldings: [
        StockHolding(securityId: _fund.id, short: false, quantity: '10'),
      ],
      events: [
        _event('sell', StockEventKind.sell, 3, quantity: '5', price: '102'),
      ],
    );
    final days = _build(portfolio, {1: '100', 2: '101', 3: '102'});
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '10',
      '10',
    ]);
    expect(days.every((point) => point.cumulativeProfit == null), isTrue);
    expect(days.every((point) => point.accountNetValue != null), isTrue);
  });

  test('卖出清仓后份额和市值为零，已实现收益不丢失', () {
    final portfolio = _portfolio(
      events: [
        _event('buy', StockEventKind.buy, 1),
        _event('sell-all', StockEventKind.sell, 2, sequence: 2, price: '101'),
      ],
    );
    final days = _build(portfolio, {1: '100', 2: '102', 3: '103'});
    expect(days.map((point) => point.quantity.toString()), ['10', '0', '0']);
    expect(days.map((point) => point.marketValue.toString()), [
      '1000',
      '0',
      '0',
    ]);
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '10',
      '0',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '0',
      '10',
      '10',
    ]);
    expect(days.last.accountNetValue, 10010);
  });

  test('香港日末包含最后微秒，次日零点交易不提前且同刻按sequence重放', () {
    final lastMicrosecond = DateTime.utc(2026, 10, 1, 15, 59, 59, 999, 999);
    final portfolio = _portfolio(
      events: [
        _event(
          'same-time-sell',
          StockEventKind.sell,
          1,
          sequence: 2,
          quantity: '5',
          at: lastMicrosecond,
        ),
        _event('same-time-buy', StockEventKind.buy, 1, at: lastMicrosecond),
        _event(
          'next-midnight-buy',
          StockEventKind.buy,
          2,
          sequence: 3,
          quantity: '2',
          at: _hongKongTime(2, 0),
        ),
      ],
    );
    final days = _build(portfolio, {1: '101', 2: '102'});
    expect(days.map((point) => point.quantity.toString()), ['5', '7']);
    expect(days.map((point) => point.cash), [9500, 9300]);
    expect(days.last.dailyProfit?.toString(), '9');
    expect(days.last.cumulativeProfit?.toString(), '14');
  });

  test('香港基金按USD份额净值精确计算，不转HKD或使用当前999后备价', () {
    final portfolio = _portfolio(
      events: [
        _event('fractional-buy', StockEventKind.buy, 1, quantity: '0.125'),
      ],
    );
    final point = _build(portfolio, {1: '100.12345678'}).single;
    expect(point.date, _date(1));
    expect(point.date.isUtc, isTrue);
    expect(point.nav.toString(), '100.12345678');
    expect(point.quantity.toString(), '0.125');
    expect(point.marketValue.toString(), '12.52');
    expect(point.cumulativeProfit?.toString(), '0.02');
    expect(point.cash, 9987.5);
    expect(point.accountNetValue, closeTo(10000.02, 0.00000001));
    expect(point.missingSecurityIds, isEmpty);
    expect(
      () => buildFundReferenceHistory(
        portfolio: portfolio,
        security: _fund,
        history: _history({1: '100'}),
        account: investmentAccountFixture(id: _accountId, currency: 'HKD'),
        entries: const [],
        anchors: const [],
      ),
      throwsFormatException,
    );
  });

  test('混合账户其他股票缺同日历史价时，基金收益已知但账户总额未知', () {
    final days = _build(_mixedPortfolio(), {1: '101', 2: '102'});
    expect(days.first.marketValue.toString(), '1010');
    expect(days.first.cumulativeProfit?.toString(), '10');
    expect(days.last.dailyProfit?.toString(), '10');
    expect(days.every((point) => point.cash == 8600), isTrue);
    expect(days.every((point) => point.accountAssets == null), isTrue);
    expect(days.every((point) => point.accountLiabilities == null), isTrue);
    expect(days.every((point) => point.accountNetValue == null), isTrue);
    expect(
      days.every((point) => point.missingSecurityIds.contains(_stock.id)),
      isTrue,
    );
  });

  test('同日有效快照补齐股票价，本基金始终使用来源NAV且不沿用前日快照', () {
    final portfolio = _mixedPortfolio();
    final recorded = _withSnapshot(
      portfolio,
      day: 1,
      prices: {_stock.id: '250', _fund.id: '999'},
    );
    final days = _build(recorded, {1: '101', 2: '102'});
    expect(days.first.marketValue.toString(), '1010');
    expect(days.first.accountAssets, 10110);
    expect(days.first.accountNetValue, 10110);
    expect(days.first.missingSecurityIds, isEmpty);
    expect(days.last.accountAssets, isNull);
    expect(days.last.missingSecurityIds, {_stock.id});
  });

  test('快照按香港日历日匹配，不按UTC日期或设备本地日误归属', () {
    final recorded = _withSnapshot(
      _mixedPortfolio(),
      day: 2,
      prices: {_stock.id: '250'},
      capturedAt: _hongKongTime(2, 0, 30),
      quotedAt: _hongKongTime(2, 0, 10),
    );
    final days = _build(recorded, {1: '101', 2: '102'});
    expect(days.first.accountAssets, isNull);
    expect(days.last.accountAssets, 10120);
    expect(days.last.missingSecurityIds, isEmpty);
  });

  test('补录过去交易后旧快照失效，不能用当前价补齐历史资产', () {
    final base = _mixedPortfolio();
    final recorded = _withSnapshot(base, day: 1, prices: {_stock.id: '250'});
    final revised = recorded.copyWith(
      events: [
        ...recorded.events,
        StockEvent(
          id: 'backfilled-stock-buy',
          securityId: _stock.id,
          kind: StockEventKind.buy,
          occurredAt: _hongKongTime(1, 11),
          sequence: 3,
          quantity: '1',
          price: '200',
        ),
      ],
    );
    final point = _build(revised, {1: '101'}).single;
    expect(point.cash, 8400);
    expect(point.marketValue.toString(), '1010');
    expect(point.accountAssets, isNull);
    expect(point.missingSecurityIds, {_stock.id});
  });

  test('当日快照之后新增交易也不能当作覆盖日日末全部持仓的依据', () {
    final recorded = _withSnapshot(
      _mixedPortfolio(),
      day: 1,
      prices: {_stock.id: '250'},
    );
    final changedAfterCapture = recorded.copyWith(
      events: [
        ...recorded.events,
        StockEvent(
          id: 'late-stock-buy',
          securityId: _stock.id,
          kind: StockEventKind.buy,
          occurredAt: _hongKongTime(1, 23, 30),
          sequence: 3,
          quantity: '1',
          price: '200',
        ),
      ],
    );
    final point = _build(changedAfterCapture, {1: '101'}).single;
    expect(point.accountAssets, isNull);
    expect(point.missingSecurityIds, {_stock.id});
  });

  test('当日保存但源报价日期较旧的股票依据不冒充当日历史价', () {
    final recorded = _withSnapshot(
      _mixedPortfolio(),
      day: 1,
      prices: {_stock.id: '250'},
      quotedAt: _hongKongTime(0, 22),
    );
    final point = _build(recorded, {1: '101'}).single;
    expect(point.accountAssets, isNull);
    expect(point.missingSecurityIds, {_stock.id});
  });

  test('历史现金复用已生效锚点和真实普通交易，不从当前总额或NAV反推', () {
    final portfolio = _portfolio(
      events: [_event('buy', StockEventKind.buy, 1)],
    );
    final entries = [
      _income('before-anchor', 1, 500),
      _income('after-anchor', 2, 25),
    ];
    final anchor = BalanceAnchor(
      id: 'cash-anchor',
      bookId: defaultLedgerBookId,
      accountId: _accountId,
      effectiveAt: _hongKongTime(2, 12),
      balance: 8000,
      createdAt: _hongKongTime(2, 12),
    );
    final days = _build(
      portfolio,
      {1: '101', 2: '102'},
      entries: entries,
      anchors: [anchor],
    );
    expect(days.map((point) => point.cash), [9500, 8025]);
    expect(days.last.dailyProfit?.toString(), '10');
    expect(days.last.accountNetValue, 9045);
    expect(entries, hasLength(2));
  });

  test('零持仓和负现金保留资产负债分解，不把融资负数显示为负资产', () {
    final portfolio = _portfolio(openingCash: '-50', allowFinancing: true);
    final days = _build(portfolio, {1: '100', 2: '101'});
    expect(days.every((point) => point.quantity.toString() == '0'), isTrue);
    expect(days.last.dailyProfit?.toString(), '0');
    expect(days.last.cumulativeProfit?.toString(), '0');
    expect(days.last.accountAssets, 0);
    expect(days.last.accountLiabilities, 50);
    expect(days.last.accountNetValue, -50);
  });
}

const _accountId = 'fund-history-usd';
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
const _stock = StockSecurity(
  symbol: 'GOOG',
  name: '谷歌',
  market: StockMarket.us,
  currencyCode: 'USD',
);

/// 将十月香港日历字段 [day]/[hour]/[minute] 换成 UTC 真实时刻，避免依赖测试机时区。
DateTime _hongKongTime(int day, int hour, [int minute = 0]) =>
    DateTime.utc(2026, 10, day, hour - 8, minute);

/// 创建来源净值日的 UTC 日期载体；[day] 只表达日历日，不表示实际发布时间。
DateTime _date(int day) => DateTime.utc(2026, 10, day);

/// 将按日期升序给出的 [prices] 转成不可变来源历史，值为每份 USD 净值文本。
FundNavHistory _history(Map<int, String> prices) => FundNavHistory([
  for (final entry in prices.entries)
    FundNavPoint(date: _date(entry.key), price: entry.value),
]);

/// 创建固定的基金事实；[sequence] 控制同刻顺序，[at] 覆盖默认香港当日十点。
/// [quantity]/[price]/[fee] 为精确文本；转移用 [carriedCost]/[batchId] 表达携带成本。
StockEvent _event(
  String id,
  StockEventKind kind,
  int day, {
  int sequence = 1,
  String quantity = '10',
  String price = '100',
  String fee = '0',
  String? carriedCost,
  String? batchId,
  DateTime? at,
}) => StockEvent(
  id: id,
  securityId: _fund.id,
  kind: kind,
  occurredAt: at ?? _hongKongTime(day, 10),
  sequence: sequence,
  quantity: quantity,
  price: price,
  fee: fee,
  carriedCost: carriedCost,
  batchId: batchId,
  note: '本地参考历史验收示例，不是真实基金成交',
);

/// 创建同币种聚合；[events]/[openingHoldings] 为真实事实测试输入，
/// [otherSecurities] 扩展混合账户；当前后备价故意设为 999，验证历史不会偷用现价。
/// [openedAt]/[openingCash]/[allowFinancing] 用于开仓边界与负现金验收。
InvestmentPortfolio _portfolio({
  List<StockEvent> events = const [],
  List<StockHolding> openingHoldings = const [],
  List<StockSecurity> otherSecurities = const [],
  DateTime? openedAt,
  String openingCash = '10000',
  bool allowFinancing = false,
}) => InvestmentPortfolio(
  accountId: _accountId,
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: openedAt ?? _hongKongTime(1, 0),
  openingCash: openingCash,
  securities: [_fund, ...otherSecurities],
  openingHoldings: openingHoldings,
  events: events,
  manualPrices: {
    _fund.id: '999',
    for (final security in otherSecurities) security.id: '999',
  },
  allowFinancing: allowFinancing,
);

/// 构造基金十份和谷歌两股同账户的已知成本事实，供其他持仓历史价缺失用例复用。
InvestmentPortfolio _mixedPortfolio() => _portfolio(
  otherSecurities: [_stock],
  events: [
    _event('fund-buy', StockEventKind.buy, 1),
    StockEvent(
      id: 'stock-buy',
      securityId: _stock.id,
      kind: StockEventKind.buy,
      occurredAt: _hongKongTime(1, 10),
      sequence: 2,
      quantity: '2',
      price: '200',
    ),
  ],
);

/// 为 [portfolio] 保存香港 [day] 的测试快照，[prices] 仅含当时人工确认的历史价。
/// [capturedAt]/[quotedAt] 可指定同日先后或源报价跨日；修订依据保存时真实事实计算。
InvestmentPortfolio _withSnapshot(
  InvestmentPortfolio portfolio, {
  required int day,
  required Map<String, String> prices,
  DateTime? capturedAt,
  DateTime? quotedAt,
}) {
  final at = capturedAt ?? _hongKongTime(day, 23);
  return portfolio.copyWith(
    valuationSnapshots: [
      InvestmentValuationSnapshot(
        capturedAt: at,
        revision: investmentRevision(portfolio, const [], const [], at),
        baseCurrencyCode: 'USD',
        rateToBase: 1,
        prices: prices.map(
          (id, price) => MapEntry(
            id,
            InvestmentPriceFact(
              price: price,
              quotedAt: quotedAt ?? _hongKongTime(day, 22),
            ),
          ),
        ),
      ),
    ],
  );
}

/// 创建会真实改变 USD 现金的普通收入；[day] 固定香港十三点，供现金锚点边界验收。
LedgerEntry _income(String id, int day, double amount) => LedgerEntry(
  id: id,
  bookId: defaultLedgerBookId,
  type: EntryType.income,
  amount: amount,
  currencyCode: 'USD',
  categoryId: 'income',
  accountId: _accountId,
  note: '独立普通现金事实，不是基金参考收益生成的流水',
  occurredAt: _hongKongTime(day, 13),
);

/// 使用固定 USD 账户调用只读入口；[prices] 为来源公布日，额外流水/锚点不被修改。
List<FundReferenceDay> _build(
  InvestmentPortfolio portfolio,
  Map<int, String> prices, {
  List<LedgerEntry> entries = const [],
  List<BalanceAnchor> anchors = const [],
}) => buildFundReferenceHistory(
  portfolio: portfolio,
  security: _fund,
  history: _history(prices),
  account: investmentAccountFixture(id: _accountId),
  entries: entries,
  anchors: anchors,
);
