import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/platform_bridge.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/auto_capture_page.dart';

import 'support/test_harness.dart';

const MethodChannel _channel = MethodChannel('verifin/app');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTestDatabases();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('同步自动采集配置时完整传递开关并返回原生提交结果', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          received = call;
          return true;
        });

    const settings = AutoCaptureSettings(
      notificationEnabled: true,
      smsEnabled: true,
      listenAllNotificationSources: true,
      sourcePackages: <String>['com.example.bank'],
    );
    final saved = await AppAutoCaptureBridge.syncConfig(settings);

    expect(saved, isTrue);
    expect(received?.method, 'setAutoCaptureConfig');
    expect(received?.arguments, <String, Object?>{
      'notificationEnabled': true,
      'smsEnabled': true,
      'listenAll': true,
      'packages': <String>['com.example.bank'],
    });
  });

  test('原生诊断区分系统授权、服务连接、原生开关与最近通知阶段', () async {
    final occurredAt = DateTime(2026, 9, 30, 9, 29, 3);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          expect(call.method, 'getAutoCaptureDiagnostics');
          return <String, Object?>{
            'available': true,
            'notificationAccessGranted': true,
            'listenerConnected': false,
            'nativeNotificationEnabled': true,
            'nativeListenAll': true,
            'pendingQueueCount': 1,
            'listenerConnectedAt': occurredAt
                .subtract(const Duration(minutes: 2))
                .millisecondsSinceEpoch,
            'listenerDisconnectedAt': occurredAt
                .subtract(const Duration(minutes: 1))
                .millisecondsSinceEpoch,
            'lastNotification': <String, Object?>{
              'occurredAt': occurredAt.millisecondsSinceEpoch,
              'sourceId': 'cmb.pb',
              'sourceLabel': '招商银行',
              'textExtraction': 'success',
              'financialFilter': 'passed',
              'queueResult': 'enqueued',
              'outcome': 'queued',
            },
          };
        });

    final diagnostics = await AppAutoCaptureBridge.diagnostics();

    expect(diagnostics.available, isTrue);
    expect(diagnostics.notificationAccessGranted, isTrue);
    expect(diagnostics.listenerConnected, isFalse);
    expect(diagnostics.nativeNotificationEnabled, isTrue);
    expect(diagnostics.nativeListenAll, isTrue);
    expect(diagnostics.pendingQueueCount, 1);
    expect(diagnostics.lastNotification?.sourceLabel, '招商银行');
    expect(diagnostics.lastNotification?.textExtraction, 'success');
    expect(diagnostics.lastNotification?.financialFilter, 'passed');
    expect(diagnostics.lastNotification?.queueResult, 'enqueued');
    expect(diagnostics.lastNotification?.occurredAt, occurredAt);
  });

  test('原生诊断不可用时安全回落，不把缺失插件误报成已连接', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          throw PlatformException(code: 'UNAVAILABLE');
        });

    final diagnostics = await AppAutoCaptureBridge.diagnostics();

    expect(diagnostics.available, isFalse);
    expect(diagnostics.listenerConnected, isFalse);
    expect(diagnostics.lastNotification, isNull);
  });

  testWidgets('自动识别页显示授权、实际连接和最近通知各阶段', (tester) async {
    final occurredAt = DateTime(2026, 9, 30, 9, 29, 3);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          return switch (call.method) {
            'setAutoCaptureConfig' => true,
            'isNotificationListenerEnabled' => true,
            'isSmsCaptureSupported' => true,
            'isSmsPermissionGranted' => false,
            'getAutoCaptureDiagnostics' => <String, Object?>{
              'available': true,
              'notificationAccessGranted': true,
              'listenerConnected': true,
              'nativeNotificationEnabled': true,
              'nativeListenAll': true,
              'pendingQueueCount': 1,
              'lastNotification': <String, Object?>{
                'occurredAt': occurredAt.millisecondsSinceEpoch,
                'sourceId': 'cmb.pb',
                'sourceLabel': '招商银行',
                'textExtraction': 'success',
                'financialFilter': 'passed',
                'queueResult': 'enqueued',
                'outcome': 'queued',
              },
            },
            _ => null,
          };
        });
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.saveAutoCaptureSettingsDraft(
      const AutoCaptureSettings(
        notificationEnabled: true,
        listenAllNotificationSources: true,
      ),
    );

    await tester.pumpWidget(
      zhMaterialApp(
        home: VeriFinScope(
          controller: controller,
          child: const AutoCapturePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('采集诊断'), findsOneWidget);
    expect(find.text('已授权'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.textContaining('招商银行 ·'), findsOneWidget);
    expect(find.text('正文提取'), findsOneWidget);
    expect(find.text('金融过滤'), findsOneWidget);
    expect(find.text('入队结果'), findsOneWidget);
    expect(find.text('已写入原生队列'), findsOneWidget);
    expect(find.text('尝试重连'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
