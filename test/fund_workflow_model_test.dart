import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/models.dart';

/// 固定香港美元基金身份；测试数据只描述内存事实，不请求官方接口或创建真实账户。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金B类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 构造申请、扣款、确认与起算分开的样例；[id] 及 [securityId] 用于验证逐笔隔离。
/// 总扣款故意不等于舍入量价，验证不能用量价结果覆盖真实扣款和总成本。
FundSubscription _order({String id = 'order-1', String? securityId}) =>
    FundSubscription(
      id: id,
      securityId: securityId ?? _fund.id,
      requestedAt: DateTime.utc(2026, 10, 26, 3),
      cashAmount: '1401.31',
      paidAt: DateTime.utc(2026, 10, 27, 6),
      expectedConfirmationDate: DateTime.utc(2026, 10, 27),
      confirmation: FundSubscriptionConfirmation(
        confirmedAt: DateTime.utc(2026, 10, 28, 3),
        navDate: DateTime.utc(2026, 10, 27),
        earningStartDate: DateTime.utc(2026, 10, 29),
        nav: '110',
        quantity: '12.73',
      ),
    );

/// 由申请的唯一经济生效时刻建立零现金持仓事件；[sequence] 仅确定同刻重放次序。
StockEvent _acquire(FundSubscription subscription, {int sequence = 1}) =>
    StockEvent(
      id: 'acquire-${subscription.id}',
      securityId: subscription.securityId,
      kind: StockEventKind.fundAcquire,
      occurredAt: fundSubscriptionEffectiveAt(subscription)!,
      sequence: sequence,
      quantity: subscription.confirmation!.quantity,
      price: subscription.confirmation!.nav,
      carriedCost: subscription.cashAmount,
      fundSubscriptionId: subscription.id,
      fundNavDate: subscription.confirmation!.navDate,
    );

/// 构造独立投资聚合；[orders] 和 [events] 分开传入，以检验缺少/重复确认链接时拒绝保存。
InvestmentPortfolio _portfolio({
  List<FundSubscription> orders = const [],
  List<StockEvent> events = const [],
  List<StockSecurity> securities = const [_fund],
}) => InvestmentPortfolio(
  accountId: 'fund-usd',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime.utc(2026, 10, 1),
  openingCash: '2000',
  securities: securities,
  fundSubscriptions: orders,
  events: events,
);

/// 按 [changes] 修改事件 JSON 后重读，保持所有其余字段一致；只用于构造有针对性的非法输入。
StockEvent _changedEvent(StockEvent event, Map<String, Object?> changes) =>
    StockEvent.fromJson({...event.toJson(), ...changes});

/// 构造已有持仓基准；报告浮盈仅作核对，不能要求精确量价和已舍入报告金额必然相等。
StockEvent _baseline() => StockEvent(
  id: 'holding-baseline',
  securityId: _fund.id,
  kind: StockEventKind.fundHoldingBaseline,
  occurredAt: DateTime.utc(2026, 10, 28, 8),
  sequence: 1,
  quantity: '12.73',
  price: '110.175',
  carriedCost: '1401.31',
  reportedUnrealized: '+1.20',
  fundNavDate: DateTime.utc(2026, 10, 28),
  quantityInferred: true,
);

/// 验证模型兼容、香港日期、延迟生效及资金守恒需要的阶段边界；不启动 Controller 或 Android。
void main() {
  test('申购事实保留真实时刻与纯日期，copyWith能明确清除阶段', () {
    final order = _order();
    final raw = jsonDecode(jsonEncode(order.toJson())) as Map<String, dynamic>;
    final restored = FundSubscription.fromJson(raw);
    expect(restored.toJson(), order.toJson());
    expect(raw['expectedConfirmationDate'], '2026-10-27');
    expect((raw['confirmation'] as Map)['navDate'], '2026-10-27');
    expect((raw['confirmation'] as Map)['earningStartDate'], '2026-10-29');
    expect(restored.paidAt!.isUtc, isTrue);
    expect(restored.copyWith(note: '确认回执').paidAt, restored.paidAt);
    expect(restored.copyWith(paidAt: null, confirmation: null).paidAt, isNull);
    expect(order.note, isEmpty);
    for (final instant in [
      '2026-02-29T03:00:00Z',
      '2026-10-26T03:00:00',
      '2026-10-26T03:00:00+08:99',
    ]) {
      expect(
        () => FundSubscription.fromJson({
          ...order.toJson(),
          'requestedAt': instant,
        }),
        throwsFormatException,
      );
    }
  });

  test('旧投资数据省略新增默认键，载入后申购默认空且集合不可变', () {
    final legacy = _portfolio();
    final json = legacy.toJson();
    expect(json.containsKey('fundSubscriptions'), isFalse);
    final restored = InvestmentPortfolio.fromJson(json);
    expect(restored.fundSubscriptions, isEmpty);
    expect(
      () => restored.fundSubscriptions.add(_order()),
      throwsUnsupportedError,
    );
    final oldEvent = StockEvent(
      id: 'old-buy',
      securityId: _fund.id,
      kind: StockEventKind.buy,
      occurredAt: DateTime.utc(2026, 10, 2),
      sequence: 1,
      quantity: '1',
      price: '110',
    );
    for (final key in [
      'fundSubscriptionId',
      'reportedUnrealized',
      'fundNavDate',
      'quantityInferred',
    ]) {
      expect(oldEvent.toJson().containsKey(key), isFalse);
    }
    expect(StockEvent.fromJson(oldEvent.toJson()).quantityInferred, isFalse);
    final copied = legacy.copyWith(fundSubscriptions: [_order()]);
    expect(
      InvestmentPortfolio.fromJson(copied.toJson()).fundSubscriptions.single.id,
      'order-1',
    );
    expect(legacy.fundSubscriptions, isEmpty);
  });

  test('基准新字段往返保留报告盈亏、纯净值日和推算标记，基金动作不属于期权', () {
    final baseline = _baseline();
    expect(StockEvent.fromJson(baseline.toJson()).toJson(), baseline.toJson());
    expect(StockEventKind.fundAcquire.isOptionEvent, isFalse);
    expect(StockEventKind.fundHoldingBaseline.isOptionEvent, isFalse);
    expect(StockEventKind.optionMargin.isOptionEvent, isTrue);
    expect(StockEventKind.optionBuyOpen.isOptionEvent, isTrue);
    expect(StockEventKind.transferIn.isOptionEvent, isFalse);
  });

  test('香港日期跨UTC边界，纯日期拒绝隐藏时刻、时间戳及溢出日期', () {
    expect(
      hongKongFundDate(DateTime.utc(2026, 10, 27, 15, 59)),
      DateTime.utc(2026, 10, 27),
    );
    expect(
      hongKongFundDate(DateTime.utc(2026, 10, 27, 16)),
      DateTime.utc(2026, 10, 28),
    );
    expect(
      hongKongFundDate(DateTime.parse('2026-10-28T01:00:00+09:00')),
      DateTime.utc(2026, 10, 28),
    );
    expect(
      hongKongFundDayStart(DateTime.utc(2026, 10, 28)),
      DateTime.utc(2026, 10, 27, 16),
    );
    expect(fundCalendarDateFromJson('2028-02-29'), DateTime.utc(2028, 2, 29));
    for (final value in [
      '2026-02-29',
      '2026-13-01',
      '2026-10-28T00:00:00Z',
      '2026-1-01',
    ]) {
      expect(() => fundCalendarDateFromJson(value), throwsFormatException);
    }
    expect(
      () => hongKongFundDayStart(DateTime.utc(2026, 10, 28, 1)),
      throwsFormatException,
    );
  });

  test('实际扣款前无现金腿和在途款，预计日期不提前生效，确认后起算前仍保留净申购款', () {
    final order = _order();
    final portfolio = _portfolio(orders: [order], events: [_acquire(order)]);
    validateFundSubscriptions(portfolio);
    final beforePayment = DateTime.utc(2026, 10, 27, 5, 59);
    expect(fundSubscriptionCashLegs(portfolio, at: beforePayment), isEmpty);
    expect(
      fundSubscriptionPendingValue(portfolio, at: beforePayment).toString(),
      '0',
    );
    for (final at in [order.paidAt!, DateTime.utc(2026, 10, 28, 15, 59)]) {
      final legs = fundSubscriptionCashLegs(portfolio, at: at);
      expect(legs.single.id, 'fund:order-1:payment');
      expect(legs.single.amount.toString(), '-1401.31');
      expect(
        fundSubscriptionPendingValue(portfolio, at: at).toString(),
        '1401.31',
      );
    }
    final effectiveAt = DateTime.utc(2026, 10, 28, 16);
    expect(fundSubscriptionEffectiveAt(order), effectiveAt);
    expect(
      fundSubscriptionPendingValue(portfolio, at: effectiveAt).toString(),
      '0',
    );
    expect(fundSubscriptionCashLegs(portfolio, at: effectiveAt), hasLength(1));
  });

  test('同日付款和起算取实际付款时刻，晚到回执允许回填真实经济事实', () {
    final order = _order().copyWith(
      confirmation: FundSubscriptionConfirmation(
        confirmedAt: DateTime.utc(2026, 10, 30, 3),
        navDate: DateTime.utc(2026, 10, 27),
        earningStartDate: DateTime.utc(2026, 10, 27),
        nav: '110',
        quantity: '12.73',
      ),
    );
    expect(fundSubscriptionEffectiveAt(order), order.paidAt);
    final portfolio = _portfolio(orders: [order], events: [_acquire(order)]);
    validateFundSubscriptions(portfolio);
    expect(
      fundSubscriptionPendingValue(portfolio, at: order.paidAt!).toString(),
      '0',
    );
    expect(
      fundSubscriptionEffectiveAt(order.copyWith(confirmation: null)),
      isNull,
    );
    expect(fundSubscriptionEffectiveAt(order.copyWith(paidAt: null)), isNull);
    final premature = _changedEvent(_acquire(order), {
      'occurredAt': '2026-10-26T16:00:00Z',
    });
    expect(
      () => validateFundSubscriptions(
        _portfolio(orders: [order], events: [premature]),
      ),
      throwsFormatException,
    );
  });

  test('取消不假装退钱，到账前保留净款，费用与实际退款差额不提前计损', () {
    final order = _order().copyWith(
      confirmation: null,
      fee: '1.31',
      cancelledAt: DateTime.utc(2026, 10, 28, 3),
      refundedAt: DateTime.utc(2026, 10, 30, 4),
      refundAmount: '1398',
    );
    final portfolio = _portfolio(orders: [order]);
    validateFundSubscriptions(portfolio);
    final waiting = DateTime.utc(2026, 10, 29, 8);
    expect(
      fundSubscriptionPendingValue(portfolio, at: waiting).toString(),
      '1400',
    );
    expect(fundSubscriptionCashLegs(portfolio, at: waiting), hasLength(1));
    final legs = fundSubscriptionCashLegs(portfolio, at: order.refundedAt!);
    expect(legs.map((leg) => leg.id), [
      'fund:order-1:payment',
      'fund:order-1:refund',
    ]);
    expect(legs.map((leg) => leg.amount.toString()), ['-1401.31', '1398']);
    expect(
      fundSubscriptionPendingValue(portfolio, at: order.refundedAt!).toString(),
      '0',
    );
    expect(() => legs.clear(), throwsUnsupportedError);
  });

  test('多笔申购各有起算日，可按基金过滤，稳定资金腿不随确认产生第二次扣款', () {
    const anotherFund = StockSecurity(
      symbol: 'HK-OTHER',
      name: '另一香港基金',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    final first = _order();
    final second = _order(id: 'order-2', securityId: anotherFund.id).copyWith(
      confirmation: null,
      cashAmount: '200',
      paidAt: DateTime.utc(2026, 10, 28, 5),
    );
    final portfolio = _portfolio(
      orders: [second, first],
      events: [_acquire(first)],
      securities: [_fund, anotherFund],
    );
    validateFundSubscriptions(portfolio);
    final at = DateTime.utc(2026, 10, 29, 9);
    expect(fundSubscriptionPendingValue(portfolio, at: at).toString(), '200');
    expect(
      fundSubscriptionPendingValue(
        portfolio,
        at: at,
        securityId: _fund.id,
      ).toString(),
      '0',
    );
    expect(fundSubscriptionCashLegs(portfolio, at: at).map((leg) => leg.id), [
      'fund:order-1:payment',
      'fund:order-2:payment',
    ]);
    expect(
      fundSubscriptionCashLegs(
        portfolio,
        at: at,
        securityId: anotherFund.id,
      ).single.amount.toString(),
      '-200',
    );
  });

  test('申请金额和阶段校验拒绝超现金精度、重复ID、逆序时间及互斥状态', () {
    final base = _order().copyWith(confirmation: null);
    final invalid = [
      base.copyWith(cashAmount: '1401.311'),
      base.copyWith(fee: '-1'),
      base.copyWith(fee: '1401.31'),
      base.copyWith(paidAt: DateTime.utc(2026, 10, 25)),
      base.copyWith(expectedConfirmationDate: DateTime.utc(2026, 10, 25)),
      base.copyWith(refundedAt: DateTime.utc(2026, 10, 29)),
      base.copyWith(refundAmount: '1400'),
      base.copyWith(
        refundedAt: DateTime.utc(2026, 10, 29),
        refundAmount: '1400',
      ),
      base.copyWith(cancelledAt: DateTime.utc(2026, 10, 25)),
      _order().copyWith(cancelledAt: DateTime.utc(2026, 10, 29)),
      _order().copyWith(paidAt: null),
    ];
    for (final order in invalid) {
      expect(
        () => validateFundSubscriptions(_portfolio(orders: [order])),
        throwsFormatException,
      );
    }
    expect(
      () => validateFundSubscriptions(_portfolio(orders: [base, base])),
      throwsFormatException,
    );
  });

  test('确认必须有唯一且一致的持仓事件，实际成本不强求等于量价金额', () {
    final order = _order();
    final acquire = _acquire(order);
    validateFundSubscriptions(_portfolio(orders: [order], events: [acquire]));
    expect(
      () => validateFundSubscriptions(_portfolio(orders: [order])),
      throwsFormatException,
    );
    expect(
      () => validateFundSubscriptions(_portfolio(events: [acquire])),
      throwsFormatException,
    );
    final variants = [
      {'quantity': '12.74'},
      {'price': '111'},
      {'carriedCost': '1400.30'},
      {'fee': '1'},
      {'fundSubscriptionId': 'missing'},
      {'fundNavDate': '2026-10-28'},
      {'occurredAt': '2026-10-28T15:59:59Z'},
      {'reportedUnrealized': '1.20'},
    ];
    for (final changes in variants) {
      expect(
        () => validateFundSubscriptions(
          _portfolio(
            orders: [order],
            events: [_changedEvent(acquire, changes)],
          ),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => validateFundSubscriptions(
        _portfolio(
          orders: [order],
          events: [acquire, _acquire(order, sequence: 2)],
        ),
      ),
      throwsFormatException,
    );
  });

  test('基准为独立零现金事实，非法证券和普通事件夹带阶段字段会被拒绝', () {
    final baseline = _baseline();
    validateFundSubscriptions(_portfolio(events: [baseline]));
    for (final changes in [
      {'fundSubscriptionId': 'order-1'},
      {'fee': '1'},
      {'quantity': '0'},
      {'carriedCost': '-1'},
      {'short': true},
      {'fundNavDate': null},
      {'kind': 'buy'},
      {'fundNavDate': '2026-10-29'},
    ]) {
      expect(
        () => validateFundSubscriptions(
          _portfolio(events: [_changedEvent(baseline, changes)]),
        ),
        throwsFormatException,
      );
    }
    for (final market in [StockMarket.us, StockMarket.cn]) {
      final unsupported = StockSecurity(
        symbol: 'FUND',
        name: '非香港基金',
        market: market,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      );
      expect(
        () => validateFundSubscriptions(
          _portfolio(
            orders: [
              _order(securityId: unsupported.id).copyWith(confirmation: null),
            ],
            securities: [unsupported],
          ),
        ),
        throwsFormatException,
      );
    }
  });
}
