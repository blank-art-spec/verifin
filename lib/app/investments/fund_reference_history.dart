/// 香港基金净值日的只读收益与账户资产推演，不联网、不写交易或历史快照。
library;

import '../currency_catalog.dart';
import '../models.dart';
import 'investment_decimal.dart';
import 'investment_valuation.dart';
import 'market_quote.dart';
import 'stock_projection.dart';

/// 一个来源实际公布净值日的参考结果；所有金额沿用账户原币，不做汇率换算。
class FundReferenceDay {
  /// [date] 是 UTC 年月日载体，表示香港净值日期而非零点报价；[nav] 为每份净值，
  /// [quantity] 为该香港日日末持有份额，[marketValue] 按账户现金精度舍入。
  /// [dailyProfit] 是与上个可观察净值日之间、剔除买卖净投入并计入分红费用的收益；
  /// 首点或区间发生持仓转移时为 null，不能把多日区间冒充单个自然日收益。
  /// [cumulativeProfit] 按已实现、净分红费用和未实现合计，未知成本时为 null。
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
  }) : missingSecurityIds = Set.unmodifiable(missingSecurityIds);

  final DateTime date;
  final InvestmentDecimal nav, quantity, marketValue;
  final InvestmentDecimal? dailyProfit, cumulativeProfit;
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
  final result = <FundReferenceDay>[];
  DateTime? previousCutoff;
  InvestmentDecimal? previousMarketValue;
  for (final point in history.points) {
    final cutoff = _hongKongDayEnd(point.date);
    if (cutoff.isBefore(portfolio.openedAt)) continue;
    final past = investmentAt(portfolio, cutoff);
    final fund = _fundProjection(past, security);
    final position = fund.positions
        .where((value) => value.securityId == security.id && !value.short)
        .firstOrNull;
    final quantity = position?.quantity ?? InvestmentDecimal.zero;
    final nav = InvestmentDecimal.parse(point.price);
    final marketValue = securityPositionValue(security, quantity, nav, digits);
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
    InvestmentDecimal? dailyProfit;
    if (previousMarketValue != null && !hasTransfer) {
      final movement = intervalEvents.fold<InvestmentDecimal>(
        InvestmentDecimal.zero,
        (sum, event) => sum + fund.cashMovements[event.id]!,
      );
      dailyProfit = marketValue - previousMarketValue + movement;
    }
    final cost = position?.cost;
    final cumulativeProfit =
        fund.realizedComplete && (position == null || cost != null)
        ? fund.realized +
              fund.income +
              marketValue -
              (cost ?? InvestmentDecimal.zero)
        : null;
    final cash = accountCashAt(
      account: account,
      entries: entries,
      anchors: anchors,
      at: cutoff,
      portfolio: portfolio,
    );
    final held = projectStocks(past).positions;
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
          ).amounts
        : null;
    result.add(
      FundReferenceDay(
        date: point.date,
        nav: nav,
        quantity: quantity,
        marketValue: marketValue,
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
    previousMarketValue = marketValue;
  }
  return List.unmodifiable(result);
}

/// 将 UTC 纯日期 [date] 换成香港当日最后一个微秒，边界不随设备时区变化。
/// 这里构造日历字段，不使用二十四小时绝对时长表达日历日增减。
DateTime _hongKongDayEnd(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day, 15, 59, 59, 999, 999);

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
  StockSecurity security,
) => projectStocks(
  past.copyWith(
    securities: [security],
    openingHoldings: past.openingHoldings
        .where((value) => value.securityId == security.id)
        .toList(),
    events: past.events
        .where((value) => value.securityId == security.id)
        .toList(),
    manualPrices: const {},
    marketPriceIds: const {},
    valuationSnapshots: const [],
  ),
);

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
