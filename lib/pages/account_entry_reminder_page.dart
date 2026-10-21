import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/models.dart';
import '../app/platform_bridge.dart';
import '../app/reminder/account_entry_reminder.dart';
import '../app/reminder/china_workday_calendar.dart';
import '../app/reminder/notification_scheduler.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 所有账户共用的记账提醒编辑页；保存前只修改本页草稿，默认提醒关闭。
class AccountEntryReminderPage extends StatefulWidget {
  /// [account] 指定固定归属账户，账本和金额币种由该账户确定，不跟随当前账本。
  const AccountEntryReminderPage({super.key, required this.account});
  final Account account;

  /// 创建负责草稿、输入校验与显式保存的页面状态。
  @override
  State<AccountEntryReminderPage> createState() =>
      _AccountEntryReminderPageState();
}

class _AccountEntryReminderPageState extends State<AccountEntryReminderPage> {
  final EditorExitController _exitController = EditorExitController();
  AccountEntryReminder? _initial;
  late AccountEntryReminder _draft;
  String? _error;
  bool _saving = false;
  bool _testing = false;

  /// 首次进入读取本机配置；依赖变化不覆盖用户正在编辑的草稿。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initial != null) return;
    final account = widget.account;
    _draft =
        VeriFinScope.of(context).accountEntryReminder(account.id) ??
        AccountEntryReminder(
          id: '',
          accountId: account.id,
          bookId: account.bookId,
          currencyCode: account.currencyCode,
        );
    _initial = _draft;
  }

  /// 比较完整配置快照，判断离开时是否需要通过现有草稿保护组件提示保存。
  bool get _isDirty =>
      jsonEncode(_draft.toJson()) != jsonEncode(_initial!.toJson());

  /// 更新本页草稿 [draft] 并清除先前校验错误；此操作不会申请权限或写入 KV。
  void _update(AccountEntryReminder draft) => setState(() {
    _draft = draft;
    _error = null;
  });

  /// 编辑名称或按钮文字；[field] 指定目标字段，空按钮文字回落为本地化默认值。
  Future<void> _editText(String field) async {
    final l10n = AppLocalizations.of(context);
    final title = switch (field) {
      'name' => l10n.accountEntryReminderName,
      'confirm' => l10n.accountEntryReminderConfirmLabel,
      _ => l10n.accountEntryReminderCancelLabel,
    };
    final value = await showTextInputDialog(
      context: context,
      title: title,
      label: title,
      initialValue: switch (field) {
        'name' => _draft.name,
        'confirm' => _draft.confirmLabel,
        _ => _draft.cancelLabel,
      },
      allowEmpty: true,
    );
    if (!mounted || value == null) return;
    _update(switch (field) {
      'name' => _draft.copyWith(name: value.trim()),
      'confirm' => _draft.copyWith(confirmLabel: value.trim()),
      _ => _draft.copyWith(cancelLabel: value.trim()),
    });
  }

  /// 用统一金额键盘修改账户原币金额，禁止负数和零，不提前冻结未来的本位币汇率。
  Future<void> _pickAmount() async {
    final amount = await showNumberPadSheet(
      context,
      title: AppLocalizations.of(context).accountEntryReminderAmount,
      initialAmount: _draft.amount,
      currencyCode: _draft.currencyCode,
    );
    if (!mounted || amount == null) return;
    _update(_draft.copyWith(amount: amount));
  }

  /// 通过已有多级分类选择器选择与当前收入/支出类型一致的分类。
  Future<void> _pickCategory() async {
    final selected = await showCategoryPickerSheet(
      context,
      categories: VeriFinScope.of(
        context,
      ).categories.where((item) => item.type == _draft.type).toList(),
      selectedId: _draft.categoryId,
    );
    if (!mounted || selected == null) return;
    _update(_draft.copyWith(categoryId: selected));
  }

  /// 系统时间选择器自动跟随 app locale；只保存本地时刻，不使用绝对 24 小时偏移。
  Future<void> _pickTime() async {
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _draft.hour, minute: _draft.minute),
    );
    if (!mounted || selected == null) return;
    _update(_draft.copyWith(hour: selected.hour, minute: selected.minute));
  }

  /// 保存时先校验必填项；首次启用才申请通知权限，拒绝时保留草稿且不宣称保存成功。
  /// 保存或测试仍在等待系统结果时拒绝再次提交，避免两个权限/排程流程互相干扰。
  /// 平台排程由根组件监听已落盘的配置后执行，异常显示根级轻提示。
  Future<bool> _save() async {
    if (_saving || _testing) return false;
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    if ((_draft.repeatMode == AccountReminderRepeatMode.weekdays &&
            _draft.weekdays.isEmpty) ||
        _draft.confirmLabel.length > 12 ||
        _draft.cancelLabel.length > 12 ||
        _draft.enabled &&
            (_draft.amount <= 0 ||
                !_draft.amount.isFinite ||
                !controller.categories.any(
                  (item) =>
                      item.id == _draft.categoryId && item.type == _draft.type,
                ))) {
      setState(() => _error = l10n.accountEntryReminderValidation);
      return false;
    }
    setState(() => _saving = true);
    try {
      if (_draft.enabled &&
          controller.accountEntryReminder(_draft.accountId)?.enabled != true) {
        final granted = await NotificationScheduler().requestPermission();
        if (!mounted) return false;
        if (!granted) {
          setState(() => _error = l10n.reminderPermissionDenied);
          return false;
        }
      }
      final saved = await controller.saveAccountEntryReminder(_draft);
      if (!mounted) return saved;
      if (saved) {
        _initial = _draft;
      } else {
        setState(() => _error = l10n.saveFailed);
      }
      return saved;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 顶部保存按钮先等待落盘；成功后使用已有编辑退出控制器返回账户详情。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      _exitController.exit();
    }
  }

  /// 用户点按钮后申请通知权限，再交给 Android 安排一分钟后的测试通知。
  /// 仅用当前草稿名称标识测试对象，不保存草稿、不启用正式提醒，也不写入交易。
  /// 等待期间禁用按钮防止重复提交；原生返回非精确排程时明确提示可能延迟。
  Future<void> _scheduleTest() async {
    if (_testing || _saving) return;
    final controller = VeriFinScope.of(context);
    final feedback = VeriFeedbackHost.of(context);
    final l10n = AppLocalizations.of(context);
    final name = _draft.name.trim();
    setState(() => _testing = true);
    try {
      final granted = await NotificationScheduler().requestPermission();
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
      final exact = await AppAccountReminderBridge.scheduleTest(
        title: l10n.accountEntryReminderTestTitle(
          name.isEmpty ? widget.account.name : name,
        ),
        body: l10n.accountEntryReminderTestBody,
        channelName: l10n.accountEntryReminderTitle,
      );
      if (!mounted) return;
      unawaited(
        feedback.showMessage(
          message: exact
              ? l10n.accountEntryReminderTestScheduled
              : l10n.accountEntryReminderTestInexact,
          tone: exact ? VeriFeedbackTone.success : VeriFeedbackTone.warning,
          duration: VeriFeedbackDuration.long,
        ),
      );
    } catch (error) {
      // 只记录阶段和异常类型，避免平台异常包含账户名等测试通知内容。
      controller.logger?.error(
        '账户提醒测试排程失败：${error.runtimeType}',
        source: 'AccountEntryReminder',
      );
      if (!mounted) return;
      unawaited(
        feedback.showMessage(
          message: l10n.accountEntryReminderTestFailed,
          tone: VeriFeedbackTone.error,
          duration: VeriFeedbackDuration.long,
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 使用统一实色页面、设置行和单选组件展示草稿；确认方式区分按钮文字与固定动作。
  /// 测试按钮独立于启用状态与草稿保存，只验证系统通知，并说明强行停止的边界。
  /// 工作日模式展示日历覆盖年份和缺失策略；旧的自定义星期留在草稿中，切回不丢失。
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = VeriFinScope.of(context);
    final category = controller.categories
        .where((item) => item.id == _draft.categoryId)
        .firstOrNull;
    final weekdays = [
      l10n.weekdayMon,
      l10n.weekdayTue,
      l10n.weekdayWed,
      l10n.weekdayThu,
      l10n.weekdayFri,
      l10n.weekdaySat,
      l10n.weekdaySun,
    ];
    return UnsavedChangesGuard(
      isDirty: _isDirty,
      onSave: _save,
      exitController: _exitController,
      child: Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
              children: [
                VeriHeader(
                  title: l10n.accountEntryReminderTitle,
                  subtitle: widget.account.name,
                  showBack: true,
                  actions: [
                    SaveHeaderAction(
                      onPressed: _isDirty && !_saving && !_testing
                          ? _saveAndExit
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                VeriCard(
                  child: CompactSwitchRow(
                    icon: Icons.notifications_active_outlined,
                    title: Text(l10n.accountEntryReminderEnabled),
                    subtitle: Text(l10n.accountEntryReminderDescription),
                    value: _draft.enabled,
                    onChanged: (value) =>
                        _update(_draft.copyWith(enabled: value)),
                  ),
                ),
                const SizedBox(height: 12),
                VeriCard(
                  child: Column(
                    children: [
                      SettingsRow(
                        icon: Icons.badge_outlined,
                        title: l10n.accountEntryReminderName,
                        trailing: _draft.name.isEmpty
                            ? l10n.accountEntryReminderTitle
                            : _draft.name,
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _editText('name'),
                      ),
                      const Divider(height: 1),
                      VeriAnchoredChoice<EntryType>(
                        values: const [EntryType.expense, EntryType.income],
                        selected: _draft.type,
                        semanticLabel: l10n.commonType,
                        idOf: (value) => value.name,
                        labelOf: (value) => value.label(l10n),
                        onSelected: (value) => _update(
                          _draft.copyWith(type: value, categoryId: ''),
                        ),
                        builder: (context, openMenu, menuOpen) => SettingsRow(
                          icon: Icons.swap_vert,
                          title: l10n.commonType,
                          trailing: _draft.type.label(l10n),
                          trailingIcon: Icons.chevron_right,
                          onTap: openMenu,
                        ),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.payments_outlined,
                        title: l10n.accountEntryReminderAmount,
                        trailing: formatUserMoney(
                          _draft.amount,
                          _draft.currencyCode,
                        ),
                        trailingIcon: Icons.chevron_right,
                        onTap: _pickAmount,
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.category_outlined,
                        title: l10n.commonCategory,
                        trailing: category?.label ?? l10n.commonNoneShort,
                        trailingIcon: Icons.chevron_right,
                        onTap: _pickCategory,
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.schedule,
                        title: l10n.accountEntryReminderTime,
                        trailing: TimeOfDay(
                          hour: _draft.hour,
                          minute: _draft.minute,
                        ).format(context),
                        trailingIcon: Icons.chevron_right,
                        onTap: _pickTime,
                      ),
                      const Divider(height: 1),
                      VeriAnchoredChoice<AccountReminderRepeatMode>(
                        values: AccountReminderRepeatMode.values,
                        selected: _draft.repeatMode,
                        semanticLabel: l10n.accountEntryReminderRepeatMode,
                        idOf: (value) => value.name,
                        labelOf: (value) => value.label(l10n),
                        onSelected: (value) =>
                            _update(_draft.copyWith(repeatMode: value)),
                        builder: (context, openMenu, menuOpen) => SettingsRow(
                          key: const Key('account_reminder_repeat_mode'),
                          icon: Icons.event_repeat,
                          title: l10n.accountEntryReminderRepeatMode,
                          trailing: _draft.repeatMode.label(l10n),
                          trailingMaxLines: null,
                          trailingIcon: Icons.chevron_right,
                          onTap: openMenu,
                        ),
                      ),
                      if (_draft.repeatMode ==
                          AccountReminderRepeatMode.chinaWorkdays) ...[
                        const Divider(height: 1),
                        VeriAnchoredChoice<MissingWorkdayCalendarPolicy>(
                          values: MissingWorkdayCalendarPolicy.values,
                          selected: _draft.missingCalendarPolicy,
                          semanticLabel:
                              l10n.accountEntryReminderCalendarPolicy,
                          idOf: (value) => value.name,
                          labelOf: (value) => value.label(l10n),
                          onSelected: (value) => _update(
                            _draft.copyWith(missingCalendarPolicy: value),
                          ),
                          builder: (context, openMenu, menuOpen) => SettingsRow(
                            key: const Key('account_reminder_calendar_policy'),
                            icon: Icons.event_busy_outlined,
                            title: l10n.accountEntryReminderCalendarPolicy,
                            trailing: _draft.missingCalendarPolicy.label(l10n),
                            trailingMaxLines: null,
                            trailingIcon: Icons.chevron_right,
                            onTap: openMenu,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.accountEntryReminderCalendarCoverage(
                                  mainlandChinaWorkdayCalendar.supportedYears
                                      .join(' / '),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(l10n.accountEntryReminderWorkdayHint),
                              if (_draft.hasMissingCalendar(
                                DateTime.now(),
                              )) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _draft.missingCalendarPolicy ==
                                          MissingWorkdayCalendarPolicy.pause
                                      ? l10n.accountEntryReminderCalendarMissingPause(
                                          DateTime.now().year,
                                        )
                                      : l10n.accountEntryReminderCalendarMissingWeekdays(
                                          DateTime.now().year,
                                        ),
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                      if (_draft.repeatMode ==
                          AccountReminderRepeatMode.weekdays)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.accountEntryReminderRepeat),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (var day = 1; day <= 7; day++)
                                    FilterChip(
                                      label: Text(weekdays[day - 1]),
                                      selected: _draft.weekdays.contains(day),
                                      onSelected: (selected) => _update(
                                        _draft.copyWith(
                                          weekdays: [
                                            for (final value in _draft.weekdays)
                                              if (value != day) value,
                                            if (selected) day,
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionLabel(l10n.accountEntryReminderConfirmation),
                VeriCard(
                  child: Column(
                    children: [
                      SettingsRow(
                        icon: Icons.check_circle_outline,
                        title: l10n.accountEntryReminderConfirmLabel,
                        trailing: _draft.confirmLabel.isEmpty
                            ? l10n.accountEntryReminderConfirmDefault
                            : _draft.confirmLabel,
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _editText('confirm'),
                      ),
                      const Divider(height: 1),
                      SettingsRow(
                        icon: Icons.cancel_outlined,
                        title: l10n.accountEntryReminderCancelLabel,
                        trailing: _draft.cancelLabel.isEmpty
                            ? l10n.commonCancel
                            : _draft.cancelLabel,
                        trailingIcon: Icons.chevron_right,
                        onTap: () => _editText('cancel'),
                      ),
                      const SizedBox(height: 8),
                      Text(l10n.accountEntryReminderButtonHint),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('account_entry_reminder_test'),
                  onPressed: _testing || _saving ? null : _scheduleTest,
                  icon: const Icon(Icons.notifications_outlined, size: 18),
                  label: Text(l10n.accountEntryReminderTestButton),
                ),
                Text(
                  l10n.accountEntryReminderTestHint,
                  style: Theme.of(context).textTheme.bodySmall,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
