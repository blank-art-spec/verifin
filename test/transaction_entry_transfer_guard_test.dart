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

/// 滚动当前普通表单以操作真实转入字段，不依赖隐藏表单或直接修改其私有状态。
Future<void> _selectTarget(WidgetTester tester, String name) async {
  final target = find.byKey(const Key('to_account_dropdown'));
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find
        .descendant(
          of: find.byType(EntryDetailPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(target);
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// 按用户路径输入一笔十元转账，金额键盘和保存校验沿用普通记账实现。
Future<void> _enterTen(WidgetTester tester) async {
  final amount = find.byKey(const Key('detail_amount_button'));
  await tester.scrollUntilVisible(
    amount,
    -200,
    scrollable: find
        .descendant(
          of: find.byType(EntryDetailPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(amount);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('number_key_C')));
  await tester.tap(find.byKey(const Key('number_key_1')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('number_key_0')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('number_pad_ok')));
  await tester.pumpAndSettle();
}

/// 返回三个独立人民币现金账户，A 为默认转出，B 为用户选中目标，C 仅作备选。
Future<
  ({
    VeriFinController controller,
    Account source,
    Account target,
    Account other,
  })
>
_readyTransfer() async {
  final controller = await makeController();
  final accounts =
      [('source-a', '转出A'), ('target-b', '目标B'), ('other-c', '备选C')]
          .map(
            (value) => investmentAccountFixture(id: value.$1, currency: 'CNY')
                .copyWith(
                  type: AccountType.cash,
                  name: value.$2,
                  initialBalance: 1000,
                ),
          )
          .toList();
  for (final account in accounts) {
    controller.addAccount(account);
  }
  await controller.waitForPendingWrites();
  controller.setDefaultAccountId(accounts.first.id);
  expect(
    await controller.changeLedgerBookType(
      controller.activeBook.id,
      LedgerBookType.investment,
    ),
    isTrue,
  );
  return (
    controller: controller,
    source: accounts[0],
    target: accounts[1],
    other: accounts[2],
  );
}

void main() {
  useTestDatabases();
  for (final hidden in [false, true]) {
    testWidgets('转入B被${hidden ? '隐藏' : '删除'}后不静默替换为C，用户重选后才能保存', (
      tester,
    ) async {
      final fixture = await _readyTransfer();
      final c = fixture.controller;
      addTearDown(c.dispose);
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        VeriFinScope(
          controller: c,
          child: zhMaterialApp(
            home: TransactionEntryPage(bookId: c.activeBook.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const Key('transaction-entry-mode')),
              matching: find.text('普通记账'),
            )
            .hitTestable()
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const Key('entry_type_segmented_button')),
              matching: find.text('转账'),
            )
            .hitTestable()
            .first,
      );
      await tester.pumpAndSettle();
      await _selectTarget(tester, fixture.target.name);
      await _enterTen(tester);
      final save = find.byKey(const Key('transaction-save-current'));
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      if (hidden) {
        expect(
          await c.saveAccountDraft(fixture.target.copyWith(hidden: true)),
          isTrue,
        );
      } else {
        expect(
          await c.deleteAccountAndRelatedEntries(fixture.target.id),
          isNotNull,
        );
      }
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(c.entries, isEmpty);
      final warning = find.byKey(const Key('entry_transfer_target_invalid'));
      await tester.scrollUntilVisible(
        warning,
        200,
        scrollable: find
            .descendant(
              of: find.byType(EntryDetailPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final target = find.byKey(const Key('to_account_dropdown'));
      final field = tester.widget<SelectField>(target);
      expect(field.value, isNot(contains(fixture.other.name)));
      expect(field.value, isNot(contains(fixture.source.name)));
      expect(warning, findsOneWidget);
      expect(c.accountBalance(fixture.source), 1000);
      expect(c.accountBalance(fixture.other), 1000);

      // 用户明确重新选择 C 后才形成 A→C，不能在 B 失效的重建中自动生成这个选择。
      await _selectTarget(tester, fixture.other.name);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(
        find.byKey(const Key('entry_transfer_target_invalid')),
        findsNothing,
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(c.entries, hasLength(1));
      expect(c.entries.single.type, EntryType.transfer);
      expect(c.entries.single.accountId, fixture.source.id);
      expect(c.entries.single.toAccountId, fixture.other.id);
      expect(c.accountBalance(fixture.source), 990);
      expect(c.accountBalance(fixture.other), 1010);
      expect(tester.takeException(), isNull);
    });
  }
}
