import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/entry_currency_draft.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'currency_rates_page.dart';
import 'sheets.dart';

/// 信用账户还款页：可选择扣款账户，也可只记录信用端实际到账的还款。
///
/// 默认金额取该币种子账户的已出账待还，不把未出账消费或历史总欠款带入。
/// 保存时原子记录转账与正式账单分配，跨币种保留两端实际金额。
class CreditRepaymentPage extends StatefulWidget {
  /// [account] 是接收还款的信用币种子账户，决定还款币种与账单归属。
  const CreditRepaymentPage({super.key, required this.account});

  final Account account;

  /// 创建页面草稿状态；打开页面本身不会新增还款记录。
  @override
  State<CreditRepaymentPage> createState() => _CreditRepaymentPageState();
}

class _CreditRepaymentPageState extends State<CreditRepaymentPage> {
  double _amount = 0;
  // 空 id 沿用模型的“无账户”语义，不创建虚拟账户。
  String _fromAccountId = '';
  double? _fromAmount;
  bool _fromAmountTouched = false;
  DateTime _occurredAt = DateTime.now();
  final TextEditingController _noteController = TextEditingController();
  bool _saving = false;
  bool _saved = false;
  // 同一份草稿重试时沿用 id，配合 Controller 的重复校验防止重复记账。
  late final String _entryId = DateTime.now().microsecondsSinceEpoch.toString();
  final EditorExitController _exitController = EditorExitController();
  bool _initialized = false;
  String? _initialSignature;

  /// 首次取得 Controller 时预填待还与默认备注；后续重建保留用户正在编辑的金额。
  /// 没有已出账待还时保持 0，提前还款由用户主动输入，不回退到总欠款。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final controller = VeriFinScope.of(context);
    _amount = controller.creditOverview(widget.account).billedOutstanding;
    final payable = _payableAccounts(controller);
    _fromAccountId =
        payable
            .where((account) => account.id == controller.defaultAccountId)
            .firstOrNull
            ?.id ??
        payable.firstOrNull?.id ??
        '';
    _resolveFromAmount(controller);
    _noteController.text = AppLocalizations.of(context).creditRepayDefaultNote;
  }

  /// 排除隐藏账户和同一信用主体内的币种调拨，避免将内部换汇当作真实还款。
  List<Account> _payableAccounts(VeriFinController controller) {
    final creditId = controller.creditAccountForAccount(widget.account)?.id;
    return controller.accounts
        .where(
          (account) =>
              !account.hidden &&
              account.id != widget.account.id &&
              (creditId == null ||
                  controller.creditAccountForAccount(account)?.id != creditId),
        )
        .toList();
  }

  /// 只按真实 id 查找当前可用扣款账户，无账户和失效选择不回退到首账户。
  Account? _fromAccount(VeriFinController controller) => _payableAccounts(
    controller,
  ).where((account) => account.id == _fromAccountId).firstOrNull;

  /// 同币种两端金额一致；跨币种优先保留手填额，否则按到账日期的汇率预填。
  void _resolveFromAmount(VeriFinController controller) {
    final source = _fromAccount(controller);
    if (source == null) {
      _fromAmount = null;
      return;
    }
    if (source.currencyCode == widget.account.currencyCode) {
      _fromAmount = normalizeCurrencyAmount(_amount, source.currencyCode);
      _fromAmountTouched = false;
      return;
    }
    if (_fromAmountTouched) return;
    final result = controller.convertAmount(
      amount: _amount,
      sourceCurrencyCode: widget.account.currencyCode,
      targetCurrencyCode: source.currencyCode,
      date: _occurredAt,
    );
    _fromAmount = result is ConvertedCurrencyAmount ? result.amount : null;
  }

  /// 页面销毁时释放备注输入控制器，避免继续持有输入监听。
  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  /// 汇总可编辑字段作为草稿指纹，用来判断离开时是否需要提示保存。
  /// 金额定点化、日期比较到分钟，避免浮点尾差或重选同一天产生虚假改动。
  String _draftSignature() {
    final date = _occurredAt;
    return <String>[
      _amount.toStringAsFixed(6),
      _fromAccountId,
      _fromAmountTouched ? (_fromAmount?.toStringAsFixed(6) ?? '') : '',
      '${date.year}-${date.month}-${date.day} ${date.hour}:${date.minute}',
      _noteController.text.trim(),
    ].join('|');
  }

  /// 构建还款、扣款账户、跨币种转出额、日期与备注表单，保存期间禁用编辑。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    _resolveFromAmount(controller);
    final source = _fromAccount(controller);
    _initialSignature ??= _draftSignature();
    final canConfirm =
        _amount > 0 &&
        !_saving &&
        !_saved &&
        (_fromAccountId.isEmpty || source != null && (_fromAmount ?? 0) > 0);

    return UnsavedChangesGuard(
      isDirty: !_saved && _draftSignature() != _initialSignature,
      onSave: _save,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
              children: <Widget>[
                VeriHeader(
                  title: l10n.creditRepayTitle,
                  subtitle: widget.account.name,
                  showBack: true,
                  actions: <Widget>[
                    SaveHeaderAction(
                      onPressed: canConfirm ? _saveAndExit : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SelectField(
                  label: l10n.creditRepayAmountLabel,
                  value: formatUserMoney(_amount, widget.account.currencyCode),
                  icon: Icons.payments_outlined,
                  onTap: _saving ? null : _pickAmount,
                ),
                const SizedBox(height: 10),
                SelectField(
                  key: const Key('repay_from_account'),
                  label: l10n.creditRepayFromAccount,
                  value: _fromAccountId.isEmpty
                      ? l10n.creditRepayNoAccountLabel
                      : source == null
                      ? l10n.pleaseSelect
                      : '${source.name} (${formatUserMoney(controller.accountBalance(source), source.currencyCode)})',
                  icon: source == null
                      ? Icons.account_balance_wallet_outlined
                      : null,
                  leading: source == null
                      ? null
                      : AccountIconBox(iconCode: source.iconCode, size: 26),
                  onTap: _saving ? null : () => _pickFromAccount(controller),
                ),
                if (source != null &&
                    source.currencyCode !=
                        widget.account.currencyCode) ...<Widget>[
                  const SizedBox(height: 10),
                  SelectField(
                    key: const Key('repay_from_amount'),
                    label: l10n.entryTransferOutAmount,
                    value: _fromAmount == null
                        ? l10n.exchangeRateNotSet
                        : formatUserMoney(_fromAmount!, source.currencyCode),
                    icon: Icons.currency_exchange,
                    onTap: _saving
                        ? null
                        : () => _pickFromAmount(source.currencyCode),
                  ),
                  if (_fromAmount == null) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      l10n.creditRepayMissingRateHint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => const CurrencyRatesPage(),
                                ),
                              ),
                        child: Text(l10n.currencyRatesTitle),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 10),
                SelectField(
                  label: l10n.dateLabel,
                  value: l10n.dateMonthDay(_occurredAt),
                  icon: Icons.event_outlined,
                  onTap: _saving ? null : _pickDate,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _noteController,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {}),
                  maxLines: 1,
                  decoration: InputDecoration(labelText: l10n.commonNote),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 用统一数字键盘编辑实际到账金额，按信用子账户的币种小数位规范化。
  /// 取消输入保留原金额；异步返回后先确认页面仍然挂载。
  Future<void> _pickAmount() async {
    final amount = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).creditRepayAmountLabel,
      initialAmount: _amount,
      maxFractionDigits: CurrencyCatalog.require(
        widget.account.currencyCode,
      ).minorUnit,
    );
    if (amount == null || !mounted) return;
    setState(() {
      final previousAmount = _amount;
      _amount = normalizeCurrencyAmount(amount, widget.account.currencyCode);
      final controller = VeriFinScope.of(context);
      final source = _fromAccount(controller);
      if (_fromAmountTouched && source != null) {
        _fromAmount = scaleDependentCurrencyAmount(
          dependentAmount: _fromAmount,
          previousOriginalAmount: previousAmount,
          nextOriginalAmount: _amount,
          targetCurrencyCode: source.currencyCode,
        );
      } else {
        _resolveFromAmount(controller);
      }
    });
  }

  /// 选择实际扣款账户或无账户；取消及重选当前项时完整保留跨币种草稿。
  Future<void> _pickFromAccount(VeriFinController controller) async {
    final l10n = AppLocalizations.of(context);
    final selected = await showAccountPickerSheet(
      context: context,
      title: l10n.creditRepayFromAccount,
      accounts: _payableAccounts(controller),
      selectedId: _fromAccountId,
      balanceOf: controller.accountBalance,
      noneLabel: l10n.creditRepayNoAccountLabel,
      noneHint: l10n.creditRepayNoAccountHint,
    );
    if (!mounted || selected == null || selected.id == _fromAccountId) return;
    setState(() {
      _fromAccountId = selected.id;
      _fromAmountTouched = false;
      _resolveFromAmount(controller);
    });
  }

  /// 填写银行实际扣款额；缺汇率时也可直接录入两端金额。
  Future<void> _pickFromAmount(String currencyCode) async {
    final l10n = AppLocalizations.of(context);
    final value = await showNumberPadSheet(
      context,
      title: l10n.entryAmountInputTitle(
        l10n.entryTransferOutAmount,
        currencyCode,
      ),
      initialAmount: _fromAmount,
      maxFractionDigits: CurrencyCatalog.require(currencyCode).minorUnit,
    );
    if (!mounted || value == null) return;
    setState(() {
      _fromAmount = normalizeCurrencyAmount(value, currencyCode);
      _fromAmountTouched = true;
    });
  }

  /// 编辑实际到账的日历日期，保留草稿时分；选同一天不会触发未保存提示。
  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _occurredAt = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _occurredAt.hour,
        _occurredAt.minute,
      );
      _resolveFromAmount(VeriFinScope.of(context));
    });
  }

  /// 顶部保存入口：只有交易与账单分配全部保存成功后才退出页面。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      _exitController.exit();
    }
  }

  /// 提交当前还款草稿，返回是否成功，供顶部保存与离开保护共同调用。
  /// Controller 负责原子落库；失败保留草稿，重试不会产生半笔还款。
  Future<bool> _save() async {
    if (_saved) return true;
    if (_amount <= 0 || _saving) return false;
    final controller = VeriFinScope.of(context);
    _resolveFromAmount(controller);
    if (_fromAccountId.isNotEmpty &&
        (_fromAccount(controller) == null || (_fromAmount ?? 0) <= 0)) {
      return false;
    }
    setState(() => _saving = true);
    final result = await controller.recordCreditRepayment(
      repaymentEntryId: _entryId,
      accountId: widget.account.id,
      amount: _amount,
      occurredAt: _occurredAt,
      note: _noteController.text,
      fromAccountId: _fromAccountId,
      fromAmount: _fromAccountId.isEmpty ? null : _fromAmount,
      conversionSource: _fromAmountTouched
          ? ConversionSource.manual
          : ConversionSource.rateTable,
    );
    if (!mounted) return result.isSuccess;
    setState(() {
      _saving = false;
      _saved = result.isSuccess;
    });
    if (!result.isSuccess) {
      // 持久化错误由 Controller 的统一入口记录并反馈；字段或失效草稿单独提示。
      if (result is EntrySaveValidationFailure) {
        unawaited(
          VeriFeedbackHost.of(context).showMessage(
            message: AppLocalizations.of(context).entrySaveValidationFailed,
            tone: VeriFeedbackTone.warning,
            duration: VeriFeedbackDuration.long,
          ),
        );
      }
      return false;
    }
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: AppLocalizations.of(context).creditRepaySuccess,
        tone: VeriFeedbackTone.success,
      ),
    );
    return true;
  }
}
