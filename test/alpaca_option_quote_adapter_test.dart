import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/alpaca_option_quote_adapter.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';

const _symbol = 'AAPL240426C00162500';
final _now = DateTime.utc(2024, 4, 22, 20);

/// 文档中的合约身份；不是用户持仓或当前市场的真实验证记录。
MarketQuoteRequest _request({
  String symbol = _symbol,
  StockMarket market = StockMarket.us,
  String currency = 'USD',
  String expiry = '2024-04-26',
  String strike = '162.5',
  String underlying = 'us:stock:AAPL',
  OptionRight right = OptionRight.call,
  bool option = true,
}) => MarketQuoteRequest(
  StockSecurity(
    symbol: symbol,
    name: '测试公开合约身份',
    market: market,
    currencyCode: currency,
    option: option
        ? OptionContract(
            underlyingId: underlying,
            expiry: expiry,
            right: right,
            strike: strike,
            premiumMultiplier: '100',
            settlement: OptionSettlement.unsupported,
            specification: '此私有说明不得发送给行情来源',
          )
        : null,
  ),
);

/// 原封提取的官方 OpenAPI 示例，只验证字段协议，不表示已做真实凭证联网验收。
String _example() => File(
  'test/fixtures/investments/alpaca_option_snapshots_official_example.json',
).readAsStringSync();

/// 官方示例带分页token；单页测试明确移除此字段，仅构造协议边界输入。
String _unpagedExample() => _example().replaceFirst(
  RegExp(r'"next_page_token":\s*"[^"]+"'),
  '"next_page_token": null',
);

AlpacaOptionQuoteResponse _response({
  String? body,
  int status = 200,
  int contentLength = -1,
}) => AlpacaOptionQuoteResponse(
  statusCode: status,
  contentLength: contentLength,
  body: Stream.value(utf8.encode(body ?? _unpagedExample())),
);

/// 仅在内存捕获测试凭证及请求，不访问网络或写日志。
class _Transport implements AlpacaOptionQuoteTransport {
  _Transport(this.respond);
  final FutureOr<AlpacaOptionQuoteResponse> Function(Uri) respond;
  final uris = <Uri>[];
  String? key, secret;
  bool closed = false;

  @override
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  }) async {
    uris.add(uri);
    key = keyId;
    secret = secretKey;
    return respond(uri);
  }

  @override
  void close() {
    closed = true;
  }
}

AlpacaOptionQuoteAdapter _adapter(_Transport transport) =>
    AlpacaOptionQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _now,
    )..configure(keyId: 'test-key', secretKey: 'test-secret');

/// 在文档结构上注入边界条件；此函数生成的值始终只是测试输入。
String _changed(void Function(Map<String, Object?>) mutate) {
  final map = jsonDecode(_unpagedExample()) as Map<String, Object?>;
  mutate(map);
  return jsonEncode(map);
}

Map<String, Object?> _child(Map<String, Object?> map, String key) =>
    map[key]! as Map<String, Object?>;

Map<String, Object?> _snapshot(Map<String, Object?> map) =>
    _child(_child(map, 'snapshots'), _symbol);

class _Headers implements HttpHeaders {
  final values = <String, Object>{
    HttpHeaders.cookieHeader: 'old-cookie',
    HttpHeaders.authorizationHeader: 'old-auth',
    HttpHeaders.proxyAuthorizationHeader: 'old-proxy',
  };
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  void removeAll(String name) => values.remove(name.toLowerCase());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => -1;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(_example())).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpRequest implements HttpClientRequest {
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  final _Headers headers = _Headers();
  @override
  final cookies = [Cookie('old', 'session')];
  @override
  Future<HttpClientResponse> close() async => _HttpResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpClient implements HttpClient {
  final request = _HttpRequest();
  final uris = <Uri>[];
  @override
  Duration? connectionTimeout;
  String Function(Uri)? proxy;
  bool forceClosed = false;
  @override
  set findProxy(String Function(Uri)? value) {
    proxy = value;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    return request;
  }

  @override
  void close({bool force = false}) {
    forceClosed = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('未配置或清除凭证时不支持、不创建连接，来源不声称已获准', () async {
    var created = 0;
    final adapter = AlpacaOptionQuoteAdapter(
      transportFactory: () {
        created++;
        return _Transport((_) => _response());
      },
    );
    expect(adapter.configured, isFalse);
    expect(adapter.supports(_request()), isFalse);
    expect(await adapter.fetch([_request()]), isEmpty);
    expect(created, 0);
    expect(adapter.capability.id, 'Alpaca OPRA');
    expect(adapter.capability.approved, isFalse);
    expect(adapter.capability.researchOnly, isTrue);
    adapter.configure(keyId: 'key', secretKey: 'secret');
    expect(adapter.supports(_request()), isTrue);
    expect(
      () => adapter.configure(keyId: '', secretKey: 'secret'),
      throwsFormatException,
    );
    expect(adapter.configured, isTrue);
    expect(
      () => adapter.configure(keyId: 'key', secretKey: 'x' * 513),
      throwsFormatException,
    );
    expect(
      () => adapter.configure(keyId: 'key', secretKey: 'a\nb'),
      throwsFormatException,
    );
    expect(adapter.configured, isTrue);
    adapter.configure(keyId: '', secretKey: '');
    expect(adapter.configured, isFalse);
    expect(await adapter.fetch([_request()]), isEmpty);
    expect(created, 0);
  });

  test('OCC与到期、方向、行权价、标的、市场及币种严格一致', () {
    final adapter = _adapter(_Transport((_) => _response()));
    expect(adapter.supports(_request()), isTrue);
    expect(adapter.supports(_request(strike: '162.500')), isTrue);
    for (final request in [
      _request(symbol: 'TEST-AAPL240426C00162500'),
      _request(symbol: 'AAPL1240426C00162500'),
      _request(symbol: 'BRK.B240426C00162500', underlying: 'us:stock:BRK.B'),
      _request(symbol: 'aapl240426C00162500'),
      _request(symbol: 'AAPL240231C00162500', expiry: '2024-02-31'),
      _request(symbol: 'AAPL240426P00162500'),
      _request(symbol: 'AAPL240426C00162501'),
      _request(strike: '162.50001'),
      _request(strike: '0'),
      _request(strike: 'not-price'),
      _request(expiry: '2024-04-27'),
      _request(underlying: 'us:stock:MSFT'),
      _request(underlying: 'hk:stock:AAPL'),
      _request(right: OptionRight.put),
      _request(market: StockMarket.hk),
      _request(currency: 'HKD'),
      _request(option: false),
    ]) {
      expect(adapter.supports(request), isFalse, reason: request.symbol);
    }
    expect(
      adapter.supports(
        _request(symbol: 'AAPL240426P00162500', right: OptionRight.put),
      ),
      isTrue,
    );
  });

  test('官方文档示例的单页变体解析为权利金中间价，保留字段时间和未知延迟', () async {
    final transport = _Transport((_) => _response());
    final adapter = _adapter(transport);
    final request = _request();
    final quote = (await adapter.fetch([request, request])).single;
    expect(quote.bid, '4.15');
    expect(quote.ask, '4.3');
    expect(quote.last, '4.1');
    expect(quote.bidAt, DateTime.parse('2024-04-22T19:59:59.992734Z'));
    expect(quote.askAt, quote.bidAt);
    expect(quote.lastAt, DateTime.parse('2024-04-22T19:57:32.589554Z'));
    expect(quote.reference(request, _now)?.price, '4.225');
    expect(quote.unit, QuotePriceUnit.premiumUnit);
    expect(quote.delayMinutes, isNull);
    expect(quote.tradeState, QuoteTradeState.unknown);
    expect(quote.fetchedAt, _now);
    expect(transport.closed, isTrue);
    expect(
      transport.uris.single.toString(),
      'https://data.alpaca.markets/v1beta1/options/snapshots?symbols=$_symbol&feed=opra',
    );
    expect(transport.key, 'test-key');
    expect(transport.secret, 'test-secret');
    expect(transport.uris.single.toString(), isNot(contains('test-secret')));
    expect(
      transport.uris.single.queryParameters.keys,
      unorderedEquals(['symbols', 'feed']),
    );
  });

  test('保持数值token八位精度和尾零，不经过double或修改字符串转义', () async {
    final body = _unpagedExample()
        .replaceFirst('4.15', '123456789012.12345678')
        .replaceFirst('4.3,', '123456789012.12345680,');
    final transport = _Transport((_) => _response(body: body));
    final quote = (await _adapter(transport).fetch([_request()])).single;
    expect(quote.bid, '123456789012.12345678');
    expect(quote.ask, '123456789012.12345680');
    expect(quote.reference(_request(), _now)?.price, '123456789012.12345679');
    final escaped = _changed((map) {
      map['unused'] = 'escaped \\" quote 1234 \\n';
    });
    expect(
      await _adapter(
        _Transport((_) => _response(body: escaped)),
      ).fetch([_request()]),
      hasLength(1),
    );
  });

  test('非匹配合约键不成为请求证券的报价', () async {
    final body = _changed((map) {
      final snapshots = _child(map, 'snapshots');
      snapshots['AAPL240426P00162500'] = snapshots.remove(_symbol);
    });
    expect(
      await _adapter(
        _Transport((_) => _response(body: body)),
      ).fetch([_request()]),
      isEmpty,
    );
  });

  test('缺时间、无时区、溢出日期或未来报价不会用抓取时刻补造', () async {
    for (final time in [
      null,
      '2024-04-22T19:59:59',
      '2024-02-31T19:59:59Z',
      '2024-04-22T24:00:00Z',
      '2024-04-22T19:59:59+25:00',
      '2024-04-23T19:59:59Z',
    ]) {
      final body = _changed((map) {
        final snapshot = _snapshot(map);
        _child(snapshot, 'latestQuote')['t'] = time;
        _child(snapshot, 'latestTrade')['t'] = time;
      });
      expect(
        await _adapter(
          _Transport((_) => _response(body: body)),
        ).fetch([_request()]),
        isEmpty,
        reason: '$time',
      );
    }
  });

  test('无效双边价只允许回退到有源时间的正成交价', () async {
    for (final bid in [0, -1, 4.4, 1.123456789, 'NaN', '1e-8']) {
      final body = _changed((map) {
        _child(_snapshot(map), 'latestQuote')['bp'] = bid;
      });
      final quote = (await _adapter(
        _Transport((_) => _response(body: body)),
      ).fetch([_request()])).single;
      expect(quote.reference(_request(), _now)?.price, '4.1');
      expect(quote.reference(_request(), _now)?.midpoint, isFalse);
    }
    final body = _changed((map) {
      _snapshot(map).remove('latestTrade');
      _child(_snapshot(map), 'latestQuote')['bp'] = 0;
    });
    expect(
      await _adapter(
        _Transport((_) => _response(body: body)),
      ).fetch([_request()]),
      isEmpty,
    );
  });

  test('HTTP拒绝和跳转不重试、不改indicative，异常不带正文或凭证', () async {
    for (final code in [301, 302, 400, 401, 403, 429, 500]) {
      final transport = _Transport(
        (_) => _response(status: code, body: 'test-secret response'),
      );
      await expectLater(
        _adapter(transport).fetch([_request()]),
        throwsA(
          isA<AlpacaOptionQuoteException>().having(
            (e) => '$e',
            '安全状态',
            'Alpaca 行情请求失败：HTTP $code',
          ),
        ),
      );
      expect(transport.uris, hasLength(1));
      expect(transport.closed, isTrue);
    }
    final transport = _Transport(
      (_) => throw StateError('test-secret APCA-API-SECRET-KEY'),
    );
    await expectLater(
      _adapter(transport).fetch([_request()]),
      throwsA(
        isA<AlpacaOptionQuoteException>().having(
          (e) => '$e',
          '脱敏异常',
          isNot(contains('test-secret')),
        ),
      ),
    );
  });

  test('损坏JSON、声明大小及流式累计超限均失败并关闭连接', () async {
    for (final body in [
      '{',
      '{"snapshots":[]}',
      '{"snapshots":{},"x":01}',
      '{"snapshots":{},"x":1e}',
      '{"snapshots":{},1:"invalid numeric key"}',
      _example(),
    ]) {
      final transport = _Transport((_) => _response(body: body));
      await expectLater(
        _adapter(transport).fetch([_request()]),
        throwsA(isA<AlpacaOptionQuoteException>()),
      );
      expect(transport.closed, isTrue);
    }
    final oversized = _Transport(
      (_) =>
          _response(contentLength: AlpacaOptionQuoteAdapter.maximumBytes + 1),
    );
    await expectLater(
      _adapter(oversized).fetch([_request()]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    final streaming = _Transport(
      (_) => AlpacaOptionQuoteResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          List.filled(AlpacaOptionQuoteAdapter.maximumBytes, 32),
          [32],
        ]),
      ),
    );
    await expectLater(
      _adapter(streaming).fetch([_request()]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    expect(oversized.closed, isTrue);
    expect(streaming.closed, isTrue);
  });

  testWidgets('整批十五秒超时会实际关闭连接', (tester) async {
    final pending = Completer<AlpacaOptionQuoteResponse>();
    final transport = _Transport((_) => pending.future);
    final expectation = expectLater(
      _adapter(transport).fetch([_request()]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    await tester.pump(const Duration(seconds: 16));
    await expectation;
    expect(transport.closed, isTrue);
  });

  test('批次上限及全部不支持都不创建请求，配置变化使旧结果失效', () async {
    final pending = Completer<AlpacaOptionQuoteResponse>();
    final transport = _Transport((_) => pending.future);
    final adapter = _adapter(transport);
    await expectLater(
      adapter.fetch(List.filled(21, _request())),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    expect(await adapter.fetch([_request(option: false)]), isEmpty);
    expect(transport.uris, isEmpty);
    final oldResult = adapter.fetch([_request()]);
    adapter.configure(keyId: 'new-key', secretKey: 'new-secret');
    expect(transport.closed, isTrue);
    pending.complete(_response());
    expect(await oldResult, isEmpty);
    expect(adapter.configured, isTrue);
  });

  test('真实HTTP传输固定地址、feed与头，禁重定向、代理及旧会话', () async {
    final client = _HttpClient();
    final transport = AlpacaHttpOptionQuoteTransport(client: client);
    final uri = Uri.https('data.alpaca.markets', '/v1beta1/options/snapshots', {
      'symbols': _symbol,
      'feed': 'opra',
    });
    await transport.get(uri, keyId: 'test-key', secretKey: 'test-secret');
    expect(client.uris, [uri]);
    expect(client.connectionTimeout, const Duration(seconds: 10));
    expect(client.proxy?.call(uri), 'DIRECT');
    expect(client.request.followRedirects, isFalse);
    expect(client.request.persistentConnection, isFalse);
    expect(client.request.cookies, isEmpty);
    expect(client.request.headers.values, {
      'accept': 'application/json',
      'apca-api-key-id': 'test-key',
      'apca-api-secret-key': 'test-secret',
    });
    for (final forbidden in [
      uri.replace(scheme: 'http'),
      uri.replace(host: 'example.com'),
      uri.replace(port: 8443),
      uri.replace(userInfo: 'user:pass'),
      uri.replace(fragment: 'x'),
      uri.replace(path: '/v1beta1/options/quotes/latest'),
      uri.replace(query: 'symbols=$_symbol&feed=indicative'),
      uri.replace(query: 'symbols=$_symbol&feed=opra&feed=indicative'),
      uri.replace(query: 'symbols=$_symbol&feed=opra&proxy=example.com'),
    ]) {
      await expectLater(
        transport.get(forbidden, keyId: 'test-key', secretKey: 'test-secret'),
        throwsFormatException,
      );
    }
    expect(client.uris, hasLength(1));
    transport.close();
    expect(client.forceClosed, isTrue);
  });
}
