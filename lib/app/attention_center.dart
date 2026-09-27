/// 异常处理中心的只读投影。
///
/// 这里不持久化“异常状态”，而是从交易、正式账单、还款分配、
/// 自动采集事件与缺失汇率中实时推导。这样用户完成处理后，对应项
/// 会自然消失，也不会出现业务数据已修复、另一张异常表却仍然挂起的
/// 双状态问题。
library;

import 'currency_math.dart';
import 'models.dart';

/// 异常中心支持的问题类型。
///
/// 枚举值表达稳定的业务含义；面向用户的中英文名称由页面的
/// l10n 层提供，避免纯领域投影依赖 Flutter `BuildContext`。
enum AttentionIssueType {
  amountConflict,
  duplicateTransaction,
  unmatchedRefund,
  unallocatedRepayment,
  missingExchangeRate,
  bankOnlyTransaction,
  localOnlyTransaction,
  lowConfidenceCapture,
  captureReview,
  captureFailure,
}

/// 异常项所指向的原始数据类型。
///
/// 页面据此选择交易详情、自动识别队列或汇率管理页，不在
/// 投影层携带任何 Navigator 或 Widget。
enum AttentionReferenceKind { entry, captureEvent, currency }

/// 一条可以被用户理解和处理的异常记录。
class AttentionIssue {
  const AttentionIssue({
    required this.id,
    required this.type,
    required this.referenceKind,
    required this.referenceId,
    required this.occurredAt,
    this.amount,
    this.currencyCode,
    this.accountId,
    this.relatedCount = 1,
  });

  /// 投影内的稳定 id，由问题类型与原始对象 id 组成。
  final String id;

  /// 问题的业务类型。
  final AttentionIssueType type;

  /// 原始对象类型，用于决定点击后的处理入口。
  final AttentionReferenceKind referenceKind;

  /// 交易 id、采集事件 id 或币种代码。
  final String referenceId;

  /// 问题发生或被观测到的时间，用于页面稳定排序。
  final DateTime occurredAt;

  /// 可选金额。汇率问题等没有单一金额的项目保持 null。
  final double? amount;

  /// [amount] 对应的币种，或缺失汇率项目的币种代码。
  final String? currencyCode;

  /// 问题涉及的账户 id；无法唯一归属时为 null。
  final String? accountId;

  /// 同一汇总项覆盖的底层对象数。普通问题固定为 1。
  final int relatedCount;
}

/// 当前账本的异常中心快照。
class AttentionCenterSnapshot {
  const AttentionCenterSnapshot(this.issues);

  /// 按严重性和时间排好的不可变异常列表。
  final List<AttentionIssue> issues;

  /// 当前待处理项总数。汇率汇总项仍按一个“可处理任务”计数。
  int get total => issues.length;

  /// 返回指定类型的问题数，供概览卡与分组标题共用。
  int countOf(AttentionIssueType type) =>
      issues.where((issue) => issue.type == type).length;

  /// 返回指定类型的不可变列表，保留快照的全局排序。
  List<AttentionIssue> issuesOf(AttentionIssueType type) =>
      List<AttentionIssue>.unmodifiable(
        issues.where((issue) => issue.type == type),
      );
}

/// 从当前账本的权威数据构建异常中心快照。
///
/// [recurringMissingRates] 是“已到期但因缺汇率未生成”的周期规则映射；
/// [accountValuation] 是当前账户估值结果。两者合并成按币种的可处理项，
/// 防止同一个 USD 缺率在页面上重复出现多次。
AttentionCenterSnapshot buildAttentionCenterSnapshot({
  required Iterable<Account> accounts,
  required Iterable<LedgerEntry> entries,
  required Iterable<CaptureEvent> captureEvents,
  required Iterable<BillingStatement> billingStatements,
  required Iterable<StatementRepaymentAllocation> repaymentAllocations,
  required Map<String, Set<String>> recurringMissingRates,
  required ConvertedAccountBalances accountValuation,
  required DateTime now,
}) {
  final accountList = accounts.toList(growable: false);
  final entryList = entries.toList(growable: false);
  final entriesById = <String, LedgerEntry>{
    for (final entry in entryList) entry.id: entry,
  };
  final accountsById = <String, Account>{
    for (final account in accountList) account.id: account,
  };
  final issues = <AttentionIssue>[];

  _appendEntryReconciliationIssues(issues, entryList);
  _appendCaptureIssues(issues, captureEvents);
  _appendUnmatchedRefunds(issues, entryList, entriesById);
  _appendUnallocatedRepayments(
    issues,
    entries: entryList,
    accountsById: accountsById,
    statements: billingStatements,
    allocations: repaymentAllocations,
  );
  _appendMissingRateIssues(
    issues,
    accounts: accountList,
    recurringMissingRates: recurringMissingRates,
    accountValuation: accountValuation,
    now: now,
  );

  issues.sort((a, b) {
    final byPriority = _attentionPriority(
      a.type,
    ).compareTo(_attentionPriority(b.type));
    if (byPriority != 0) return byPriority;
    final byDate = b.occurredAt.compareTo(a.occurredAt);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  return AttentionCenterSnapshot(List<AttentionIssue>.unmodifiable(issues));
}

/// 把交易与正式来源的对账差异转换成异常项。
///
/// 自动匹配、人工确认和未核准并不代表确定异常，因此只收集已有
/// `amountConflict` / `bankOnly` / `localOnly` 明确证据的三类状态。
void _appendEntryReconciliationIssues(
  List<AttentionIssue> issues,
  Iterable<LedgerEntry> entries,
) {
  for (final entry in entries) {
    final type = switch (entry.reconciliationStatus) {
      ReconciliationStatus.amountConflict => AttentionIssueType.amountConflict,
      ReconciliationStatus.bankOnly => AttentionIssueType.bankOnlyTransaction,
      ReconciliationStatus.localOnly => AttentionIssueType.localOnlyTransaction,
      ReconciliationStatus.unverified ||
      ReconciliationStatus.autoMatched ||
      ReconciliationStatus.manuallyConfirmed => null,
    };
    if (type == null) continue;
    issues.add(
      AttentionIssue(
        id: '${type.name}:${entry.id}',
        type: type,
        referenceKind: AttentionReferenceKind.entry,
        referenceId: entry.id,
        occurredAt: entry.occurredAt,
        amount: entry.amount,
        currencyCode: entry.currencyCode,
        accountId: entry.accountId.isEmpty ? null : entry.accountId,
      ),
    );
  }
}

/// 把自动采集事件分流到唯一的异常类型。
///
/// 优先级为：失败 > 疑似重复 > 未匹配退款 > 低置信度 > 普通待确认。
/// 一个事件只生成一项，避免首页统计和处理列表重复计数。
void _appendCaptureIssues(
  List<AttentionIssue> issues,
  Iterable<CaptureEvent> events,
) {
  for (final event in events) {
    final type = switch (event.status) {
      CaptureStatus.failed => AttentionIssueType.captureFailure,
      CaptureStatus.duplicateSuspected =>
        AttentionIssueType.duplicateTransaction,
      _
          when event.kind == CaptureTransactionKind.refund &&
              event.status.needsAttention =>
        AttentionIssueType.unmatchedRefund,
      _
          when event.processedAt != null &&
              event.confidence == CaptureConfidence.low &&
              event.status != CaptureStatus.ignored &&
              event.status != CaptureStatus.misidentified =>
        AttentionIssueType.lowConfidenceCapture,
      CaptureStatus.pendingReview => AttentionIssueType.captureReview,
      _ => null,
    };
    if (type == null) continue;
    issues.add(
      AttentionIssue(
        id: '${type.name}:${event.id}',
        type: type,
        referenceKind: AttentionReferenceKind.captureEvent,
        referenceId: event.id,
        occurredAt: event.receivedAt,
        amount: event.parsedAmount,
        currencyCode: event.parsedAmount == null ? null : event.currencyCode,
        accountId: event.accountCandidateId,
      ),
    );
  }
}

/// 查找已进入账本、但原支出关系已缺失或无效的退款。
///
/// 正常的“待到账退款”有有效 [LedgerEntry.refundOf]，属于时间状态，
/// 不是未匹配异常，故不在这里报警。
void _appendUnmatchedRefunds(
  List<AttentionIssue> issues,
  Iterable<LedgerEntry> entries,
  Map<String, LedgerEntry> entriesById,
) {
  for (final refund in entries.where(
    (entry) => entry.type == EntryType.refund,
  )) {
    final original = refund.refundOf == null
        ? null
        : entriesById[refund.refundOf];
    if (original?.type == EntryType.expense) continue;
    issues.add(
      AttentionIssue(
        id: '${AttentionIssueType.unmatchedRefund.name}:${refund.id}',
        type: AttentionIssueType.unmatchedRefund,
        referenceKind: AttentionReferenceKind.entry,
        referenceId: refund.id,
        occurredAt: refund.settledAt ?? refund.occurredAt,
        amount: refund.amount,
        currencyCode: refund.currencyCode,
        accountId: refund.accountId.isEmpty ? null : refund.accountId,
      ),
    );
  }
}

/// 查找已还入信用账户、但尚未完整归属到正式账单的转账。
///
/// 只在目标账户已存在正式账单时提醒；没有正式账单时，转入信用账户
/// 可能是提前还款，系统无从建立关系，不把它误报为异常。
void _appendUnallocatedRepayments(
  List<AttentionIssue> issues, {
  required Iterable<LedgerEntry> entries,
  required Map<String, Account> accountsById,
  required Iterable<BillingStatement> statements,
  required Iterable<StatementRepaymentAllocation> allocations,
}) {
  final billedAccountIds = statements
      .map((statement) => statement.accountId)
      .toSet();
  final allocatedByEntryId = <String, double>{};
  for (final allocation in allocations) {
    allocatedByEntryId[allocation.repaymentEntryId] =
        (allocatedByEntryId[allocation.repaymentEntryId] ?? 0) +
        allocation.amount;
  }
  for (final entry in entries) {
    final targetId = entry.toAccountId;
    final target = targetId == null ? null : accountsById[targetId];
    if (entry.type != EntryType.transfer ||
        target == null ||
        !target.type.supportsCredit ||
        !billedAccountIds.contains(target.id)) {
      continue;
    }
    final repaidAmount = entry.toAccountAmount ?? entry.amount;
    final unallocated = repaidAmount - (allocatedByEntryId[entry.id] ?? 0);
    if (unallocated <= currencyAmountTolerance(target.currencyCode)) continue;
    issues.add(
      AttentionIssue(
        id: '${AttentionIssueType.unallocatedRepayment.name}:${entry.id}',
        type: AttentionIssueType.unallocatedRepayment,
        referenceKind: AttentionReferenceKind.entry,
        referenceId: entry.id,
        occurredAt: entry.occurredAt,
        amount: unallocated,
        currencyCode: target.currencyCode,
        accountId: target.id,
      ),
    );
  }
}

/// 合并账户估值与到期周期规则的缺失汇率，每个币种只生成一项。
void _appendMissingRateIssues(
  List<AttentionIssue> issues, {
  required Iterable<Account> accounts,
  required Map<String, Set<String>> recurringMissingRates,
  required ConvertedAccountBalances accountValuation,
  required DateTime now,
}) {
  final affectedAccountCount = <String, int>{};
  for (final account in accounts) {
    if (accountValuation.affectedAccountIds.contains(account.id)) {
      final code = account.currencyCode.toUpperCase();
      affectedAccountCount[code] = (affectedAccountCount[code] ?? 0) + 1;
    }
  }
  final affectedRuleCount = <String, int>{};
  for (final codes in recurringMissingRates.values) {
    for (final code in codes) {
      final normalized = code.toUpperCase();
      affectedRuleCount[normalized] = (affectedRuleCount[normalized] ?? 0) + 1;
    }
  }
  final codes = <String>{
    ...accountValuation.missingCurrencyCodes.map((code) => code.toUpperCase()),
    ...affectedRuleCount.keys,
  }.toList()..sort();
  for (final code in codes) {
    final relatedCount =
        (affectedAccountCount[code] ?? 0) + (affectedRuleCount[code] ?? 0);
    issues.add(
      AttentionIssue(
        id: '${AttentionIssueType.missingExchangeRate.name}:$code',
        type: AttentionIssueType.missingExchangeRate,
        referenceKind: AttentionReferenceKind.currency,
        referenceId: code,
        occurredAt: now,
        currencyCode: code,
        relatedCount: relatedCount == 0 ? 1 : relatedCount,
      ),
    );
  }
}

/// 给各类问题提供稳定排序：持久化/对账冲突优先，其次是重复与
/// 未匹配关系，最后是需要用户补充信息的自动识别项。
int _attentionPriority(AttentionIssueType type) => switch (type) {
  AttentionIssueType.amountConflict => 0,
  AttentionIssueType.bankOnlyTransaction ||
  AttentionIssueType.localOnlyTransaction => 1,
  AttentionIssueType.duplicateTransaction => 2,
  AttentionIssueType.unmatchedRefund ||
  AttentionIssueType.unallocatedRepayment => 3,
  AttentionIssueType.missingExchangeRate => 4,
  AttentionIssueType.captureFailure => 5,
  AttentionIssueType.lowConfidenceCapture ||
  AttentionIssueType.captureReview => 6,
};
