import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 固定基金身份及金额仅用于离线隔离验证，不表示基金真实成交、收益或公开行情。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '基金与期权隔离夹具',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 将十月的 [day] 号 [hour] 点转换为香港真实时刻；使用时区偏移而非绝对时长推算日历日。
DateTime _time(int day, int hour) => DateTime.utc(2026, 10, day, hour - 8);

/// 为测试基线替换 [source] 的期初现金 [cash]，其余原始事实通过模型 JSON 映射完整保留。
/// 期初现金不属于生产 copyWith 的可编辑字段，此 helper 只构造独立测试输入，不修改原聚合。
InvestmentPortfolio _withOpeningCash(InvestmentPortfolio source, String cash) =>
    InvestmentPortfolio.fromJson({...source.toJson(), 'openingCash': cash});

/// 创建以二十日净值成交的已确认申购；[paidAt] 可指定与期权结算同刻的实际扣款。
/// 回执二十一日才到，但历史计算仍以二十日日末形成基准，不以回执日替代经济日期。
FundSubscription _order({DateTime? paidAt}) => FundSubscription(
  id: 'option-isolation-fund',
  securityId: _fund.id,
  requestedAt: _time(18, 9),
  paidAt: paidAt ?? _time(19, 9),
  cashAmount: '1000',
  confirmation: FundSubscriptionConfirmation(
    confirmedAt: _time(21, 10),
    navDate: DateTime.utc(2026, 10, 20),
    earningStartDate: DateTime.utc(2026, 10, 20),
    accrualRule: FundAccrualRule.dealNavDate,
    nav: '100',
    quantity: '10',
  ),
);

/// 为既有股票/期权聚合 [source] 添加独立基金事实，不修改原事件、价格、成本或期权规格。
/// [paidAt] 供同刻锚点用例覆盖真实扣款时刻；序号一百只用于避开原证券事件的稳定序号。
InvestmentPortfolio _withFund(InvestmentPortfolio source, {DateTime? paidAt}) {
  final order = _order(paidAt: paidAt);
  final confirmation = order.confirmation!;
  return source.copyWith(
    securities: [...source.securities, _fund],
    fundSubscriptions: [order],
    manualPrices: {...source.manualPrices, _fund.id: '100'},
    events: [
      ...source.events,
      StockEvent(
        id: 'fund-confirm:${order.id}',
        securityId: _fund.id,
        kind: StockEventKind.fundAcquire,
        occurredAt: fundSubscriptionEffectiveAt(order)!,
        sequence: 100,
        quantity: confirmation.quantity,
        price: confirmation.nav,
        carriedCost: order.cashAmount,
        fundSubscriptionId: order.id,
        fundNavDate: confirmation.navDate,
      ),
    ],
  );
}

/// 取 [projection] 中原股票和期权的数量、方向及成本；明确去掉基金，避免把总持仓数量作比较。
/// 结果按身份与方向排序，不依赖底层 Map 的插入顺序，也不自行计算期权权利金或交割成本。
List<Map<String, Object?>> _originalPositions(StockProjection projection) {
  final result = [
    for (final position in projection.positions)
      if (position.securityId != _fund.id)
        <String, Object?>{
          'securityId': position.securityId,
          'short': position.short,
          'quantity': position.quantity.toString(),
          'cost': position.cost?.toString(),
        },
  ];
  result.sort((a, b) {
    final byId = (a['securityId']! as String).compareTo(
      b['securityId']! as String,
    );
    return byId == 0
        ? (a['short']! as bool ? 1 : 0).compareTo(b['short']! as bool ? 1 : 0)
        : byId;
  });
  return result;
}

/// 计算 [portfolio] 在 [at] 的现金；保留实际逐笔融资校验，基金在途不能用于支付期权支出。
/// [anchor] 为真实核对余额，缺省沿用期初现金及所有实际资金腿，不以市值或冻结额抵现金。
double _cash(
  InvestmentPortfolio portfolio,
  DateTime at, {
  BalanceAnchor? anchor,
}) => investmentCashBalance(
  portfolio: portfolio,
  entries: const [],
  at: at,
  anchor: anchor,
  rejectUnfundedHistory: true,
);

/// 比较同一原证券组合的 [mixed] 和 [baseline]；基线只移除基金并保留一千美元扣款影响。
/// [at] 为两边相同截点，[fundActive] 区分基金在途与份额，不改变期权现金、成本及保证金。
/// [anchor] 若存在，两侧采用相同真实余额，稳定包含 ID 分别由各自聚合保存。
void _expectIsolation(
  InvestmentPortfolio mixed,
  InvestmentPortfolio baseline, {
  required DateTime at,
  bool fundActive = false,
  BalanceAnchor? anchor,
}) {
  validateFundSubscriptions(mixed);
  final actual = projectStocks(mixed, at: at);
  final expected = projectStocks(baseline, at: at);
  expect(_originalPositions(actual), _originalPositions(expected));
  expect(actual.realized.toString(), expected.realized.toString());
  expect(actual.income.toString(), expected.income.toString());
  expect(actual.realizedComplete, expected.realizedComplete);
  expect(actual.frozenMargin.toString(), expected.frozenMargin.toString());
  expect(actual.optionReviews, expected.optionReviews);
  for (final entry in expected.cashMovements.entries) {
    expect(actual.cashMovements[entry.key]?.toString(), entry.value.toString());
  }
  final actualCash = _cash(mixed, at, anchor: anchor);
  final expectedCash = _cash(baseline, at, anchor: anchor);
  expect(actualCash, expectedCash);
  final actualValue = valueInvestmentAccount(mixed, actualCash, at: at);
  final expectedValue = valueInvestmentAccount(baseline, expectedCash, at: at);
  expect(actualValue.frozen, expectedValue.frozen);
  expect(actualValue.unrealized, expectedValue.unrealized);
  expect(actualValue.realized, expectedValue.realized);
  expect(actualValue.shortObligation, expectedValue.shortObligation);
  expect(actualValue.pendingSubscriptionValue, fundActive ? 0 : 1000);
  expect(
    actualValue.longValue,
    expectedValue.longValue! + (fundActive ? 1000 : 0),
  );
  expect(actualValue.amounts!.net, expectedValue.amounts!.net + 1000);
  expect(
    actual.positions.where((position) => position.securityId == _fund.id),
    fundActive ? hasLength(1) : isEmpty,
  );
}

/// 验证基金待生效及日末生效前后，原期权开平仓、保证金、实物交割与现金边界不变。
void main() {
  test('基金新规则待日末不改变两张认购部分平仓的现金、成本和已实现收益', () {
    final option = optionFixture();
    final source = optionPortfolioFixture(
      option,
      events: [
        optionEventFixture(
          option,
          StockEventKind.optionBuyOpen,
          id: 'call-open',
          quantity: '2',
          fee: '2',
          date: _time(20, 10),
        ),
        optionEventFixture(
          option,
          StockEventKind.optionSellClose,
          id: 'call-close',
          price: '3',
          fee: '1',
          sequence: 2,
          date: _time(20, 14),
        ),
      ],
    );
    final mixed = _withFund(source);
    final baseline = _withOpeningCash(source, '9000');
    final cutoff = _time(20, 15);
    _expectIsolation(mixed, baseline, at: cutoff);
    expect(_cash(mixed, cutoff), 8897);
    final projection = projectStocks(mixed, at: cutoff);
    expect(projection.positions.single.quantity.toString(), '1');
    expect(projection.positions.single.cost.toString(), '201');
    expect(projection.realized.toString(), '98');
    _expectIsolation(
      mixed,
      baseline,
      at: hongKongFundDayEnd(DateTime.utc(2026, 10, 20)),
      fundActive: true,
    );
  });

  test('基金在途不进入空头认沽权利金、保证金或平仓释放计算', () {
    final option = optionFixture(right: OptionRight.put);
    final open = optionEventFixture(
      option,
      StockEventKind.optionSellOpen,
      id: 'put-open',
      fee: '1',
      date: _time(20, 10),
    );
    final margin = optionEventFixture(
      option,
      StockEventKind.optionMargin,
      id: 'put-margin',
      quantity: '0',
      price: '0',
      margin: '1000',
      sequence: 2,
      date: _time(20, 11),
    );
    for (final close in [false, true]) {
      final source = optionPortfolioFixture(
        option,
        price: '1',
        events: [
          open,
          margin,
          if (close)
            optionEventFixture(
              option,
              StockEventKind.optionBuyClose,
              id: 'put-close',
              price: '1',
              fee: '1',
              margin: '0',
              sequence: 3,
              date: _time(20, 14),
            ),
        ],
      );
      final mixed = _withFund(source);
      final cutoff = _time(20, 15);
      _expectIsolation(mixed, _withOpeningCash(source, '9000'), at: cutoff);
      expect(_cash(mixed, cutoff), close ? 9098 : 9199);
      final result = projectStocks(mixed, at: cutoff);
      expect(result.frozenMargin.toString(), close ? '0' : '1000');
      expect(result.realized.toString(), close ? '98' : '0');
    }
  });

  for (final right in OptionRight.values) {
    for (final short in [false, true]) {
      test('待日末基金与${right.name}${short ? '空头' : '多头'}实物交割保持数量成本隔离', () {
        final option = optionFixture(right: right);
        final sellsStock =
            right == OptionRight.put && !short ||
            right == OptionRight.call && short;
        final source = optionPortfolioFixture(
          option,
          opening: sellsStock
              ? [
                  StockHolding(
                    securityId: avgoFixture.id,
                    short: false,
                    quantity: '100',
                    cost: '4000',
                  ),
                ]
              : [],
          events: [
            optionEventFixture(
              option,
              short
                  ? StockEventKind.optionSellOpen
                  : StockEventKind.optionBuyOpen,
              id: 'physical-open',
              date: _time(20, 10),
            ),
            optionEventFixture(
              option,
              StockEventKind.optionPhysicalSettle,
              id: 'physical-delivery',
              price: '0',
              short: short,
              settled: true,
              sequence: 2,
              date: _time(20, 14),
            ),
          ],
        );
        final mixed = _withFund(source);
        final baseline = _withOpeningCash(source, '9000');
        final cutoff = _time(20, 15);
        _expectIsolation(mixed, baseline, at: cutoff);
        final result = projectStocks(mixed, at: cutoff);
        expect(
          _cash(mixed, cutoff),
          sellsStock ? (short ? 14200 : 13800) : (short ? 4200 : 3800),
        );
        expect(
          result.positions.any((position) => position.securityId == option.id),
          isFalse,
        );
        if (sellsStock) {
          expect(result.positions, isEmpty);
          expect(result.realized.toString(), short ? '1200' : '800');
        } else {
          expect(result.positions.single.securityId, avgoFixture.id);
          expect(result.positions.single.quantity.toString(), '100');
          expect(
            result.positions.single.cost.toString(),
            short ? '4800' : '5200',
          );
        }
        _expectIsolation(
          mixed,
          baseline,
          at: hongKongFundDayEnd(DateTime.utc(2026, 10, 20)),
          fundActive: true,
        );
      });
    }
  }

  test('基金扣款和期权实物交割与现金锚点同刻只计一次，后补费用仍生效', () {
    final option = optionFixture();
    final settlementAt = _time(20, 10);
    final source = optionPortfolioFixture(
      option,
      events: [
        optionEventFixture(
          option,
          StockEventKind.optionBuyOpen,
          id: 'anchored-open',
          date: _time(19, 10),
        ),
        optionEventFixture(
          option,
          StockEventKind.optionPhysicalSettle,
          id: 'anchored-delivery',
          sequence: 2,
          date: settlementAt,
          price: '0',
          settled: true,
        ),
        StockEvent(
          id: 'late-fee',
          securityId: avgoFixture.id,
          kind: StockEventKind.fee,
          occurredAt: settlementAt,
          sequence: 3,
          quantity: '0',
          price: '1',
        ),
      ],
    );
    final mixed = _withFund(source, paidAt: settlementAt).copyWith(
      anchorIncludedIds: const {
        'mixed-anchor': [
          'stock:anchored-delivery',
          'fund:option-isolation-fund:payment',
        ],
      },
    );
    final baseline = _withOpeningCash(source, '9000').copyWith(
      anchorIncludedIds: const {
        'mixed-anchor': ['stock:anchored-delivery'],
      },
    );
    final anchor = BalanceAnchor(
      id: 'mixed-anchor',
      accountId: source.accountId,
      bookId: source.bookId,
      effectiveAt: settlementAt,
      balance: 3800,
      createdAt: _time(20, 15),
    );
    _expectIsolation(mixed, baseline, at: _time(20, 15), anchor: anchor);
    expect(_cash(mixed, _time(20, 15), anchor: anchor), 3799);
    expect(
      projectStocks(mixed, at: _time(20, 15)).positions.single.cost.toString(),
      '5200',
    );
    _expectIsolation(
      mixed,
      baseline,
      at: hongKongFundDayEnd(DateTime.utc(2026, 10, 20)),
      fundActive: true,
      anchor: anchor,
    );
  });

  test('基金一千美元在途不是可用现金，不足以支付原期权买入时仍拒绝融资', () {
    final option = optionFixture();
    final source = _withOpeningCash(
      optionPortfolioFixture(
        option,
        events: [
          optionEventFixture(
            option,
            StockEventKind.optionBuyOpen,
            id: 'unfunded-option',
            price: '3',
            fee: '1',
            date: _time(20, 10),
          ),
        ],
      ),
      '1200',
    );
    final mixed = _withFund(source);
    validateFundSubscriptions(mixed);
    expect(
      fundSubscriptionPendingValue(mixed, at: _time(20, 15)).toString(),
      '1000',
    );
    expect(() => _cash(mixed, _time(20, 15)), throwsFormatException);
    expect(
      () => _cash(_withOpeningCash(source, '200'), _time(20, 15)),
      throwsFormatException,
    );
  });
}
