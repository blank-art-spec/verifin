/// 持仓列表的只读展示排序；不改变交易重放顺序、成本或账户聚合。
library;

import '../../l10n/app_localizations.dart';
import '../models/investment.dart';
import 'stock_projection.dart';

/// 页面可选择的持仓排序口径；默认顺序沿用投影原顺序。
enum InvestmentPositionSortOrder {
  original,
  marketValueDesc,
  marketValueAsc,
  unrealizedDesc,
  unrealizedAsc;

  /// 返回当前排序的完整本地化名称，供菜单选项和触发按钮共用。
  /// [l] 是当前页面语言；升降序直接包含在名称中，避免只靠箭头表达方向。
  String label(AppLocalizations l) => switch (this) {
    original => l.investSortOriginal,
    marketValueDesc => l.investSortMarketValueDesc,
    marketValueAsc => l.investSortMarketValueAsc,
    unrealizedDesc => l.investSortUnrealizedDesc,
    unrealizedAsc => l.investSortUnrealizedAsc,
  };
}

/// 按 [order] 返回 [positions] 的排序副本，原列表及每项数量、成本均不修改。
///
/// [portfolio] 必须与持仓来自同一账户，并已由调用方选好当前有效参考价，
/// 这样列表顺序与持仓卡的市值、未实现盈亏保持相同口径。股票、基金和期权
/// 共用 [valueStockPosition]；市值排序中的空头采用正的回补义务金额，盈亏
/// 则保留真实正负号，不按绝对值排列。所有比较使用精确十进制数。
///
/// 缺价格或成本导致当前排序金额未知时，无论升序还是降序都放在已知值后面；
/// 金额相等或双方均未知时按输入索引保持稳定顺序。原顺序模式只复制列表，
/// 不计算估值，也不因缺少报价而影响显示。返回列表中的持仓对象仍为只读引用。
List<StockPosition> sortedInvestmentPositions(
  InvestmentPortfolio portfolio,
  Iterable<StockPosition> positions,
  InvestmentPositionSortOrder order,
) {
  final source = positions.toList();
  if (order == InvestmentPositionSortOrder.original) return source;
  final byMarketValue =
      order == InvestmentPositionSortOrder.marketValueDesc ||
      order == InvestmentPositionSortOrder.marketValueAsc;
  final descending =
      order == InvestmentPositionSortOrder.marketValueDesc ||
      order == InvestmentPositionSortOrder.unrealizedDesc;
  // 每项只估值一次；排序比较器只读取缓存，避免重复解析报价和查找证券。
  final ranked = source.indexed.map((item) {
    final valuation = valueStockPosition(portfolio, item.$2);
    return (
      index: item.$1,
      position: item.$2,
      amount: byMarketValue ? valuation.marketValue : valuation.unrealized,
    );
  }).toList();
  ranked.sort((a, b) {
    final first = a.amount, second = b.amount;
    if (first == null) {
      return second == null ? a.index.compareTo(b.index) : 1;
    }
    if (second == null) return -1;
    final compared = first.compareTo(second);
    if (compared == 0) return a.index.compareTo(b.index);
    return descending ? -compared : compared;
  });
  return ranked.map((item) => item.position).toList();
}
