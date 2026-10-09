import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;

import '../currency_math.dart';
import 'financial_reminder.dart';
import 'reminder_settings.dart';
import '../../l10n/app_localizations.dart';

/// 移动平台的本地通知实现（`flutter_local_notifications` + `timezone`）。
/// 每日在用户设定时刻发一条记账提醒。**用精确闹钟**（`exactAllowWhileIdle`）：
/// inexact 调度在 Doze / 国产 ROM 后台限制下常被系统无限推迟、根本不显示，是历史上
/// 「设了提醒却收不到」的根因；精确闹钟在休眠下也能准时触发。无精确权限时回退 inexact。
class NotificationScheduler {
  NotificationScheduler();

  static const int _reminderId = 1001;
  static const int _testId = 1002;
  static const String _channelId = 'verifin_daily_reminder';
  static const String _channelName = '记账提醒';
  static const String _channelDescription = '每日记账提醒通知';
  static const String _financialChannelId = 'verifin_financial_reminder';
  static const String _financialChannelName = '账单与预算提醒';
  static const String _financialChannelDescription = '信用账户账单日、还款日和账期预算提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _timezoneReady = false;
  bool _timezoneDatabaseLoaded = false;

  bool get supported => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_initialized || !supported) {
      return;
    }
    await _ensureTimezone();
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
      ),
    );
    _initialized = true;
  }

  Future<void> _ensureTimezone() async {
    if (_timezoneReady) {
      return;
    }
    if (!_timezoneDatabaseLoaded) {
      // 保留 latest_all 的全部历史/别名数据，只改变包内存储形式。
      // scripts/prepare_timezone_asset.dart --check 保证解压后与锁定依赖逐字节相同。
      final data = await rootBundle.load('assets/timezone/latest_all.tzf.gz');
      final packed = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      tz.initializeDatabase(gzip.decode(packed));
      _timezoneDatabaseLoaded = true;
    }
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
      // 只有成功解析到本地时区才算就绪；否则保持未就绪以便下次 apply 重试。
      // 若在此把 _timezoneReady 置真，早期通道未就绪等瞬时失败会让 tz.local
      // 永久停在 UTC，导致提醒按 UTC 时刻触发（如 UTC+8 的 21:00 变成次日 05:00）。
      _timezoneReady = true;
    } catch (_) {
      // 拿不到本地时区时本次退回 UTC（仍可工作、时刻可能有偏差），但不置就绪，
      // 下次 apply（开屏/回前台/改配置）会再试一次拿正确时区。
    }
  }

  Future<bool> requestPermission() async {
    if (!supported) {
      return false;
    }
    await init();
    try {
      if (Platform.isAndroid) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await android?.requestNotificationsPermission();
        // 精确闹钟权限：Android 12 需用户在系统页授权；13+ 用 USE_EXACT_ALARM
        // 自动授予。失败/被拒不阻断——apply 会回退到 inexact 调度。
        try {
          await android?.requestExactAlarmsPermission();
        } catch (_) {
          // 忽略：无精确权限时回退 inexact。
        }
        return granted ?? true;
      }
      if (Platform.isIOS) {
        final ios = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final granted = await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return granted ?? false;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> apply(
    ReminderSettings settings, {
    AppLocalizations? l10n,
    List<CreditReminderSnapshot> financialReminders =
        const <CreditReminderSnapshot>[],
  }) async {
    if (!supported) {
      return;
    }
    await init();
    await cancel();
    if (settings.enabled) {
      final scheduled = _nextInstanceOf(settings.hour, settings.minute);
      final details = _details(l10n);
      // 优先精确闹钟（Doze 下也能准时触发、更可靠）；精确权限缺失会抛异常，则回退
      // inexact，至少仍有机会触发，不至于像以前那样彻底不响。
      final ok = await _scheduleDaily(
        scheduled,
        details,
        l10n,
        AndroidScheduleMode.exactAllowWhileIdle,
      );
      if (!ok) {
        await _scheduleDaily(
          scheduled,
          details,
          l10n,
          AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }
    if (settings.statementDateEnabled || settings.repaymentDueEnabled) {
      await _scheduleFinancialDates(settings, financialReminders, l10n: l10n);
    }
  }

  /// 安排每日重复提醒；返回 false 表示当前调度模式不可用，可由调用方降级重试。
  Future<bool> _scheduleDaily(
    tz.TZDateTime when,
    NotificationDetails details,
    AppLocalizations? l10n,
    AndroidScheduleMode mode,
  ) async {
    try {
      await _plugin.zonedSchedule(
        id: _reminderId,
        title: l10n?.reminderTitle ?? _channelName,
        body: l10n?.reminderNotifBody ?? '别忘了记录今天的收支～',
        scheduledDate: when,
        notificationDetails: details,
        androidScheduleMode: mode,
        matchDateTimeComponents: DateTimeComponents.time,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 按当前信用账户投影安排账单日和还款日的一次性通知。
  ///
  /// 每次同步前 [cancel] 会清掉旧排程，因此账户规则、正式账单或提前天数变化后不会
  /// 留下过时通知。只安排未来时刻：用户在触发日的设定时间之后才打开开关时，页面
  /// 仍会展示状态，但不会用“补发”制造每次回前台都重复的通知。
  Future<void> _scheduleFinancialDates(
    ReminderSettings settings,
    Iterable<CreditReminderSnapshot> reminders, {
    AppLocalizations? l10n,
  }) async {
    for (final reminder in reminders) {
      if (settings.statementDateEnabled && reminder.hasUpcomingStatementDebt) {
        final date = DateTime(
          reminder.overview.nextStatementDate.year,
          reminder.overview.nextStatementDate.month,
          reminder.overview.nextStatementDate.day - settings.advanceDays,
        );
        final when = _localDateTime(date, settings.hour, settings.minute);
        if (when.isAfter(tz.TZDateTime.now(tz.local))) {
          await _scheduleOneTime(
            id: _stableFinancialId('statement:${reminder.creditAccount.id}'),
            when: when,
            title: reminder.creditAccount.name,
            body: settings.advanceDays == 0
                ? l10n?.reminderStatementToday ?? '今天出账'
                : l10n?.reminderDaysUntilStatement(settings.advanceDays) ??
                      '${settings.advanceDays} 天后出账',
            l10n: l10n,
          );
        }
      }
      if (settings.repaymentDueEnabled && reminder.hasOutstandingStatement) {
        final date = DateTime(
          reminder.dueDate.year,
          reminder.dueDate.month,
          reminder.dueDate.day - settings.advanceDays,
        );
        final when = _localDateTime(date, settings.hour, settings.minute);
        if (when.isAfter(tz.TZDateTime.now(tz.local))) {
          final dueText = settings.advanceDays == 0
              ? l10n?.reminderDueToday ?? '今天到期'
              : l10n?.reminderDaysUntilDue(settings.advanceDays) ??
                    '${settings.advanceDays} 天后还款';
          final amount = formatUserMoney(
            reminder.dueOutstandingAmount!,
            reminder.creditAccount.currencyCode,
          );
          final outstanding =
              l10n?.reminderOutstandingAmount(amount) ?? '尚未还清 $amount';
          await _scheduleOneTime(
            id: _stableFinancialId('due:${reminder.creditAccount.id}'),
            when: when,
            title: reminder.creditAccount.name,
            body: '$dueText · $outstanding',
            l10n: l10n,
          );
        }
      }
    }
  }

  /// 安排一条一次性财务提醒；精确闹钟不可用时自动降级为非精确调度。
  Future<bool> _scheduleOneTime({
    required int id,
    required tz.TZDateTime when,
    required String title,
    required String body,
    AppLocalizations? l10n,
  }) async {
    Future<bool> schedule(AndroidScheduleMode mode) async {
      try {
        await _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: when,
          notificationDetails: _financialDetails(l10n),
          androidScheduleMode: mode,
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    if (await schedule(AndroidScheduleMode.exactAllowWhileIdle)) {
      return true;
    }
    return schedule(AndroidScheduleMode.inexactAllowWhileIdle);
  }

  /// 立即显示账期预算跨档提醒；返回 true 后 Controller 才可写入跨重启去重状态。
  Future<bool> showBudgetAlert(
    CreditReminderSnapshot reminder, {
    AppLocalizations? l10n,
  }) async {
    if (!supported || reminder.budgetAlertLevel == CycleBudgetAlertLevel.none) {
      return false;
    }
    await init();
    final budget = reminder.creditAccount.cycleBudget;
    final ratio = reminder.budgetUsageRatio;
    if (budget == null || ratio == null) {
      return false;
    }
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      try {
        if (await android?.areNotificationsEnabled() == false) {
          // 权限关闭时 `show` 可能仍正常返回但系统不会展示；此时不能提前写入去重状态，
          // 否则用户稍后授权也永远收不到本账期提醒。
          return false;
        }
      } catch (_) {
        // 某些旧系统不支持查询；继续尝试 show，由其实际异常决定是否标记送达。
      }
    }
    final body = switch (reminder.budgetAlertLevel) {
      CycleBudgetAlertLevel.warning =>
        l10n?.reminderBudgetWarning((ratio * 100).floor().clamp(0, 999)) ??
            '账期预算已使用 ${(ratio * 100).floor()}%',
      CycleBudgetAlertLevel.reached => l10n?.reminderBudgetReached ?? '账期预算已达到',
      CycleBudgetAlertLevel.exceeded =>
        l10n?.reminderBudgetExceeded(
              formatUserMoney(
                (reminder.overview.netSpending - budget).clamp(
                  0.0,
                  double.infinity,
                ),
                reminder.creditAccount.currencyCode,
              ),
            ) ??
            '账期预算已超出',
      CycleBudgetAlertLevel.none => '',
    };
    try {
      await _plugin.show(
        id: _stableFinancialId(
          'budget:${reminder.creditAccount.id}:${reminder.overview.cycle.end.toIso8601String()}:${reminder.budgetAlertLevel.name}',
        ),
        title: reminder.creditAccount.name,
        body: body,
        notificationDetails: _financialDetails(l10n),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  NotificationDetails _details(AppLocalizations? l10n) => NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      l10n?.reminderTitle ?? _channelName,
      channelDescription: l10n?.reminderChannelDesc ?? _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: const DarwinNotificationDetails(),
  );

  /// 信用账户财务提醒使用独立 Android 通知渠道，方便用户在系统设置中单独控制。
  NotificationDetails _financialDetails(AppLocalizations? l10n) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          _financialChannelId,
          l10n?.reminderFinancialChannelTitle ?? _financialChannelName,
          channelDescription:
              l10n?.reminderFinancialChannelDescription ??
              _financialChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      );

  /// 立即发一条测试通知：用于让用户当场确认「通知到底能不能显示」，把权限/渠道
  /// 问题与「定时不触发」问题区分开。
  Future<void> showTest({AppLocalizations? l10n}) async {
    if (!supported) {
      return;
    }
    await init();
    try {
      await _plugin.show(
        id: _testId,
        title: l10n?.reminderTitle ?? _channelName,
        body: l10n?.reminderTestBody ?? '这是一条测试通知——能看到它就说明通知功能正常。',
        notificationDetails: _details(l10n),
      );
    } catch (_) {
      // 显示失败（无权限等）静默处理。
    }
  }

  Future<void> cancel() async {
    if (!supported) {
      return;
    }
    try {
      // 当前插件实例只负责提醒；清空全部待触发项可同时移除已删除账户或旧规则留下的
      // 一次性通知，再由 [apply] 按最新投影完整重建。
      await _plugin.cancelAllPendingNotifications();
    } catch (_) {
      // 忽略取消失败。
    }
  }

  /// 计算下一次 hour:minute 的本地时区时刻（今天已过则顺延到明天）。
  ///
  /// 顺延按「日历日 +1」构造而非 `add(Duration(days: 1))`——[tz.TZDateTime] 的
  /// 加法同样是绝对 24 小时，跨夏令时切换会把提醒推到次日的 hour±1。
  tz.TZDateTime _nextInstanceOf(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    final scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (scheduled.isAfter(now)) {
      return scheduled;
    }
    return tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day + 1,
      hour,
      minute,
    );
  }

  /// 把普通日历日期与用户设定时刻组合成本地时区时间，避免按 UTC 错位。
  tz.TZDateTime _localDateTime(DateTime date, int hour, int minute) {
    return tz.TZDateTime(
      tz.local,
      date.year,
      date.month,
      date.day,
      hour,
      minute,
    );
  }

  /// 把通知业务键映射到 Android 允许的稳定正整数 id。
  ///
  /// 使用固定 FNV-1a 变体而非运行时 [String.hashCode]，保证进程重启后相同账户仍覆盖
  /// 同一条排程；保留 1–9999 给现有固定通知 id。
  int _stableFinancialId(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return 10000 + (hash % 2000000000);
  }
}
