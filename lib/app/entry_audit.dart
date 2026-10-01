import 'models.dart';

/// 比较一次交易提交的关键字段并追加不可覆盖的修改记录。
///
/// [before] 为 null 表示创建，[after] 是准备落库的交易；[actor]、[reason] 标明修改
/// 主体和业务原因，[at] 使用真实提交时刻，[sourceId] 可指出正式导入来源。只记录
/// 有变化的字段，不记录完整通知原文、附件或密钥，避免审计历史无界放大隐私数据。
LedgerEntry appendEntryAudit({
  required LedgerEntry? before,
  required LedgerEntry after,
  required EntryAuditActor actor,
  required EntryAuditReason reason,
  required DateTime at,
  String sourceId = '',
}) {
  final oldFields = before == null
      ? const <String, String>{}
      : _auditedEntryFields(before);
  final newFields = _auditedEntryFields(after);
  final changes = <String, EntryAuditChange>{};
  for (final field in newFields.entries) {
    final previous = oldFields[field.key] ?? '';
    if (before == null || previous != field.value) {
      changes[field.key] = EntryAuditChange(
        before: previous,
        after: field.value,
      );
    }
  }
  // 草稿可能携带旧快照：即使字段无变化，也必须保留落库交易已有的完整历史。
  if (changes.isEmpty) {
    return before == null
        ? after
        : after.copyWith(auditHistory: before.auditHistory);
  }
  final history = <EntryAuditRecord>[
    ...?before?.auditHistory,
    EntryAuditRecord(
      at: at,
      actor: actor,
      reason: reason,
      changes: changes,
      sourceId: sourceId,
    ),
  ];
  return after.copyWith(auditHistory: history);
}

/// 把可审计字段转换成稳定文本；不把派生退款缓存和完整原始通知写入历史。
Map<String, String> _auditedEntryFields(LedgerEntry entry) => <String, String>{
  'type': entry.type.name,
  'amount': entry.amount.toString(),
  'currencyCode': entry.currencyCode,
  'accountAmount': entry.accountAmount?.toString() ?? '',
  'baseAmount': entry.baseAmount.toString(),
  'toAccountAmount': entry.toAccountAmount?.toString() ?? '',
  'conversionSource': entry.conversionSource.name,
  'accountId': entry.accountId,
  'toAccountId': entry.toAccountId ?? '',
  'categoryId': entry.categoryId,
  'note': entry.note,
  'occurredAt': entry.occurredAt.toIso8601String(),
  'occurredAtPrecision': entry.occurredAtPrecision.name,
  'postDate': entry.postDate?.toIso8601String() ?? '',
  'billingCycleId': entry.billingCycleId ?? '',
  'tagIds': entry.tagIds.join(','),
  'fee': entry.fee.toString(),
  'reimbursable': entry.reimbursable.toString(),
  'refundOf': entry.refundOf ?? '',
  'settledAt': entry.settledAt?.toIso8601String() ?? '',
  'reconciliationStatus': entry.reconciliationStatus.name,
  'sourceIds': entry.sourceRecords.map((record) => record.id).join(','),
};
