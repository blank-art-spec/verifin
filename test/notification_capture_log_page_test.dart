import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/auto_capture_page.dart';
import 'package:verifin/pages/notification_capture_log_page.dart';

import 'support/test_harness.dart';

const _channel = MethodChannel('verifin/app');

Map<String, Object?> _entry(
  String id, {
  String outcome = 'queued',
  String text = '掌上生活通知\n消费 USD 9.25\n卡尾号 1234',
}) {
  final time = DateTime(2026, 10, 26, 10).millisecondsSinceEpoch;
  return {
    'id': id,
    'recordedAt': time,
    'occurredAt': time - 1000,
    'sourceId': 'com.cmbchina.ccd.pluto',
    'sourceLabel': '掌上生活',
    'sourceEventId': 'event-$id',
    'textExtraction': 'success',
    'financialFilter': outcome == 'financialRejected' ? 'rejected' : 'passed',
    'queueResult': outcome == 'financialRejected' ? 'notRun' : 'enqueued',
    'outcome': outcome,
    'rawText': text,
  };
}

Map<String, Object?> _batch(
  List<Map<String, Object?>> entries, {
  String? next,
}) => {'entries': entries, 'hasMore': next != null, 'nextBeforeId': next};

Future<VeriFinController> _pumpPage(
  WidgetTester tester, {
  Widget page = const NotificationCaptureLogPage(),
}) async {
  final controller = await makeController();
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTestDatabases();

  late Future<Object?> Function(MethodCall call) read;
  late Future<Object?> Function() clear;
  var clearCalls = 0;

  setUp(() {
    clearCalls = 0;
    read = (_) async => _batch([]);
    clear = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'readNotificationCaptureLogs') return read(call);
          if (call.method == 'setAutoCaptureConfig') return true;
          if (call.method == 'resetNotificationCaptureLogs') {
            return clear();
          }
          if (call.method == 'clearNotificationCaptureLogs') {
            clearCalls++;
            return clear();
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('自动采集页提供通知捕获日志入口', (tester) async {
    await _pumpPage(tester, page: const AutoCapturePage());
    final entry = find.byKey(const Key('notification_capture_log_entry'));
    await tester.scrollUntilVisible(
      entry,
      160,
      scrollable: firstVerticalScrollable(),
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(NotificationCaptureLogPage), findsOneWidget);
    expect(find.text('最近 7 天暂无捕获日志'), findsOneWidget);
  });

  testWidgets('日志详情可显示并选择三行以后的完整通知原文', (tester) async {
    const text = '第一行\n第二行\n第三行\n第四行\n完整通知末尾 USD 9.25';
    read = (_) async => _batch([_entry('30', text: text)]);
    await _pumpPage(tester);

    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byKey(const ValueKey('notification_log_detail_30')));
    await tester.pumpAndSettle();

    final body = tester.widget<SelectableText>(
      find.byKey(const ValueKey('notification_log_body_30')),
    );
    expect(body.data, text);
    expect(body.maxLines, isNull);
    // 使用本地化日期/时间，具体标点和12/24小时制由宿主决定。
    expect(find.textContaining('通知时间'), findsOneWidget);
  });

  testWidgets('过滤通知仅显示状态，不暴露桥接返回的正文', (tester) async {
    read = (_) async =>
        _batch([_entry('30', outcome: 'financialRejected', text: '不应显示的私密正文')]);
    await _pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('notification_log_detail_30')));
    await tester.pumpAndSettle();

    expect(find.text('缺少数字或交易关键词'), findsOneWidget);
    expect(find.text('不应显示的私密正文'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text('此结果未保留通知正文，仅记录处理状态。'), findsOneWidget);
  });

  testWidgets('读取失败不会假装为空，重试后展示日志', (tester) async {
    var fail = true;
    read = (_) async => fail ? null : _batch([_entry('30')]);
    await _pumpPage(tester);

    expect(find.text('无法读取通知捕获日志，请重试。'), findsOneWidget);
    expect(find.text('最近 7 天暂无捕获日志'), findsNothing);
    fail = false;
    await tester.tap(find.byKey(const Key('notification_log_retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notification_log_30')), findsOneWidget);
    expect(find.text('无法读取通知捕获日志，请重试。'), findsNothing);
  });

  testWidgets('分页去重，错误的非前进游标不会无限加载', (tester) async {
    read = (call) async {
      final args = call.arguments as Map<dynamic, dynamic>;
      return args['beforeId'] == null
          ? _batch([_entry('30')], next: '30')
          : _batch([_entry('30'), _entry('29')], next: '30');
    };
    await _pumpPage(tester);
    await tester.ensureVisible(find.byKey(const Key('notification_log_more')));
    await tester.tap(find.byKey(const Key('notification_log_more')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notification_log_30')), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_log_29')), findsOneWidget);
    expect(find.byKey(const Key('notification_log_more')), findsNothing);
  });

  testWidgets('刷新后迟到的分页结果不会重新加入旧日志', (tester) async {
    final older = Completer<Object?>();
    var refreshed = false;
    read = (call) async {
      final args = call.arguments as Map<dynamic, dynamic>;
      if (args['beforeId'] != null) return older.future;
      return refreshed
          ? _batch([_entry('50')])
          : _batch([_entry('30')], next: '30');
    };
    await _pumpPage(tester);
    await tester.ensureVisible(find.byKey(const Key('notification_log_more')));
    await tester.tap(find.byKey(const Key('notification_log_more')));
    await tester.pump();
    refreshed = true;
    await tester.ensureVisible(
      find.byKey(const Key('notification_log_refresh')),
    );
    await tester.tap(find.byKey(const Key('notification_log_refresh')));
    await tester.pumpAndSettle();
    older.complete(_batch([_entry('20')]));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('notification_log_50')), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_log_20')), findsNothing);
    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
  });

  testWidgets('清空须确认，失败保留列表，成功后清空且不影响账本', (tester) async {
    read = (_) async => _batch([_entry('30')]);
    var saved = false;
    clear = () async => saved;
    final controller = await _pumpPage(tester);
    final entriesBefore = controller.entries.length;

    await tester.tap(find.byKey(const Key('notification_log_clear')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除待确认事件'), findsOneWidget);
    expect(clearCalls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(clearCalls, 0);

    await tester.tap(find.byKey(const Key('notification_log_clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    expect(clearCalls, 1);
    expect(find.byKey(const ValueKey('notification_log_30')), findsOneWidget);
    expect(find.text('清空失败，日志仍保留，请重试。'), findsOneWidget);
    await tester.pumpAndSettle();

    saved = true;
    await tester.tap(find.byKey(const Key('notification_log_clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(clearCalls, 2);
    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
    expect(find.text('最近 7 天暂无捕获日志'), findsOneWidget);
    expect(controller.entries.length, entriesBefore);
  });

  testWidgets('清空后迟到的分页结果不会恢复已删除日志', (tester) async {
    final older = Completer<Object?>();
    read = (call) async {
      final args = call.arguments as Map<dynamic, dynamic>;
      return args['beforeId'] == null
          ? _batch([_entry('30')], next: '30')
          : older.future;
    };
    await _pumpPage(tester);
    await tester.ensureVisible(find.byKey(const Key('notification_log_more')));
    await tester.tap(find.byKey(const Key('notification_log_more')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('notification_log_clear')));
    await tester.tap(find.byKey(const Key('notification_log_clear')));
    // 分页仍在等待时会显示进度动画，只推进确认框动画而不等待全部动画停止。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    older.complete(_batch([_entry('20')]));
    await tester.pumpAndSettle();

    expect(find.text('最近 7 天暂无捕获日志'), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_log_20')), findsNothing);
  });

  testWidgets('初始化立即清除页面缓存和展开正文，并等待原生日志清理', (tester) async {
    final cleanup = Completer<Object?>();
    var reads = 0;
    read = (_) async {
      reads++;
      return reads == 1 ? _batch([_entry('30')]) : _batch([]);
    };
    clear = () => cleanup.future;
    final controller = await _pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('notification_log_detail_30')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notification_log_body_30')),
      findsOneWidget,
    );

    controller.resetAllData();
    await tester.pump();

    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(reads, 1);
    // 原生清理仍在等待时，不发起可能重新读取旧数据库的刷新。
    await tester.tap(find.byKey(const Key('notification_log_refresh')));
    await tester.pump();
    expect(reads, 1);

    cleanup.complete(true);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('最近 7 天暂无捕获日志'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    await controller.waitForPendingWrites();
  });

  testWidgets('初始化之后旧刷新结果不能恢复缓存正文', (tester) async {
    final stale = Completer<Object?>();
    var reads = 0;
    read = (_) async {
      reads++;
      if (reads == 1) return _batch([_entry('30')]);
      if (reads == 2) return stale.future;
      return _batch([]);
    };
    final controller = await _pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('notification_log_detail_30')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notification_log_body_30')),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const Key('notification_log_refresh')),
    );
    await tester.tap(find.byKey(const Key('notification_log_refresh')));
    await tester.pump();

    controller.resetAllData();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
    expect(find.byType(SelectableText), findsNothing);

    stale.complete(_batch([_entry('30', text: '初始化前的私密通知原文')]));
    await tester.pumpAndSettle();
    expect(find.text('初始化前的私密通知原文'), findsNothing);
    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
    expect(find.text('最近 7 天暂无捕获日志'), findsOneWidget);
    await controller.waitForPendingWrites();
  });

  testWidgets('初始化尚未清理完成时首次打开日志页也等待写入屏障', (tester) async {
    final cleanup = Completer<void>();
    var cleared = false;
    var reads = 0;
    clear = () async {
      await cleanup.future;
      cleared = true;
      return true;
    };
    read = (_) async {
      reads++;
      return cleared ? _batch([]) : _batch([_entry('30', text: '初始化之前的旧通知正文')]);
    };
    final controller = await makeController();
    addTearDown(controller.dispose);
    controller.resetAllData();

    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const NotificationCaptureLogPage()),
      ),
    );
    await tester.pump();
    expect(reads, 0);
    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
    expect(find.text('初始化之前的旧通知正文'), findsNothing);

    cleanup.complete();
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('最近 7 天暂无捕获日志'), findsOneWidget);
    expect(find.byKey(const ValueKey('notification_log_30')), findsNothing);
    await controller.waitForPendingWrites();
  });
}
