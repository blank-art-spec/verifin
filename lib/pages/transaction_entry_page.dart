/// 投资账本的手动新增明细外壳，复用普通记账和三类投资表单。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/feedback.dart';
import '../app/investments/investment_widgets.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'entry_detail_page.dart';
import 'entry_editor_session.dart';
import 'fund_entry_page.dart';
import 'investment_page.dart';
import 'investment_setup_page.dart';
import 'option_editor_page.dart';
import 'securities_account_creation.dart';
import 'sheets.dart';

enum _EntryMode { general, investment }

enum _InvestmentActivity { stock, option, fundPurchase, fundHolding }

/// 新建记录专用页面；已有记录与外部复核草稿继续走其原来的专用编辑页。
class TransactionEntryPage extends StatefulWidget {
  /// [bookId] 固定本次新增的目标账本；[initialAccountId] 只接受该本证券币种账户。
  /// [onCreateSecuritiesAccount] 可注入现有新建流程，返回后重新读取合格账户。
  const TransactionEntryPage({
    super.key,
    required this.bookId,
    this.initialAccountId,
    this.onCreateSecuritiesAccount,
    this.clock,
  });

  final String bookId;
  final String? initialAccountId;
  final Future<void> Function(BuildContext context)? onCreateSecuritiesAccount;

  /// 普通草稿默认时间的可注入来源；不影响真实投资事件或开户时刻的业务计算。
  final DateTime Function()? clock;

  /// 每次新增创建独立页面会话；未提交草稿不进入全局或设备存储。
  @override
  State<TransactionEntryPage> createState() => _TransactionEntryPageState();
}

class _TransactionEntryPageState extends State<TransactionEntryPage> {
  final _exitController = EditorExitController();
  final _sessions = <String, EntryEditorSession>{};
  final _editors = <String, Widget>{};
  _EntryMode _mode = _EntryMode.investment;
  _InvestmentActivity _activity = _InvestmentActivity.stock;
  String? _accountId;
  bool _selectionInitialized = false;

  /// 只读取目标账本已初始化、未隐藏的真实证券币种账户，不返回父账户或无账户哨兵。
  List<Account> _eligibleAccounts(VeriFinController controller) => controller
      .accountsForBook(widget.bookId)
      .where(
        (account) =>
            !account.hidden &&
            account.type.supportsSecurities &&
            controller.investmentFor(account.id) != null,
      )
      .toList();

  /// 明确上下文优先，其次同账本有效默认账户；仅一个候选时才自动选择。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectionInitialized) return;
    _selectionInitialized = true;
    final controller = VeriFinScope.of(context);
    final accounts = _eligibleAccounts(controller);
    final preferred = widget.initialAccountId ?? controller.defaultAccountId;
    if (accounts.any((account) => account.id == preferred)) {
      _accountId = preferred;
    } else if (accounts.length == 1) {
      _accountId = accounts.single.id;
    }
  }

  /// 子表单把状态通知交给同一个外壳，隐藏草稿的修改也参与整体退出判断。
  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  /// 为每个“模式/账户/业务”建立稳定会话及 Widget；切页签不销毁其输入控制器。
  EntryEditorSession _sessionFor(String key) => _sessions.putIfAbsent(key, () {
    final session = EntryEditorSession();
    session.addListener(_onSessionChanged);
    return session;
  });

  /// 只保存当前已显示的表单。其他草稿未保存时反馈并留页，绝不连带提交。
  Future<bool> _saveCurrent() async {
    final controller = VeriFinScope.of(context);
    if (controller.activeBook.id != widget.bookId) return false;
    final session = _currentSession;
    if (session == null || !session.canSave) return false;
    final success = await session.save();
    if (!mounted) return success;
    if (success && _hasUnsavedDrafts) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: AppLocalizations.of(context).entrySavedCurrent,
          tone: VeriFeedbackTone.success,
        ),
      );
    }
    return success;
  }

  /// 显式保存与返回确认共用业务提交；仅在所有草稿处理完毕后退出。
  Future<void> _saveAndExit() async {
    if (await _saveCurrent() && mounted && !_hasUnsavedDrafts) {
      _exitController.exit();
    }
  }

  bool get _hasUnsavedDrafts =>
      _sessions.values.any((session) => session.isDirty);
  bool get _isSaving => _sessions.values.any((session) => session.isSaving);

  /// 普通模式固定一个槽位；投资槽位包含具体账户与业务，不在币种间共享数值。
  String? get _currentKey => _mode == _EntryMode.general
      ? 'general'
      : _accountId == null
      ? null
      : 'investment:$_accountId:${_activity.name}';

  EntryEditorSession? get _currentSession => _sessions[_currentKey];

  /// 当前账户展示主账户上下文及真实币种，以区分两个主账户中的同币种账户。
  String _accountLabel(VeriFinController controller, Account account) {
    final parent = controller.accountParents
        .where((parent) => parent.id == account.creditAccountId)
        .firstOrNull;
    return '${parent?.name ?? account.name} · ${account.currencyCode}';
  }

  /// 从筛选后的领域选择器选择真实账户；取消只返回，不初始化或写入任何账户。
  Future<void> _chooseAccount(List<Account> accounts) async {
    final controller = VeriFinScope.of(context);
    final selected = await showAccountPickerSheet(
      context: context,
      title: AppLocalizations.of(context).entrySelectInvestmentAccount,
      accounts: accounts,
      selectedId: _accountId,
      balanceOf: controller.accountBalance,
    );
    if (!mounted ||
        selected == null ||
        controller.activeBook.id != widget.bookId) {
      return;
    }
    setState(() => _accountId = selected.id);
  }

  /// 从现有正式新建流程返回后，只在出现一个候选时自动选择，不猜多个账户的归属。
  Future<void> _createAccount() async {
    final callback = widget.onCreateSecuritiesAccount;
    if (callback != null) {
      await callback(context);
    } else {
      await createSecuritiesAccount(context: context, bookId: widget.bookId);
    }
    if (!mounted) return;
    final controller = VeriFinScope.of(context);
    if (controller.activeBook.id != widget.bookId) return;
    final accounts = _eligibleAccounts(controller);
    if (accounts.length == 1) setState(() => _accountId = accounts.single.id);
  }

  /// 历史投资类账户只在用户明确选择后进入原期初核对表单，取消保持原账户不变。
  Future<void> _initializeExisting(List<Account> accounts) async {
    final controller = VeriFinScope.of(context);
    final selected = await showAccountPickerSheet(
      context: context,
      title: AppLocalizations.of(context).entryInitializeSecuritiesAccount,
      accounts: accounts,
      selectedId: null,
      balanceOf: controller.accountBalance,
    );
    if (!mounted ||
        selected == null ||
        controller.activeBook.id != widget.bookId) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => InvestmentSetupPage(accountId: selected.id),
      ),
    );
    if (!mounted) return;
    if (controller.activeBook.id == widget.bookId &&
        controller.investmentFor(selected.id) != null) {
      setState(() => _accountId = selected.id);
    }
  }

  /// 各业务使用原表单及命令；这里只安排外壳，不重复量价、结算或收益计算。
  Widget _investmentEditor(String key, String accountId) {
    final session = _sessionFor(key);
    return switch (_activity) {
      _InvestmentActivity.stock => StockEditorPage(
        key: ValueKey(key),
        accountId: accountId,
        editorSession: session,
      ),
      _InvestmentActivity.option => OptionEditorPage(
        key: ValueKey(key),
        accountId: accountId,
        editorSession: session,
      ),
      _InvestmentActivity.fundPurchase => FundEntryPage(
        key: ValueKey(key),
        accountId: accountId,
        mode: FundEntryMode.purchase,
        editorSession: session,
      ),
      _InvestmentActivity.fundHolding => FundEntryPage(
        key: ValueKey(key),
        accountId: accountId,
        mode: FundEntryMode.holdingBaseline,
        editorSession: session,
      ),
    };
  }

  /// 品种名称使用既有文案；两个基金入口继续明确区分申购和已有份额基准。
  String _activityLabel(_InvestmentActivity activity, AppLocalizations l) =>
      switch (activity) {
        _InvestmentActivity.stock => l.investNewTrade,
        _InvestmentActivity.option => l.optionTitle,
        _InvestmentActivity.fundPurchase => l.fundBuyByAmount,
        _InvestmentActivity.fundHolding => l.fundRecordHolding,
      };

  /// 释放所有会话通知；真实输入控制器由各领域表单自己的 dispose 释放。
  @override
  void dispose() {
    for (final session in _sessions.values) {
      session.removeListener(_onSessionChanged);
      session.dispose();
    }
    super.dispose();
  }

  /// 单个 Scaffold 承载固定标题、两种模式和保存区；领域表单只占据中间可滚动区域。
  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l = AppLocalizations.of(context);
    final book = controller.ledgerBooks
        .where((book) => book.id == widget.bookId)
        .firstOrNull;
    final isCurrentBook =
        book != null && controller.activeBook.id == widget.bookId;
    final accounts = _eligibleAccounts(controller);
    final selected = accounts
        .where((account) => account.id == _accountId)
        .firstOrNull;
    final setupAccounts = controller
        .accountsForBook(widget.bookId)
        .where(
          (account) =>
              !account.hidden &&
              account.type.supportsSecurities &&
              controller.investmentFor(account.id) == null,
        )
        .toList();
    _editors.putIfAbsent(
      'general',
      () => EntryDetailPage(
        key: const ValueKey('transaction-general-form'),
        initialAmount: 0,
        initialAccountId: controller.defaultAccountId,
        bookId: widget.bookId,
        clock: widget.clock,
        editorSession: _sessionFor('general'),
      ),
    );
    final key = _currentKey;
    if (_mode == _EntryMode.investment && selected != null && key != null) {
      _editors.putIfAbsent(key, () => _investmentEditor(key, selected.id));
    }
    final activeKey = _mode == _EntryMode.general || selected != null
        ? key
        : null;
    final activeIndex = activeKey == null
        ? -1
        : _editors.keys.toList().indexOf(activeKey);
    final session = activeKey == null ? null : _sessions[activeKey];
    final hasOtherDrafts = _sessions.entries.any(
      (entry) => entry.key != activeKey && entry.value.isDirty,
    );
    final empty = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        InvestmentHint(
          !isCurrentBook
              ? l.entryBookUnavailable
              : accounts.isEmpty
              ? l.entryNoSecuritiesAccount
              : l.entrySelectInvestmentAccount,
        ),
        if (isCurrentBook) ...[
          const SizedBox(height: 12),
          if (accounts.isNotEmpty)
            OutlinedButton(
              onPressed: () => _chooseAccount(accounts),
              child: Text(l.entrySelectInvestmentAccount),
            ),
          OutlinedButton(
            onPressed: _createAccount,
            child: Text(l.entryCreateSecuritiesAccount),
          ),
          if (setupAccounts.isNotEmpty)
            OutlinedButton(
              onPressed: () => _initializeExisting(setupAccounts),
              child: Text(l.entryInitializeSecuritiesAccount),
            ),
        ],
      ],
    );
    return UnsavedChangesGuard(
      isDirty: _hasUnsavedDrafts,
      isSaving: _isSaving,
      canSave: isCurrentBook && (session?.canSave ?? false),
      onSave: _saveCurrent,
      hasRemainingChanges: () => _hasUnsavedDrafts,
      message: hasOtherDrafts ? l.entryMultipleDraftsUnsaved : null,
      saveLabel: l.entrySaveCurrent,
      discardLabel: hasOtherDrafts ? l.entryDiscardAll : null,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: VeriHeader(
                    title: l.entryNewRecord,
                    subtitle: book?.name,
                    showBack: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: VeriSegmentedControl<_EntryMode>(
                    key: const Key('transaction-entry-mode'),
                    values: _EntryMode.values,
                    selected: _mode,
                    labelOf: (mode) => mode == _EntryMode.general
                        ? l.entryModeGeneral
                        : l.entryModeInvestment,
                    keyOf: (mode) => ValueKey('transaction-mode-${mode.name}'),
                    onChanged: _isSaving
                        ? null
                        : (mode) => setState(() => _mode = mode),
                  ),
                ),
                if (_mode == _EntryMode.investment && isCurrentBook)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: VeriCard(
                      child: Column(
                        children: [
                          SettingsRow(
                            key: const Key('transaction-investment-account'),
                            icon: Icons.account_balance_outlined,
                            title: l.entryInvestmentAccount,
                            trailing: selected == null
                                ? l.entrySelectInvestmentAccount
                                : _accountLabel(controller, selected),
                            trailingMaxLines: null,
                            onTap: _isSaving || accounts.isEmpty
                                ? null
                                : () => _chooseAccount(accounts),
                          ),
                          VeriAnchoredChoice<_InvestmentActivity>(
                            values: _InvestmentActivity.values,
                            selected: _activity,
                            idOf: (value) => value.name,
                            labelOf: (value) => _activityLabel(value, l),
                            semanticLabel: l.entryInvestmentInstrument,
                            onSelected: (value) {
                              if (!_isSaving) setState(() => _activity = value);
                            },
                            builder: (context, open, active) => SettingsRow(
                              key: const Key('transaction-investment-activity'),
                              icon: Icons.swap_horiz,
                              title: l.entryInvestmentInstrument,
                              trailing: _activityLabel(_activity, l),
                              trailingMaxLines: null,
                              onTap: _isSaving ? null : open,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!isCurrentBook)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: InvestmentHint(l.entryBookUnavailable),
                  ),
                if (session?.isSaved ?? false)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: InvestmentHint(l.entrySavedReadOnly),
                  ),
                Expanded(
                  child: IgnorePointer(
                    ignoring: _isSaving || !isCurrentBook,
                    child: IndexedStack(
                      index: activeIndex < 0 ? _editors.length : activeIndex,
                      children: [..._editors.values, empty],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const Key('transaction-save-current'),
                      onPressed: isCurrentBook && (session?.canSave ?? false)
                          ? _saveAndExit
                          : null,
                      child: Text(
                        _isSaving ? l.commonProcessing : l.entrySaveCurrent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
