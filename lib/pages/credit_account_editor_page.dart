// 信用主体编辑页：维护共享额度、动态账期规则和账期预算。
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 编辑一个信用主体，而不是某个具体币种子账户。
///
/// [creditAccount] 是进入页面时的持久化快照；保存时通过 Controller 原子更新主体和
/// 所有子账户的兼容镜像字段，避免人民币/美元子账户出现两套额度或账期规则。
class CreditAccountEditorPage extends StatefulWidget {
  const CreditAccountEditorPage({super.key, required this.creditAccount});

  final CreditAccount creditAccount;

  @override
  State<CreditAccountEditorPage> createState() =>
      _CreditAccountEditorPageState();
}

class _CreditAccountEditorPageState extends State<CreditAccountEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _exitController = EditorExitController();
  late final TextEditingController _nameController;
  late final TextEditingController _institutionController;
  late final TextEditingController _cardLast4Controller;
  late CreditAccount _draft;
  bool _saved = false;

  /// 从传入的持久化快照建立页面草稿；文本控制器只负责文本字段，金额和规则直接
  /// 保存在 [_draft]，这样取消离开不会触碰 Controller。
  @override
  void initState() {
    super.initState();
    _draft = widget.creditAccount;
    _nameController = TextEditingController(text: _draft.name)
      ..addListener(_handleTextChanged);
    _institutionController = TextEditingController(text: _draft.institution)
      ..addListener(_handleTextChanged);
    _cardLast4Controller = TextEditingController(text: _draft.cardLast4)
      ..addListener(_handleTextChanged);
  }

  /// 释放本页创建的输入控制器，避免路由反复进入后残留监听器。
  @override
  void dispose() {
    _nameController
      ..removeListener(_handleTextChanged)
      ..dispose();
    _institutionController
      ..removeListener(_handleTextChanged)
      ..dispose();
    _cardLast4Controller
      ..removeListener(_handleTextChanged)
      ..dispose();
    super.dispose();
  }

  /// 文本变化只刷新保存按钮和未保存离开保护；实际持久化统一由 [_save] 完成。
  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  /// 比较当前草稿与进入页面时的快照，决定是否启用保存与返回拦截。
  bool get _isDirty {
    if (_saved) return false;
    return _nameController.text.trim() != widget.creditAccount.name ||
        _institutionController.text.trim() !=
            widget.creditAccount.institution ||
        cardLast4Of(_cardLast4Controller.text) !=
            widget.creditAccount.cardLast4 ||
        _draft.creditLimit != widget.creditAccount.creditLimit ||
        _draft.statementDay != widget.creditAccount.statementDay ||
        _draft.dueRuleType != widget.creditAccount.dueRuleType ||
        _draft.dueDay != widget.creditAccount.dueDay ||
        _draft.daysAfterStatement != widget.creditAccount.daysAfterStatement ||
        _draft.cycleBudget != widget.creditAccount.cycleBudget;
  }

  /// 构建标准编辑页。规则选择使用锚点单选，金额/日期分别复用数字键盘与选项弹层。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final children = VeriFinScope.of(
      context,
    ).accountsForCreditAccount(_draft.id);
    final currency = CurrencyCatalog.require(_draft.currencyCode);
    return UnsavedChangesGuard(
      isDirty: _isDirty,
      onSave: _save,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                children: <Widget>[
                  VeriHeader(
                    title: l10n.creditAccountEditTitle,
                    subtitle: l10n.creditChildAccountsSummary(
                      children.length,
                      children.map((item) => item.currencyCode).join(' · '),
                    ),
                    showBack: true,
                    actions: <Widget>[
                      SaveHeaderAction(
                        onPressed: _isDirty ? _saveAndExit : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: l10n.creditAccountNameLabel,
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? l10n.accountNameRequired
                        : null,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _institutionController,
                    decoration: InputDecoration(
                      labelText: l10n.creditInstitutionLabel,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _cardLast4Controller,
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    decoration: InputDecoration(labelText: l10n.cardLast4Label),
                  ),
                  SelectField(
                    label: l10n.creditLimitLabel,
                    value: _draft.creditLimit == null
                        ? l10n.notSet
                        : formatUserMoney(
                            _draft.creditLimit!,
                            _draft.currencyCode,
                          ),
                    icon: Icons.speed_outlined,
                    onTap: () => _pickAmount(isBudget: false),
                  ),
                  const SizedBox(height: 10),
                  SelectField(
                    label: l10n.statementDay,
                    value: _draft.statementDay == null
                        ? l10n.notSet
                        : l10n.monthlyDayLabel(_draft.statementDay!),
                    icon: Icons.event_note_outlined,
                    onTap: () => _pickDay(isStatement: true),
                  ),
                  const SizedBox(height: 10),
                  VeriAnchoredChoice<CreditDueRuleType>(
                    values: CreditDueRuleType.values,
                    selected: _draft.dueRuleType,
                    idOf: (value) => 'credit_due_rule_${value.name}',
                    labelOf: (value) => value == CreditDueRuleType.fixedDay
                        ? l10n.creditDueRuleFixedDay
                        : l10n.creditDueRuleDaysAfter,
                    onSelected: (value) {
                      setState(() {
                        var next = _draft.copyWith(dueRuleType: value);
                        if (value == CreditDueRuleType.daysAfterStatement &&
                            next.daysAfterStatement == null) {
                          // 20 天是常见相对还款周期；切换规则时补默认值，避免出现
                          // “已选择相对规则但没有间隔”的不可保存中间状态。
                          next = next.copyWith(daysAfterStatement: 20);
                        }
                        _draft = next;
                      });
                    },
                    semanticLabel: l10n.creditDueRuleLabel,
                    builder: (context, openMenu, menuOpen) => SelectField(
                      label: l10n.creditDueRuleLabel,
                      value: _draft.dueRuleType == CreditDueRuleType.fixedDay
                          ? l10n.creditDueRuleFixedDay
                          : l10n.creditDueRuleDaysAfter,
                      icon: Icons.event_available_outlined,
                      onTap: openMenu,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SelectField(
                    label: _draft.dueRuleType == CreditDueRuleType.fixedDay
                        ? l10n.dueDay
                        : l10n.creditDaysAfterStatementLabel,
                    value: _dueRuleValue(l10n),
                    icon: Icons.calendar_month_outlined,
                    onTap: () => _pickDay(isStatement: false),
                  ),
                  const SizedBox(height: 10),
                  SelectField(
                    label: l10n.creditCycleBudgetLabel,
                    value: _draft.cycleBudget == null
                        ? l10n.notSet
                        : formatUserMoney(
                            _draft.cycleBudget!,
                            _draft.currencyCode,
                          ),
                    icon: Icons.donut_large_outlined,
                    onTap: () => _pickAmount(isBudget: true),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${currency.code} · ${currency.nameForLocale(Localizations.localeOf(context).toLanguageTag())}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.56),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 格式化还款规则的当前数值；未设置时保持统一的“未设置”文案。
  String _dueRuleValue(AppLocalizations l10n) {
    if (_draft.dueRuleType == CreditDueRuleType.fixedDay) {
      return _draft.dueDay == null
          ? l10n.notSet
          : l10n.monthlyDayLabel(_draft.dueDay!);
    }
    return _draft.daysAfterStatement == null
        ? l10n.notSet
        : l10n.creditDaysAfterStatement(_draft.daysAfterStatement!);
  }

  /// 选择共享额度或账期预算。输入 0 表示清除，正数按主体币种精度保存。
  Future<void> _pickAmount({required bool isBudget}) async {
    final value = await showNumberPadSheet(
      context,
      title: isBudget
          ? AppLocalizations.of(context).creditCycleBudgetLabel
          : AppLocalizations.of(context).creditLimitEditTitle,
      initialAmount: isBudget ? _draft.cycleBudget : _draft.creditLimit,
      allowZero: true,
      currencyCode: _draft.currencyCode,
      maxFractionDigits: CurrencyCatalog.require(_draft.currencyCode).minorUnit,
    );
    if (!mounted || value == null) return;
    setState(() {
      _draft = isBudget
          ? _draft.copyWith(
              cycleBudget: value > 0 ? value : null,
              clearCycleBudget: value <= 0,
            )
          : _draft.copyWith(
              creditLimit: value > 0 ? value : null,
              clearCreditLimit: value <= 0,
            );
    });
  }

  /// 选择账单日、固定还款日或“账单日后 N 天”。全部限制在安全范围内；0 是仅在
  /// 弹层内部使用的清除哨兵，不会写入领域模型。
  Future<void> _pickDay({required bool isStatement}) async {
    const clearValue = 0;
    final relative =
        !isStatement &&
        _draft.dueRuleType == CreditDueRuleType.daysAfterStatement;
    final current = isStatement
        ? _draft.statementDay
        : relative
        ? _draft.daysAfterStatement
        : _draft.dueDay;
    final max = relative ? 60 : 28;
    final selected = await showOptionSheet<int>(
      context: context,
      title: isStatement
          ? AppLocalizations.of(context).pickStatementDay
          : relative
          ? AppLocalizations.of(context).creditDaysAfterStatementLabel
          : AppLocalizations.of(context).pickDueDay,
      values: <int>[
        if (!relative) clearValue,
        for (var day = 1; day <= max; day++) day,
      ],
      selected: relative ? current ?? 20 : current ?? clearValue,
      labelOf: (value) {
        if (!relative && value == clearValue) {
          return AppLocalizations.of(context).clearOption;
        }
        return relative
            ? AppLocalizations.of(context).creditDaysAfterStatement(value)
            : AppLocalizations.of(context).monthlyDayLabel(value);
      },
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (isStatement) {
        _draft = _draft.copyWith(
          statementDay: selected == clearValue ? null : selected,
          clearStatementDay: selected == clearValue,
        );
      } else if (relative) {
        _draft = _draft.copyWith(daysAfterStatement: selected);
      } else {
        _draft = _draft.copyWith(
          dueDay: selected == clearValue ? null : selected,
          clearDueDay: selected == clearValue,
        );
      }
    });
  }

  /// 保存并退出。只有 Controller 确认 SQLite 写入成功后才把页面标记为已保存。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      setState(() => _saved = true);
      _exitController.exit();
    }
  }

  /// 校验文本字段并提交完整信用主体草稿；返回值供未保存离开保护决定是否退出。
  Future<bool> _save() async {
    if (!_formKey.currentState!.validate()) return false;
    final next = _draft.copyWith(
      name: _nameController.text.trim(),
      institution: _institutionController.text.trim(),
      cardLast4: cardLast4Of(_cardLast4Controller.text),
    );
    final saved = await VeriFinScope.of(context).saveCreditAccountDraft(next);
    if (!mounted || !saved) return false;
    unawaited(
      VeriFeedbackHost.of(context).showMessage(
        message: AppLocalizations.of(context).creditAccountSaved,
        tone: VeriFeedbackTone.success,
      ),
    );
    return true;
  }
}
