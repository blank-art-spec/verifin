import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/reminder/workday_calendar_sync.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations_zh.dart';
import 'package:verifin/pages/workday_calendar_page.dart';

import 'support/test_harness.dart';
import 'support/workday_calendar_fixture.dart';
import 'support/workday_calendar_harness.dart';

/// 用户可见的默认关闭、显式联网、失败/未公布状态与窄屏布局；由用户手动运行。
void main() {
  testWidgets('进入工具页不联网，主动开启后检查，运行中可关闭且不接收旧结果', (tester) async {
    final gate = Completer<HolidayCalendarDocument?>();
    final client = FakeHolidayCalendarClient((_) => gate.future);
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const WorkdayCalendarPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(client.calls, isEmpty);
    final check = find.byKey(const Key('workday_calendar_check_now'));
    // 来源 SelectableText 也包含内部滚动，默认 Scrollable.single 会命中多项；
    // 复用共享纵向列表定位，只滚动页面主列表，不改变原联网与撤销断言。
    await tester.scrollUntilVisible(
      check,
      150,
      scrollable: firstVerticalScrollable(),
    );
    expect(tester.widget<OutlinedButton>(check).onPressed, isNull);
    final toggle = find.byKey(const Key('workday_calendar_auto_update'));
    await tester.ensureVisible(toggle);
    await tester.tap(
      find.descendant(of: toggle, matching: find.byType(Switch)),
    );
    // 使用固定帧推进，不能在存在加载动画时 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.workdayCalendarListenable.value.enabled, isTrue);
    expect(client.calls.length, 1);
    await tester.tap(
      find.descendant(of: toggle, matching: find.byType(Switch)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.workdayCalendarListenable.value.enabled, isFalse);
    gate.complete(workdayCalendarDocument());
    await tester.pumpAndSettle();
    expect(client.calls.length, 1);
    expect(controller.workdayCalendarListenable.value.documents, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字显示来源、可用年份、未公布与失败状态，允许手动重试', (tester) async {
    tester.view.physicalSize = const Size(360, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = FakeHolidayCalendarClient((year) async {
      if (year == 2026) throw StateError('隔离下载失败');
      return null;
    });
    final controller = await makeWorkdayCalendarController(client: client);
    addTearDown(controller.dispose);
    await controller.setWorkdayCalendarAutoUpdate(true);
    await controller.syncWorkdayCalendar(now: DateTime(2026, 10, 21));
    final l10n = AppLocalizationsZh();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 852),
              textScaler: TextScaler.linear(1.5),
            ),
            child: const WorkdayCalendarPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(l10n.accountEntryReminderCalendarCoverage('2026')),
      findsOneWidget,
    );
    final pending = find.text(l10n.workdayCalendarPendingYears('2027'));
    // 窄屏下同样存在来源文本的内部滚动，显式限定页面纵向主列表以保持查找唯一。
    await tester.scrollUntilVisible(
      pending,
      150,
      scrollable: firstVerticalScrollable(),
    );
    expect(pending, findsOneWidget);
    expect(find.text(l10n.workdayCalendarFailedYears('2026')), findsOneWidget);
    final check = find.byKey(const Key('workday_calendar_check_now'));
    await tester.ensureVisible(check);
    expect(tester.widget<OutlinedButton>(check).onPressed, isNotNull);
    final source = find.text(l10n.workdayCalendarSource);
    await tester.scrollUntilVisible(
      source,
      150,
      scrollable: firstVerticalScrollable(),
    );
    expect(source, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
