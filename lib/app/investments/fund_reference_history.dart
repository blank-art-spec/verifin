/// 香港基金净值日的只读收益与账户资产推演，不联网、不写交易或历史快照。
library;

import '../currency_catalog.dart';
import '../models.dart';
import 'investment_decimal.dart';
import 'investment_valuation.dart';
import 'market_quote.dart';
import 'stock_projection.dart';
import 'fund_workflow_math.dart';

/// 一个来源实际公布净值日的参考结果；所有金额沿用账户原币，不做汇率换算。
class FundReferenceDay {
  /// [date] 是 UTC 年月日载体，表示香港净值日期而非零点报价；[nav] 为每份净值，
  /// [quantity] 为该香港日日末持有份额，[marketValue] 按账户现金精度舍入。
  /// [dailyProfit] 是与上个可观察净值日之间、剔除买卖净投入并计入分红费用的收益；
  /// 首点或区间发生持仓转移时为 null，不能把多日区间冒充单个自然日收益。
  /// [cumulativeProfit] 按已实现、净分红费用和未实现合计，未知成本时为 null。
  /// [profitFromDate] 为上一实际公布净值日，和 [date] 组成完整观察区间；首点无区间。
  /// [subscriptionAdjustment] 是同一区间内申购费用、确认量价差及退款差额，已包含在
  /// [dailyProfit] 中，只供分项说明，不能再次加减或冒充正常净值增长。
  /// [cash] 复用账户历史现金；其余账户金额只有全部持仓具有当日价格依据时才存在，
  /// 否则 [missingSecurityIds] 列出缺价持仓，基金自身的参考市值仍可独立显示。
  FundReferenceDay({
    required this.date,
    required this.nav,
    required this.quantity,
    required this.marketValue,
    required this.dailyProfit,
    required this.cumulativeProfit,
    required this.cash,
    required this.accountAssets,
    required this.accountLiabilities,
    required this.accountNetValue,
    required Set<String> missingSecurityIds,
    InvestmentDecimal? pendingSubscriptionValue,
    this.profitFromDate,
    this.subscriptionAdjustment,
  }) : pendingSubscriptionValue =
           pendingSubscriptionValue ?? InvestmentDecimal.zero,
       missingSecurityIds = Set.unmodifiable(missingSecurityIds);

  final DateTime date;
  final DateTime? profitFromDate;
  final InvestmentDecimal nav, quantity, marketValue;

  /// 已实际付款但尚未起算或待实际退款的本基金资产；不参与份额与净值乘积。
  final InvestmentDecimal pendingSubscriptionValue;
  final InvestmentDecimal? dailyProfit, cumulativeProfit;
  final InvestmentDecimal? subscriptionAdjustment;
  final double cash;
  final double? accountAssets, accountLiabilities, accountNetValue;
  final Set<String> missingSecurityIds;
}

/// 依据真实投资事实和来源历史净值，生成香港各公布净值日日末的参考结果。
///
/// [portfolio] 提供期初、交易、成本及用户主动保存的历史依据；[security] 必须是该
/// 聚合中同币种的香港基金，[history] 只含来源实际公布的 UTC 纯日期和正净值。
/// [account] 必须对应同一账本、账户与结算币种；[entries]、[anchors] 可含其他账户，
/// 历史现金入口会按账户隔离并仅使用当日已生效的交易和现金锚点。
///
/// 每点截在香港 23:59:59.999999，不取开仓前的点，不补造周末或来源缺失日期。
/// 净值日期不等于发布时刻；本函数不依赖设备时区或当前时钟。买卖、分红和费用的
/// 现金腿均从既有精确重放读取；转入/转出的份额不是收益，发生转移的区间明确未知。
///
/// 本基金使用对应日的来源净值；其他持仓只采用香港同日、修订在保存时及日日末均
/// 有效、且价格自身也来自该日的用户历史依据。绝不回退当前手填价、当前股票行情或
/// 其他日期的快照。结果不可变，仅作参考，不生成 LedgerEntry 或权威资产快照。
List<FundReferenceDay> buildFundReferenceHistory({
  required InvestmentPortfolio portfolio,
  required StockSecurity security,
  required FundNavHistory history,
  required Account account,
  required List<LedgerEntry> entries,
  required List<BalanceAnchor> anchors,
}) {
  if (!security.isFund ||
      security.option != null ||
      security.market != StockMarket.hk ||
      security.currencyCode != portfolio.currencyCode ||
      !portfolio.securities.any((value) => value.id == security.id) ||
      account.id != portfolio.accountId ||
      account.bookId != portfolio.bookId ||
      account.currencyCode != portfolio.currencyCode ||
      !account.type.supportsSecurities) {
    throw const FormatException('基金参考历史的证券、账户或结算币种不一致');
  }
  final digits = CurrencyCatalog.require(portfolio.currencyCode).minorUnit;
  final publishedNavs = {
    for (final point in history.points)
      point.date: InvestmentDecimal.parse(point.price),
  };
  final result = <FundReferenceDay>[];
  DateTime? previousCutoff;
  InvestmentDecimal? previousCapitalValue;
  final baselines =
      portfolio.events
          .where(
            (event) =>
                event.securityId == security.id &&
                event.kind == StockEventKind.fundHoldingBaseline,
          )
          .toList()
        ..sort(compareStockEvents);
  final firstBaseline = baselines.firstOrNull;
  final hasFactsBeforeBaseline =
      firstBaseline == null ||
      portfolio.openingHoldings.any((h) => h.securityId == security.id) ||
      portfolio.events.any(
        (event) =>
            event.securityId == security.id &&
            event.occurredAt.isBefore(firstBaseline.occurredAt),
      ) ||
      portfolio.fundSubscriptions.any(
        (subscription) =>
            subscription.securityId == security.id &&
            subscription.paidAt != null &&
            subscription.paidAt!.isBefore(firstBaseline.occurredAt),
      );
  for (final point in history.points) {
    final cutoff = hongKongFundDayEnd(point.date);
    if (cutoff.isBefore(portfolio.openedAt)) continue;
    // 第一次录入已有持仓不等于此前持仓为零；没有更早事实时，不给开户日至基准日补造历史。
    if (!hasFactsBeforeBaseline && cutoff.isBefore(firstBaseline.occurredAt)) {
      continue;
    }
    final past = investmentAt(portfolio, cutoff);
    final baseline = baselines
        .where((event) => !event.occurredAt.isAfter(cutoff))
        .lastOrNull;
    final fund = _fundProjection(
      past,
      security,
      at: cutoff,
      baseline: baseline,
    );
    final position = fund.positions
        .where((value) => value.securityId == security.id && !value.short)
        .firstOrNull;
    final quantity = position?.quantity ?? InvestmentDecimal.zero;
    final nav = InvestmentDecimal.parse(point.price);
    final marketValue = securityPositionValue(security, quantity, nav, digits);
    final pending = fundSubscriptionPendingValue(
      past,
      at: cutoff,
      securityId: security.id,
    );
    final capitalValue = marketValue + pending;
    final intervalEvents = past.events.where(
      (event) =>
          event.securityId == security.id &&
          previousCutoff != null &&
          event.occurredAt.isAfter(previousCutoff),
    );
    final hasTransfer = intervalEvents.any(
      (event) =>
          event.kind == StockEventKind.transferIn ||
          event.kind == StockEventKind.transferOut,
    );
    final hasBaseline = intervalEvents.any(
      (event) => event.kind == StockEventKind.fundHoldingBaseline,
    );
    InvestmentDecimal? dailyProfit;
    if (previousCapitalValue != null && !hasTransfer && !hasBaseline) {
      var movement = intervalEvents.fold<InvestmentDecimal>(
        InvestmentDecimal.zero,
        (sum, event) => sum + fund.cashMovements[event.id]!,
      );
      for (final leg in fundSubscriptionCashLegs(
        past,
        at: cutoff,
        securityId: security.id,
      )) {
        if (leg.occurredAt.isAfter(previousCutoff!)) {
          movement = movement + leg.amount;
        }
      }
      // 本金转为在途或确认份额不产生收益；已知费用和量价/退款差额仍计入净投资盈亏，
      // 并由独立分项解释，不能将截位损益当作净值正常增长或再加一笔利息。
      dailyProfit = capitalValue - previousCapitalValue + movement;
    }
    final cost = position?.cost;
    final cumulativeProfit =
        fund.realizedComplete && (position == null || cost != null)
        ? fund.realized +
              fund.income +
              marketValue -
              (cost ?? InvestmentDecimal.zero) +
              _subscriptionProfitAdjustment(
                past,
                security,
                cutoff,
                baseline?.occurredAt,
              )
        : null;
    final cash = accountCashAt(
      account: account,
      entries: entries,
      anchors: anchors,
      at: cutoff,
      portfolio: portfolio,
    );
    final held = projectStocks(past, at: cutoff).positions;
    final otherIds = held
        .where((value) => value.securityId != security.id)
        .map((value) => value.securityId)
        .toSet();
    final historicalPrices = _otherHistoricalPrices(
      portfolio: portfolio,
      date: point.date,
      cutoff: cutoff,
      securityIds: otherIds,
      entries: entries,
      anchors: anchors,
    );
    final missing = otherIds.difference(historicalPrices.keys.toSet());
    final valuation = missing.isEmpty
        ? valueInvestmentAccount(
            past.copyWith(
              manualPrices: {security.id: point.price, ...historicalPrices},
            ),
            cash,
            at: cutoff,
          ).amounts
        : null;
    result.add(
      FundReferenceDay(
        date: point.date,
        nav: nav,
        quantity: quantity,
        marketValue: marketValue,
        pendingSubscriptionValue: pending,
        profitFromDate: result.lastOrNull?.date,
        subscriptionAdjustment: dailyProfit == null
            ? null
            : _intervalSubscriptionAdjustment(
                past,
                security,
                previousCutoff!,
                cutoff,
                digits,
                publishedNavs,
              ),
        dailyProfit: dailyProfit,
        cumulativeProfit: cumulativeProfit,
        cash: cash,
        accountAssets: valuation?.assets,
        accountLiabilities: valuation?.liabilities,
        accountNetValue: valuation?.net,
        missingSecurityIds: missing,
      ),
    );
    previousCutoff = cutoff;
    previousCapitalValue = capitalValue;
  }
  return List.unmodifiable(result);
}

/// 计算本基金在观察区间 ([from], [to]] 内已计入净盈亏的申购费用和结算差额。
/// [portfolio] 为历史截点聚合，[digits] 是账户现金精度；付款时列已知费用，确认时
/// 列新增份额带来的合并持仓市值增量相对净申购额的差额，退款时列实退额相对净款的差额。
/// [publishedNavs] 仅包含真实公开来源点；新规则在成交日有公开净值时据其区分发行价差，
/// 缺失时仅列已知成交价与份额尾差，不补造该日净值，也不假装已经拆出未知的发行价差。
/// 各阶段只计算一次，保留真实总成本；此分项不另写现金、收入或来源净值历史。
InvestmentDecimal _intervalSubscriptionAdjustment(
  InvestmentPortfolio portfolio,
  StockSecurity security,
  DateTime from,
  DateTime to,
  int digits,
  Map<DateTime, InvestmentDecimal> publishedNavs,
) {
  var adjustment = InvestmentDecimal.zero;
  for (final subscription in portfolio.fundSubscriptions) {
    if (subscription.securityId != security.id) continue;
    final paidAt = subscription.paidAt;
    if (paidAt == null || paidAt.isAfter(to)) continue;
    final cash = InvestmentDecimal.parse(subscription.cashAmount);
    final fee = InvestmentDecimal.parse(subscription.fee);
    final net = cash - fee;
    if (paidAt.isAfter(from)) adjustment = adjustment - fee;
    final refundedAt = subscription.refundedAt;
    if (refundedAt != null &&
        refundedAt.isAfter(from) &&
        !refundedAt.isAfter(to)) {
      adjustment =
          adjustment +
          InvestmentDecimal.parse(subscription.refundAmount!) -
          net;
    }
    final effectiveAt = fundSubscriptionEffectiveAt(subscription);
    if (effectiveAt != null &&
        effectiveAt.isAfter(from) &&
        !effectiveAt.isAfter(to)) {
      final confirmation = subscription.confirmation!;
      final acquisition = portfolio.events.firstWhere(
        (event) =>
            event.kind == StockEventKind.fundAcquire &&
            event.fundSubscriptionId == subscription.id,
      );
      // 与完整市值一致，先按稳定事件顺序取新增前数量，再对合并市值舍入。
      // 逐笔量价各自舍入后相加，在两笔半分等边界会凭空产生或漏掉一分结算差额。
      final before =
          _fundProjection(
                portfolio.copyWith(
                  events: [
                    for (final event in portfolio.events)
                      if (compareStockEvents(event, acquisition) < 0) event,
                  ],
                ),
                security,
                at: effectiveAt,
              ).positions
              .where((p) => p.securityId == security.id && !p.short)
              .firstOrNull;
      final oldQuantity = before?.quantity ?? InvestmentDecimal.zero;
      final newQuantity =
          oldQuantity + InvestmentDecimal.parse(confirmation.quantity);
      final dealNav = confirmation.accrualRule == FundAccrualRule.dealNavDate
          ? publishedNavs[confirmation.navDate] ??
                InvestmentDecimal.parse(confirmation.nav)
          : InvestmentDecimal.parse(confirmation.nav);
      adjustment =
          adjustment +
          newQuantity.moneyProduct(dealNav, digits) -
          oldQuantity.moneyProduct(dealNav, digits) -
          net;
    }
  }
  return adjustment;
}

/// 取得真实时刻 [instant] 在香港的日历日期；返回 UTC 日期载体供字段比较。
/// 香港为固定 UTC+8；八小时是时区偏移，不是按绝对时长推算日历天数。
DateTime _hongKongDate(DateTime instant) {
  final local = instant.toUtc().add(const Duration(hours: 8));
  return DateTime.utc(local.year, local.month, local.day);
}

/// 只重放 [security] 的持仓、现金腿和已实现盈亏，避免把其他股票的成本混入基金收益。
/// [past] 已按日日末截断；清空无关价格、选择和快照，原聚合及其集合不会被修改。
StockProjection _fundProjection(
  InvestmentPortfolio past,
  StockSecurity security, {
  required DateTime at,
  StockEvent? baseline,
}) => projectStocks(
  past.copyWith(
    securities: [security],
    openingHoldings: past.openingHoldings
        .where((value) => value.securityId == security.id && baseline == null)
        .toList(),
    events: past.events
        .where(
          (value) =>
              value.securityId == security.id &&
              (baseline == null || compareStockEvents(value, baseline) >= 0),
        )
        .toList(),
    fundSubscriptions: past.fundSubscriptions
        .where((s) => s.securityId == security.id)
        .toList(),
    manualPrices: const {},
    marketPriceIds: const {},
    valuationSnapshots: const [],
  ),
  at: at,
);

/// 把尚未进入确认份额成本的费用及已完成退款的实际差额纳入参考累计盈亏。
/// [baselineAt] 之前已经结清的费用不跨新持仓基准重复累加；未结清申购只确认已明确的费用，
/// 不能把尚在等待退款的本金当成损失。起算后总成本已包含费用，因此本函数不再重复扣费。
InvestmentDecimal _subscriptionProfitAdjustment(
  InvestmentPortfolio portfolio,
  StockSecurity security,
  DateTime at,
  DateTime? baselineAt,
) {
  var result = InvestmentDecimal.zero;
  for (final subscription in portfolio.fundSubscriptions.where(
    (s) => s.securityId == security.id,
  )) {
    if (subscription.paidAt == null || subscription.paidAt!.isAfter(at)) {
      continue;
    }
    final effectiveAt = fundSubscriptionEffectiveAt(subscription);
    if (effectiveAt != null && !effectiveAt.isAfter(at)) continue;
    if (subscription.refundedAt != null &&
        !subscription.refundedAt!.isAfter(at)) {
      if (baselineAt == null ||
          !subscription.refundedAt!.isBefore(baselineAt)) {
        result =
            result +
            InvestmentDecimal.parse(subscription.refundAmount!) -
            InvestmentDecimal.parse(subscription.cashAmount);
      }
    } else {
      result = result - InvestmentDecimal.parse(subscription.fee);
    }
  }
  return result;
}

/// 为 [securityIds] 读取香港净值日 [date] 的用户历史价格，绝不读取当前后备价。
/// [cutoff] 是该日日末，[entries]/[anchors] 用于核对保存时和日日末的事实修订；
/// 同日后续补录或交易改变事实时，旧快照不再作为完整账户资产的依据。
Map<String, String> _otherHistoricalPrices({
  required InvestmentPortfolio portfolio,
  required DateTime date,
  required DateTime cutoff,
  required Set<String> securityIds,
  required List<LedgerEntry> entries,
  required List<BalanceAnchor> anchors,
}) {
  if (securityIds.isEmpty) return const {};
  final candidates =
      portfolio.valuationSnapshots
          .where(
            (snapshot) =>
                !snapshot.capturedAt.isAfter(cutoff) &&
                _hongKongDate(snapshot.capturedAt) == date,
          )
          .toList()
        ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  if (candidates.isEmpty) return const {};
  final endRevision = investmentRevision(portfolio, entries, anchors, cutoff);
  final snapshot = candidates
      .where(
        (value) =>
            value.revision == endRevision &&
            value.revision ==
                investmentRevision(
                  portfolio,
                  entries,
                  anchors,
                  value.capturedAt,
                ),
      )
      .firstOrNull;
  if (snapshot == null) return const {};
  final prices = <String, String>{};
  for (final id in securityIds) {
    final fact = snapshot.prices[id];
    if (fact == null ||
        (!fact.manual && fact.source.isEmpty) ||
        (fact.dateOnly && !isCanonicalQuoteDate(fact.quotedAt)) ||
        (fact.dateOnly ? fact.quotedAt : _hongKongDate(fact.quotedAt)) !=
            date) {
      continue;
    }
    try {
      final value = InvestmentDecimal.parse(fact.price);
      if (value.units < BigInt.zero) continue;
      value.toDouble();
      prices[id] = value.toString();
    } on FormatException {
      // 历史价格依据无效时仅标记缺价；纯计算不能补零、写日志敏感正文或改动快照。
    }
  }
  return prices;
}
