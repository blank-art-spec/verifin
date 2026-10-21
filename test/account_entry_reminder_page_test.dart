import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/platform_bridge.dart';
import 'package:verifin/app/reminder/account_entry_reminder.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations_zh.dart';
import 'package:verifin/pages/account_entry_reminder_page.dart';

import 'support/test_harness.dart';
import 'support/account_reminder_harness.dart';

/// 长卡片可能大于视口；按目标的实际可点击位置滚动，避免只把整个卡片顶边滚入屏幕。
Future<void> _reveal(
  WidgetTester tester,
  Finder finder, {
  bool scrollUp = false,
}) async {
  for (var attempt = 0; attempt < 45; attempt++) {
    if (finder.hitTestable().evaluate().isNotEmpty) return;
    var delta = scrollUp ? 200.0 : -200.0;
    if (finder.evaluate().isNotEmpty && tester.getCenter(finder).dy < 0) {
      delta = 200;
    }
    await tester.drag(firstVerticalScrollable(), Offset(0, delta));
    await tester.pumpAndSettle();
  }
  expect(finder.hitTestable(), findsOneWidget);
}

/// 覆盖权限拒绝、运行检查、系统设置返回和原生桥结果。
/// 这些用例不能替代 Android 进程退出、锁屏与 release/R8 的实际闹钟验收。
void main() {
  useTestDatabases();
  const channel = MethodChannel('verifin/app');
  Map<String, Object?> deliveryState({String testState = 'pending'}) => {
    'notificationsEnabled': true,
    'channelEnabled': true,
    'exactAlarmsAllowed': true,
    'batteryExempt': false,
    'backgroundRestricted': false,
    'testState': testState,
  };

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('工作日切换只改草稿，显示年份与缺失策略，切回保留原星期', (tester) async {
    final controller = await makeReminderController();
    addTearDown(controller.dispose);
    final l10n = AppLocalizationsZh();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: AccountEntryReminderPage(account: controller.accounts.first),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('account_reminder_repeat_mode'));
    await _reveal(tester, mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.accountEntryReminderChinaWorkdays).last);
    await tester.pumpAndSettle();
    expect(find.byType(FilterChip), findsNothing);
    expect(
      find.text(l10n.accountEntryReminderCalendarCoverage('2026')),
      findsOneWidget,
    );
    expect(find.text(l10n.accountEntryReminderCalendarPause), findsOneWidget);
    expect(controller.accountEntryRemindersListenable.value, isEmpty);
    final policy = find.byKey(const Key('account_reminder_calendar_policy'));
    await _reveal(tester, policy);
    await tester.tap(policy);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.accountEntryReminderCalendarWeekdays).last);
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.accountEntryReminderCalendarWeekdays),
      findsOneWidget,
    );
    await _reveal(tester, mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.accountEntryReminderCustomWeekdays).last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .where((chip) => chip.selected)
          .length,
      5,
    );
    expect(controller.accountEntryRemindersListenable.value, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字工作日名称完整换行，保存关闭草稿无需选择星期或申请权限', (tester) async {
    tester.view.physicalSize = const Size(360, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await makeReminderController();
    addTearDown(controller.dispose);
    final account = controller.accounts.first;
    expect(
      await controller.saveAccountEntryReminder(
        AccountEntryReminder(
          id: '',
          accountId: account.id,
          bookId: account.bookId,
          currencyCode: account.currencyCode,
          weekdays: const [],
          repeatMode: AccountReminderRepeatMode.chinaWorkdays,
        ),
      ),
      isTrue,
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 852),
              textScaler: TextScaler.linear(1.5),
            ),
            child: AccountEntryReminderPage(account: account),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final mode = find.byKey(const Key('account_reminder_repeat_mode'));
    await _reveal(tester, mode);
    final label = tester.widget<Text>(
      find.descendant(
        of: mode,
        matching: find.text(
          AppLocalizationsZh().accountEntryReminderChinaWorkdays,
        ),
      ),
    );
    expect(label.maxLines, isNull);
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    final policy = find.byKey(const Key('account_reminder_calendar_policy'));
    await _reveal(tester, policy);
    await tester.tap(policy);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(AppLocalizationsZh().accountEntryReminderCalendarWeekdays).last,
    );
    await tester.pumpAndSettle();
    final save = find.byTooltip(AppLocalizationsZh().commonSave);
    await _reveal(tester, save, scrollUp: true);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      controller.accountEntryReminder(account.id)!.missingCalendarPolicy,
      MissingWorkdayCalendarPolicy.weekdays,
    );
    expect(controller.accountEntryReminder(account.id)!.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提醒未开启也能测试，权限拒绝不排程、不保存配置或记账', (tester) async {
    final controller = await makeReminderController();
    addTearDown(controller.dispose);
    final beforeEntries = controller.entries.length;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getAccountReminderDeliveryStatus') {
            return deliveryState();
          }
          return true;
        });
    // 桌面测试宿主的 NotificationScheduler 明确返回权限不可用，不能伪造发送成功。
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: AccountEntryReminderPage(account: controller.accounts.first),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('account_entry_reminder_test'));
    await _reveal(tester, button);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls.map((call) => call.method), [
      'getAccountReminderDeliveryStatus',
    ]);
    expect(controller.accountEntryRemindersListenable.value, isEmpty);
    expect(controller.entries.length, beforeEntries);
    expect(
      find.text(AppLocalizationsZh().reminderPermissionDenied),
      findsOneWidget,
    );
    expect(find.textContaining('系统已接受 1 分钟后的测试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字显示后台限制，设置只导航，返回后核对测试实际发布状态', (tester) async {
    tester.view.physicalSize = const Size(360, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var state = deliveryState();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'getAccountReminderDeliveryStatus'
              ? state
              : null;
        });
    final controller = await makeReminderController();
    addTearDown(controller.dispose);
    final beforeEntries = controller.entries.length;
    final l10n = AppLocalizationsZh();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: AccountEntryReminderPage(account: controller.accounts.first),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final background = find.byKey(
      const Key('account_reminder_background_settings'),
    );
    await _reveal(tester, background);
    expect(find.text(l10n.accountReminderBatteryManaged), findsOneWidget);
    await tester.tap(background);
    await tester.pumpAndSettle();
    expect(calls.last.method, 'openAccountReminderSettings');
    expect(calls.last.arguments, {'kind': 'background'});
    expect(find.text(l10n.accountReminderBatteryManaged), findsOneWidget);
    state = deliveryState(testState: 'posted')
      ..['batteryExempt'] = true
      ..['backgroundRestricted'] = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(l10n.accountReminderBackgroundRestricted), findsOneWidget);
    final status = find.byKey(const Key('account_reminder_test_status'));
    await _reveal(tester, status);
    expect(find.text(l10n.accountReminderTestPosted), findsOneWidget);
    expect(controller.entries.length, beforeEntries);
    expect(controller.accountEntryRemindersListenable.value, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桥准确区分精确与非精确排程，传输只含通知文案', (tester) async {
    var exact = true;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return exact;
        });
    for (final value in [true, false]) {
      exact = value;
      expect(
        await AppAccountReminderBridge.scheduleTest(
          title: '饭堂午餐 · 测试提醒',
          body: '测试不会记账',
          channelName: '账户记账提醒',
        ),
        value,
      );
    }
    expect(calls.length, 2);
    expect(calls.last.method, 'scheduleAccountEntryReminderTest');
    expect(calls.last.arguments, {
      'title': '饭堂午餐 · 测试提醒',
      'body': '测试不会记账',
      'channelName': '账户记账提醒',
    });
  });

  test('运行条件缺字段时不得把未知状态当成已授权', () {
    expect(
      () => AccountReminderDeliveryStatus.fromMap({'testState': 'posted'}),
      throwsFormatException,
    );
  });

  testWidgets('原生拒绝、缺少插件或无返回值均不得伪报排程成功', (tester) async {
    for (final failure in [
      PlatformException(code: 'ACCOUNT_REMINDER_FAILED', message: '通知渠道已关闭'),
      MissingPluginException('测试宿主没有 Android 闹钟'),
      null,
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (failure != null) throw failure;
            return null;
          });
      await expectLater(
        AppAccountReminderBridge.scheduleTest(
          title: '饭堂午餐 · 测试提醒',
          body: '测试不会记账',
          channelName: '账户记账提醒',
        ),
        throwsA(
          failure == null
              ? isA<StateError>()
              : failure is MissingPluginException
              ? isA<MissingPluginException>()
              : isA<PlatformException>(),
        ),
      );
    }
  });
}
