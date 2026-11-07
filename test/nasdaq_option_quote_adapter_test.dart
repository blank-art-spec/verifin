import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/nasdaq_option_quote_adapter.dart';
import 'package:verifin/app/models.dart';

const _call = 'AVGO261109C00265000';
const _put = 'AVGO261109P00265000';
final _now = DateTime.utc(2026, 11, 7, 13, 55);

MarketQuoteRequest _request({
  String symbol = _call,
  String underlying = 'us:stock:AVGO',
  String expiry = '2026-11-09',
  String strike = '265',
  OptionRight right = OptionRight.call,
  StockMarket market = StockMarket.us,
  String currency = 'USD',
  bool option = true,
}) => MarketQuoteRequest(
  StockSecurity(
    symbol: symbol,
    name: '不发送的私有名称',
    market: market,
    currencyCode: currency,
    option: option
        ? OptionContract(
            underlyingId: underlying,
            expiry: expiry,
            right: right,
            strike: strike,
            premiumMultiplier: '10',
            settlement: OptionSettlement.unsupported,
            specification: '不发送的私有交割说明',
          )
        : null,
  ),
);

/// 原始匿名响应原样保留；字段变体仅用于本地校验，不声称为真实市场数据。
String _fixture() => File(
  'test/fixtures/investments/nasdaq_option_detail_20261107.json',
).readAsStringSync();

String _changed(void Function(Map<String, Object?>) change) {
  final value = jsonDecode(_fixture()) as Map<String, Object?>;
  change(value);
  return jsonEncode(value);
}

/// 真实夹具中已知的嵌套对象；显式读取结构，避免动态调用掩盖字段路径错误。
Map<String, Object?> _mapAt(Map<String, Object?> value, List<String> path) {
  var current = value;
  for (final key in path) {
    current = current[key]! as Map<String, Object?>;
  }
  return current;
}

NasdaqOptionQuoteResponse _response({
  String? body,
  int status = 200,
  int contentLength = -1,
  String? retryAfter,
}) => NasdaqOptionQuoteResponse(
  statusCode: status,
  contentLength: contentLength,
  retryAfter: retryAfter,
  body: Stream.value(utf8.encode(body ?? _fixture())),
);

class _Transport implements NasdaqOptionQuoteTransport {
  _Transport(this.respond);
  final FutureOr<NasdaqOptionQuoteResponse> Function(Uri) respond;
  final uris = <Uri>[];
  bool closed = false;

  @override
  Future<NasdaqOptionQuoteResponse> get(Uri uri) async {
    uris.add(uri);
    return respond(uri);
  }

  @override
  void close() => closed = true;
}

NasdaqOptionQuoteAdapter _adapter(
  _Transport transport, {
  Duration timeout = const Duration(seconds: 15),
}) => NasdaqOptionQuoteAdapter(
  transportFactory: () => transport,
  clock: () => _now,
  requestTimeout: timeout,
);

/// 多标的响应只替换真实结构中的公开合约身份，价格仍只用作固定测试输入。
String _forSymbol(String root) => _changed((value) {
  _mapAt(value, ['data', 'optionChainCallData'])['header'] =
      'Call <br>$root  261109C00265000';
  _mapAt(value, ['data', 'optionChainPutData'])['header'] =
      'Put <br>$root  261109P00265000';
});

List<MarketQuoteRequest> _many(int count) => [
  for (var i = 0; i < count; i++)
    _request(
      symbol: '${String.fromCharCode(65 + i)}261109C00265000',
      underlying: 'us:stock:${String.fromCharCode(65 + i)}',
    ),
];

class _Headers implements HttpHeaders {
  final values = <String, Object>{
    HttpHeaders.authorizationHeader: 'old-auth',
    HttpHeaders.cookieHeader: 'old-cookie',
    HttpHeaders.proxyAuthorizationHeader: 'old-proxy-auth',
  };
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;
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
  }) => Stream.value(utf8.encode(_fixture())).listen(
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
  @override
  int? maxConnectionsPerHost;
  String Function(Uri)? proxy;
  bool forceClosed = false;
  @override
  set findProxy(String Function(Uri)? value) => proxy = value;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    uris.add(uri);
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('无需凭证即支持完整合约，构造和不支持的身份均不联网', () async {
    var connections = 0;
    final adapter = NasdaqOptionQuoteAdapter(
      transportFactory: () {
        connections++;
        return _Transport((_) => _response());
      },
    );
    expect(adapter.supports(_request()), isTrue);
    expect(adapter.capability.id, NasdaqOptionQuoteAdapter.sourceId);
    expect(adapter.capability.approved, isFalse);
    expect(connections, 0);
    expect(await adapter.fetch([_request(symbol: 'TEST-AVGO')]), isEmpty);
    expect(connections, 0);
  });

  test('合约日期方向行权价市场币种须匹配，调整根可与实际标的不同', () {
    final adapter = _adapter(_Transport((_) => _response()));
    expect(adapter.supports(_request(strike: '265.000')), isTrue);
    expect(adapter.supports(_request(symbol: 'AVGO1261109C00265000')), isTrue);
    for (final request in [
      _request(symbol: 'TEST261109C00265000'),
      _request(symbol: 'test261109C00265000'),
      _request(symbol: 'AVGO261131C00265000', expiry: '2026-11-31'),
      _request(symbol: _put),
      _request(expiry: '2026-11-10'),
      _request(strike: '265.001'),
      _request(strike: '0'),
      _request(underlying: 'hk:stock:AVGO'),
      _request(underlying: 'us:stock:AVGO/path'),
      _request(market: StockMarket.hk),
      _request(currency: 'HKD'),
      _request(option: false),
    ]) {
      expect(adapter.supports(request), isFalse, reason: request.symbol);
    }
  });

  test('真实详情取各自最后价且call put共用请求，不借用快照时间或乘数', () async {
    final transport = _Transport((_) => _response());
    final call = _request(),
        put = _request(symbol: _put, right: OptionRight.put);
    final quotes = await _adapter(transport).fetch([call, put, call]);
    final byId = {for (final quote in quotes) quote.securityId: quote};
    expect(quotes, hasLength(2));
    expect(byId[call.securityId]!.last, '32.66');
    expect(byId[put.securityId]!.last, '0.38');
    for (final request in [call, put]) {
      final quote = byId[request.securityId]!;
      expect(quote.source, 'Nasdaq Options');
      expect(quote.currency, 'USD');
      expect(quote.unit, QuotePriceUnit.premiumUnit);
      expect(quote.lastAt, isNull);
      expect(quote.sourceTimeUnknown, isTrue);
      expect(quote.bid, isNull);
      expect(quote.ask, isNull);
      expect(quote.fetchedAt, _now);
      expect(quote.reference(request, _now)?.price, quote.last);
      expect(quote.reference(request, _now)?.midpoint, isFalse);
    }
    expect(transport.closed, isTrue);
    expect(transport.uris.single.scheme, 'https');
    expect(transport.uris.single.host, 'api.nasdaq.com');
    expect(transport.uris.single.path, '/api/quote/avgo/option-chain');
    expect(transport.uris.single.queryParameters, {
      'assetclass': 'stocks',
      'recordID': 'AVGO--261109C00265000',
    });
    expect(transport.uris.single.userInfo, isEmpty);
  });

  test('调整合约使用真实标的路径，仍精确校验返回合约完整代码', () async {
    final transport = _Transport((_) => _response(body: _forSymbol('AVGO1')));
    final request = _request(symbol: 'AVGO1261109C00265000');
    final quote = (await _adapter(transport).fetch([request])).single;
    expect(quote.securityId, request.securityId);
    expect(transport.uris.single.path, '/api/quote/avgo/option-chain');
    expect(
      transport.uris.single.queryParameters['recordID'],
      'AVGO1--261109C00265000',
    );
  });

  test('错误或缺失header不得把同标的另一份合约价当作请求价', () async {
    for (final header in [
      null,
      '',
      'Call <br>AVGO 261109C00267500',
      'Call <br>AVGO 261109P00265000',
      'Call <br>AAPL 261109C00265000',
    ]) {
      final body = _changed((value) {
        _mapAt(value, ['data', 'optionChainCallData'])['header'] = header;
      });
      expect(
        await _adapter(
          _Transport((_) => _response(body: body)),
        ).fetch([_request()]),
        isEmpty,
        reason: '$header',
      );
    }
  });

  test('来源展示时间即使缺失或非法也不补造成交时间', () async {
    for (final time in [null, 'not-a-time', 'Nov 7, 2026 08:40 AM ET']) {
      final body = _changed((value) {
        _mapAt(value, ['data', 'optionChainCallData'])['timeStamp'] = time;
      });
      final quote = (await _adapter(
        _Transport((_) => _response(body: body)),
      ).fetch([_request()])).single;
      expect(quote.last, '32.66');
      expect(quote.lastAt, isNull);
      expect(quote.sourceTimeUnknown, isTrue);
    }
  });

  test('缺价零价非法数字均不回退买卖价，也不返回零价', () async {
    for (final price in [null, '', '--', 'N/A', '0', '-1', 'NaN', '1e2']) {
      final body = _changed((value) {
        _mapAt(value, [
          'data',
          'optionChainCallData',
          'optionChainListData',
          'LastSale',
        ])['value'] = price;
      });
      expect(
        await _adapter(
          _Transport((_) => _response(body: body)),
        ).fetch([_request()]),
        isEmpty,
        reason: '$price',
      );
    }
  });

  test('原始小数精度与尾零保留，金额不在适配器预乘', () async {
    final body = _changed((value) {
      _mapAt(value, [
        'data',
        'optionChainCallData',
        'optionChainListData',
        'LastSale',
      ])['value'] = '0.12345670';
    });
    final quote = (await _adapter(
      _Transport((_) => _response(body: body)),
    ).fetch([_request()])).single;
    expect(quote.last, '0.12345670');
  });

  test('业务拒绝与空数据保留缺价，不能采用响应内其他价格', () async {
    for (final body in [
      '{"data":null,"status":{"rCode":200}}',
      _changed((value) => _mapAt(value, ['status'])['rCode'] = 400),
      'not-json',
    ]) {
      final transport = _Transport((_) => _response(body: body));
      expect(await _adapter(transport).fetch([_request()]), isEmpty);
      expect(transport.closed, isTrue);
    }
  });

  test('单标的无数据不影响其他标的，未挂牌合约不伪造价格', () async {
    final requests = _many(4);
    final transport = _Transport((uri) {
      final root = uri.path.split('/')[3].toUpperCase();
      return _response(
        body: root == 'B'
            ? '{"data":null,"status":{"rCode":200}}'
            : _forSymbol(root),
      );
    });
    final quotes = await _adapter(transport).fetch(requests);
    expect(
      quotes.map((quote) => quote.securityId),
      unorderedEquals([
        requests[0].securityId,
        requests[2].securityId,
        requests[3].securityId,
      ]),
    );
    expect(transport.uris, hasLength(4));
  });

  test('二十个合约可以独立取价，超过单批上限不联网', () async {
    final transport = _Transport((uri) {
      final root = uri.path.split('/')[3].toUpperCase();
      return _response(body: _forSymbol(root));
    });
    expect(await _adapter(transport).fetch(_many(20)), hasLength(20));
    final invalid = _Transport((_) => _response());
    await expectLater(
      _adapter(invalid).fetch(_many(21)),
      throwsFormatException,
    );
    expect(invalid.uris, isEmpty);
  });

  for (final status in [401, 403, 429]) {
    test('HTTP $status 停止尚未开始的请求，允许少量已在途请求释放', () async {
      final transport = _Transport((_) => _response(status: status));
      expect(await _adapter(transport).fetch(_many(8)), isEmpty);
      expect(transport.uris.length, inInclusiveRange(1, 3));
      expect(transport.closed, isTrue);
    });
  }

  test('429 后跨批次暂停至少五分钟，并遵守更长的 Retry-After', () async {
    for (final retryAfter in <String?>[
      null,
      '600',
      HttpDate.format(_now.add(const Duration(minutes: 10))),
    ]) {
      var now = _now;
      final transports = <_Transport>[];
      final adapter = NasdaqOptionQuoteAdapter(
        clock: () => now,
        transportFactory: () {
          final rejected = transports.isEmpty;
          final transport = _Transport(
            (_) => rejected
                ? _response(status: 429, retryAfter: retryAfter)
                : _response(),
          );
          transports.add(transport);
          return transport;
        },
      );
      expect(await adapter.fetch([_request()]), isEmpty);
      expect(transports, hasLength(1));
      // 新一批即使换了公开合约，也不能绕过来源暂停继续建立连接。
      expect(await adapter.fetch(_many(2)), isEmpty);
      now = _now.add(const Duration(minutes: 4, seconds: 59));
      expect(await adapter.fetch([_request()]), isEmpty);
      expect(transports, hasLength(1));
      now = _now.add(const Duration(minutes: 5));
      if (retryAfter != null) {
        expect(await adapter.fetch([_request()]), isEmpty);
        expect(transports, hasLength(1));
        now = _now.add(const Duration(minutes: 9, seconds: 59));
        expect(await adapter.fetch([_request()]), isEmpty);
        expect(transports, hasLength(1));
        now = _now.add(const Duration(minutes: 10));
      }
      expect(await adapter.fetch([_request()]), hasLength(1));
      expect(transports, hasLength(2));
      expect(transports.every((transport) => transport.closed), isTrue);
    }
  });

  test('普通合约根必须对应真实标的，数字调整根仍按独立身份查询', () {
    final adapter = _adapter(_Transport((_) => _response()));
    expect(adapter.supports(_request()), isTrue);
    expect(adapter.supports(_request(underlying: 'us:stock:AAPL')), isFalse);
    expect(adapter.supports(_request(symbol: 'AVGO1261109C00265000')), isTrue);
  });

  test('错误响应主动取消正文，其他有效合约仍能完成', () async {
    var errorBodyCancelled = false;
    final errorBody = StreamController<List<int>>(
      onCancel: () => errorBodyCancelled = true,
    );
    final transport = _Transport((uri) {
      final root = uri.path.split('/')[3].toUpperCase();
      return root == 'A'
          ? NasdaqOptionQuoteResponse(statusCode: 500, body: errorBody.stream)
          : _response(body: _forSymbol(root));
    });
    final requests = _many(2);
    final quotes = await _adapter(transport).fetch(requests);
    expect(errorBodyCancelled, isTrue);
    expect(quotes.map((quote) => quote.securityId), [requests.last.securityId]);
    expect(transport.uris, hasLength(2));
    expect(transport.closed, isTrue);
    await errorBody.close();
  });

  test('整批超时保留已完成结果，关闭连接并让其余项目缺价', () async {
    final stalled = Completer<NasdaqOptionQuoteResponse>();
    final transport = _Transport((uri) {
      final root = uri.path.split('/')[3].toUpperCase();
      return root == 'A' ? _response(body: _forSymbol(root)) : stalled.future;
    });
    final requests = _many(2);
    final quotes = await _adapter(
      transport,
      timeout: const Duration(milliseconds: 30),
    ).fetch(requests);
    expect(quotes.map((quote) => quote.securityId), [
      requests.first.securityId,
    ]);
    expect(transport.closed, isTrue);
    stalled.complete(_response(body: _forSymbol('B')));
  });

  test('撤销会话后丢弃所有在途结果，也不再启动其他合约', () async {
    final first = Completer<void>();
    final stalled = Completer<NasdaqOptionQuoteResponse>();
    var current = true;
    final transport = _Transport((_) {
      if (!first.isCompleted) first.complete();
      return stalled.future;
    });
    final pending = _adapter(
      transport,
    ).fetchCancellable(_many(8), isCurrent: () => current);
    await first.future;
    final started = transport.uris.length;
    current = false;
    stalled.complete(_response());
    expect(await pending, isEmpty);
    expect(transport.uris, hasLength(started));
    expect(started, lessThanOrEqualTo(3));
    expect(transport.closed, isTrue);
  });

  test('声明长度和累计流大小超过预算均不采用，并关闭连接', () async {
    for (final response in [
      _response(contentLength: NasdaqOptionQuoteAdapter.maximumBytes + 1),
      NasdaqOptionQuoteResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          List.filled(NasdaqOptionQuoteAdapter.maximumBytes, 32),
          [32],
        ]),
      ),
    ]) {
      final transport = _Transport((_) => response);
      expect(await _adapter(transport).fetch([_request()]), isEmpty);
      expect(transport.closed, isTrue);
    }
  });

  test('原生传输固定主机路径并禁重定向，不携带旧认证或cookie', () async {
    final client = _HttpClient();
    final transport = NasdaqHttpOptionQuoteTransport(client: client);
    final uri = Uri.https('api.nasdaq.com', '/api/quote/avgo/option-chain', {
      'assetclass': 'stocks',
      'recordID': 'AVGO--261109C00265000',
    });
    expect((await transport.get(uri)).statusCode, 200);
    expect(client.uris, [uri]);
    expect(client.request.followRedirects, isFalse);
    expect(client.request.persistentConnection, isFalse);
    expect(client.request.cookies, isEmpty);
    for (final header in [
      HttpHeaders.authorizationHeader,
      HttpHeaders.cookieHeader,
      HttpHeaders.proxyAuthorizationHeader,
    ]) {
      expect(client.request.headers.values, isNot(contains(header)));
    }
    for (final invalid in [
      uri.replace(scheme: 'http'),
      uri.replace(host: 'example.com'),
      uri.replace(path: '/api/quote/avgo/info'),
      uri.replace(userInfo: 'secret'),
    ]) {
      await expectLater(transport.get(invalid), throwsFormatException);
    }
    expect(client.uris, hasLength(1));
    transport.close();
    expect(client.forceClosed, isTrue);
  });
}
