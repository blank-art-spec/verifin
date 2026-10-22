import 'dart:async';
import 'package:flutter/material.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'account_detail_page.dart';
import 'credit_account_editor_page.dart';
import 'credit_repayment_page.dart';
import 'entry_detail_page.dart';
import 'transaction_detail_page.dart';
import 'sheets.dart';

enum _ParentEntryFilter { recent, all, expense, income }

/// 父账户仅聚合真实子账户，列表先合并去重排序，再应用最近条数限制。
class CreditAccountDetailPage extends StatefulWidget {
  const CreditAccountDetailPage({super.key, required this.parentId});
  final String parentId;
  @override
  State<CreditAccountDetailPage> createState() =>
      _CreditAccountDetailPageState();
}

class _CreditAccountDetailPageState extends State<CreditAccountDetailPage> {
  _ParentEntryFilter _filter = _ParentEntryFilter.recent;
  bool _creating = false;

  /// 为当前主账户选择尚未创建的币种；取消或跨账本时不写入，失败保留原子账户。
  Future<void> _addChild() async {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final bookId = c.activeBook.id;
    final selected = await showCurrencyPickerSheet(
      context: context,
      title: l.creditAddCurrencyChild,
      excludedCodes: c
          .accountsForParent(widget.parentId)
          .map((a) => a.currencyCode),
      preferredCodes: [
        c.activeBook.baseCurrencyCode,
        'USD',
        'EUR',
        'HKD',
        'JPY',
      ],
    );
    if (!mounted || selected == null || c.activeBook.id != bookId) return;
    setState(() => _creating = true);
    final child = await c.ensureCurrencyChild(widget.parentId, selected.code);
    if (!mounted) return;
    setState(() => _creating = false);
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: child == null
            ? l.saveFailed
            : l.creditCurrencyChildAdded(selected.code),
        tone: child == null ? VeriFeedbackTone.error : VeriFeedbackTone.success,
      ),
    );
  }

  /// 展示主账户估值、真实币种子账户和合并流水；信用业务单独按能力显示。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final parent = c.accountParents
        .where((p) => p.id == widget.parentId)
        .firstOrNull;
    if (parent == null) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(l.accountNameRequired))),
      );
    }
    final children = c.accountsForParent(parent.id);
    final isCredit = children.any((a) => a.type.supportsCredit);
    final displayCode = isCredit
        ? c.activeBook.baseCurrencyCode
        : parent.currencyCode;
    final valuation = c.parentAccountBalances(parent);
    final entries = c
        .entriesForParent(parent.id)
        .where(
          (e) => switch (_filter) {
            _ParentEntryFilter.expense => e.type == EntryType.expense,
            _ParentEntryFilter.income => e.type == EntryType.income,
            _ => true,
          },
        )
        .toList();
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              VeriHeader(
                title: parent.name,
                subtitle: l.creditChildAccountsSummary(
                  children.length,
                  children.map((a) => a.currencyCode).join(' · '),
                ),
                showBack: true,
                actions: [
                  HeaderAction(
                    icon: Icons.add,
                    tooltip: l.creditAddCurrencyChild,
                    onPressed: _creating ? null : _addChild,
                  ),
                  HeaderAction(
                    icon: Icons.edit_outlined,
                    tooltip: isCredit
                        ? l.creditAccountEditTitle
                        : l.accountParentSettings,
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            CreditAccountEditorPage(creditAccount: parent),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isCredit ? l.creditNetValue : l.accountParentValuation,
                    ),
                    Text(
                      valuation.isComplete
                          ? formatUserMoney(
                              valuation.amountsByAccountId.values.fold<double>(
                                0,
                                (s, v) => s + v,
                              ),
                              displayCode,
                            )
                          : l.statisticsMissingRates(
                              valuation.missingCurrencyCodes.join(', '),
                            ),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (isCredit && parent.creditLimit != null)
                      Text(
                        '${l.creditLimitLabel}：${formatUserMoney(parent.creditLimit!, parent.currencyCode)}',
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (isCredit)
                          FilledButton.tonal(
                            onPressed: children.isEmpty
                                ? null
                                : () => Navigator.of(context).push<void>(
                                    MaterialPageRoute(
                                      builder: (_) => CreditRepaymentPage(
                                        account: children.first,
                                      ),
                                    ),
                                  ),
                            child: Text(l.creditRepayTitle),
                          ),
                        OutlinedButton(
                          onPressed: children.isEmpty
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    builder: (_) => EntryDetailPage(
                                      initialAmount: 0,
                                      initialAccountId: children.first.id,
                                      initialCreditAccountId: parent.id,
                                    ),
                                  ),
                                ),
                          child: Text(l.creditParentPick),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionLabel(l.creditChildren),
              VeriCard(
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      for (final a in children)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: AccountIconBox(
                            iconCode: a.iconCode,
                            size: 32,
                          ),
                          title: Text(a.name),
                          subtitle: Text(a.currencyCode),
                          trailing: Text(
                            formatUserMoney(
                              c.accountBalance(a),
                              a.currencyCode,
                            ),
                          ),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => AccountDetailPage(account: a),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SectionLabel(l.creditParentTransactions),
              VeriSegmentedControl<_ParentEntryFilter>(
                key: const Key('credit_parent_entry_filter'),
                values: _ParentEntryFilter.values,
                selected: _filter,
                keyOf: (value) => Key('credit_parent_filter_${value.name}'),
                labelOf: (value) => switch (value) {
                  _ParentEntryFilter.recent => l.panelRecentLabel,
                  _ParentEntryFilter.all => l.allLabel,
                  _ParentEntryFilter.expense => EntryType.expense.label(l),
                  _ParentEntryFilter.income => EntryType.income.label(l),
                },
                onChanged: (value) => setState(() => _filter = value),
              ),
              const SizedBox(height: 8),
              for (final e
                  in _filter == _ParentEntryFilter.recent
                      ? entries.take(20)
                      : entries)
                TransactionTile(
                  e,
                  accounts: c.accounts,
                  categories: c.categories,
                  tags: c.tags,
                  baseCurrencyCode: c.activeBook.baseCurrencyCode,
                  showDate: true,
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => TransactionDetailPage(entryId: e.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
