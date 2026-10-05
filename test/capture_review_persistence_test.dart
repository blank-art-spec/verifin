import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';

class _DelayedCaptureRepository extends InMemoryLedgerRepository {
  Completer<void>? entered;
  Completer<void>? release;
  bool failAggregate = false;

  Future<void> _pause() async {
    final gate = release;
    if (gate == null) return;
    release = null;
    entered!.complete();
    await gate.future;
  }

  @override
  Future<void> saveCaptureEvents(List<CaptureEvent> events) async {
    await _pause();
    await super.saveCaptureEvents(events);
  }

  @override
  Future<void> saveCaptureProcessing({
    required List<LedgerEntry> entries,
    required List<CaptureEvent> captureEvents,
  }) async {
    await _pause();
    await super.saveCaptureProcessing(
      entries: entries,
      captureEvents: captureEvents,
    );
  }

  @override
  Future<void> saveEntryAggregate({
    required List<LedgerEntry> entries,
    required List<Attachment> attachments,
    List<ExchangeRate>? exchangeRates,
    List<CaptureEvent>? captureEvents,
  }) async {
    if (failAggregate) throw StateError('injected save failure');
    await super.saveEntryAggregate(
      entries: entries,
      attachments: attachments,
      exchangeRates: exchangeRates,
      captureEvents: captureEvents,
    );
  }
}

CaptureEvent _event(String id, String bookId) => captureEventFromInput(
  id: id,
  bookId: bookId,
  input: RawCaptureInput(
    sourceKind: CaptureSourceKind.notification,
    sourceId: 'cmb-life',
    sourceEventId: id,
    rawText: '您在财付通-遂小狮有一笔2.30人民币的消费已成功',
    receivedAt: DateTime(2026, 10, 2, 18, 5),
  ),
);

LedgerEntry _entry(VeriFinController controller, String id) => LedgerEntry(
  id: id,
  bookId: controller.activeBook.id,
  type: EntryType.expense,
  amount: 2.30,
  accountId: '',
  categoryId: controller.categories
      .firstWhere((category) => category.type == EntryType.expense)
      .id,
  note: '复核',
  occurredAt: DateTime(2026, 10, 2, 18, 5),
);

void main() {
  test('后台延迟落库不能覆盖用户已复核状态，冷启动后仍已确认', () async {
    final store = LocalKeyValueStore();
    final repo = _DelayedCaptureRepository();
    var controller = await VeriFinController.create(store, repository: repo);
    final reviewedEntry = _entry(controller, 'reviewed');
    expect(
      await controller.saveEntryAggregateDraft(
        entry: reviewedEntry,
        isNew: true,
      ),
      isTrue,
    );
    final event = _event('reviewed-event', controller.activeBook.id).copyWith(
      status: CaptureStatus.autoPosted,
      linkedEntryId: reviewedEntry.id,
    );
    await repo.saveCaptureEvents([
      event,
      _event('background', controller.activeBook.id),
    ]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);

    final gate = Completer<void>();
    repo.entered = Completer<void>();
    repo.release = gate;
    final background = controller.processPendingCaptureEvents(
      allowAutomaticActions: false,
    );
    await repo.entered!.future;
    final review = controller.markCaptureEventConfirmed(
      eventId: event.id,
      entryId: reviewedEntry.id,
    );
    // 让旧实现的独立状态保存先完成，再释放后台旧快照。
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await Future.wait([background, review]);
    expect(
      controller.captureEvents
          .singleWhere((item) => item.id == event.id)
          .status,
      CaptureStatus.confirmed,
    );
    controller.dispose();
    final reloaded = await VeriFinController.create(store, repository: repo);
    expect(
      reloaded.captureEvents.singleWhere((item) => item.id == event.id).status,
      CaptureStatus.confirmed,
    );
    expect(reloaded.entries.single.id, reviewedEntry.id);
    reloaded.dispose();
  });

  test('复核交易与事件原子保存，失败保持待确认并可重试，重复保存被拒绝', () async {
    final store = LocalKeyValueStore();
    final repo = _DelayedCaptureRepository();
    var controller = await VeriFinController.create(store, repository: repo);
    final event = _event('atomic-review', controller.activeBook.id);
    await repo.saveCaptureEvents([
      event.copyWith(status: CaptureStatus.pendingReview),
    ]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    final entry = _entry(controller, 'atomic-entry');
    repo.failAggregate = true;
    final failed = await controller.saveEntryAggregateDraftResult(
      entry: entry,
      isNew: true,
      captureEventId: event.id,
    );
    expect(failed, isA<EntrySavePersistenceFailure>());
    expect(controller.entries, isEmpty);
    expect(await repo.loadEntries(), isEmpty);
    expect(
      (await repo.loadCaptureEvents()).single.status,
      CaptureStatus.pendingReview,
    );
    repo.failAggregate = false;
    expect(
      (await controller.saveEntryAggregateDraftResult(
        entry: entry,
        isNew: true,
        captureEventId: event.id,
      )).isSuccess,
      isTrue,
    );
    expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
    expect(controller.captureEvents.single.linkedEntryId, entry.id);
    expect(
      controller.entries.single.sourceRecords.single.fingerprint,
      event.fingerprint,
    );
    expect(
      (await controller.saveEntryAggregateDraftResult(
        entry: entry.copyWith(id: 'duplicate'),
        isNew: true,
        captureEventId: event.id,
      )).isSuccess,
      isFalse,
    );
    await controller.ingestCaptureInputs([
      RawCaptureInput(
        sourceKind: event.sourceKind,
        sourceId: event.sourceId,
        sourceEventId: event.sourceEventId,
        rawText: event.rawText,
        receivedAt: event.receivedAt,
      ),
    ]);
    await controller.replayRecentCaptureEvents();
    controller.dispose();
    final reloaded = await VeriFinController.create(store, repository: repo);
    expect(reloaded.entries, hasLength(1));
    expect(reloaded.captureEvents.single.status, CaptureStatus.confirmed);
    reloaded.dispose();
  });

  test('旧版留下的待复核事件按唯一来源证据恢复，不要求再次记账', () async {
    final store = LocalKeyValueStore();
    final repo = InMemoryLedgerRepository();
    var controller = await VeriFinController.create(store, repository: repo);
    final event = _event('old-review', controller.activeBook.id);
    final entry = _entry(
      controller,
      'old-entry',
    ).copyWith(sourceRecords: [sourceRecordForCapture(event)]);
    expect(
      await controller.saveEntryAggregateDraft(entry: entry, isNew: true),
      isTrue,
    );
    await repo.saveCaptureEvents([
      event.copyWith(status: CaptureStatus.pendingReview),
    ]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
    expect(controller.captureEvents.single.linkedEntryId, entry.id);
    expect(controller.entries, hasLength(1));
    controller.dispose();
  });
}
