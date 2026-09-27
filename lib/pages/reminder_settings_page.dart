import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/reminder/financial_reminder.dart';
import '../app/reminder/notification_scheduler.dart';
import '../app/reminder/reminder_settings.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 提醒设置与信用账户近期状态页。
///
/// 每日记账、账期预算、出账日和还款日均为显式开关；开启任一系统提醒时才申请通知
/// 权限。页面下半部分直接展示实时信用账户投影，让用户无需等待通知也能检查口径。
class ReminderSettingsPage extends StatefulWidget {
  const ReminderSettingsPage({super.key});

  /// 创建保留设置草稿的页面状态。
  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage> {
  final EditorExitController _exitController = EditorExitController();
  final NotificationScheduler _scheduler = NotificationScheduler();
  late ReminderSettings _initialSettings;
  late ReminderSettings _draftSettings;
  bool _initialized = false;

  /// 首次进入页面时抓取 Controller 快照；后续依赖变化不覆盖尚未保存的草稿。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    final settings = VeriFinScope.of(context).reminderSettings;
    _initialSettings = _draftSettings = settings;
    _initialized = true;
  }

  /// 选择所有通知共用的本地触发时刻。
  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _draftSettings.hour,
        minute: _draftSettings.minute,
      ),
      helpText: AppLocalizations.of(context).reminderPickTime,
    );
    if (picked != null && mounted) {
      setState(() {
        _draftSettings = _draftSettings.copyWith(
          hour: picked.hour,
          minute: picked.minute,
        );
      });
    }
  }

  /// 选择出账日和还款日提前提醒的天数。
  Future<void> _pickAdvanceDays() async {
    final l10n = AppLocalizations.of(context);
    final selected = await showOptionSheet<int>(
      context: context,
      title: l10n.reminderAdvanceDays,
      values: const <int>[0, 1, 3, 5, 7],
      selected: _draftSettings.advanceDays,
      labelOf: (days) =>
          days == 0 ? l10n.reminderOnDate : l10n.reminderAdvanceDaysValue(days),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      _draftSettings = _draftSettings.copyWith(advanceDays: selected);
    });
  }

  /// 渲染设置草稿和当前信用账户状态；保存前所有开关都不会写入 KV。
  @override
  Widget build(BuildContext context) {
    final settings = _draftSettings;
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final snapshots = controller.creditReminderSnapshots();
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);

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
                  title: l10n.reminderTitle,
                  showBack: true,
                  actions: <Widget>[
                    SaveHeaderAction(onPressed: _isDirty ? _saveAndExit : null),
                  ],
                ),
                const SizedBox(height: 10),
                _sectionLabel(context, l10n.reminderSectionDaily),
                const SizedBox(height: 6),
                VeriCard(
                  child: CompactSwitchRow(
                    icon: Icons.notifications_active_outlined,
                    title: Text(l10n.reminderDaily),
                    subtitle: Text(l10n.reminderDailyDescription),
                    value: settings.enabled,
                    onChanged: (enabled) => setState(
                      () =>
                          _draftSettings = settings.copyWith(enabled: enabled),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _sectionLabel(context, l10n.reminderSectionFinancial),
                const SizedBox(height: 6),
                VeriCard(
                  child: Column(
                    children: <Widget>[
                      CompactSwitchRow(
                        icon: Icons.donut_large_outlined,
                        title: Text(l10n.reminderCycleBudget),
                        subtitle: Text(l10n.reminderCycleBudgetDescription),
                        value: settings.cycleBudgetEnabled,
                        onChanged: (enabled) => setState(
                          () => _draftSettings = settings.copyWith(
                            cycleBudgetEnabled: enabled,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      CompactSwitchRow(
                        icon: Icons.receipt_long_outlined,
                        title: Text(l10n.reminderStatementDate),
                        subtitle: Text(l10n.reminderStatementDateDescription),
                        value: settings.statementDateEnabled,
                        onChanged: (enabled) => setState(
                          () => _draftSettings = settings.copyWith(
                            statementDateEnabled: enabled,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      CompactSwitchRow(
                        icon: Icons.event_busy_outlined,
                        title: Text(l10n.reminderRepaymentDue),
                        subtitle: Text(l10n.reminderRepaymentDueDescription),
                        value: settings.repaymentDueEnabled,
                        onChanged: (enabled) => setState(
                          () => _draftSettings = settings.copyWith(
                            repaymentDueEnabled: enabled,
                          ),
                        ),
                      ),
                      if (settings.statementDateEnabled ||
                          settings.repaymentDueEnabled) ...<Widget>[
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.date_range_outlined,
                          title: l10n.reminderAdvanceDays,
                          trailing: settings.advanceDays == 0
                              ? l10n.reminderOnDate
                              : l10n.reminderAdvanceDaysValue(
                                  settings.advanceDays,
                                ),
                          trailingIcon: Icons.chevron_right,
                          onTap: _pickAdvanceDays,
                        ),
                      ],
                    ],
                  ),
                ),
                if (settings.hasAnyEnabled) ...<Widget>[
                  const SizedBox(height: 12),
                  VeriCard(
                    child: SettingsRow(
                      icon: Icons.schedule_outlined,
                      title: l10n.reminderTimeLabel,
                      trailing: settings.timeLabel,
                      trailingIcon: Icons.chevron_right,
                      onTap: _pickTime,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    _scheduler.supported
                        ? l10n.reminderDescSupported
                        : l10n.reminderDescUnsupported,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: muted, height: 1.5),
                  ),
                ),
                if (_scheduler.supported) ...<Widget>[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _sendTest,
                    icon: const Icon(Icons.notifications_outlined, size: 18),
                    label: Text(l10n.reminderTestButton),
                  ),
                ],
                const SizedBox(height: 18),
                _sectionLabel(context, l10n.reminderFinancialPreview),
                const SizedBox(height: 6),
                if (snapshots.isEmpty)
                  VeriCard(
                    child: Text(
                      l10n.reminderNoCreditAccounts,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: muted),
                    ),
                  )
                else
                  ...snapshots.map(
                    (snapshot) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _CreditReminderCard(snapshot: snapshot),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 发送一条即时测试通知，用于区分权限问题和定时调度问题。
  Future<void> _sendTest() async {
    final feedback = VeriFeedbackHost.of(context);
    final l10n = AppLocalizations.of(context);
    // 先确保有通知/精确闹钟权限（首次可能未申请过），再立即发一条测试通知。
    final granted = await _scheduler.requestPermission();
    if (!mounted) {
      return;
    }
    // 权限被拒时不能报「已发送」：用户会以为提醒正常，实际一条都收不到。
    if (!granted) {
      unawaited(
        feedback.showMessage(
          message: l10n.reminderPermissionDenied,
          tone: VeriFeedbackTone.warning,
          duration: VeriFeedbackDuration.long,
        ),
      );
      return;
    }
    await _scheduler.showTest(l10n: l10n);
    if (!mounted) {
      return;
    }
    unawaited(
      feedback.showMessage(
        message: l10n.reminderTestSent,
        tone: VeriFeedbackTone.success,
      ),
    );
  }

  bool get _isDirty => _draftSettings != _initialSettings;

  /// 保存草稿并在成功后退出；失败时留在当前页，方便用户重试。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      setState(() => _initialSettings = _draftSettings);
      _exitController.exit();
    }
  }

  /// 持久化提醒草稿；从“全部关闭”变为任一开启时才主动请求系统通知权限。
  Future<bool> _save() async {
    final feedback = VeriFeedbackHost.of(context);
    final l10n = AppLocalizations.of(context);
    var granted = true;
    if (_draftSettings.hasAnyEnabled && !_initialSettings.hasAnyEnabled) {
      granted = await _scheduler.requestPermission();
      if (!mounted) {
        return false;
      }
    }
    final saved = await VeriFinScope.of(
      context,
    ).saveReminderSettingsDraft(_draftSettings);
    if (!mounted || !saved) {
      return false;
    }
    if (_draftSettings.hasAnyEnabled && _scheduler.supported && !granted) {
      unawaited(
        feedback.showMessage(
          message: l10n.reminderPermissionDenied,
          tone: VeriFeedbackTone.warning,
          duration: VeriFeedbackDuration.long,
        ),
      );
    }
    return true;
  }
}

/// 提醒设置页的小节标题，保持与其他设置页一致的弱化层级。
Widget _sectionLabel(BuildContext context, String label) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// 单个信用主体的实时提醒卡片。
///
/// 卡片只消费 [CreditReminderSnapshot]，不自行重算账期或账单金额；这样后续系统通知
/// 接入时可以复用同一投影，并用纯函数测试保证两端显示一致。
class _CreditReminderCard extends StatelessWidget {
  const _CreditReminderCard({required this.snapshot});

  final CreditReminderSnapshot snapshot;

  /// 展示出账倒计时、还款状态和账期预算档位。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final account = snapshot.creditAccount;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final statusLines = <Widget>[
      _statusLine(
        context,
        Icons.receipt_long_outlined,
        snapshot.daysUntilStatement == 0
            ? l10n.reminderStatementToday
            : l10n.reminderDaysUntilStatement(snapshot.daysUntilStatement),
      ),
      const SizedBox(height: 6),
      _statusLine(
        context,
        snapshot.daysUntilDue < 0
            ? Icons.warning_amber_rounded
            : Icons.event_available_outlined,
        _dueText(l10n),
        warning: snapshot.daysUntilDue <= 2 && snapshot.hasOutstandingStatement,
      ),
    ];
    if (snapshot.hasFormalStatement) {
      statusLines
        ..add(const SizedBox(height: 6))
        ..add(
          _statusLine(
            context,
            snapshot.latestStatementSettled
                ? Icons.check_circle_outline_rounded
                : Icons.account_balance_wallet_outlined,
            _statementText(l10n),
            success: snapshot.latestStatementSettled,
            warning: !snapshot.latestStatementSettled,
          ),
        );
    }
    final budgetText = _budgetText(l10n);
    if (budgetText != null) {
      statusLines
        ..add(const SizedBox(height: 6))
        ..add(
          _statusLine(
            context,
            Icons.donut_large_outlined,
            budgetText,
            warning: snapshot.budgetAlertLevel != CycleBudgetAlertLevel.none,
          ),
        );
    }
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  account.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                account.currencyCode,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...statusLines,
        ],
      ),
    );
  }

  /// 生成还款日状态；有未结金额时才把临期/逾期表达成风险提示。
  String _dueText(AppLocalizations l10n) {
    if (snapshot.daysUntilDue < 0) {
      return l10n.reminderDueOverdue(-snapshot.daysUntilDue);
    }
    if (snapshot.daysUntilDue == 0) {
      return l10n.reminderDueToday;
    }
    return l10n.reminderDaysUntilDue(snapshot.daysUntilDue);
  }

  /// 生成最近一期正式账单摘要；缺汇率时拒绝展示伪造合计。
  String _statementText(AppLocalizations l10n) {
    if (snapshot.formalStatementMissingConversion) {
      return l10n.reminderMissingRate;
    }
    if (snapshot.latestStatementSettled) {
      return l10n.reminderSettled;
    }
    final billed = formatUserMoney(
      snapshot.latestBilledAmount,
      snapshot.creditAccount.currencyCode,
    );
    final outstanding = formatUserMoney(
      snapshot.latestOutstandingAmount,
      snapshot.creditAccount.currencyCode,
    );
    return '${l10n.reminderBilledAmount(billed)} · '
        '${l10n.reminderOutstandingAmount(outstanding)}';
  }

  /// 按 80% / 达到 / 超出三档生成账期预算摘要；未设置预算时不占用卡片空间。
  String? _budgetText(AppLocalizations l10n) {
    final budget = snapshot.creditAccount.cycleBudget;
    final ratio = snapshot.budgetUsageRatio;
    if (budget == null) {
      return null;
    }
    if (ratio == null) {
      return l10n.reminderMissingRate;
    }
    return switch (snapshot.budgetAlertLevel) {
      CycleBudgetAlertLevel.exceeded => l10n.reminderBudgetExceeded(
        formatUserMoney(
          (snapshot.overview.netSpending - budget).clamp(0.0, double.infinity),
          snapshot.creditAccount.currencyCode,
        ),
      ),
      CycleBudgetAlertLevel.reached => l10n.reminderBudgetReached,
      CycleBudgetAlertLevel.warning => l10n.reminderBudgetWarning(
        (ratio * 100).floor().clamp(0, 999),
      ),
      CycleBudgetAlertLevel.none => l10n.reminderBudgetUsage(
        (ratio * 100).floor().clamp(0, 999),
      ),
    };
  }

  /// 渲染统一图标 + 状态文本行；颜色只使用语义色令牌。
  Widget _statusLine(
    BuildContext context,
    IconData icon,
    String text, {
    bool warning = false,
    bool success = false,
  }) {
    final color = success
        ? veriSemantic(context, veriIncome)
        : warning
        ? veriSemantic(context, veriWarning)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: warning || success ? FontWeight.w700 : null,
            ),
          ),
        ),
      ],
    );
  }
}
