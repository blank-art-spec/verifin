import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/platform_bridge.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations_zh.dart';
import 'package:verifin/pages/account_entry_reminder_page.dart';

import 'support/test_harness.dart';

/// 覆盖测试按钮的权限拒绝和原生桥结果；按用户要求保留为手动执行的回归用例。
/// 这些用例不能替代 Android 进程退出、锁屏与 release/R8 的实际闹钟验收。
void main() {
  useTestDatabases();
  const channel = MethodChannel('verifin/app');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('提醒未开启也能测试，权限拒绝不排程、不保存配置或记账', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final beforeEntries = controller.entries.length;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
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
    await tester.scrollUntilVisible(button, 200);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(controller.accountEntryRemindersListenable.value, isEmpty);
    expect(controller.entries.length, beforeEntries);
    expect(
      find.text(AppLocalizationsZh().reminderPermissionDenied),
      findsOneWidget,
    );
    expect(find.textContaining('已安排 1 分钟后提醒'), findsNothing);
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
