import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/entry_audit.dart';
import 'package:verifin/app/models.dart';

/// 构造没有外部来源的交易；[note]、[amount] 用于验证每次提交只记录真实差异。
LedgerEntry _entry({String note = '原备注', double amount = 30}) => LedgerEntry(
  id: 'entry-1',
  bookId: 'book-1',
  type: EntryType.expense,
  amount: amount,
  baseAmount: amount,
  accountAmount: amount,
  categoryId: 'music',
  accountId: 'cmb',
  note: note,
  occurredAt: DateTime(2026, 9, 27, 19, 12),
);

void main() {
  test('入账日期从仅日期改为确认零点也记录精度变更，清除后记录移除', () {
    final before = _entry().copyWith(postDate: DateTime(2026, 9, 28));
    final after = appendEntryAudit(
      before: before,
      after: before.copyWith(postDatePrecision: OccurredAtPrecision.minute),
      actor: EntryAuditActor.user,
      reason: EntryAuditReason.edited,
      at: DateTime(2026, 9, 28, 9),
    );
    expect(after.auditHistory.single.changes.keys, ['postDatePrecision']);
    expect(
      after.auditHistory.single.changes['postDatePrecision']!.before,
      'date',
    );
    expect(
      after.auditHistory.single.changes['postDatePrecision']!.after,
      'minute',
    );
    final cleared = appendEntryAudit(
      before: after,
      after: after.copyWith(clearPostDate: true),
      actor: EntryAuditActor.user,
      reason: EntryAuditReason.edited,
      at: DateTime(2026, 9, 28, 10),
    );
    expect(cleared.auditHistory.last.changes['postDate']!.after, isEmpty);
    expect(
      cleared.auditHistory.last.changes['postDatePrecision']!.after,
      isEmpty,
    );
  });

  test('创建和修改仅记录变化字段，编辑草稿不能覆盖既有历史', () {
    final created = appendEntryAudit(
      before: null,
      after: _entry(),
      actor: EntryAuditActor.autoCapture,
      reason: EntryAuditReason.created,
      at: DateTime(2026, 9, 27, 19, 12),
      sourceId: 'cmb-notification',
    );
    final edited = appendEntryAudit(
      before: created,
      after: _entry(
        note: '音乐会员',
      ).copyWith(auditHistory: const <EntryAuditRecord>[]),
      actor: EntryAuditActor.user,
      reason: EntryAuditReason.edited,
      at: DateTime(2026, 9, 27, 19, 15),
    );
    expect(edited.auditHistory, hasLength(2));
    expect(edited.auditHistory.first.actor, EntryAuditActor.autoCapture);
    expect(edited.auditHistory.last.changes.keys, <String>['note']);
    expect(edited.auditHistory.last.changes['note']!.before, '原备注');
    expect(edited.auditHistory.last.changes['note']!.after, '音乐会员');
    expect(
      LedgerEntry.fromJson(
        edited.toJson(),
      ).auditHistory.last.changes['note']!.after,
      '音乐会员',
    );
    final unchanged = appendEntryAudit(
      before: edited,
      after: edited.copyWith(auditHistory: const <EntryAuditRecord>[]),
      actor: EntryAuditActor.user,
      reason: EntryAuditReason.edited,
      at: DateTime(2026, 9, 27, 19, 16),
    );
    expect(unchanged.auditHistory, hasLength(2));
  });
}
