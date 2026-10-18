import 'dart:async';
import 'package:flutter/material.dart';
import '../app/common_widgets.dart';
import '../app/credit_hierarchy.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/ledger_math.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';
import 'transaction_detail_page.dart';

/// 父账户统一还款，各币种到账与扣款分摊一次原子保存。
class CreditRepaymentPage extends StatefulWidget {
  const CreditRepaymentPage({super.key, required this.account, this.batchId});
  final Account account;
  final String? batchId;
  @override
  State<CreditRepaymentPage> createState() => _CreditRepaymentPageState();
}

class _CreditRepaymentPageState extends State<CreditRepaymentPage> {
  CreditRepaymentScope _scope = CreditRepaymentScope.current;
  final _amounts = <String, double>{};
  final _debits = <String, double?>{};
  final _touched = <String>{};
  String _fromId = '';
  DateTime _date = DateTime.now();
  OccurredAtPrecision _timePrecision = OccurredAtPrecision.minute;
  final _note = TextEditingController();
  final _exit = EditorExitController();
  late final _batchId =
      widget.batchId ?? 'repayment-${DateTime.now().microsecondsSinceEpoch}';
  bool _initialized = false, _saving = false, _saved = false;
  String? _initial;
  String get _parentId =>
      VeriFinScope.of(context).creditAccountForAccount(widget.account)?.id ??
      '';
  List<Account> _children(VeriFinController c) =>
      c.accountsForCreditAccount(_parentId);
  List<Account> _sources(VeriFinController c) => c.accounts
      .where((a) => !a.hidden && a.creditAccountId != _parentId)
      .toList();
  Account? _source(VeriFinController c) =>
      _sources(c).where((a) => a.id == _fromId).firstOrNull;
  List<CreditRepaymentLine> get _lines => [
    for (final e in _amounts.entries)
      CreditRepaymentLine(
        accountId: e.key,
        amount: e.value,
        sourceAmount: _debits[e.key],
        conversionSource: _touched.contains(e.key)
            ? ConversionSource.manual
            : ConversionSource.rateTable,
      ),
  ];
  String get _signature =>
      '$_scope|$_fromId|${_date.toIso8601String()}|$_timePrecision|${_note.text}|$_amounts|$_debits';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final c = VeriFinScope.of(context);
    _note.text = AppLocalizations.of(context).creditRepayDefaultNote;
    final old = c.entries
        .where(
          (e) => e.repaymentBatchId == widget.batchId && widget.batchId != null,
        )
        .toList();
    if (old.isNotEmpty) {
      _fromId = old.first.accountId;
      _date = old.first.occurredAt;
      _timePrecision = old.first.occurredAtPrecision;
      _note.text = old.first.note;
      for (final a in _children(c)) {
        _amounts[a.id] = 0;
      }
      for (final e in old) {
        _amounts[e.toAccountId!] = e.toAccountAmount ?? e.amount;
        _debits[e.toAccountId!] = e.accountAmount ?? e.amount;
        _touched.add(e.toAccountId!);
      }
    } else {
      _date = DateTime(
        _date.year,
        _date.month,
        _date.day,
        _date.hour,
        _date.minute,
      );
      _fromId =
          _sources(
            c,
          ).where((a) => a.id == c.defaultAccountId).firstOrNull?.id ??
          _sources(c).firstOrNull?.id ??
          '';
      _prefill(c);
    }
    _resolve(c);
    _initial = _signature;
  }

  void _prefill(VeriFinController c) {
    _amounts.clear();
    _debits.clear();
    _touched.clear();
    for (final l in c.creditRepaymentDefaults(_parentId, _scope)) {
      _amounts[l.accountId] = l.amount;
    }
  }

  void _resolve(VeriFinController c) {
    final source = _source(c);
    for (final a in _children(c)) {
      final amount = _amounts[a.id] ?? 0;
      if (source == null) {
        _debits[a.id] = null;
        continue;
      }
      if (source.currencyCode == a.currencyCode) {
        _debits[a.id] = amount;
        continue;
      }
      if (_touched.contains(a.id)) continue;
      final converted = c.convertAmount(
        amount: amount,
        sourceCurrencyCode: a.currencyCode,
        targetCurrencyCode: source.currencyCode,
        date: _date,
      );
      _debits[a.id] = converted is ConvertedCurrencyAmount
          ? converted.amount
          : null;
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final source = _source(c);
    _resolve(c);
    final missing = c.repaymentDraftMissingReferences(
      _parentId,
      _lines,
      batchId: widget.batchId,
    );
    final canSave =
        !_saving &&
        !_saved &&
        _amounts.values.any((v) => v > 0) &&
        (_fromId.isEmpty ||
            source != null &&
                _amounts.entries
                    .where((v) => v.value > 0)
                    .every((v) => (_debits[v.key] ?? 0) > 0));
    return UnsavedChangesGuard(
      isDirty: !_saved && _signature != _initial,
      onSave: _save,
      exitController: _exit,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
              children: [
                VeriHeader(
                  title: l.creditRepayTitle,
                  subtitle:
                      c.creditAccountForAccount(widget.account)?.name ??
                      widget.account.name,
                  showBack: true,
                  actions: [
                    if (widget.batchId != null)
                      HeaderAction(
                        icon: Icons.delete_outline,
                        tooltip: l.commonDelete,
                        onPressed: _saving
                            ? null
                            : () async {
                                final confirmed = await showConfirmDialog(
                                  context,
                                  title: l.commonDelete,
                                  message: l.creditDeleteBatch,
                                  destructive: true,
                                );
                                if (!mounted || !confirmed) return;
                                final entry = c.entries
                                    .where(
                                      (e) =>
                                          e.repaymentBatchId == widget.batchId,
                                    )
                                    .firstOrNull;
                                if (entry == null) return;
                                final success = await c.deleteEntry(entry.id);
                                if (!mounted || !success) return;
                                setState(() => _saved = true);
                                _exit.exit();
                              },
                      ),
                    SaveHeaderAction(
                      onPressed: canSave
                          ? () async {
                              if (await _save() && mounted) _exit.exit();
                            }
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (widget.batchId != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(l.creditRepaymentEditBatch),
                  ),
                VeriAnchoredChoice<CreditRepaymentScope>(
                  values: CreditRepaymentScope.values,
                  selected: _scope,
                  idOf: (v) => v.name,
                  labelOf: (v) => v == CreditRepaymentScope.current
                      ? l.creditRepaymentCurrent
                      : l.creditRepaymentAll,
                  onSelected: (v) {
                    if (_saving) return;
                    setState(() {
                      _scope = v;
                      _prefill(c);
                      _resolve(c);
                    });
                  },
                  semanticLabel: l.creditRepaymentScope,
                  builder: (context, open, opened) => SelectField(
                    key: const Key('repay_scope'),
                    label: l.creditRepaymentScope,
                    value: _scope == CreditRepaymentScope.current
                        ? l.creditRepaymentCurrent
                        : l.creditRepaymentAll,
                    icon: Icons.receipt_long_outlined,
                    onTap: _saving ? null : open,
                  ),
                ),
                const SizedBox(height: 10),
                SelectField(
                  key: const Key('repay_from_account'),
                  label: l.creditRepayFromAccount,
                  value: source?.name ?? l.creditRepayNoAccountLabel,
                  icon: Icons.account_balance_wallet_outlined,
                  onTap: _saving
                      ? null
                      : () async {
                          final selected = await showAccountPickerSheet(
                            context: context,
                            title: l.creditRepayFromAccount,
                            accounts: _sources(c),
                            selectedId: _fromId,
                            balanceOf: c.accountBalance,
                            noneLabel: l.creditRepayNoAccountLabel,
                            noneHint: l.creditRepayNoAccountHint,
                          );
                          if (!mounted || selected == null) return;
                          setState(() {
                            _fromId = selected.id;
                            _touched.clear();
                            _resolve(c);
                          });
                        },
                ),
                for (final a in _children(c)) ...[
                  const SizedBox(height: 10),
                  SelectField(
                    key: Key('repay_amount_${a.currencyCode}'),
                    label: _children(c).length == 1
                        ? l.creditRepayAmountLabel
                        : l.creditChildAmount(a.currencyCode),
                    value: formatUserMoney(_amounts[a.id] ?? 0, a.currencyCode),
                    icon: Icons.payments_outlined,
                    onTap: _saving
                        ? null
                        : () async {
                            final value = await showNumberPadSheet(
                              context,
                              title: l.creditChildAmount(a.currencyCode),
                              initialAmount: _amounts[a.id],
                              currencyCode: a.currencyCode,
                              allowZero: true,
                            );
                            if (!mounted || value == null) return;
                            setState(() {
                              _amounts[a.id] = normalizeCurrencyAmount(
                                value,
                                a.currencyCode,
                              );
                              _touched.remove(a.id);
                              _resolve(c);
                            });
                          },
                  ),
                  if (source != null &&
                      source.currencyCode != a.currencyCode &&
                      (_amounts[a.id] ?? 0) > 0)
                    SelectField(
                      key: _children(c).length == 1
                          ? const Key('repay_from_amount')
                          : Key('repay_debit_${a.currencyCode}'),
                      label: '${l.entryTransferOutAmount} · ${a.currencyCode}',
                      value: _debits[a.id] == null
                          ? l.exchangeRateNotSet
                          : formatUserMoney(
                              _debits[a.id]!,
                              source.currencyCode,
                            ),
                      icon: Icons.currency_exchange,
                      onTap: _saving
                          ? null
                          : () async {
                              final value = await showNumberPadSheet(
                                context,
                                title: l.entryTransferOutAmount,
                                initialAmount: _debits[a.id],
                                currencyCode: source.currencyCode,
                              );
                              if (!mounted || value == null) return;
                              setState(() {
                                _debits[a.id] = normalizeCurrencyAmount(
                                  value,
                                  source.currencyCode,
                                );
                                _touched.add(a.id);
                              });
                            },
                    ),
                ],
                if (source != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      '${l.creditSourceTotal}：${_amounts.entries.where((e) => e.value > 0).any((e) => _debits[e.key] == null) ? l.exchangeRateNotSet : formatUserMoney(_amounts.entries.where((e) => e.value > 0).fold<double>(0, (s, e) => s + (_debits[e.key] ?? 0)), source.currencyCode)}',
                    ),
                  ),
                if (missing.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(l.creditRepaymentReferenceRequired),
                  for (final e in missing)
                    Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${formatUserMoney(e.amount, e.currencyCode)} · ${l.dateMonthDay(e.occurredAt)}',
                        ),
                        subtitle: Text(l.creditFillReference),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) =>
                                  TransactionDetailPage(entryId: e.id),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                ],
                const SizedBox(height: 10),
                SelectField(
                  key: const Key('repay_date'),
                  label: l.dateLabel,
                  value: l.dateMonthDay(_date),
                  icon: Icons.event_outlined,
                  onTap: _saving
                      ? null
                      : () async {
                          final date = await showEntryDatePicker(
                            context: context,
                            initialDateTime: _date,
                          );
                          if (!mounted || date == null) return;
                          setState(() {
                            _date = date;
                            _resolve(c);
                          });
                        },
                ),
                const SizedBox(height: 10),
                SelectField(
                  key: const Key('repay_time'),
                  label: l.timeLabel,
                  value: _timePrecision == OccurredAtPrecision.date
                      ? l.commonNoneShort
                      : formatTime(_date),
                  icon: Icons.schedule_outlined,
                  onTap: _saving
                      ? null
                      : () async {
                          final time = await showEntryTimePicker(
                            context: context,
                            initialDateTime: _date,
                          );
                          if (!mounted || time == null) return;
                          setState(() {
                            _date = time;
                            _timePrecision = OccurredAtPrecision.minute;
                            _resolve(c);
                          });
                        },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _note,
                  enabled: !_saving,
                  decoration: InputDecoration(labelText: l.commonNote),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _save() async {
    if (_saved) return true;
    if (_saving) return false;
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (c
        .repaymentDraftMissingReferences(
          _parentId,
          _lines,
          batchId: widget.batchId,
        )
        .isNotEmpty) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: l.creditRepaymentReferenceRequired,
          tone: VeriFeedbackTone.warning,
          duration: VeriFeedbackDuration.long,
        ),
      );
      return false;
    }
    setState(() => _saving = true);
    final result = await c.recordCreditRepaymentBatch(
      batchId: _batchId,
      parentId: _parentId,
      lines: _lines,
      occurredAt: _date,
      occurredAtPrecision: _timePrecision,
      fromAccountId: _fromId,
      note: _note.text,
      replace: widget.batchId != null,
    );
    if (!mounted) return result.isSuccess;
    setState(() {
      _saving = false;
      _saved = result.isSuccess;
    });
    if (result is EntrySaveValidationFailure) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: l.entrySaveValidationFailed,
          tone: VeriFeedbackTone.warning,
        ),
      );
    }
    if (result.isSuccess) {
      unawaited(
        VeriFeedbackHost.of(context).showMessage(
          message: l.creditRepaySuccess,
          tone: VeriFeedbackTone.success,
        ),
      );
    }
    return result.isSuccess;
  }
}
