import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';

void main() {
  final t = DateTime.utc(2026, 10, 24, 12);
  test('较慢开启写入与稍后关闭并发，最终授权和冷启动均保持关闭', () async {
    final store = PausingQuoteStore(),
        client = MarketQuoteClient(
          adapters: [
            FixtureQuoteAdapter((_) async => [stockQuote(t)]),
          ],
        );
    final sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => t,
    );
    addTearDown(sync.dispose);
    final enabling = sync.configure(enabled: true, automatic: true);
    final disabling = sync.configure(enabled: false, automatic: false);
    expect(sync.state.value.enabled, isFalse);
    store.release.complete();
    expect(await enabling, isFalse);
    expect(await disabling, isTrue);
    expect(sync.state.value.enabled, isFalse);
    final restored = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => t,
    );
    addTearDown(restored.dispose);
    expect(restored.state.value.enabled, isFalse);
  });
  InvestmentPortfolio holding() => portfolioFixture(
    opening: [
      StockHolding(
        securityId: avgoFixture.id,
        short: false,
        quantity: '2',
        cost: '600',
      ),
    ],
  );

  test('空账本冷启动也清除已删除账户的孤立报价缓存', () async {
    final store = LocalKeyValueStore(),
        client = MarketQuoteClient(
          adapters: [
            FixtureQuoteAdapter((_) async => [stockQuote(t)]),
          ],
        ),
        p = holding();
    var sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => t,
    );
    addTearDown(() => sync.dispose());
    sync.reconcile([p]);
    await sync.configure(enabled: true, automatic: false);
    sync.setVisible(p);
    expect(await sync.refresh(p, isCurrent: () => true), isTrue);
    sync.dispose();
    sync = InvestmentQuoteSync(store: store, client: client, clock: () => t);
    sync.reconcile([]);
    expect(sync.quotesFor(p), isEmpty);
    await Future<void>.delayed(Duration.zero);
  });
  test('第一来源等待中关闭，随后失败时也不能继续请求下一来源', () async {
    final pending = Completer<List<MarketQuote>>();
    final first = FixtureQuoteAdapter(
      (_) => pending.future,
      support: (q) => q.symbol == 'AVGO',
    );
    final second = FixtureQuoteAdapter(
      (_) async => [],
      support: (q) => q.symbol == 'TEST-AVGO-SECOND',
    );
    const other = StockSecurity(
      symbol: 'TEST-AVGO-SECOND',
      name: '第二来源验收',
      market: StockMarket.us,
      currencyCode: 'USD',
    );
    final p = holding().copyWith(
      securities: [avgoFixture, other],
      openingHoldings: [
        ...holding().openingHoldings,
        StockHolding(
          securityId: other.id,
          short: false,
          quantity: '1',
          cost: '10',
        ),
      ],
      manualPrices: {avgoFixture.id: '300', other.id: '10'},
    );
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: MarketQuoteClient(adapters: [first, second]),
      clock: () => t,
    );
    addTearDown(sync.dispose);
    sync.reconcile([p]);
    await sync.configure(enabled: true, automatic: false);
    sync.setVisible(p);
    final running = sync.refresh(p, isCurrent: () => true);
    await sync.configure(enabled: false, automatic: false);
    pending.completeError(StateError('第一来源模拟失败'));
    expect(await running, isFalse);
    expect(first.requests, 1);
    expect(second.requests, 0);
  });

  test('生产来源门禁未通过时不可开启，无网络或伪造演示报价', () async {
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: const MarketQuoteClient(),
      clock: () => t,
    );
    addTearDown(sync.dispose);
    expect(await sync.configure(enabled: true, automatic: true), isFalse);
    sync.reconcile([holding()]);
    sync.setVisible(holding());
    expect(await sync.refresh(holding(), isCurrent: () => true), isFalse);
    expect(sync.quotesFor(holding()), isEmpty);
  });
  test('来源要求更长刷新间隔时遵守更严格冷却', () async {
    var now = t;
    final p = holding(),
        adapter = FixtureQuoteAdapter(
          (_) async => [stockQuote(now)],
          minimumInterval: const Duration(minutes: 10),
        );
    final store = LocalKeyValueStore();
    var sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => now,
    );
    addTearDown(() => sync.dispose());
    sync.reconcile([p]);
    await sync.configure(enabled: true, automatic: false);
    sync.setVisible(p);
    expect(await sync.refresh(p, isCurrent: () => true), isTrue);
    now = now.add(const Duration(minutes: 1));
    sync.dispose();
    sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => now,
    );
    sync.reconcile([p]);
    sync.setVisible(p);
    now = now.add(const Duration(minutes: 5));
    expect(await sync.refresh(p, isCurrent: () => true), isFalse);
    expect(adapter.requests, 1);
    now = now.add(const Duration(minutes: 5));
    expect(await sync.refresh(p, isCurrent: () => true), isTrue);
    expect(adapter.requests, 2);
  });

  test('明确源时间、币种与单位校验；期权双边中间价和最近成交降级', () {
    final s = optionFixture(), request = MarketQuoteRequest(optionFixture());
    final q = MarketQuote(
      securityId: s.id,
      source: '本地测试夹具',
      currency: 'USD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: t,
      bid: '2',
      ask: '4',
      bidAt: t,
      askAt: t,
    );
    expect(q.reference(request, t)!.price, '3');
    expect(q.reference(request, t)!.midpoint, isTrue);
    final zeroBid = MarketQuote(
      securityId: s.id,
      source: '本地测试夹具',
      currency: 'USD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: t,
      bid: '0',
      ask: '4',
      bidAt: t,
      askAt: t,
      last: '1',
      lastAt: t,
    );
    expect(zeroBid.reference(request, t)!.price, '1');
    expect(zeroBid.reference(request, t)!.midpoint, isFalse);
    final noTime = MarketQuote(
      securityId: s.id,
      source: '本地测试夹具',
      currency: 'USD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: t,
      bid: '2',
      ask: '4',
    );
    expect(noTime.reference(request, t), isNull);
    final wrong = MarketQuote(
      securityId: s.id,
      source: '本地测试夹具',
      currency: 'HKD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: t,
      last: '3',
      lastAt: t,
    );
    expect(wrong.reference(request, t), isNull);
    expect(
      stockQuote(
        t.add(const Duration(hours: 1)),
      ).reference(MarketQuoteRequest(avgoFixture), t),
      isNull,
    );
    expect(
      stockQuote(t, price: '0').reference(MarketQuoteRequest(avgoFixture), t),
      isNull,
    );
    expect(
      stockQuote(t, price: 'NaN').reference(MarketQuoteRequest(avgoFixture), t),
      isNull,
    );
    final inverted = MarketQuote(
      securityId: s.id,
      source: '本地测试夹具',
      currency: 'USD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: t,
      bid: '4',
      ask: '2',
      bidAt: t,
      askAt: t,
      last: '1.5',
      lastAt: t,
    );
    expect(inverted.reference(request, t)!.price, '1.5');
    expect(inverted.reference(request, t)!.midpoint, isFalse);
  });

  test('冷却、缓存冷启动、旧源时间不覆盖新值，断网继续保留旧时间', () async {
    var now = t, reported = t;
    var fail = false;
    final store = LocalKeyValueStore(), p = holding();
    final adapter = FixtureQuoteAdapter((_) async {
      if (fail) throw const FormatException('夹具失败');
      return [stockQuote(reported)];
    });
    final client = MarketQuoteClient(adapters: [adapter]);
    var sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => now,
    );
    sync.reconcile([p]);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    sync.setVisible(p);
    expect(await sync.refresh(p, isCurrent: () => true), isTrue);
    expect(adapter.lastRequests.single.symbol, 'AVGO');
    expect(await sync.refresh(p, isCurrent: () => true), isFalse);
    expect(adapter.requests, 1);
    sync.dispose();
    sync = InvestmentQuoteSync(store: store, client: client, clock: () => now);
    addTearDown(() => sync.dispose());
    sync.reconcile([p]);
    sync.setVisible(p);
    expect(sync.quotesFor(p).singleValue.last, '330');
    expect(await sync.refresh(p, isCurrent: () => true), isFalse);
    now = now.add(const Duration(minutes: 6));
    reported = t.subtract(const Duration(minutes: 1));
    await sync.refresh(p, isCurrent: () => true);
    expect(sync.quotesFor(p).singleValue.lastAt, t);
    now = now.add(const Duration(minutes: 6));
    fail = true;
    expect(await sync.refresh(p, isCurrent: () => true), isFalse);
    expect(sync.state.value.status, QuoteSyncStatus.failed);
    expect(sync.quotesFor(p).singleValue.lastAt, t);
  });

  test('关闭开关/离页/上下文失效阻止旧响应，且可再次正常刷新', () async {
    for (final mode in ['disable', 'leave', 'revision']) {
      final pending = Completer<List<MarketQuote>>(), p = holding();
      var current = true;
      final adapter = FixtureQuoteAdapter((_) => pending.future);
      final sync = InvestmentQuoteSync(
        store: LocalKeyValueStore(),
        client: MarketQuoteClient(adapters: [adapter]),
        clock: () => t,
      );
      sync.reconcile([p]);
      await sync.configure(enabled: true, automatic: true);
      sync.setVisible(p);
      final work = sync.refresh(p, isCurrent: () => current);
      if (mode == 'disable') {
        await sync.configure(enabled: false, automatic: false);
      }
      if (mode == 'leave') sync.setVisible(null);
      if (mode == 'revision') current = false;
      pending.complete([stockQuote(t)]);
      expect(await work, isFalse);
      expect(sync.quotesFor(p), isEmpty);
      expect(sync.state.value.status, isNot(QuoteSyncStatus.loading));
      sync.dispose();
    }
  });

  test('缓存保存失败不伪报持久化；准入撤销和恢复清缓存不回退手填事实', () async {
    final p = holding(), store = FailingQuoteStore();
    final adapter = FixtureQuoteAdapter((_) async => [stockQuote(t)]);
    final sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => t,
    );
    addTearDown(sync.dispose);
    sync.reconcile([p]);
    await sync.configure(enabled: true, automatic: false);
    sync.setVisible(p);
    store.failCache = true;
    expect(await sync.refresh(p, isCurrent: () => true), isTrue);
    expect(sync.state.value.status, QuoteSyncStatus.notCached);
    expect(sync.quotesFor(p).singleValue.last, '330');
    adapter.approved = false;
    expect(sync.quotesFor(p), isEmpty);
    adapter.approved = true;
    await sync.clearCache();
    expect(sync.state.value.status, QuoteSyncStatus.notCached);
    store.failCache = false;
    await sync.clearCache();
    expect(sync.state.value.status, QuoteSyncStatus.idle);
    expect(sync.quotesFor(p), isEmpty);
    expect(p.manualPrices[avgoFixture.id], '330');
  });
}

/// 明确断言测试集合只有一项，避免依赖任意映射遍历顺序。
extension _SingleQuote on Map<String, MarketQuote> {
  MarketQuote get singleValue => values.single;
}
