import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/ledger_math.dart';
import '../app/reminder/financial_reminder.dart';
import '../app/reminder/notification_scheduler.dart';
import '../app/reminder/reminder_settings.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 日期选项中“恢复默认”的哨兵；0 是有效的还款日当天，null 留给关闭弹层。
const _defaultRepaymentDayOption = -1;

/// 将 [days] 转成账户还款日期规则的本地化文本；0 明确指还款日当天。
String _repaymentDayLabel(AppLocalizations l10n, int days) => days == 0
    ? l10n.reminderRepaymentOnDueDate
    : l10n.reminderRepaymentDaysBefore(days);

/// 将 [days] 转成账单日规则文案，沿用通用的提前天数和当天选项。
String _statementDayLabel(AppLocalizations l10n, int days) =>
    days == 0 ? l10n.reminderOnDate : l10n.reminderAdvanceDaysValue(days);

/// 提醒设置与信用账户近期状态页。
///
/// 每日记账、账期预算、出账日和还款日均为显式开关；开启任一系统提醒时才申请通知
/// 权限。页面下半部分直接展示实时信用账户投影，让用户无需等待通知也能检查口径。
class ReminderSettingsPage extends StatefulWidget {
  /// 创建提醒设置页。[scheduler] 仅用于在测试中替换设备通知服务；正式页面使用系统通知。
  const ReminderSettingsPage({super.key, this.scheduler});

  @visibleForTesting
  final NotificationScheduler? scheduler;

  /// 创建保留设置草稿的页面状态。
  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage> {
  final EditorExitController _exitController = EditorExitController();
  late final NotificationScheduler _scheduler =
      widget.scheduler ?? NotificationScheduler();
  late ReminderSettings _initialSettings;
  late ReminderSettings _draftSettings;
  bool _initialized = false;
  bool _schedulingDelayedTest = false;

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

  /// 选择全局本地时刻；已单独设置时分的还款提醒不受影响。
  Future<void> _pickTime() async {
    final picked = await showTimeOfDayPicker(
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

  /// 为 [creditAccountId] 选还款提醒日期：还款日当天、提前指定天数或恢复默认。
  /// 仅更新当前页面草稿，取消弹层不改变日期，时分也不随这次选择而改变。
  Future<void> _pickRepaymentDate(String creditAccountId) async {
    final l10n = AppLocalizations.of(context);
    final selected = await showOptionSheet<int>(
      context: context,
      title: l10n.reminderAccountRepaymentDate,
      values: <int>[
        _defaultRepaymentDayOption,
        for (var days = 0; days <= ReminderSettings.maxAdvanceDays; days++)
          days,
      ],
      selected:
          _draftSettings.repaymentAdvanceDaysOverride(creditAccountId) ??
          _defaultRepaymentDayOption,
      labelOf: (days) => days == _defaultRepaymentDayOption
          ? l10n.reminderRepaymentUsesDefault(
              _repaymentDayLabel(
                l10n,
                _draftSettings.defaultRepaymentAdvanceDays,
              ),
            )
          : _repaymentDayLabel(l10n, days),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _draftSettings = _draftSettings.withRepaymentAdvanceDays(
        creditAccountId,
        selected == _defaultRepaymentDayOption ? null : selected,
      );
    });
  }

  /// 选择 [creditAccountId] 在还款提醒当天的本地时分。
  /// 默认用全局时刻初始化选择器；恢复默认清除覆盖，取消不改动；所有更改仅写入草稿。
  Future<void> _pickRepaymentTime(String creditAccountId) async {
    final l10n = AppLocalizations.of(context);
    final custom = _draftSettings.repaymentTimeOverride(creditAccountId);
    final time = custom ?? _draftSettings.defaultTime;
    final picked = await showTimeOfDayPicker(
      context: context,
      initialTime: TimeOfDay(hour: time.hour, minute: time.minute),
      helpText: l10n.reminderAccountRepaymentTime,
      clearLabel: l10n.reminderRestoreDefaultTime,
      onClear: custom == null
          ? null
          : () {
              if (!mounted) return;
              setState(() {
                _draftSettings = _draftSettings.withRepaymentTime(
                  creditAccountId,
                  null,
                );
              });
            },
    );
    if (picked == null || !mounted) return;
    setState(() {
      _draftSettings = _draftSettings.withRepaymentTime(creditAccountId, (
        hour: picked.hour,
        minute: picked.minute,
      ));
    });
  }

  /// 编辑 [type] 对应的全局日期规则；只修改本页草稿，不改另一类提醒或账户覆盖。
  Future<void> _pickDefaultDate(CreditDateReminderType type) async {
    final l10n = AppLocalizations.of(context);
    final isRepayment = type == CreditDateReminderType.repayment;
    final selected = await showOptionSheet<int>(
      context: context,
      title: isRepayment
          ? l10n.reminderDefaultRepaymentDate
          : l10n.reminderStatementReminderDate,
      values: <int>[
        for (var days = 0; days <= ReminderSettings.maxAdvanceDays; days++)
          days,
      ],
      selected: isRepayment
          ? _draftSettings.defaultRepaymentAdvanceDays
          : _draftSettings.statementAdvanceDays,
      labelOf: isRepayment
          ? (days) => _repaymentDayLabel(l10n, days)
          : (days) => _statementDayLabel(l10n, days),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _draftSettings = isRepayment
          ? _draftSettings.copyWith(defaultRepaymentAdvanceDays: selected)
          : _draftSettings.copyWith(statementAdvanceDays: selected);
    });
  }

  /// 由 [context] 获取主题和本地化，渲染设置草稿、信用账户状态及下次提醒。
  /// 所有候选使用同一个查看时刻，修改草稿只预览，保存前不写 KV 或重排通知。
  @override
  Widget build(BuildContext context) {
    final settings = _draftSettings;
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final snapshots = controller.creditReminderSnapshots(now: now);
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
                      if (settings.statementDateEnabled) ...<Widget>[
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.date_range_outlined,
                          title: l10n.reminderStatementReminderDate,
                          trailing: _statementDayLabel(
                            l10n,
                            settings.statementAdvanceDays,
                          ),
                          trailingMaxLines: null,
                          trailingIcon: Icons.chevron_right,
                          onTap: () => _pickDefaultDate(
                            CreditDateReminderType.statement,
                          ),
                        ),
                      ],
                      if (settings.repaymentDueEnabled) ...<Widget>[
                        const Divider(height: 1),
                        SettingsRow(
                          icon: Icons.event_outlined,
                          title: l10n.reminderDefaultRepaymentDate,
                          trailing: _repaymentDayLabel(
                            l10n,
                            settings.defaultRepaymentAdvanceDays,
                          ),
                          trailingMaxLines: null,
                          trailingIcon: Icons.chevron_right,
                          onTap: () => _pickDefaultDate(
                            CreditDateReminderType.repayment,
                          ),
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
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _schedulingDelayedTest
                        ? null
                        : _scheduleDelayedTest,
                    icon: const Icon(Icons.timer_outlined, size: 18),
                    label: Text(l10n.reminderDelayedTestButton),
                  ),
                ],
                const SizedBox(height: 18),
                _sectionLabel(context, l10n.reminderFinancialPreview),
                const SizedBox(height: 6),
                if (_isDirty) ...<Widget>[
                  Text(
                    l10n.reminderScheduleDraftPreview,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 6),
                ],
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
                      child: _CreditReminderCard(
                        key: ValueKey<String>(
                          'credit_reminder_${snapshot.creditAccount.id}',
                        ),
                        snapshot: snapshot,
                        settings: settings,
                        now: now,
                        onPickRepaymentDate: () =>
                            _pickRepaymentDate(snapshot.creditAccount.id),
                        onPickRepaymentTime: () =>
                            _pickRepaymentTime(snapshot.creditAccount.id),
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

  /// 请求系统权限并独立安排一次一分钟后的账单与预算测试，无需先保存或启用提醒。
  /// 请求期间暂时禁用按钮。反馈区分未授权、已排程、可能延迟和失败，成功仅指系统接受。
  Future<void> _scheduleDelayedTest() async {
    if (_schedulingDelayedTest) return;
    final logger = VeriFinScope.of(context).logger;
    final feedback = VeriFeedbackHost.of(context);
    final l10n = AppLocalizations.of(context);
    setState(() => _schedulingDelayedTest = true);
    try {
      final granted = await _scheduler.requestPermission();
      if (!mounted) return;
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
      final exact = await _scheduler.scheduleDelayedTest(l10n: l10n);
      if (!mounted) return;
      unawaited(
        feedback.showMessage(
          message: exact
              ? l10n.reminderDelayedTestScheduled
              : l10n.reminderDelayedTestInexact,
          tone: exact ? VeriFeedbackTone.success : VeriFeedbackTone.warning,
          duration: VeriFeedbackDuration.long,
        ),
      );
    } catch (error) {
      // 只记录异常类型，避免日志带入系统异常中的通知内容。
      logger?.error('延时提醒测试排程失败：${error.runtimeType}', source: 'Reminder');
      if (!mounted) return;
      unawaited(
        feedback.showMessage(
          message: l10n.reminderDelayedTestFailed,
          tone: VeriFeedbackTone.error,
          duration: VeriFeedbackDuration.long,
        ),
      );
    } finally {
      if (mounted) setState(() => _schedulingDelayedTest = false);
    }
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
/// 账务状态读取 [CreditReminderSnapshot]，日期排程读取同一设置草稿与共享纯函数；
/// 不自行重算账单金额，确保页面与系统通知采用相同的欠款和日期条件。
class _CreditReminderCard extends StatelessWidget {
  /// [snapshot] 是账户状态，[settings] 是当前设置草稿，[now] 统一本帧的时间边界。
  /// [onPickRepaymentDate] 和 [onPickRepaymentTime] 编辑当前主体的日期规则和时分，
  /// 草稿及保存由设置页管理。
  const _CreditReminderCard({
    super.key,
    required this.snapshot,
    required this.settings,
    required this.now,
    required this.onPickRepaymentDate,
    required this.onPickRepaymentTime,
  });

  final CreditReminderSnapshot snapshot;
  final ReminderSettings settings;
  final DateTime now;
  final VoidCallback onPickRepaymentDate;
  final VoidCallback onPickRepaymentTime;

  /// 展示账务状态、下次实际计划时刻，以及可分别设置或继承全局的还款提醒日期和时分。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final account = snapshot.creditAccount;
    final customDays = settings.repaymentAdvanceDaysOverride(account.id);
    final customTime = settings.repaymentTimeOverride(account.id);
    final repaymentDateLabel = _repaymentDayLabel(
      l10n,
      settings.effectiveRepaymentAdvanceDays(account.id),
    );
    final repaymentTimeLabel = formatReminderTime(
      customTime ?? settings.defaultTime,
    );
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
    statusLines
      ..add(const SizedBox(height: 6))
      ..add(
        _statusLine(
          context,
          Icons.notifications_outlined,
          _nextReminderText(l10n),
        ),
      );
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
          const SizedBox(height: 8),
          const Divider(height: 1),
          SettingsRow(
            icon: Icons.event_outlined,
            title: l10n.reminderAccountRepaymentDate,
            trailing: customDays == null
                ? l10n.reminderRepaymentUsesDefault(repaymentDateLabel)
                : repaymentDateLabel,
            trailingMaxLines: null,
            trailingIcon: Icons.chevron_right,
            onTap: onPickRepaymentDate,
          ),
          const Divider(height: 1),
          SettingsRow(
            icon: Icons.schedule_outlined,
            title: l10n.reminderAccountRepaymentTime,
            trailing: customTime == null
                ? l10n.reminderRepaymentUsesDefault(repaymentTimeLabel)
                : repaymentTimeLabel,
            trailingMaxLines: null,
            trailingIcon: Icons.chevron_right,
            onTap: onPickRepaymentTime,
          ),
        ],
      ),
    );
  }

  /// 按 [settings] 取最早一条未来排程；关闭或无符合条件的排程时显示明确状态。
  /// [l10n] 负责日期、提醒类型和完整句子的本地化，时分复用统一格式化函数。
  /// 预算通知没有固定触发时刻，不能用提醒时间设置伪造其“下次时间”。
  String _nextReminderText(AppLocalizations l10n) {
    if (!settings.statementDateEnabled && !settings.repaymentDueEnabled) {
      return l10n.reminderNextDatesDisabled;
    }
    final dates = buildCreditDateReminders(
      snapshot: snapshot,
      settings: settings,
      now: now,
    );
    if (dates.isEmpty) {
      return l10n.reminderNextDatesNone;
    }
    final next = dates.first;
    final type = switch (next.type) {
      CreditDateReminderType.statement => l10n.reminderStatementDate,
      CreditDateReminderType.repayment => l10n.reminderRepaymentDue,
    };
    return l10n.reminderNextScheduled(
      next.scheduledAt,
      formatTime(next.scheduledAt),
      type,
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
