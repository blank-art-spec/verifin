import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/market_quotes_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 为行情页面构造隔离上下文，不调用真实网络，也不复用生产来源门禁。
/// [enabled] 决定是否初始化证券组合，[holdings] 仅在组合启用时加入固定持仓；
/// [adapter] 用请求计数验证失效页面即使设备已授权联网也不会发送旧账户请求。
Future<({VeriFinController controller, Account account})> _makeContext({
  bool enabled = false,
  bool holdings = false,
  FixtureQuoteAdapter? adapter,
}) async {
  final c = await VeriFinController.create(
    LocalKeyValueStore(),
    repository: InMemoryLedgerRepository(),
    marketQuoteClient: MarketQuoteClient(
      adapters: adapter == null ? const [] : [adapter],
    ),
  );
  final account = investmentAccountFixture();
  c.addAccount(account);
  await c.waitForPendingWrites();
  if (enabled) {
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: holdings ? const [avgoFixture] : const [],
        openingHoldings: holdings
            ? [
                StockHolding(
                  securityId: avgoFixture.id,
                  short: false,
                  quantity: '2',
                  cost: '600',
                ),
              ]
            : const [],
        manualPrices: holdings ? {avgoFixture.id: '300'} : const {},
      ),
      isTrue,
    );
  }
  return (controller: c, account: account);
}

/// 从真实 Navigator 路由打开行情页，使返回按钮的效果可以被用户行为断言。
/// [tester] 驱动挂载与点击，[controller] 和 [accountId] 提供当前账本的实际账户；
/// [brightness]、[scale] 用于窄屏和字号组合，不修改应用偏好或账务。
Future<void> _openQuotes(
  WidgetTester tester,
  VeriFinController controller,
  String accountId, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: buildVeriFinTheme(brightness),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(scale)),
                        child: MarketQuotesPage(accountId: accountId),
                      ),
                    ),
                  );
                },
                child: const Text('打开行情测试页'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开行情测试页'));
  await tester.pumpAndSettle();
}

/// 注册无证券空态、行情不可用态和返回导航的行为用例；不编译或安装 Android 应用。
void main() {
  useTestDatabases();

  testWidgets('未录入证券也保留行情入口，点击显示正常空态且不创建组合', (tester) async {
    final ready = await _makeContext();
    addTearDown(ready.controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: ready.controller,
        child: zhMaterialApp(home: InvestmentPage(accountId: ready.account.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('启用证券持仓'), findsOneWidget);
    expect(find.byTooltip('参考行情'), findsOneWidget);
    await tester.tap(find.byTooltip('参考行情'));
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(
      tester.element(find.byType(MarketQuotesPage)),
    );
    expect(find.text(l.marketNoSecurities), findsOneWidget);
    expect(find.text(l.investSaveError), findsNothing);
    expect(find.text(l.entryBookUnavailable), findsNothing);
    expect(ready.controller.investmentFor(ready.account.id), isNull);
    expect(ready.controller.entries, isEmpty);
    await tester.tap(find.byTooltip(l.commonBack));
    await tester.pumpAndSettle();
    expect(find.byType(MarketQuotesPage), findsNothing);
    expect(find.text('启用证券持仓'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('尚无组合也是未录入证券空态，已开启联网时仍不发请求且可返回', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final ready = await _makeContext(adapter: adapter);
    final c = ready.controller;
    addTearDown(c.dispose);
    await c.investmentQuoteSync.configure(enabled: true, automatic: true);
    await _openQuotes(tester, c, ready.account.id);
    final l = AppLocalizations.of(
      tester.element(find.byType(MarketQuotesPage)),
    );
    expect(find.text(l.marketTitle), findsWidgets);
    expect(find.byType(VeriPage), findsOneWidget);
    expect(find.text(l.marketNoSecurities), findsOneWidget);
    expect(find.text(l.investSaveError), findsNothing);
    expect(find.byType(CompactSwitchRow), findsNothing);
    expect(adapter.requests, 0);
    expect(c.investmentFor(ready.account.id), isNull);
    expect(c.entries, isEmpty);
    await tester.tap(find.byTooltip(l.commonBack));
    await tester.pumpAndSettle();
    expect(find.byType(MarketQuotesPage), findsNothing);
    expect(find.text('打开行情测试页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有空组合在自动刷新开启时仍显示未录入证券，不发送无目标查询', (tester) async {
    final adapter = FixtureQuoteAdapter(
      (_) async => [stockQuote(DateTime.now())],
    );
    final ready = await _makeContext(enabled: true, adapter: adapter);
    final c = ready.controller;
    addTearDown(c.dispose);
    await c.investmentQuoteSync.configure(enabled: true, automatic: true);
    await _openQuotes(tester, c, ready.account.id);
    final l = AppLocalizations.of(
      tester.element(find.byType(MarketQuotesPage)),
    );
    await tester.scrollUntilVisible(
      find.text(l.marketNoSecurities),
      250,
      scrollable: firstVerticalScrollable(),
    );
    expect(find.text(l.marketNoSecurities), findsOneWidget);
    expect(find.text(l.investSaveError), findsNothing);
    expect(find.text(l.marketUnavailable), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, l.marketRefresh),
          )
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(minutes: 6));
    await tester.pumpAndSettle();
    expect(adapter.requests, 0);
    expect(c.investmentQuoteSync.state.value.status, QuoteSyncStatus.idle);
    expect(c.investmentFor(ready.account.id)!.securities, isEmpty);
    expect(c.investmentFor(ready.account.id)!.events, isEmpty);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有证券全部卖出时显示无持仓行情，不误称从未录入证券', (tester) async {
    final ready = await _makeContext(enabled: true, holdings: true);
    final c = ready.controller;
    addTearDown(c.dispose);
    expect(
      await c.saveStockEvent(
        accountId: ready.account.id,
        security: avgoFixture,
        event: stockEventFixture('close-all', StockEventKind.sell, '2', '300'),
        referencePrice: '300',
      ),
      isTrue,
    );
    await _openQuotes(tester, c, ready.account.id);
    final l = AppLocalizations.of(
      tester.element(find.byType(MarketQuotesPage)),
    );
    await tester.scrollUntilVisible(
      find.text(l.marketEmptyHoldings),
      250,
      scrollable: firstVerticalScrollable(),
    );
    expect(find.text(l.marketEmptyHoldings), findsOneWidget);
    expect(find.text(l.marketNoSecurities), findsNothing);
    expect(
      c.investmentFor(ready.account.id)!.securities.single.id,
      avgoFixture.id,
    );
    expect(tester.takeException(), isNull);
  });

  for (final deleted in [false, true]) {
    testWidgets(deleted ? '账户删除后行情页可返回且不保留旧证券' : '切换账本后行情页可返回且不泄漏旧证券', (
      tester,
    ) async {
      final adapter = FixtureQuoteAdapter(
        (_) async => [stockQuote(DateTime.now())],
      );
      final ready = await _makeContext(
        enabled: true,
        holdings: true,
        adapter: adapter,
      );
      final c = ready.controller;
      addTearDown(c.dispose);
      await _openQuotes(tester, c, ready.account.id);
      final l = AppLocalizations.of(
        tester.element(find.byType(MarketQuotesPage)),
      );
      if (deleted) {
        expect(await c.deleteAccount(ready.account.id), isNotNull);
      } else {
        c.addLedgerBook('另一个账本');
        await c.waitForPendingWrites();
      }
      await tester.pumpAndSettle();
      expect(find.text(l.entryBookUnavailable), findsOneWidget);
      expect(find.text(l.investSaveError), findsNothing);
      expect(find.text(avgoFixture.name), findsNothing);
      expect(find.text(avgoFixture.symbol), findsNothing);
      expect(find.byType(CompactSwitchRow), findsNothing);
      expect(adapter.requests, 0);
      await tester.tap(find.byTooltip(l.commonBack));
      await tester.pumpAndSettle();
      expect(find.byType(MarketQuotesPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [393.0, 360.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('$width / ${brightness.name} 大字号未录入证券有说明且全部内容可滚动', (
        tester,
      ) async {
        final ready = await _makeContext(enabled: true);
        final c = ready.controller;
        addTearDown(c.dispose);
        await tester.binding.setSurfaceSize(Size(width, 852));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _openQuotes(
          tester,
          c,
          ready.account.id,
          brightness: brightness,
          scale: 1.8,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(MarketQuotesPage)),
        );
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text(l.marketNoSecurities),
          250,
          scrollable: firstVerticalScrollable(),
        );
        expect(find.text(l.marketNoSecurities), findsOneWidget);
        final text = tester.widget<Text>(find.text(l.marketNoSecurities));
        expect(text.maxLines, isNull);
        expect(tester.takeException(), isNull);
        expect(c.investmentFor(ready.account.id)!.events, isEmpty);
        expect(c.investmentQuoteSync.state.value.enabled, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
