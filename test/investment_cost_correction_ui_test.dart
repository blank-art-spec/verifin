import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/stock_opening_cost_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 创建包含旧总成本记录的隔离账户；[quantity] 为期初股数，[cost] 为原总成本。
/// [reference] 固定每股参考价，不连接网络；控制器由测试结束时统一释放。
Future<VeriFinController> _holdingController({
  String quantity = '3',
  String cost = '341',
  String reference = '325.48',
}) async {
  final controller = await makeController();
  addTearDown(controller.dispose);
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '100',
      openedAt: DateTime(2026, 10, 1),
      securities: [avgoFixture],
      openingHoldings: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: quantity,
          cost: cost,
        ),
      ],
      manualPrices: {avgoFixture.id: reference},
    ),
    isTrue,
  );
  return controller;
}

/// 打开真实持仓页面；[width] 和 [scale] 同时作用于随后推入的成本更正页面。
/// 使用项目主题与中文脚手架，测试结束后恢复屏幕尺寸和系统字号。
Future<void> _pumpHolding(
  WidgetTester tester,
  VeriFinController controller, {
  double width = 393,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: buildVeriFinTheme(Brightness.light),
        home: InvestmentPage(accountId: investmentAccountFixture().id),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 定位 [pageType] 内的纵向页面滚动区，避免误选导航动画或其他组件的滚动节点。
Finder _scroll(Type pageType) => find
    .descendant(of: find.byType(pageType), matching: find.byType(Scrollable))
    .first;

/// 在 [pageType] 的真实滚动区内把 [target] 移到可点击位置，而非只确认它已构建。
/// 持仓卡较高时目标虽已在组件树中仍可能位于屏幕外；最多拖动四十次并明确断言命中。
Future<void> _revealAction(
  WidgetTester tester,
  Finder target,
  Type pageType,
) async {
  final scroll = _scroll(pageType);
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: scroll,
    maxScrolls: 40,
  );
  await tester.pumpAndSettle();
  for (
    var attempt = 0;
    attempt < 40 && target.hitTestable().evaluate().isEmpty;
    attempt++
  ) {
    final offset = tester.getCenter(target).dy < 0 ? 180.0 : -180.0;
    await tester.drag(scroll, Offset(0, offset));
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget);
}

/// 从真实持仓卡进入成本更正页；该入口在修复前对已有成本的持仓不可见。
Future<void> _openCorrection(WidgetTester tester) async {
  final action = find.widgetWithText(TextButton, '更正期初成本');
  await _revealAction(tester, action, InvestmentPage);
  await tester.tap(action);
  await tester.pumpAndSettle();
  expect(find.byType(StockOpeningCostPage), findsOneWidget);
}

/// 读取指定业务标签对应的明细值；[label] 使用页面真实文案而非组件顺序。
String _detail(WidgetTester tester, String label) => tester
    .widget<DetailInfoRow>(
      find.byWidgetPredicate(
        (widget) => widget is DetailInfoRow && widget.label == label,
      ),
    )
    .value;

/// 输入新的每股成本 [text]，先滚动到输入框，保留页面的真实输入和预览回调。
Future<void> _enterCost(WidgetTester tester, String text) async {
  final field = find.byKey(const ValueKey('stock-opening-unit-cost'));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

/// 点击真实保存按钮并等待页面稳定；成功返回持仓页，失败应继续保留编辑草稿。
Future<void> _saveCorrection(WidgetTester tester) async {
  final save = find.widgetWithText(FilledButton, '保存');
  await _revealAction(tester, save, StockOpeningCostPage);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

/// 读取当前成本输入原文，验证错误和离页取消不会清空或偷偷改写用户草稿。
String _costText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('stock-opening-unit-cost')))
    .controller!
    .text;

/// 覆盖已有持仓修复、取消、非法输入、精度保护和并发变化，不操作用户设备数据。
void main() {
  useTestDatabases();

  for (final layout in [
    (width: 393.0, scale: 1.0),
    (width: 360.0, scale: 1.5),
  ]) {
    testWidgets('已有三股成本可更正为每股341并显示亏损 ${layout.width}/${layout.scale}', (
      tester,
    ) async {
      final controller = await _holdingController();
      final account = investmentAccountFixture();
      await _pumpHolding(
        tester,
        controller,
        width: layout.width,
        scale: layout.scale,
      );
      await _openCorrection(tester);
      expect(_costText(tester), '113.66666667');
      expect(_detail(tester, '期初股数'), '3');
      expect(_detail(tester, '期初总成本'), formatUserMoney(341, 'USD'));

      await _enterCost(tester, '341');
      expect(_detail(tester, '期初总成本'), formatUserMoney(1023, 'USD'));
      // 预览不落库；只有明确保存才改变期初成本。
      expect(
        controller.investmentFor(account.id)!.openingHoldings.single.cost,
        '341',
      );
      await _saveCorrection(tester);

      expect(find.byType(StockOpeningCostPage), findsNothing);
      expect(_detail(tester, '剩余总成本'), formatUserMoney(1023, 'USD'));
      expect(_detail(tester, '每股平均成本'), formatUserSecurityPrice('341', 'USD'));
      expect(_detail(tester, '未实现盈亏'), formatSignedUserMoney(-46.56, 'USD'));
      expect(controller.accountBalance(account), 100);
      final portfolio = controller.investmentFor(account.id)!;
      expect(portfolio.openingHoldings.single.cost, '1023');
      expect(portfolio.openingHoldings.single.quantity, '3');
      expect(portfolio.events, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('离页取消保留草稿，明确不保存后原持仓完全不变', (tester) async {
    final controller = await _holdingController();
    final account = investmentAccountFixture();
    final original = controller.investmentFor(account.id)!;
    await _pumpHolding(tester, controller);
    await _openCorrection(tester);
    await _enterCost(tester, '341');

    await Navigator.of(
      tester.element(find.byType(StockOpeningCostPage)),
    ).maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(_costText(tester), '341');
    expect(identical(controller.investmentFor(account.id), original), isTrue);

    await Navigator.of(
      tester.element(find.byType(StockOpeningCostPage)),
    ).maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '不保存'));
    await tester.pumpAndSettle();
    expect(find.byType(StockOpeningCostPage), findsNothing);
    expect(identical(controller.investmentFor(account.id), original), isTrue);
    expect(controller.accountBalance(account), 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('负的极小单位成本不能被舍入为零，失败保留输入和原记录', (tester) async {
    final controller = await _holdingController();
    final account = investmentAccountFixture();
    final original = controller.investmentFor(account.id)!;
    await _pumpHolding(tester, controller);
    await _openCorrection(tester);
    await _enterCost(tester, '-0.00000001');
    await _saveCorrection(tester);

    expect(find.byType(StockOpeningCostPage), findsOneWidget);
    expect(find.textContaining('请输入非负的每股成本'), findsOneWidget);
    expect(_costText(tester), '-0.00000001');
    expect(identical(controller.investmentFor(account.id), original), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开不改动禁止保存，仅改均价格式也不反乘覆盖原总成本', (tester) async {
    final controller = await _holdingController(
      quantity: '10000000',
      cost: '1.01',
      reference: '0.0000001',
    );
    final account = investmentAccountFixture();
    await _pumpHolding(tester, controller);
    await _openCorrection(tester);
    expect(_costText(tester), '0.0000001');
    expect(_detail(tester, '期初总成本'), formatUserMoney(1.01, 'USD'));
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.scrollUntilVisible(
      save,
      160,
      scrollable: _scroll(StockOpeningCostPage),
    );
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    // 该均价乘股数只能得到1.00；补一个尾零不应将真实总成本1.01改为1.00。
    await _enterCost(tester, '0.00000010');
    expect(_detail(tester, '期初总成本'), formatUserMoney(1.01, 'USD'));
    await _saveCorrection(tester);
    expect(find.byType(StockOpeningCostPage), findsNothing);
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '1.01',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('非零总成本的均价低于八位精度时留空，明确输入零可将成本归零', (tester) async {
    final controller = await _holdingController(
      quantity: '100000000',
      cost: '0.01',
      reference: '0.00000001',
    );
    final account = investmentAccountFixture();
    await _pumpHolding(tester, controller);
    await _openCorrection(tester);
    // 每股真实成本低于最小可输入精度，预填零会混淆“原成本”和“主动归零”。
    expect(_costText(tester), isEmpty);
    expect(_detail(tester, '期初总成本'), formatUserMoney(0.01, 'USD'));
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '0.01',
    );

    await _enterCost(tester, '0');
    expect(_detail(tester, '期初总成本'), formatUserMoney(0, 'USD'));
    await _saveCorrection(tester);
    expect(find.byType(StockOpeningCostPage), findsNothing);
    final holding = controller
        .investmentFor(account.id)!
        .openingHoldings
        .single;
    expect(holding.cost, '0');
    expect(holding.quantity, '100000000');
    expect(controller.accountBalance(account), 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑中切换账本隐藏旧证券资料并禁止保存，仍可丢弃草稿退出', (tester) async {
    final controller = await _holdingController();
    final account = investmentAccountFixture();
    final original = controller.investmentFor(account.id)!;
    await _pumpHolding(tester, controller);
    await _openCorrection(tester);
    await _enterCost(tester, '341');

    controller.addLedgerBook('另一个账本');
    await tester.pumpAndSettle();
    expect(find.byType(StockOpeningCostPage), findsOneWidget);
    expect(find.textContaining('持仓资料已变化'), findsOneWidget);
    expect(find.byKey(const ValueKey('stock-opening-unit-cost')), findsNothing);
    expect(find.textContaining('博通'), findsNothing);
    expect(find.textContaining('AVGO'), findsNothing);
    expect(find.text('期初股数'), findsNothing);
    expect(find.text('期初总成本'), findsNothing);
    expect(find.widgetWithText(FilledButton, '保存'), findsNothing);

    await Navigator.of(
      tester.element(find.byType(StockOpeningCostPage)),
    ).maybePop();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '保存'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '不保存'));
    await tester.pumpAndSettle();
    expect(find.byType(StockOpeningCostPage), findsNothing);
    controller.switchLedgerBook(original.bookId);
    await tester.pumpAndSettle();
    expect(identical(controller.investmentFor(account.id), original), isTrue);
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '341',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑期间持仓资料更新后拒绝旧草稿并保留用户输入', (tester) async {
    final controller = await _holdingController();
    final account = investmentAccountFixture();
    await _pumpHolding(tester, controller);
    await _openCorrection(tester);
    await _enterCost(tester, '341');
    expect(
      await controller.setStockReferencePrice(
        account.id,
        avgoFixture.id,
        '326',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    final updated = controller.investmentFor(account.id)!;
    await _saveCorrection(tester);

    expect(find.textContaining('持仓资料已变化'), findsOneWidget);
    expect(find.byType(StockOpeningCostPage), findsOneWidget);
    expect(_costText(tester), '341');
    expect(identical(controller.investmentFor(account.id), updated), isTrue);
    expect(updated.openingHoldings.single.cost, '341');
    expect(updated.manualPrices[avgoFixture.id], '326');
    expect(tester.takeException(), isNull);
  });
}
