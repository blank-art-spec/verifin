import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';

/// 构造多个股票和期权真实持仓的本地夹具；定义中的 AVGO 没有持仓，不应请求。
/// [count] 决定持有身份数，[accountId]/[bookId] 只用于验证本地账户隔离。
InvestmentPortfolio _portfolio(
  int count, {
  String accountId = '私有账户',
  String bookId = defaultLedgerBookId,
}) {
  final securities = List.generate(count, (index) {
    final option = index.isOdd;
    return StockSecurity(
      symbol: 'TEST-${option ? 'OPTION' : 'STOCK'}-$index',
      name: '用户私有名称 $index',
      market: StockMarket.us,
      currencyCode: 'USD',
      option: option
          ? OptionContract(
              underlyingId: avgoFixture.id,
              expiry: '2026-12-18',
              right: OptionRight.call,
              strike: '50',
              premiumMultiplier: '100',
              settlement: OptionSettlement.physical,
              deliverableShares: '100',
              exerciseCash: '5000',
              specification: '本地测试规格，不发送真实端点',
              confirmed: true,
            )
          : null,
    );
  });
  return InvestmentPortfolio(
    accountId: accountId,
    bookId: bookId,
    currencyCode: 'USD',
    openedAt: DateTime.utc(2026, 10, 1),
    openingCash: '12345',
    securities: [...securities, avgoFixture],
    openingHoldings: [
      for (final security in securities)
        StockHolding(
          securityId: security.id,
          short: false,
          quantity: '7',
          cost: '9876',
        ),
    ],
  );
}

/// 只按公开请求生成带真实测试时间的报价；期权明确使用每权利金单位。
MarketQuote _quote(
  MarketQuoteRequest request,
  DateTime time, {
  String price = '10',
  String source = '本地测试夹具',
}) => MarketQuote(
  securityId: request.securityId,
  source: source,
  currency: request.currency,
  unit: request.option
      ? QuotePriceUnit.premiumUnit
      : request.fund
      ? QuotePriceUnit.fundUnit
      : QuotePriceUnit.share,
  fetchedAt: time,
  last: price,
  lastAt: time,
);

/// 为给定账务上下文启用本地夹具，调用方决定可见或应用前台范围。
Future<InvestmentQuoteSync> _sync(
  FixtureQuoteAdapter adapter,
  List<InvestmentPortfolio> portfolios,
  DateTime Function() clock, {
  LocalKeyValueStore? store,
  List<MarketQuoteAdapter> extraAdapters = const [],
}) async {
  final sync = InvestmentQuoteSync(
    store: store ?? LocalKeyValueStore(),
    client: MarketQuoteClient(adapters: [adapter, ...extraAdapters]),
    clock: clock,
  );
  sync.reconcile(portfolios);
  expect(await sync.configure(enabled: true, automatic: true), isTrue);
  addTearDown(sync.dispose);
  return sync;
}

/// 验证持仓完整分批、失败降级和取消边界；所有请求仅走本地适配器。
void main() {
  final start = DateTime.utc(2026, 11, 5, 4);

  test('45 个股票期权身份全部分批且串行，未持有定义不请求', () async {
    final portfolio = _portfolio(45);
    final original = jsonEncode(portfolio.toJson());
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final batches = <List<MarketQuoteRequest>>[];
    final adapter = FixtureQuoteAdapter((requests) async {
      batches.add(requests);
      if (batches.length == 1) {
        firstEntered.complete();
        await releaseFirst.future;
      }
      return [for (final request in requests) _quote(request, start)];
    }, support: (_) => true);
    final sync = await _sync(adapter, [portfolio], () => start);
    sync.setVisible(portfolio);
    var notifications = 0;
    sync.onPricesChanged = () => notifications++;
    final refreshing = sync.refresh(portfolio, isCurrent: () => true);
    await firstEntered.future;
    expect(batches, hasLength(1));
    expect(sync.state.value.status, QuoteSyncStatus.loading);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(batches, hasLength(1));
    releaseFirst.complete();
    expect(await refreshing, isTrue);
    expect(batches.map((batch) => batch.length), [20, 20, 5]);
    final requests = batches.expand((batch) => batch).toList();
    expect(
      requests.map((request) => request.securityId),
      portfolio.openingHoldings.map((holding) => holding.securityId),
    );
    expect(requests.where((request) => request.option), hasLength(22));
    expect(requests.every((request) => request.currency == 'USD'), isTrue);
    expect(
      requests.every((request) => request.market == StockMarket.us),
      isTrue,
    );
    expect(requests.any((request) => request.fund), isFalse);
    expect(requests.map((request) => request.symbol), isNot(contains('AVGO')));
    expect(sync.quotesFor(portfolio), hasLength(45));
    expect(sync.state.value.changed, 45);
    expect(sync.state.value.status, QuoteSyncStatus.ready);
    expect(notifications, 1);
    expect(jsonEncode(portfolio.toJson()), original);
  });

  test('中间批失败仍刷新末批，保留失败批旧价并准确统计', () async {
    var now = start;
    var failMiddle = false;
    final portfolio = _portfolio(45);
    final batches = <List<MarketQuoteRequest>>[];
    final adapter = FixtureQuoteAdapter((requests) async {
      batches.add(requests);
      if (failMiddle && requests.first.symbol == 'TEST-STOCK-20') {
        throw const FormatException('本地中间批故障');
      }
      return [
        for (final request in requests)
          _quote(request, now, price: failMiddle ? '20' : '10'),
      ];
    }, support: (_) => true);
    final sync = await _sync(adapter, [portfolio], () => now);
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    failMiddle = true;
    now = start.add(const Duration(minutes: 1));
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(batches.map((batch) => batch.length), [20, 20, 5, 20, 20, 5]);
    expect(sync.state.value.status, QuoteSyncStatus.failed);
    expect(sync.state.value.changed, 25);
    final quotes = sync.quotesFor(portfolio);
    expect(quotes, hasLength(45));
    for (var index = 0; index < 45; index++) {
      final quote = quotes[portfolio.securities[index].id]!;
      final failed = index >= 20 && index < 40;
      expect(quote.last, failed ? '10' : '20');
      expect(quote.fetchedAt, failed ? start : now);
    }
  });

  test('超过 100 个持仓刷新后内存完整，磁盘仍只保留最新 100 条', () async {
    var now = start;
    final portfolio = _portfolio(102);
    final store = LocalKeyValueStore();
    final batches = <int>[];
    final adapter = FixtureQuoteAdapter((requests) async {
      batches.add(requests.length);
      now = now.add(const Duration(seconds: 1));
      return [for (final request in requests) _quote(request, now)];
    }, support: (_) => true);
    final sync = await _sync(adapter, [portfolio], () => now, store: store);
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(batches, [20, 20, 20, 20, 20, 2]);
    expect(sync.quotesFor(portfolio), hasLength(102));
    expect(sync.state.value.changed, 102);
    expect(sync.state.value.status, QuoteSyncStatus.ready);
    final raw = store.read('investment_quote_cache_v1')!;
    final rows = (jsonDecode(raw) as Map)['rows'] as List;
    expect(rows, hasLength(100));
    expect(raw.length, lessThanOrEqualTo(512 * 1024));
    expect(
      rows.map((row) => ((row as Map)['quote'] as Map)['securityId']),
      containsAll(portfolio.securities.skip(100).take(2).map((s) => s.id)),
    );
    final restored = await _sync(adapter, [portfolio], () => now, store: store);
    expect(restored.quotesFor(portfolio), hasLength(100));
    expect(adapter.requests, 6);
    expect(sync.quotesFor(portfolio), hasLength(102));
  });

  test('重复响应只计一个更新，其他批次身份不能提前进入缓存', () async {
    final portfolio = _portfolio(21);
    final later = MarketQuoteRequest(portfolio.securities[20]);
    var calls = 0;
    final adapter = FixtureQuoteAdapter((requests) async {
      if (++calls == 2) throw const FormatException('本地末批故障');
      return [
        _quote(requests.first, start),
        _quote(requests.first, start),
        _quote(later, start),
      ];
    }, support: (_) => true);
    final sync = await _sync(adapter, [portfolio], () => start);
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(calls, 2);
    expect(sync.state.value.status, QuoteSyncStatus.failed);
    expect(sync.state.value.changed, 1);
    expect(sync.quotesFor(portfolio).keys, [portfolio.securities.first.id]);
  });

  for (final reason in ['后台', '关闭联网', '换账本', '修改组合', '修订失效']) {
    test('第 2 批等待时$reason，丢弃本轮结果并停止后续批次', () async {
      final portfolio = _portfolio(45);
      final other = _portfolio(21, bookId: '另一个账本');
      final secondEntered = Completer<void>();
      final releaseSecond = Completer<void>();
      var calls = 0;
      var current = true;
      final adapter = FixtureQuoteAdapter((requests) async {
        if (++calls == 2) {
          secondEntered.complete();
          await releaseSecond.future;
          if (reason == '关闭联网') {
            throw const FormatException('已关闭期间请求失败');
          }
        }
        return [for (final request in requests) _quote(request, start)];
      }, support: (_) => true);
      final sync = await _sync(adapter, [portfolio, other], () => start);
      sync.setVisible(portfolio);
      sync.setForegroundPortfolios([portfolio]);
      var notifications = 0;
      sync.onPricesChanged = () => notifications++;
      final refreshing = sync.refresh(portfolio, isCurrent: () => current);
      await secondEntered.future;
      expect(sync.quotesFor(portfolio), isEmpty);
      switch (reason) {
        case '后台':
          sync.setForegroundPortfolios(null);
        case '关闭联网':
          expect(
            await sync.configure(enabled: false, automatic: false),
            isTrue,
          );
        case '换账本':
          sync.setForegroundPortfolios([other]);
          sync.setVisible(other);
        case '修改组合':
          sync.reconcile([_portfolio(44), other]);
        case '修订失效':
          current = false;
      }
      releaseSecond.complete();
      expect(await refreshing, isFalse);
      expect(calls, 2);
      expect(sync.quotesFor(portfolio), isEmpty);
      expect(sync.quotesFor(other), isEmpty);
      expect(sync.stateFor(portfolio).changed, 0);
      expect(sync.state.value.status, isNot(QuoteSyncStatus.loading));
      expect(notifications, 0);
    });
  }

  test('两账户分批刷新和五分钟自动计时独立，失败不会污染另一账户', () async {
    final first = _portfolio(21, accountId: '账户一');
    final second = _portfolio(21, accountId: '账户二');
    var calls = 0;
    final adapter = FixtureQuoteAdapter((requests) async {
      if (++calls == 2) throw const FormatException('仅第一账户末批失败');
      return [
        for (final request in requests)
          _quote(request, start, price: calls <= 2 ? '10' : '30'),
      ];
    }, support: (_) => true);
    final sync = await _sync(adapter, [first, second], () => start);
    sync.setForegroundPortfolios([first, second]);
    for (final portfolio in [first, second]) {
      expect(
        await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
        isTrue,
      );
    }
    expect(calls, 4);
    expect(sync.stateFor(first).status, QuoteSyncStatus.failed);
    expect(sync.stateFor(first).changed, 20);
    expect(sync.stateFor(second).status, QuoteSyncStatus.ready);
    expect(sync.stateFor(second).changed, 21);
    expect(sync.quotesFor(first).values.every((q) => q.last == '10'), isTrue);
    expect(sync.quotesFor(second).values.every((q) => q.last == '30'), isTrue);
    for (final portfolio in [first, second]) {
      expect(
        await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
        isFalse,
      );
      expect(
        sync.stateFor(portfolio).cooldownUntil,
        start.add(const Duration(minutes: 5)),
      );
    }
    expect(calls, 4);
  });
}
