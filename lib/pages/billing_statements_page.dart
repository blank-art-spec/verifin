// 信用账户正式账单与还款分配页面。账单不复制消费流水，只保存银行口径和还款关系。
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/calendar_days.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';
import 'transaction_detail_page.dart';

class BillingStatementsPage extends StatelessWidget {
  const BillingStatementsPage({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final statements = controller.billingStatementsForAccount(account.id);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: l10n.billingStatementsTitle,
                subtitle: account.name,
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.add,
                    tooltip: l10n.billingStatementAdd,
                    onPressed: () => _addStatement(context),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (statements.isEmpty)
                EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: l10n.billingStatementsEmpty,
                  description: l10n.balanceAnchorHint,
                )
              else
                for (final statement in statements) ...<Widget>[
                  _StatementCard(account: account, statement: statement),
                  const SizedBox(height: 10),
                ],
            ],
          ),
        ),
      ),
    );
  }

  /// 依次采集正式账单必要字段。金额用统一数字键盘，日期用随当前语言的系统日期选择器。
  Future<void> _addStatement(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final statementDate = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 2),
      helpText: l10n.statementDateLabel,
    );
    if (!context.mounted || statementDate == null) return;
    final amount = await showNumberPadSheet(
      context,
      title: l10n.statementAmountLabel,
      allowZero: true,
      currencyCode: account.currencyCode,
    );
    if (!context.mounted || amount == null || amount < 0) return;
    final minimum = await showNumberPadSheet(
      context,
      title: l10n.minimumPaymentLabel,
      initialAmount: 0,
      allowZero: true,
      currencyCode: account.currencyCode,
    );
    if (!context.mounted || minimum == null || minimum > amount) return;
    final paid = await showNumberPadSheet(
      context,
      title: l10n.paidAmountLabel,
      initialAmount: 0,
      allowZero: true,
      currencyCode: account.currencyCode,
    );
    if (!context.mounted || paid == null || paid > amount) return;
    final dueDate = await showDatePicker(
      context: context,
      initialDate: DateTime(statementDate.year, statementDate.month + 1, 13),
      firstDate: statementDate,
      lastDate: DateTime(statementDate.year + 2),
      helpText: l10n.dueDateLabel,
    );
    if (!context.mounted || dueDate == null) return;

    // 未提供上一期正式账单时，以“上月同日次日”推导账期起点；用户后续导入银行
    // 正式账单时，同一期可按来源 id 幂等覆盖为银行给出的精确区间。
    final previousBoundary = DateTime(
      statementDate.year,
      statementDate.month - 1,
      statementDate.day.clamp(1, 28).toInt(),
    );
    final saved = await VeriFinScope.of(context).createBillingStatement(
      account: account,
      statementDate: statementDate,
      periodStart: addCalendarDays(previousBoundary, 1),
      periodEnd: DateTime(
        statementDate.year,
        statementDate.month,
        statementDate.day,
        23,
        59,
        59,
        999,
      ),
      statementAmount: amount,
      minimumPayment: minimum,
      dueDate: dueDate,
      paidAmount: paid,
    );
    if (!context.mounted || !saved) return;
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: l10n.billingStatementAdd,
        tone: VeriFeedbackTone.success,
      ),
    );
  }
}

class _StatementCard extends StatelessWidget {
  const _StatementCard({required this.account, required this.statement});

  final Account account;
  final BillingStatement statement;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return VeriCard(
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BillingStatementDetailPage(
            account: account,
            statementId: statement.id,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.dateMonthDay(statement.statementDate),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(_statusLabel(l10n, statement)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${l10n.statementAmountLabel} '
            '${formatUserMoney(statement.statementAmount, account.currencyCode)} · '
            '${l10n.paidAmountLabel} '
            '${formatUserMoney(statement.paidAmount, account.currencyCode)}',
          ),
          const SizedBox(height: 4),
          Text(
            l10n.statementRemaining(
              formatUserMoney(
                statement.outstandingAmount,
                account.currencyCode,
              ),
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: statement.outstandingAmount > 0
                  ? veriSemantic(context, veriExpense)
                  : veriSemantic(context, veriIncome),
            ),
          ),
        ],
      ),
    );
  }
}

class BillingStatementDetailPage extends StatelessWidget {
  const BillingStatementDetailPage({
    super.key,
    required this.account,
    required this.statementId,
  });

  final Account account;
  final String statementId;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final statement = controller.billingStatements
        .where((item) => item.id == statementId)
        .firstOrNull;
    final l10n = AppLocalizations.of(context);
    if (statement == null) return const SizedBox.shrink();
    final allocations = controller.allocationsForStatement(statement.id);
    final refunds = controller.refundAllocationsForStatement(statement.id);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: l10n.dateMonthDay(statement.statementDate),
                subtitle: _statusLabel(l10n, statement),
                showBack: true,
                actions: <Widget>[
                  HeaderAction(
                    icon: Icons.delete_outline,
                    tooltip: l10n.commonDelete,
                    onPressed: () => _delete(context, statement),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Row(
                  children: <Widget>[
                    SummaryMetric(
                      label: l10n.statementAmountLabel,
                      value: formatUserMoney(
                        statement.statementAmount,
                        account.currencyCode,
                      ),
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    SummaryMetric(
                      label: l10n.paidAmountLabel,
                      value: formatUserMoney(
                        statement.paidAmount,
                        account.currencyCode,
                      ),
                      color: veriSemantic(context, veriIncome),
                    ),
                    SummaryMetric(
                      label: l10n.billedOutstandingLabel,
                      value: formatUserMoney(
                        statement.outstandingAmount,
                        account.currencyCode,
                      ),
                      color: statement.outstandingAmount > 0
                          ? veriSemantic(context, veriExpense)
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (refunds.isNotEmpty) ...<Widget>[
                SectionLabel(l10n.statementPostBillRefund),
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      for (final (index, refund)
                          in refunds.indexed) ...<Widget>[
                        if (index > 0) const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.undo_outlined,
                          title: l10n.dateMonthDay(refund.settledAt),
                          trailing: formatUserMoney(
                            refund.amount,
                            account.currencyCode,
                          ),
                          onTap: () {
                            final refundEntry = controller.entries
                                .where(
                                  (item) => item.id == refund.refundEntryId,
                                )
                                .firstOrNull;
                            final original = controller.entries
                                .where(
                                  (item) => item.id == refundEntry?.refundOf,
                                )
                                .firstOrNull;
                            if (original != null) {
                              openEntryDetail(context, original);
                            }
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SectionLabel(l10n.repaymentAllocationsTitle),
              if (allocations.isEmpty)
                EmptyState(
                  icon: Icons.payments_outlined,
                  title: l10n.commonNoneShort,
                  description: l10n.creditRepayDefaultNote,
                )
              else
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      for (final (index, allocation)
                          in allocations.indexed) ...<Widget>[
                        if (index > 0) const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.payments_outlined,
                          title: l10n.creditRepayDefaultNote,
                          trailing: formatUserMoney(
                            allocation.amount,
                            account.currencyCode,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, BillingStatement statement) async {
    final confirmed = await showConfirmDialog(
      context,
      title: AppLocalizations.of(context).commonDelete,
      message: AppLocalizations.of(context).billingStatementsTitle,
      confirmLabel: AppLocalizations.of(context).commonDelete,
      destructive: true,
    );
    if (!context.mounted || confirmed != true) return;
    final deleted = await VeriFinScope.of(
      context,
    ).deleteBillingStatement(statement.id);
    if (context.mounted && deleted) Navigator.of(context).pop();
  }
}

String _statusLabel(AppLocalizations l10n, BillingStatement statement) {
  final status =
      statement.status == BillingStatementStatus.open &&
          statement.outstandingAmount > 0 &&
          statement.dueDate.isBefore(DateTime.now())
      ? BillingStatementStatus.overdue
      : statement.status;
  return switch (status) {
    BillingStatementStatus.paid => l10n.statementPaid,
    BillingStatementStatus.partiallyPaid => l10n.statementPartiallyPaid,
    BillingStatementStatus.overdue => l10n.statementOverdue,
    BillingStatementStatus.disputed => l10n.statementDisputed,
    BillingStatementStatus.open => l10n.statementOpen,
  };
}
