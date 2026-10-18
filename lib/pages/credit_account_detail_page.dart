import 'package:flutter/material.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'account_detail_page.dart';
import 'credit_account_editor_page.dart';
import 'credit_repayment_page.dart';
import 'entry_detail_page.dart';
import 'transaction_detail_page.dart';

/// 父账户仅聚合真实子账户，列表先合并去重排序，再应用最近条数限制。
class CreditAccountDetailPage extends StatefulWidget {
  const CreditAccountDetailPage({super.key, required this.parentId});
  final String parentId;
  @override
  State<CreditAccountDetailPage> createState() =>
      _CreditAccountDetailPageState();
}

class _CreditAccountDetailPageState extends State<CreditAccountDetailPage> {
  EntryType? _type;
  bool _recent = true;
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final parent = c.creditAccounts
        .where((p) => p.id == widget.parentId)
        .firstOrNull;
    if (parent == null) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(l.accountNameRequired))),
      );
    }
    final children = c.accountsForCreditAccount(parent.id);
    final valuation = c.accountBalancesInBase(accounts: children);
    final entries = c
        .entriesForCreditParent(parent.id)
        .where((e) => _type == null || e.type == _type)
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
                    icon: Icons.edit_outlined,
                    tooltip: l.creditAccountEditTitle,
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
                    Text(l.creditNetValue),
                    Text(
                      valuation.isComplete
                          ? formatUserMoney(
                              valuation.amountsByAccountId.values.fold<double>(
                                0,
                                (s, v) => s + v,
                              ),
                              c.activeBook.baseCurrencyCode,
                            )
                          : l.statisticsMissingRates(
                              valuation.missingCurrencyCodes.join(', '),
                            ),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (parent.creditLimit != null)
                      Text(
                        '${l.creditLimitLabel}：${formatUserMoney(parent.creditLimit!, parent.currencyCode)}',
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
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
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(l.allLabel),
                    selected: _type == null,
                    onSelected: (_) => setState(() => _type = null),
                  ),
                  for (final type in [EntryType.expense, EntryType.income])
                    ChoiceChip(
                      label: Text(type.label(l)),
                      selected: _type == type,
                      onSelected: (_) => setState(() => _type = type),
                    ),
                  FilterChip(
                    label: Text(l.panelRecentLabel),
                    selected: _recent,
                    onSelected: (v) => setState(() => _recent = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final e in _recent ? entries.take(20) : entries)
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
