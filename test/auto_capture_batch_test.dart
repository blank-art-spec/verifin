import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/auto_capture_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

class _BatchRepository extends InMemoryLedgerRepository {
  bool fail = false;
  int writes = 0;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> saveCaptureEvents(List<CaptureEvent> events) async {
    writes++;
    final gate = release;
    if (gate != null) {
      release = null;
      entered!.complete();
      await gate.future;
    }
    if (fail) throw StateError('injected capture save failure');
    await super.saveCaptureEvents(events);
  }
}

typedef _Fixture = ({
  VeriFinController controller,
  LocalKeyValueStore store,
  _BatchRepository repository,
});

CaptureEvent _event(String id, String bookId, int minute) =>
    captureEventFromInput(
      id: id,
      bookId: bookId,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.store',
        sourceLabel: '商店',
        sourceEventId: id,
        rawText: '推广通知 $id',
        receivedAt: DateTime(2026, 10, 6, 1, minute),
      ),
    ).copyWith(processedAt: DateTime(2026, 10, 6, 2));

Future<_Fixture> _fixture({int count = 3}) async {
  final store = LocalKeyValueStore();
  store.write('verifin.locale.v1', 'zh');
  final repository = _BatchRepository();
  final initial = await VeriFinController.create(store, repository: repository);
  final bookId = initial.activeBook.id;
  await repository.saveBooks([
    ...initial.ledgerBooks,
    LedgerBook(
      id: 'other-book',
      name: '另一个账本',
      createdAt: DateTime(2026),
      isDefault: false,
    ),
  ]);
  final posted = _event(
    'event-0',
    bookId,
    0,
  ).copyWith(status: CaptureStatus.autoPosted, linkedEntryId: 'posted-entry');
  await repository.saveEntries([
    ...initial.entries,
    LedgerEntry(
      id: 'posted-entry',
      bookId: bookId,
      type: EntryType.expense,
      amount: 12,
      accountId: '',
      categoryId: initial.categories
          .firstWhere((category) => category.type == EntryType.expense)
          .id,
      note: '',
      occurredAt: DateTime(2026, 10, 6),
      sourceRecords: [sourceRecordForCapture(posted)],
    ),
  ]);
  await repository.saveCaptureEvents([
    posted,
    for (var i = 1; i < count; i++) _event('event-$i', bookId, i),
    _event(
      'confirmed',
      bookId,
      40,
    ).copyWith(status: CaptureStatus.confirmed, linkedEntryId: 'posted-entry'),
    _event('foreign', 'other-book', 41),
  ]);
  initial.dispose();
  final controller = await VeriFinController.create(
    store,
    repository: repository,
  );
  repository.writes = 0;
  return (controller: controller, store: store, repository: repository);
}

void main() {
  useTestDatabases();

  test('批量误识别一次保存，只改所选当前账本事件并保留原文和交易证据', () async {
    final fixture = await _fixture();
    final controller = fixture.controller;
    addTearDown(controller.dispose);
    final entries = (await fixture.repository.loadEntries())
        .map((entry) => entry.toJson())
        .toList();
    expect(
      await controller.markCaptureEventsMisidentified([
        'event-0',
        'event-1',
        'event-1',
        'foreign',
        'confirmed',
        'missing',
      ]),
      2,
    );
    expect(fixture.repository.writes, 1);
    final saved = await fixture.repository.loadCaptureEvents();
    for (final id in ['event-0', 'event-1']) {
      final event = saved.singleWhere((event) => event.id == id);
      expect(event.status, CaptureStatus.misidentified);
      expect(event.rawText, '推广通知 $id');
      expect(event.linkedEntryId, isNull);
    }
    expect(
      saved.singleWhere((event) => event.id == 'event-2').status,
      CaptureStatus.raw,
    );
    expect(
      saved.singleWhere((event) => event.id == 'foreign').status,
      CaptureStatus.raw,
    );
    expect(
      saved.singleWhere((event) => event.id == 'confirmed').status,
      CaptureStatus.confirmed,
    );
    expect(
      (await fixture.repository.loadEntries()).map((entry) => entry.toJson()),
      entries,
    );
    final reloaded = await VeriFinController.create(
      fixture.store,
      repository: fixture.repository,
    );
    addTearDown(reloaded.dispose);
    expect(
      reloaded.captureEvents.where(
        (event) => event.status == CaptureStatus.misidentified,
      ),
      hasLength(2),
    );
    expect(
      reloaded.entries
          .singleWhere((entry) => entry.id == 'posted-entry')
          .sourceRecords,
      hasLength(1),
    );
  });

  test('批量删除失败不改内存或磁盘；重试只删选中事件并保留已生成交易', () async {
    final fixture = await _fixture();
    final controller = fixture.controller;
    addTearDown(controller.dispose);
    final before = controller.captureEvents
        .map((event) => event.toJson())
        .toList();
    Object? persistError;
    controller.onPersistError = (error) => persistError = error;
    fixture.repository.fail = true;
    expect(
      await controller.deleteCaptureEvents(['event-0', 'event-1']),
      isNull,
    );
    expect(persistError, isNotNull);
    expect(controller.captureEvents.map((event) => event.toJson()), before);
    expect(
      (await fixture.repository.loadCaptureEvents()).where(
        (event) => event.id.startsWith('event-'),
      ),
      hasLength(3),
    );
    fixture.repository.fail = false;
    expect(
      await controller.deleteCaptureEvents([
        'event-0',
        'event-1',
        'foreign',
        'confirmed',
      ]),
      2,
    );
    final saved = await fixture.repository.loadCaptureEvents();
    expect(
      saved.map((event) => event.id),
      containsAll(['event-2', 'foreign', 'confirmed']),
    );
    expect(saved.map((event) => event.id), isNot(contains('event-0')));
    expect(
      controller.entries
          .singleWhere((entry) => entry.id == 'posted-entry')
          .sourceRecords,
      hasLength(1),
    );
    final reloaded = await VeriFinController.create(
      fixture.store,
      repository: fixture.repository,
    );
    addTearDown(reloaded.dispose);
    expect(
      reloaded.captureEvents.map((event) => event.id),
      isNot(contains('event-1')),
    );
  });

  test('排队期间切换账本或修改选择集合，不扩大批量操作范围', () async {
    final fixture = await _fixture();
    final controller = fixture.controller;
    addTearDown(controller.dispose);
    fixture.repository.entered = Completer<void>();
    final gate = Completer<void>();
    fixture.repository.release = gate;
    final first = controller.ignoreCaptureEvent('event-2');
    await fixture.repository.entered!.future;
    final ids = <String>{'event-1', 'foreign'};
    final batch = controller.deleteCaptureEvents(ids);
    ids.add('event-0');
    controller.switchLedgerBook('other-book');
    gate.complete();
    expect(await first, isTrue);
    expect(await batch, 1);
    final saved = await fixture.repository.loadCaptureEvents();
    expect(saved.map((event) => event.id), containsAll(['event-0', 'foreign']));
    expect(saved.map((event) => event.id), isNot(contains('event-1')));
  });

  for (final delete in [false, true]) {
    testWidgets('多选全选后批量${delete ? '删除' : '误识别'}，取消确认不改数据', (tester) async {
      final fixture = await _fixture();
      addTearDown(fixture.controller.dispose);
      await tester.pumpWidget(
        VeriFinScope(
          controller: fixture.controller,
          child: zhMaterialApp(home: const AutoCapturePage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('capture_batch_select')),
        180,
        scrollable: firstVerticalScrollable(),
      );
      await tester.tap(find.byKey(const Key('capture_batch_select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选当前列表'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 项'), findsOneWidget);
      final action = delete ? '批量删除' : '批量误识别';
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
      await tester.pumpAndSettle();
      expect(fixture.repository.writes, 0);
      expect(find.text('已选 3 项'), findsOneWidget);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.text(delete ? '删除' : '标记误识别'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.repository.writes, 1);
      expect(
        find.byKey(const ValueKey<String>('capture_event_event-0')),
        findsNothing,
      );
      expect(
        fixture.controller.entries.singleWhere(
          (entry) => entry.id == 'posted-entry',
        ),
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('全选仅覆盖当前三十条，多选期间新通知不自动加入', (tester) async {
    final fixture = await _fixture(count: 31);
    addTearDown(fixture.controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: fixture.controller,
        child: zhMaterialApp(home: const AutoCapturePage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('capture_batch_select')),
      180,
      scrollable: firstVerticalScrollable(),
    );
    await tester.tap(find.byKey(const Key('capture_batch_select')));
    await tester.pumpAndSettle();
    final firstCheckbox = find.byKey(
      const ValueKey<String>('capture_select_event-30'),
    );
    await tester.ensureVisible(firstCheckbox);
    await tester.tap(firstCheckbox);
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.text('全选当前列表'));
    await tester.pumpAndSettle();
    expect(find.text('已选 30 项'), findsOneWidget);
    await fixture.controller.ingestCaptureInputs([
      RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.store',
        sourceEventId: 'arrived-later',
        rawText: '新的推广通知',
        receivedAt: DateTime(2026, 10, 6, 3),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('已选 30 项'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('capture_select_event-0')),
      findsNothing,
    );
    fixture.repository.writes = 0;
    await tester.tap(find.text('批量删除'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle();
    expect(fixture.repository.writes, 1);
    expect(
      fixture.controller.captureEvents.any((event) => event.id == 'event-0'),
      isTrue,
    );
    expect(
      fixture.controller.captureEvents.any(
        (event) => event.sourceEventId == 'arrived-later',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
