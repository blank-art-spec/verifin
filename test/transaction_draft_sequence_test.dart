import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/option_editor_page.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 建立无成交、现金一万元的美元组合，同时登记已核对的本地期权规格。
/// 合约仅用于离线表单验证，未来到期日不依赖当前真实期权挂牌或行情。
Future<({VeriFinController controller, Account account, StockSecurity option})>
_ready() async {
  final controller = await makeController();
  final account = investmentAccountFixture();
  final option = optionFixture(expiry: '2099-12-18');
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
      securities: [avgoFixture, option],
      manualPrices: {avgoFixture.id: '50', option.id: '3'},
    ),
    isTrue,
  );
  return (controller: controller, account: account, option: option);
}

/// 挂载真实双页签页面；两个投资品种均通过现有领域表单保存。
Future<void> _pumpEditor(
  WidgetTester tester,
  VeriFinController controller,
) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: TransactionEntryPage(
          bookId: controller.activeBook.id,
          initialAccountId: controller.accounts.single.id,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 切换股票/期权草稿，实际点击品种选择器，不直接调用页面内部回调。
Future<void> _activity(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('transaction-investment-activity')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// 从当前领域列表顶部向下寻找控件，避免上次停在表单底部导致滚动方向错误。
Future<void> _reveal(
  WidgetTester tester,
  Finder target,
  Type editorType,
) async {
  final scroll = find
      .descendant(
        of: find.byType(editorType),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.drag(scroll, const Offset(0, 6000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(target, 260, scrollable: scroll);
  await tester.pumpAndSettle();
}

/// 使用真实文本输入填写指定领域字段，保留两个隐藏表单各自的控制器。
Future<void> _field(
  WidgetTester tester,
  String prefix,
  String key,
  String value,
  Type editorType,
) async {
  final field = find.byKey(ValueKey('$prefix-$key'));
  await _reveal(tester, field, editorType);
  await tester.enterText(field, value);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

/// 填写两股、每股十元的股票草稿；参考价只用于估值，不影响真实二十元现金腿。
Future<void> _stockDraft(WidgetTester tester) async {
  for (final field in {
    'symbol': 'AVGO',
    'name': '博通',
    'quantity': '2',
    'price': '10',
    'reference': '50',
  }.entries) {
    await _field(tester, 'stock', field.key, field.value, StockEditorPage);
  }
}

/// 使用已登记的完整规格，填写一张权利金每股两元的认购草稿并手动预览。
Future<void> _optionDraft(WidgetTester tester, StockSecurity option) async {
  final select = find.widgetWithText(OutlinedButton, '选择已有合约');
  await _reveal(tester, select, OptionEditorPage);
  await tester.tap(select);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option.symbol).last);
  await tester.pumpAndSettle();
  await _field(tester, 'option', 'quantity', '1', OptionEditorPage);
  await _field(tester, 'option', 'price', '2', OptionEditorPage);
  await _previewOption(tester);
}

/// 每次预览都重新核对当时现金及当前组合，不把旧预览自动转换成确认。
Future<void> _previewOption(WidgetTester tester) async {
  final preview = find.widgetWithText(OutlinedButton, '预览结算后现金与持仓');
  await _reveal(tester, preview, OptionEditorPage);
  await tester.tap(preview);
  await tester.pumpAndSettle();
}

void main() {
  useTestDatabases();

  testWidgets('同账户先保存期权，再保存此前已打开的股票草稿，不冲突或重复现金', (tester) async {
    final fixture = await _ready();
    final c = fixture.controller;
    addTearDown(c.dispose);
    await _pumpEditor(tester, c);
    await _stockDraft(tester);
    await _activity(tester, '期权交易与结算');
    await _optionDraft(tester, fixture.option);
    final save = find.byKey(const Key('transaction-save-current'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(c.investmentFor(fixture.account.id)!.events, hasLength(1));
    expect(c.accountBalance(fixture.account), 9800);
    await _activity(tester, '记录股票交易');
    await tester.tap(save);
    await tester.pumpAndSettle();
    final events = c.investmentFor(fixture.account.id)!.events;
    expect(events, hasLength(2));
    expect(events.map((event) => event.sequence).toSet(), hasLength(2));
    expect(
      events.singleWhere((event) => event.kind == StockEventKind.buy).sequence,
      1,
    );
    expect(c.accountBalance(fixture.account), 9780);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('期权旧预览在另一股票草稿保存后失效，重新预览才可按新序号保存', (tester) async {
    final fixture = await _ready();
    final c = fixture.controller;
    addTearDown(c.dispose);
    await _pumpEditor(tester, c);
    await _activity(tester, '期权交易与结算');
    await _optionDraft(tester, fixture.option);
    final save = find.byKey(const Key('transaction-save-current'));
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await _activity(tester, '记录股票交易');
    await _stockDraft(tester);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(c.accountBalance(fixture.account), 9980);
    await _activity(tester, '期权交易与结算');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(c.investmentFor(fixture.account.id)!.events, hasLength(1));
    await _previewOption(tester);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final events = c.investmentFor(fixture.account.id)!.events;
    expect(events, hasLength(2));
    expect(events.map((event) => event.sequence).toSet(), {0, 1});
    expect(
      events
          .singleWhere((event) => event.kind == StockEventKind.optionBuyOpen)
          .sequence,
      1,
    );
    expect(c.accountBalance(fixture.account), 9780);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑已有股票事件在新增其他成交后仍保留原序号', (tester) async {
    final fixture = await _ready();
    final c = fixture.controller;
    addTearDown(c.dispose);
    final original = stockEventFixture(
      'original-stock',
      StockEventKind.buy,
      '1',
      '10',
      sequence: 7,
    );
    expect(
      await c.saveStockEvent(
        accountId: fixture.account.id,
        security: avgoFixture,
        event: original,
        referencePrice: '50',
      ),
      isTrue,
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: StockEditorPage(
            accountId: fixture.account.id,
            event: original,
            securityId: avgoFixture.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _field(tester, 'stock', 'quantity', '2', StockEditorPage);
    expect(
      await c.saveStockEvent(
        accountId: fixture.account.id,
        security: avgoFixture,
        event: stockEventFixture(
          'another-stock',
          StockEventKind.buy,
          '1',
          '5',
          sequence: 8,
          day: 3,
        ),
        referencePrice: '50',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, '保存');
    await _reveal(tester, save, StockEditorPage);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final events = c.investmentFor(fixture.account.id)!.events;
    expect(events, hasLength(2));
    expect(events.singleWhere((event) => event.id == original.id).sequence, 7);
    expect(
      events.singleWhere((event) => event.id == original.id).quantity,
      '2',
    );
    expect(c.accountBalance(fixture.account), 9975);
    expect(tester.takeException(), isNull);
  });
}
