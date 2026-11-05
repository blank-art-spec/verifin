import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/entry_sheets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'package:verifin/pages/transaction_detail_page.dart';

import 'support/test_harness.dart';

final _consumedAt = DateTime(2026, 11, 24, 23, 58);

/// 创建无网络依赖的真实表单账户；[controller] 持有本次用例隔离的内存仓储。
Future<void> _addAccount(VeriFinController controller) async {
  controller.addAccount(
    Account(
      id: 'posting-cash',
      bookId: controller.activeBook.id,
      name: '现金',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 1000,
      iconCode: 'cash',
      note: '',
      includeInAssets: true,
      hidden: false,
    ),
  );
  await controller.waitForPendingWrites();
}

/// 挂载真实页面，[width] 覆盖常规与窄屏，[use24HourFormat] 明确指定设备时制。
/// 测试树直接注入媒体配置，避免平台偏好通知未更新根媒体缓存而误用 12 小时制。
Future<void> _pumpPage(
  WidgetTester tester,
  VeriFinController controller,
  Widget page, {
  double width = 393,
  bool use24HourFormat = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 852);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(alwaysUse24HourFormat: use24HourFormat),
      child: VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 将 [target] 滚入当前表单并点击；[delta] 向下为正、向上查找页头为负。
/// 等待滚动后的布局校正再做命中检查，避免命中列表缓存中尚在屏幕外的字段。
Future<void> _tapField(
  WidgetTester tester,
  Finder target, {
  double delta = 240,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target.hitTestable());
  await tester.pumpAndSettle();
}

/// 在真实系统日期弹窗选择当月 [day] 并确认，不直接调用表单内部回调。
Future<void> _selectPostingDay(WidgetTester tester, int day) async {
  await _tapField(tester, find.byKey(const Key('entry_post_date')));
  final dialog = find.byType(DatePickerDialog);
  await tester.tap(find.descendant(of: dialog, matching: find.text('$day')));
  await tester.tap(find.descendant(of: dialog, matching: find.text('确定')));
  await tester.pumpAndSettle();
}

/// 在真实时间选择器填入 24 小时口径的 [hour]、[minute]，确认分钟精度而不补造秒。
/// [use24HourFormat] 为 false 时按界面实际时制转换小时并点击上午/下午，保存值仍相同。
Future<void> _selectPostingTime(
  WidgetTester tester,
  String hour,
  String minute, {
  bool use24HourFormat = true,
}) async {
  await _tapField(tester, find.byKey(const Key('entry_post_time')));
  await tester.tap(find.byIcon(Icons.keyboard_outlined));
  await tester.pumpAndSettle();
  final fields = find.descendant(
    of: find.byType(TimePickerDialog),
    matching: find.byType(TextField),
  );
  expect(
    MediaQuery.alwaysUse24HourFormatOf(tester.element(fields.first)),
    use24HourFormat,
    reason: '输入必须遵循真实弹窗的设备时制',
  );
  final requestedHour = int.parse(hour);
  final displayHour = use24HourFormat
      ? hour
      : (requestedHour % 12 == 0 ? 12 : requestedHour % 12).toString();
  if (!use24HourFormat) {
    final l10n = MaterialLocalizations.of(tester.element(fields.first));
    await tester.tap(
      find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.text(
          requestedHour < 12
              ? l10n.anteMeridiemAbbreviation
              : l10n.postMeridiemAbbreviation,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
  await tester.enterText(fields.at(0), displayHour);
  await tester.pumpAndSettle();
  await tester.enterText(fields.at(1), minute);
  await tester.pumpAndSettle();
  expect(tester.widget<TextField>(fields.at(0)).controller!.text, displayHour);
  expect(tester.widget<TextField>(fields.at(1)).controller!.text, minute);
  tester.testTextInput.hide();
  await tester.tap(
    find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.text('确定'),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(TimePickerDialog), findsNothing);
}

/// 创建可编辑的已有支出；日期精度与明确归期供回显、清除和草稿保留断言使用。
LedgerEntry _expense(VeriFinController controller) => LedgerEntry(
  id: 'posting-expense',
  bookId: controller.activeBook.id,
  type: EntryType.expense,
  amount: 30,
  categoryId: 'dining',
  accountId: 'posting-cash',
  note: '',
  occurredAt: _consumedAt,
  occurredAtPrecision: OccurredAtPrecision.minute,
  postDate: DateTime(2026, 11, 25, 14, 37),
  postDatePrecision: OccurredAtPrecision.minute,
  billingCycleId: '2026-12-25',
);

void main() {
  useTestDatabases();

  testWidgets('新建支出可取消入账选择，再录入日期时分并与消费时间分别保存', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    await _pumpPage(
      tester,
      controller,
      EntryDetailPage(initialAmount: 30, clock: () => _consumedAt),
    );
    await _tapField(tester, find.byKey(const Key('entry_post_date')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EntryPostDateFields>(find.byType(EntryPostDateFields))
          .postDate,
      isNull,
    );
    expect(find.byKey(const Key('entry_post_time')), findsNothing);
    await _selectPostingDay(tester, 25);
    final dateOnlyFields = tester.widget<EntryPostDateFields>(
      find.byType(EntryPostDateFields),
    );
    expect(dateOnlyFields.postDate, DateTime(2026, 11, 25));
    expect(dateOnlyFields.precision, OccurredAtPrecision.date);
    await _selectPostingTime(tester, '14', '37');
    expect(
      tester
          .widget<EntryPostDateFields>(find.byType(EntryPostDateFields))
          .postDate,
      DateTime(2026, 11, 25, 14, 37),
    );
    expect(
      find.byKey(const Key('save_entry_button')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    await controller.waitForPendingWrites();
    final saved = controller.entries.single;
    expect(saved.occurredAt, _consumedAt);
    expect(saved.postDate, DateTime(2026, 11, 25, 14, 37));
    expect(saved.postDatePrecision, OccurredAtPrecision.minute);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有支出取消不改草稿，清除具体时分后仍保留入账日期', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    controller.addEntry(_expense(controller));
    await controller.waitForPendingWrites();
    await _pumpPage(
      tester,
      controller,
      const TransactionDetailPage(entryId: 'posting-expense'),
    );
    await _tapField(tester, find.byKey(const Key('entry_post_time')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );
    await _tapField(tester, find.byKey(const Key('entry_clear_post_time')));
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isTrue,
    );
    await _tapField(tester, find.byTooltip('保存'), delta: -240);
    await controller.waitForPendingWrites();
    final saved = controller.entries.single;
    expect(saved.postDate, DateTime(2026, 11, 25));
    expect(saved.postDatePrecision, OccurredAtPrecision.date);
    expect(saved.occurredAt, _consumedAt);
    expect(saved.billingCycleId, '2026-12-25');
    expect(tester.takeException(), isNull);
  });

  testWidgets('12 小时制从日期零点补录下午时分后保存为正确入账时间', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    await _pumpPage(
      tester,
      controller,
      EntryDetailPage(initialAmount: 30, clock: () => _consumedAt),
      use24HourFormat: false,
    );
    await _selectPostingDay(tester, 25);
    await _selectPostingTime(tester, '14', '37', use24HourFormat: false);
    expect(
      find.byKey(const Key('save_entry_button')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    await controller.waitForPendingWrites();
    final saved = controller.entries.single;
    expect(saved.occurredAt, _consumedAt);
    expect(saved.postDate, DateTime(2026, 11, 25, 14, 37));
    expect(saved.postDatePrecision, OccurredAtPrecision.minute);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏已有支出可清除入账日期，保存后回退消费时间', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    controller.addEntry(
      _expense(controller).copyWith(clearBillingCycleId: true),
    );
    await controller.waitForPendingWrites();
    await _pumpPage(
      tester,
      controller,
      const TransactionDetailPage(entryId: 'posting-expense'),
      width: 360,
    );
    await _tapField(tester, find.byKey(const Key('entry_clear_post_date')));
    await _tapField(tester, find.byTooltip('保存'), delta: -240);
    await controller.waitForPendingWrites();
    final saved = controller.entries.single;
    expect(saved.postDate, isNull);
    expect(saved.postDatePrecision, OccurredAtPrecision.date);
    expect(saved.billingOccurredAt, _consumedAt);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入草稿入账日期修改只返回草稿并保留银行确认账期', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    LedgerEntry? result;
    await _pumpPage(
      tester,
      controller,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<LedgerEntry>(
                MaterialPageRoute(
                  builder: (_) =>
                      EntryDetailPage.draft(entry: _expense(controller)),
                ),
              );
            },
            child: const Text('打开草稿'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开草稿'));
    await tester.pumpAndSettle();
    await _selectPostingDay(tester, 26);
    final fields = tester.widget<EntryPostDateFields>(
      find.byType(EntryPostDateFields),
    );
    expect(fields.postDate, DateTime(2026, 11, 26, 14, 37));
    expect(fields.precision, OccurredAtPrecision.minute);
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.postDate, DateTime(2026, 11, 26, 14, 37));
    expect(result!.billingCycleId, '2026-12-25');
    expect(controller.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
