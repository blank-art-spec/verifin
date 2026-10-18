import 'currency_math.dart';
import 'models.dart';

double? confirmedReferenceAmount(LedgerEntry entry) =>
    entry.referenceBaseAmount;

/// 返回只读统计投影，原始金额、余额和已保存交易不被汇率更新改写。
({List<LedgerEntry> entries, Set<String> missing}) projectStatisticsCurrency({
  required List<LedgerEntry> entries,
  required LedgerBook book,
  required Iterable<ExchangeRate> rates,
  required DateTime now,
}) {
  final missing = <String>{};
  final projected = entries.map((entry) {
    if (entry.type == EntryType.transfer) return entry;
    double? value;
    if (entry.currencyCode == book.baseCurrencyCode) {
      value = entry.amount;
    } else {
      value = confirmedReferenceAmount(entry);
      if (value == null) {
        final converted = convertCurrencyAmount(
          amount: entry.amount,
          sourceCurrencyCode: entry.currencyCode,
          targetCurrencyCode: book.baseCurrencyCode,
          baseCurrencyCode: book.baseCurrencyCode,
          bookId: book.id,
          date: now,
          rates: rates,
        );
        if (converted is ConvertedCurrencyAmount) value = converted.amount;
      }
    }
    if (value == null) missing.add(entry.currencyCode);
    return entry.copyWith(baseAmount: value ?? 0);
  }).toList();
  final refunds = <String, double>{};
  for (final entry in projected.where((e) => e.isSettledRefund)) {
    refunds[entry.refundOf!] =
        (refunds[entry.refundOf!] ?? 0) + entry.baseAmount;
  }
  return (
    entries: List<LedgerEntry>.unmodifiable([
      for (final entry in projected)
        if (entry.type == EntryType.expense)
          entry.copyWith(refundedBaseAmount: refunds[entry.id] ?? 0)
        else
          entry,
    ]),
    missing: Set<String>.unmodifiable(missing),
  );
}
