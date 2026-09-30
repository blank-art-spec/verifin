import 'currency_math.dart';
import 'models.dart';

/// 一笔交易各字段可解释的外部来源。空值表示该字段只有本地值或来源之间仍冲突。
class EntryFieldProvenance {
  const EntryFieldProvenance({
    this.occurredAt,
    this.postDate,
    this.amount,
    this.merchant,
  });

  final EntrySourceRecord? occurredAt;
  final EntrySourceRecord? postDate;
  final EntrySourceRecord? amount;
  final EntrySourceRecord? merchant;
}

/// 从同一交易的来源证据中为各字段选择可解释的来源。
///
/// [entry] 保留用户已确认的权威交易值；本函数只选“能解释当前值”的证据，不
/// 修改金额或时间。时间优先来源精度，金额必须与交易值在币种容差内一致；文件
/// 来源优先于实时采集，但日期精度低的正式账单不能覆盖通知提供的具体时刻。
EntryFieldProvenance resolveEntryFieldProvenance(LedgerEntry entry) {
  final records = entry.sourceRecords;
  final occurred =
      <EntrySourceRecord>[
        for (final record in records)
          if (record.transactionDate.year == entry.occurredAt.year &&
              record.transactionDate.month == entry.occurredAt.month &&
              record.transactionDate.day == entry.occurredAt.day &&
              (entry.occurredAtPrecision == OccurredAtPrecision.date ||
                  (record.transactionDatePrecision !=
                          OccurredAtPrecision.date &&
                      record.transactionDate.hour == entry.occurredAt.hour &&
                      record.transactionDate.minute ==
                          entry.occurredAt.minute &&
                      (entry.occurredAtPrecision !=
                              OccurredAtPrecision.second ||
                          (record.transactionDatePrecision ==
                                  OccurredAtPrecision.second &&
                              record.transactionDate.second ==
                                  entry.occurredAt.second)))))
            record,
      ]..sort((a, b) {
        final precision = b.transactionDatePrecision.index.compareTo(
          a.transactionDatePrecision.index,
        );
        return precision != 0
            ? precision
            : _sourcePriority(b).compareTo(_sourcePriority(a));
      });
  final posting = <EntrySourceRecord>[
    for (final record in records)
      if (entry.postDate != null &&
          record.postedDate != null &&
          _sameDay(record.postedDate!, entry.postDate!))
        record,
  ]..sort((a, b) => _sourcePriority(b).compareTo(_sourcePriority(a)));
  final amounts = <EntrySourceRecord>[
    for (final record in records)
      if (record.currencyCode == entry.currencyCode &&
          (record.amount - entry.amount).abs() <
              currencyAmountTolerance(entry.currencyCode))
        record,
  ]..sort((a, b) => _sourcePriority(b).compareTo(_sourcePriority(a)));
  final merchants = <EntrySourceRecord>[
    for (final record in records)
      if (record.merchant.trim().isNotEmpty) record,
  ]..sort((a, b) => _sourcePriority(b).compareTo(_sourcePriority(a)));
  return EntryFieldProvenance(
    occurredAt: occurred.firstOrNull,
    postDate: posting.firstOrNull,
    amount: entry.reconciliationStatus == ReconciliationStatus.amountConflict
        ? null
        : amounts.firstOrNull,
    merchant: merchants.firstOrNull,
  );
}

/// 文件导入记录优先于实时通知；同级别时按较晚导入时间稳定排序。
int _sourcePriority(EntrySourceRecord record) =>
    (record.sourceId.startsWith('capture:') ? 0 : 1000000000000000) +
    record.importedAt.millisecondsSinceEpoch;

/// 仅比较日历日期，避免来源文件的记账日零点与本地时区时刻误判不同。
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
