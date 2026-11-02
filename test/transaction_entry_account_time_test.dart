import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

final _draftAt = DateTime(2026, 10, 20, 17, 36, 14);
final _openedAt = DateTime(2026, 10, 20, 17, 36, 51);
final _accountReadyAt = DateTime(2026, 10, 20, 17, 36, 52);

/// 在真实双页签中保留一个先于开户的普通草稿，时钟只控制默认时间，不改现金计算。
Future<void> _pumpDraft(
  WidgetTester tester,
  VeriFinController controller,
  DateTime Function() clock,
) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: TransactionEntryPage(
          bookId: controller.activeBook.id,
          clock: clock,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _mode(tester, '普通记账');
}

/// 点击真实模式标签并等待动画，保留原表单 State。
Future<void> _mode(WidgetTester tester, String label) async {
  await tester.tap(
    find
        .descendant(
          of: find.byKey(const Key('transaction-entry-mode')),
          matching: find.text(label),
        )
        .hitTestable()
        .first,
  );
  await tester.pumpAndSettle();
}

/// 把普通表单字段滚入视口，兼容懒构建及从其他页签返回后的滚动位置。
Future<void> _reveal(WidgetTester tester, Finder target, double delta) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find
        .descendant(
          of: find.byType(EntryDetailPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

/// 通过原普通表单选择收入并使用计算器输入1000，最后点新增页的正式保存区。
Future<void> _saveIncome(WidgetTester tester) async {
  final type = find.byKey(const Key('entry_type_segmented_button'));
  await _reveal(tester, type, -250);
  await tester.tap(
    find.descendant(of: type, matching: find.text('收入')).hitTestable().first,
  );
  await tester.pumpAndSettle();
  final amount = find.byKey(const Key('detail_amount_button'));
  await _reveal(tester, amount, -250);
  await tester.tap(amount);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('number_key_C')));
  for (final digit in '1000'.split('')) {
    await tester.tap(find.byKey(Key('number_key_$digit')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('number_pad_ok')));
  await tester.pumpAndSettle();
  final save = find.byKey(const Key('transaction-save-current'));
  expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

/// 用明确期初时刻创建零现金证券账户；不伪造入金或改写已经存在的普通草稿。
Future<Account> _createAccount(VeriFinController controller) async {
  final account = investmentAccountFixture(
    id: 'account-after-blank-draft',
    currency: 'CNY',
  );
  expect(
    await controller.createSecuritiesAccount(
      account: account,
      openingCash: '0',
      openedAt: _openedAt,
    ),
    isTrue,
  );
  return controller.accounts.singleWhere((value) => value.id == account.id);
}

void main() {
  useTestDatabases();

  testWidgets('空白普通草稿首次自动补入后建证券账户时刷新默认时间，随后收入计入现金', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    var now = _draftAt;
    await _pumpDraft(tester, controller, () => now);
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );
    await _mode(tester, '投资交易');
    now = _accountReadyAt;
    final account = await _createAccount(controller);
    await tester.pumpAndSettle();
    await _mode(tester, '普通记账');
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );
    await _saveIncome(tester);
    expect(controller.entries, hasLength(1));
    expect(controller.entries.single.type, EntryType.income);
    expect(controller.entries.single.occurredAt, _accountReadyAt);
    expect(controller.entries.single.occurredAt.isAfter(_openedAt), isTrue);
    expect(controller.accountBalance(account), 1000);
    expect(controller.investmentFor(account.id)!.openingCash, '0');
    expect(controller.investmentFor(account.id)!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有普通输入的草稿自动补入账户时保留原发生时间，不重写历史资金归属', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    var now = _draftAt;
    await _pumpDraft(tester, controller, () => now);
    final note = find.byKey(const Key('entry_note_field'));
    await _reveal(tester, note, 250);
    await tester.enterText(note, '已开始填写的历史草稿');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await _mode(tester, '投资交易');
    now = _accountReadyAt;
    final account = await _createAccount(controller);
    await tester.pumpAndSettle();
    await _mode(tester, '普通记账');
    await _saveIncome(tester);
    expect(controller.entries, hasLength(1));
    expect(controller.entries.single.occurredAt, _draftAt);
    expect(controller.entries.single.note, '已开始填写的历史草稿');
    expect(controller.entries.single.occurredAt.isBefore(_openedAt), isTrue);
    // 期初前流水仍由原领域规则排除；界面不能为让数字增加而修改这个历史事实。
    expect(controller.accountBalance(account), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户明确确认同一日期后即使草稿仍干净，首次补账户也不刷新发生时间', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    var now = _draftAt;
    await _pumpDraft(tester, controller, () => now);
    final date = find.byKey(const Key('entry_metadata_date'));
    await _reveal(tester, date, 250);
    await tester.tap(date);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('确定'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );
    await _mode(tester, '投资交易');
    now = _accountReadyAt;
    final account = await _createAccount(controller);
    await tester.pumpAndSettle();
    await _mode(tester, '普通记账');
    await _saveIncome(tester);
    expect(controller.entries.single.occurredAt, _draftAt);
    expect(controller.accountBalance(account), 0);
    expect(tester.takeException(), isNull);
  });
}
