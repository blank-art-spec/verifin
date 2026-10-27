import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/market_quote_fixture.dart';

const _hkStock = StockSecurity(
  symbol: '00700',
  name: '港币账户本地夹具',
  market: StockMarket.hk,
  currencyCode: 'HKD',
);
const _cnStock = StockSecurity(
  symbol: '600026',
  name: '人民币账户本地夹具',
  market: StockMarket.cn,
  currencyCode: 'CNY',
);

/// 创建包含一只股票的独立币种账户；证券代码仅交给本地夹具，不连接真实行情。
///
/// [security] 决定市场、原币和稳定证券身份；[accountId] 与 [bookId] 用于验证
/// 请求计时按“账本和账户”隔离，而不是单独依赖币种或可能跨账本重复的账户 ID。
InvestmentPortfolio _holding(
  StockSecurity security, {
  required String accountId,
  String bookId = defaultLedgerBookId,
}) => InvestmentPortfolio(
  accountId: accountId,
  bookId: bookId,
  currencyCode: security.currencyCode,
  openedAt: DateTime(2026, 10, 1),
  openingCash: '10000',
  securities: [security],
  openingHoldings: [
    StockHolding(
      securityId: security.id,
      short: false,
      quantity: '2',
      cost: '600',
    ),
  ],
  manualPrices: {security.id: '300'},
);

/// 为已捕获的公开请求构造报价，明确分离抓取时间与来源原始报价时间。
///
/// [request] 提供市场证券身份及原币；[fetchedAt] 为本次获取时间；[reportedAt]
/// 为服务方数据时间，省略时与抓取时间相同；[price] 是固定测试单股价。
MarketQuote _quote(
  MarketQuoteRequest request,
  DateTime fetchedAt, {
  DateTime? reportedAt,
  String price = '330',
}) => MarketQuote(
  securityId: request.securityId,
  source: '本地测试夹具',
  currency: request.currency,
  unit: QuotePriceUnit.share,
  fetchedAt: fetchedAt,
  last: price,
  lastAt: reportedAt ?? fetchedAt,
);

/// 建立已授权但不自行联网的同步器；调用方负责选择可见账户并在结束时销毁。
///
/// [adapter] 只返回内存报价；[portfolios] 为允许保留缓存的账务上下文；[clock]
/// 提供测试时钟，不真实等待五分钟；[store] 可在冷启动测试中复用设备缓存。
Future<InvestmentQuoteSync> _createSync(
  FixtureQuoteAdapter adapter, {
  required List<InvestmentPortfolio> portfolios,
  required DateTime Function() clock,
  LocalKeyValueStore? store,
}) async {
  final sync = InvestmentQuoteSync(
    store: store ?? LocalKeyValueStore(),
    client: MarketQuoteClient(adapters: [adapter]),
    clock: clock,
  );
  sync.reconcile(portfolios);
  expect(await sync.configure(enabled: true, automatic: true), isTrue);
  return sync;
}

/// 只暂停下一次行情缓存落盘，并在允许继续后注入一次保存失败。
///
/// 测试先完成上下文初始化，再开启 [pauseNextCache]；[entered] 用于确定请求已经
/// 进入落盘阶段，[release] 由测试在切换账户后完成，避免依赖真实时间或网络。
class _PausingCacheFailureStore extends LocalKeyValueStore {
  bool pauseNextCache = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  /// [key] 与 [value] 是设备缓存键值；只拦截一次指定缓存写入，其他偏好照常保存。
  /// 释放暂停后抛出可预期错误，用于验证旧账户保存失败不会改变新账户页面状态。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (pauseNextCache && key == 'investment_quote_cache_v1') {
      pauseNextCache = false;
      entered.complete();
      await release.future;
      throw StateError('模拟旧账户报价缓存保存失败');
    }
    await super.writeAndFlush(key, value);
  }
}

/// 注册手动刷新与自动轮询的独立行为；全部使用本地夹具且不会访问公开端点。
void main() {
  final start = DateTime.utc(2026, 10, 27, 4);

  test('手动重复刷新不等待五分钟，同价同源时间仍更新抓取时间', () async {
    var now = start;
    final portfolio = _holding(_cnStock, accountId: 'cny');
    final original = jsonEncode(portfolio.toJson());
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, now, reportedAt: start)],
      minimumInterval: const Duration(minutes: 10),
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [portfolio],
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    now = now.add(const Duration(seconds: 1));
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(adapter.requests, 2);
    final quote = sync.quotesFor(portfolio).values.single;
    expect(quote.last, '330');
    expect(quote.lastAt, start);
    expect(quote.fetchedAt, now);
    expect(sync.state.value.attemptedAt, now);
    expect(sync.state.value.cooldownUntil, isNull);
    expect(jsonEncode(portfolio.toJson()), original);
  });

  test('手动刷新不推迟同账户原有的五分钟自动刷新时间', () async {
    var now = start;
    final portfolio = _holding(_hkStock, accountId: 'hkd');
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, now)],
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [portfolio],
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.setVisible(portfolio);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isTrue,
    );
    final nextAutomatic = start.add(const Duration(minutes: 5));
    expect(sync.state.value.cooldownUntil, nextAutomatic);
    now = start.add(const Duration(minutes: 2));
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(sync.state.value.attemptedAt, now);
    expect(sync.state.value.cooldownUntil, nextAutomatic);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isFalse,
    );
    expect(adapter.requests, 2);
    now = nextAutomatic;
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isTrue,
    );
    expect(adapter.requests, 3);
  });

  test('港币和人民币账户的自动计时及最近请求状态互不影响', () async {
    var now = start;
    final hk = _holding(_hkStock, accountId: 'hkd');
    final cn = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, now)],
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [hk, cn],
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.setVisible(hk);
    expect(
      await sync.refresh(hk, isCurrent: () => true, automatic: true),
      isTrue,
    );
    final hkNext = start.add(const Duration(minutes: 5));
    now = start.add(const Duration(seconds: 30));
    sync.setVisible(cn);
    expect(sync.state.value.attemptedAt, isNull);
    expect(sync.state.value.cooldownUntil, isNull);
    expect(
      await sync.refresh(cn, isCurrent: () => true, automatic: true),
      isTrue,
    );
    expect(adapter.requests, 2);
    expect(sync.state.value.attemptedAt, now);
    expect(sync.state.value.cooldownUntil, now.add(const Duration(minutes: 5)));
    sync.setVisible(hk);
    expect(sync.state.value.attemptedAt, start);
    expect(sync.state.value.cooldownUntil, hkNext);
    expect(
      await sync.refresh(hk, isCurrent: () => true, automatic: true),
      isFalse,
    );
    expect(adapter.requests, 2);
    now = hkNext;
    expect(
      await sync.refresh(hk, isCurrent: () => true, automatic: true),
      isTrue,
    );
    sync.setVisible(cn);
    expect(
      await sync.refresh(cn, isCurrent: () => true, automatic: true),
      isFalse,
    );
    expect(adapter.requests, 3);
  });

  test('不同账本相同账户 ID 也分别计时，冷启动保留各自时间', () async {
    var now = start;
    final first = _holding(_hkStock, accountId: 'same', bookId: 'book-a');
    final second = _holding(_hkStock, accountId: 'same', bookId: 'book-b');
    final store = LocalKeyValueStore();
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, now)],
      support: (_) => true,
    );
    var sync = await _createSync(
      adapter,
      portfolios: [first, second],
      clock: () => now,
      store: store,
    );
    addTearDown(() => sync.dispose());
    sync.setVisible(first);
    expect(
      await sync.refresh(first, isCurrent: () => true, automatic: true),
      isTrue,
    );
    now = start.add(const Duration(minutes: 1));
    sync.setVisible(second);
    expect(
      await sync.refresh(second, isCurrent: () => true, automatic: true),
      isTrue,
    );
    sync.dispose();
    now = start.add(const Duration(minutes: 4));
    sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => now,
    );
    sync.reconcile([first, second]);
    sync.setVisible(first);
    expect(sync.state.value.attemptedAt, start);
    expect(
      sync.state.value.cooldownUntil,
      start.add(const Duration(minutes: 5)),
    );
    expect(
      await sync.refresh(first, isCurrent: () => true, automatic: true),
      isFalse,
    );
    sync.setVisible(second);
    expect(sync.state.value.attemptedAt, start.add(const Duration(minutes: 1)));
    expect(
      sync.state.value.cooldownUntil,
      start.add(const Duration(minutes: 6)),
    );
    expect(
      await sync.refresh(second, isCurrent: () => true, automatic: true),
      isFalse,
    );
    expect(adapter.requests, 2);
    expect(sync.quotesFor(first).values.single.fetchedAt, start);
    expect(
      sync.quotesFor(second).values.single.fetchedAt,
      start.add(const Duration(minutes: 1)),
    );
    final payload = jsonDecode(store.read('investment_quote_cache_v1')!) as Map;
    expect(payload['version'], 2);
    expect(payload['accounts'], hasLength(2));
  });

  test('旧版全局冷却无法归属账户，升级后不阻止各币种首次自动请求', () async {
    final hk = _holding(_hkStock, accountId: 'hkd');
    final cn = _holding(_cnStock, accountId: 'cny');
    final store = LocalKeyValueStore()
      ..write(
        'investment_quote_settings_v1',
        jsonEncode({'enabled': true, 'automatic': true}),
      )
      ..write(
        'investment_quote_cache_v1',
        jsonEncode({
          'version': 1,
          'attemptedAt': start.toIso8601String(),
          'cooldownUntil': start
              .add(const Duration(minutes: 5))
              .toIso8601String(),
          'rows': [],
        }),
      );
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, start)],
      support: (_) => true,
    );
    final sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => start,
    );
    addTearDown(sync.dispose);
    sync.reconcile([hk, cn]);
    sync.setVisible(hk);
    expect(sync.state.value.attemptedAt, isNull);
    expect(
      await sync.refresh(hk, isCurrent: () => true, automatic: true),
      isTrue,
    );
    sync.setVisible(cn);
    expect(sync.state.value.attemptedAt, isNull);
    expect(
      await sync.refresh(cn, isCurrent: () => true, automatic: true),
      isTrue,
    );
    expect(adapter.requests, 2);
  });

  test('同账户请求进行中阻止手动连点，完成后立即允许再次手动刷新', () async {
    final pending = Completer<List<MarketQuote>>();
    final portfolio = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter(
      (requests) => pending.future,
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [portfolio],
      clock: () => start,
    );
    addTearDown(sync.dispose);
    sync.setVisible(portfolio);
    final running = sync.refresh(portfolio, isCurrent: () => true);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(adapter.requests, 1);
    pending.complete([_quote(adapter.lastRequests.single, start)]);
    expect(await running, isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(adapter.requests, 2);
  });

  test('另一账户可在旧请求等待时刷新，旧响应不覆盖当前状态或任何账户缓存', () async {
    final pending = Completer<List<MarketQuote>>();
    final hk = _holding(_hkStock, accountId: 'hkd');
    final cn = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter(
      (requests) => requests.single.currency == 'HKD'
          ? pending.future
          : Future.value([_quote(requests.single, start)]),
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [hk, cn],
      clock: () => start,
    );
    addTearDown(sync.dispose);
    sync.setVisible(hk);
    final hkWork = sync.refresh(hk, isCurrent: () => true);
    final hkRequest = adapter.lastRequests.single;
    sync.setVisible(cn);
    expect(await sync.refresh(cn, isCurrent: () => true), isTrue);
    expect(adapter.requests, 2);
    expect(sync.state.value.status, QuoteSyncStatus.ready);
    pending.complete([_quote(hkRequest, start)]);
    expect(await hkWork, isFalse);
    expect(sync.quotesFor(hk), isEmpty);
    expect(sync.quotesFor(cn).values.single.securityId, _cnStock.id);
    expect(sync.state.value.status, QuoteSyncStatus.ready);
  });

  test('一个币种的失败和自动间隔不阻止另一币种获取报价', () async {
    final hk = _holding(_hkStock, accountId: 'hkd');
    final cn = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter((requests) async {
      if (requests.single.currency == 'HKD') {
        throw const FormatException('模拟港币来源暂时不可用');
      }
      return [_quote(requests.single, start)];
    }, support: (_) => true);
    final sync = await _createSync(
      adapter,
      portfolios: [hk, cn],
      clock: () => start,
    );
    addTearDown(sync.dispose);
    sync.setVisible(hk);
    expect(
      await sync.refresh(hk, isCurrent: () => true, automatic: true),
      isFalse,
    );
    expect(sync.state.value.status, QuoteSyncStatus.failed);
    sync.setVisible(cn);
    expect(sync.state.value.attemptedAt, isNull);
    expect(sync.state.value.status, isNot(QuoteSyncStatus.failed));
    expect(
      await sync.refresh(cn, isCurrent: () => true, automatic: true),
      isTrue,
    );
    expect(adapter.requests, 2);
  });

  testWidgets('自动轮询每五分钟一次，手动刷新不重置定时且离页立即停止', (tester) async {
    var now = start;
    final portfolio = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, now)],
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [portfolio],
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.setVisible(portfolio);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isTrue,
    );
    sync.scheduleVisibleRefresh(() async {
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true);
    });
    now = start.add(const Duration(minutes: 4));
    await tester.pump(const Duration(minutes: 4));
    expect(adapter.requests, 1);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(adapter.requests, 2);
    // 手动请求后再过一分钟即到原自动周期；不能被推迟为手动操作后的五分钟。
    now = start.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 1));
    expect(adapter.requests, 3);
    sync.setVisible(null);
    now = start.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 5));
    expect(adapter.requests, 3);
  });

  testWidgets('第四分钟离页重入，自动刷新仍在原第五分钟触发', (tester) async {
    var now = start;
    final portfolio = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, now)],
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [portfolio],
      clock: () => now,
    );
    addTearDown(sync.dispose);
    sync.setVisible(portfolio);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isTrue,
    );
    sync.scheduleVisibleRefresh(() async {
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true);
    });
    now = start.add(const Duration(minutes: 4));
    await tester.pump(const Duration(minutes: 4));
    sync.setVisible(null);
    sync.setVisible(portfolio);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isFalse,
    );
    // 重绑只等待原截止时间的剩余一分钟，不能从重新进入页面再计五分钟。
    sync.scheduleVisibleRefresh(() async {
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true);
    });
    now = start.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 1));
    expect(adapter.requests, 2);
    expect(
      sync.state.value.cooldownUntil,
      start.add(const Duration(minutes: 10)),
    );
    now = start.add(const Duration(minutes: 9));
    await tester.pump(const Duration(minutes: 4));
    expect(adapter.requests, 2);
    now = start.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 1));
    expect(adapter.requests, 3);
    sync.setVisible(null);
  });

  test('旧账户缓存写入等待中切换账户，保存失败不污染新账户状态', () async {
    final hk = _holding(_hkStock, accountId: 'hkd');
    final cn = _holding(_cnStock, accountId: 'cny');
    final store = _PausingCacheFailureStore();
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, start)],
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [hk, cn],
      clock: () => start,
      store: store,
    );
    addTearDown(sync.dispose);
    // 确保 reconcile 引起的初始缓存写入完成，暂停点仅属于下方港币刷新。
    await Future<void>.delayed(Duration.zero);
    sync.setVisible(hk);
    store.pauseNextCache = true;
    final hkWork = sync.refresh(hk, isCurrent: () => true);
    await store.entered.future;
    sync.setVisible(cn);
    expect(sync.state.value.status, QuoteSyncStatus.idle);
    expect(sync.state.value.attemptedAt, isNull);
    store.release.complete();
    expect(await hkWork, isFalse);
    expect(sync.state.value.status, QuoteSyncStatus.idle);
    expect(sync.state.value.attemptedAt, isNull);
    expect(sync.state.value.status, isNot(QuoteSyncStatus.notCached));
    // 旧写入失败后队列仍可继续，新账户可成功获取并持久保存自己的报价。
    expect(await sync.refresh(cn, isCurrent: () => true), isTrue);
    expect(sync.state.value.status, QuoteSyncStatus.ready);
    expect(sync.quotesFor(cn).values.single.securityId, _cnStock.id);
  });

  test('删除账户上下文后不复活旧自动计时，其他账户时间保持有效', () async {
    final hk = _holding(_hkStock, accountId: 'hkd');
    final cn = _holding(_cnStock, accountId: 'cny');
    final adapter = FixtureQuoteAdapter(
      (requests) async => [_quote(requests.single, start)],
      support: (_) => true,
    );
    final sync = await _createSync(
      adapter,
      portfolios: [hk, cn],
      clock: () => start,
    );
    addTearDown(sync.dispose);
    for (final portfolio in [hk, cn]) {
      sync.setVisible(portfolio);
      expect(
        await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
        isTrue,
      );
    }
    sync.reconcile([cn]);
    expect(sync.state.value.attemptedAt, start);
    expect(
      sync.state.value.cooldownUntil,
      start.add(const Duration(minutes: 5)),
    );
    // 同一 ID 日后重新加入也视为新的上下文，不能继承已经删除账户的冷却记录。
    sync.reconcile([hk, cn]);
    sync.setVisible(hk);
    expect(sync.state.value.attemptedAt, isNull);
    expect(sync.state.value.cooldownUntil, isNull);
    expect(
      await sync.refresh(hk, isCurrent: () => true, automatic: true),
      isTrue,
    );
    expect(adapter.requests, 3);
  });
}
