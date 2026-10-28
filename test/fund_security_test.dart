import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';

/// 固定基金身份；下方交易为纯计算输入，不表示真实历史成交或个人持仓。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金B类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 构造单笔份额事实；[kind] 为待验证动作，[quantity] 与 [price] 均保留精确文本。
/// [sequence] 同时控制固定成交日，避免重放顺序依赖测试机器当前时间。
StockEvent _event(
  StockEventKind kind, {
  String quantity = '10',
  String price = '100',
  int sequence = 1,
}) => StockEvent(
  id: 'fund-$sequence',
  securityId: _fund.id,
  kind: kind,
  occurredAt: DateTime(2026, 10, sequence + 1),
  sequence: sequence,
  quantity: quantity,
  price: price,
);

/// 构造独立美元账户；[events] 与 [opening] 只在内存重放，不创建 Controller 或联网。
InvestmentPortfolio _portfolio({
  List<StockEvent> events = const [],
  List<StockHolding> opening = const [],
}) => InvestmentPortfolio(
  accountId: 'fund-usd',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime(2026, 10, 1),
  openingCash: '2000',
  securities: const [_fund],
  openingHoldings: opening,
  events: events,
  manualPrices: {_fund.id: '109.815'},
);

/// 生成日期型净值观察；[date] 只承载来源年月日，[unit] 用于检验错误单位拒绝。
MarketQuote _quote(
  DateTime date, {
  QuotePriceUnit unit = QuotePriceUnit.fundUnit,
}) => MarketQuote(
  securityId: _fund.id,
  source: '本地基金夹具',
  currency: 'USD',
  unit: unit,
  fetchedAt: DateTime.utc(2026, 10, 26, 16, 30),
  last: '109.8150',
  lastAt: date,
  dateOnly: true,
);

/// 验证份额成本、未经支持动作的拒绝及跨 UTC 日期边界的日精度语义。
void main() {
  test('基金买卖按份额分摊成本，部分卖出不会把净值收益写成现金分红', () {
    final portfolio = _portfolio(
      events: [
        _event(StockEventKind.buy),
        _event(StockEventKind.sell, quantity: '2', price: '110', sequence: 2),
      ],
    );
    final projection = projectStocks(portfolio);
    final position = projection.positions.single;
    expect(position.quantity.toString(), '8');
    expect(position.cost.toString(), '800');
    expect(projection.realized.toString(), '20');
    expect(projection.income.toString(), '0');
    expect(projection.cashMovements.values.map((v) => v.toString()), [
      '-1000',
      '220',
    ]);
    final valuation = valueStocks(portfolio, projection);
    expect(valuation.marketValue.toString(), '878.52');
    expect(valuation.unrealized.toString(), '78.52');
  });

  for (final kind in [
    StockEventKind.shortSell,
    StockEventKind.cover,
    StockEventKind.split,
    StockEventKind.optionBuyOpen,
  ]) {
    test('基金拒绝未经实现的${kind.name}动作', () {
      expect(
        () => projectStocks(_portfolio(events: [_event(kind)])),
        throwsFormatException,
      );
    });
  }

  test('基金不能通过期初空仓或单股期权标的绕过品种校验', () {
    expect(
      () => projectStocks(
        _portfolio(
          opening: [
            StockHolding(
              securityId: _fund.id,
              short: true,
              quantity: '1',
              cost: '100',
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    final option = StockSecurity(
      symbol: 'TEST-FUND-CALL',
      name: '非法基金单股交割夹具',
      market: StockMarket.hk,
      currencyCode: 'USD',
      option: OptionContract(
        underlyingId: _fund.id,
        expiry: '2026-12-31',
        right: OptionRight.call,
        strike: '100',
        premiumMultiplier: '100',
        settlement: OptionSettlement.physical,
        deliverableShares: '100',
        exerciseCash: '10000',
        specification: '仅用于拒绝错误品种，非真实合约',
        confirmed: true,
      ),
    );
    expect(
      () => projectStocks(_portfolio().copyWith(securities: [_fund, option])),
      throwsFormatException,
    );
  });

  test('香港净值日期按香港日历核对，不把日期载体当成未来UTC报价时刻', () {
    // UTC 10月26日16:30是香港10月27日00:30；来源只给10月27日，不是UTC午夜报价。
    final date = DateTime.utc(2026, 10, 27);
    final quote = _quote(date);
    final reference = quote.reference(
      MarketQuoteRequest(_fund),
      DateTime.utc(2026, 10, 26, 16, 30),
    );
    expect(quote.last, '109.8150');
    expect(reference?.price, '109.815');
    expect(reference?.time, date);
    expect(MarketQuote.fromJson(quote.toJson()).dateOnly, isTrue);
    expect(
      _quote(DateTime.utc(2026, 10, 28)).reference(
        MarketQuoteRequest(_fund),
        DateTime.utc(2026, 10, 26, 16, 30),
      ),
      isNull,
    );
  });

  test('日期型净值拒绝隐藏时刻、本地时间载体和股票单位', () {
    final now = DateTime.utc(2026, 10, 26, 16, 30);
    for (final invalid in [
      _quote(DateTime.utc(2026, 10, 27, 1)),
      _quote(DateTime(2026, 10, 27)),
      _quote(DateTime.utc(2026, 10, 27), unit: QuotePriceUnit.share),
    ]) {
      expect(invalid.reference(MarketQuoteRequest(_fund), now), isNull);
    }
  });
}
