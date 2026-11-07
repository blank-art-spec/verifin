import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_session.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/market_quotes_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 模拟匿名期权来源的失败回退策略；所有价格只来自本地响应。
class _OptionSource extends FixtureQuoteAdapter {
  _OptionSource(super.respond) : super(support: (request) => request.option);

  @override
  bool get retainQuotesOnFailure => false;
}

MarketQuote _optionQuote(
  StockSecurity security,
  DateTime fetchedAt, {
  String price = '7',
}) => MarketQuote(
  securityId: security.id,
  source: '本地测试夹具',
  currency: 'USD',
  unit: QuotePriceUnit.premiumUnit,
  fetchedAt: fetchedAt,
  last: price,
  sourceTimeUnknown: true,
);

void main() {
  useTestDatabases();
  final now = DateTime.utc(2026, 11, 7, 12);
  final option = optionFixture();

  for (final closed in [false, true]) {
    test('${closed ? '已平仓' : '零持仓'}美股期权继续自动刷新，报价不创造资产持仓', () async {
      final p = optionPortfolioFixture(
        option,
        opening: [
          if (closed)
            StockHolding(
              securityId: option.id,
              short: false,
              quantity: '1',
              cost: '200',
            ),
        ],
        events: [
          if (closed)
            optionEventFixture(option, StockEventKind.optionSellClose),
        ],
      );
      final source = _OptionSource((_) async => [_optionQuote(option, now)]);
      final sync = InvestmentQuoteSync(
        store: LocalKeyValueStore(),
        client: MarketQuoteClient(adapters: [source]),
        clock: () => now,
      );
      addTearDown(sync.dispose);
      sync.reconcile([p]);
      final session = InvestmentQuoteSession(
        sync: sync,
        isCurrent: (candidate) => identical(candidate, p),
      );
      addTearDown(session.dispose);
      await sync.configure(enabled: true, automatic: true);
      session.update(active: true, portfolios: [p]);
      await session.refreshIfDue();
      expect(source.lastRequests.map((q) => q.securityId), [option.id]);
      expect(projectStocks(p, at: now).positions, isEmpty);
      expect(sync.quotesFor(p), isEmpty);
      expect(
        sync.quotesFor(p, includeConfiguredOptions: true)[option.id]!.last,
        '7',
      );
    });
  }

  for (final throwsError in [false, true]) {
    test('期权${throwsError ? '请求失败' : '无有效价'}清旧价并通知回退，股票缓存及手填保持', () async {
      var failing = false;
      final p = optionPortfolioFixture(
        option,
        opening: [
          for (final security in [option, avgoFixture])
            StockHolding(
              securityId: security.id,
              short: false,
              quantity: '1',
              cost: '200',
            ),
        ],
      );
      final original = jsonEncode(p.toJson());
      final options = _OptionSource((_) async {
        if (failing) {
          if (throwsError) throw StateError('本地失败');
          return [];
        }
        return [_optionQuote(option, now)];
      });
      final stocks = FixtureQuoteAdapter((_) async {
        if (failing) throw StateError('本地股票失败');
        return [stockQuote(now)];
      }, support: (q) => !q.option);
      var notifications = 0;
      final sync = InvestmentQuoteSync(
        store: LocalKeyValueStore(),
        client: MarketQuoteClient(adapters: [options, stocks]),
        clock: () => now,
      )..onPricesChanged = () => notifications++;
      addTearDown(sync.dispose);
      sync.reconcile([p]);
      sync.setVisible(p);
      await sync.configure(enabled: true, automatic: false);
      expect(await sync.refresh(p, isCurrent: () => true), isTrue);
      expect(sync.quotesFor(p), hasLength(2));
      failing = true;
      expect(await sync.refresh(p, isCurrent: () => true), isFalse);
      expect(sync.quotesFor(p).keys, [avgoFixture.id]);
      expect(sync.quotesFor(p)[avgoFixture.id]!.last, '330');
      expect(notifications, 2, reason: '只有旧报价失效也必须通知资产回到手填');
      expect(jsonEncode(p.toJson()), original);
      expect(p.manualPrices[option.id], '3');
    });
  }

  test('后续请求等待中取消，前面合约的失败不清缓存也不保存部分结果', () async {
    final waiting = Completer<List<MarketQuote>>();
    var failing = false, current = true;
    final p = optionPortfolioFixture(
      option,
      opening: [
        for (final security in [option, avgoFixture])
          StockHolding(
            securityId: security.id,
            short: false,
            quantity: '1',
            cost: '200',
          ),
      ],
    ).copyWith(securities: [option, avgoFixture]);
    final options = _OptionSource(
      (_) async => failing ? [] : [_optionQuote(option, now)],
    );
    final stocks = FixtureQuoteAdapter(
      (_) => failing ? waiting.future : Future.value([stockQuote(now)]),
      support: (q) => !q.option,
    );
    final store = LocalKeyValueStore();
    final sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [options, stocks]),
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.reconcile([p]);
    sync.setVisible(p);
    await sync.configure(enabled: true, automatic: false);
    await sync.refresh(p, isCurrent: () => current);
    final cached = store.read('investment_quote_cache_v1');
    failing = true;
    final pending = sync.refresh(p, isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    waiting.complete([]);
    expect(await pending, isFalse);
    expect(sync.quotesFor(p)[option.id]!.last, '7');
    expect(store.read('investment_quote_cache_v1'), cached);
  });

  test('未知源时间按观察抓取顺序更新，较早观察不覆盖且源时间一直为空', () async {
    var observation = now;
    var price = '7';
    final p = optionPortfolioFixture(option);
    final source = _OptionSource(
      (_) async => [_optionQuote(option, observation, price: price)],
    );
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: MarketQuoteClient(adapters: [source]),
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.reconcile([p]);
    sync.setVisible(p);
    await sync.configure(enabled: true, automatic: false);
    await sync.refresh(p, isCurrent: () => true);
    observation = now.subtract(const Duration(minutes: 10));
    price = '2';
    await sync.refresh(p, isCurrent: () => true);
    final quote = sync.quotesFor(p, includeConfiguredOptions: true)[option.id]!;
    expect(quote.last, '7');
    expect(quote.lastAt, isNull);
    expect(quote.reference(MarketQuoteRequest(option), now)!.time, isNull);
  });

  testWidgets('零持仓期权可选免密钥行情，显示未知源时间与独立抓取时间', (tester) async {
    final source = _OptionSource(
      (_) async => [_optionQuote(option, DateTime.now().toUtc())],
    );
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(adapters: [source]),
    );
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: [avgoFixture, option],
        manualPrices: {avgoFixture.id: '50', option.id: '3'},
      ),
      isTrue,
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: MarketQuotesPage(accountId: account.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(option.symbol),
      250,
      scrollable: firstVerticalScrollable(),
    );
    expect(find.text(option.symbol), findsOneWidget);
    final optionSwitch = find.byType(Switch).last;
    await tester.ensureVisible(optionSwitch);
    expect(tester.widget<Switch>(optionSwitch).onChanged, isNotNull);
    await tester.tap(optionSwitch);
    await tester.pumpAndSettle();
    expect(c.investmentFor(account.id)!.marketPriceIds, contains(option.id));
    await tester.scrollUntilVisible(
      find.text('报价时间未知'),
      150,
      scrollable: firstVerticalScrollable(),
    );
    expect(find.text('报价时间未知'), findsOneWidget);
    expect(find.text('抓取时间'), findsOneWidget);
    expect(find.text('美股期权行情'), findsNothing);
    expect(c.accountAssetValue(account), 10000);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
