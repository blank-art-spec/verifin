import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_reference_history.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 固定的香港美元基金身份，仅验证本地估值与历史重放，不请求网络行情。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 将纯日期 [date] 按日历字段平移 [days] 天，始终返回领域要求的 UTC 日期载体。
DateTime _shiftDate(DateTime date, int days) =>
    DateTime.utc(date.year, date.month, date.day + days);

/// 将香港民用日期 [date] 的 [hour] 点转换成真实 UTC 时刻，避免依赖测试机时区。
DateTime _hongKongTime(DateTime date, int hour) =>
    DateTime.utc(date.year, date.month, date.day, hour - 8);

/// 创建现在已经起算、但在历史截点仅完成付款的基金申购；[account] 限定所属币种账户。
/// 历史快照不含份额价格，因为当时只有现金与在途款；当前参考价已变为每份 110 美元。
({InvestmentPortfolio portfolio, DateTime historicalAt}) _confirmedPortfolio(
  Account account,
) {
  final today = hongKongFundDate(DateTime.now());
  final paidDate = _shiftDate(today, -5);
  final startDate = _shiftDate(today, -3);
  final historicalAt = _hongKongTime(_shiftDate(today, -4), 23);
  final subscription = FundSubscription(
    id: 'confirmed-subscription',
    securityId: _fund.id,
    requestedAt: _hongKongTime(_shiftDate(today, -6), 10),
    paidAt: _hongKongTime(paidDate, 10),
    cashAmount: '1000',
    confirmation: FundSubscriptionConfirmation(
      confirmedAt: _hongKongTime(startDate, 10),
      navDate: paidDate,
      earningStartDate: startDate,
      nav: '100',
      quantity: '10',
    ),
  );
  final portfolio = InvestmentPortfolio(
    accountId: account.id,
    bookId: account.bookId,
    currencyCode: 'USD',
    openedAt: _hongKongTime(_shiftDate(today, -10), 0),
    openingCash: '10000',
    securities: [_fund],
    fundSubscriptions: [subscription],
    events: [
      StockEvent(
        id: 'fund-confirm:confirmed-subscription',
        securityId: _fund.id,
        kind: StockEventKind.fundAcquire,
        occurredAt: hongKongFundDayStart(startDate),
        sequence: 1,
        quantity: '10',
        price: '100',
        carriedCost: '1000',
        fundSubscriptionId: subscription.id,
        fundNavDate: paidDate,
      ),
    ],
    manualPrices: {_fund.id: '110'},
  );
  return (
    historicalAt: historicalAt,
    portfolio: portfolio.copyWith(
      valuationSnapshots: [
        InvestmentValuationSnapshot(
          capturedAt: historicalAt,
          revision: investmentRevision(
            portfolio,
            const [],
            const [],
            historicalAt,
          ),
          baseCurrencyCode: 'USD',
          rateToBase: 1,
          prices: const {},
        ),
      ],
    ),
  );
}

/// 注册跨截点估值与同刻基准重置用例；只检查用户会看到的资产与收益结果。
void main() {
  test('历史付款后起算前仍保留在途资产，不因现在已经起算而漏掉本金', () {
    final account = investmentAccountFixture();
    final fixture = _confirmedPortfolio(account);
    final portfolio = fixture.portfolio;
    expect(
      fundSubscriptionPendingValue(portfolio, at: DateTime.now()).toString(),
      '0',
    );
    expect(
      investmentSnapshotAt(portfolio, fixture.historicalAt, const [], const []),
      isNotNull,
    );
    final historical = valueLedgerAccounts(
      accounts: [account],
      entries: const [],
      anchors: const [],
      portfolios: [portfolio],
      bookId: account.bookId,
      baseCurrencyCode: 'USD',
      rates: const [],
      at: fixture.historicalAt,
      current: false,
    );
    // 当时现金 9000、在途款 1000，没有份额持仓，因此不需要基金历史价格。
    expect(historical.completeAssets, 10000);
    expect(historical.completeLiabilities, 0);
    expect(historical.completeTotal, 10000);
    expect(historical.missingValuationAccountIds, isEmpty);
  });

  test('等值扣款费用与退款文本不作废历史依据，实际数值变化仍更新修订', () {
    final fixture = _confirmedPortfolio(investmentAccountFixture());
    final portfolio = fixture.portfolio, at = fixture.historicalAt;
    final subscription = portfolio.fundSubscriptions.single;
    final equivalent = portfolio.copyWith(
      fundSubscriptions: [
        subscription.copyWith(cashAmount: '1000.00', fee: '0.00'),
      ],
    );
    final original = investmentRevision(portfolio, const [], const [], at);
    expect(investmentRevision(equivalent, const [], const [], at), original);
    expect(investmentSnapshotAt(equivalent, at, const [], const []), isNotNull);
    expect(
      investmentRevision(
        portfolio.copyWith(
          fundSubscriptions: [subscription.copyWith(fee: '0.01')],
        ),
        const [],
        const [],
        at,
      ),
      isNot(original),
    );
    final refunded = portfolio.copyWith(
      events: [],
      fundSubscriptions: [
        subscription.copyWith(
          confirmation: null,
          cancelledAt: at,
          refundedAt: at,
          refundAmount: '999.5',
        ),
      ],
    );
    final equivalentRefund = refunded.copyWith(
      fundSubscriptions: [
        refunded.fundSubscriptions.single.copyWith(refundAmount: '999.50'),
      ],
    );
    expect(
      investmentRevision(refunded, const [], const [], at),
      investmentRevision(equivalentRefund, const [], const [], at),
    );
  });

  test('当前汇总的旧汇率日期不截掉现在已起算份额，仍显示当前现金加参考市值', () {
    final account = investmentAccountFixture();
    final fixture = _confirmedPortfolio(account);
    final current = valueLedgerAccounts(
      accounts: [account],
      entries: const [],
      anchors: const [],
      portfolios: [fixture.portfolio],
      bookId: account.bookId,
      baseCurrencyCode: 'USD',
      rates: const [],
      at: fixture.historicalAt,
      current: true,
      currentCashOf: (_) => 9000,
    );
    // at 落在付款后、起算前，但这里只选汇率日期；当前 10 份 × 110 加现金 9000。
    expect(current.completeAssets, 10100);
    expect(current.completeLiabilities, 0);
    expect(current.completeTotal, 9000 + 10 * 110);
    expect(current.missingValuationAccountIds, isEmpty);
  });

  test('同刻先卖出和分红再核对基准，累计收益重置且下一净值日恢复正常日收益', () {
    final account = investmentAccountFixture();
    final firstDate = DateTime.utc(2026, 10, 1);
    final baselineDate = DateTime.utc(2026, 10, 2);
    final nextDate = DateTime.utc(2026, 10, 3);
    final sameInstant = _hongKongTime(baselineDate, 10);
    final baseline = StockEvent(
      id: 'new-baseline',
      securityId: _fund.id,
      kind: StockEventKind.fundHoldingBaseline,
      occurredAt: sameInstant,
      sequence: 3,
      quantity: '2',
      price: '110',
      carriedCost: '220',
      reportedUnrealized: '0',
      fundNavDate: baselineDate,
    );
    final portfolio = InvestmentPortfolio(
      accountId: account.id,
      bookId: account.bookId,
      currencyCode: 'USD',
      openedAt: _hongKongTime(firstDate, 0),
      openingCash: '10000',
      securities: [_fund],
      openingHoldings: [
        StockHolding(
          securityId: _fund.id,
          short: false,
          quantity: '10',
          cost: '1000',
        ),
      ],
      // 故意不按列表顺序排列；同刻事实必须按 sequence 解释。
      events: [
        baseline,
        StockEvent(
          id: 'old-dividend',
          securityId: _fund.id,
          kind: StockEventKind.dividend,
          occurredAt: sameInstant,
          sequence: 2,
          quantity: '0',
          price: '5',
        ),
        StockEvent(
          id: 'old-sell',
          securityId: _fund.id,
          kind: StockEventKind.sell,
          occurredAt: sameInstant,
          sequence: 1,
          quantity: '8',
          price: '120',
        ),
      ],
      manualPrices: {_fund.id: '999'},
    );
    final days = buildFundReferenceHistory(
      portfolio: portfolio,
      security: _fund,
      history: FundNavHistory([
        FundNavPoint(date: firstDate, price: '100'),
        FundNavPoint(date: baselineDate, price: '111'),
        FundNavPoint(date: nextDate, price: '112'),
      ]),
      account: account,
      entries: const [],
      anchors: const [],
    );
    expect(days.map((day) => day.quantity.toString()), ['10', '2', '2']);
    expect(days.map((day) => day.marketValue.toString()), [
      '1000',
      '222',
      '224',
    ]);
    expect(days.map((day) => day.cumulativeProfit?.toString()), [
      '0',
      '2',
      '4',
    ]);
    expect(days.map((day) => day.dailyProfit?.toString()), [null, null, '2']);
    // 基准仅重置收益观察依据，先前真实卖出和分红到账仍保留在现金中。
    expect(days.map((day) => day.cash), [10000, 10965, 10965]);
    expect(days.last.accountNetValue, 11189);
  });
}
