import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/stock_opening_cost_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 创建隔离证券账户；[withOpening] 为 true 时预置三股期初持仓，总成本为 341。
/// 现金固定为 5,000，所有价格仅用于验算；不读取用户账目或请求真实行情。
Future<VeriFinController> _removalController({bool withOpening = true}) async {
  final controller = await makeController();
  addTearDown(controller.dispose);
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '5000',
      openedAt: DateTime(2026, 10, 1),
      securities: [avgoFixture],
      openingHoldings: [
        if (withOpening)
          StockHolding(
            securityId: avgoFixture.id,
            short: false,
            quantity: '3',
            cost: '341',
          ),
      ],
      manualPrices: {avgoFixture.id: '325.48'},
    ),
    isTrue,
  );
  return controller;
}

/// 显示真实持仓页；[width] 和 [scale] 同时作用于删除确认及成本编辑路由。
/// 每个用例结束后恢复测试屏幕与字号，避免影响其他页面用例。
Future<void> _pumpRemovalPage(
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

/// 取得 [pageType] 的页面滚动区，不把弹窗内容滚动区或其他内部节点当成页面。
Finder _pageScroll(Type pageType) => find
    .descendant(of: find.byType(pageType), matching: find.byType(Scrollable))
    .first;

/// 将 [target] 在 [pageType] 中真正滚动到可点击位置，避免仅已构建却仍在屏幕外。
/// 最多继续拖动四十次，最后明确断言命中；不屏蔽点击警告。
Future<void> _revealRemovalAction(
  WidgetTester tester,
  Finder target,
  Type pageType,
) async {
  final scroll = _pageScroll(pageType);
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

/// 点击持仓卡的清除入口；[feedbackMessage] 非空时等待错误提示出现而非结束其倒计时。
/// 受限记录不弹确认，调用者仍须断言对应的用户可见反馈和原有数据。
Future<void> _openRemoval(
  WidgetTester tester, {
  String? feedbackMessage,
}) async {
  final action = find.widgetWithText(TextButton, '清除持仓');
  await _revealRemovalAction(tester, action, InvestmentPage);
  await tester.tap(action);
  if (feedbackMessage == null) {
    await tester.pumpAndSettle();
  } else {
    await _waitForRemovalFeedback(tester, feedbackMessage);
  }
}

/// 点击确认框内的 [label] 按钮；操作必须可点击，不能绕过真正的删除确认。
/// [feedbackMessage] 指定需要观察的错误提示，避免等待动画完全停止时提示已消失。
Future<void> _confirmRemoval(
  WidgetTester tester, {
  String label = '清除持仓',
  String? feedbackMessage,
}) async {
  final action = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.widgetWithText(FilledButton, label),
  );
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  await tester.tap(action);
  if (feedbackMessage == null) {
    await tester.pumpAndSettle();
  } else {
    await _waitForRemovalFeedback(tester, feedbackMessage);
  }
}

/// 最多推进两秒直到 [message] 真实渲染，再完成入场动画并验证提示处于可见区域。
/// 根反馈使用持续倒计时动画；这里不能 pumpAndSettle，否则会把八秒提示直接等到消失。
Future<void> _waitForRemovalFeedback(
  WidgetTester tester,
  String message,
) async {
  final feedback = find.textContaining(message);
  for (
    var attempt = 0;
    attempt < 20 && feedback.evaluate().isEmpty;
    attempt++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 240));
  expect(feedback.hitTestable(), findsOneWidget);
}

/// 返回删除说明原文，检查范围及现金预览使用页面真实文案而非内部计算结果。
String _removalMessage(WidgetTester tester) =>
    tester.widget<Text>(find.textContaining('将删除当前账户中该证券')).data!;

/// 验证清除和单独删除期初持仓的真实用户流程，所有写入都发生在隔离测试仓储。
void main() {
  useTestDatabases();

  for (final layout in [
    (width: 393.0, scale: 1.0),
    (width: 360.0, scale: 1.5),
  ]) {
    testWidgets('期初持仓清除先确认范围，取消不写入，确认后消失 ${layout.width}/${layout.scale}', (
      tester,
    ) async {
      final controller = await _removalController();
      final account = investmentAccountFixture();
      final original = controller.investmentFor(account.id)!;
      await _pumpRemovalPage(
        tester,
        controller,
        width: layout.width,
        scale: layout.scale,
      );
      await _openRemoval(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue,
      );
      final message = _removalMessage(tester);
      expect(message, contains('博通 · AVGO'));
      expect(message, contains('期初 1 条'));
      expect(message, contains('投资交易 0 条'));
      expect(
        message,
        contains(
          '现金：${formatUserMoney(5000, 'USD')} → ${formatUserMoney(5000, 'USD')}',
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(identical(controller.investmentFor(account.id), original), isTrue);
      expect(
        controller
            .investmentProjection(account.id)!
            .positions
            .single
            .quantity
            .toString(),
        '3',
      );

      await _openRemoval(tester);
      await _confirmRemoval(tester);
      final cleared = controller.investmentFor(account.id)!;
      expect(cleared.openingHoldings, isEmpty);
      expect(cleared.events, isEmpty);
      expect(controller.investmentProjection(account.id)!.positions, isEmpty);
      expect(controller.accountBalance(account), 5000);
      expect(find.text('博通 · AVGO'), findsNothing);
      expect(find.widgetWithText(TextButton, '清除持仓'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('交易产生的持仓可清除，先预览现金变化再删除相关买入记录', (tester) async {
    final controller = await _removalController(withOpening: false);
    final account = investmentAccountFixture();
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: avgoFixture,
        event: stockEventFixture('buy', StockEventKind.buy, '3', '300'),
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4100);
    await _pumpRemovalPage(tester, controller);
    await _openRemoval(tester);
    final message = _removalMessage(tester);
    expect(message, contains('期初 0 条'));
    expect(message, contains('投资交易 1 条'));
    expect(
      message,
      contains(
        '现金：${formatUserMoney(4100, 'USD')} → ${formatUserMoney(5000, 'USD')}',
      ),
    );
    expect(controller.investmentFor(account.id)!.events, hasLength(1));
    await _confirmRemoval(tester);
    expect(controller.investmentFor(account.id)!.events, isEmpty);
    expect(controller.investmentProjection(account.id)!.positions, isEmpty);
    expect(controller.accountBalance(account), 5000);
    expect(controller.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成本页单独删除期初持仓，保留后续买入且不保存当前成本草稿', (tester) async {
    final controller = await _removalController();
    final account = investmentAccountFixture();
    final event = stockEventFixture(
      'later-buy',
      StockEventKind.buy,
      '2',
      '300',
    );
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: avgoFixture,
        event: event,
      ),
      isTrue,
    );
    await _pumpRemovalPage(tester, controller);
    final edit = find.widgetWithText(TextButton, '更正期初持仓');
    await _revealRemovalAction(tester, edit, InvestmentPage);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('stock-opening-unit-cost'));
    await tester.ensureVisible(input);
    await tester.enterText(input, '341');
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(TextButton, '删除期初持仓');
    await _revealRemovalAction(tester, remove, StockOpeningCostPage);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.textContaining('未保存的成本草稿不会保存'), findsOneWidget);
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '341',
    );
    await _confirmRemoval(tester, label: '删除');
    expect(find.byType(StockOpeningCostPage), findsNothing);
    final result = controller.investmentFor(account.id)!;
    expect(result.openingHoldings, isEmpty);
    expect(result.events.single.toJson(), event.toJson());
    final holding = controller
        .investmentProjection(account.id)!
        .positions
        .single;
    expect(holding.quantity.toString(), '2');
    expect(holding.cost.toString(), '600');
    expect(controller.accountBalance(account), 4400);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认期间成本资料已变化时拒绝旧确认，保留最新记录', (tester) async {
    final controller = await _removalController();
    final account = investmentAccountFixture();
    await _pumpRemovalPage(tester, controller);
    await _openRemoval(tester);
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '400',
      ),
      isTrue,
    );
    final updated = controller.investmentFor(account.id)!;
    await tester.pumpAndSettle();
    await _confirmRemoval(tester, feedbackMessage: '未删除：资料已变化或保存失败');
    expect(identical(controller.investmentFor(account.id), updated), isTrue);
    expect(updated.openingHoldings.single.cost, '400');
    expect(
      controller
          .investmentProjection(account.id)!
          .positions
          .single
          .quantity
          .toString(),
      '3',
    );
    expect(find.textContaining('未删除：资料已变化或保存失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('成本页已过期时拒绝删除期初，不打开确认也不删除最新持仓', (tester) async {
    final controller = await _removalController();
    final account = investmentAccountFixture();
    await _pumpRemovalPage(tester, controller);
    final edit = find.widgetWithText(TextButton, '更正期初持仓');
    await _revealRemovalAction(tester, edit, InvestmentPage);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('stock-opening-unit-cost'));
    await tester.ensureVisible(input);
    await tester.enterText(input, '341');
    await tester.pumpAndSettle();

    // 模拟页面打开后另一操作已更正成本；旧页面仍保存自己的草稿与原聚合身份。
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '400',
      ),
      isTrue,
    );
    final updated = controller.investmentFor(account.id)!;
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(TextButton, '删除期初持仓');
    await _revealRemovalAction(tester, remove, StockOpeningCostPage);
    await tester.tap(remove);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(StockOpeningCostPage), findsOneWidget);
    expect(find.text('持仓资料已变化，请返回后重新打开期初持仓更正。当前草稿尚未保存。'), findsOneWidget);
    expect(identical(controller.investmentFor(account.id), updated), isTrue);
    expect(updated.openingHoldings.single.cost, '400');
    expect(updated.openingHoldings.single.quantity, '3');
    expect(tester.widget<TextField>(input).controller!.text, '341');
    expect(controller.accountBalance(account), 5000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有关联转移时说明原因，不弹出删除确认也不修改任一账户', (tester) async {
    final controller = await _removalController();
    final account = investmentAccountFixture();
    final target = investmentAccountFixture(id: 'stock-target');
    controller.addAccount(target);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: target.id,
        openingCash: '100',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
    expect(
      await controller.transferStock(
        fromAccountId: account.id,
        toAccountId: target.id,
        securityId: avgoFixture.id,
        quantity: '1',
        short: false,
        occurredAt: DateTime(2026, 10, 3),
        batchId: 'transfer-removal-ui',
      ),
      isTrue,
    );
    final sourceBefore = controller.investmentFor(account.id)!;
    final targetBefore = controller.investmentFor(target.id)!;
    await _pumpRemovalPage(tester, controller);
    await _openRemoval(tester, feedbackMessage: '该证券有关联的跨账户转移');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('该证券有关联的跨账户转移'), findsOneWidget);
    expect(
      identical(controller.investmentFor(account.id), sourceBefore),
      isTrue,
    );
    expect(
      identical(controller.investmentFor(target.id), targetBefore),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });
}
