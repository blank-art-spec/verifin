import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/alpaca_option_quote_adapter.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/option_quote_credential_store.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';

final _time = DateTime.utc(2026, 1, 1, 4);
final _request = MarketQuoteRequest.usOptionSymbol('AVGO261218P00300000');

/// 所有价格及时间都是本地夹具；查询不接触真实网络或设备凭证。
MarketQuote _quote({
  String? id,
  String source = '本地测试夹具',
  String currency = 'USD',
  QuotePriceUnit unit = QuotePriceUnit.premiumUnit,
  String? bid = '4',
  String? ask = '6',
  String? last = '4.25',
  DateTime? time,
}) => MarketQuote(
  securityId: id ?? _request.securityId,
  source: source,
  currency: currency,
  unit: unit,
  fetchedAt: _time,
  bid: bid,
  ask: ask,
  last: last,
  bidAt: time ?? _time,
  askAt: time ?? _time,
  lastAt: time ?? _time,
);

class _Preferences extends LocalKeyValueStore {
  int writes = 0;

  @override
  Future<void> writeAndFlush(String key, String value) async {
    writes++;
    await super.writeAndFlush(key, value);
  }
}

FixtureQuoteAdapter _adapter(
  Future<List<MarketQuote>> Function(List<MarketQuoteRequest>) respond,
) => FixtureQuoteAdapter(respond, support: (request) => request.option);

InvestmentQuoteSync _sync(
  MarketQuoteAdapter adapter, {
  LocalKeyValueStore? store,
}) => InvestmentQuoteSync(
  store: store ?? LocalKeyValueStore(),
  client: MarketQuoteClient(adapters: [adapter]),
  clock: () => _time,
);

class _Credentials implements OptionQuoteCredentialStore {
  OptionQuoteCredentials? value;
  Completer<void>? saving, release;

  @override
  Future<OptionQuoteCredentials?> read() async => value;

  @override
  Future<void> write(OptionQuoteCredentials credentials) async {
    saving?.complete();
    if (release != null) await release!.future;
    value = credentials;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

/// 在真实 Alpaca 解析器外替换传输边界，可让旧连接在关闭后仍迟到。
class _Transport implements AlpacaOptionQuoteTransport {
  int calls = 0, closes = 0;
  final firstRequest = Completer<void>();
  Completer<AlpacaOptionQuoteResponse>? pending;

  /// 构造明确早于免费截止时点的每单位成交，不提供买卖价以验证不会合成中间价。
  /// 所有身份、价格和时间都为本地夹具，不能据此宣称免费账户已联网验证。
  /// [requireNextPage] 为 true 时返回不计价的取消成交及下一页令牌，迫使有效查询继续分页。
  AlpacaOptionQuoteResponse response({bool requireNextPage = false}) =>
      AlpacaOptionQuoteResponse(
        statusCode: 200,
        body: Stream.value(
          utf8.encode(
            jsonEncode({
              'trades': {
                _request.symbol: [
                  {
                    'p': 5,
                    't': _time
                        .subtract(const Duration(minutes: 20))
                        .toIso8601String(),
                    'c': requireNextPage ? 'A' : 'I',
                    's': 1,
                    'x': 'B',
                  },
                ],
              },
              'next_page_token': requireNextPage ? 'next-fixture-page' : null,
            }),
          ),
        ),
      );

  /// 校验 [uri] 是免费历史成交路径；[keyId]/[secretKey] 只供接口兼容，不持久化。
  /// [pending] 非空时让响应延后，覆盖改凭证后旧查询不能回填的行为。
  @override
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  }) async {
    calls++;
    if (!firstRequest.isCompleted) firstRequest.complete();
    expect(uri.path, '/v1beta1/options/trades');
    expect(uri.queryParameters['symbols'], _request.symbol);
    expect(uri.queryParameters['sort'], 'desc');
    expect(uri.queryParameters, isNot(contains('feed')));
    expect(
      DateTime.parse(
        uri.queryParameters['end']!,
      ).isAfter(_time.subtract(const Duration(minutes: 15))),
      isFalse,
    );
    if (pending != null) return pending!.future;
    return response();
  }

  /// 记录真实适配器退出时关闭传输的次数，验证取消分支仍释放连接。
  @override
  void close() => closes++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('完整代码产生公开请求身份并保留千分之一行权价，不需要证券或乘数', () {
    final request = MarketQuoteRequest.usOptionSymbol(' avgo261218p00300125 ');
    expect(request.symbol, 'AVGO261218P00300125');
    expect(request.securityId, 'us:option:AVGO261218P00300125');
    expect(request.optionUnderlyingSymbol, 'AVGO');
    expect(request.optionExpiry, '2026-12-18');
    expect(request.optionRight, OptionRight.put);
    expect(request.optionStrike, '300.125');
    expect(request.currency, 'USD');
    expect(request.option, isTrue);
    expect(request.fund, isFalse);
    for (final invalid in [
      'AVGO',
      'TEST261218C00300000',
      'AVGO1261218C00300000',
      'AVGO260230C00300000',
      'AVGO261218C00000000',
    ]) {
      expect(
        () => MarketQuoteRequest.usOptionSymbol(invalid),
        throwsFormatException,
      );
    }
  });

  test('未启用、来源未准入和非期权请求都不联网', () async {
    final adapter = _adapter((_) async => [_quote()]);
    final sync = _sync(adapter);
    addTearDown(sync.dispose);
    expect(
      (await sync.fetchDraftOptionQuote(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.networkDisabled,
    );
    await sync.configure(enabled: true, automatic: false);
    expect(
      (await sync.fetchDraftOptionQuote(
        MarketQuoteRequest(avgoFixture),
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.unsupported,
    );
    adapter.approved = false;
    expect(
      (await sync.fetchDraftOptionQuote(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.unsupported,
    );
    expect(adapter.requests, 0);
  });

  test('无真实持仓也可取得中间价，草稿查询不写缓存或更改刷新状态', () async {
    final store = _Preferences();
    final adapter = _adapter((_) async => [_quote()]);
    final sync = _sync(adapter, store: store);
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final writes = store.writes, state = sync.state.value;
    final result = await sync.fetchDraftOptionQuote(
      _request,
      isCurrent: () => true,
    );
    expect(result.status, DraftOptionQuoteStatus.available);
    expect(result.quote!.reference(_request, _time)?.price, '5');
    expect(result.quote!.reference(_request, _time)?.midpoint, isTrue);
    expect(adapter.requests, 1);
    expect(adapter.lastRequests.single, same(_request));
    expect(store.writes, writes);
    expect(store.read('investment_quote_cache_v1'), isNull);
    expect(sync.state.value, same(state));
  });

  test('旧成交价仍携带旧时间；错误身份、来源、币种或单位不得采用', () async {
    var response = [
      _quote(
        bid: null,
        ask: null,
        time: _time.subtract(const Duration(days: 2)),
      ),
    ];
    final sync = _sync(_adapter((_) async => response));
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final old = await sync.fetchDraftOptionQuote(
      _request,
      isCurrent: () => true,
    );
    expect(old.quote!.reference(_request, _time)?.price, '4.25');
    expect(old.quote!.reference(_request, _time)?.midpoint, isFalse);
    expect(old.quote!.isOlderThanOneDay(_request, _time), isTrue);
    response = [
      _quote(id: 'us:option:MSFT261218P00300000'),
      _quote(source: '错误来源'),
      _quote(currency: 'HKD'),
      _quote(unit: QuotePriceUnit.share),
      _quote(time: _time.add(const Duration(hours: 1))),
      _quote(bid: '0', ask: '0', last: '0'),
    ];
    expect(
      (await sync.fetchDraftOptionQuote(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.noQuote,
    );
  });

  test('页面修订或关闭联网后迟到结果取消，重复点击不再发送', () async {
    final pending = Completer<List<MarketQuote>>();
    final adapter = _adapter((_) => pending.future);
    final sync = _sync(adapter);
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final revision = sync.draftQuoteRevision;
    final first = sync.fetchDraftOptionQuote(_request, isCurrent: () => true);
    expect(
      (await sync.fetchDraftOptionQuote(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.cancelled,
    );
    expect(adapter.requests, 1);
    await sync.configure(enabled: false, automatic: false);
    expect(sync.draftQuoteRevision, greaterThan(revision));
    pending.complete([_quote()]);
    expect((await first).status, DraftOptionQuoteStatus.cancelled);
  });

  test('退后台或销毁使未完成查询失效，后台不新建请求', () async {
    for (final dispose in [false, true]) {
      final pending = Completer<List<MarketQuote>>();
      final adapter = _adapter((_) => pending.future);
      final sync = _sync(adapter);
      await sync.configure(enabled: true, automatic: false);
      sync.setForegroundPortfolios(const []);
      final future = sync.fetchDraftOptionQuote(
        _request,
        isCurrent: () => true,
      );
      if (dispose) {
        sync.dispose();
      } else {
        sync.setForegroundPortfolios(null);
      }
      expect(
        (await sync.fetchDraftOptionQuote(
          _request,
          isCurrent: () => true,
        )).status,
        DraftOptionQuoteStatus.cancelled,
      );
      pending.complete([_quote()]);
      expect((await future).status, DraftOptionQuoteStatus.cancelled);
      expect(adapter.requests, 1);
      if (!dispose) sync.dispose();
    }
  });

  test('草稿关闭联网后首屏迟到，不再请求下一页成交或写入缓存', () async {
    final transport = _Transport()
      ..pending = Completer<AlpacaOptionQuoteResponse>();
    final adapter = AlpacaOptionQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _time,
    )..configure(keyId: 'fixture-key', secretKey: 'fixture-secret');
    final store = LocalKeyValueStore();
    final sync = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(
        adapters: [adapter],
        allowResearchSources: true,
      ),
      clock: () => _time,
    );
    addTearDown(sync.dispose);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    final fetching = sync.fetchDraftOptionQuote(
      _request,
      isCurrent: () => true,
    );
    await transport.firstRequest.future;

    // 首屏没有可采用成交且携带下一页；取消须进入真实适配器内部，阻止追加网络请求。
    expect(await sync.configure(enabled: false, automatic: false), isTrue);
    transport.pending!.complete(transport.response(requireNextPage: true));

    expect((await fetching).status, DraftOptionQuoteStatus.cancelled);
    expect(transport.calls, 1);
    expect(transport.closes, 1);
    expect(store.read('investment_quote_cache_v1'), isNull);
  });

  testWidgets('十五秒超时返回失败，迟到错误不能修改结果或泄漏异步异常', (tester) async {
    final pending = Completer<List<MarketQuote>>();
    final sync = _sync(_adapter((_) => pending.future));
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final result = sync.fetchDraftOptionQuote(_request, isCurrent: () => true);
    await tester.pump(const Duration(seconds: 16));
    expect((await result).status, DraftOptionQuoteStatus.failed);
    pending.completeError(StateError('迟到的本地夹具错误'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('Controller 查询未保存期权不改变账目，切换账本取消旧请求', () async {
    Completer<List<MarketQuote>>? pending;
    final adapter = _adapter((_) async {
      if (pending != null) return pending.future;
      return [_quote()];
    });
    final store = _Preferences();
    final controller = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
    );
    addTearDown(controller.dispose);
    await controller.investmentQuoteSync.configure(
      enabled: true,
      automatic: false,
    );
    Map<String, Object?> accountData() =>
        (jsonDecode(controller.exportDataJson()) as Map<String, Object?>)
          ..remove('exportedAt');
    final before = accountData(), writes = store.writes;
    final result = await controller.fetchDraftOptionQuote(_request);
    expect(result.status, DraftOptionQuoteStatus.available);
    expect(accountData(), before);
    expect(store.writes, writes);
    pending = Completer<List<MarketQuote>>();
    final old = controller.fetchDraftOptionQuote(_request);
    controller.addLedgerBook('另一本账本');
    pending.complete([_quote()]);
    expect((await old).status, DraftOptionQuoteStatus.cancelled);
    await controller.waitForPendingWrites();
  });

  test('缺凭证明确反馈；来源配置保存及清除撤销未保存期权的旧请求', () async {
    final credentials = _Credentials();
    final transport = _Transport();
    final adapter = AlpacaOptionQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _time,
    );
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(
        adapters: [adapter],
        allowResearchSources: true,
      ),
      optionQuoteCredentialStore: credentials,
    );
    addTearDown(controller.dispose);
    await controller.investmentQuoteSync.configure(
      enabled: true,
      automatic: false,
    );
    expect(
      (await controller.fetchDraftOptionQuote(_request)).status,
      DraftOptionQuoteStatus.credentialsRequired,
    );
    expect(transport.calls, 0);
    expect(
      await controller.saveOptionQuoteCredentials(
        'fixture-key',
        'fixture-secret',
      ),
      isTrue,
    );
    transport.pending = Completer<AlpacaOptionQuoteResponse>();
    final previous = controller.fetchDraftOptionQuote(_request);
    credentials.saving = Completer<void>();
    credentials.release = Completer<void>();
    final revision = controller.investmentQuoteSync.draftQuoteRevision;
    final changing = controller.saveOptionQuoteCredentials(
      'replacement-key',
      'replacement-secret',
    );
    await credentials.saving!.future;
    expect(
      controller.investmentQuoteSync.draftQuoteRevision,
      greaterThan(revision),
    );
    expect(
      (await controller.fetchDraftOptionQuote(_request)).status,
      DraftOptionQuoteStatus.cancelled,
    );
    credentials.release!.complete();
    expect(await changing, isTrue);
    transport.pending!.complete(transport.response());
    expect((await previous).status, DraftOptionQuoteStatus.cancelled);
    transport.pending = null;
    final delayed = await controller.fetchDraftOptionQuote(_request);
    expect(delayed.status, DraftOptionQuoteStatus.available);
    expect(delayed.quote!.source, 'Alpaca OPRA Delayed');
    expect(delayed.quote!.delayMinutes, 15);
    expect(delayed.quote!.reference(_request, _time), (
      price: '5',
      time: _time.subtract(const Duration(minutes: 20)),
      midpoint: false,
    ));
    expect(await controller.saveOptionQuoteCredentials('', ''), isTrue);
    expect(
      (await controller.fetchDraftOptionQuote(_request)).status,
      DraftOptionQuoteStatus.credentialsRequired,
    );
    expect(transport.calls, 2);
  });
}
