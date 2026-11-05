/// 证券期初列表的临时草稿与纯组装；保存前不创建账户、交易或现金流水。
library;

import 'dart:convert';

import '../models.dart';
import 'investment_decimal.dart';
import 'stock_projection.dart';

/// 一项已持有证券；期权总成本与权利金报价分别保留，不混用乘数。
class InvestmentOpeningHolding {
  const InvestmentOpeningHolding({
    required this.security,
    required this.holding,
    required this.referencePrice,
    this.underlying,
    this.underlyingPrice,
    this.frozenMargin,
  });

  final StockSecurity security;
  final StockHolding holding;
  final String referencePrice;
  final StockSecurity? underlying;
  final String? underlyingPrice, frozenMargin;

  /// 只用于父表单比较未保存草稿，不改变持久化或备份格式。
  Map<String, Object?> toJson() => {
    'security': security.toJson(),
    'holding': holding.toJson(),
    'referencePrice': referencePrice,
    'underlying': underlying?.toJson(),
    'underlyingPrice': underlyingPrice,
    'frozenMargin': frozenMargin,
  };
}

/// 多项表单中需要用户明确处理的冲突，不静默合并数量或覆盖另一行。
enum InvestmentOpeningIssue {
  duplicateHolding,
  conflictingSecurity,
  conflictingReference,
  conflictingMargin,
}

class InvestmentOpeningConflict implements Exception {
  const InvestmentOpeningConflict(this.issue);
  final InvestmentOpeningIssue issue;
}

/// 将每合约冻结额表示为期初时刻的保证金核对；只冻结，不产生资金变动。
/// [securities] 与 [holdings] 必须包含该期权，不能给无持仓或股票写期权保证金。
List<StockEvent> investmentOpeningMarginEvents({
  required DateTime openedAt,
  required List<StockSecurity> securities,
  required List<StockHolding> holdings,
  required Map<String, String> margins,
}) {
  final events = <StockEvent>[];
  for (final entry in margins.entries) {
    if (!securities.any((s) => s.id == entry.key && s.option != null) ||
        !holdings.any((h) => h.securityId == entry.key)) {
      throw const FormatException('期初保证金必须对应已录入的期权持仓');
    }
    events.add(
      StockEvent(
        id: 'opening-margin:${entry.key}',
        securityId: entry.key,
        kind: StockEventKind.optionMargin,
        occurredAt: openedAt,
        sequence: events.length,
        quantity: '0',
        price: '0',
        fee: '0',
        marginAfter: entry.value,
      ),
    );
  }
  return events;
}

/// 以所有期初条目重新组装候选，保留账户层的现金与时间，不从旧交易推断期初。
/// 同一证券可有多空两行；它们共用合约、报价与冻结额，矛盾输入明确拒绝。
InvestmentPortfolio composeInvestmentOpening({
  required InvestmentPortfolio base,
  required List<InvestmentOpeningHolding> holdings,
}) {
  final securities = <String, StockSecurity>{};
  final prices = <String, String>{};
  final underlyingPrices = <String, String>{};
  final margins = <String, String>{};
  final directions = <String>{};

  void mergeNumber(
    Map<String, String> values,
    String id,
    String text,
    InvestmentOpeningIssue issue,
  ) {
    final value = InvestmentDecimal.parse(text);
    if (value.units < BigInt.zero) {
      throw const FormatException('期初参考价或冻结额不能为负');
    }
    value.toDouble();
    if (values.containsKey(id) &&
        InvestmentDecimal.parse(values[id]!).compareTo(value) != 0) {
      throw InvestmentOpeningConflict(issue);
    }
    values[id] = value.toString();
  }

  void mergeSecurity(StockSecurity security, {bool underlying = false}) {
    if (security.currencyCode != base.currencyCode) {
      throw const FormatException('期初证券币种与账户不一致');
    }
    final old = securities[security.id];
    if (old != null &&
        (old.type != security.type ||
            jsonEncode(old.option?.toJson()) !=
                jsonEncode(security.option?.toJson()))) {
      throw const InvestmentOpeningConflict(
        InvestmentOpeningIssue.conflictingSecurity,
      );
    }
    // 标的定义只补缺，不覆盖用户独立录入的股票名称。
    if (!underlying || old == null) securities[security.id] = security;
  }

  for (final item in holdings) {
    final security = item.security;
    if (item.holding.securityId != security.id) {
      throw const FormatException('期初持仓与证券身份不一致');
    }
    if (!directions.add('${security.id}:${item.holding.short}')) {
      throw const InvestmentOpeningConflict(
        InvestmentOpeningIssue.duplicateHolding,
      );
    }
    mergeSecurity(security);
    mergeNumber(
      prices,
      security.id,
      item.referencePrice,
      InvestmentOpeningIssue.conflictingReference,
    );
    if (item.underlying case final underlying?) {
      if (security.option?.underlyingId != underlying.id ||
          !underlying.isStock) {
        throw const FormatException('期权标的与合约不一致');
      }
      mergeSecurity(underlying, underlying: true);
      if (item.underlyingPrice case final price?) {
        mergeNumber(
          underlyingPrices,
          underlying.id,
          price,
          InvestmentOpeningIssue.conflictingReference,
        );
      }
    }
    if (item.frozenMargin case final margin?) {
      mergeNumber(
        margins,
        security.id,
        margin,
        InvestmentOpeningIssue.conflictingMargin,
      );
    }
  }
  // 已有股票条目的参考价为显式依据；期权标的的可选价仅补充没有持仓的标的。
  for (final entry in underlyingPrices.entries) {
    prices.putIfAbsent(entry.key, () => entry.value);
  }
  final opening = holdings.map((h) => h.holding).toList();
  final result = base.copyWith(
    securities: securities.values.toList(),
    openingHoldings: opening,
    manualPrices: prices,
    events: investmentOpeningMarginEvents(
      openedAt: base.openedAt,
      securities: securities.values.toList(),
      holdings: opening,
      margins: margins,
    ),
  );
  final projection = projectStocks(result);
  final valuation = valueStocks(result, projection);
  if (valuation.marketValue == null) {
    throw const FormatException('期初持仓须填写有效参考价');
  }
  valuation.marketValue!.toDouble();
  valuation.unrealized?.toDouble();
  projection.frozenMargin.toDouble();
  for (final position in projection.positions) {
    position.cost?.toDouble();
  }
  return result;
}
