import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';

/// 构造入账持久化所需的最小支出；[id] 区分测试记录，
/// [postDate] 和 [precision] 分别表达可选入账时刻与用户确认的精度。
/// 消费时刻固定在账单日前，便于识别保存或冷读时意外覆盖消费时间的问题。
LedgerEntry _postingEntry(
  String id, {
  DateTime? postDate,
  OccurredAtPrecision precision = OccurredAtPrecision.date,
}) => LedgerEntry(
  id: id,
  bookId: defaultLedgerBookId,
  type: EntryType.expense,
  amount: 100,
  categoryId: 'dining',
  accountId: 'credit-card',
  note: '入账日期持久化示例',
  occurredAt: DateTime(2026, 11, 24, 22, 30),
  occurredAtPrecision: OccurredAtPrecision.minute,
  postDate: postDate,
  postDatePrecision: precision,
);

/// 通过关闭再重开真实 SQLite 文件，核对四种入账状态及明确清除行为。
/// 此处不依赖内存仓储，以便发现数据库行映射或增量更新遗漏新字段的问题。
void main() {
  setUpAll(sqfliteFfiInit);

  test('入账日期、明确午夜和具体时分在 SQLite 冷启动后保留，清除后回退消费时间', () async {
    final directory = await Directory.systemTemp.createTemp('verifin_posting_');
    final path = '${directory.path}/posting.db';
    AppDatabase? database;
    try {
      final original = <LedgerEntry>[
        _postingEntry('without-posting'),
        _postingEntry('date-only', postDate: DateTime(2026, 11, 25)),
        _postingEntry(
          'explicit-midnight',
          postDate: DateTime(2026, 11, 25),
          precision: OccurredAtPrecision.minute,
        ),
        _postingEntry(
          'minute',
          postDate: DateTime(2026, 11, 25, 8, 15),
          precision: OccurredAtPrecision.minute,
        ),
      ];
      database = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      await SqliteLedgerRepository(database).saveEntries(original);
      await database.close();
      database = null;

      database = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      var repository = SqliteLedgerRepository(database);
      final restored = await repository.loadEntries();
      for (final expected in original) {
        final actual = restored.singleWhere((entry) => entry.id == expected.id);
        expect(actual.toJson(), expected.toJson());
        expect(actual.postDatePrecision, expected.postDatePrecision);
        expect(actual.occurredAt, expected.occurredAt);
      }

      // 清除只改变入账字段，正常消费时间与其他记录仍保留；再次冷读验证确已落盘。
      final changed = restored.map((entry) {
        return entry.id == 'minute'
            ? entry.copyWith(clearPostDate: true)
            : entry;
      }).toList();
      await repository.saveEntries(changed);
      await database.close();
      database = null;
      database = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      repository = SqliteLedgerRepository(database);
      final afterClear = await repository.loadEntries();
      final cleared = afterClear.singleWhere((entry) => entry.id == 'minute');
      expect(cleared.postDate, isNull);
      expect(cleared.postDatePrecision, OccurredAtPrecision.date);
      expect(cleared.billingOccurredAt, DateTime(2026, 11, 24, 22, 30));
      expect(
        afterClear
            .singleWhere((entry) => entry.id == 'explicit-midnight')
            .postDatePrecision,
        OccurredAtPrecision.minute,
      );

      // 仓储的整集合语义仍有效，删除交易不会留下独立的入账记录。
      await repository.saveEntries(const []);
      expect(await repository.loadEntries(), isEmpty);
    } finally {
      await database?.close();
      await directory.delete(recursive: true);
    }
  });
}
