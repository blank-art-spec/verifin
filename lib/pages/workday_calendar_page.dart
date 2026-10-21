import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/feedback.dart';
import '../app/reminder/workday_calendar_sync.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';

/// 所有账户共用的工作日日历工具页；联网授权即时保存，下载缓存仍可离线使用。
class WorkdayCalendarPage extends StatefulWidget {
  /// 不绑定账户，避免切换账本或编辑账户草稿时重复维护全局日历。
  const WorkdayCalendarPage({super.key});

  /// 创建管理开关保存与用户主动检查动作的页面状态。
  @override
  State<WorkdayCalendarPage> createState() => _WorkdayCalendarPageState();
}

class _WorkdayCalendarPageState extends State<WorkdayCalendarPage> {
  bool _saving = false;

  /// 保存用户的 [enabled] 选择，成功开启后立即检查；关闭保留已缓存日历。
  /// 此开关只控制本功能的公共年份请求，不读取其他应用通知或手机日历。
  Future<void> _setEnabled(bool enabled) async {
    if (_saving) return;
    final controller = VeriFinScope.of(context);
    final feedback = VeriFeedbackHost.of(context);
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final saved = await controller.setWorkdayCalendarAutoUpdate(enabled);
      if (!mounted) return;
      if (!saved) {
        unawaited(
          feedback.showMessage(
            message: l10n.saveFailed,
            tone: VeriFeedbackTone.error,
          ),
        );
      } else if (enabled) {
        unawaited(_checkForUpdates());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 用户主动检查当前及下一年度，绕过每日节流但仍要求开关已开启。
  /// force 固定为 true；结果只说明缓存保存，原生排程失败由根组件反馈。
  Future<void> _checkForUpdates() async {
    final controller = VeriFinScope.of(context);
    final feedback = VeriFeedbackHost.of(context);
    final l10n = AppLocalizations.of(context);
    final result = await controller.syncWorkdayCalendar(force: true);
    if (!mounted) return;
    final message = switch (result) {
      WorkdayCalendarSyncResult.updated => l10n.workdayCalendarUpdated,
      WorkdayCalendarSyncResult.pending => l10n.workdayCalendarPending,
      WorkdayCalendarSyncResult.partial => l10n.workdayCalendarPartial,
      WorkdayCalendarSyncResult.failed => l10n.workdayCalendarFailed,
      WorkdayCalendarSyncResult.skipped ||
      WorkdayCalendarSyncResult.disabled => null,
    };
    if (message == null) return;
    unawaited(
      feedback.showMessage(
        message: message,
        tone: result == WorkdayCalendarSyncResult.updated
            ? VeriFeedbackTone.success
            : VeriFeedbackTone.warning,
        duration: VeriFeedbackDuration.long,
        dedupeKey: 'workday-calendar-manual-check',
      ),
    );
  }

  /// 显示已落盘的授权、可用年份、来源和检查结果；运行中可关闭联网以撤销后续请求。
  /// 日期与时间通过 MaterialLocalizations 格式化，跟随 app 语言和设备时间制式。
  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<WorkdayCalendarSettings>(
      valueListenable: controller.workdayCalendarListenable,
      builder: (context, settings, _) {
        final checkedAt = settings.checkedAt;
        final material = MaterialLocalizations.of(context);
        return Scaffold(
          body: SafeArea(
            child: VeriPage(
              child: ListView(
                key: const Key('workday_calendar_page'),
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
                children: [
                  VeriHeader(title: l10n.workdayCalendarTitle, showBack: true),
                  const SizedBox(height: 10),
                  VeriCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CompactSwitchRow(
                          key: const Key('workday_calendar_auto_update'),
                          icon: Icons.cloud_sync_outlined,
                          title: Text(l10n.workdayCalendarAutoUpdate),
                          subtitle: Text(l10n.workdayCalendarAutoUpdateHint),
                          value: settings.enabled,
                          onChanged: _saving ? null : _setEnabled,
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.workdayCalendarPrivacy),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  VeriCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.accountEntryReminderCalendarCoverage(
                            settings.calendar.supportedYears.join(' / '),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          checkedAt == null
                              ? l10n.workdayCalendarNeverChecked
                              : l10n.workdayCalendarCheckedAt(
                                  material.formatFullDate(checkedAt),
                                  material.formatTimeOfDay(
                                    TimeOfDay.fromDateTime(checkedAt),
                                    alwaysUse24HourFormat:
                                        MediaQuery.alwaysUse24HourFormatOf(
                                          context,
                                        ),
                                  ),
                                ),
                        ),
                        if (settings.pendingYears.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.workdayCalendarPendingYears(
                              (settings.pendingYears.toList()..sort()).join(
                                ' / ',
                              ),
                            ),
                          ),
                        ],
                        if (settings.failedYears.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.workdayCalendarFailedYears(
                              (settings.failedYears.toList()..sort()).join(
                                ' / ',
                              ),
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          key: const Key('workday_calendar_check_now'),
                          onPressed:
                              !settings.enabled || settings.updating || _saving
                              ? null
                              : _checkForUpdates,
                          icon: settings.updating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                          label: Text(
                            settings.updating
                                ? l10n.workdayCalendarChecking
                                : l10n.workdayCalendarCheckNow,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.workdayCalendarOfflineHint),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  VeriCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.workdayCalendarSource),
                        const SizedBox(height: 8),
                        const SelectableText(
                          'https://github.com/NateScarlet/holiday-cn',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
