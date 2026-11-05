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
/// [credit] 为 true 时创建每月 25 日出账的信用账户，返回 Controller 归并后的真实子账户。
Future<Account> _addAccount(
  VeriFinController controller, {
  bool credit = false,
}) async {
  controller.addAccount(
    Account(
      id: 'posting-cash',
      bookId: controller.activeBook.id,
      name: credit ? '测试信用卡' : '现金',
      type: credit ? AccountType.creditCard : AccountType.cash,
      groupId: null,
      initialBalance: credit ? 0 : 1000,
      iconCode: credit ? 'credit' : 'cash',
      note: '',
      includeInAssets: true,
      hidden: false,
      statementDay: credit ? 25 : null,
      dueDay: credit ? 13 : null,
    ),
  );
  await controller.waitForPendingWrites();
  return controller.accounts.single;
}

/// 在固定 11 月 26 日核对 [account] 的父/子账户账单结果，避免实际运行日期造成跨期。
/// [billed] 为已出账待还，[current] 为本期金额；本组单笔 30 元的余额和总负债必须不变。
void _expectCreditTotals(
  VeriFinController controller,
  Account account, {
  required double billed,
  required double current,
}) {
  final now = DateTime(2026, 11, 26, 12);
  final parent = controller.creditCycleOverview(
    controller.creditAccountForAccount(account)!,
    now: now,
  );
  final child = controller.creditOverview(account, now: now);
  expect(parent.netSpending, current);
  expect(parent.currentCycleDebt, current);
  expect(parent.billedOutstanding, billed);
  expect(parent.totalDebt, 30);
  expect(child.billedOutstanding, billed);
  expect(child.unbilledAmount, current);
  expect(controller.accountBalance(account), -30);
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

/// 以真实导航打开导入 [entry] 草稿；返回结果交给 [onReturned]，Controller 不落库。
/// 复用生产草稿页面与保存按钮，避免通过内部回调直接拼造测试结果。
Future<void> _openDraft(
  WidgetTester tester,
  VeriFinController controller, {
  required LedgerEntry entry,
  required ValueChanged<LedgerEntry?> onReturned,
}) async {
  await _pumpPage(
    tester,
    controller,
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final result = await Navigator.of(context).push<LedgerEntry>(
              MaterialPageRoute(
                builder: (_) => EntryDetailPage.draft(entry: entry),
              ),
            );
            onReturned(result);
          },
          child: const Text('打开草稿'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开草稿'));
  await tester.pumpAndSettle();
}

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
    expect(saved.billingCycleId, isNull);
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

  testWidgets('窄屏信用支出清除入账日期后撤销旧归期并按消费时间重算金额', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = await _addAccount(controller, credit: true);
    controller.addEntry(_expense(controller));
    await controller.waitForPendingWrites();
    _expectCreditTotals(controller, account, billed: 0, current: 30);
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
    expect(saved.billingCycleId, isNull);
    _expectCreditTotals(controller, account, billed: 30, current: 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('信用支出跨账单日修改入账时间后立即重算本期及已出账待还', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = await _addAccount(controller, credit: true);
    controller.addEntry(_expense(controller));
    await controller.waitForPendingWrites();
    _expectCreditTotals(controller, account, billed: 0, current: 30);
    await _pumpPage(
      tester,
      controller,
      const TransactionDetailPage(entryId: 'posting-expense'),
    );

    // 原 12 月 25 日标记与 11 月 24 日入账推导的 11 月 25 日账期不同，必须撤销旧标记。
    await _selectPostingDay(tester, 24);
    await _tapField(tester, find.byTooltip('保存'), delta: -240);
    await controller.waitForPendingWrites();
    final saved = controller.entries.single;
    expect(saved.postDate, DateTime(2026, 11, 24, 14, 37));
    expect(saved.postDatePrecision, OccurredAtPrecision.minute);
    expect(saved.billingCycleId, isNull);
    expect(saved.occurredAt, _consumedAt);
    _expectCreditTotals(controller, account, billed: 30, current: 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('入账日期改后改回或取消选择不会清除归期，修改其他字段保存仍保留', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = await _addAccount(controller, credit: true);
    controller.addEntry(_expense(controller));
    await controller.waitForPendingWrites();
    await _pumpPage(
      tester,
      controller,
      const TransactionDetailPage(entryId: 'posting-expense'),
    );
    await _selectPostingDay(tester, 24);
    await _selectPostingDay(tester, 25);
    await _tapField(tester, find.byKey(const Key('entry_post_time')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );

    // 通过另一字段产生实际保存，验证“未改入账事实”不会在最终组装时丢弃银行归期。
    await _tapField(tester, find.widgetWithText(DetailInfoRow, '备注'));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '仅补充备注',
    );
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('确认')),
    );
    await tester.pumpAndSettle();
    await _tapField(tester, find.byTooltip('保存'), delta: -240);
    await controller.waitForPendingWrites();
    final saved = controller.entries.single;
    expect(saved.note, '仅补充备注');
    expect(saved.postDate, DateTime(2026, 11, 25, 14, 37));
    expect(saved.postDatePrecision, OccurredAtPrecision.minute);
    expect(saved.billingCycleId, '2026-12-25');
    _expectCreditTotals(controller, account, billed: 0, current: 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入草稿入账日期修改撤销旧归期且只返回草稿', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    LedgerEntry? result;
    await _openDraft(
      tester,
      controller,
      entry: _expense(controller),
      onReturned: (value) => result = value,
    );
    await _selectPostingDay(tester, 24);
    final fields = tester.widget<EntryPostDateFields>(
      find.byType(EntryPostDateFields),
    );
    expect(fields.postDate, DateTime(2026, 11, 24, 14, 37));
    expect(fields.precision, OccurredAtPrecision.minute);
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.postDate, DateTime(2026, 11, 24, 14, 37));
    expect(result!.billingCycleId, isNull);
    expect(controller.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入草稿清除入账日期时同步清除旧归期且不落库', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    LedgerEntry? result;
    await _openDraft(
      tester,
      controller,
      entry: _expense(controller),
      onReturned: (value) => result = value,
    );
    await _tapField(tester, find.byKey(const Key('entry_clear_post_date')));
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.postDate, isNull);
    expect(result!.postDatePrecision, OccurredAtPrecision.date);
    expect(result!.billingCycleId, isNull);
    expect(result!.billingOccurredAt, _consumedAt);
    expect(controller.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导入草稿入账日期改回初值且取消时分选择后保留旧归期', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _addAccount(controller);
    LedgerEntry? result;
    await _openDraft(
      tester,
      controller,
      entry: _expense(controller),
      onReturned: (value) => result = value,
    );
    await _selectPostingDay(tester, 24);
    await _selectPostingDay(tester, 25);
    await _tapField(tester, find.byKey(const Key('entry_post_time')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );
    final note = find.byKey(const Key('entry_note_field'));
    await _tapField(tester, note, delta: -240);
    await tester.enterText(note, '只修改草稿备注');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.note, '只修改草稿备注');
    expect(result!.postDate, DateTime(2026, 11, 25, 14, 37));
    expect(result!.postDatePrecision, OccurredAtPrecision.minute);
    expect(result!.billingCycleId, '2026-12-25');
    expect(controller.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
