/// 账户期初设置与多证券草稿列表；只有最终保存才原子启用证券账务。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_opening_draft.dart';
import '../app/investments/investment_widgets.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'entry_editor_session.dart';
import 'investment_page.dart';
import 'option_editor_page.dart';
import 'sheets.dart';

/// 同一真实币种账户的期初现金、股票、基金和期权，取消不会创建部分组合。
class InvestmentSetupPage extends StatefulWidget {
  const InvestmentSetupPage({super.key, required this.accountId});
  final String accountId;

  @override
  State<InvestmentSetupPage> createState() => _InvestmentSetupPageState();
}

class _InvestmentSetupPageState extends State<InvestmentSetupPage> {
  final _cash = TextEditingController(text: '0');
  final _exitController = EditorExitController();
  final _holdings = <InvestmentOpeningHolding>[];
  late String _bookId, _initialSnapshot;
  String? _currencyCode;
  DateTime _date = DateTime.now();
  bool _initialized = false,
      _financing = false,
      _saving = false,
      _saved = false;
  String? _error;

  String get _snapshot => jsonEncode({
    'cash': _cash.text,
    'date': _date.toIso8601String(),
    'financing': _financing,
    'holdings': _holdings.map((h) => h.toJson()).toList(),
  });

  bool get _dirty => !_saved && _initialized && _snapshot != _initialSnapshot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final c = VeriFinScope.of(context);
    _bookId = c.activeBook.id;
    _currencyCode = c.accounts
        .where((a) => a.id == widget.accountId && a.bookId == _bookId)
        .firstOrNull
        ?.currencyCode;
    _initialSnapshot = _snapshot;
  }

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  /// 不从旧总资产猜现金；明确输入的现金与期初时刻只在账户层维护。
  InvestmentPortfolio _base(Account account) => InvestmentPortfolio(
    accountId: account.id,
    bookId: account.bookId,
    currencyCode: account.currencyCode,
    openedAt: _date,
    openingCash: _cash.text.trim(),
    allowFinancing: _financing,
  );

  Account? _account() {
    final c = VeriFinScope.of(context);
    if (c.activeBook.id != _bookId ||
        c.investmentFor(widget.accountId) != null) {
      return null;
    }
    return c.accounts
        .where(
          (a) =>
              a.id == widget.accountId &&
              a.bookId == _bookId &&
              a.currencyCode == _currencyCode &&
              a.type.supportsSecurities,
        )
        .firstOrNull;
  }

  String _conflictMessage(InvestmentOpeningIssue issue) {
    final l = AppLocalizations.of(context);
    return switch (issue) {
      InvestmentOpeningIssue.duplicateHolding => l.investOpeningDuplicate,
      InvestmentOpeningIssue.conflictingSecurity =>
        l.investOpeningContractConflict,
      InvestmentOpeningIssue.conflictingReference =>
        l.investOpeningPriceConflict,
      InvestmentOpeningIssue.conflictingMargin => l.investOpeningMarginConflict,
    };
  }

  /// 编辑上下文去重但不提交；冲突草稿仍须能打开修正，最终保存才严格验证全列表。
  InvestmentPortfolio _editorPortfolio(
    InvestmentPortfolio base,
    InvestmentOpeningHolding? current,
  ) {
    final securities = <String, StockSecurity>{};
    final positions = <String, StockHolding>{};
    final prices = <String, String>{};
    final margins = <String, String>{};
    for (final item in [..._holdings, ?current]) {
      final underlying = item.underlying;
      if (underlying != null) {
        securities.putIfAbsent(underlying.id, () => underlying);
        if (item.underlyingPrice != null) {
          prices.putIfAbsent(underlying.id, () => item.underlyingPrice!);
        }
      }
      securities[item.security.id] = item.security;
      positions['${item.security.id}:${item.holding.short}'] = item.holding;
      prices[item.security.id] = item.referencePrice;
      if (item.frozenMargin != null) {
        margins[item.security.id] = item.frozenMargin!;
      }
    }
    return base.copyWith(
      securities: securities.values.toList(),
      openingHoldings: positions.values.toList(),
      manualPrices: prices,
      events: investmentOpeningMarginEvents(
        openedAt: base.openedAt,
        securities: securities.values.toList(),
        holdings: positions.values.toList(),
        margins: margins,
      ),
    );
  }

  /// 子表单只返回一行；冲突条目保留在草稿供更正，取消保留之前的每一项。
  Future<void> _editHolding({
    int? index,
    bool option = false,
    bool fund = false,
  }) async {
    final account = _account();
    if (account == null || _saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final current = index == null ? null : _holdings[index];
    // 添加证券不依赖尚未填完的现金文本，最终保存再校验账户现金。
    final base = InvestmentPortfolio(
      accountId: account.id,
      bookId: account.bookId,
      currencyCode: account.currencyCode,
      openedAt: _date,
      openingCash: '0',
      allowFinancing: _financing,
    );
    final portfolio = _editorPortfolio(base, current);
    final useOption = current?.security.option != null || option;
    final result = await Navigator.of(context).push<InvestmentOpeningHolding>(
      MaterialPageRoute(
        builder: (_) => useOption
            ? OptionEditorPage(
                accountId: account.id,
                openingPortfolio: portfolio,
                openingHolding: current,
              )
            : StockEditorPage(
                accountId: account.id,
                openingPortfolio: portfolio,
                openingHolding: current,
                openingSecurityType: fund
                    ? InvestmentSecurityType.fund
                    : InvestmentSecurityType.stock,
              ),
      ),
    );
    if (!mounted || result == null || _account() == null) return;
    final next = [..._holdings];
    if (index == null) {
      next.add(result);
    } else {
      next[index] = result;
    }
    setState(() {
      _holdings
        ..clear()
        ..addAll(next);
      _error = null;
    });
    try {
      composeInvestmentOpening(base: base, holdings: next);
    } on InvestmentOpeningConflict catch (error) {
      setState(() => _error = _conflictMessage(error.issue));
    } on FormatException {
      // 可预期的草稿校验失败，只显示本地化错误，不写入任何账目。
      setState(() => _error = AppLocalizations.of(context).investSaveError);
    }
  }

  /// 现金、所有持仓、合约与保证金共享一次持久化事务，失败不留下半套期初。
  Future<bool> _save() async {
    final account = _account();
    if (account == null || _saving || _saved) return false;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final p = composeInvestmentOpening(
        base: _base(account),
        holdings: _holdings,
      );
      final ok = await VeriFinScope.of(context).enableInvestment(
        accountId: account.id,
        openingCash: p.openingCash,
        openedAt: p.openedAt,
        securities: p.securities,
        openingHoldings: p.openingHoldings,
        manualPrices: p.manualPrices,
        allowFinancing: p.allowFinancing,
        openingOptionMargins: {
          for (final event in p.events) event.securityId: event.marginAfter!,
        },
      );
      if (!mounted) return ok;
      setState(() {
        _saved = ok;
        if (!ok) _error = AppLocalizations.of(context).investSaveError;
      });
      return ok;
    } on InvestmentOpeningConflict catch (error) {
      if (mounted) setState(() => _error = _conflictMessage(error.issue));
      return false;
    } on FormatException {
      // 用户输入尚未完成或超出支持精度，保留全部草稿以便更正。
      if (mounted) {
        setState(() => _error = AppLocalizations.of(context).investSaveError);
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAndClose() async {
    if (await _save() && mounted) _exitController.exit();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), account = _account();
    return EntryEditorSurface(
      isDirty: _dirty,
      canSave: account != null && !_saving && !_saved,
      isSaving: _saving,
      onSave: _save,
      exitController: _exitController,
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            key: const ValueKey('opening-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(
                title: l.investEnable,
                subtitle: account == null
                    ? null
                    : currencyUnitSubtitle(
                        l,
                        account.name,
                        account.currencyCode,
                      ),
                showBack: true,
              ),
              const SizedBox(height: 12),
              if (account == null)
                InvestmentHint(l.investSaveError)
              else ...[
                InvestmentSection(
                  title: l.investEnableOpening,
                  children: [
                    InvestmentHint(l.investOpeningPortfolioHint),
                    InvestmentInputField(
                      label: l.investOpeningCash,
                      child: TextField(
                        key: const ValueKey('opening-cash'),
                        controller: _cash,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: investmentInputDecoration(context),
                        onChanged: (_) => setState(() => _error = null),
                      ),
                    ),
                    ListTile(
                      key: const ValueKey('opening-date'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.investOpeningDate),
                      subtitle: Text(
                        '${MaterialLocalizations.of(context).formatFullDate(_date)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_date))}',
                      ),
                      onTap: () async {
                        final day = await showEntryDatePicker(
                          context: context,
                          initialDateTime: _date,
                        );
                        if (!context.mounted || day == null) return;
                        final time = await showEntryTimePicker(
                          context: context,
                          initialDateTime: day,
                        );
                        if (!mounted || time == null) return;
                        setState(() => _date = time);
                      },
                    ),
                    SwitchListTile(
                      key: const ValueKey('opening-financing'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.investFinance),
                      value: _financing,
                      onChanged: (value) => setState(() => _financing = value),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                InvestmentSection(
                  title: l.investOpeningHoldingTitle,
                  children: [
                    if (_holdings.isEmpty) InvestmentHint(l.investOpeningEmpty),
                    for (var index = 0; index < _holdings.length; index++)
                      _holdingCard(
                        _holdings[index],
                        index,
                        account.currencyCode,
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('opening-add-stock'),
                          onPressed: () => _editHolding(),
                          icon: const Icon(Icons.add),
                          label: Text(l.investOpeningAddStock),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('opening-add-option'),
                          onPressed: () => _editHolding(option: true),
                          icon: const Icon(Icons.add),
                          label: Text(l.investOpeningAddOption),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('opening-add-fund'),
                          onPressed: () => _editHolding(fund: true),
                          icon: const Icon(Icons.add),
                          label: Text(l.investOpeningAddFund),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('opening-save'),
                  onPressed: _saving || _saved ? null : _saveAndClose,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l.investSave),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _holdingCard(
    InvestmentOpeningHolding item,
    int index,
    String currency,
  ) {
    final l = AppLocalizations.of(context), holding = item.holding;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${item.security.name} · ${item.security.symbol}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(holding.short ? l.investShortPosition : l.investLong),
          DetailInfoRow(
            inline: true,
            label: item.security.option == null
                ? l.investOpeningHoldingQuantity
                : l.optionContracts,
            value: holding.quantity,
          ),
          DetailInfoRow(
            inline: true,
            label: l.investOpeningTotalCost,
            value: holding.cost == null
                ? l.investUnknown
                : formatUserMoney(
                    InvestmentDecimal.parse(holding.cost!).toDouble(),
                    currency,
                  ),
          ),
          if (item.frozenMargin != null)
            DetailInfoRow(
              inline: true,
              label: l.optionMargin,
              value: formatUserMoney(
                InvestmentDecimal.parse(item.frozenMargin!).toDouble(),
                currency,
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                key: ValueKey('opening-edit-$index'),
                onPressed: () => _editHolding(index: index),
                icon: const Icon(Icons.edit_outlined),
                label: Text(l.commonEdit),
              ),
              TextButton.icon(
                key: ValueKey('opening-remove-$index'),
                onPressed: () => setState(() {
                  _holdings.removeAt(index);
                  _error = null;
                }),
                icon: const Icon(Icons.remove_circle_outline),
                label: Text(l.investOpeningRemove),
              ),
            ],
          ),
          const Divider(),
        ],
      ),
    );
  }
}
