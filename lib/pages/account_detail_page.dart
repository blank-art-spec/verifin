// 账户详情相关页面：从 assets_pages 拆出。账户详情/编辑、账户报表、
// 信用卡还款日横幅与迷你分段切换控件。
import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/account_icon_assets.dart';
import '../app/app_theme.dart';
import '../app/chart_painters.dart';
import '../app/common_widgets.dart';
import '../app/credit_card.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/icon_catalog.dart';
import '../app/ledger_math.dart';
import '../app/models.dart';
import '../app/series_math.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'billing_statements_page.dart';
import 'credit_account_editor_page.dart';
import 'credit_repayment_page.dart';
import 'entry_detail_page.dart';
import 'sheets.dart';
import 'transactions_pages.dart';

const double assetCoverAspectRatio = 1200 / 760;

const int assetCoverTargetWidth = 1200;

const int assetCoverTargetHeight = 760;

class AccountDetailPage extends StatefulWidget {
  const AccountDetailPage({super.key, required this.account});

  final Account account;

  @override
  State<AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends State<AccountDetailPage> {
  final EditorExitController _exitController = EditorExitController();
  bool _monthlyTrend = false;
  late Account _initialAccount;
  late Account _draftAccount;
  late bool _initialDefault;
  late bool _draftDefault;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    final controller = VeriFinScope.of(context);
    final account = controller.accounts.firstWhere(
      (item) => item.id == widget.account.id,
      orElse: () => widget.account,
    );
    _initialAccount = account;
    _draftAccount = account;
    _initialDefault = controller.defaultAccountId == account.id;
    _draftDefault = _initialDefault;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final persistedAccount = controller.accounts.firstWhere(
      (item) => item.id == widget.account.id,
      orElse: () => widget.account,
    );
    // 创建账户后调用方可能仍持有“尚未回填信用主体 id”的旧快照；渲染时用
    // Controller 的持久化关联补齐本地视图，避免主体选择器误显示为未选择。
    final currentAccount =
        _draftAccount.type.supportsCredit &&
            _draftAccount.creditAccountId == null &&
            persistedAccount.creditAccountId != null
        ? _draftAccount.copyWith(
            creditAccountId: persistedAccount.creditAccountId,
          )
        : _draftAccount;
    final creditAccount = controller.creditAccountForAccount(currentAccount);
    final creditCycleOverview = creditAccount == null
        ? null
        : controller.creditCycleOverview(creditAccount);
    final creditDueDate = creditAccount?.hasCompleteCycleRule == true
        ? creditCycleOverview!.dueDate
        : null;
    final balance = controller.accountBalance(currentAccount);
    final entries = controller.entries
        .where((entry) => entryTouchesAccount(entry, currentAccount.id))
        .toList();
    final timelineEntries = accountTimelineEntries(
      controller.entries,
      currentAccount.id,
    );
    final balanceTrendValues = _monthlyTrend
        ? accountMonthlyBalanceSeries(currentAccount, entries)
        : accountBalanceSeries(currentAccount, entries);
    final matchingGroups = controller.accountGroups.where(
      (group) => group.id == currentAccount.groupId,
    );
    final groupName = matchingGroups.isEmpty
        ? AppLocalizations.of(context).assetsUngrouped
        : matchingGroups.first.name;

    return UnsavedChangesGuard(
      isDirty: _isDirty,
      onSave: _save,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
              children: <Widget>[
                VeriHeader(
                  title: currentAccount.name,
                  subtitle: currencyUnitSubtitle(
                    AppLocalizations.of(context),
                    currentAccount.type.label(AppLocalizations.of(context)),
                    currentAccount.currencyCode,
                  ),
                  showBack: true,
                  actions: <Widget>[
                    HeaderAction(
                      icon: Icons.edit_outlined,
                      tooltip: AppLocalizations.of(
                        context,
                      ).balanceAdjustTooltip,
                      onPressed: () => currentAccount.type.supportsCredit
                          ? _confirmBalanceAnchor(persistedAccount, balance)
                          : _editBalance(persistedAccount, balance),
                    ),
                    SaveHeaderAction(onPressed: _isDirty ? _saveAndExit : null),
                  ],
                ),
                const SizedBox(height: 10),
                if (currentAccount.type.supportsCredit &&
                    creditDueDate != null) ...<Widget>[
                  _CreditCardDueBanner(dueDate: creditDueDate),
                  const SizedBox(height: 10),
                ],
                VeriCard(
                  onTap: () => currentAccount.type.supportsCredit
                      ? _confirmBalanceAnchor(persistedAccount, balance)
                      : _editBalance(persistedAccount, balance),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(AppLocalizations.of(context).currentBalance),
                            const SizedBox(height: 6),
                            Text(
                              formatUserMoney(
                                balance,
                                currentAccount.currencyCode,
                              ),
                              style: Theme.of(context).textTheme.displaySmall
                                  ?.copyWith(
                                    color: veriSemantic(context, veriBlue),
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      VeriIconBox(icon: Icons.edit_outlined, size: 36),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (currentAccount.type.supportsCredit &&
                    (creditAccount?.creditLimit != null ||
                        currentAccount.creditLimit != null ||
                        creditAccount?.statementDay != null ||
                        currentAccount.statementDay != null ||
                        controller
                            .billingStatementsForAccount(currentAccount.id)
                            .isNotEmpty)) ...<Widget>[
                  _CreditSummaryCard(
                    account: currentAccount,
                    balance: balance,
                    overview: controller.creditOverview(currentAccount),
                    creditAccount: creditAccount,
                    creditCycleOverview: creditCycleOverview,
                  ),
                  const SizedBox(height: 10),
                ],
                if (currentAccount.type.supportsCredit) ...<Widget>[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _startRepayment(persistedAccount),
                      icon: const Icon(Icons.payments_outlined),
                      label: Text(
                        AppLocalizations.of(context).creditRepayAction,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                VeriCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context).balanceTrend,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          _MiniSegmentedToggle(
                            value: _monthlyTrend,
                            leftLabel: AppLocalizations.of(context).dayShort,
                            rightLabel: AppLocalizations.of(context).monthShort,
                            onChanged: (value) =>
                                setState(() => _monthlyTrend = value),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 148,
                        child: InteractiveTrendChart(
                          color: veriSemantic(context, veriBlue),
                          values: balanceTrendValues,
                          xLabels: _monthlyTrend
                              ? evenMonthAxisLabels()
                              : monthAxisLabels(DateTime.now()),
                          yLabels: balanceAxisLabels(
                            balanceTrendValues,
                            currentAccount.currencyCode,
                          ),
                          labelColor: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.50),
                          tooltipOf: (index) => ChartTooltip(
                            title: _monthlyTrend
                                ? AppLocalizations.of(
                                    context,
                                  ).monthNumber(index + 1)
                                : AppLocalizations.of(context).dateMonthDay(
                                    DateTime(
                                      DateTime.now().year,
                                      DateTime.now().month,
                                      index + 1,
                                    ),
                                  ),
                            lines: <ChartTooltipLine>[
                              ChartTooltipLine(
                                text: AppLocalizations.of(context)
                                    .balanceAmount(
                                      formatUserMoney(
                                        balanceTrendValues[index],
                                        currentAccount.currencyCode,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (context) =>
                                  AccountReportPage(account: persistedAccount),
                            ),
                          );
                        },
                        child: Text(AppLocalizations.of(context).viewReport),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                VeriCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context).panelRecentLabel,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                          ),
                          VeriSectionAction(
                            icon: Icons.add,
                            tooltip: AppLocalizations.of(
                              context,
                            ).addEntryTooltip,
                            onPressed: () => _startEntryForAccount(
                              context,
                              persistedAccount,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (timelineEntries.isEmpty)
                        EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: AppLocalizations.of(context).noEntriesTitle,
                          description: AppLocalizations.of(
                            context,
                          ).accountNoEntriesDesc,
                        )
                      else
                        ...timelineEntries
                            .take(3)
                            .map(
                              (entry) => TransactionTile(
                                entry,
                                accounts: controller.accounts,
                                categories: controller.categories,
                                tags: controller.tags,
                                showDate: true,
                                baseCurrencyCode:
                                    controller.activeBook.baseCurrencyCode,
                                onTap: () => openEntryDetail(context, entry),
                              ),
                            ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (context) => TransactionsPage(
                                accountId: currentAccount.id,
                                title: AppLocalizations.of(
                                  context,
                                ).accountEntriesTitle(currentAccount.name),
                              ),
                            ),
                          );
                        },
                        child: Text(AppLocalizations.of(context).allEntries),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SectionLabel(AppLocalizations.of(context).accountSectionBasic),
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      VeriAnchoredChoice<AccountType>(
                        key: const Key('account_detail_type_choice'),
                        values: AccountType.values,
                        selected: currentAccount.type,
                        idOf: (value) => 'account_detail_type_${value.name}',
                        labelOf: (value) =>
                            value.label(AppLocalizations.of(context)),
                        subtitleOf: (value) =>
                            value.capabilityHint(AppLocalizations.of(context)),
                        onSelected: (value) =>
                            _selectAccountType(currentAccount, value),
                        semanticLabel: AppLocalizations.of(
                          context,
                        ).accountTypePickerTitle,
                        builder: (context, openMenu, menuOpen) => SettingsRow(
                          icon: Icons.category_outlined,
                          title: AppLocalizations.of(context).commonType,
                          trailing: currentAccount.type.label(
                            AppLocalizations.of(context),
                          ),
                          trailingIcon: Icons.chevron_right,
                          onTap: openMenu,
                        ),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.badge_outlined,
                        title: AppLocalizations.of(context).commonName,
                        trailing: currentAccount.name,
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _editAccountName(currentAccount),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        leading: AccountIconBox(
                          iconCode: currentAccount.iconCode,
                          size: 28,
                        ),
                        title: AppLocalizations.of(context).commonIcon,
                        trailing: iconLabelForCode(
                          AppLocalizations.of(context),
                          currentAccount.iconCode,
                        ),
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _pickAccountIcon(currentAccount),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.currency_exchange,
                        title: AppLocalizations.of(context).commonCurrency,
                        trailing:
                            '${currentAccount.currencyCode} · ${CurrencyCatalog.require(currentAccount.currencyCode).nameForLocale(Localizations.localeOf(context).toLanguageTag())}',
                        trailingIcon:
                            controller.accountCurrencyLocked(persistedAccount)
                            ? Icons.lock_outline
                            : Icons.chevron_right,
                        onTap: () => _pickAccountCurrency(
                          persistedAccount,
                          currentAccount,
                        ),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.notes,
                        title: AppLocalizations.of(context).commonNote,
                        trailing: currentAccount.note.isEmpty
                            ? AppLocalizations.of(context).commonNoneShort
                            : currentAccount.note,
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _editAccountNote(currentAccount),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.folder_outlined,
                        title: AppLocalizations.of(context).commonGroup,
                        trailing: groupName,
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _pickAccountGroup(currentAccount),
                      ),
                    ],
                  ),
                ),
                if (currentAccount.type.supportsCardLast4) ...<Widget>[
                  const SizedBox(height: 12),
                  SectionLabel(AppLocalizations.of(context).accountSectionCard),
                  VeriCard(
                    child: Column(
                      children: <Widget>[
                        if (creditAccount != null) ...<Widget>[
                          SettingsRow(
                            icon: Icons.account_balance_outlined,
                            title: AppLocalizations.of(
                              context,
                            ).creditAccountParentLabel,
                            trailing: creditAccount.name,
                            trailingIcon: Icons.chevron_right,
                            onTap: () => _pickCreditAccountParent(
                              currentAccount,
                              controller.creditAccounts,
                            ),
                          ),
                          const Divider(height: 1),
                          SettingsRow(
                            icon: Icons.tune_outlined,
                            title: AppLocalizations.of(
                              context,
                            ).creditAccountEditTitle,
                            trailing: creditAccount.currencyCode,
                            trailingIcon: Icons.chevron_right,
                            onTap: () =>
                                _openCreditAccountEditor(creditAccount),
                          ),
                          const Divider(height: 1),
                        ],
                        SettingsRow(
                          icon: Icons.credit_card,
                          title: AppLocalizations.of(context).cardLabel,
                          trailing: currentAccount.cardLast4.isEmpty
                              ? AppLocalizations.of(context).notSet
                              : currentAccount.cardLast4,
                          trailingIcon: Icons.chevron_right,
                          onTap: () => _editCard(currentAccount),
                        ),
                        if (currentAccount.cardNumber.isNotEmpty) ...<Widget>[
                          const Divider(height: 1),
                          SettingsRow(
                            icon: Icons.numbers_outlined,
                            title: AppLocalizations.of(context).cardNumberTitle,
                            trailing: currentAccount.cardNumber,
                            trailingIcon: Icons.copy_outlined,
                            onTap: () =>
                                _copyCardNumber(currentAccount.cardNumber),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (currentAccount.type.supportsCredit) ...<Widget>[
                  const SizedBox(height: 12),
                  SectionLabel(
                    AppLocalizations.of(context).accountSectionCredit,
                  ),
                  VeriCard(
                    child: Column(
                      children: <Widget>[
                        SettingsRow(
                          icon: Icons.speed_outlined,
                          title: AppLocalizations.of(context).creditLimitLabel,
                          trailing:
                              (creditAccount?.creditLimit ??
                                      currentAccount.creditLimit) ==
                                  null
                              ? AppLocalizations.of(context).notSet
                              : formatUserMoney(
                                  creditAccount?.creditLimit ??
                                      currentAccount.creditLimit!,
                                  creditAccount?.currencyCode ??
                                      currentAccount.currencyCode,
                                ),
                          trailingIcon: Icons.chevron_right,
                          onTap: () => creditAccount == null
                              ? _editCreditLimit(currentAccount)
                              : _openCreditAccountEditor(creditAccount),
                        ),
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.event_note_outlined,
                          title: AppLocalizations.of(context).statementDay,
                          trailing:
                              (creditAccount?.statementDay ??
                                      currentAccount.statementDay) ==
                                  null
                              ? AppLocalizations.of(context).notSet
                              : AppLocalizations.of(context).monthlyDayLabel(
                                  creditAccount?.statementDay ??
                                      currentAccount.statementDay!,
                                ),
                          trailingIcon: Icons.chevron_right,
                          onTap: () => creditAccount == null
                              ? _pickBillingDay(currentAccount, false)
                              : _openCreditAccountEditor(creditAccount),
                        ),
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.event_available_outlined,
                          title: creditAccount == null
                              ? AppLocalizations.of(context).dueDay
                              : AppLocalizations.of(context).creditDueRuleLabel,
                          trailing:
                              creditAccount?.dueRuleType ==
                                  CreditDueRuleType.daysAfterStatement
                              ? creditAccount?.daysAfterStatement == null
                                    ? AppLocalizations.of(context).notSet
                                    : AppLocalizations.of(
                                        context,
                                      ).creditDaysAfterStatement(
                                        creditAccount!.daysAfterStatement!,
                                      )
                              : (creditAccount?.dueDay ??
                                        currentAccount.dueDay) ==
                                    null
                              ? AppLocalizations.of(context).notSet
                              : AppLocalizations.of(context).monthlyDayLabel(
                                  creditAccount?.dueDay ??
                                      currentAccount.dueDay!,
                                ),
                          trailingIcon: Icons.chevron_right,
                          onTap: () => creditAccount == null
                              ? _pickBillingDay(currentAccount, true)
                              : _openCreditAccountEditor(creditAccount),
                        ),
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.verified_outlined,
                          title: AppLocalizations.of(
                            context,
                          ).balanceAnchorAction,
                          trailing: _anchorLabel(
                            context,
                            controller.latestBalanceAnchor(currentAccount.id),
                            currentAccount.currencyCode,
                          ),
                          trailingIcon: Icons.chevron_right,
                          onTap: () =>
                              _confirmBalanceAnchor(persistedAccount, balance),
                        ),
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.receipt_long_outlined,
                          title: AppLocalizations.of(
                            context,
                          ).billingStatementsAction,
                          trailing: controller
                              .billingStatementsForAccount(currentAccount.id)
                              .length
                              .toString(),
                          trailingIcon: Icons.chevron_right,
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => BillingStatementsPage(
                                account: persistedAccount,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SectionLabel(
                  AppLocalizations.of(context).accountSectionDisplay,
                ),
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      CompactSwitchRow(
                        icon: Icons.account_balance_wallet_outlined,
                        title: Text(
                          AppLocalizations.of(context).includeInAssets,
                        ),
                        value: currentAccount.includeInAssets,
                        onChanged: (value) => setState(
                          () => _draftAccount = currentAccount.copyWith(
                            includeInAssets: value,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      CompactSwitchRow(
                        icon: Icons.visibility_off_outlined,
                        title: Text(AppLocalizations.of(context).accountHide),
                        value: currentAccount.hidden,
                        onChanged: (value) => setState(() {
                          _draftAccount = currentAccount.copyWith(
                            hidden: value,
                          );
                          if (value) {
                            _draftDefault = false;
                          }
                        }),
                      ),
                      // 设为该账本记账时的默认付款账户（关闭即清除默认）。隐藏账户不提供。
                      if (!currentAccount.hidden) ...<Widget>[
                        const Divider(height: 1),
                        CompactSwitchRow(
                          icon: Icons.push_pin_outlined,
                          title: Text(
                            AppLocalizations.of(context).setAsDefaultAccount,
                          ),
                          subtitle: Text(
                            AppLocalizations.of(
                              context,
                            ).setAsDefaultAccountHint,
                          ),
                          value: _draftDefault,
                          onChanged: (value) =>
                              setState(() => _draftDefault = value),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionLabel(AppLocalizations.of(context).accountSectionDanger),
                VeriCard(
                  child: SettingsRow(
                    icon: Icons.delete_outline,
                    title: AppLocalizations.of(context).accountDelete,
                    contentColor: veriSemantic(context, veriExpense),
                    trailing: entries.isEmpty
                        ? AppLocalizations.of(context).deletableLabel
                        : AppLocalizations.of(context).hasEntriesLabel,
                    trailingIcon: Icons.chevron_right,
                    onTap: () async {
                      final completed = await confirmDeleteAccount(
                        context,
                        persistedAccount,
                        entries,
                      );
                      if (completed && mounted) {
                        _exitController.exit();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editBalance(Account account, double balance) async {
    final amount = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).balanceAdjustTooltip,
      initialAmount: balance,
      allowNegative: true,
      allowZero: true,
      currencyCode: account.currencyCode,
    );
    if (amount == null || !mounted) {
      return;
    }
    var recordEntry = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(AppLocalizations.of(context).balanceEditConfirmTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                AppLocalizations.of(context).balanceEditConfirmMessage(
                  account.name,
                  formatUserMoney(amount, account.currencyCode),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: recordEntry,
                onChanged: (value) =>
                    setDialogState(() => recordEntry = value ?? true),
                title: Text(AppLocalizations.of(context).balanceEditRecord),
                subtitle: Text(
                  AppLocalizations.of(context).balanceEditRecordDesc,
                ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(AppLocalizations.of(context).commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(AppLocalizations.of(context).commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final controller = VeriFinScope.of(context);
    if (recordEntry) {
      final saved = controller.adjustAccountBalance(
        account,
        amount,
        note: AppLocalizations.of(context).balanceAdjustNote,
      );
      if (!saved && mounted) {
        unawaited(
          VeriFeedbackHost.of(context).showMessage(
            message: AppLocalizations.of(
              context,
            ).balanceAdjustMissingRate(account.currencyCode),
            tone: VeriFeedbackTone.warning,
            duration: VeriFeedbackDuration.long,
          ),
        );
      }
    } else {
      controller.rebaseAccountBalance(account, amount);
    }
  }

  /// 为信用账户写入正式余额锚点；不生成“历史结清校准”交易。
  Future<void> _confirmBalanceAnchor(Account account, double balance) async {
    final l10n = AppLocalizations.of(context);
    final amount = await showNumberPadSheet(
      context,
      title: l10n.balanceAnchorTitle,
      initialAmount: balance,
      allowNegative: true,
      allowZero: true,
      currencyCode: account.currencyCode,
    );
    if (!mounted || amount == null) return;
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(2000),
      lastDate: now,
      helpText: l10n.balanceAnchorDate,
    );
    if (!mounted || picked == null) return;
    final isToday =
        picked.year == now.year &&
        picked.month == now.month &&
        picked.day == now.day;
    final effectiveAt = isToday
        ? now
        : DateTime(picked.year, picked.month, picked.day, 23, 59, 59, 999);
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.balanceAnchorTitle,
      message: l10n.balanceAnchorHint,
      confirmLabel: l10n.commonConfirm,
    );
    if (!mounted || confirmed != true) return;
    final saved = await VeriFinScope.of(context).saveBalanceAnchor(
      account: account,
      effectiveAt: effectiveAt,
      balance: amount,
      note: l10n.balanceAnchorTitle,
    );
    if (!mounted || !saved) return;
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: l10n.balanceAnchorSaved,
        tone: VeriFeedbackTone.success,
      ),
    );
  }

  String _anchorLabel(
    BuildContext context,
    BalanceAnchor? anchor,
    String currencyCode,
  ) {
    if (anchor == null) return AppLocalizations.of(context).notSet;
    return AppLocalizations.of(context).balanceAnchorLatest(
      AppLocalizations.of(context).dateMonthDay(anchor.effectiveAt),
      formatUserMoney(anchor.balance, currencyCode),
    );
  }

  Future<void> _startEntryForAccount(
    BuildContext context,
    Account account,
  ) async {
    final amount = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).quickEntry,
      currencyCode: account.currencyCode,
    );
    if (!context.mounted || amount == null || amount <= 0) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => EntryDetailPage(
          initialAmount: amount,
          initialAccountId: account.id,
        ),
      ),
    );
  }

  void _selectAccountType(Account account, AccountType selected) {
    if (account.type == selected) return;
    // 切换期间保留暂时隐藏的卡片/信用草稿，用户切回原类型时不会丢输入；
    // 只有最终保存为不支持该能力的类型时才清空对应字段。
    setState(() => _draftAccount = account.copyWith(type: selected));
  }

  Future<void> _pickAccountCurrency(
    Account persistedAccount,
    Account currentAccount,
  ) async {
    var controller = VeriFinScope.of(context);
    var accountDraft = currentAccount;
    if (controller.accountCurrencyLocked(persistedAccount)) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).accountCurrencyLocked,
          tone: VeriFeedbackTone.warning,
        ),
      );
      return;
    }
    if (controller.activeBook.currencySetupStatus ==
        CurrencySetupStatus.legacyUnconfirmed) {
      final confirmed = await confirmLegacyLedgerCurrency(
        context: context,
        book: controller.activeBook,
      );
      if (!mounted || !confirmed) return;
      controller = VeriFinScope.of(context);
      final latest = controller.accounts.firstWhere(
        (account) => account.id == persistedAccount.id,
        orElse: () => currentAccount,
      );
      setState(() {
        _initialAccount = latest;
        _draftAccount = latest;
      });
      accountDraft = latest;
    }
    final selected = await showCurrencyPickerSheet(
      context: context,
      title: AppLocalizations.of(context).selectAccountCurrency,
      selectedCode: accountDraft.currencyCode,
      preferredCodes: controller.accounts.map(
        (account) => account.currencyCode,
      ),
    );
    if (selected != null && mounted) {
      setState(
        () =>
            _draftAccount = accountDraft.copyWith(currencyCode: selected.code),
      );
    }
  }

  Future<void> _editAccountName(Account account) async {
    final name = await showTextInputDialog(
      context: context,
      title: AppLocalizations.of(context).accountNameEditTitle,
      label: AppLocalizations.of(context).accountNameLabel,
      initialValue: account.name,
    );
    if (name != null && mounted) {
      final suggested = suggestedAccountIconCode(name);
      setState(() {
        _draftAccount = account.copyWith(
          name: name,
          iconCode: suggested ?? account.iconCode,
        );
      });
    }
  }

  Future<void> _editCard(Account account) async {
    final result = await showCardNumberDialog(
      context: context,
      initialNumber: account.cardNumber,
      initialLast4: account.cardLast4,
      initialFollows: account.cardLast4Follows,
    );
    if (result == null || !mounted) {
      return;
    }
    setState(() {
      _draftAccount = account.copyWith(
        cardNumber: result.number,
        cardLast4: result.last4,
        cardLast4Follows: result.follows,
      );
    });
  }

  Future<void> _copyCardNumber(String cardNumber) async {
    await Clipboard.setData(ClipboardData(text: cardNumber));
    if (!mounted) {
      return;
    }
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: AppLocalizations.of(context).copiedToClipboard,
        tone: VeriFeedbackTone.success,
        duration: VeriFeedbackDuration.short,
      ),
    );
  }

  void _startRepayment(Account account) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => CreditRepaymentPage(account: account),
      ),
    );
  }

  /// 设置信用额度；输入 0 视为清除额度（不再展示可用额度）。
  Future<void> _editCreditLimit(Account account) async {
    final amount = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).creditLimitEditTitle,
      initialAmount: account.creditLimit,
      allowZero: true,
      currencyCode: account.currencyCode,
    );
    if (amount == null || !mounted) {
      return;
    }
    setState(() {
      _draftAccount = account.copyWith(
        creditLimit: amount <= 0 ? null : amount,
        clearCreditLimit: amount <= 0,
      );
    });
  }

  /// 把当前币种账户改挂到另一个信用主体。选择只更新页面草稿；用户点击右上角保存后，
  /// Controller 才会原子写入账户与主体，并在旧主体没有其他子账户时清理它。
  Future<void> _pickCreditAccountParent(
    Account account,
    List<CreditAccount> creditAccounts,
  ) async {
    final candidates = creditAccounts
        .where((item) => item.bookId == account.bookId)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final selected = await showOptionSheet<String>(
      context: context,
      title: AppLocalizations.of(context).creditAccountParentLabel,
      values: candidates.map((item) => item.id).toList(growable: false),
      // 旧备份或尚未保存的草稿可能还没有主体 ID；空字符串不会命中任何候选项，
      // 因而弹窗只是不显示选中标记，不会误把第一个主体当成用户选择。
      selected: account.creditAccountId ?? '',
      labelOf: (value) =>
          candidates.firstWhere((item) => item.id == value).name,
    );
    if (!mounted || selected == null || selected == account.creditAccountId) {
      return;
    }
    final parent = candidates.firstWhere((item) => item.id == selected);
    setState(() {
      _draftAccount = account.copyWith(
        creditAccountId: parent.id,
        creditLimit: parent.creditLimit,
        clearCreditLimit: parent.creditLimit == null,
        statementDay: parent.statementDay,
        clearStatementDay: parent.statementDay == null,
        dueDay: parent.dueRuleType == CreditDueRuleType.fixedDay
            ? parent.dueDay
            : null,
        clearDueDay:
            parent.dueRuleType != CreditDueRuleType.fixedDay ||
            parent.dueDay == null,
      );
    });
  }

  /// 打开父主体编辑页。共享额度、卡尾号、账单规则与账期预算只在该页维护，
  /// 子账户详情不再各自保存一套容易互相覆盖的配置。
  Future<void> _openCreditAccountEditor(CreditAccount creditAccount) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CreditAccountEditorPage(creditAccount: creditAccount),
      ),
    );
    if (!mounted) return;
    final latest = VeriFinScope.of(
      context,
    ).accounts.where((item) => item.id == _draftAccount.id).firstOrNull;
    if (latest == null) return;

    // 父主体页可能已经同步了卡尾号、额度和日期镜像。把这些已持久化字段同时并入
    // 初始值与当前草稿：既避免随后保存备注时用旧镜像反向覆盖主体，也不会把这次
    // 父页保存误判为本页未保存修改。名称、备注、分组等本页草稿保持不变。
    Account mergeSharedFields(Account base) => base.copyWith(
      creditAccountId: latest.creditAccountId,
      cardLast4: latest.cardLast4,
      creditLimit: latest.creditLimit,
      clearCreditLimit: latest.creditLimit == null,
      statementDay: latest.statementDay,
      clearStatementDay: latest.statementDay == null,
      dueDay: latest.dueDay,
      clearDueDay: latest.dueDay == null,
    );
    setState(() {
      _initialAccount = mergeSharedFields(_initialAccount);
      _draftAccount = mergeSharedFields(_draftAccount);
    });
  }

  Future<void> _pickAccountIcon(Account account) async {
    final selected = await showAccountIconSheet(
      context: context,
      selected: account.iconCode,
    );
    if (selected != null && mounted) {
      setState(() => _draftAccount = account.copyWith(iconCode: selected));
    }
  }

  /// 选择信用卡账单日 / 还款日（1–28 或不设置）。
  Future<void> _pickBillingDay(Account account, bool isDue) async {
    const clearValue = 0;
    final current =
        (isDue ? account.dueDay : account.statementDay) ?? clearValue;
    final selected = await showOptionSheet<int>(
      context: context,
      title: isDue
          ? AppLocalizations.of(context).pickDueDay
          : AppLocalizations.of(context).pickStatementDay,
      values: <int>[clearValue, for (var d = 1; d <= 28; d++) d],
      selected: current,
      labelOf: (value) => value == clearValue
          ? AppLocalizations.of(context).clearOption
          : AppLocalizations.of(context).monthlyDayLabel(value),
    );
    if (selected == null || !mounted) {
      return;
    }
    if (isDue) {
      setState(() {
        _draftAccount = account.copyWith(
          dueDay: selected == clearValue ? null : selected,
          clearDueDay: selected == clearValue,
        );
      });
    } else {
      setState(() {
        _draftAccount = account.copyWith(
          statementDay: selected == clearValue ? null : selected,
          clearStatementDay: selected == clearValue,
        );
      });
    }
  }

  Future<void> _editAccountNote(Account account) async {
    final note = await showTextInputDialog(
      context: context,
      title: AppLocalizations.of(context).accountNoteEditTitle,
      label: AppLocalizations.of(context).commonNote,
      initialValue: account.note,
      allowEmpty: true,
    );
    if (note != null && mounted) {
      setState(() => _draftAccount = account.copyWith(note: note));
    }
  }

  Future<void> _pickAccountGroup(Account account) async {
    final controller = VeriFinScope.of(context);
    final groups = controller.accountGroups;
    final values = <String>['ungrouped', ...groups.map((group) => group.id)];
    final selected = await showOptionSheet<String>(
      context: context,
      title: AppLocalizations.of(context).accountGroupPickerTitle,
      values: values,
      selected: account.groupId ?? 'ungrouped',
      labelOf: (value) {
        if (value == 'ungrouped') {
          return AppLocalizations.of(context).assetsUngrouped;
        }
        return groups.firstWhere((group) => group.id == value).name;
      },
    );
    if (selected != null && mounted) {
      setState(() => _draftAccount = account.copyWith(groupId: selected));
    }
  }

  bool get _isDirty =>
      !mapEquals(_initialAccount.toJson(), _draftAccount.toJson()) ||
      _initialDefault != _draftDefault;

  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      setState(() {
        _initialAccount = _draftAccount;
        _initialDefault = _draftDefault;
      });
      _exitController.exit();
    }
  }

  Future<bool> _save() async {
    final controller = VeriFinScope.of(context);
    final account = _draftAccount;
    final normalized = account.copyWith(
      cardLast4: account.type.supportsCardLast4 ? account.cardLast4 : '',
      cardNumber: account.type.supportsCardLast4 ? account.cardNumber : '',
      clearCreditLimit: !account.type.supportsCredit,
      clearStatementDay: !account.type.supportsCredit,
      clearDueDay: !account.type.supportsCredit,
      clearCreditAccountId: !account.type.supportsCredit,
    );
    if (!await controller.saveAccountDraft(normalized)) {
      return false;
    }
    if (_initialDefault != _draftDefault &&
        !await controller.saveDefaultAccountDraft(
          _draftDefault ? _draftAccount.id : null,
        )) {
      return false;
    }
    return true;
  }
}

class _MiniSegmentedToggle extends StatelessWidget {
  const _MiniSegmentedToggle({
    required this.value,
    required this.leftLabel,
    required this.rightLabel,
    required this.onChanged,
  });

  final bool value;
  final String leftLabel;
  final String rightLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // 卡片标题行内的小切换：走统一分段控件的紧凑档（false=左项，true=右项）。
    return VeriSegmentedControl<bool>(
      values: const <bool>[false, true],
      selected: value,
      compact: true,
      labelOf: (selected) => selected ? rightLabel : leftLabel,
      onChanged: onChanged,
    );
  }
}

class AccountReportPage extends StatelessWidget {
  const AccountReportPage({super.key, required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final currentAccount = controller.accounts.firstWhere(
      (item) => item.id == account.id,
      orElse: () => account,
    );
    final entries = controller.entries
        .where((entry) => entryTouchesAccount(entry, currentAccount.id))
        .toList();
    final timelineEntries = accountTimelineEntries(
      controller.entries,
      currentAccount.id,
    );
    final expense = sumByType(entries, EntryType.expense);
    final income = sumByType(entries, EntryType.income);
    final balance = controller.accountBalance(currentAccount);
    final reportBalanceValues = accountBalanceSeries(currentAccount, entries);

    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: <Widget>[
              VeriHeader(
                title: AppLocalizations.of(context).accountReportTitle,
                subtitle: currencyUnitSubtitle(
                  AppLocalizations.of(context),
                  currentAccount.name,
                  controller.activeBook.baseCurrencyCode,
                ),
                showBack: true,
              ),
              const SizedBox(height: 10),
              VeriCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 16,
                ),
                child: Row(
                  children: <Widget>[
                    SummaryMetric(
                      label: AppLocalizations.of(context).currentBalance,
                      value: formatUserMoney(
                        balance,
                        currentAccount.currencyCode,
                      ),
                      color: balance < 0
                          ? veriSemantic(context, veriExpense)
                          : veriRoyal,
                    ),
                    SummaryMetric(
                      label: AppLocalizations.of(context).entryTypeIncome,
                      value: formatUserMoney(
                        income,
                        controller.activeBook.baseCurrencyCode,
                      ),
                      color: veriSemantic(context, veriIncome),
                    ),
                    SummaryMetric(
                      label: AppLocalizations.of(context).entryTypeExpense,
                      value: formatSignedUserMoney(
                        -expense,
                        controller.activeBook.baseCurrencyCode,
                      ),
                      color: isZeroAmount(expense)
                          ? Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.48)
                          : veriSemantic(context, veriExpense),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SectionTitle(
                      title: AppLocalizations.of(context).balanceTrend,
                      trailing: AppLocalizations.of(context).thisMonth,
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 156,
                      child: InteractiveTrendChart(
                        color: veriRoyal,
                        values: reportBalanceValues,
                        xLabels: monthAxisLabels(DateTime.now()),
                        yLabels: balanceAxisLabels(
                          reportBalanceValues,
                          currentAccount.currencyCode,
                        ),
                        labelColor: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.50),
                        tooltipOf: (index) => ChartTooltip(
                          title: AppLocalizations.of(context).dateMonthDay(
                            DateTime(
                              DateTime.now().year,
                              DateTime.now().month,
                              index + 1,
                            ),
                          ),
                          lines: <ChartTooltipLine>[
                            ChartTooltipLine(
                              text: AppLocalizations.of(context).balanceAmount(
                                formatUserMoney(
                                  reportBalanceValues[index],
                                  currentAccount.currencyCode,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              VeriCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SectionTitle(
                      title: AppLocalizations.of(context).panelRecentLabel,
                      trailing: null,
                    ),
                    const SizedBox(height: 6),
                    if (timelineEntries.isEmpty)
                      EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: AppLocalizations.of(context).noEntriesTitle,
                        description: AppLocalizations.of(
                          context,
                        ).accountNoEntriesDesc,
                      )
                    else
                      ...timelineEntries
                          .take(6)
                          .map(
                            (entry) => TransactionTile(
                              entry,
                              accounts: controller.accounts,
                              categories: controller.categories,
                              tags: controller.tags,
                              showDate: true,
                              baseCurrencyCode:
                                  controller.activeBook.baseCurrencyCode,
                              onTap: () => openEntryDetail(context, entry),
                            ),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 信用卡还款提醒条：展示动态规则推导出的到期日与剩余日历天数。
class _CreditCardDueBanner extends StatelessWidget {
  const _CreditCardDueBanner({required this.dueDate});

  final DateTime dueDate;

  /// 到期日由信用主体或正式账单计算完成，本组件只负责日期与紧迫程度展示。
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final due = dateOnly(dueDate);
    final days = calendarDaysBetween(now, due).clamp(0, 1 << 30).toInt();
    final urgent = days <= 3;
    final color = urgent ? veriSemantic(context, veriExpense) : veriRoyal;
    final l10n = AppLocalizations.of(context);
    final daysText = days == 0 ? l10n.dueToday : l10n.dueInDays(days);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(veriRadiusMd),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.event_available_outlined, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${l10n.dueDay} ${l10n.dateMonthDay(due)} · $daysText',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 信用类账户（信用卡 / 信用账户）额度与本期账单卡片。
/// 设了额度展示已用 / 可用 + 使用进度条；设了账单日展示本期账单（当前账单周期净消费）。
class _CreditSummaryCard extends StatelessWidget {
  const _CreditSummaryCard({
    required this.account,
    required this.balance,
    required this.overview,
    required this.creditAccount,
    required this.creditCycleOverview,
  });

  final Account account;
  final double balance;
  final CreditStatementOverview overview;
  final CreditAccount? creditAccount;
  final CreditCycleOverview? creditCycleOverview;

  /// 共享额度和已用额度以父主体币种展示；正式账单仍属于当前币种子账户，继续使用
  /// 子账户币种。这样不会把 7 万人民币共享额度误显示成美元子账户的 7 万美元。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final limit = creditAccount?.creditLimit ?? account.creditLimit;
    final limitCurrency = creditAccount?.currencyCode ?? account.currencyCode;
    final statementDay = creditAccount?.statementDay ?? account.statementDay;
    final used = creditCycleOverview?.totalDebt ?? usedCredit(balance);
    final missingConversion = creditCycleOverview?.missingConversion ?? false;

    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (limit != null) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.creditLimitLabel,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  formatUserMoney(limit, limitCurrency),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(veriRadiusSm),
              child: LinearProgressIndicator(
                value: !missingConversion && limit > 0
                    ? (used / limit).clamp(0.0, 1.0).toDouble()
                    : 0.0,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: veriSemantic(context, veriBlue),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: _CreditStat(
                    label: l10n.creditUsedLabel,
                    value: missingConversion
                        ? l10n.notSet
                        : formatUserMoney(used, limitCurrency),
                  ),
                ),
                Expanded(
                  child: _CreditStat(
                    label: l10n.creditAvailableLabel,
                    value: missingConversion
                        ? l10n.notSet
                        : formatUserMoney(
                            (limit - used)
                                .clamp(0.0, double.infinity)
                                .toDouble(),
                            limitCurrency,
                          ),
                    highlight: true,
                  ),
                ),
              ],
            ),
            if (missingConversion) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                l10n.creditCycleMissingRate,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: veriSemantic(context, veriWarning),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
          if (limit != null && statementDay != null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),
          if (statementDay != null || overview.latestStatement != null)
            Row(
              children: <Widget>[
                Expanded(
                  child: _CreditStat(
                    // 保留「本期账单」这一既有页面文案，同时在下方明确
                    // 标注这是已经出账、尚未还清的金额，避免和未出账消费混淆。
                    label: l10n.currentBillLabel,
                    value: formatUserMoney(
                      overview.billedOutstanding,
                      account.currencyCode,
                    ),
                    hint: l10n.billedOutstandingLabel,
                  ),
                ),
                Expanded(
                  child: _CreditStat(
                    label: l10n.unbilledAmountLabel,
                    value: formatUserMoney(
                      overview.unbilledAmount,
                      account.currencyCode,
                    ),
                  ),
                ),
                Expanded(
                  child: _CreditStat(
                    label: l10n.latestStatementLabel,
                    value: overview.latestStatement == null
                        ? l10n.notSet
                        : _statementStatusLabel(
                            l10n,
                            overview.latestStatement!,
                          ),
                    hint: statementDay == null
                        ? null
                        : _billingHint(
                            l10n,
                            statementDay,
                            creditAccount,
                            account.dueDay,
                          ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _statementStatusLabel(
    AppLocalizations l10n,
    BillingStatement statement,
  ) => switch (statement.status) {
    BillingStatementStatus.paid => l10n.statementPaid,
    BillingStatementStatus.partiallyPaid => l10n.statementPartiallyPaid,
    BillingStatementStatus.overdue => l10n.statementOverdue,
    BillingStatementStatus.disputed => l10n.statementDisputed,
    BillingStatementStatus.open => l10n.statementOpen,
  };

  /// 账单提示按父主体规则展示；旧数据没有主体时回退子账户固定还款日。
  String _billingHint(
    AppLocalizations l10n,
    int statementDay,
    CreditAccount? creditAccount,
    int? legacyDueDay,
  ) {
    final parts = <String>[
      '${l10n.statementDay} ${l10n.monthlyDayLabel(statementDay)}',
      if (creditAccount?.dueRuleType == CreditDueRuleType.daysAfterStatement &&
          creditAccount?.daysAfterStatement != null)
        l10n.creditDaysAfterStatement(creditAccount!.daysAfterStatement!)
      else if ((creditAccount?.dueDay ?? legacyDueDay) != null)
        '${l10n.dueDay} ${l10n.monthlyDayLabel(creditAccount?.dueDay ?? legacyDueDay!)}',
    ];
    return parts.join(' · ');
  }
}

class _CreditStat extends StatelessWidget {
  const _CreditStat({
    required this.label,
    required this.value,
    this.hint,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String? hint;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: highlight ? veriSemantic(context, veriBlue) : null,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (hint != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            hint!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ],
    );
  }
}
