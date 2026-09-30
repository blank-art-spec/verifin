import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/entry_provenance.dart';
import 'package:verifin/app/models.dart';

void main() {
  test('实时通知保留具体时间，正式账单提供记账日、金额与商户来源', () {
    final time = DateTime(2026, 9, 27, 19, 12);
    final capture = EntrySourceRecord(
      id: 'notice',
      sourceId: 'capture:notification:cmb',
      fingerprint: 'notice-1',
      importedAt: DateTime(2026, 9, 27, 19, 13),
      transactionDate: time,
      transactionDatePrecision: OccurredAtPrecision.minute,
      amount: 30,
      currencyCode: 'CNY',
      merchant: '财付通-QQ音乐会员',
    );
    final bank = EntrySourceRecord(
      id: 'statement',
      sourceId: 'cmb',
      fingerprint: 'statement-1',
      importedAt: DateTime(2026, 10, 25),
      transactionDate: DateTime(2026, 9, 27),
      transactionDatePrecision: OccurredAtPrecision.date,
      postedDate: DateTime(2026, 9, 28),
      amount: 30,
      currencyCode: 'CNY',
      merchant: '财付通-QQ音乐会员',
    );
    final entry = LedgerEntry(
      id: 'qq-music',
      bookId: 'default',
      type: EntryType.expense,
      amount: 30,
      categoryId: 'entertainment',
      accountId: 'cmb-4185',
      note: '音乐会员',
      occurredAt: time,
      occurredAtPrecision: OccurredAtPrecision.minute,
      postDate: DateTime(2026, 9, 28),
      reconciliationStatus: ReconciliationStatus.autoMatched,
      sourceRecords: <EntrySourceRecord>[capture, bank],
    );

    final source = resolveEntryFieldProvenance(entry);
    expect(source.occurredAt?.id, 'notice');
    expect(source.postDate?.id, 'statement');
    expect(source.amount?.id, 'statement');
    expect(source.merchant?.id, 'statement');
    expect(
      resolveEntryFieldProvenance(
        entry.copyWith(
          reconciliationStatus: ReconciliationStatus.amountConflict,
        ),
      ).amount,
      isNull,
    );
  });
}
