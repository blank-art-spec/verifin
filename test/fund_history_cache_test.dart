import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

const _source = 'CMS Asset Management (HK)';
const _accountId = 'closed-fund-history-usd';
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
final _now = DateTime.utc(2026, 10, 29, 4);

/// 只生成本地合成净值的研究来源，不访问官网，不把测试数值宣称为真实基金历史。
class _FundHistoryAdapter extends MarketQuoteAdapter {
  /// [clock] 提供精确抓取时刻；[lastDay] 控制历史覆盖到十月哪一天，便于模拟补齐。
  _FundHistoryAdapter(this.clock, {this.lastDay = 26});

  final DateTime Function() clock;
  int lastDay;
  bool researchOnly = true;
  int requests = 0;
  List<MarketQuoteRequest> lastRequests = [];

  /// [researchOnly] 可模拟当前构建撤销研究来源，但 approved 始终保持 false。
  @override
  QuoteSourceCapability get capability => QuoteSourceCapability(
    _source,
    approved: false,
    researchOnly: researchOnly,
    reviewNote: '清仓基金历史缓存的本地研究夹具，不访问互联网',
  );

  /// 仅支持同一香港美元基金；同代码的股票或不同币种不能借此重新采用旧净值。
  @override
  bool supports(MarketQuoteRequest request) =>
      request.securityId == _fund.id &&
      request.fund &&
      !request.option &&
      request.market == StockMarket.hk &&
      request.currency == 'USD';

  /// 记录公开请求并返回合成历史；25日为100、26日为101、27日为102，全部有纯日期。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
    this.requests++;
    lastRequests = List.unmodifiable(requests);
    final history = FundNavHistory([
      for (var day = 25; day <= lastDay; day++)
        FundNavPoint(
          date: DateTime.utc(2026, 10, day),
          price: '${100 + day - 25}.0000',
        ),
    ]);
    return [
      for (final request in requests)
        MarketQuote(
          securityId: request.securityId,
          source: _source,
          currency: 'USD',
          unit: QuotePriceUnit.fundUnit,
          fetchedAt: clock().toUtc(),
          last: history.points.last.price,
          lastAt: history.points.last.date,
          dateOnly: true,
          navHistory: history,
        ),
    ];
  }
}

/// 观察真正完成的设备缓存写入；用于等待 reconcile 的异步保存，不依赖随意延时。
class _CacheStore extends LocalKeyValueStore {
  final _nextWrites = <Completer<void>>[];

  /// 在触发下一次缓存变更前调用，返回缓存保存完成通知；两秒上限让缺写入及时失败。
  Future<void> nextCacheWrite() {
    final completion = Completer<void>();
    _nextWrites.add(completion);
    return completion.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw TimeoutException('未观察到预期的行情缓存保存'),
    );
  }

  /// [key]/[value] 沿用真实 KV 写入，只有行情缓存落地成功才释放当前等待者。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    await super.writeAndFlush(key, value);
    if (key != 'investment_quote_cache_v1') return;
    final pending = List<Completer<void>>.of(_nextWrites);
    _nextWrites.clear();
    for (final completion in pending) {
      completion.complete();
    }
  }
}

/// 构造固定时点的基金买卖事实；[at] 可覆盖未来交易，[security] 用于测试类型更改。
StockEvent _event(
  String id,
  StockEventKind kind,
  int day, {
  int sequence = 1,
  String quantity = '10',
  String price = '100',
  DateTime? at,
  StockSecurity security = _fund,
}) => StockEvent(
  id: id,
  securityId: security.id,
  kind: kind,
  occurredAt: at ?? DateTime.utc(2026, 10, day, 4),
  sequence: sequence,
  quantity: quantity,
  price: price,
);

/// 创建同一账户的可变账务版本；[events] 只改变真实成交，缓存应保留公开基金资料。
/// [withStock] 加入 AVGO 以验证股票失效规则没有放宽；[adopted] 控制清仓补取许可。
InvestmentPortfolio _portfolio({
  List<StockEvent>? events,
  StockSecurity security = _fund,
  String currency = 'USD',
  bool withStock = false,
  bool adopted = true,
}) => InvestmentPortfolio(
  accountId: _accountId,
  bookId: defaultLedgerBookId,
  currencyCode: currency,
  openedAt: DateTime.utc(2026, 10, 1),
  openingCash: '10000',
  securities: [security, if (withStock) avgoFixture],
  openingHoldings: [
    if (withStock)
      StockHolding(
        securityId: avgoFixture.id,
        short: false,
        quantity: '2',
        cost: '600',
      ),
  ],
  events: events ?? [_event('buy', StockEventKind.buy, 25, security: security)],
  manualPrices: {security.id: '100', if (withStock) avgoFixture.id: '330'},
  marketPriceIds: {if (adopted) security.id},
);

/// 返回一份已经清仓的事实版本；[lastDay] 是最后卖出业务日在香港的日期。
InvestmentPortfolio _closedPortfolio({int lastDay = 26, bool adopted = true}) =>
    _portfolio(
      adopted: adopted,
      events: [
        _event('buy', StockEventKind.buy, 25),
        _event('sell', StockEventKind.sell, lastDay, sequence: 2, price: '101'),
      ],
    );

/// 建立没有真实网络的同步器；[clock]、[store] 和 [stock] 分别控制时钟、冷启和股票对照。
Future<InvestmentQuoteSync> _createSync(
  _FundHistoryAdapter adapter,
  InvestmentPortfolio portfolio, {
  required DateTime Function() clock,
  LocalKeyValueStore? store,
  FixtureQuoteAdapter? stock,
}) async {
  final sync = InvestmentQuoteSync(
    store: store ?? LocalKeyValueStore(),
    client: MarketQuoteClient(
      // 可空元素标记只在提供股票夹具时加入列表，避免放入空适配器。
      adapters: [adapter, ?stock],
      allowResearchSources: true,
    ),
    clock: clock,
  );
  sync.reconcile([portfolio]);
  sync.setVisible(portfolio);
  expect(await sync.configure(enabled: true, automatic: true), isTrue);
  return sync;
}

/// 注册清仓后的只读历史留存、补齐、门禁与真实 Controller 重算；全程不访问网络。
void main() {
  useTestDatabases();

  test('编辑或部分卖出后基金公开历史保留，股票普通缓存仍按账务修订失效', () async {
    final fund = _FundHistoryAdapter(() => _now);
    final stock = FixtureQuoteAdapter((_) async => [stockQuote(_now)]);
    final original = _portfolio(withStock: true);
    final sync = await _createSync(
      fund,
      original,
      clock: () => _now,
      stock: stock,
    );
    addTearDown(sync.dispose);
    expect(await sync.refresh(original, isCurrent: () => true), isTrue);
    expect(
      sync.quotesFor(original).keys,
      containsAll([_fund.id, avgoFixture.id]),
    );
    final history = sync.fundNavHistoryFor(original, _fund.id)!;

    final edited = original.copyWith(
      events: [_event('buy', StockEventKind.buy, 25, price: '99')],
    );
    sync.reconcile([edited]);
    expect(
      sync.fundNavHistoryFor(edited, _fund.id)!.toJson(),
      history.toJson(),
    );
    expect(sync.quotesFor(edited).keys, contains(_fund.id));
    expect(sync.quotesFor(edited).keys, isNot(contains(avgoFixture.id)));
    expect(sync.quotesFor(original), isEmpty);

    final soldPart = edited.copyWith(
      events: [
        ...edited.events,
        _event(
          'sell-part',
          StockEventKind.sell,
          26,
          sequence: 2,
          quantity: '4',
        ),
      ],
    );
    sync.reconcile([soldPart]);
    expect(
      sync.fundNavHistoryFor(soldPart, _fund.id)!.toJson(),
      history.toJson(),
    );
    expect(sync.quotesFor(soldPart).keys, contains(_fund.id));
    expect(sync.quotesFor(soldPart).keys, isNot(contains(avgoFixture.id)));
    expect(fund.requests, 1);
    expect(stock.requests, 1);
  });

  test('全卖后默认报价不含零持仓，覆盖最后事件的历史仍可读且不会重复请求', () async {
    var now = _now;
    final adapter = _FundHistoryAdapter(() => now);
    final held = _portfolio();
    final sync = await _createSync(adapter, held, clock: () => now);
    addTearDown(sync.dispose);
    expect(await sync.refresh(held, isCurrent: () => true), isTrue);
    final closed = _closedPortfolio();
    sync.reconcile([closed]);
    expect(sync.quotesFor(closed), isEmpty);
    expect(
      sync.fundNavHistoryFor(closed, _fund.id)!.points.last.date,
      DateTime.utc(2026, 10, 26),
    );
    expect(sync.quotesFor(closed, includeFundHistory: true).keys, [_fund.id]);
    expect(sync.hasSupportedHoldings(closed), isFalse);
    for (var attempt = 0; attempt < 3; attempt++) {
      now = now.add(const Duration(minutes: 10));
      expect(
        await sync.refresh(closed, isCurrent: () => true, automatic: true),
        isFalse,
      );
    }
    expect(adapter.requests, 1);
  });

  test('冷启动无缓存的已采用清仓基金可补取，覆盖后不继续空转', () async {
    final adapter = _FundHistoryAdapter(() => _now);
    final closed = _closedPortfolio();
    final sync = await _createSync(adapter, closed, clock: () => _now);
    addTearDown(sync.dispose);
    expect(sync.quotesFor(closed), isEmpty);
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNull);
    expect(sync.hasSupportedHoldings(closed), isTrue);
    expect(await sync.refresh(closed, isCurrent: () => true), isTrue);
    expect(adapter.lastRequests.map((request) => request.securityId), [
      _fund.id,
    ]);
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNotNull);
    expect(sync.quotesFor(closed), isEmpty);
    expect(sync.hasSupportedHoldings(closed), isFalse);
    expect(await sync.refresh(closed, isCurrent: () => true), isFalse);
    expect(adapter.requests, 1);
  });

  test('已有缓存未覆盖最后卖出日时只补齐所缺历史，补齐后停止请求', () async {
    final adapter = _FundHistoryAdapter(() => _now, lastDay: 25);
    final held = _portfolio();
    final sync = await _createSync(adapter, held, clock: () => _now);
    addTearDown(sync.dispose);
    expect(await sync.refresh(held, isCurrent: () => true), isTrue);
    final closed = _closedPortfolio();
    sync.reconcile([closed]);
    expect(
      sync.fundNavHistoryFor(closed, _fund.id)!.points.last.date,
      DateTime.utc(2026, 10, 25),
    );
    expect(sync.hasSupportedHoldings(closed), isTrue);
    adapter.lastDay = 26;
    expect(await sync.refresh(closed, isCurrent: () => true), isTrue);
    expect(
      sync.fundNavHistoryFor(closed, _fund.id)!.points.last.date,
      DateTime.utc(2026, 10, 26),
    );
    expect(sync.hasSupportedHoldings(closed), isFalse);
    expect(await sync.refresh(closed, isCurrent: () => true), isFalse);
    expect(adapter.requests, 2);
  });

  test('未采用、没有份额事实或只有未来交易的零持仓基金不补取历史', () async {
    final adapter = _FundHistoryAdapter(() => _now);
    final cases = [
      _closedPortfolio(adopted: false),
      _portfolio(events: const []),
      _portfolio(
        events: [
          _event(
            'future-buy',
            StockEventKind.buy,
            25,
            at: DateTime.utc(2030, 10, 25),
          ),
          _event(
            'future-sell',
            StockEventKind.sell,
            26,
            sequence: 2,
            at: DateTime.utc(2030, 10, 26),
          ),
        ],
      ),
    ];
    for (final portfolio in cases) {
      final sync = await _createSync(adapter, portfolio, clock: () => _now);
      expect(sync.hasSupportedHoldings(portfolio), isFalse);
      expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
      sync.dispose();
    }
    expect(adapter.requests, 0);
  });

  test('撤销研究来源期间不可读或请求，禁用研究的冷启动也不能读取旧历史', () async {
    final store = _CacheStore();
    final adapter = _FundHistoryAdapter(() => _now, lastDay: 25);
    final closed = _closedPortfolio();
    final sync = await _createSync(
      adapter,
      closed,
      clock: () => _now,
      store: store,
    );
    addTearDown(sync.dispose);
    expect(await sync.refresh(closed, isCurrent: () => true), isTrue);
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNotNull);
    expect(sync.hasSupportedHoldings(closed), isTrue);
    adapter.researchOnly = false;
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNull);
    expect(sync.quotesFor(closed, includeFundHistory: true), isEmpty);
    expect(sync.hasSupportedHoldings(closed), isFalse);
    expect(await sync.refresh(closed, isCurrent: () => true), isFalse);
    expect(adapter.requests, 1);

    final cold = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(
        adapters: [adapter],
        allowResearchSources: false,
      ),
      clock: () => _now,
    );
    addTearDown(cold.dispose);
    cold.reconcile([closed]);
    expect(cold.fundNavHistoryFor(closed, _fund.id), isNull);
    expect(cold.hasSupportedHoldings(closed), isFalse);
    expect(cold.stateFor(closed).enabled, isFalse);
  });

  test('删除账户后同ID重建也不复活原账户的公开历史', () async {
    final store = _CacheStore();
    final adapter = _FundHistoryAdapter(() => _now);
    final closed = _closedPortfolio();
    final sync = await _createSync(
      adapter,
      closed,
      clock: () => _now,
      store: store,
    );
    addTearDown(sync.dispose);
    expect(await sync.refresh(closed, isCurrent: () => true), isTrue);
    final savedDeletion = store.nextCacheWrite();
    sync.reconcile([]);
    await savedDeletion;
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNull);
    sync.reconcile([closed]);
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNull);
    expect(sync.quotesFor(closed, includeFundHistory: true), isEmpty);
  });

  test('同账户同基金ID变币种后丢弃旧历史，改回USD也不能复活', () async {
    final adapter = _FundHistoryAdapter(() => _now);
    final original = _portfolio();
    final sync = await _createSync(adapter, original, clock: () => _now);
    addTearDown(sync.dispose);
    expect(await sync.refresh(original, isCurrent: () => true), isTrue);
    const changedSecurity = StockSecurity(
      symbol: 'HK0001039582',
      name: '同ID错误港币身份',
      market: StockMarket.hk,
      currencyCode: 'HKD',
      type: InvestmentSecurityType.fund,
    );
    expect(changedSecurity.id, _fund.id);
    final changed = _portfolio(currency: 'HKD', security: changedSecurity);
    sync.reconcile([changed]);
    expect(sync.fundNavHistoryFor(changed, _fund.id), isNull);
    sync.reconcile([original]);
    expect(sync.fundNavHistoryFor(original, _fund.id), isNull);
    expect(adapter.requests, 1);
  });

  test('基金改成同代码股票时不能复用或在改回基金后复活历史', () async {
    final adapter = _FundHistoryAdapter(() => _now);
    final original = _portfolio();
    final sync = await _createSync(adapter, original, clock: () => _now);
    addTearDown(sync.dispose);
    expect(await sync.refresh(original, isCurrent: () => true), isTrue);
    const stockIdentity = StockSecurity(
      symbol: 'HK0001039582',
      name: '相同文本的股票身份',
      market: StockMarket.hk,
      currencyCode: 'USD',
    );
    final changed = _portfolio(security: stockIdentity);
    sync.reconcile([changed]);
    expect(sync.fundNavHistoryFor(changed, stockIdentity.id), isNull);
    sync.reconcile([original]);
    expect(sync.fundNavHistoryFor(original, _fund.id), isNull);
    expect(adapter.requests, 1);
  });

  test('清仓后重绑的历史实际保存到KV，冷启动仍可读且不再请求', () async {
    final store = _CacheStore();
    final adapter = _FundHistoryAdapter(() => _now);
    final original = _portfolio();
    final sync = await _createSync(
      adapter,
      original,
      clock: () => _now,
      store: store,
    );
    expect(await sync.refresh(original, isCurrent: () => true), isTrue);
    final closed = _closedPortfolio();
    final saved = store.nextCacheWrite();
    sync.reconcile([closed]);
    await saved;
    sync.dispose();

    final cold = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(
        adapters: [adapter],
        allowResearchSources: true,
      ),
      clock: () => _now,
    );
    addTearDown(cold.dispose);
    final reconciled = store.nextCacheWrite();
    cold.reconcile([closed]);
    await reconciled;
    expect(cold.quotesFor(closed), isEmpty);
    expect(cold.fundNavHistoryFor(closed, _fund.id)!.points, hasLength(2));
    expect(cold.hasSupportedHoldings(closed), isFalse);
    expect(adapter.requests, 1);
  });

  test('显式清缓存后内存和冷启动均无历史，已采用清仓基金可重新补取', () async {
    final store = _CacheStore();
    final adapter = _FundHistoryAdapter(() => _now);
    final closed = _closedPortfolio();
    final sync = await _createSync(
      adapter,
      closed,
      clock: () => _now,
      store: store,
    );
    expect(await sync.refresh(closed, isCurrent: () => true), isTrue);
    await sync.clearCache();
    expect(sync.fundNavHistoryFor(closed, _fund.id), isNull);
    expect(sync.hasSupportedHoldings(closed), isTrue);
    final raw =
        jsonDecode(store.read('investment_quote_cache_v1')!)
            as Map<String, Object?>;
    expect(raw['rows'], isEmpty);
    sync.dispose();
    final cold = await _createSync(
      adapter,
      closed,
      clock: () => _now,
      store: store,
    );
    addTearDown(cold.dispose);
    expect(cold.fundNavHistoryFor(closed, _fund.id), isNull);
    expect(cold.hasSupportedHoldings(closed), isTrue);
    expect(adapter.requests, 1);
  });

  test('Controller编辑及全卖后用原NAV重算参考历史，不新增收入交易或现金收益', () async {
    final store = LocalKeyValueStore()..write('verifin.locale.v1', 'zh');
    final adapter = _FundHistoryAdapter(DateTime.now);
    final controller = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(
        adapters: [adapter],
        allowResearchSources: true,
      ),
    );
    addTearDown(controller.dispose);
    final account = investmentAccountFixture(id: _accountId);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime.utc(2026, 10, 1),
        securities: const [_fund],
        manualPrices: {_fund.id: '100'},
      ),
      isTrue,
    );
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: _fund,
        event: _event('buy', StockEventKind.buy, 25),
        referencePrice: '100',
      ),
      isTrue,
    );
    final sync = controller.investmentQuoteSync;
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    var current = controller.investmentFor(account.id)!;
    sync.setVisible(current);
    expect(await sync.refresh(current, isCurrent: () => true), isTrue);
    expect(
      await controller.setInvestmentMarketPrice(account.id, _fund.id, true),
      isTrue,
    );
    final originalEntries = jsonEncode(
      controller.entries.map((entry) => entry.toJson()).toList(),
    );
    expect(
      controller
          .fundReferenceHistoryFor(account.id, _fund.id)
          .last
          .cumulativeProfit
          .toString(),
      '10',
    );

    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: _fund,
        event: _event('buy', StockEventKind.buy, 25, price: '99'),
      ),
      isTrue,
    );
    expect(
      controller
          .fundReferenceHistoryFor(account.id, _fund.id)
          .last
          .cumulativeProfit
          .toString(),
      '20',
    );
    expect(adapter.requests, 1);
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: _fund,
        event: _event(
          'sell',
          StockEventKind.sell,
          26,
          sequence: 2,
          price: '101',
        ),
      ),
      isTrue,
    );
    current = controller.investmentFor(account.id)!;
    final history = controller.fundReferenceHistoryFor(account.id, _fund.id);
    expect(history, hasLength(2));
    expect(history.last.quantity.toString(), '0');
    expect(history.last.marketValue.toString(), '0');
    expect(history.last.cumulativeProfit.toString(), '20');
    expect(controller.accountBalance(account), 10020);
    expect(sync.quotesFor(current), isEmpty);
    expect(sync.fundNavHistoryFor(current, _fund.id), isNotNull);
    expect(sync.hasSupportedHoldings(current), isFalse);
    expect(current.valuationSnapshots, isEmpty);
    expect(
      jsonEncode(controller.entries.map((entry) => entry.toJson()).toList()),
      originalEntries,
    );
    expect(adapter.requests, 1);
  });
}
