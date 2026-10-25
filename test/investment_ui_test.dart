import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/investment_page.dart';
import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();
  testWidgets('编辑中切换账本后显示失效状态，不泄漏或误写旧账户', (tester) async {
    final c = await makeController();
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: StockEditorPage(accountId: account.id, setup: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    c.addLedgerBook('另一个账本');
    await tester.pumpAndSettle();
    expect(find.textContaining('未保存：'), findsOneWidget);
    expect(c.investmentFor(account.id), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('启用表单取消不落库；保存现金后可进入真实持仓页', (tester) async {
    final c = await makeController();
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: InvestmentPage(accountId: account.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用证券持仓'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stock-cash')), '5000');
    Navigator.of(tester.element(find.byType(StockEditorPage))).pop();
    await tester.pumpAndSettle();
    expect(c.investmentFor(account.id), isNull);
    await tester.tap(find.text('启用证券持仓'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.scrollUntilVisible(
      save,
      250,
      scrollable: find
          .descendant(
            of: find.byType(StockEditorPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(c.investmentFor(account.id), isNotNull);
    expect(find.text('参考净值'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('暂无证券持仓'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(InvestmentPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('暂无证券持仓'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('393 与窄屏显示博通部分平仓结果；超量卖出保留草稿', (tester) async {
    final c = await makeController();
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await c.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
    );
    await c.saveStockEvent(
      accountId: account.id,
      security: avgoFixture,
      event: stockEventFixture(
        'buy',
        StockEventKind.buy,
        '10',
        '300',
        fee: '1',
      ),
      referencePrice: '330',
    );
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: InvestmentPage(accountId: account.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('博通 · AVGO'), findsOneWidget);
    expect(find.text('参考净值'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(360, 852));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('记录股票交易'));
    await tester.pumpAndSettle();
    // 用户切换动作时只看到该动作的真实输入：股息填总额，拆股填比例。
    await tester.tap(find.text('买入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('股息'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stock-quantity')), findsNothing);
    expect(find.text('总额'), findsOneWidget);
    await tester.tap(find.text('股息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拆股 / 合股'));
    await tester.pumpAndSettle();
    expect(find.text('新股数'), findsOneWidget);
    expect(find.text('原股数'), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-fee')), findsNothing);
    await tester.tap(find.text('拆股 / 合股'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('买入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stock-symbol')), 'AVGO');
    await tester.enterText(find.byKey(const ValueKey('stock-name')), '博通');
    await tester.enterText(find.byKey(const ValueKey('stock-quantity')), '999');
    await tester.enterText(find.byKey(const ValueKey('stock-price')), '330');
    await tester.enterText(
      find.byKey(const ValueKey('stock-reference')),
      '330',
    );
    // 超量买入也因现金不足拒绝，避免 UI 校验只检查数字格式。
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.scrollUntilVisible(
      save,
      250,
      scrollable: find
          .descendant(
            of: find.byType(StockEditorPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(c.investmentFor(account.id)!.events, hasLength(1));
    expect(find.textContaining('未保存：'), findsOneWidget);
    expect(find.byType(StockEditorPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
