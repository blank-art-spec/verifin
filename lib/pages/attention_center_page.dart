import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/attention_center.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'auto_capture_page.dart';
import 'currency_rates_page.dart';
import 'transaction_detail_page.dart';

/// 统一异常处理中心。
///
/// 页面每次从 Controller 取得当前账本的实时快照，不在 Widget 内维护
/// 另一套“已处理”状态。补汇率、合并重复项或确认对账后，问题
/// 会随 Controller 刷新自动从页面消失。
class AttentionCenterPage extends StatelessWidget {
  const AttentionCenterPage({super.key});

  /// 构建页面骨架、实时概览与按类型分组的问题列表。
  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final snapshot = controller.attentionCenterSnapshot();
    final l10n = AppLocalizations.of(context);
    final visibleTypes = AttentionIssueType.values
        .where((type) => snapshot.countOf(type) > 0)
        .toList(growable: false);

    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: l10n.attentionCenterTitle,
                subtitle: l10n.attentionCenterSubtitle,
                showBack: true,
              ),
              const SizedBox(height: 10),
              _AttentionSummary(snapshot: snapshot),
              const SizedBox(height: 10),
              if (snapshot.issues.isEmpty)
                EmptyState(
                  icon: Icons.task_alt,
                  title: l10n.attentionCenterEmptyTitle,
                  description: l10n.attentionCenterEmptyDescription,
                )
              else
                for (final type in visibleTypes) ...<Widget>[
                  _AttentionIssueGroup(
                    type: type,
                    issues: snapshot.issuesOf(type),
                  ),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 页首概览：展示总待处理数以及当前实际出现的分类计数。
class _AttentionSummary extends StatelessWidget {
  const _AttentionSummary({required this.snapshot});

  final AttentionCenterSnapshot snapshot;

  /// 构建总待处理数和非零分类计数，空分类不占用界面空间。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final activeTypes = AttentionIssueType.values
        .where((type) => snapshot.countOf(type) > 0)
        .toList(growable: false);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              VeriIconBox(
                icon: snapshot.total == 0
                    ? Icons.task_alt
                    : Icons.rule_folder_outlined,
                color: snapshot.total == 0
                    ? veriSemantic(context, veriIncome)
                    : veriSemantic(context, veriWarning),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  l10n.attentionCenterPendingCount(snapshot.total),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (activeTypes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final type in activeTypes)
                  _AttentionCountChip(
                    label: _attentionTypeLabel(l10n, type),
                    count: snapshot.countOf(type),
                    color: _attentionTypeColor(context, type),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 概览卡中的紧凑计数胶囊，只用实色表面与语义色文字区分类型。
class _AttentionCountChip extends StatelessWidget {
  const _AttentionCountChip({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  /// 构建单个异常分类的实色计数胶囊。
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(veriRadiusSm),
      ),
      child: Text(
        '$label $count',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 一类异常的标题、数量与具体条目容器。
class _AttentionIssueGroup extends StatelessWidget {
  const _AttentionIssueGroup({required this.type, required this.issues});

  final AttentionIssueType type;
  final List<AttentionIssue> issues;

  /// 构建分组标题与组内问题行，相邻行使用统一细分隔线。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _attentionTypeColor(context, type);
    return VeriCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: <Widget>[
                Icon(_attentionTypeIcon(type), size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _attentionTypeLabel(l10n, type),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${issues.length}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          for (final (index, issue) in issues.indexed) ...<Widget>[
            if (index > 0) const Divider(height: 1, indent: 14, endIndent: 14),
            _AttentionIssueRow(issue: issue),
          ],
        ],
      ),
    );
  }
}

/// 单条异常：显示来源、可读原因、日期和可选金额。
class _AttentionIssueRow extends StatelessWidget {
  const _AttentionIssueRow({required this.issue});

  final AttentionIssue issue;

  /// 构建单条异常的标题、原因、日期、金额与可选处理入口。
  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final onTap = _attentionIssueAction(context, controller, issue);
    final amount = issue.amount;
    final currencyCode = issue.currencyCode;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _attentionIssueTitle(controller, l10n, issue),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _attentionIssueDetail(l10n, issue),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.56),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    l10n.dateMonthDay(issue.occurredAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.42),
                    ),
                  ),
                ],
              ),
            ),
            if (amount != null && currencyCode != null) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                formatUserMoney(amount, currencyCode),
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
            if (onTap != null) const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 返回问题类型的本地化标题。
String _attentionTypeLabel(AppLocalizations l10n, AttentionIssueType type) =>
    switch (type) {
      AttentionIssueType.amountConflict => l10n.attentionIssueAmountConflict,
      AttentionIssueType.duplicateTransaction =>
        l10n.attentionIssueDuplicateTransaction,
      AttentionIssueType.unmatchedRefund => l10n.attentionIssueUnmatchedRefund,
      AttentionIssueType.unallocatedRepayment =>
        l10n.attentionIssueUnallocatedRepayment,
      AttentionIssueType.missingExchangeRate =>
        l10n.attentionIssueMissingExchangeRate,
      AttentionIssueType.bankOnlyTransaction =>
        l10n.attentionIssueBankOnlyTransaction,
      AttentionIssueType.localOnlyTransaction =>
        l10n.attentionIssueLocalOnlyTransaction,
      AttentionIssueType.lowConfidenceCapture =>
        l10n.attentionIssueLowConfidenceCapture,
      AttentionIssueType.captureReview => l10n.attentionIssueCaptureReview,
      AttentionIssueType.captureFailure => l10n.attentionIssueCaptureFailure,
    };

/// 根据原始对象给一条异常生成简短主标题。
String _attentionIssueTitle(
  VeriFinController controller,
  AppLocalizations l10n,
  AttentionIssue issue,
) {
  switch (issue.referenceKind) {
    case AttentionReferenceKind.currency:
      return l10n.attentionMissingRateTitle(issue.referenceId);
    case AttentionReferenceKind.captureEvent:
      final event = controller.captureEvents
          .where((item) => item.id == issue.referenceId)
          .firstOrNull;
      if (event == null) return l10n.attentionCapturedEventFallback;
      if (event.merchant.trim().isNotEmpty) return event.merchant.trim();
      if (event.sourceLabel.trim().isNotEmpty) return event.sourceLabel.trim();
      return l10n.attentionCapturedEventFallback;
    case AttentionReferenceKind.entry:
      final entry = controller.entries
          .where((item) => item.id == issue.referenceId)
          .firstOrNull;
      if (issue.type == AttentionIssueType.unallocatedRepayment) {
        final account = controller.accounts
            .where((item) => item.id == issue.accountId)
            .firstOrNull;
        if (account != null) return account.name;
      }
      if (entry == null) return _attentionTypeLabel(l10n, issue.type);
      return entry.note.trim().isEmpty
          ? entry.type.label(l10n)
          : entry.note.trim();
  }
}

/// 返回单条异常的稳定、本地化原因说明。
String _attentionIssueDetail(
  AppLocalizations l10n,
  AttentionIssue issue,
) => switch (issue.type) {
  AttentionIssueType.amountConflict => l10n.attentionIssueAmountConflictDetail,
  AttentionIssueType.duplicateTransaction => l10n.attentionIssueDuplicateDetail,
  AttentionIssueType.unmatchedRefund => l10n.attentionIssueRefundDetail,
  AttentionIssueType.unallocatedRepayment => l10n.attentionIssueRepaymentDetail,
  AttentionIssueType.missingExchangeRate =>
    l10n.attentionIssueMissingRateDetail(issue.relatedCount),
  AttentionIssueType.bankOnlyTransaction => l10n.attentionIssueBankOnlyDetail,
  AttentionIssueType.localOnlyTransaction => l10n.attentionIssueLocalOnlyDetail,
  AttentionIssueType.lowConfidenceCapture =>
    l10n.attentionIssueLowConfidenceDetail,
  AttentionIssueType.captureReview => l10n.attentionIssueCaptureReviewDetail,
  AttentionIssueType.captureFailure => l10n.attentionIssueCaptureFailureDetail,
};

/// 根据异常引用类型生成对应的处理动作。
///
/// 损坏备份可能带入“原支出已丢失”的退款条目，现有交易编辑页
/// 不允许独立编辑退款，故这类极端数据只展示、不提供会误写数据的跳转。
VoidCallback? _attentionIssueAction(
  BuildContext context,
  VeriFinController controller,
  AttentionIssue issue,
) {
  if (issue.type == AttentionIssueType.unallocatedRepayment) {
    return () => _allocateRepayment(context, controller, issue);
  }
  switch (issue.referenceKind) {
    case AttentionReferenceKind.currency:
      return () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => const CurrencyRatesPage(),
        ),
      );
    case AttentionReferenceKind.captureEvent:
      return () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (context) => const AutoCapturePage()),
      );
    case AttentionReferenceKind.entry:
      final entry = controller.entries
          .where((item) => item.id == issue.referenceId)
          .firstOrNull;
      if (entry == null || entry.type == EntryType.refund) return null;
      return () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => TransactionDetailPage(entryId: entry.id),
        ),
      );
  }
}

/// 经用户确认后，把已存在的信用账户还款按最早到期顺序关联到
/// 未结清正式账单。这里只调用 Controller 的原子持久化入口，不直接改内存。
Future<void> _allocateRepayment(
  BuildContext context,
  VeriFinController controller,
  AttentionIssue issue,
) async {
  final accountId = issue.accountId;
  final repayment = controller.entries
      .where((entry) => entry.id == issue.referenceId)
      .firstOrNull;
  final repaymentAmount = repayment == null
      ? null
      : repayment.toAccountAmount ?? repayment.amount;
  if (accountId == null ||
      repayment == null ||
      repaymentAmount == null ||
      repaymentAmount <= 0) {
    return;
  }
  final l10n = AppLocalizations.of(context);
  final confirmed = await showConfirmDialog(
    context,
    title: l10n.attentionAllocateRepaymentTitle,
    message: l10n.attentionAllocateRepaymentMessage,
    confirmLabel: l10n.attentionAllocateRepaymentAction,
  );
  if (confirmed != true || !context.mounted) return;
  final allocated = await controller.allocateRepaymentToStatements(
    repaymentEntryId: issue.referenceId,
    creditAccountId: accountId,
    // Controller 会先回滚这笔还款的旧分配再整体重算，因此
    // 必须传真实转入总额，不能传异常行上展示的“未分配余额”。
    repaymentAmount: repaymentAmount,
  );
  if (!context.mounted) return;
  unawaited(
    VeriFeedbackHost.of(context).showMessage(
      message: allocated > 0
          ? l10n.attentionAllocateRepaymentSuccess
          : l10n.attentionAllocateRepaymentNoChange,
      tone: allocated > 0 ? VeriFeedbackTone.success : VeriFeedbackTone.warning,
    ),
  );
}

/// 返回分类图标，让概览和详细分组保持相同语义。
IconData _attentionTypeIcon(AttentionIssueType type) => switch (type) {
  AttentionIssueType.amountConflict => Icons.compare_arrows,
  AttentionIssueType.duplicateTransaction => Icons.content_copy_outlined,
  AttentionIssueType.unmatchedRefund => Icons.currency_exchange,
  AttentionIssueType.unallocatedRepayment => Icons.receipt_long_outlined,
  AttentionIssueType.missingExchangeRate => Icons.money_off_csred_outlined,
  AttentionIssueType.bankOnlyTransaction => Icons.account_balance_outlined,
  AttentionIssueType.localOnlyTransaction => Icons.phone_android_outlined,
  AttentionIssueType.lowConfidenceCapture => Icons.help_outline,
  AttentionIssueType.captureReview => Icons.fact_check_outlined,
  AttentionIssueType.captureFailure => Icons.error_outline,
};

/// 返回符合当前明暗主题对比度的异常语义色。
Color _attentionTypeColor(BuildContext context, AttentionIssueType type) =>
    switch (type) {
      AttentionIssueType.amountConflict ||
      AttentionIssueType.captureFailure => veriSemantic(context, veriExpense),
      AttentionIssueType.duplicateTransaction ||
      AttentionIssueType.unmatchedRefund ||
      AttentionIssueType.unallocatedRepayment ||
      AttentionIssueType.missingExchangeRate ||
      AttentionIssueType.lowConfidenceCapture ||
      AttentionIssueType.captureReview => veriSemantic(context, veriWarning),
      AttentionIssueType.bankOnlyTransaction ||
      AttentionIssueType.localOnlyTransaction => veriSemantic(
        context,
        veriBlue,
      ),
    };
