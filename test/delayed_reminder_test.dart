import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/reminder/notification_scheduler.dart';
import 'package:verifin/app/reminder/reminder_settings.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations_zh.dart';
import 'package:verifin/pages/reminder_settings_page.dart';

import 'support/test_harness.dart';

/// 桌面测试宿主不申请实际系统权限；保留真实排程逻辑，通过模拟 Android 通道检查请求。
class _TestScheduler extends NotificationScheduler {
  @override
  bool get supported => true;

  /// 无需访问设备时区或载入原生插件；测试直接使用 UTC 排程。
  @override
  Future<void> init() async {}

  /// 模拟用户允许应用发送通知，后续排程结果仍由通道独立决定。
  @override
  Future<bool> requestPermission() async => true;
}

/// 验证用户的延时测试请求，以及它与应用回前台刷新正式提醒之间的隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final l10n = AppLocalizationsZh();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('延时测试使用账单渠道，重复排程后回前台仍保留最后一条', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final pending = <int, Map<Object?, Object?>>{
      1001: {'id': 1001},
      10000: {'id': 10000},
    };
    final requests = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getNotificationChannels':
          return [];
        case 'zonedSchedule':
          final request = call.arguments as Map<Object?, Object?>;
          requests.add(request);
          pending[request['id'] as int] = request;
        case 'pendingNotificationRequests':
          return pending.values.toList();
        case 'cancel':
          final args = call.arguments as Map<Object?, Object?>;
          pending.remove(args['id']);
        default:
          fail('意外的通知请求：${call.method}');
      }
      return null;
    });

    final scheduler = _TestScheduler();
    final before = DateTime.now().toUtc();
    expect(await scheduler.scheduleDelayedTest(l10n: l10n), isTrue);
    expect(await scheduler.scheduleDelayedTest(l10n: l10n), isTrue);
    final after = DateTime.now().toUtc();
    final request = requests.last;
    final when = DateTime.parse(request['scheduledDateTimeISO8601'] as String);
    expect(
      when.microsecondsSinceEpoch,
      inInclusiveRange(
        before.add(const Duration(minutes: 1)).microsecondsSinceEpoch,
        after.add(const Duration(minutes: 1)).microsecondsSinceEpoch,
      ),
    );
    expect(request['title'], l10n.reminderDelayedTestTitle);
    expect(
      request['platformSpecifics'],
      containsPair('channelId', 'verifin_financial_reminder'),
    );
    expect(request, isNot(contains('matchDateTimeComponents')));
    expect(
      pending.values,
      unorderedEquals([
        {'id': 1001},
        {'id': 10000},
        request,
      ]),
    );

    // 应用根组件使用自己的服务实例同步，这里也用另一个实例模拟回到前台。
    await _TestScheduler().apply(const ReminderSettings());
    expect(pending.values, [request]);
  });

  for (final fallbackSucceeds in [true, false]) {
    testWidgets(
      fallbackSucceeds ? '正式提醒关闭时可测试，非精确排程提示可能延迟' : '两种排程均失败时不会显示已安排',
      (tester) async {
        final modes = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getNotificationChannels':
              return [];
            case 'zonedSchedule':
              final args = call.arguments as Map<Object?, Object?>;
              final details =
                  args['platformSpecifics'] as Map<Object?, Object?>;
              modes.add(details['scheduleMode'] as String);
              if (modes.length == 1 || !fallbackSucceeds) {
                throw PlatformException(code: 'schedule_rejected');
              }
            default:
              fail('意外的通知请求：${call.method}');
          }
          return null;
        });
        final controller = await makeController();
        final settings = controller.reminderSettings;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          VeriFinScope(
            controller: controller,
            child: zhMaterialApp(
              home: ReminderSettingsPage(scheduler: _TestScheduler()),
            ),
          ),
        );
        final delayed = find.text(l10n.reminderDelayedTestButton);
        await tester.scrollUntilVisible(delayed, 120);
        expect(find.text(l10n.reminderTestButton), findsOneWidget);
        await tester.tap(delayed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(modes, ['exactAllowWhileIdle', 'inexactAllowWhileIdle']);
        expect(find.text(l10n.reminderDelayedTestScheduled), findsNothing);
        expect(
          find.text(
            fallbackSucceeds
                ? l10n.reminderDelayedTestInexact
                : l10n.reminderDelayedTestFailed,
          ),
          findsOneWidget,
        );
        expect(controller.reminderSettings, settings);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
