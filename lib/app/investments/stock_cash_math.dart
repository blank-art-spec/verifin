/// 普通交易与证券资金腿在现金核对边界上的组合计算。
library;

import '../ledger_math.dart';
import '../models.dart';
import 'investment_decimal.dart';
import 'stock_projection.dart';

/// 计算已启用证券账户现金；现金锚点只截断资金腿，不截断持仓重放。
/// [anchor] 是最新用户核对余额；[entries] 可含全部账本，内部严格按账户和账本过滤。
double investmentCashBalance({
  required InvestmentPortfolio portfolio,
  required Iterable<LedgerEntry> entries,
  BalanceAnchor? anchor,
  bool rejectUnfundedHistory = false,
}) {
  final useAnchor =
      anchor != null &&
      anchor.effectiveAt.millisecondsSinceEpoch >=
          portfolio.openedAt.millisecondsSinceEpoch;
  final boundary = useAnchor ? anchor.effectiveAt : portfolio.openedAt;
  final included = useAnchor
      ? portfolio.anchorIncludedIds[anchor.id]?.toSet()
      : null;
  var cash = InvestmentDecimal.parse(
    useAnchor ? anchor.balance.toStringAsFixed(8) : portfolio.openingCash,
  );
  final timeline = <(DateTime, String, InvestmentDecimal)>[];
  for (final entry in entries) {
    final date = accountEffectDate(entry);
    final after =
        date.millisecondsSinceEpoch > boundary.millisecondsSinceEpoch ||
        (useAnchor &&
            date.millisecondsSinceEpoch == boundary.millisecondsSinceEpoch &&
            included != null &&
            !included.contains('entry:${entry.id}')) ||
        (!useAnchor &&
            date.millisecondsSinceEpoch == boundary.millisecondsSinceEpoch &&
            !portfolio.includedEntryIds.contains(entry.id));
    if (entry.bookId == portfolio.bookId &&
        after &&
        entryTouchesAccount(entry, portfolio.accountId)) {
      final movement = InvestmentDecimal.parse(
        accountDeltaForEntry(entry, portfolio.accountId).toStringAsFixed(8),
      );
      timeline.add((date, '0:${entry.id}', movement));
    }
  }
  final projection = projectStocks(portfolio);
  for (final event in portfolio.events) {
    if (!useAnchor ||
        event.occurredAt.millisecondsSinceEpoch >
            boundary.millisecondsSinceEpoch ||
        (event.occurredAt.millisecondsSinceEpoch ==
                boundary.millisecondsSinceEpoch &&
            included != null &&
            !included.contains('stock:${event.id}'))) {
      timeline.add((
        event.occurredAt,
        '1:${event.sequence.toString().padLeft(20, '0')}',
        projection.cashMovements[event.id]!,
      ));
    }
  }
  timeline.sort((a, b) {
    final time = a.$1.compareTo(b.$1);
    return time != 0 ? time : a.$2.compareTo(b.$2);
  });
  if (rejectUnfundedHistory && cash.units < BigInt.zero) {
    throw const FormatException('期初现金不足，需确认真实融资');
  }
  for (final point in timeline) {
    cash = cash + point.$3;
    if (rejectUnfundedHistory && cash.units < BigInt.zero) {
      throw const FormatException('历史成交时现金不足，需确认真实融资');
    }
  }
  return cash.toDouble();
}
