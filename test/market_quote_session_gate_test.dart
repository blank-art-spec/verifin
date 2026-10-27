import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/main.dart';
import 'package:verifin/pages/app_lock_gate.dart';
import 'package:verifin/pages/market_quote_session_gate.dart';
import 'package:verifin/pages/market_quotes_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 添加 [accountId] 对应的真实测试聚合；只走 Controller 命令，不直接改内存集合。
Future<void> _addPortfolio(
  VeriFinController controller,
  String accountId,
) async {
  final account = investmentAccountFixture(id: accountId);
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
      securities: const [avgoFixture],
      openingHoldings: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '2',
          cost: '600',
        ),
      ],
      manualPrices: {avgoFixture.id: '300'},
    ),
    isTrue,
  );
}

/// 创建已明确授权行情的控制器；[consent] 用于证明未过隐私门卫时不请求来源。
/// 构造和数据准备均不联网，测试适配器只返回内存中的固定公开字段。
Future<VeriFinController> _controller(
  FixtureQuoteAdapter adapter, {
  bool consent = true,
}) async {
  final store = LocalKeyValueStore()
    ..write('verifin.locale.v1', 'zh')
    ..write('verifin.onboarding.v1', 'true')
    ..write('verifin.privacy_consent.v1', consent ? 'true' : 'false');
  final controller = await VeriFinController.create(
    store,
    repository: InMemoryLedgerRepository(),
    marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
  );
  await _addPortfolio(controller, 'first');
  await controller.investmentQuoteSync.configure(
    enabled: true,
    automatic: true,
  );
  expect(adapter.requests, 0);
  return controller;
}

/// 注册应用装配、锁屏和前后台桥接行为；所有来源都是本地夹具。
void main() {
  useTestDatabases();

  testWidgets('正式应用打开后仍在首页就刷新，不必先进入行情页', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final controller = await _controller(adapter);
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.byType(MarketQuotesPage), findsNothing);
    expect(adapter.requests, 1);
    expect(
      controller.investmentQuoteSync.quotesFor(
        controller.investmentFor('first')!,
      ),
      isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('未同意隐私时即使设备开关已开也不创建自动联网会话', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final controller = await _controller(adapter, consent: false);
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();
    expect(adapter.requests, 0);
    expect(controller.investmentQuoteSync.applicationManaged, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('锁定不请求，解锁后检查；后台新增到期账户仍等待回前台', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final controller = await _controller(adapter);
    addTearDown(controller.dispose);

    /// [unlocked] 仅模拟门卫公布的状态，不绕过应用真实认证逻辑。
    Widget app(bool unlocked) => VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: AppUnlockScope(
          unlocked: unlocked,
          child: const MarketQuoteSessionGate(child: Text('首页占位内容')),
        ),
      ),
    );

    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    expect(adapter.requests, 0);
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(adapter.requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    // 新账户没有任何冷却，若后台门卫失效，它会立刻产生第二次来源请求。
    await _addPortfolio(controller, 'second');
    await tester.pumpAndSettle();
    expect(adapter.requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(adapter.requests, 2);
    expect(
      controller.investmentQuoteSync.quotesFor(
        controller.investmentFor('second')!,
      ),
      isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
