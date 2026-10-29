import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_reference_history.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 已核对实际净值交易规则的固定基金身份；全部价格均为测试值，不表示真实基金行情。
const _cmsFund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 将 2026 年十月的 [day] 号构造成香港纯日期载体，不包含日内时刻或设备时区。
DateTime _date(int day) => DateTime.utc(2026, 10, day);

/// 返回香港 [day] 号 [hour] 点对应的真实 UTC 时刻；八小时用于时区转换而非日历加减。
DateTime _time(int day, int hour) => DateTime.utc(2026, 10, day, hour - 8);

/// 创建实际扣款和成交净值分离的确认申请，确认回执默认比成交净值日晚三天。
/// [day] 是实际成交净值日，[paidDay] 可指定更早扣款；[cash] 已包含单独列示的 [fee]。
/// [quantity] 和 [nav] 为回执事实，不要求量价乘积恰好等于净申购款，以覆盖真实舍入差额。
/// [rule] 缺省采用已核实的成交净值规则；旧规则由测试明确指定并单独传入 [earningDay]。
FundSubscription _order({
  String id = 'cms-order',
  StockSecurity security = _cmsFund,
  int day = 20,
  int? paidDay,
  int? confirmedDay,
  int? earningDay,
  String cash = '1000',
  String fee = '0',
  String quantity = '10',
  String nav = '100',
  FundAccrualRule rule = FundAccrualRule.dealNavDate,
}) => FundSubscription(
  id: id,
  securityId: security.id,
  requestedAt: _time((paidDay ?? day) - 1, 9),
  paidAt: _time(paidDay ?? day, 9),
  cashAmount: cash,
  fee: fee,
  confirmation: FundSubscriptionConfirmation(
    confirmedAt: _time(confirmedDay ?? day + 3, 10),
    navDate: _date(day),
    earningStartDate: _date(earningDay ?? day),
    nav: nav,
    quantity: quantity,
    accrualRule: rule,
  ),
);

/// 把 [order] 的实际确认转换成唯一零现金份额事件；[sequence] 保证多笔同刻事实顺序稳定。
/// 经济时点直接使用领域函数，单独的非法时点测试会修改此字段验证聚合校验不会放行。
StockEvent _acquire(FundSubscription order, int sequence) => StockEvent(
  id: 'fund-confirm:${order.id}',
  securityId: order.securityId,
  kind: StockEventKind.fundAcquire,
  occurredAt: fundSubscriptionEffectiveAt(order)!,
  sequence: sequence,
  quantity: order.confirmation!.quantity,
  price: order.confirmation!.nav,
  carriedCost: order.cashAmount,
  fundSubscriptionId: order.id,
  fundNavDate: order.confirmation!.navDate,
);

/// 复用统一账户 fixture 构造固定原币聚合；[events] 非空时允许刻意传入非法关联事件。
/// 未确认申请不产生持仓事件，扣款、取消、退款只保留在 [orders] 的实际资金事实中。
InvestmentPortfolio _portfolio(
  List<FundSubscription> orders, {
  List<StockSecurity> securities = const [_cmsFund],
  List<StockEvent>? events,
}) {
  final account = investmentAccountFixture();
  var sequence = 0;
  return InvestmentPortfolio(
    accountId: account.id,
    bookId: account.bookId,
    currencyCode: account.currencyCode,
    openedAt: _time(1, 0),
    openingCash: '10000',
    securities: securities,
    fundSubscriptions: orders,
    events:
        events ??
        [
          for (final order in orders)
            if (order.confirmation != null) _acquire(order, ++sequence),
        ],
  );
}

/// 仅按 [navs] 真实传入的日期生成来源点；缺失成交日、周末或其他日期均不会自行补齐。
/// 返回原币历史结果，不读取当前行情、网络、数据库或机器时间。
List<FundReferenceDay> _history(
  InvestmentPortfolio portfolio,
  Map<int, String> navs,
) => buildFundReferenceHistory(
  portfolio: portfolio,
  security: _cmsFund,
  history: FundNavHistory([
    for (final entry in navs.entries)
      FundNavPoint(date: _date(entry.key), price: entry.value),
  ]),
  account: investmentAccountFixture(),
  entries: const [],
  anchors: const [],
);

/// 覆盖实际成交净值基准、独立申购、区间归属、非净值调整与旧备份兼容，不运行 Android。
void main() {
  test('成交净值日只形成基准，后续收益逐期归属而不集中到晚到回执日', () {
    final order = _order(confirmedDay: 23);
    final portfolio = _portfolio([order]);
    validateFundSubscriptions(portfolio);
    final effectiveAt = hongKongFundDayEnd(_date(20));
    expect(fundSubscriptionEffectiveAt(order), effectiveAt);
    expect(projectStocks(portfolio, at: _time(20, 12)).positions, isEmpty);
    expect(
      fundSubscriptionPendingValue(portfolio, at: _time(20, 12)).toString(),
      '1000',
    );
    expect(
      projectStocks(
        portfolio,
        at: effectiveAt,
      ).positions.single.quantity.toString(),
      '10',
    );
    expect(
      fundSubscriptionPendingValue(portfolio, at: effectiveAt).toString(),
      '0',
    );
    final days = _history(portfolio, {
      19: '99',
      20: '100',
      21: '101',
      22: '102',
      23: '102',
    });
    expect(days.map((point) => point.quantity.toString()), [
      '0',
      '10',
      '10',
      '10',
      '10',
    ]);
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '0',
      '10',
      '10',
      '0',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '0',
      '0',
      '10',
      '20',
      '20',
    ]);
    expect(days.map((point) => point.profitFromDate), [
      null,
      _date(19),
      _date(20),
      _date(21),
      _date(22),
    ]);
    expect(days.map((point) => point.cash), [10000, 9000, 9000, 9000, 9000]);
    expect(days.map((point) => point.accountNetValue), [
      10000,
      10000,
      10010,
      10020,
      10020,
    ]);
  });

  test('多笔申购各用成交净值建基准，新增本金不计收益且下跌按实际份额计损', () {
    final portfolio = _portfolio([
      _order(id: 'first', day: 19),
      _order(id: 'second', day: 21, cash: '510', quantity: '5', nav: '102'),
    ]);
    validateFundSubscriptions(portfolio);
    final days = _history(portfolio, {
      19: '100',
      20: '101',
      21: '102',
      22: '101',
      23: '103',
    });
    expect(days.map((point) => point.quantity.toString()), [
      '10',
      '10',
      '15',
      '15',
      '15',
    ]);
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '10',
      '10',
      '-15',
      '30',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '0',
      '10',
      '20',
      '5',
      '35',
    ]);
    expect(days.last.accountNetValue, 10035);
  });

  test('周五至周一明确属于跨公布日区间，不拆造周末价格或周末单日收益', () {
    final portfolio = _portfolio([_order(day: 23, confirmedDay: 27)]);
    final days = _history(portfolio, {22: '99', 23: '100', 26: '103'});
    expect(days.map((point) => point.date), [_date(22), _date(23), _date(26)]);
    expect(days.last.profitFromDate, _date(23));
    expect(days.last.dailyProfit?.toString(), '30');
    expect(days.last.cumulativeProfit?.toString(), '30');
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '0',
      '30',
    ]);
  });

  test('公开历史首点缺少成交日净值时不伪造日收益，实际成本仍支持累计收益', () {
    final portfolio = _portfolio([_order(day: 20)]);
    final days = _history(portfolio, {21: '101', 22: '102'});
    expect(days.map((point) => point.date), [_date(21), _date(22)]);
    expect(days.first.profitFromDate, isNull);
    expect(days.first.dailyProfit, isNull);
    expect(days.first.cumulativeProfit?.toString(), '10');
    expect(days.last.profitFromDate, _date(21));
    expect(days.last.dailyProfit?.toString(), '10');
    expect(days.last.cumulativeProfit?.toString(), '20');
  });

  test('扣款费用与确认量价差额分期单列，完整净盈亏和实际现金保持守恒', () {
    final portfolio = _portfolio([
      _order(day: 21, paidDay: 20, cash: '1002', fee: '2', quantity: '10.001'),
    ]);
    validateFundSubscriptions(portfolio);
    final days = _history(portfolio, {
      19: '99',
      20: '99',
      21: '100',
      22: '101',
    });
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '-2',
      '0.1',
      '10',
    ]);
    expect(days.map((point) => point.subscriptionAdjustment?.toString()), [
      null,
      '-2',
      '0.1',
      '0',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '0',
      '-2',
      '-1.9',
      '8.1',
    ]);
    expect(days.map((point) => point.cash), [10000, 8998, 8998, 8998]);
    expect(days.last.accountNetValue, closeTo(10008.1, 0.000001));
    expect(portfolio.fundSubscriptions.single.cashAmount, '1002');
    expect(portfolio.events.single.carriedCost, '1002');
  });

  test('退款实际差额在到账区间单列，先前申购费用不会被重复计损', () {
    final order = _order(day: 21, paidDay: 20, fee: '2').copyWith(
      confirmation: null,
      cancelledAt: _time(21, 10),
      refundedAt: _time(22, 10),
      refundAmount: '995',
    );
    final portfolio = _portfolio([order]);
    validateFundSubscriptions(portfolio);
    final days = _history(portfolio, {
      19: '100',
      20: '100',
      21: '100',
      22: '100',
    });
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '-2',
      '0',
      '-3',
    ]);
    expect(days.map((point) => point.subscriptionAdjustment?.toString()), [
      null,
      '-2',
      '0',
      '-3',
    ]);
    expect(days.map((point) => point.cumulativeProfit?.toString()), [
      '0',
      '-2',
      '-2',
      '-5',
    ]);
    expect(days.last.cash, 9995);
    expect(days.last.pendingSubscriptionValue.toString(), '0');
  });

  test('两笔半分向上舍入时按合并份额分配确认差额，分项不超过完整净收益', () {
    final portfolio = _portfolio([
      _order(id: 'half-cent-first', quantity: '10.00005'),
      _order(id: 'half-cent-second', quantity: '10.00005'),
    ]);
    validateFundSubscriptions(portfolio);
    final days = _history(portfolio, {19: '100', 20: '100', 21: '100'});
    // 每笔单独市值为 1000.01，但同账户份额合计市值仅为 2000.01；不能重复多记半分钱。
    expect(days[1].quantity.toString(), '20.0001');
    expect(days[1].marketValue.toString(), '2000.01');
    expect(days[1].dailyProfit?.toString(), '0.01');
    expect(days[1].subscriptionAdjustment?.toString(), '0.01');
    expect(days[1].cumulativeProfit?.toString(), '0.01');
    expect(days[1].accountNetValue, closeTo(10000.01, 0.000001));
    expect(days.last.dailyProfit?.toString(), '0');
    expect(days.last.subscriptionAdjustment?.toString(), '0');
  });

  test('两笔量价分别舍入至扣款额但合并少一分时，实际差额完整列入确认分项', () {
    final portfolio = _portfolio([
      _order(
        id: 'fraction-first',
        cash: '1010.52',
        quantity: '10.005',
        nav: '101.001',
      ),
      _order(
        id: 'fraction-second',
        cash: '1010.52',
        quantity: '10.005',
        nav: '101.001',
      ),
    ]);
    validateFundSubscriptions(portfolio);
    final days = _history(portfolio, {
      19: '101.001',
      20: '101.001',
      21: '101.001',
    });
    // 10.005×101.001＝1010.515005；两笔合计舍入为 2021.03，实际总扣款仍为 2021.04。
    expect(days[1].quantity.toString(), '20.01');
    expect(days[1].marketValue.toString(), '2021.03');
    expect(days[1].dailyProfit?.toString(), '-0.01');
    expect(days[1].subscriptionAdjustment?.toString(), '-0.01');
    expect(days[1].cumulativeProfit?.toString(), '-0.01');
    expect(days[1].cash, closeTo(7978.96, 0.000001));
    expect(days[1].accountNetValue, closeTo(9999.99, 0.000001));
    expect(days.last.dailyProfit?.toString(), '0');
    expect(days.last.subscriptionAdjustment?.toString(), '0');
  });

  test('已有零碎份额后新增申购沿用合并市值舍入，不再单独补记一分钱', () {
    final portfolio = _portfolio([_order(quantity: '10.00005')]).copyWith(
      openingHoldings: [
        StockHolding(
          securityId: _cmsFund.id,
          short: false,
          quantity: '10.00005',
          cost: '1000',
        ),
      ],
    );
    validateFundSubscriptions(portfolio);
    final days = _history(portfolio, {19: '100', 20: '100'});
    // 原持仓已包含向上舍入的一分钱；新增后合并市值只增加整 1000，不能再次记为确认收益。
    expect(days.first.marketValue.toString(), '1000.01');
    expect(days.last.marketValue.toString(), '2000.01');
    expect(days.last.dailyProfit?.toString(), '0');
    expect(days.last.subscriptionAdjustment?.toString(), '0');
    expect(days.last.cumulativeProfit?.toString(), '0.01');
    expect(days.last.accountNetValue, days.first.accountNetValue);
  });

  test('成交净值规则只允许核实的代码市场品种和美元身份', () {
    expect(supportsCmsDealNavAccrual(_cmsFund), isTrue);
    const unsupported = [
      StockSecurity(
        symbol: 'HK-OTHER',
        name: '其他香港基金',
        market: StockMarket.hk,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      StockSecurity(
        symbol: 'HK0001039582',
        name: '同代码股票',
        market: StockMarket.hk,
        currencyCode: 'USD',
      ),
      StockSecurity(
        symbol: 'HK0001039582',
        name: '不同市场基金',
        market: StockMarket.us,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      StockSecurity(
        symbol: 'HK0001039582',
        name: '不同币种基金',
        market: StockMarket.hk,
        currencyCode: 'HKD',
        type: InvestmentSecurityType.fund,
      ),
    ];
    for (final security in unsupported) {
      expect(supportsCmsDealNavAccrual(security), isFalse);
      expect(
        () => validateFundSubscriptions(
          _portfolio([_order(security: security)], securities: [security]),
        ),
        throwsFormatException,
      );
    }
  });

  test('成交净值规则拒绝晚于成交日扣款和不一致的兼容起算日期', () {
    for (final order in [_order(paidDay: 21), _order(earningDay: 21)]) {
      expect(
        () => validateFundSubscriptions(_portfolio([order])),
        throwsFormatException,
      );
    }
    final order = _order();
    final event = _acquire(order, 1);
    final premature = StockEvent.fromJson({
      ...event.toJson(),
      'occurredAt': hongKongFundDayStart(_date(20)).toIso8601String(),
    });
    expect(
      () => validateFundSubscriptions(_portfolio([order], events: [premature])),
      throwsFormatException,
    );
  });

  test('旧JSON缺失规则时保持旧时点和原JSON形状，不能被证券代码静默改算', () {
    final legacy = _order(
      rule: FundAccrualRule.explicitStartDate,
      earningDay: 22,
    );
    final expected = <String, Object?>{
      'confirmedAt': _time(23, 10).toIso8601String(),
      'navDate': '2026-10-20',
      'earningStartDate': '2026-10-22',
      'nav': '100',
      'quantity': '10',
    };
    expect(legacy.confirmation!.toJson(), expected);
    final restoredConfirmation = FundSubscriptionConfirmation.fromJson(
      expected,
    );
    expect(restoredConfirmation.accrualRule, FundAccrualRule.explicitStartDate);
    expect(restoredConfirmation.toJson(), expected);
    final portfolio = _portfolio([legacy]);
    final before = jsonEncode(portfolio.toJson());
    final restored = InvestmentPortfolio.fromJson(
      jsonDecode(before) as Map<String, Object?>,
    );
    expect(jsonEncode(restored.toJson()), before);
    validateFundSubscriptions(restored);
    expect(
      fundSubscriptionEffectiveAt(restored.fundSubscriptions.single),
      hongKongFundDayStart(_date(22)),
    );
    final days = _history(restored, {20: '100', 21: '101', 22: '102'});
    expect(days.map((point) => point.quantity.toString()), ['0', '0', '10']);
    expect(days.map((point) => point.dailyProfit?.toString()), [
      null,
      '0',
      '20',
    ]);
  });

  test('成交发行价与同日公开净值的已知差额属于结算分项，不冒充之后净值增长', () {
    final portfolio = _portfolio([_order()]);
    final days = _history(portfolio, {
      19: '99',
      20: '100.0009',
      21: '101.0009',
    });
    expect(days[1].dailyProfit?.toString(), '0.01');
    expect(days[1].subscriptionAdjustment?.toString(), '0.01');
    expect(days.last.dailyProfit?.toString(), '10');
    expect(days.last.subscriptionAdjustment?.toString(), '0');
  });

  test('净值日末同刻按稳定序号拒绝先核对后加申购，先申购后核对则不会重复', () {
    final order = _order();
    final acquisition = _acquire(order, 2);
    final baseline = StockEvent(
      id: 'same-end-baseline',
      securityId: _cmsFund.id,
      kind: StockEventKind.fundHoldingBaseline,
      occurredAt: hongKongFundDayEnd(_date(20)),
      sequence: 1,
      quantity: '10',
      price: '100',
      carriedCost: '1000',
      fundNavDate: _date(20),
    );
    expect(
      () => validateFundSubscriptions(
        _portfolio([order], events: [baseline, acquisition]),
      ),
      throwsFormatException,
    );
    final safe = _portfolio(
      [order],
      events: [
        _acquire(order, 1),
        StockEvent.fromJson({...baseline.toJson(), 'sequence': 2}),
      ],
    );
    validateFundSubscriptions(safe);
    expect(
      projectStocks(
        safe,
        at: _time(21, 0),
      ).positions.single.quantity.toString(),
      '10',
    );
  });

  test('新规则JSON显式保存且往返保持，未知规则直接拒绝而不是降级旧公式', () {
    final raw = _order().confirmation!.toJson();
    expect(raw['accrualRule'], 'dealNavDate');
    final restored = FundSubscriptionConfirmation.fromJson(raw);
    expect(restored.accrualRule, FundAccrualRule.dealNavDate);
    expect(restored.toJson(), raw);
    for (final invalid in ['unknown-rule', 123, true]) {
      expect(
        () => FundSubscriptionConfirmation.fromJson({
          ...raw,
          'accrualRule': invalid,
        }),
        throwsFormatException,
      );
    }
  });
}
