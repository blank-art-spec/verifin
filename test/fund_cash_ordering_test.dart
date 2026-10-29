import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 固定基金身份只用于本地资金顺序验证，不联网、不推算份额或创建任何普通收支。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
final _sameTime = DateTime.utc(2026, 10, 3, 4);
final _cutoff = DateTime.utc(2026, 10, 3, 5);

/// 构造先前已付款、在 [_sameTime] 实际退款的申请；[id] 不应决定现金能否用于同刻再投资。
/// [refundAmount] 可小于本金，用来检验真实可用资金不足仍会被拒绝。
FundSubscription _refunded({String id = 'old', String refundAmount = '1000'}) =>
    FundSubscription(
      id: id,
      securityId: _fund.id,
      requestedAt: DateTime.utc(2026, 10, 1, 4),
      paidAt: DateTime.utc(2026, 10, 2, 4),
      cashAmount: '1000',
      cancelledAt: DateTime.utc(2026, 10, 3, 3),
      refundedAt: _sameTime,
      refundAmount: refundAmount,
    );

/// 构造在退款同刻实际付款的另一笔申请；[amount] 是真实总扣款，不从退款余额自动凑数。
FundSubscription _newPayment(String id, {String amount = '1000'}) =>
    FundSubscription(
      id: id,
      securityId: _fund.id,
      requestedAt: DateTime.utc(2026, 10, 3, 3),
      paidAt: _sameTime,
      cashAmount: amount,
    );

/// 构造退款同刻的股票事实；[sequence] 是股票自身的稳定顺序，不能被基金优先级重排。
StockEvent _stockEvent(
  String id,
  StockEventKind kind, {
  int sequence = 1,
  String quantity = '10',
}) => StockEvent(
  id: id,
  securityId: avgoFixture.id,
  kind: kind,
  occurredAt: _sameTime,
  sequence: sequence,
  quantity: quantity,
  price: '100',
);

/// 组装独立账户事实；[included] 只存现金锚点同刻已包含的稳定腿 ID，不影响持仓重放。
InvestmentPortfolio _portfolio({
  String openingCash = '1000',
  List<FundSubscription> orders = const [],
  List<StockEvent> events = const [],
  List<StockHolding> opening = const [],
  Map<String, List<String>> included = const {},
}) => InvestmentPortfolio(
  accountId: 'fund-refund-ordering',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime.utc(2026, 10, 1),
  openingCash: openingCash,
  securities: const [_fund, avgoFixture],
  fundSubscriptions: orders,
  events: events,
  openingHoldings: opening,
  manualPrices: {avgoFixture.id: '100'},
  anchorIncludedIds: included,
);

/// 读取 [_cutoff] 现金并保留逐笔融资校验；[anchor] 可验证同刻已核对资金不重复计入。
double _cash(InvestmentPortfolio portfolio, {BalanceAnchor? anchor}) =>
    investmentCashBalance(
      portfolio: portfolio,
      entries: const [],
      anchor: anchor,
      at: _cutoff,
      rejectUnfundedHistory: true,
    );

/// 在 [effectiveAt] 核准 [balance] 为真实现金；缺省使用 [_sameTime]，可另测同毫秒的微秒差异。
/// 不伪造普通收入或把基金退款再写成另一笔到账。
BalanceAnchor _anchor(double balance, {DateTime? effectiveAt}) => BalanceAnchor(
  id: 'cash-anchor',
  accountId: 'fund-refund-ordering',
  bookId: defaultLedgerBookId,
  effectiveAt: effectiveAt ?? _sameTime,
  balance: balance,
  createdAt: _cutoff,
);

/// 覆盖基金退款的同刻供款能力，同时保持旧股票顺序和真实融资校验，不合并所有交易净额。
void main() {
  test('已实际到账的基金退款可用于同刻股票买入，不能因品种前缀误报现金不足', () {
    final portfolio = _portfolio(
      orders: [_refunded()],
      events: [_stockEvent('buy-after-refund', StockEventKind.buy)],
    );
    validateFundSubscriptions(portfolio);
    expect(_cash(portfolio), 0);
  });

  test('退款用于同刻另一笔申购时，订单ID字典序不决定是否误报融资', () {
    for (final ids in [
      ('z-old-refund', 'a-new-payment'),
      ('a-old-refund', 'z-new-payment'),
    ]) {
      final portfolio = _portfolio(
        orders: [
          _newPayment(ids.$2),
          _refunded(id: ids.$1),
        ],
      );
      validateFundSubscriptions(portfolio);
      expect(_cash(portfolio), 0, reason: '${ids.$1}退款与${ids.$2}付款应各计一次');
      expect(fundSubscriptionCashLegs(portfolio, at: _cutoff), hasLength(3));
    }
  });

  test('实际退款仍不足以支付同刻股票或申购时，继续拒绝真实融资', () {
    final stockPurchase = _portfolio(
      orders: [_refunded(refundAmount: '900')],
      events: [_stockEvent('unfunded-stock', StockEventKind.buy)],
    );
    expect(() => _cash(stockPurchase), throwsFormatException);
    final fundPurchase = _portfolio(
      orders: [
        _refunded(),
        _newPayment('new-too-large', amount: '1100'),
      ],
    );
    expect(() => _cash(fundPurchase), throwsFormatException);
  });

  test('锚点已包含退款时不再到账，同刻后补的股票支出仍计入一次', () {
    final portfolio = _portfolio(
      orders: [_refunded()],
      events: [_stockEvent('late-stock-buy', StockEventKind.buy)],
      included: const {
        'cash-anchor': ['fund:old:refund'],
      },
    );
    // 退款已包含在1000余额里，股票买入是同刻之后补录的新事实。
    expect(_cash(portfolio, anchor: _anchor(1000)), 0);
    final reconciled = portfolio.copyWith(
      anchorIncludedIds: const {
        'cash-anchor': ['fund:old:refund', 'stock:late-stock-buy'],
      },
    );
    expect(_cash(reconciled, anchor: _anchor(0)), 0);
    final beforeBoth = portfolio.copyWith(
      anchorIncludedIds: const {'cash-anchor': []},
    );
    expect(_cash(beforeBoth, anchor: _anchor(0)), 0);
  });

  test('原股票同刻先卖后买仍按sequence供款，先买后卖仍按原语义拒绝融资', () {
    final sellThenBuy = _portfolio(
      openingCash: '0',
      opening: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '1',
          cost: '100',
        ),
      ],
      // 容器故意反序，证券仍按sequence先卖出一股，再用所得买入一股。
      events: [
        _stockEvent('buy', StockEventKind.buy, sequence: 2, quantity: '1'),
        _stockEvent('sell', StockEventKind.sell, sequence: 1, quantity: '1'),
      ],
    );
    expect(_cash(sellThenBuy), 0);
    final buyThenSell = sellThenBuy.copyWith(
      events: [
        _stockEvent('sell', StockEventKind.sell, sequence: 2, quantity: '1'),
        _stockEvent('buy', StockEventKind.buy, sequence: 1, quantity: '1'),
      ],
    );
    expect(() => _cash(buyThenSell), throwsFormatException);
  });

  test('现金锚点按毫秒恢复后，微秒付款和退款仍由稳定腿ID判断是否已包含', () {
    final payment = _newPayment(
      'paid-micros',
    ).copyWith(paidAt: _sameTime.add(const Duration(microseconds: 500)));
    final paid = _portfolio(
      orders: [payment],
      included: const {
        'cash-anchor': ['fund:paid-micros:payment'],
      },
    );
    // 模拟锚点已在SQLite截成整毫秒，但基金JSON仍保留原500微秒。
    expect(_cash(paid, anchor: _anchor(0)), 0);
    final refund = _refunded().copyWith(
      refundedAt: _sameTime.add(const Duration(microseconds: 900)),
    );
    final refunded = _portfolio(
      orders: [refund],
      included: const {
        'cash-anchor': ['fund:old:refund'],
      },
    );
    expect(_cash(refunded, anchor: _anchor(1000)), 1000);
  });

  test('同毫秒后补的付款未列入锚点时，即使微秒更早也应计入一次', () {
    final payment = _newPayment(
      'late-payment',
    ).copyWith(paidAt: _sameTime.add(const Duration(microseconds: 500)));
    final portfolio = _portfolio(
      orders: [payment],
      included: const {'cash-anchor': []},
    );
    final anchor = _anchor(
      1000,
      effectiveAt: _sameTime.add(const Duration(microseconds: 900)),
    );
    expect(_cash(portfolio, anchor: anchor), 0);
  });
}
