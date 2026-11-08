import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/chart_painters.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/report_analysis_page.dart';
import 'package:verifin/pages/sheets.dart';

import 'support/test_harness.dart';

Account _account(
  VeriFinController controller,
  String id, {
  AccountType type = AccountType.cash,
  String currency = 'CNY',
  String? parentId,
}) => Account(
  id: id,
  bookId: controller.activeBook.id,
  name: id,
  type: type,
  groupId: null,
  initialBalance: 0,
  iconCode: type.supportsCredit ? 'credit_card' : 'wallet',
  note: '',
  includeInAssets: true,
  hidden: false,
  currencyCode: currency,
  creditAccountId: parentId,
  statementDay: type.supportsCredit ? 25 : null,
  dueDay: type.supportsCredit ? 13 : null,
);

void _entry(
  VeriFinController controller,
  String id,
  String accountId,
  double amount,
  DateTime date, {
  EntryType type = EntryType.expense,
  String category = 'dining',
  DateTime? postDate,
  String currency = 'CNY',
  double? referenceBaseAmount,
  List<String> tagIds = const <String>[],
}) {
  controller.addEntry(
    LedgerEntry(
      id: id,
      bookId: controller.activeBook.id,
      type: type,
      amount: amount,
      currencyCode: currency,
      referenceBaseAmount: referenceBaseAmount,
      categoryId: category,
      accountId: accountId,
      note: id,
      occurredAt: date,
      postDate: postDate,
      tagIds: tagIds,
    ),
  );
}

Future<void> _pumpReport(
  WidgetTester tester,
  VeriFinController controller, {
  double width = 393,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 852);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const ReportAnalysisPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('report_range_selector')),
    -300,
    scrollable: firstVerticalScrollable(),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAccounts(WidgetTester tester) async {
  await _top(tester);
  await tester.tap(find.byKey(const Key('report_account_filter')));
  await tester.pumpAndSettle();
}

Future<void> _pickAccount(WidgetTester tester, String id) async {
  await _openAccounts(tester);
  final row = find.byKey(ValueKey(id));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

Future<void> _range(WidgetTester tester, String label) async {
  await _top(tester);
  await tester.tap(find.byKey(const Key('report_range_selector')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Finder _cardWithTitle(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(VeriCard)).first;

void _expectExpense(double expense) {
  expect(
    find.descendant(
      of: _cardWithTitle('收支概览'),
      matching: find.text(formatExpenseAmount(expense)),
    ),
    findsWidgets,
  );
}

void _expectAccountLabel(String label) {
  expect(
    find.descendant(
      of: find.byKey(const Key('report_account_filter')),
      matching: find.text(label),
    ),
    findsOneWidget,
  );
}

void main() {
  useTestDatabases();

  testWidgets('账户范围统一筛选收支、趋势、排行与月度对比，普通周期按消费日', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.addAccountDraft(_account(controller, '日常现金'));
    await controller.addAccountDraft(_account(controller, '备用现金'));
    final now = DateTime.now();
    final current = DateTime(now.year, now.month, 1);
    final previous = DateTime(now.year, now.month - 1, 1);
    final lastYear = DateTime(now.year - 1, now.month, 1);
    _entry(
      controller,
      'selected-current',
      '日常现金',
      120,
      current,
      postDate: DateTime(now.year, now.month + 1, 1),
    );
    _entry(
      controller,
      'selected-previous',
      '日常现金',
      60,
      previous,
      postDate: current,
    );
    _entry(controller, 'selected-last-year', '日常现金', 30, lastYear);
    _entry(
      controller,
      'selected-income',
      '日常现金',
      500,
      current,
      type: EntryType.income,
      category: 'salary',
    );
    for (final (id, date, amount) in [
      ('other-current', current, 900.0),
      ('other-previous', previous, 900.0),
      ('other-last-year', lastYear, 900.0),
    ]) {
      _entry(controller, id, '备用现金', amount, date, category: 'transport');
    }
    await _pumpReport(tester, controller);
    _expectExpense(1020);
    await _pickAccount(tester, '日常现金');
    _expectExpense(120);
    expect(
      find.descendant(
        of: _cardWithTitle('收支概览'),
        matching: find.text(formatIncomeAmount(500)),
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('同比 · 环比'),
      150,
      scrollable: firstVerticalScrollable(),
    );
    final comparison = _cardWithTitle('同比 · 环比');
    expect(
      find.descendant(of: comparison, matching: find.text('+100.0%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: comparison, matching: find.text('+300.0%')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byType(InteractiveTrendChart),
      200,
      scrollable: firstVerticalScrollable(),
    );
    final chart = tester.widget<InteractiveTrendChart>(
      find.byType(InteractiveTrendChart),
    );
    expect(chart.values.reduce((sum, amount) => sum + amount), 120);
    await tester.scrollUntilVisible(
      find.text('分类排行'),
      200,
      scrollable: firstVerticalScrollable(),
    );
    final ranking = _cardWithTitle('分类排行');
    expect(
      find.descendant(of: ranking, matching: find.text('餐饮')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ranking, matching: find.text('交通')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('可统计主账户全部币种、单币种和无账户，取消保留且可恢复全部', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    const bankName = '用于家庭日常消费与长期旅行预算的多币种银行账户';
    await controller.addAccountDraft(
      _account(controller, bankName, type: AccountType.debitCard),
    );
    final parent = controller.accountParents.single;
    final usd = (await controller.ensureCurrencyChild(parent.id, 'USD'))!;
    await controller.addAccountDraft(_account(controller, '其他现金'));
    final now = DateTime.now();
    _entry(controller, 'bank-cny', bankName, 100, now);
    _entry(
      controller,
      'bank-usd',
      usd.id,
      10,
      now,
      currency: 'USD',
      referenceBaseAmount: 70,
    );
    _entry(controller, 'other-account', '其他现金', 800, now);
    _entry(controller, 'without-account', '', 25, now);
    await _pumpReport(
      tester,
      controller,
      width: 360,
      brightness: Brightness.dark,
      textScale: 1.5,
    );
    await _openAccounts(tester);
    expect(find.text('合并全部币种账户'), findsWidgets);
    await tester.tap(
      find.byKey(ValueKey('$creditParentPickerPrefix${parent.id}')),
    );
    await tester.pumpAndSettle();
    _expectExpense(170);
    _expectAccountLabel(bankName);
    final filterRect = tester.getRect(
      find.byKey(const Key('report_account_filter')),
    );
    expect(filterRect.left, greaterThanOrEqualTo(0));
    expect(filterRect.right, lessThanOrEqualTo(360));
    await _pickAccount(tester, usd.id);
    _expectExpense(70);
    await _openAccounts(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectExpense(70);
    await _openAccounts(tester);
    await tester.tap(find.text('无账户').last);
    await tester.pumpAndSettle();
    _expectAccountLabel('无账户');
    _expectExpense(25);
    await _openAccounts(tester);
    await tester.tap(find.text('全部账户').last);
    await tester.pumpAndSettle();
    _expectAccountLabel('全部账户');
    _expectExpense(995);
    await _pickAccount(tester, '$creditParentPickerPrefix${parent.id}');
    expect(await controller.deleteAccountAndRelatedEntries(usd.id), isNotNull);
    await tester.pumpAndSettle();
    _expectAccountLabel(bankName);
    _expectExpense(100);
    expect(
      await controller.deleteAccountAndRelatedEntries(bankName),
      isNotNull,
    );
    await tester.pumpAndSettle();
    _expectAccountLabel('全部账户');
    _expectExpense(825);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择账户后翻月和切换季、年、自定义及账期仍保持各自统计范围', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.addAccountDraft(_account(controller, '周期现金'));
    await controller.addAccountDraft(
      _account(controller, '账期信用卡', type: AccountType.creditCard),
    );
    final now = DateTime.now();
    final current = DateTime(now.year, now.month, 1);
    final previous = DateTime(now.year, now.month - 1, 1);
    _entry(controller, 'current-cash', '周期现金', 120, current);
    _entry(controller, 'previous-cash', '周期现金', 40, previous);
    _entry(controller, 'current-credit', '账期信用卡', 777, now);
    await _pumpReport(tester, controller);
    await _pickAccount(tester, '周期现金');
    await tester.tap(find.byTooltip('上一段'));
    await tester.pumpAndSettle();
    _expectExpense(40);
    _expectAccountLabel('周期现金');
    await _range(tester, '本季');
    _expectExpense(now.month % 3 == 1 ? 120 : 160);
    _expectAccountLabel('周期现金');
    await _range(tester, '本年');
    _expectExpense(now.month == 1 ? 120 : 160);
    await _range(tester, '本月');
    await _range(tester, '自定义');
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    _expectAccountLabel('周期现金');
    _expectExpense(120);
    expect(find.byTooltip('上一段'), findsNothing);
    await _range(tester, '账期');
    expect(find.byKey(const Key('report_account_filter')), findsNothing);
    _expectExpense(777);
    await _range(tester, '本月');
    _expectAccountLabel('周期现金');
    _expectExpense(120);
    expect(tester.takeException(), isNull);
  });

  testWidgets('所选账户删除或切换账本后回到全部账户且不保留旧账本筛选', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.addAccountDraft(_account(controller, '待删除现金'));
    await controller.addAccountDraft(_account(controller, '保留现金'));
    final now = DateTime.now();
    _entry(controller, 'removed-account-entry', '待删除现金', 120, now);
    _entry(controller, 'kept-account-entry', '保留现金', 180, now);
    await _pumpReport(tester, controller);
    await _pickAccount(tester, '待删除现金');
    _expectExpense(120);
    // 普通删除会拒绝仍有交易的账户，使用真实的“账户及相关流水”删除命令。
    expect(await controller.deleteAccountAndRelatedEntries('待删除现金'), isNotNull);
    await tester.pumpAndSettle();
    _expectAccountLabel('全部账户');
    _expectExpense(180);
    await _pickAccount(tester, '保留现金');
    expect(await controller.createLedgerBook('另一本账'), isTrue);
    await controller.addAccountDraft(_account(controller, '新账本现金'));
    _entry(controller, 'new-book-entry', '新账本现金', 9, now);
    await tester.pumpAndSettle();
    _expectAccountLabel('全部账户');
    _expectExpense(9);
    await _openAccounts(tester);
    expect(find.byKey(const ValueKey('保留现金')), findsNothing);
    expect(find.byKey(const ValueKey('新账本现金')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账户、标签与分类可交叉筛选，跨账户已到账退款冲减原消费账户', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.addAccountDraft(_account(controller, '消费账户'));
    await controller.addAccountDraft(_account(controller, '退款账户'));
    final tagId = controller.addTag('出差统计标签')!;
    final now = DateTime.now();
    _entry(controller, 'tagged-dining', '消费账户', 120, now, tagIds: [tagId]);
    _entry(
      controller,
      'tagged-transport',
      '消费账户',
      50,
      now,
      category: 'transport',
      tagIds: [tagId],
    );
    _entry(controller, 'untagged-dining', '消费账户', 30, now);
    _entry(
      controller,
      'other-account-dining',
      '退款账户',
      800,
      now,
      tagIds: [tagId],
    );
    expect(
      controller.addRefund(
        expenseId: 'tagged-dining',
        amount: 20,
        accountId: '退款账户',
        initiatedAt: now,
        settledAt: now,
      ),
      isNotNull,
    );
    expect(
      controller.addRefund(
        expenseId: 'tagged-dining',
        amount: 10,
        accountId: '退款账户',
        initiatedAt: now,
      ),
      isNotNull,
    );
    await _pumpReport(tester, controller);
    await _pickAccount(tester, '消费账户');
    // 已到账的 20 元冲减原账户支出；待到账的 10 元不影响净额。
    _expectExpense(180);
    await tester.tap(find.text('筛选标签维度'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('出差统计标签'));
    await tester.tap(find.text('出差统计标签'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    _expectExpense(150);
    await tester.tap(find.text('筛选分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('餐饮').last);
    await tester.pumpAndSettle();
    _expectExpense(100);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    _expectAccountLabel('消费账户');
    _expectExpense(180);
    await _pickAccount(tester, '退款账户');
    _expectExpense(800);
    expect(tester.takeException(), isNull);
  });
}
