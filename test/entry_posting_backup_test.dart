import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/backup_service.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

/// 创建备份测试用支出；[bookId] 与 [categoryId] 取自实际控制器，
/// [id] 区分记录，[postDate] 为空表示未填入账日期；有值时明确保存分钟精度。
/// 使用无账户记录，避免账户开户、外币折算与本次入账时间往返断言互相干扰。
LedgerEntry _backupExpense({
  required String id,
  required String bookId,
  required String categoryId,
  DateTime? postDate,
}) => LedgerEntry(
  id: id,
  bookId: bookId,
  type: EntryType.expense,
  amount: 30,
  categoryId: categoryId,
  accountId: '',
  note: '可选入账时间备份示例',
  occurredAt: DateTime(2026, 11, 2, 22, 30),
  occurredAtPrecision: OccurredAtPrecision.minute,
  postDate: postDate,
  postDatePrecision: postDate == null
      ? OccurredAtPrecision.date
      : OccurredAtPrecision.minute,
);

/// 通过完整导出/恢复入口验证入账字段备份范围，以及 v16 缺精度字段的兼容行为。
void main() {
  useTestDatabases();

  test('v17 入账具体时分经过备份字节、恢复预览与重开控制器仍保留', () async {
    final source = await makeController();
    addTearDown(source.dispose);
    final posting = DateTime(2026, 11, 3, 8, 15);
    final entry = _backupExpense(
      id: 'posted-v17',
      bookId: source.activeBook.id,
      categoryId: source.categoriesForType(EntryType.expense).first.id,
      postDate: posting,
    );
    source.addEntry(entry);
    await source.waitForPendingWrites();
    final exported = source.exportDataJson();
    expect((jsonDecode(exported) as Map)['version'], 18);
    final prepared = await BackupService.prepare(
      json: exported,
      passphrase: '',
      now: DateTime(2026, 11, 5, 10),
      auto: false,
    );
    final decoded =
        BackupService.decodeBackupBytes(prepared.bytes) as PlainBackupJson;
    final store = LocalKeyValueStore();
    final target = await makeController(store);
    addTearDown(target.dispose);
    final preview = target.importDataJson(decoded.json, dryRun: true);
    expect(preview.entryCount, 1);
    expect(target.entries, isEmpty);
    target.importDataJson(decoded.json);
    await target.waitForPendingWrites();
    final reopened = await makeController(store);
    addTearDown(reopened.dispose);
    final restored = reopened.entries.single;
    expect(restored.id, entry.id);
    expect(restored.postDate, posting);
    expect(restored.postDatePrecision, OccurredAtPrecision.minute);
    expect(restored.billingOccurredAt, posting);
    expect(restored.occurredAt, entry.occurredAt);
    final root = jsonDecode(reopened.exportDataJson()) as Map;
    final encoded = ((root['data'] as Map)['entries'] as List).single as Map;
    expect(encoded['postDate'], posting.toIso8601String());
    expect(encoded['postDatePrecision'], 'minute');

    // 初始化删除交易本体及其入账字段，不把可选入账信息留作设备偏好。
    reopened.resetAllData();
    await reopened.waitForPendingWrites();
    final afterReset = await makeController(store);
    addTearDown(afterReset.dispose);
    expect(afterReset.entries, isEmpty);
  });

  test('v16 旧备份缺入账精度时采用日期精度，未填入账仍回退消费时间', () async {
    final source = await makeController();
    addTearDown(source.dispose);
    final categoryId = source.categoriesForType(EntryType.expense).first.id;
    final posting = DateTime(2026, 11, 3, 8, 15);
    source.addEntry(
      _backupExpense(
        id: 'legacy-posted',
        bookId: source.activeBook.id,
        categoryId: categoryId,
        postDate: posting,
      ),
    );
    source.addEntry(
      _backupExpense(
        id: 'legacy-without-posting',
        bookId: source.activeBook.id,
        categoryId: categoryId,
      ),
    );
    await source.waitForPendingWrites();
    final legacy = jsonDecode(source.exportDataJson()) as Map<String, dynamic>;
    legacy['version'] = 16;
    final entries = (legacy['data'] as Map)['entries'] as List;
    for (final entry in entries.cast<Map>()) {
      entry.remove('postDatePrecision');
    }
    final target = await makeController();
    addTearDown(target.dispose);
    target.importDataJson(jsonEncode(legacy));
    await target.waitForPendingWrites();
    final posted = target.entries.singleWhere(
      (entry) => entry.id == 'legacy-posted',
    );
    expect(posted.postDate, posting);
    expect(posted.postDatePrecision, OccurredAtPrecision.date);
    expect(posted.billingOccurredAt, posting);
    final without = target.entries.singleWhere(
      (entry) => entry.id == 'legacy-without-posting',
    );
    expect(without.postDate, isNull);
    expect(without.postDatePrecision, OccurredAtPrecision.date);
    expect(without.billingOccurredAt, without.occurredAt);
    expect(without.occurredAt, DateTime(2026, 11, 2, 22, 30));
  });
}
