import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/platform_bridge.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

const _channel = MethodChannel('verifin/app');
const _time = 1792944000000;

Map<String, Object?> _row(
  String id, {
  String outcome = 'queued',
  String financialFilter = 'passed',
  String rawText = '信用卡尾号1234消费USD 12.34',
  String textCompleteness = 'captured',
}) => <String, Object?>{
  'id': id,
  'recordedAt': _time,
  'occurredAt': _time - 3000,
  'sourceId': 'com.example.bank',
  'sourceLabel': '银行',
  'sourceEventId': 'event-$id',
  'textExtraction': 'success',
  'financialFilter': financialFilter,
  'queueResult': switch (outcome) {
    'financialRejected' || 'textUnavailable' => 'notRun',
    'duplicate' => 'duplicate',
    'queueWriteFailed' => 'writeFailed',
    _ => 'enqueued',
  },
  'outcome': outcome,
  'rawText': rawText,
  'textCompleteness': textCompleteness,
};

class _FailingRuleWriteRepository extends InMemoryLedgerRepository {
  bool failRuleWrites = false;

  @override
  Future<void> saveAutoCaptureRules(List<AutoCaptureRule> rules) async {
    if (failRuleWrites) throw StateError('isolated rule write failure');
    await super.saveAutoCaptureRules(rules);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useTestDatabases();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('日志保留捕获与通知两个时间，不把缺失字段伪造成当前时间', () {
    final entry = NotificationCaptureLogEntry.fromMap(_row('19'))!;
    expect(entry.id, '19');
    expect(entry.recordedAt.millisecondsSinceEpoch, _time);
    expect(entry.occurredAt.millisecondsSinceEpoch, _time - 3000);
    expect(entry.sourceEventId, 'event-19');
    expect(entry.rawText, contains('USD 12.34'));
    for (final invalid in <Map<String, Object?>>[
      <String, Object?>{..._row('19'), 'id': 'bad'},
      <String, Object?>{..._row('19'), 'id': '0'},
      <String, Object?>{..._row('19'), 'recordedAt': null},
      <String, Object?>{..._row('19'), 'recordedAt': 'yesterday'},
      <String, Object?>{..._row('19'), 'occurredAt': -1},
      <String, Object?>{..._row('19'), 'occurredAt': 9000000000000000},
    ]) {
      expect(NotificationCaptureLogEntry.fromMap(invalid), isNull);
    }
  });

  test('来源拦截、关闭和异常结果仍不暴露正文', () {
    for (final outcome in <String>[
      'sourceBlocked',
      'nativeDisabled',
      'unknownFutureOutcome',
    ]) {
      final entry = NotificationCaptureLogEntry.fromMap(
        _row('1', outcome: outcome),
      )!;
      expect(entry.rawText, isEmpty, reason: outcome);
      expect(entry.sourceEventId, isEmpty, reason: outcome);
      expect(entry.textCompleteness, 'notStored', reason: outcome);
    }
    for (final invalid in <Map<String, Object?>>[
      _row('1', financialFilter: 'rejected'),
      <String, Object?>{..._row('1'), 'sourceId': ''},
      <String, Object?>{..._row('1'), 'textExtraction': 'failed'},
      _row('1', textCompleteness: 'notStored'),
      _row('1', textCompleteness: 'unavailable'),
    ]) {
      expect(NotificationCaptureLogEntry.fromMap(invalid)!.rawText, isEmpty);
    }
  });

  test('日志文字独立于金融筛选或识别正文提取结果', () {
    final rejected = NotificationCaptureLogEntry.fromMap(
      _row(
        '1',
        outcome: 'financialRejected',
        financialFilter: 'rejected',
        rawText: '完整的来源通知文字',
      ),
    )!;
    expect(rejected.rawText, '完整的来源通知文字');
    expect(rejected.textCompleteness, 'captured');
    expect(rejected.outcome, 'financialRejected');
    expect(rejected.queueResult, 'notRun');
    final unavailable = NotificationCaptureLogEntry.fromMap(<String, Object?>{
      ..._row(
        '2',
        outcome: 'textUnavailable',
        financialFilter: 'notRun',
        rawText: '日志独立提取到的可见文字',
      ),
      'textExtraction': 'failed',
    })!;
    expect(unavailable.rawText, '日志独立提取到的可见文字');
    expect(unavailable.textExtraction, 'failed');
    expect(unavailable.queueResult, 'notRun');
  });

  test('完整日志不再被旧8000字符边界截断，超出65536时明确标记部分内容', () {
    final body = '${List<String>.filled(9000, '字').join()}通知原文末尾';
    final full = NotificationCaptureLogEntry.fromMap(
      _row('1', outcome: 'queueWriteFailed', rawText: body),
    )!;
    expect(full.rawText, body);
    expect(full.textCompleteness, 'captured');
    final boundary = List<String>.filled(65536, '字').join();
    expect(
      NotificationCaptureLogEntry.fromMap(
        _row('2', rawText: boundary),
      )!.textCompleteness,
      'captured',
    );
    final truncated = NotificationCaptureLogEntry.fromMap(
      _row('3', rawText: '$boundary超出'),
    )!;
    expect(truncated.rawText, boundary);
    expect(truncated.textCompleteness, 'partial');
  });

  test('日志截断不切断跨越65536边界的emoji代理对', () {
    final prefix = List<String>.filled(65535, '字').join();
    final truncated = NotificationCaptureLogEntry.fromMap(
      _row('1', rawText: '$prefix😀末尾'),
    )!;
    expect(truncated.rawText, prefix);
    expect(truncated.textCompleteness, 'partial');
    final exact = '${List<String>.filled(65534, '字').join()}😀';
    final complete = NotificationCaptureLogEntry.fromMap(
      _row('2', rawText: exact),
    )!;
    expect(complete.rawText, exact);
    expect(complete.rawText.length, 65536);
    expect(complete.textCompleteness, 'captured');
  });
  test('旧桥或未知完整性保持未知，部分内容和无文字状态不伪装成完整', () {
    final legacy = _row('1')..remove('textCompleteness');
    expect(
      NotificationCaptureLogEntry.fromMap(legacy)!.textCompleteness,
      'legacy',
    );
    expect(
      NotificationCaptureLogEntry.fromMap(
        _row('2', textCompleteness: 'futureState'),
      )!.textCompleteness,
      'legacy',
    );
    expect(
      NotificationCaptureLogEntry.fromMap(
        _row('3', textCompleteness: 'partial'),
      )!.textCompleteness,
      'partial',
    );
    final unavailable = NotificationCaptureLogEntry.fromMap(
      _row('4', textCompleteness: 'unavailable'),
    )!;
    expect(unavailable.rawText, isEmpty);
    expect(unavailable.textCompleteness, 'unavailable');
  });
  test('分页结果跳过坏行并去重，无有效数据时不制造无限加载游标', () {
    final batch = NotificationCaptureLogBatch.fromMap(<String, Object?>{
      'entries': <Object?>[
        _row('3'),
        _row('3'),
        'invalid',
        _row('2'),
        _row('0'),
      ],
      'hasMore': true,
      'nextBeforeId': '2',
    });
    expect(batch.entries.map((entry) => entry.id), <String>['3', '2']);
    expect(batch.hasMore, isTrue);
    expect(batch.nextBeforeId, '2');
    expect(() => batch.entries.clear(), throwsUnsupportedError);
    final invalid = NotificationCaptureLogBatch.fromMap(<String, Object?>{
      'entries': <Object?>[_row('0')],
      'hasMore': true,
      'nextBeforeId': '0',
    });
    expect(invalid.entries, isEmpty);
    expect(invalid.hasMore, isFalse);
    expect(invalid.nextBeforeId, isNull);
  });

  test('读取传递稳定游标并限制每页数量，清空只调用专用原生日志接口', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'clearNotificationCaptureLogs') return true;
          return <String, Object?>{
            'entries': <Object?>[_row('12')],
            'hasMore': true,
            'nextBeforeId': '12',
          };
        });
    final batch = await AppAutoCaptureBridge.notificationLogs(
      beforeId: '13',
      limit: 500,
    );
    expect(batch!.entries.single.sourceLabel, '银行');
    expect(calls.first.method, 'readNotificationCaptureLogs');
    expect(calls.first.arguments, <String, Object?>{
      'beforeId': '13',
      'limit': 100,
    });
    expect(await AppAutoCaptureBridge.clearNotificationLogs(), isTrue);
    expect(calls.last.method, 'clearNotificationCaptureLogs');
    expect(calls.length, 2);
  });

  test('读取失败与空日志不同，旧桥和删除失败不被报告为成功', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'readNotificationCaptureLogs') {
            return <String, Object?>{'entries': <Object?>[], 'hasMore': false};
          }
          return false;
        });
    expect((await AppAutoCaptureBridge.notificationLogs())!.entries, isEmpty);
    expect(await AppAutoCaptureBridge.clearNotificationLogs(), isFalse);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          throw PlatformException(code: 'SQLITE_READ_FAILED');
        });
    expect(await AppAutoCaptureBridge.notificationLogs(), isNull);
    expect(await AppAutoCaptureBridge.clearNotificationLogs(), isFalse);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    expect(await AppAutoCaptureBridge.notificationLogs(), isNull);
    expect(await AppAutoCaptureBridge.clearNotificationLogs(), isFalse);
    await AppAutoCaptureBridge.resetNotificationLogsAfterDataReset();
  });

  test('控制器清空捕获日志不删除待确认事件、配置或账目', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.ingestCaptureInputs(<RawCaptureInput>[
      RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'bank',
        sourceEventId: 'event-retained',
        rawText: '消费USD 12.34',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(_time),
      ),
    ]);
    final eventId = controller.captureEvents.single.id;
    final entries = controller.entries.map((entry) => entry.id).toList();
    final settings = controller.autoCaptureSettings;
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          methods.add(call.method);
          return true;
        });
    expect(await controller.clearNotificationCaptureLogs(), isTrue);
    expect(controller.captureEvents.single.id, eventId);
    expect(controller.entries.map((entry) => entry.id), entries);
    expect(controller.autoCaptureSettings, same(settings));
    expect(methods, <String>['clearNotificationCaptureLogs']);
  });

  test('显式初始化数据会请求原生清除日志，实际清理失败会上报', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          methods.add(call.method);
          return true;
        });
    final controller = await makeController();
    addTearDown(controller.dispose);
    controller.resetAllData();
    await controller.waitForPendingWrites();
    expect(methods, contains('resetNotificationCaptureLogs'));

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => false);
    await expectLater(
      AppAutoCaptureBridge.resetNotificationLogsAfterDataReset(),
      throwsA(isA<PlatformException>()),
    );
  });
  test('初始化等待日志清理完成，后台刷盘也不能提前结束', () async {
    final cleanup = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'resetNotificationCaptureLogs') {
            return cleanup.future;
          }
          return null;
        });
    final controller = await makeController();
    addTearDown(controller.dispose);
    controller.resetAllData();
    var waitFinished = false;
    var flushFinished = false;
    final waiting = controller.waitForPendingWritesSucceeded().then((value) {
      waitFinished = true;
      return value;
    });
    final flushing = controller.flushPendingWrites().then((_) {
      flushFinished = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(waitFinished, isFalse);
    expect(flushFinished, isFalse);
    cleanup.complete(true);
    expect(await waiting, isTrue);
    await flushing;
    expect(flushFinished, isTrue);
  });

  test('原生日志清理失败计入初始化失败，并走统一错误反馈', () async {
    final cleanup = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'resetNotificationCaptureLogs') {
            return cleanup.future;
          }
          return null;
        });
    final controller = await makeController();
    addTearDown(controller.dispose);
    final errors = <Object>[];
    controller.onPersistError = errors.add;
    controller.resetAllData();
    final waiting = controller.waitForPendingWritesSucceeded();
    cleanup.complete(false);
    expect(await waiting, isFalse);
    expect(errors, hasLength(1));
    expect(errors.single, isA<PlatformException>());

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async => null);
    await expectLater(
      AppAutoCaptureBridge.resetNotificationLogsAfterDataReset(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('日志清理成功不能掩盖初始化账本尾写入失败，也不重复反馈', () async {
    final cleanup = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'resetNotificationCaptureLogs') {
            return cleanup.future;
          }
          return null;
        });
    final repository = _FailingRuleWriteRepository();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repository,
    );
    addTearDown(controller.dispose);
    await controller.waitForPendingWrites();
    final errors = <Object>[];
    controller.onPersistError = errors.add;
    repository.failRuleWrites = true;
    controller.resetAllData();
    final waiting = controller.waitForPendingWritesSucceeded();
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    cleanup.complete(true);
    expect(await waiting, isFalse);
    expect(errors, hasLength(1));
  });
}
