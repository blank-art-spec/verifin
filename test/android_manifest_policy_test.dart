import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('正式 Manifest 明确禁用 Android 系统备份', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
  });

  test('桌面只注册固定模板小组件，不注册用户自定义 Provider', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, isNot(contains('android:name=".UserWidgetProvider"')));
    expect(
      manifest,
      isNot(contains('android:name=".UserWidgetConfigureActivity"')),
    );
    expect(manifest, contains('android:name=".QuickEntryWidgetProvider"'));
    expect(manifest, contains('android:name=".BudgetWidgetProvider"'));
    expect(manifest, contains('android:name=".NetWorthWidgetProvider"'));
    expect(manifest, contains('android:name=".TrendWidgetProvider"'));
  });

  test('GitHub 渠道声明通知监听和仅接收新短信所需能力', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android.permission.RECEIVE_SMS'));
    expect(manifest, isNot(contains('android.permission.READ_SMS')));
    expect(
      manifest,
      contains('android:name=".PaymentNotificationListenerService"'),
    );
    expect(manifest, contains('android:name=".SmsCaptureReceiver"'));
    expect(
      manifest,
      contains('android.permission.BIND_NOTIFICATION_LISTENER_SERVICE'),
    );
    expect(manifest, contains('android:stopWithTask="false"'));
  });

  test('通知监听覆盖扩展正文、连接重绑和阶段诊断', () {
    final listener = File(
      'android/app/src/main/kotlin/top/talyra42/verifin/'
      'PaymentNotificationListenerService.kt',
    ).readAsStringSync();
    final bridge = File(
      'android/app/src/main/kotlin/top/talyra42/verifin/AutoCaptureBridge.kt',
    ).readAsStringSync();

    expect(listener, contains('override fun onListenerConnected()'));
    expect(listener, contains('override fun onListenerDisconnected()'));
    expect(listener, contains('requestRebind('));
    expect(listener, contains('activeNotifications'));
    expect(listener, contains('Notification.EXTRA_TEXT_LINES'));
    expect(listener, contains('Notification.EXTRA_SUB_TEXT'));
    expect(listener, contains('Notification.EXTRA_SUMMARY_TEXT'));
    expect(listener, contains('Notification.EXTRA_MESSAGES'));
    expect(listener, contains('notification.tickerText'));
    expect(bridge, contains('recordNotificationDiagnostic'));
    expect(bridge, contains('notificationListenerConnected'));
    expect(bridge, contains('return editor.commit()'));
  });

  test('Play 渠道显式移除短信权限和接收器', () {
    final manifest = File(
      'android/app/src/play/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:name="android.permission.RECEIVE_SMS"'));
    expect(manifest, contains('tools:node="remove"'));
    expect(manifest, contains('android:name=".SmsCaptureReceiver"'));
  });
}
