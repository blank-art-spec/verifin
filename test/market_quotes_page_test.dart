import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/market_quotes_page.dart';
import 'package:verifin/pages/app_lock_gate.dart';
import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 创建零网络副作用的持仓上下文；只有显式传入的本地适配器能通过测试门禁。
Future<({VeriFinController controller, Account account})> quoteController({
  FixtureQuoteAdapter? adapter,
  LocalKeyValueStore? store,
}) async {
  final c = await VeriFinController.create(
    store ?? LocalKeyValueStore(),
    repository: InMemoryLedgerRepository(),
    marketQuoteClient: MarketQuoteClient(
      adapters: adapter == null ? const [] : [adapter],
    ),
  );
  final a = investmentAccountFixture();
  c.addAccount(a);
  await c.waitForPendingWrites();
  await c.enableInvestment(
    accountId: a.id,
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
  );
  return (controller: c, account: a);
}

void main() {
  useTestDatabases();
  test('冷启动未打开行情页就恢复，也必须清除上次设备缓存而非复活旧价', () async {
    final store = LocalKeyValueStore(),
        adapter = FixtureQuoteAdapter(
          (_) async => [stockQuote(DateTime.now())],
        );
    final fixture = await quoteController(adapter: adapter, store: store),
        first = fixture.controller;
    await first.setInvestmentMarketPrice(
      fixture.account.id,
      avgoFixture.id,
      true,
    );
    final p = first.investmentFor(fixture.account.id)!,
        sync = first.investmentQuoteSync;
    await sync.configure(enabled: true, automatic: false);
    sync.setVisible(p);
    expect(await sync.refresh(p, isCurrent: () => true), isTrue);
    final raw = first.exportDataJson();
    first.dispose();
    final cold = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
    );
    addTearDown(cold.dispose);
    cold.importDataJson(raw);
    await cold.waitForPendingWrites();
    final restored = cold.investmentFor(fixture.account.id)!;
    expect(cold.investmentQuoteSync.quotesFor(restored), isEmpty);
    expect(
      cold.accountAssetValue(
        cold.accounts.singleWhere((a) => a.id == fixture.account.id),
      ),
      10600,
    );
  });
  testWidgets('后台创建行情页不联网，回前台才核对授权刷新', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [
        MarketQuote.fromJson({
          ...stockQuote(DateTime.now()).toJson(),
          'tradeState': 'closed',
          'delayMinutes': 15,
        }),
      ],
    );
    final ready = await quoteController(adapter: adapter), c = ready.controller;
    addTearDown(c.dispose);
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: MarketQuotesPage(accountId: ready.account.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(adapter.requests, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(adapter.requests, 1);
    expect(find.text('来源标记：休市'), findsOneWidget);
    expect(find.text('来源声明延迟：15 分钟'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  test('成交页填写参考价同样撤销该证券行情选择，后续刷新不覆盖', () async {
    final fixture = await quoteController(
      adapter: FixtureQuoteAdapter((_) async => [stockQuote(DateTime.now())]),
    );
    final c = fixture.controller, a = fixture.account;
    addTearDown(c.dispose);
    await c.setInvestmentMarketPrice(a.id, avgoFixture.id, true);
    expect(
      await c.saveStockEvent(
        accountId: a.id,
        security: avgoFixture,
        event: stockEventFixture('dividend', StockEventKind.dividend, '0', '1'),
        referencePrice: '350',
      ),
      isTrue,
    );
    expect(c.investmentFor(a.id)!.marketPriceIds, isEmpty);
    expect(c.accountAssetValue(a), 10701);
  });
  test('行情只更新估值，手填原值/真实事件/现金不变；切回手填持续覆盖', () async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final fixture = await quoteController(adapter: adapter),
        c = fixture.controller,
        a = fixture.account;
    addTearDown(c.dispose);
    expect(
      await c.setInvestmentMarketPrice(a.id, avgoFixture.id, true),
      isTrue,
    );
    final p = c.investmentFor(a.id)!, sync = c.investmentQuoteSync;
    await sync.configure(enabled: true, automatic: false);
    sync.setVisible(p);
    expect(
      await sync.refresh(
        p,
        isCurrent: () => identical(p, c.investmentFor(a.id)),
      ),
      isTrue,
    );
    expect(c.accountBalance(a), 10000);
    expect(c.accountAssetValue(a), 10660);
    expect(c.investmentFor(a.id)!.manualPrices[avgoFixture.id], '300');
    expect(c.entries, isEmpty);
    final exported = jsonDecode(c.exportDataJson()) as Map;
    final data = exported['data'] as Map;
    expect(data.containsKey('quoteCache'), isFalse);
    expect(data.containsKey('quoteSettings'), isFalse);
    await sync.configure(enabled: false, automatic: false);
    expect(c.accountAssetValue(a), 10660);
    expect(await c.setStockReferencePrice(a.id, avgoFixture.id, '350'), isTrue);
    expect(c.accountAssetValue(a), 10700);
    expect(c.investmentFor(a.id)!.marketPriceIds, isEmpty);
    c.importDataJson(c.exportDataJson(), dryRun: true);
    expect(sync.quotesFor(c.investmentFor(a.id)!), isNotEmpty);
    c.importDataJson(c.exportDataJson());
    await c.waitForPendingWrites();
    expect(sync.quotesFor(c.investmentFor(a.id)!), isEmpty);
  });

  testWidgets('无准入来源默认关闭，清楚显示限制，窄屏不会发请求', (tester) async {
    final fixture = await quoteController(), c = fixture.controller;
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: MarketQuotesPage(accountId: fixture.account.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('来源尚未通过自动估值门禁'), findsWidgets);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '开启参考行情联网'),
          )
          .onChanged,
      isNull,
    );
    expect(c.investmentQuoteSync.state.value.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('锁屏阻止当前页刷新，解锁后请求；退后台停止后不接收页面旧结果', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final fixture = await quoteController(adapter: adapter),
        c = fixture.controller;
    addTearDown(c.dispose);
    await c.investmentQuoteSync.configure(enabled: true, automatic: true);
    Widget app(bool unlocked) => VeriFinScope(
      controller: c,
      child: zhMaterialApp(
        home: AppUnlockScope(
          unlocked: unlocked,
          child: MarketQuotesPage(accountId: fixture.account.id),
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
    await tester.pump(const Duration(minutes: 6));
    expect(adapter.requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    // 页面定时器在销毁时取消，测试结束不会留下周期任务。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
