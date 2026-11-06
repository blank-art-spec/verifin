import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';

/// 模拟应用升级前后的期权来源；仅返回本地夹具，不请求任何真实合约。
class _MigratingOptionSource extends MarketQuoteAdapter {
  /// [source] 区分旧实时快照与新延迟成交；[now] 固定抓取时间以重现时间倒退。
  _MigratingOptionSource(this.source, this.now);

  String source;
  final DateTime now;
  bool empty = false;
  bool get delayed => source == 'Alpaca OPRA Delayed';

  @override
  QuoteSourceCapability get capability =>
      QuoteSourceCapability(source, approved: true, reviewNote: '本地迁移测试');

  /// 只支持本地期权，使同一组合的股票继续由独立来源提供。
  @override
  bool supports(MarketQuoteRequest request) => request.option;

  /// [requests] 来自当前组合；旧价故意比新价更新，验证来源切换不能比较旧时刻。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async =>
      empty
      ? []
      : [
          for (final request in requests)
            MarketQuote(
              securityId: request.securityId,
              source: source,
              currency: 'USD',
              unit: QuotePriceUnit.premiumUnit,
              fetchedAt: now,
              last: delayed ? '2' : '9',
              lastAt: now.subtract(Duration(minutes: delayed ? 20 : 1)),
              delayMinutes: delayed ? 15 : null,
            ),
        ];
}

/// 验证来源切换只改变设备参考价，保留股票缓存、联网设置和权威组合。
void main() {
  final now = DateTime.utc(2026, 11, 6, 12);
  final option = optionFixture();
  final portfolio = optionPortfolioFixture(
    option,
    opening: [
      StockHolding(
        securityId: option.id,
        short: false,
        quantity: '1',
        cost: '100',
      ),
      StockHolding(
        securityId: avgoFixture.id,
        short: false,
        quantity: '1',
        cost: '300',
      ),
    ],
  );

  for (final restart in [false, true]) {
    test('${restart ? '冷启动' : '运行中'}切换延迟来源可接收较早价格，不改股票缓存和组合', () async {
      final store = LocalKeyValueStore();
      final source = _MigratingOptionSource('Alpaca OPRA', now);
      final stock = FixtureQuoteAdapter(
        (_) async => [stockQuote(now)],
        support: (request) => !request.option,
      );
      final client = MarketQuoteClient(adapters: [source, stock]);
      var sync = InvestmentQuoteSync(
        store: store,
        client: client,
        clock: () => now,
      );
      addTearDown(() => sync.dispose());
      final original = jsonEncode(portfolio.toJson());
      sync.reconcile([portfolio]);
      sync.setVisible(portfolio);
      await sync.configure(enabled: true, automatic: false);
      expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
      expect(sync.quotesFor(portfolio)[option.id]!.last, '9');

      source.source = 'Alpaca OPRA Delayed';
      if (restart) {
        sync.dispose();
        sync = InvestmentQuoteSync(
          store: store,
          client: client,
          clock: () => now,
        );
        sync.reconcile([portfolio]);
        sync.setVisible(portfolio);
      }
      expect(sync.state.value.enabled, isTrue);
      expect(sync.quotesFor(portfolio).containsKey(option.id), isFalse);
      expect(sync.quotesFor(portfolio)[avgoFixture.id]!.last, '330');
      expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
      final price = sync.quotesFor(portfolio)[option.id]!;
      expect(price.last, '2');
      expect(price.lastAt, now.subtract(const Duration(minutes: 20)));
      expect(price.delayMinutes, 15);
      expect(jsonEncode(portfolio.toJson()), original);
    });
  }

  test('升级后新来源无成交时清除退役缓存，不清除股票价或联网偏好', () async {
    final store = LocalKeyValueStore();
    final source = _MigratingOptionSource('Alpaca OPRA', now);
    final client = MarketQuoteClient(
      adapters: [
        source,
        FixtureQuoteAdapter(
          (_) async => [stockQuote(now)],
          support: (request) => !request.option,
        ),
      ],
    );
    var sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => now,
    );
    addTearDown(() => sync.dispose());
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    await sync.configure(enabled: true, automatic: false);
    await sync.refresh(portfolio, isCurrent: () => true);
    sync.dispose();
    source.source = 'Alpaca OPRA Delayed';
    source.empty = true;
    sync = InvestmentQuoteSync(store: store, client: client, clock: () => now);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    await sync.refresh(portfolio, isCurrent: () => true);
    expect(sync.state.value.enabled, isTrue);
    expect(sync.quotesFor(portfolio).keys, [avgoFixture.id]);
    final cache = jsonDecode(store.read('investment_quote_cache_v1')!) as Map;
    expect(
      (cache['rows'] as List).map(
        (row) => ((row as Map)['quote'] as Map)['source'],
      ),
      ['本地测试夹具'],
    );
  });
}
