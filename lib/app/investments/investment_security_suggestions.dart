/// 证券代码输入的本地候选；只整理已存在的身份，不联网、不创建证券或交易。
library;

import '../models/investment.dart';

/// 一项证券身份建议；参考价只能来自正在录入的同一账户。
class InvestmentSecuritySuggestion {
  /// [security] 是代码、名称、市场、品种与结算币种；[referencePrice] 只允许填入
  /// 当前账户原本保存的后备价，其他账户或联网搜索返回的报价不得放进这里。
  /// [matchedQuery] 保留远端已匹配的查询词，以支持不直接出现在代码/名称中的拼音。
  const InvestmentSecuritySuggestion({
    required this.security,
    this.referencePrice,
    this.matchedQuery,
  });

  final StockSecurity security;
  final String? referencePrice;

  /// 远端已经匹配的原查询词，例如拼音缩写；不据此改变证券代码或名称。
  final String? matchedQuery;
}

/// 收集相同账本、币种、市场和品种的已录入证券，当前账户资料优先。
///
/// [portfolios] 是调用方通过 Controller 只读 API 得到的组合；[bookId]、
/// [accountId]、[currencyCode] 固定当前草稿上下文，[market] 与 [type] 是用户
/// 已选择的筛选条件。期权使用独立合约选择器，不混入普通股票或基金候选。
/// 身份按“市场、品种、大小写归一后的原代码”去重，港股前导零保持原样。
/// [remoteSecurities] 只接收用户主动查询得到的身份，[remoteQuery] 是该次原查询词；
/// 远端同名项仍优先保留当前账户资料，任何远端价格都不会进入结果。
List<InvestmentSecuritySuggestion> collectInvestmentSecuritySuggestions({
  required Iterable<InvestmentPortfolio> portfolios,
  required String bookId,
  required String accountId,
  required String currencyCode,
  required StockMarket market,
  required InvestmentSecurityType type,
  Iterable<StockSecurity> remoteSecurities = const [],
  String? remoteQuery,
}) {
  final eligible = portfolios
      .where((p) => p.bookId == bookId && p.currencyCode == currencyCode)
      .toList();
  final ordered = [
    ...eligible.where((p) => p.accountId == accountId),
    ...eligible.where((p) => p.accountId != accountId),
  ];
  final result = <String, InvestmentSecuritySuggestion>{};
  for (final portfolio in ordered) {
    for (final security in portfolio.securities) {
      if (security.option != null ||
          security.market != market ||
          security.type != type ||
          security.currencyCode != currencyCode) {
        continue;
      }
      final identity =
          '${security.market.name}:${security.type.name}:${security.symbol.toUpperCase()}';
      result.putIfAbsent(
        identity,
        () => InvestmentSecuritySuggestion(
          security: security,
          referencePrice: portfolio.accountId == accountId
              ? portfolio.manualPrices[security.id]
              : null,
        ),
      );
    }
  }
  for (final security in remoteSecurities) {
    if (security.option != null ||
        security.market != market ||
        security.type != type ||
        security.currencyCode != currencyCode) {
      continue;
    }
    final identity =
        '${security.market.name}:${security.type.name}:${security.symbol.toUpperCase()}';
    final local = result[identity];
    result[identity] = InvestmentSecuritySuggestion(
      security: local?.security ?? security,
      referencePrice: local?.referencePrice,
      matchedQuery: remoteQuery,
    );
  }
  return result.values.toList(growable: false);
}

/// 按用户输入的代码或名称做大小写无关包含匹配，不改变原候选优先顺序。
/// [query] 会去掉首尾空白；空输入返回完整本地候选，未命中返回空列表，
/// 由输入组件保留自由手填能力，不把未命中视作保存错误。
List<InvestmentSecuritySuggestion> matchInvestmentSecuritySuggestions(
  Iterable<InvestmentSecuritySuggestion> suggestions,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  return suggestions
      .where(
        (suggestion) =>
            suggestion.security.symbol.toLowerCase().contains(normalized) ||
            suggestion.security.name.toLowerCase().contains(normalized) ||
            suggestion.matchedQuery?.trim().toLowerCase() == normalized,
      )
      .toList(growable: false);
}
