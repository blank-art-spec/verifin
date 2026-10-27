import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_session.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/market_quote_fixture.dart';

const _hkStock = StockSecurity(
  symbol: '00700',
  name: '应用会话港股夹具',
  market: StockMarket.hk,
  currencyCode: 'HKD',
);
const _cnStock = StockSecurity(
  symbol: '600026',
  name: '应用会话A股夹具',
  market: StockMarket.cn,
  currencyCode: 'CNY',
);
const _unsupportedStock = StockSecurity(
  symbol: 'TEST-SESSION-UNSUPPORTED',
  name: '不支持联网的本地夹具',
  market: StockMarket.hk,
  currencyCode: 'HKD',
);

/// 创建单证券持仓，以不同账户和账本验证应用级批次的隔离。
///
/// [security] 决定公开身份和原币；[accountId]、[bookId] 仅保存在本地上下文中。
/// [held] 为 false 时只有证券定义，没有实际持仓，不应进入自动查询批次。
InvestmentPortfolio _portfolio(
  StockSecurity security,
  String accountId, {
  String bookId = defaultLedgerBookId,
  bool held = true,
}) => InvestmentPortfolio(
  accountId: accountId,
  bookId: bookId,
  currencyCode: security.currencyCode,
  openedAt: DateTime(2026, 10, 1),
  openingCash: '10000',
  securities: [security],
  openingHoldings: [
    if (held)
      StockHolding(
        securityId: security.id,
        short: false,
        quantity: '2',
        cost: '600',
      ),
  ],
  manualPrices: {security.id: '300'},
);

/// 根据已捕获请求生成固定单股报价，不访问任何真实来源。
/// [request] 提供公开证券和币种；[time] 同时作为此夹具的来源及获取时间。
MarketQuote _quote(MarketQuoteRequest request, DateTime time) => MarketQuote(
  securityId: request.securityId,
  source: '本地测试夹具',
  currency: request.currency,
  unit: QuotePriceUnit.share,
  fetchedAt: time,
  last: '330',
  lastAt: time,
);

/// 创建即时本地适配器；[clock] 是可控假时钟，[requested] 可记录实际证券请求顺序。
/// 只支持两只明确定义的股票，用来证明空账户及不支持身份不会进入网络分发。
FixtureQuoteAdapter _instantAdapter(
  DateTime Function() clock, {
  List<String>? requested,
}) => FixtureQuoteAdapter((requests) async {
  requested?.addAll(requests.map((request) => request.symbol));
  return [for (final request in requests) _quote(request, clock())];
}, support: (request) => const {'00700', '600026'}.contains(request.symbol));

/// 应用会话夹具，显式模拟前台及当前账本范围；不构建参考行情页。
class _SessionFixture {
  /// [sync] 已载入所有合法账务上下文；[scope] 是当前可自动刷新的聚合快照。
  /// isCurrent 每次重新检查前台状态和同一聚合实例，模拟应用的解锁/修订保护。
  _SessionFixture(this.sync, this.scope) {
    session = InvestmentQuoteSession(
      sync: sync,
      isCurrent: (portfolio) =>
          active && scope.any((current) => identical(current, portfolio)),
    );
  }

  final InvestmentQuoteSync sync;
  late final InvestmentQuoteSession session;
  List<InvestmentPortfolio> scope;
  bool active = false;

  /// [active] 代表应用前台且解锁；[portfolios] 用于模拟切换账本或持仓快照变化。
  /// 不调用 setVisible，因此初次打开首页也必须能建立自动刷新批次。
  void update({required bool active, List<InvestmentPortfolio>? portfolios}) {
    this.active = active;
    if (portfolios != null) scope = portfolios;
    session.update(active: active, portfolios: scope);
  }

  /// 先停止会话及其定时器，再销毁通知源，避免回调访问已销毁的同步器。
  void dispose() {
    session.dispose();
    sync.dispose();
  }
}

/// 创建设备内存偏好及同步器，所有请求均交给 [adapter] 本地夹具。
///
/// [scope] 是当前账本；[allPortfolios] 可包含其他账本以验证切换行为；
/// [clock] 控制真实时间间隔；[enabled]、[automatic] 独立控制两项用户偏好。
/// [store] 可注入暂挂写入的偏好存储，未传入时使用独立的内存存储。
/// 返回对象会在测试结束时自动释放，构造过程不应主动请求报价。
Future<_SessionFixture> _fixture(
  FixtureQuoteAdapter adapter, {
  required List<InvestmentPortfolio> scope,
  required DateTime Function() clock,
  List<InvestmentPortfolio>? allPortfolios,
  bool enabled = true,
  bool automatic = true,
  LocalKeyValueStore? store,
}) async {
  final sync = InvestmentQuoteSync(
    store: store ?? LocalKeyValueStore(),
    client: MarketQuoteClient(adapters: [adapter]),
    clock: clock,
  );
  sync.reconcile(allPortfolios ?? scope);
  expect(await sync.configure(enabled: enabled, automatic: automatic), isTrue);
  final fixture = _SessionFixture(sync, scope);
  addTearDown(fixture.dispose);
  return fixture;
}

/// 只暂挂下一次设置保存，模拟关闭自动刷新时设备偏好仍未落盘。
class _PausingSessionSettingsStore extends LocalKeyValueStore {
  /// [failAfterRelease] 为 true 时，释放等待后模拟保存失败；初始化保存不受影响。
  _PausingSessionSettingsStore({required this.failAfterRelease});

  final bool failAfterRelease;
  bool pauseNextSettings = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  /// [key] 为独立设备偏好键；[value] 不输出到日志。
  /// 先让测试确认关闭写入已进入等待，再由测试显式释放成功或失败结果。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (pauseNextSettings && key == 'investment_quote_settings_v1') {
      pauseNextSettings = false;
      entered.complete();
      await release.future;
      if (failAfterRelease) throw StateError('模拟关闭自动行情偏好保存失败');
    }
    await super.writeAndFlush(key, value);
  }
}

/// 应用级前台会话的自动刷新验证；只操作内存报价与假时钟，无真实网络副作用。
void main() {
  final start = DateTime.utc(2026, 10, 27, 4);

  test('打开应用无需进入行情页，串行刷新当前账本各个到期账户', () async {
    final pending = Completer<List<MarketQuote>>();
    final hk = _portfolio(_hkStock, 'hkd');
    final cn = _portfolio(_cnStock, 'cny');
    final requested = <String>[];
    final adapter = FixtureQuoteAdapter((requests) {
      requested.add(requests.single.symbol);
      return requests.single.symbol == '00700'
          ? pending.future
          : Future.value([_quote(requests.single, start)]);
    }, support: (_) => true);
    final fixture = await _fixture(
      adapter,
      scope: [hk, cn],
      clock: () => start,
    );
    expect(adapter.requests, 0);
    fixture.update(active: true);
    final opening = fixture.session.refreshIfDue();
    await Future<void>.delayed(Duration.zero);
    expect(requested, ['00700']);
    pending.complete([_quote(MarketQuoteRequest(_hkStock), start)]);
    await opening;
    expect(requested, ['00700', '600026']);
    expect(fixture.sync.quotesFor(hk).keys, [_hkStock.id]);
    expect(fixture.sync.quotesFor(cn).keys, [_cnStock.id]);
    expect(
      fixture.sync.stateFor(hk).cooldownUntil,
      start.add(InvestmentQuoteSync.interval),
    );
    expect(
      fixture.sync.stateFor(cn).cooldownUntil,
      start.add(InvestmentQuoteSync.interval),
    );
  });

  test('再次回前台只跳过仍在冷却的账户，另一币种立即刷新', () async {
    var now = start;
    final hk = _portfolio(_hkStock, 'hkd');
    final cn = _portfolio(_cnStock, 'cny');
    final requested = <String>[];
    final adapter = _instantAdapter(() => now, requested: requested);
    final fixture = await _fixture(
      adapter,
      scope: [hk],
      allPortfolios: [hk, cn],
      clock: () => now,
    );
    fixture.update(active: true);
    await fixture.session.refreshIfDue();
    fixture.update(active: false);
    now = start.add(const Duration(minutes: 1));
    fixture.update(active: true, portfolios: [hk, cn]);
    await fixture.session.refreshIfDue();
    expect(requested, ['00700', '600026']);
    expect(fixture.sync.stateFor(hk).attemptedAt, start);
    expect(fixture.sync.stateFor(cn).attemptedAt, now);
  });

  testWidgets('手动刷新不推迟应用级五分钟自动周期', (tester) async {
    var now = start;
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = _instantAdapter(() => now);
    final fixture = await _fixture(adapter, scope: [cn], clock: () => now);
    try {
      fixture.update(active: true);
      await fixture.session.refreshIfDue();
      expect(adapter.requests, 1);
      now = start.add(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      expect(
        await fixture.sync.refresh(cn, isCurrent: () => fixture.active),
        isTrue,
      );
      expect(adapter.requests, 2);
      expect(
        fixture.sync.stateFor(cn).cooldownUntil,
        start.add(const Duration(minutes: 5)),
      );
      now = start.add(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(adapter.requests, 3);
      expect(
        fixture.sync.stateFor(cn).cooldownUntil,
        start.add(const Duration(minutes: 10)),
      );
    } finally {
      // Flutter 在测试体结束时检查Timer，不能延后到addTearDown才暂停会话。
      fixture.update(active: false);
    }
  });

  testWidgets('离开行情页不停止前台应用的自动定时', (tester) async {
    var now = start;
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = _instantAdapter(() => now);
    final fixture = await _fixture(adapter, scope: [cn], clock: () => now);
    try {
      fixture.update(active: true);
      await fixture.session.refreshIfDue();
      fixture.sync.setVisible(cn);
      fixture.sync.setVisible(null);
      now = start.add(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(adapter.requests, 2);
      expect(fixture.sync.quotesFor(cn).values.single.fetchedAt, now);
    } finally {
      fixture.update(active: false);
    }
  });

  testWidgets('手动请求等待中离页，丢弃旧结果后仍在原截止时间自动刷新', (tester) async {
    var now = start;
    var manualPageVisible = true;
    final pending = Completer<List<MarketQuote>>();
    final cn = _portfolio(_cnStock, 'cny');
    var requests = 0;
    final adapter = FixtureQuoteAdapter((captured) async {
      requests++;
      if (requests == 2) return pending.future;
      return [_quote(captured.single, now)];
    }, support: (_) => true);
    final fixture = await _fixture(adapter, scope: [cn], clock: () => now);
    try {
      fixture.update(active: true);
      await fixture.session.refreshIfDue();
      expect(adapter.requests, 1);
      fixture.sync.setVisible(cn);
      now = start.add(const Duration(minutes: 4));
      await tester.pump(const Duration(minutes: 4));
      final manual = fixture.sync.refresh(
        cn,
        isCurrent: () => fixture.active && manualPageVisible,
      );
      expect(adapter.requests, 2);
      // 页面离开时应用仍在前台；手动请求失去页面上下文，但自动会话必须继续。
      manualPageVisible = false;
      fixture.sync.setVisible(null);
      pending.complete([_quote(MarketQuoteRequest(_cnStock), now)]);
      expect(await manual, isFalse);
      expect(fixture.sync.quotesFor(cn).values.single.fetchedAt, start);
      now = start.add(const Duration(minutes: 5));
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      // 直接检查Timer触发，不能调用refreshIfDue来掩盖完成信号丢失的问题。
      expect(adapter.requests, 3);
      expect(fixture.sync.quotesFor(cn).values.single.fetchedAt, now);
    } finally {
      if (!pending.isCompleted) {
        pending.complete([_quote(MarketQuoteRequest(_cnStock), now)]);
      }
      fixture.update(active: false);
    }
  });

  testWidgets('退后台或锁屏后超过五分钟不再发出请求，恢复前台才检查', (tester) async {
    var now = start;
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = _instantAdapter(() => now);
    final fixture = await _fixture(adapter, scope: [cn], clock: () => now);
    try {
      fixture.update(active: true);
      await fixture.session.refreshIfDue();
      fixture.update(active: false);
      now = start.add(const Duration(minutes: 6));
      await tester.pump(const Duration(minutes: 6));
      await fixture.session.refreshIfDue();
      expect(adapter.requests, 1);
      fixture.update(active: true);
      await fixture.session.refreshIfDue();
      expect(adapter.requests, 2);
    } finally {
      fixture.update(active: false);
    }
  });

  test('退后台时撤销旧响应，并且不继续刷新批次内后续账户', () async {
    final pending = Completer<List<MarketQuote>>();
    final hk = _portfolio(_hkStock, 'hkd');
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = FixtureQuoteAdapter((requests) {
      return requests.single.symbol == '00700'
          ? pending.future
          : Future.value([_quote(requests.single, start)]);
    }, support: (_) => true);
    final fixture = await _fixture(
      adapter,
      scope: [hk, cn],
      clock: () => start,
    );
    fixture.update(active: true);
    final opening = fixture.session.refreshIfDue();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, 1);
    fixture.update(active: false);
    pending.complete([_quote(MarketQuoteRequest(_hkStock), start)]);
    await opening;
    expect(adapter.requests, 1);
    expect(fixture.sync.quotesFor(hk), isEmpty);
    expect(fixture.sync.quotesFor(cn), isEmpty);
  });

  for (final failSaving in [false, true]) {
    test('关闭自动立即停止在途批次后续请求，设置保存失败=$failSaving', () async {
      var now = start;
      final pending = Completer<List<MarketQuote>>();
      final hk = _portfolio(_hkStock, 'hkd');
      final cn = _portfolio(_cnStock, 'cny');
      final store = _PausingSessionSettingsStore(failAfterRelease: failSaving);
      final adapter = FixtureQuoteAdapter((requests) {
        return requests.single.symbol == '00700'
            ? pending.future
            : Future.value([_quote(requests.single, now)]);
      }, support: (_) => true);
      final fixture = await _fixture(
        adapter,
        scope: [hk, cn],
        clock: () => now,
        store: store,
      );
      fixture.update(active: true);
      final opening = fixture.session.refreshIfDue();
      Future<bool>? disabling;
      try {
        await Future<void>.delayed(Duration.zero);
        expect(adapter.requests, 1);
        store.pauseNextSettings = true;
        disabling = fixture.sync.configure(enabled: true, automatic: false);
        await store.entered.future;
        // 关闭写入仍在等待时，内存和会话就必须停止自动行为，不能等保存完成。
        expect(fixture.sync.state.value.automatic, isFalse);
        pending.complete([_quote(MarketQuoteRequest(_hkStock), now)]);
        await opening;
        expect(adapter.requests, 1);
        expect(fixture.sync.quotesFor(hk), isEmpty);
        expect(fixture.sync.quotesFor(cn), isEmpty);
        now = start.add(const Duration(minutes: 6));
        await fixture.session.refreshIfDue();
        expect(adapter.requests, 1);
        store.release.complete();
        expect(await disabling, !failSaving);
        expect(fixture.sync.state.value.automatic, isFalse);
        expect(fixture.sync.state.value.enabled, isTrue);
        now = start.add(const Duration(minutes: 12));
        await fixture.session.refreshIfDue();
        expect(adapter.requests, 1);
        // 只关闭自动不等于关闭联网；用户主动刷新另一账户仍可正常使用。
        expect(
          await fixture.sync.refresh(cn, isCurrent: () => fixture.active),
          isTrue,
        );
        expect(adapter.requests, 2);
      } finally {
        if (!pending.isCompleted) {
          pending.complete([_quote(MarketQuoteRequest(_hkStock), now)]);
        }
        if (!store.release.isCompleted) store.release.complete();
        if (disabling != null) await disabling;
        await opening;
        fixture.update(active: false);
      }
    });
  }

  test('切换账本时旧批次不能请求后续旧账户或接受其迟到响应', () async {
    final pending = Completer<List<MarketQuote>>();
    final oldHk = _portfolio(_hkStock, 'hkd', bookId: 'old-book');
    final oldCn = _portfolio(_cnStock, 'old-cny', bookId: 'old-book');
    final newCn = _portfolio(_cnStock, 'new-cny', bookId: 'new-book');
    final requested = <String>[];
    final adapter = FixtureQuoteAdapter((requests) {
      requested.add(requests.single.symbol);
      return requests.single.symbol == '00700'
          ? pending.future
          : Future.value([_quote(requests.single, start)]);
    }, support: (_) => true);
    final fixture = await _fixture(
      adapter,
      scope: [oldHk, oldCn],
      allPortfolios: [oldHk, oldCn, newCn],
      clock: () => start,
    );
    fixture.update(active: true);
    final opening = fixture.session.refreshIfDue();
    await Future<void>.delayed(Duration.zero);
    fixture.update(active: true, portfolios: [newCn]);
    pending.complete([_quote(MarketQuoteRequest(_hkStock), start)]);
    await opening;
    await fixture.session.refreshIfDue();
    expect(requested, ['00700', '600026']);
    expect(fixture.sync.quotesFor(oldHk), isEmpty);
    expect(fixture.sync.quotesFor(oldCn), isEmpty);
    expect(fixture.sync.quotesFor(newCn).values.single.securityId, _cnStock.id);
  });

  testWidgets('空持仓与不支持证券不会请求或产生零延时自动循环', (tester) async {
    var now = start;
    final empty = _portfolio(_cnStock, 'empty', held: false);
    final unsupported = _portfolio(_unsupportedStock, 'unsupported');
    final adapter = _instantAdapter(() => now);
    final fixture = await _fixture(
      adapter,
      scope: [empty, unsupported],
      clock: () => now,
    );
    fixture.update(active: true);
    await fixture.session.refreshIfDue();
    now = start.add(const Duration(minutes: 30));
    await tester.pump(const Duration(minutes: 30));
    expect(adapter.requests, 0);
    expect(fixture.sync.stateFor(empty).attemptedAt, isNull);
    expect(fixture.sync.stateFor(unsupported).attemptedAt, isNull);
  });

  test('默认关闭及只开联网时不会自动请求，开启自动后在首页立即触发', () async {
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = _instantAdapter(() => start);
    final fixture = await _fixture(
      adapter,
      scope: [cn],
      clock: () => start,
      enabled: false,
      automatic: false,
    );
    fixture.update(active: true);
    await fixture.session.refreshIfDue();
    expect(adapter.requests, 0);
    expect(
      await fixture.sync.configure(enabled: true, automatic: false),
      isTrue,
    );
    await fixture.session.refreshIfDue();
    expect(adapter.requests, 0);
    expect(
      await fixture.sync.configure(enabled: true, automatic: true),
      isTrue,
    );
    await fixture.session.refreshIfDue();
    expect(adapter.requests, 1);
  });

  test('相同前台及聚合范围重复通知不会撤销在途请求或重启自身批次', () async {
    final pending = Completer<List<MarketQuote>>();
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = FixtureQuoteAdapter(
      (_) => pending.future,
      support: (_) => true,
    );
    final fixture = await _fixture(adapter, scope: [cn], clock: () => start);
    fixture.update(active: true);
    final opening = fixture.session.refreshIfDue();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, 1);
    fixture.update(active: true);
    fixture.update(active: true, portfolios: [cn]);
    pending.complete([_quote(MarketQuoteRequest(_cnStock), start)]);
    await opening;
    expect(adapter.requests, 1);
    expect(fixture.sync.quotesFor(cn).values.single.fetchedAt, start);
  });

  testWidgets('销毁应用会话后不会留下自动定时器', (tester) async {
    var now = start;
    final cn = _portfolio(_cnStock, 'cny');
    final adapter = _instantAdapter(() => now);
    final fixture = await _fixture(adapter, scope: [cn], clock: () => now);
    fixture.update(active: true);
    await fixture.session.refreshIfDue();
    fixture.session.dispose();
    now = start.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    expect(adapter.requests, 1);
  });
}
