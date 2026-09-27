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
