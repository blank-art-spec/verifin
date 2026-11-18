import 'reminder_settings.dart';
import 'financial_reminder.dart';
import '../../l10n/app_localizations.dart';

/// 非移动平台（测试宿主）的通知占位实现：一律不可用、不做任何调度。
class NotificationScheduler {
  const NotificationScheduler();

  /// 平台是否支持本地通知。
  bool get supported => false;

  /// 初始化通知插件与时区。占位实现无操作。
  Future<void> init() async {}

  /// 请求通知权限（Android 13+ / iOS）。占位返回 false。
  Future<bool> requestPermission() async => false;

  /// 按配置应用每日提醒：开启则调度、关闭则取消。占位无操作。
  Future<void> apply(
    ReminderSettings settings, {
    AppLocalizations? l10n,
    List<CreditReminderSnapshot> financialReminders =
        const <CreditReminderSnapshot>[],
  }) async {}

  /// 非移动平台无法显示预算跨档通知，因此返回 false，Controller 不写去重状态。
  Future<bool> showBudgetAlert(
    CreditReminderSnapshot reminder, {
    AppLocalizations? l10n,
  }) async => false;

  /// 取消已安排的正式提醒；[keepDaily] 表示是否保留每日提醒。占位无操作。
  Future<void> cancel({bool keepDaily = false}) async {}

  /// 占位平台无法安排延时测试；[l10n] 在移动端用于生成通知文案。
  Future<bool> scheduleDelayedTest({required AppLocalizations l10n}) async {
    throw UnsupportedError('当前平台不支持测试提醒');
  }

  /// 立即发一条测试通知。占位无操作。
  Future<void> showTest({AppLocalizations? l10n}) async {}
}
