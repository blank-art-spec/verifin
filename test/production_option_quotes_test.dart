import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/alpaca_option_quote_adapter.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/nasdaq_option_quote_adapter.dart';
import 'package:verifin/app/investments/production_market_quotes.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';

const _callSymbol = 'AVGO261218C00300000';
const _putSymbol = 'AVGO261218P00300000';
const _testKey = 'local-fixture-key';
const _testSecret = 'local-fixture-secret';

/// OCC 身份及合约规格仅作为本地测试输入，不声称这些价格或乘数来自真实市场。
/// 不同权利金乘数用于检查报价保持每单位口径，只有资产计算乘一次。
StockSecurity _option({bool put = false}) => StockSecurity(
  symbol: put ? _putSymbol : _callSymbol,
  name: '用户私有期权名称',
  market: StockMarket.us,
  currencyCode: 'USD',
  option: OptionContract(
    underlyingId: avgoFixture.id,
    expiry: '2026-12-18',
    right: put ? OptionRight.put : OptionRight.call,
    strike: '300',
    premiumMultiplier: put ? '10' : '100',
    settlement: OptionSettlement.unsupported,
    specification: '私有测试说明，不得随公开行情请求发送',
  ),
);

/// 只有期权持仓；股票定义仅为本地合约标的引用，不能触发腾讯股票请求。
InvestmentPortfolio _holding({bool includePut = false}) {
  final options = [_option(), if (includePut) _option(put: true)];
  return InvestmentPortfolio(
    accountId: '私有期权账户',
    bookId: defaultLedgerBookId,
    currencyCode: 'USD',
    openedAt: DateTime.utc(2026, 10, 1),
    openingCash: '43210',
    securities: [avgoFixture, ...options],
    openingHoldings: [
      for (final security in options)
        StockHolding(
          securityId: security.id,
          short: false,
          quantity: security.option!.right == OptionRight.call ? '2' : '3',
          cost: security.option!.right == OptionRight.call ? '1111' : '222',
        ),
    ],
    manualPrices: {options.first.id: '2', if (includePut) options.last.id: '3'},
  );
}

/// 按官方历史成交结构合成固定延迟价；不是来源原始响应或实时行情。
/// [time] 是抓取测试时钟，成交固定早二十分钟，确保落在免费查询截止时间前；
/// [symbols] 只从实际生产适配器传来的公开查询中提取，条件 I 表示正常自动成交。
String _tradesBody(Iterable<String> symbols, DateTime time) => jsonEncode({
  'trades': {
    for (final symbol in symbols)
      symbol: [
        {
          'p': symbol == _callSymbol ? 5 : 10,
          't': time
              .toUtc()
              .subtract(const Duration(minutes: 20))
              .toIso8601String(),
          'c': 'I',
          's': 1,
          'x': 'B',
        },
      ],
  },
  'next_page_token': null,
});

/// 只替换网络边界，仍通过生产来源选择、凭证门禁、OCC 校验与历史成交解析器。
class _OptionTransport implements AlpacaOptionQuoteTransport {
  /// [time] 固定成交时间基准；[firstResponseGate] 可阻塞首个响应以模拟请求中退后台。
  _OptionTransport(this.time, {this.firstResponseGate});

  final DateTime time;
  final Completer<void>? firstResponseGate;
  final firstRequest = Completer<void>();
  final uris = <Uri>[];
  String? key, secret;
  bool closed = false;

  /// 记录实际请求及认证字段，并按 [uri] 中的单合约身份返回本地延迟成交。
  /// [keyId]/[secretKey] 仅保留在测试内存中，用于确认传输仍使用原有凭证。
  /// 首次请求通知 [firstRequest]，并可等待门闩释放，以便精确插入生命周期取消。
  @override
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  }) async {
    uris.add(uri);
    key = keyId;
    secret = secretKey;
    if (!firstRequest.isCompleted) firstRequest.complete();
    if (uris.length == 1 && firstResponseGate != null) {
      await firstResponseGate!.future;
    }
    final body = utf8.encode(
      _tradesBody(uri.queryParameters['symbols']!.split(','), time),
    );
    return AlpacaOptionQuoteResponse(
      statusCode: 200,
      contentLength: body.length,
      body: Stream.value(body),
    );
  }

  /// 标记本次查询传输已释放，便于检查取消后的连接清理。
  @override
  void close() => closed = true;
}

/// 旧来源显式注入，保留凭证隔离与逐项采用的回归覆盖；生产工厂已不用 Alpaca。
MarketQuoteClient _client(List<_OptionTransport> transports, DateTime time) =>
    MarketQuoteClient(
      allowResearchSources: true,
      adapters: [
        AlpacaOptionQuoteAdapter(
          transportFactory: () {
            final transport = _OptionTransport(time);
            transports.add(transport);
            return transport;
          },
          clock: () => time,
        ),
      ],
    );

class _NasdaqTransport implements NasdaqOptionQuoteTransport {
  _NasdaqTransport({this.available = true});
  bool available;
  final uris = <Uri>[];
  bool closed = false;

  @override
  Future<NasdaqOptionQuoteResponse> get(Uri uri) async {
    uris.add(uri);
    return NasdaqOptionQuoteResponse(
      statusCode: 200,
      body: Stream.value(
        available
            ? File(
                'test/fixtures/investments/nasdaq_option_detail_20261107.json',
              ).readAsBytesSync()
            : utf8.encode('{"data":null,"status":{"rCode":200}}'),
      ),
    );
  }

  @override
  void close() => closed = true;
}

/// 对应已保存的真实行情身份；数量、成本、乘数和后备价始终只是本地测试事实。
InvestmentPortfolio _nasdaqHolding() {
  final options = [
    for (final right in OptionRight.values)
      StockSecurity(
        symbol: right == OptionRight.call
            ? 'AVGO261109C00265000'
            : 'AVGO261109P00265000',
        name: '私有期权持仓',
        market: StockMarket.us,
        currencyCode: 'USD',
        option: OptionContract(
          underlyingId: avgoFixture.id,
          expiry: '2026-11-09',
          right: right,
          strike: '265',
          premiumMultiplier: right == OptionRight.call ? '100' : '10',
          settlement: OptionSettlement.unsupported,
          specification: '私有规格不发送',
        ),
      ),
  ];
  return InvestmentPortfolio(
    accountId: 'private-option-account',
    bookId: defaultLedgerBookId,
    currencyCode: 'USD',
    openedAt: DateTime.utc(2026, 10, 1),
    openingCash: '43210',
    securities: [avgoFixture, ...options],
    openingHoldings: [
      for (final option in options)
        StockHolding(
          securityId: option.id,
          short: false,
          quantity: '2',
          cost: '1111',
        ),
    ],
    manualPrices: {for (final option in options) option.id: '2'},
  );
}

/// 正式来源用真实公开响应，旧 Alpaca 回归仍用本地合成数据，均不触达网络。
void main() {
  test('生产期权无需凭证，联网授权后查询并保留手填和真实账务', () async {
    final time = DateTime.utc(2026, 11, 7, 14);
    final transports = <_NasdaqTransport>[];
    final client = buildProductionMarketQuoteClient(
      tencentTransportFactory: () => throw StateError('不应连接股票来源'),
      cmsTransportFactory: () => throw StateError('不应连接基金来源'),
      nasdaqTransportFactory: () {
        final transport = _NasdaqTransport();
        transports.add(transport);
        return transport;
      },
      clock: () => time,
    );
    final portfolio = _nasdaqHolding();
    final before = portfolio.toJson();
    final call = portfolio.securities[1], put = portfolio.securities[2];
    expect(
      client.adapterFor(MarketQuoteRequest(call)),
      isA<NasdaqOptionQuoteAdapter>(),
    );
    expect(client.adapters.whereType<AlpacaOptionQuoteAdapter>(), isEmpty);
    final store = LocalKeyValueStore();
    final sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => time,
    );
    addTearDown(sync.dispose);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(transports, isEmpty);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(transports, isEmpty);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(transports.single.uris, hasLength(1));
    expect(transports.single.closed, isTrue);
    final quotes = sync.quotesFor(portfolio);
    expect(quotes[call.id]!.last, '32.66');
    expect(quotes[put.id]!.last, '0.38');
    for (final quote in quotes.values) {
      expect(quote.source, 'Nasdaq Options');
      expect(quote.lastAt, isNull);
      expect(quote.sourceTimeUnknown, isTrue);
      expect(quote.fetchedAt, time);
    }
    expect(store.read('investment_quote_cache_v1'), contains('Nasdaq Options'));
    expect(portfolio.toJson(), before);
    expect(portfolio.marketPriceIds, isEmpty);
    expect(
      investmentCashBalance(portfolio: portfolio, entries: const []),
      43210,
    );
    final address = transports.single.uris.single.toString();
    for (final private in [portfolio.accountId, '43210', '1111', call.name]) {
      expect(address, isNot(contains(private)));
    }
  });

  test('Nasdaq 未挂牌或无价时保持手填，不需要补填API密钥', () async {
    final transport = _NasdaqTransport(available: false);
    final portfolio = _nasdaqHolding();
    final before = portfolio.toJson();
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: buildProductionMarketQuoteClient(
        tencentTransportFactory: () => throw StateError('不应连接股票来源'),
        cmsTransportFactory: () => throw StateError('不应连接基金来源'),
        nasdaqTransportFactory: () => transport,
      ),
    );
    addTearDown(sync.dispose);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(portfolio.toJson(), before);
    expect(transport.closed, isTrue);
  });

  test('Nasdaq 参考价逐项采用且只乘一次，刷新缺价后恢复手填估值', () async {
    final transport = _NasdaqTransport();
    final client = buildProductionMarketQuoteClient(
      tencentTransportFactory: () => throw StateError('不应连接股票来源'),
      cmsTransportFactory: () => throw StateError('不应连接基金来源'),
      nasdaqTransportFactory: () => transport,
    );
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: client,
    );
    addTearDown(controller.dispose);
    final account = investmentAccountFixture();
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    final fixture = _nasdaqHolding();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: fixture.openingCash,
        openedAt: fixture.openedAt,
        securities: fixture.securities,
        openingHoldings: fixture.openingHoldings,
        manualPrices: fixture.manualPrices,
      ),
      isTrue,
    );
    final call = fixture.securities[1], put = fixture.securities[2];
    final initial = controller.investmentFor(account.id)!;
    final facts = initial.toJson()..remove('marketPriceIds');
    final sync = controller.investmentQuoteSync;
    sync.setVisible(initial);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(initial, isCurrent: () => true), isTrue);
    expect(controller.accountAssetValue(account), 43650);
    for (final security in [call, put]) {
      expect(
        await controller.setInvestmentMarketPrice(
          account.id,
          security.id,
          true,
        ),
        isTrue,
      );
    }
    var portfolio = controller.investmentFor(account.id)!;
    expect(controller.pricedInvestmentPortfolio(portfolio).manualPrices, {
      call.id: '32.66',
      put.id: '0.38',
    });
    // 43210 + 2 张 × 100 × 32.66 + 2 张 × 10 × 0.38。
    expect(controller.accountAssetValue(account), 49749.6);
    expect(controller.accountBalance(account), 43210);
    transport.available = false;
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    portfolio = controller.investmentFor(account.id)!;
    expect(controller.accountAssetValue(account), 43650);
    expect(controller.pricedInvestmentPortfolio(portfolio).manualPrices, {
      call.id: '2',
      put.id: '2',
    });
    expect(portfolio.toJson()..remove('marketPriceIds'), facts);
  });

  test('显式旧期权来源配置与联网各自授权，获取和清除缓存均不改账务', () async {
    final time = DateTime.utc(2026, 11, 5, 4);
    final transports = <_OptionTransport>[];
    final client = _client(transports, time);
    final adapter = client.adapters
        .whereType<AlpacaOptionQuoteAdapter>()
        .single;
    final portfolio = _holding();
    final option = portfolio.securities.last;
    final request = MarketQuoteRequest(option);
    final original = jsonEncode(portfolio.toJson());
    final store = LocalKeyValueStore();
    final sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => time,
    );
    addTearDown(sync.dispose);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(adapter.configured, isFalse);
    expect(adapter.supports(request), isFalse);
    expect(client.adapterFor(request), isNull);
    expect(transports, isEmpty);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);

    // 即使打开全局联网，尚未配置的期权来源也不能创建请求。
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.state.value.status, QuoteSyncStatus.unavailable);
    expect(transports, isEmpty);
    expect(await sync.configure(enabled: false, automatic: false), isTrue);
    expect(
      await sync.reconfigureSource(
        sourceId: adapter.capability.id,
        configure: () =>
            adapter.configure(keyId: _testKey, secretKey: _testSecret),
        affectedPortfolios: [portfolio],
      ),
      isTrue,
    );
    expect(adapter.configured, isTrue);
    expect(client.adapterFor(request), same(adapter));
    expect(adapter.capability.approved, isFalse);
    expect(sync.state.value.enabled, isFalse);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(transports, isEmpty);

    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(transports, isEmpty);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(transports, hasLength(1));
    final transport = transports.single;
    expect(transport.closed, isTrue);
    expect(transport.key, _testKey);
    expect(transport.secret, _testSecret);
    expect(transport.uris.single.host, 'data.alpaca.markets');
    expect(transport.uris.single.path, '/v1beta1/options/trades');
    final query = transport.uris.single.queryParameters;
    expect(query['symbols'], _callSymbol);
    expect(query['sort'], 'desc');
    expect(query, isNot(contains('feed')));
    final cutoff = DateTime.parse(query['end']!);
    expect(cutoff.isAfter(time.subtract(const Duration(minutes: 15))), isFalse);
    expect(DateTime.parse(query['start']!).isBefore(cutoff), isTrue);
    final address = transport.uris.single.toString();
    for (final private in [
      _testKey,
      _testSecret,
      portfolio.accountId,
      portfolio.openingCash,
      option.name,
      option.option!.specification,
      portfolio.openingHoldings.single.cost!,
    ]) {
      expect(address, isNot(contains(private)));
    }
    final quote = sync.quotesFor(portfolio)[option.id]!;
    expect(quote.source, 'Alpaca OPRA Delayed');
    expect(quote.unit, QuotePriceUnit.premiumUnit);
    expect(quote.currency, 'USD');
    expect(quote.reference(request, time)?.price, '5');
    expect(quote.reference(request, time)?.midpoint, isFalse);
    expect(quote.lastAt, time.subtract(const Duration(minutes: 20)));
    expect(quote.bid, isNull);
    expect(quote.ask, isNull);
    expect(quote.delayMinutes, 15);
    expect(quote.fetchedAt, time);
    expect(sync.state.value.changed, 1);
    expect(sync.state.value.status, QuoteSyncStatus.ready);
    final cached = store.read('investment_quote_cache_v1')!;
    expect(cached, contains('Alpaca OPRA Delayed'));
    expect(cached, isNot(contains(_testKey)));
    expect(cached, isNot(contains(_testSecret)));
    expect(jsonEncode(portfolio.toJson()), original);
    expect(
      investmentCashBalance(portfolio: portfolio, entries: const []),
      43210,
    );
    expect(projectStocks(portfolio).positions.single.cost.toString(), '1111');
    expect(portfolio.manualPrices[option.id], '2');
    expect(portfolio.marketPriceIds, isEmpty);

    expect(
      await sync.reconfigureSource(
        sourceId: adapter.capability.id,
        configure: () => adapter.configure(keyId: '', secretKey: ''),
        affectedPortfolios: [portfolio],
      ),
      isTrue,
    );
    expect(adapter.configured, isFalse);
    expect(adapter.supports(request), isFalse);
    expect(client.adapterFor(request), isNull);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(
      store.read('investment_quote_cache_v1'),
      isNot(contains('Alpaca OPRA')),
    );
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(transports, hasLength(1));
    expect(jsonEncode(portfolio.toJson()), original);
  });

  test('显式旧期权报价逐项采用，100 和 10 乘数只在资产计算中应用一次', () async {
    final time = DateTime.now().toUtc();
    final transports = <_OptionTransport>[];
    final client = _client(transports, time);
    final adapter = client.adapters
        .whereType<AlpacaOptionQuoteAdapter>()
        .single;
    final store = LocalKeyValueStore();
    final controller = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: client,
    );
    addTearDown(controller.dispose);
    final account = investmentAccountFixture();
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    final fixture = _holding(includePut: true);
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: fixture.openingCash,
        openedAt: fixture.openedAt,
        securities: fixture.securities,
        openingHoldings: fixture.openingHoldings,
        manualPrices: fixture.manualPrices,
      ),
      isTrue,
    );
    final call = fixture.securities[1], put = fixture.securities[2];
    final initial = controller.investmentFor(account.id)!;
    final facts = initial.toJson()..remove('marketPriceIds');
    final sync = controller.investmentQuoteSync;
    sync.setVisible(initial);
    expect(
      await controller.setInvestmentMarketPrice(account.id, call.id, true),
      isFalse,
    );
    expect(
      await sync.reconfigureSource(
        sourceId: adapter.capability.id,
        configure: () =>
            adapter.configure(keyId: _testKey, secretKey: _testSecret),
        affectedPortfolios: [initial],
      ),
      isTrue,
    );
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(initial, isCurrent: () => true), isTrue);
    expect(sync.quotesFor(initial), hasLength(2));
    expect(controller.accountBalance(account), 43210);
    // 尚未采用：43210 + 2 张 × 100 × 手填 2 + 3 张 × 10 × 手填 3。
    expect(controller.accountAssetValue(account), 43700);
    expect(controller.investmentFor(account.id)!.toJson(), initial.toJson());

    expect(
      await controller.setInvestmentMarketPrice(account.id, call.id, true),
      isTrue,
    );
    var portfolio = controller.investmentFor(account.id)!;
    expect(portfolio.marketPriceIds, {call.id});
    expect(controller.pricedInvestmentPortfolio(portfolio).manualPrices, {
      call.id: '5',
      put.id: '3',
    });
    expect(controller.accountAssetValue(account), 44300);
    expect(
      await controller.setInvestmentMarketPrice(account.id, put.id, true),
      isTrue,
    );
    portfolio = controller.investmentFor(account.id)!;
    expect(controller.pricedInvestmentPortfolio(portfolio).manualPrices, {
      call.id: '5',
      put.id: '10',
    });
    // 两项都采用：43210 + 2 × 100 × 5 + 3 × 10 × 10，不在适配器内预乘。
    expect(controller.accountAssetValue(account), 44510);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(controller.accountAssetValue(account), 44510);
    expect(portfolio.toJson()..remove('marketPriceIds'), facts);
    expect(portfolio.manualPrices, fixture.manualPrices);
    expect(controller.accountBalance(account), 43210);

    expect(
      await controller.setInvestmentMarketPrice(account.id, call.id, false),
      isTrue,
    );
    portfolio = controller.investmentFor(account.id)!;
    expect(portfolio.marketPriceIds, {put.id});
    expect(controller.accountAssetValue(account), 43910);
    expect(
      await sync.reconfigureSource(
        sourceId: adapter.capability.id,
        configure: () => adapter.configure(keyId: '', secretKey: ''),
        affectedPortfolios: [portfolio],
      ),
      isTrue,
    );
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(controller.accountAssetValue(account), 43700);
    expect(controller.accountBalance(account), 43210);
    expect(
      controller.investmentFor(account.id)!.toJson()..remove('marketPriceIds'),
      facts,
    );
    expect(transports, hasLength(2));
    expect(transports.every((transport) => transport.closed), isTrue);
    for (final transport in transports) {
      // 单合约分别请求才能保证两个合约都取到各自最近成交，不会被整页条数限制吞掉。
      expect(
        transport.uris.map((uri) => uri.queryParameters['symbols']),
        containsAllInOrder([_callSymbol, _putSymbol]),
      );
      expect(transport.uris, hasLength(2));
    }
  });

  test('持仓退后台后首个成交响应迟到，不再查询下一合约或写入缓存', () async {
    final time = DateTime.utc(2026, 11, 5, 4);
    final gate = Completer<void>();
    final transport = _OptionTransport(time, firstResponseGate: gate);
    final client = MarketQuoteClient(
      allowResearchSources: true,
      adapters: [
        AlpacaOptionQuoteAdapter(
          transportFactory: () => transport,
          clock: () => time,
        ),
      ],
    );
    client.adapters.whereType<AlpacaOptionQuoteAdapter>().single.configure(
      keyId: _testKey,
      secretKey: _testSecret,
    );
    final store = LocalKeyValueStore();
    final sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => time,
    );
    addTearDown(sync.dispose);
    final portfolio = _holding(includePut: true);
    sync.reconcile([portfolio]);
    sync.setForegroundPortfolios([portfolio]);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    // 等待初始化的缓存写入队列完成，避免把正常空缓存落盘误判为迟到报价写入。
    await sync.clearCache();
    final cachedBefore = store.read('investment_quote_cache_v1');

    final refreshing = sync.refresh(portfolio, isCurrent: () => true);
    await transport.firstRequest.future;
    // 取消发生在来源请求内部；必须阻止第二合约，不能仅在整批返回后丢弃缓存。
    sync.setForegroundPortfolios(null);
    gate.complete();

    expect(await refreshing, isFalse);
    expect(transport.uris, hasLength(1));
    expect(transport.closed, isTrue);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(store.read('investment_quote_cache_v1'), cachedBefore);
  });
}
