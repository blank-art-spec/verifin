import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/pages/sheets.dart';

import 'support/test_harness.dart';

void main() {
  testWidgets('字段来源弹层展示可信分钟时间与正式记账日', (tester) async {
    final record = EntrySourceRecord(
      id: 'source-qq',
      sourceId: 'cmb',
      sourceTransactionId: 'bank-123',
      fingerprint: 'fingerprint-qq',
      importedAt: DateTime(2026, 10, 25),
      transactionDate: DateTime(2026, 9, 27, 19, 12),
      transactionDatePrecision: OccurredAtPrecision.minute,
      postedDate: DateTime(2026, 9, 28),
      amount: 30,
      currencyCode: 'CNY',
      merchant: '财付通-QQ音乐会员',
    );
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showEntrySourceEvidenceSheet(
                context: context,
                record: record,
                title: '交易时间来源',
              ),
              child: const Text('查看来源'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('查看来源'));
    await tester.pumpAndSettle();
    expect(find.text('cmb'), findsOneWidget);
    expect(find.text('bank-123'), findsOneWidget);
    expect(find.text('财付通-QQ音乐会员'), findsOneWidget);
    expect(find.textContaining('19:12'), findsOneWidget);
  });
}
