import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/option_editor_page.dart';
import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  testWidgets('期权窄屏编辑预览零落库，改字段后重新预览才可保存', (tester) async {
    final c = await makeController(),
        account = investmentAccountFixture(),
        s = optionFixture();
    addTearDown(c.dispose);
    c.addAccount(account);
    await c.waitForPendingWrites();
    await c.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
    );
    final open = optionEventFixture(s, StockEventKind.optionBuyOpen);
    expect(
      await c.saveOptionEvent(
        accountId: account.id,
        security: s,
        underlying: avgoFixture,
        event: open,
        referencePrice: '3',
        underlyingReferencePrice: '50',
      ),
      isTrue,
    );
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: OptionEditorPage(accountId: account.id, event: open),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = find
        .descendant(
          of: find.byType(OptionEditorPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final quantity = find.byKey(const ValueKey('option-quantity'));
    await tester.scrollUntilVisible(quantity, 300, scrollable: scroll);
    await tester.enterText(quantity, '2');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final preview = find.widgetWithText(OutlinedButton, '预览结算后现金与持仓');
    await tester.scrollUntilVisible(preview, 300, scrollable: scroll);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(c.accountBalance(account), 9800);
    expect(find.textContaining('9600'), findsWidgets);
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: scroll,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNotNull,
    );
    await tester.scrollUntilVisible(quantity, -300, scrollable: scroll);
    await tester.enterText(quantity, '3');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(preview, 300, scrollable: scroll);
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, '保存'),
      200,
      scrollable: scroll,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.tap(preview);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.scrollUntilVisible(save, 200, scrollable: scroll);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(c.accountBalance(account), 9400);
    expect(c.investmentFor(account.id)!.events, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换账本后期权草稿失效，不误写其他账本', (tester) async {
    final c = await makeController(), a = investmentAccountFixture();
    addTearDown(c.dispose);
    c.addAccount(a);
    await c.waitForPendingWrites();
    await c.enableInvestment(
      accountId: a.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: OptionEditorPage(accountId: a.id)),
      ),
    );
    await tester.pumpAndSettle();
    c.addLedgerBook('另一账本');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('option-symbol')), findsNothing);
    expect(find.textContaining('未保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
