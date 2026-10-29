import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/reminder/account_entry_reminder.dart';
import 'package:verifin/app/reminder/workday_calendar_client.dart';
import 'package:verifin/app/reminder/workday_calendar_sync.dart';
import 'package:verifin/l10n/app_localizations_zh.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/workday_calendar_fixture.dart';
import 'support/workday_calendar_harness.dart';

/// 日历联网授权、缓存、跨年、竞态与保存失败回归；按用户要求由用户手动运行。
void main() {
  test('默认关闭且创建不联网，force 也不能绕过授权', () async {
    final client = FakeHolidayCalendarClient(
      (_) async => workdayCalendarDocument(),
    );
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    expect(controller.workdayCalendarListenable.value.enabled, isFalse);
    expect(
      await controller.syncWorkdayCalendar(force: true),
      WorkdayCalendarSyncResult.disabled,
    );
    expect(client.calls, isEmpty);
    expect(controller.workdayCalendar.supportedYears, [2026]);
  });

  test('快速连续开启再关闭按用户最后选择落盘，不触发隐式请求', () async {
    final client = FakeHolidayCalendarClient((_) async => null);
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    final results = await Future.wait([
      controller.setWorkdayCalendarAutoUpdate(true),
      controller.setWorkdayCalendarAutoUpdate(false),
    ]);
    expect(results, [true, true]);
    expect(controller.workdayCalendarListenable.value.enabled, isFalse);
    expect(client.calls, isEmpty);
  });

  test('当前年度可用、下一年度未公布，冷启动保留缓存与授权且不进入备份', () async {
    final store = LocalKeyValueStore();
    final repository = InMemoryLedgerRepository();
    final client = FakeHolidayCalendarClient(
      (year) async => year == 2026 ? workdayCalendarDocument() : null,
    );
    var controller = await makeWorkdayCalendarController(
      client: client,
      store: store,
      repository: repository,
    );
    expect(await controller.setWorkdayCalendarAutoUpdate(true), isTrue);
    expect(client.calls, isEmpty);
    expect(
      await controller.syncWorkdayCalendar(now: DateTime(2026, 10, 21)),
      WorkdayCalendarSyncResult.pending,
    );
    expect(client.calls, [2026, 2027]);
    final saved = controller.workdayCalendarListenable.value.toJson();
    expect(controller.workdayCalendarListenable.value.pendingYears, {2027});
    expect(controller.workdayCalendar.supportedYears, [2026]);
    final backup = controller.exportDataJson();
    expect(backup, isNot(contains('workday_calendar')));
    expect(backup, isNot(contains('holiday-cn')));
    controller.importDataJson(backup);
    await controller.flushPendingWrites();
    expect(controller.workdayCalendarListenable.value.toJson(), saved);
    controller.dispose();
    controller = await makeWorkdayCalendarController(
      client: client,
      store: store,
      repository: repository,
    );
    expect(controller.workdayCalendarListenable.value.toJson(), saved);
    expect(client.calls, [2026, 2027]);
    expect(controller.workdayCalendarListenable.value.updating, isFalse);
    controller.dispose();
  });

  test('预取下一年度后无需更新应用，失败或占位不替换原缓存；关闭继续离线可用', () async {
    var fail = false;
    final client = FakeHolidayCalendarClient((year) async {
      if (fail) throw const SocketException('测试离线');
      return workdayCalendarDocument(year);
    });
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    await controller.setWorkdayCalendarAutoUpdate(true);
    expect(
      await controller.syncWorkdayCalendar(now: DateTime(2026, 12, 30)),
      WorkdayCalendarSyncResult.updated,
    );
    expect(controller.workdayCalendar.supportedYears, [2026, 2027]);
    final calendar = controller.workdayCalendar.toJson();
    fail = true;
    expect(
      await controller.syncWorkdayCalendar(
        force: true,
        now: DateTime(2026, 12, 31),
      ),
      WorkdayCalendarSyncResult.failed,
    );
    expect(controller.workdayCalendar.toJson(), calendar);
    await controller.setWorkdayCalendarAutoUpdate(false);
    expect(controller.workdayCalendar.toJson(), calendar);
    final calls = client.calls.length;
    expect(
      await controller.syncWorkdayCalendar(force: true),
      WorkdayCalendarSyncResult.disabled,
    );
    expect(client.calls.length, calls);
  });

  test('每日节流不阻止一月一日首次检查，手动检查可绕过节流', () async {
    final client = FakeHolidayCalendarClient((_) async => null);
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    await controller.setWorkdayCalendarAutoUpdate(true);
    await controller.syncWorkdayCalendar(now: DateTime(2026, 12, 31, 23, 59));
    expect(
      await controller.syncWorkdayCalendar(
        now: DateTime(2026, 12, 31, 23, 59, 30),
      ),
      WorkdayCalendarSyncResult.skipped,
    );
    await controller.syncWorkdayCalendar(now: DateTime(2027, 1, 1));
    expect(client.calls, [2026, 2027, 2027, 2028]);
    await controller.syncWorkdayCalendar(
      force: true,
      now: DateTime(2027, 1, 1),
    );
    expect(client.calls.length, 6);
  });

  test('下载日历同时进入原生快照和确认日期规则，跨账本/删除账户不删除公共缓存', () async {
    final changed = workdayCalendarFixture();
    // 隔离修订，不代表真实公告；用于确认生产读取路径确实使用下载缓存。
    (changed['days']! as List).add({
      'name': '元旦',
      'date': '2026-12-31',
      'isOffDay': true,
    });
    final doc = HolidayCalendarDocument.parse(changed, expectedYear: 2026)!;
    final client = FakeHolidayCalendarClient(
      (year) async => year == 2026 ? doc : null,
    );
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    await controller.setWorkdayCalendarAutoUpdate(true);
    await controller.syncWorkdayCalendar(now: DateTime(2026, 10, 21));
    // 新账本按产品约定不预置账户；本用例显式建立隔离账户，不能从空列表取 first。
    // 保留下载缓存、原生快照与删除后的全部断言，避免借生产种子数据掩盖夹具缺失。
    final account = Account(
      id: 'calendar-account',
      bookId: controller.activeBook.id,
      name: '日历测试账户',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 0,
      iconCode: 'cash',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    await controller.saveAccountEntryReminder(
      AccountEntryReminder(
        id: '',
        accountId: account.id,
        bookId: account.bookId,
        currencyCode: account.currencyCode,
        enabled: true,
        amount: 12,
        categoryId: controller.categories
            .firstWhere((item) => item.type == EntryType.expense)
            .id,
        repeatMode: AccountReminderRepeatMode.chinaWorkdays,
      ),
    );
    final projection = controller
        .accountEntryReminderNotifications(AppLocalizationsZh())
        .single;
    final calendar = projection['workdayCalendar']! as Map<String, Object?>;
    final years = calendar['years']! as Map<String, Object?>;
    expect(
      (years['2026']! as Map<String, Object?>)['holidays'],
      contains(1231),
    );
    expect(
      controller
          .accountEntryReminder(account.id)!
          .matchesDate(
            DateTime(2026, 12, 31),
            calendar: controller.workdayCalendar,
          ),
      isFalse,
    );
    controller.addLedgerBook('另一账本');
    expect(controller.workdayCalendar.toJson(), calendar);
    controller.switchLedgerBook(account.bookId);
    expect(await controller.deleteAccount(account.id), isNotNull);
    expect(
      controller.workdayCalendarListenable.value.documents[2026]!.toJson(),
      doc.toJson(),
    );
  });

  test('并发检查只发一轮，关闭或初始化后拒绝旧结果且不再请求下一年度', () async {
    for (final reset in [false, true]) {
      final gate = Completer<HolidayCalendarDocument?>();
      final client = FakeHolidayCalendarClient((_) => gate.future);
      final store = LocalKeyValueStore();
      final controller = await makeWorkdayCalendarController(
        client: client,
        store: store,
      );
      await controller.setWorkdayCalendarAutoUpdate(true);
      final running = controller.syncWorkdayCalendar(
        now: DateTime(2026, 10, 21),
      );
      expect(
        await controller.syncWorkdayCalendar(force: true),
        WorkdayCalendarSyncResult.skipped,
      );
      if (reset) {
        controller.resetAllData();
      } else {
        await controller.setWorkdayCalendarAutoUpdate(false);
      }
      gate.complete(workdayCalendarDocument());
      expect(await running, WorkdayCalendarSyncResult.skipped);
      expect(client.calls, [2026]);
      expect(controller.workdayCalendarListenable.value.enabled, isFalse);
      expect(controller.workdayCalendarListenable.value.documents, isEmpty);
      await controller.flushPendingWrites();
      controller.dispose();
    }
  });

  test('保存失败保留内存和磁盘中的旧设置，损坏缓存不会恢复联网授权', () async {
    final store = _CalendarWriteStore();
    final client = FakeHolidayCalendarClient(
      (year) async => workdayCalendarDocument(year),
    );
    final controller = await makeWorkdayCalendarController(
      client: client,
      store: store,
    );
    await controller.setWorkdayCalendarAutoUpdate(true);
    final previous = store.read('verifin.workday_calendar.v1');
    store.fail = true;
    expect(
      await controller.syncWorkdayCalendar(now: DateTime(2026, 10, 21)),
      WorkdayCalendarSyncResult.failed,
    );
    expect(store.read('verifin.workday_calendar.v1'), previous);
    expect(controller.workdayCalendarListenable.value.documents, isEmpty);
    expect(controller.workdayCalendarListenable.value.checkedAt, isNull);
    controller.dispose();
    store.write('verifin.workday_calendar.v1', '{损坏缓存');
    final restored = await makeWorkdayCalendarController(
      client: client,
      store: store,
    );
    expect(restored.workdayCalendarListenable.value.enabled, isFalse);
    expect(restored.workdayCalendar.supportedYears, [2026]);
    restored.dispose();
  });

  test('初始化发生于 KV 写入等待期间，也不会恢复已撤销的联网授权', () async {
    final store = _CalendarWriteStore();
    final client = FakeHolidayCalendarClient(
      (year) async => workdayCalendarDocument(year),
    );
    final controller = await makeWorkdayCalendarController(
      client: client,
      store: store,
    );
    await controller.setWorkdayCalendarAutoUpdate(true);
    store.delay = true;
    final running = controller.syncWorkdayCalendar(now: DateTime(2026, 10, 21));
    await store.started.future;
    controller.resetAllData();
    store.release.complete();
    expect(await running, WorkdayCalendarSyncResult.skipped);
    expect(controller.workdayCalendarListenable.value.enabled, isFalse);
    final persisted = WorkdayCalendarSettings.decode(
      store.read('verifin.workday_calendar.v1'),
    );
    expect(persisted.enabled, isFalse);
    expect(persisted.documents, isEmpty);
    await controller.flushPendingWrites();
    controller.dispose();
  });

  test('关闭尚在等待 KV 落盘时，也立即阻止备用地址与新一轮检查', () async {
    final response = Completer<HolidayCalendarResponse>();
    var calls = 0;
    final client = HolidayCalendarClient(
      transport: (_) {
        calls++;
        return response.future;
      },
    );
    final store = _CalendarWriteStore();
    final controller = await makeWorkdayCalendarController(
      client: client,
      store: store,
    );
    await controller.setWorkdayCalendarAutoUpdate(true);
    final running = controller.syncWorkdayCalendar(now: DateTime(2026, 10, 21));
    store.delay = true;
    final closing = controller.setWorkdayCalendarAutoUpdate(false);
    await store.started.future;
    expect(
      await controller.syncWorkdayCalendar(force: true),
      WorkdayCalendarSyncResult.disabled,
    );
    response.complete((statusCode: 500, bytes: const <int>[]));
    expect(await running, WorkdayCalendarSyncResult.skipped);
    expect(calls, 1);
    store.release.complete();
    expect(await closing, isTrue);
    expect(controller.workdayCalendarListenable.value.enabled, isFalse);
    controller.dispose();
  });
}

/// 只对日历 KV 注入失败或延迟，不改变账目仓储与其他偏好的行为。
class _CalendarWriteStore extends LocalKeyValueStore {
  bool fail = false;
  bool delay = false;
  final started = Completer<void>();
  final release = Completer<void>();

  /// 对 [key] 的日历写入按测试开关注入异常或等待；其他 [value] 正常保存。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (key == 'verifin.workday_calendar.v1') {
      if (fail) throw StateError('隔离的日历保存失败');
      if (delay) {
        delay = false;
        started.complete();
        await release.future;
      }
    }
    await super.writeAndFlush(key, value);
  }
}
