import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/entry_editor_session.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 创建真实初始化过的本地币种账户；不装配行情来源，不依赖实时价格或网络。
Future<({VeriFinController controller, Account account})> _ready() async {
  final controller = await makeController();
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
    ),
    isTrue,
  );
  return (controller: controller, account: account);
}

/// 直接挂载真实新增外壳，验证其子表单没有额外嵌套 Scaffold。
Future<void> _pumpEditor(
  WidgetTester tester,
  VeriFinController controller, {
  String? initialAccountId,
  Future<void> Function(BuildContext context)? onCreateSecuritiesAccount,
}) async {
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: TransactionEntryPage(
          bookId: controller.activeBook.id,
          initialAccountId: initialAccountId,
          onCreateSecuritiesAccount: onCreateSecuritiesAccount,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 切换业务模式后等待分段动画和草稿状态通知完成，不发送额外设备输入。
Future<void> _mode(WidgetTester tester, String mode) async {
  final label = mode == 'general' ? '普通记账' : '投资交易';
  // 滚动指示胶囊只给当前前景副本挂 Key；点击真实可命中的标签，
  // 然后用前景 Key 确认选择确已变化，而不是直接调用控件回调。
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
  expect(find.byKey(ValueKey('transaction-mode-$mode')), findsOneWidget);
}

/// 在真实股票表单内滚动并填写字段，避免把固定保存区的滚动位置当作录入条件。
Future<void> _stockField(WidgetTester tester, String key, String text) async {
  final field = find.byKey(ValueKey('stock-$key'));
  await tester.scrollUntilVisible(
    field,
    200,
    scrollable: find
        .descendant(
          of: find.byType(StockEditorPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.enterText(field, text);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

/// 普通表单沿用懒构建列表，先在本领域滚动至备注，再填写以验证真实输入行为。
Future<Finder> _generalNote(WidgetTester tester, String text) async {
  final note = find.byKey(const Key('entry_note_field'));
  await tester.scrollUntilVisible(
    note,
    200,
    scrollable: find
        .descendant(
          of: find.byType(EntryDetailPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.enterText(note, text);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  return note;
}

void main() {
  useTestDatabases();

  testWidgets('同一草稿保存成功后不能再次新增，失败可用原草稿重试', (tester) async {
    final session = EntryEditorSession();
    addTearDown(session.dispose);
    var attempts = 0;
    session.update(
      isDirty: true,
      canSave: true,
      onSave: () async {
        attempts++;
        return attempts > 1;
      },
    );
    await tester.pump();
    expect(await session.save(), isFalse);
    expect(session.isDirty, isTrue);
    expect(session.canSave, isTrue);
    expect(await session.save(), isTrue);
    expect(session.isDirty, isFalse);
    expect(session.isSaved, isTrue);
    expect(await session.save(), isFalse);
    expect(attempts, 2);
  });

  testWidgets('投资新增默认展示实际股票表单，只有一个页面外壳，空记录不可保存', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await _pumpEditor(tester, fixture.controller);
    expect(find.byKey(const ValueKey('stock-symbol')), findsOneWidget);
    expect(find.text('普通记账'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('transaction-mode-investment')),
      findsOneWidget,
    );
    expect(find.byType(Scaffold), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('transaction-save-current')),
          )
          .onPressed,
      isNull,
    );
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通记账和股票草稿切换保留，切换不写入账目', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await _pumpEditor(tester, fixture.controller);
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    await tester.enterText(find.byKey(const ValueKey('stock-name')), '博通草稿');
    await _mode(tester, 'general');
    final note = await _generalNote(tester, '普通记账草稿');
    await _mode(tester, 'investment');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-symbol')))
          .controller!
          .text,
      'AVGO',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-name')))
          .controller!
          .text,
      '博通草稿',
    );
    await _mode(tester, 'general');
    expect(tester.widget<TextField>(note).controller!.text, '普通记账草稿');
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换期权和基金使用原业务表单，不将基金送入股票录入', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await _pumpEditor(tester, fixture.controller);
    final activity = find.byKey(const Key('transaction-investment-activity'));
    await tester.tap(activity);
    await tester.pumpAndSettle();
    await tester.tap(find.text('期权交易与结算').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('option-symbol')), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-symbol')), findsNothing);
    await tester.tap(activity);
    await tester.pumpAndSettle();
    await tester.tap(find.text('按金额买入').last);
    await tester.pumpAndSettle();
    expect(find.text('选择基金'), findsWidgets);
    expect(find.byKey(const ValueKey('stock-symbol')), findsNothing);
    expect(find.byKey(const ValueKey('option-symbol')), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存当前股票时保留隐藏普通草稿，不能再次新增相同成交', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await _pumpEditor(tester, fixture.controller);
    await _stockField(tester, 'symbol', 'AVGO');
    await _stockField(tester, 'name', '博通');
    await _stockField(tester, 'quantity', '2');
    await _stockField(tester, 'price', '10');
    await _stockField(tester, 'reference', '11');
    await _mode(tester, 'general');
    final note = await _generalNote(tester, '仍未保存的普通草稿');
    await _mode(tester, 'investment');
    final save = find.byKey(const Key('transaction-save-current'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      hasLength(1),
    );
    expect(fixture.controller.accountBalance(fixture.account), 9980);
    expect(find.text('此记录已保存。可切换到其他草稿继续编辑。'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await _mode(tester, 'general');
    expect(tester.widget<TextField>(note).controller!.text, '仍未保存的普通草稿');
    await _mode(tester, 'investment');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('不同币种账户保持独立股票草稿，不把美元输入解释成人民币', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    final cny = investmentAccountFixture(id: 'stock-cny', currency: 'CNY');
    fixture.controller.addAccount(cny);
    await fixture.controller.waitForPendingWrites();
    expect(
      await fixture.controller.enableInvestment(
        accountId: cny.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
    await _pumpEditor(
      tester,
      fixture.controller,
      initialAccountId: fixture.account.id,
    );
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    final accountPicker = find.byKey(
      const Key('transaction-investment-account'),
    );
    await tester.tap(accountPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(cny.name).last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-symbol')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('stock-symbol')),
      '600795',
    );
    await tester.tap(accountPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(fixture.account.name).last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-symbol')))
          .controller!
          .text,
      'AVGO',
    );
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(fixture.controller.investmentFor(cny.id)!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无证券账户时显示初始化与新建引导，不回落普通账户', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await _pumpEditor(tester, controller);
    expect(find.text('此账本尚无可用的证券账户。'), findsOneWidget);
    expect(find.text('新建证券账户'), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-symbol')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('transaction-save-current')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏草稿也阻止系统返回，取消保留并可明确丢弃全部退出', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: fixture.controller,
        child: zhMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => TransactionEntryPage(
                      bookId: fixture.controller.activeBook.id,
                    ),
                  ),
                ),
                child: const Text('打开录入'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开录入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    await _mode(tester, 'general');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('丢弃全部并退出'), findsOneWidget);
    // 当前普通草稿未修改、只有隐藏股票草稿有改动，不能保存一条空普通记录。
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '保存当前'),
      ),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    await _mode(tester, 'investment');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-symbol')))
          .controller!
          .text,
      'AVGO',
    );
    await _mode(tester, 'general');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃全部并退出'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionEntryPage), findsNothing);
    expect(find.text('打开录入'), findsOneWidget);
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部切换账本使表单失效，切回后仍保留原草稿且不写入新账本', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    final bookId = fixture.controller.activeBook.id;
    await _pumpEditor(tester, fixture.controller);
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    fixture.controller.addLedgerBook('另一账本');
    await tester.pumpAndSettle();
    expect(find.text('目标账本或账户已变化，请返回处理后重试。'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('transaction-save-current')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    fixture.controller.switchLedgerBook(bookId);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('stock-symbol')))
          .controller!
          .text,
      'AVGO',
    );
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('被删除账户的隐藏表单只显示失效，不抛异常或回落其他账户', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await _pumpEditor(tester, fixture.controller);
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    await fixture.controller.deleteAccountAndRelatedEntries(fixture.account.id);
    await tester.pumpAndSettle();
    expect(find.text('此账本尚无可用的证券账户。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('transaction-save-current')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建首个证券账户不会把隐藏普通表单默认值当作未保存交易', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = investmentAccountFixture();
    await _pumpEditor(
      tester,
      controller,
      onCreateSecuritiesAccount: (_) async {
        controller.addAccount(account);
        await controller.waitForPendingWrites();
        expect(
          await controller.enableInvestment(
            accountId: account.id,
            openingCash: '10000',
            openedAt: DateTime(2026, 10, 1),
          ),
          isTrue,
        );
      },
    );
    await tester.tap(find.text('新建证券账户'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-symbol')), findsOneWidget);
    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .isDirty,
      isFalse,
    );
    expect(controller.investmentFor(account.id)!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏与键盘压缩后保存区仍可见，领域表单保持可滚动', (tester) async {
    final fixture = await _ready();
    addTearDown(fixture.controller.dispose);
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpEditor(tester, fixture.controller);
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    await tester.showKeyboard(find.byKey(const ValueKey('stock-name')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transaction-save-current')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('transaction-save-current'))).bottom,
      lessThanOrEqualTo(852),
    );
    expect(tester.takeException(), isNull);
  });
}
