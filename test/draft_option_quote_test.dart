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
}
