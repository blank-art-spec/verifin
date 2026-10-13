import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 信用账户还款页：只记录实际到账的还款，不要求选择扣款账户。
///
/// 默认金额取该币种子账户的已出账待还，不把未出账消费或历史总欠款带入。
/// 保存时以无转出账户的转账抵扣信用余额，并同步关联未结清的正式账单。
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
    _noteController.text = AppLocalizations.of(context).creditRepayDefaultNote;
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
      '${date.year}-${date.month}-${date.day} ${date.hour}:${date.minute}',
      _noteController.text.trim(),
    ].join('|');
  }

  /// 构建金额、到账日期和备注表单；[context] 提供本地化文案与根级轻提示。
  /// 保存期间禁用保存按钮，页面不再解析或展示默认扣款账户及转出金额。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    _initialSignature ??= _draftSignature();
    final canConfirm = _amount > 0 && !_saving && !_saved;

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
      _amount = normalizeCurrencyAmount(amount, widget.account.currencyCode);
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
    setState(() => _saving = true);
    final result = await controller.recordCreditRepayment(
      repaymentEntryId: _entryId,
      accountId: widget.account.id,
      amount: _amount,
      occurredAt: _occurredAt,
      note: _noteController.text,
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
