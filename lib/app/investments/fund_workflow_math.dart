/// 香港基金申购的阶段校验及资金、在途资产纯计算；不联网、不落账、不推测确认日期。
library;

import '../currency_catalog.dart';
import '../models/fund_subscription.dart';
import '../models/investment.dart';
import 'investment_decimal.dart';
import 'stock_projection.dart' show compareStockEvents;

export '../models/fund_subscription.dart'
    show
        hongKongFundDate,
        hongKongFundDayStart,
        hongKongFundDayEnd,
        isCanonicalFundDate;

/// 判断 [security] 是否为已核实成交净值归属规则的招商美元货币基金 B 类。
/// 同时核对真实品种、市场、币种及 ISIN，不按名称、相似代码或其他类别扩大规则覆盖。
bool supportsCmsDealNavAccrual(StockSecurity security) =>
    security.isFund &&
    security.option == null &&
    security.market == StockMarket.hk &&
    security.currencyCode == 'USD' &&
    security.symbol == 'HK0001039582';

/// 一笔已经实际发生的基金资金腿；用于现金重放、历史收益与同刻现金核对去重。
class FundCashLeg {
  /// [id] 使用稳定的申购 ID 及 payment/refund 后缀，编辑日期或金额不会生成第二条资金腿。
  /// [occurredAt] 是实际扣款或到账时刻；[amount] 付款为负、退款为非负，不包括任何份额变动。
  const FundCashLeg({
    required this.id,
    required this.occurredAt,
    required this.amount,
  });

  final String id;
  final DateTime occurredAt;
  final InvestmentDecimal amount;
}

/// 返回申购 [subscription] 的持仓经济生效时刻；未付款或未确认时返回 null。
/// 旧规则按独立收益起算日日初、且不早于付款时刻生效，原有记录保持原形状及口径。
/// 成交净值规则按实际净值日日末形成日级持仓基准，其后净值变化归各公布区间；确认回执
/// 晚到不改变经济日期。日日末是日报边界而非实际收市钟点；不支持获份额后才付款的应付款模型。
DateTime? fundSubscriptionEffectiveAt(FundSubscription subscription) {
  final confirmation = subscription.confirmation;
  final paidAt = subscription.paidAt;
  if (confirmation == null || paidAt == null) return null;
  if (confirmation.accrualRule == FundAccrualRule.dealNavDate) {
    final end = hongKongFundDayEnd(confirmation.navDate);
    if (paidAt.isAfter(end)) {
      throw const FormatException('成交净值日规则暂不支持扣款晚于成交净值日，请核对实际成交记录');
    }
    return end;
  }
  final start = hongKongFundDayStart(confirmation.earningStartDate);
  return start.isBefore(paidAt) ? paidAt.toUtc() : start;
}

/// 读取 [portfolio] 在真实时刻 [at] 以前已经发生的基金付款/退款，含恰好等于截点的事实。
/// [securityId] 非空时只读取该基金。付款扣总金额（已含费用），退款只加实际退回金额；
/// 确认、预计确认或收益起算均不再次扣现金，撤销申请也不能假装退款已到账。
/// 返回按实际时刻、稳定 ID 排序的不可变列表；本函数不改原聚合，也不补造日常收支。
List<FundCashLeg> fundSubscriptionCashLegs(
  InvestmentPortfolio portfolio, {
  required DateTime at,
  String? securityId,
}) {
  final legs = <FundCashLeg>[];
  for (final subscription in portfolio.fundSubscriptions) {
    if (securityId != null && subscription.securityId != securityId) continue;
    final paidAt = subscription.paidAt;
    if (paidAt != null && !paidAt.isAfter(at)) {
      legs.add(
        FundCashLeg(
          id: 'fund:${subscription.id}:payment',
          occurredAt: paidAt.toUtc(),
          amount: -InvestmentDecimal.parse(subscription.cashAmount),
        ),
      );
    }
    final refundedAt = subscription.refundedAt;
    if (refundedAt != null && !refundedAt.isAfter(at)) {
      final amount = subscription.refundAmount;
      if (amount == null) throw const FormatException('实际基金退款缺少退款金额');
      legs.add(
        FundCashLeg(
          id: 'fund:${subscription.id}:refund',
          occurredAt: refundedAt.toUtc(),
          amount: InvestmentDecimal.parse(amount),
        ),
      );
    }
  }
  legs.sort((a, b) {
    final timeOrder = a.occurredAt.compareTo(b.occurredAt);
    return timeOrder == 0 ? a.id.compareTo(b.id) : timeOrder;
  });
  return List.unmodifiable(legs);
}

/// 计算 [portfolio] 在 [at] 的已付待确认、已确认待起算或待退款净申购款。
/// [securityId] 可限定一只基金。净款为总扣款减已发生费用，不采用当前净值估计在途资产；
/// 起算时转为份额，或实际退款时结清。在退款之前，即使申请已取消，也保留尚待退回的款项，
/// 不能提前把预计退款差额计成损失。纯读取不依赖现在的机器时间，便于重算同一历史时点。
InvestmentDecimal fundSubscriptionPendingValue(
  InvestmentPortfolio portfolio, {
  required DateTime at,
  String? securityId,
}) {
  var value = InvestmentDecimal.zero;
  for (final subscription in portfolio.fundSubscriptions) {
    if (securityId != null && subscription.securityId != securityId) continue;
    final paidAt = subscription.paidAt;
    if (paidAt == null || paidAt.isAfter(at)) continue;
    final refundedAt = subscription.refundedAt;
    if (refundedAt != null && !refundedAt.isAfter(at)) continue;
    final effectiveAt = fundSubscriptionEffectiveAt(subscription);
    if (effectiveAt != null && !effectiveAt.isAfter(at)) continue;
    value =
        value +
        InvestmentDecimal.parse(subscription.cashAmount) -
        InvestmentDecimal.parse(subscription.fee);
  }
  return value;
}

/// 完整校验 [portfolio] 的基金阶段事实和唯一持仓事件；失败抛出中文 FormatException。
/// 本流程只支持同币种香港基金，避免把香港日历强加于美国或内地基金。实际时刻必须有先后依据，
/// 预计日期只作提示；旧规则保留独立起算日，新规则只允许已核实基金并以成交净值日为基准。
/// 每笔确认必须关联唯一零现金 fundAcquire，总成本保留实际总扣款，不能用舍入后的量价替代。
/// 该函数不读取当前时间、不重放持仓、不修改数据；Controller 可在原子保存或备份恢复前调用。
void validateFundSubscriptions(InvestmentPortfolio portfolio) {
  final digits = CurrencyCatalog.require(portfolio.currencyCode).minorUnit;
  final securities = {
    for (final security in portfolio.securities) security.id: security,
  };
  final subscriptions = <String, FundSubscription>{};
  for (final subscription in portfolio.fundSubscriptions) {
    if (subscription.id.trim().isEmpty ||
        subscriptions.containsKey(subscription.id)) {
      throw const FormatException('基金申购 ID 为空或重复');
    }
    subscriptions[subscription.id] = subscription;
    _requireHongKongFund(securities[subscription.securityId], portfolio);
    final cash = _cashValue(subscription.cashAmount, digits, '申购总扣款');
    final fee = _cashValue(subscription.fee, digits, '申购费用');
    if (cash.units <= BigInt.zero ||
        fee.units < BigInt.zero ||
        fee.compareTo(cash) >= 0) {
      throw const FormatException('申购总扣款须大于零，费用须非负且小于总扣款');
    }
    if (subscription.requestedAt.isBefore(portfolio.openedAt)) {
      throw const FormatException('基金申购申请不能早于账户启用');
    }
    final requestedDay = hongKongFundDate(subscription.requestedAt);
    final paidAt = subscription.paidAt;
    if (paidAt != null && paidAt.isBefore(subscription.requestedAt)) {
      throw const FormatException('基金实际扣款不能早于申请');
    }
    final expected = subscription.expectedConfirmationDate;
    if (expected != null) {
      _requireCalendarDay(expected, '预计确认日');
      if (expected.isBefore(requestedDay)) {
        throw const FormatException('基金预计确认日不能早于申请日');
      }
    }
    final cancelledAt = subscription.cancelledAt;
    if (cancelledAt != null && cancelledAt.isBefore(subscription.requestedAt)) {
      throw const FormatException('基金取消时刻不能早于申请');
    }
    final confirmation = subscription.confirmation;
    if (confirmation != null &&
        (cancelledAt != null ||
            subscription.refundedAt != null ||
            subscription.refundAmount != null)) {
      throw const FormatException('已确认基金申购不能同时取消或退款');
    }
    final refundedAt = subscription.refundedAt;
    if ((refundedAt == null) != (subscription.refundAmount == null)) {
      throw const FormatException('基金实际退款时刻和退款金额必须同时填写');
    }
    if (refundedAt != null) {
      if (paidAt == null ||
          cancelledAt == null ||
          refundedAt.isBefore(paidAt) ||
          refundedAt.isBefore(cancelledAt)) {
        throw const FormatException('基金退款须有实际扣款和取消事实，且不能早于两者');
      }
      final refund = _cashValue(subscription.refundAmount!, digits, '基金实际退款');
      if (refund.units < BigInt.zero || refund.compareTo(cash) > 0) {
        throw const FormatException('基金实际退款不能为负或超过原总扣款');
      }
    }
    if (confirmation == null) continue;
    if (paidAt == null ||
        confirmation.confirmedAt.isBefore(paidAt) ||
        confirmation.confirmedAt.isBefore(subscription.requestedAt)) {
      throw const FormatException('基金确认须有实际扣款，且确认时刻不能早于申请或扣款');
    }
    _requireCalendarDay(confirmation.navDate, '确认净值日');
    _requireCalendarDay(confirmation.earningStartDate, '收益起算日');
    if (confirmation.accrualRule == FundAccrualRule.dealNavDate) {
      if (!supportsCmsDealNavAccrual(securities[subscription.securityId]!) ||
          confirmation.earningStartDate != confirmation.navDate) {
        throw const FormatException('成交净值日规则只支持已核实的招商美元基金 B 类，兼容起算日须等于成交净值日');
      }
      // 不能用 max(付款日, 净值日) 悄悄推迟权益，否则仍会把多日收益集中到付款日。
      fundSubscriptionEffectiveAt(subscription);
    }
    if (confirmation.navDate.isBefore(requestedDay) ||
        confirmation.navDate.isAfter(
          hongKongFundDate(confirmation.confirmedAt),
        ) ||
        confirmation.earningStartDate.isBefore(confirmation.navDate) ||
        confirmation.earningStartDate.isBefore(hongKongFundDate(paidAt))) {
      throw const FormatException('基金净值日或收益起算日的先后关系不合法');
    }
    final nav = _positiveValue(confirmation.nav, '确认净值');
    final quantity = _positiveValue(confirmation.quantity, '确认份额');
    quantity.moneyProduct(nav, digits).toDouble();
  }

  final acquiredOrders = <String>{};
  for (final event in portfolio.events) {
    final acquire = event.kind == StockEventKind.fundAcquire;
    final baseline = event.kind == StockEventKind.fundHoldingBaseline;
    if (!acquire && !baseline) {
      if (event.fundSubscriptionId != null ||
          event.reportedUnrealized != null ||
          event.fundNavDate != null ||
          event.quantityInferred) {
        throw const FormatException('普通股票、基金交易或期权不能携带基金确认/基准字段');
      }
      continue;
    }
    _requireHongKongFund(securities[event.securityId], portfolio);
    final quantity = _positiveValue(event.quantity, '基金持仓份额');
    final nav = _positiveValue(event.price, '基金持仓净值');
    final costText = event.carriedCost;
    if (costText == null) throw const FormatException('基金确认或持仓基准缺少总成本');
    final cost = _cashValue(costText, digits, '基金持仓总成本');
    if (cost.units < BigInt.zero ||
        InvestmentDecimal.parse(event.fee).units != BigInt.zero ||
        event.short ||
        event.batchId != null ||
        event.marginAfter != null ||
        event.settlementConfirmed ||
        event.allowUncoveredAssignment ||
        event.occurredAt.isBefore(portfolio.openedAt)) {
      throw const FormatException('基金确认/基准的费用、总成本、时刻或交易附加字段不合法');
    }
    final navDate = event.fundNavDate;
    if (navDate == null) throw const FormatException('基金确认或持仓基准缺少对应净值日');
    _requireCalendarDay(navDate, '基金持仓净值日');
    if (navDate.isAfter(hongKongFundDate(event.occurredAt))) {
      throw const FormatException('基金持仓净值日不能晚于经济生效日');
    }
    quantity.moneyProduct(nav, digits).toDouble();
    if (baseline) {
      if (event.fundSubscriptionId != null) {
        throw const FormatException('已有基金持仓基准不能关联申购扣款');
      }
      final reported = event.reportedUnrealized;
      if (reported != null) {
        final unrealized = _cashValue(
          reported,
          digits,
          '报告未实现盈亏',
          allowPlus: true,
        );
        final reportedValue = cost + unrealized;
        if (reportedValue.units <= BigInt.zero) {
          throw const FormatException('基金成本与报告未实现盈亏之和必须大于零');
        }
        reportedValue.toDouble();
      }
      continue;
    }
    final subscription = subscriptions[event.fundSubscriptionId];
    final confirmation = subscription?.confirmation;
    if (subscription == null ||
        confirmation == null ||
        !acquiredOrders.add(subscription.id)) {
      throw const FormatException('基金申购确认事件缺少申请、实际确认或发生重复');
    }
    final effectiveAt = fundSubscriptionEffectiveAt(subscription);
    if (event.securityId != subscription.securityId ||
        effectiveAt == null ||
        !event.occurredAt.isAtSameMomentAs(effectiveAt) ||
        quantity.compareTo(InvestmentDecimal.parse(confirmation.quantity)) !=
            0 ||
        nav.compareTo(InvestmentDecimal.parse(confirmation.nav)) != 0 ||
        cost.compareTo(InvestmentDecimal.parse(subscription.cashAmount)) != 0 ||
        navDate != confirmation.navDate ||
        event.reportedUnrealized != null) {
      throw const FormatException('基金申购确认事件与原申请的份额、净值、总成本或起算时刻不一致');
    }
    // 日级净值无法证明同一净值日内的真实核对是否已经包含该申购。
    // 使用与持仓重放相同的稳定顺序，连日末同刻但核对序号在先的边界也要拒绝，避免重复加份额。
    if (confirmation.accrualRule == FundAccrualRule.dealNavDate &&
        portfolio.events.any(
          (baseline) =>
              baseline.securityId == subscription.securityId &&
              baseline.kind == StockEventKind.fundHoldingBaseline &&
              hongKongFundDate(baseline.occurredAt) == confirmation.navDate &&
              compareStockEvents(baseline, event) < 0,
        )) {
      throw const FormatException('成交净值日内已有持仓核对基准，无法确认是否已包含该申购，请先核对记录');
    }
  }
  for (final subscription in subscriptions.values) {
    if (subscription.confirmation != null &&
        !acquiredOrders.contains(subscription.id)) {
      throw const FormatException('已确认基金申购缺少唯一持仓生效事件');
    }
  }
}

/// 校验 [security] 为聚合 [portfolio] 内的同币种香港基金；不会按名字或代码猜基金类型。
void _requireHongKongFund(
  StockSecurity? security,
  InvestmentPortfolio portfolio,
) {
  if (security == null ||
      !security.isFund ||
      security.option != null ||
      security.market != StockMarket.hk ||
      security.currencyCode != portfolio.currencyCode) {
    throw const FormatException('基金申购和持仓基准只支持账户内同币种香港基金');
  }
}

/// 读取 [text] 的精确原币金额，按 [digits] 拒绝超出最小现金单位的实值；等值尾零允许。
/// [label] 用于指出错误字段，[allowPlus] 仅用于用户报告的带正号浮盈，不改变存储数值。
InvestmentDecimal _cashValue(
  String text,
  int digits,
  String label, {
  bool allowPlus = false,
}) {
  final value = text.trim();
  final amount = InvestmentDecimal.parse(
    allowPlus && value.startsWith('+') ? value.substring(1) : value,
  );
  if (amount.compareTo(amount.rounded(digits)) != 0) {
    throw FormatException('$label 超出账户币种的现金精度');
  }
  amount.toDouble();
  return amount;
}

/// 读取必须大于零的八位精确 [text]；[label] 区分份额与净值，不经 double 计算。
InvestmentDecimal _positiveValue(String text, String label) {
  final value = InvestmentDecimal.parse(text);
  if (value.units <= BigInt.zero) throw FormatException('$label 必须大于零');
  return value;
}

/// 校验 [day] 为香港年月日的规范 UTC 零点载体；[label] 用于指出哪个日期需要用户修正。
void _requireCalendarDay(DateTime day, String label) {
  if (!isCanonicalFundDate(day)) throw FormatException('$label 必须是有效的香港纯日期');
}
