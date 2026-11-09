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

/// 读取 SOFX 的真实 ETF 详情，保留来源的完整合约身份和原始价格文本。
/// 此函数不联网；夹具对应 2026-12-18、9 美元行权价的认购与认沽。
String _sofxFixture() => File(
  'test/fixtures/investments/nasdaq_sofx_option_detail_20261109.json',
).readAsStringSync();

/// 读取同一 SOFX 合约误走股票分类时的真实空响应，用于复现分类遗漏。
/// 它是 HTTP 成功且业务状态正常的空数据，不表示授权拒绝或网络错误。
String _emptyStocksFixture() => File(
  'test/fixtures/investments/nasdaq_sofx_stocks_empty_20261109.json',
).readAsStringSync();

/// 创建与真实 SOFX 夹具一致的公开请求；[right] 指定认购或认沽方向。
/// ETF 标的沿用应用现有的股票身份，不新增分类字段或修改合约乘数。
MarketQuoteRequest _sofxRequest({OptionRight right = OptionRight.put}) =>
    _request(
      symbol: 'SOFX261218${right == OptionRight.call ? 'C' : 'P'}00009000',
      underlying: 'us:stock:SOFX',
      expiry: '2026-12-18',
      strike: '9',
      right: right,
    );

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

/// 注册离线适配器检查：验证公开身份、分类补查、价格采用与整批资源限制。
/// 所有传输均由本文件替身提供，不访问真实网络或用户账目。
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

  test('SOFX 股票分类空数据后查询 ETF，认购认沽共用一次补查', () async {
    final transport = _Transport(
      (uri) => _response(
        body: uri.queryParameters['assetclass'] == 'stocks'
            ? _emptyStocksFixture()
            : _sofxFixture(),
      ),
    );
    final call = _sofxRequest(right: OptionRight.call);
    final put = _sofxRequest();
    final quotes = await _adapter(transport).fetch([call, put, put]);
    final byId = {for (final quote in quotes) quote.securityId: quote};
    expect(quotes, hasLength(2));
    expect(byId[call.securityId]!.last, '0.3');
    expect(byId[put.securityId]!.last, '2.71');
    expect(transport.uris.map((uri) => uri.queryParameters['assetclass']), [
      'stocks',
      'etf',
    ]);
    for (final uri in transport.uris) {
      expect(uri.host, 'api.nasdaq.com');
      expect(uri.path, '/api/quote/sofx/option-chain');
      expect(uri.queryParameters['recordID'], 'SOFX--261218C00009000');
      expect(
        uri.queryParameters.keys,
        unorderedEquals(['assetclass', 'recordID']),
      );
    }
    for (final request in [call, put]) {
      final quote = byId[request.securityId]!;
      expect(quote.lastAt, isNull);
      expect(quote.sourceTimeUnknown, isTrue);
      expect(quote.fetchedAt, _now);
      expect(quote.unit, QuotePriceUnit.premiumUnit);
      expect(quote.reference(request, _now)?.price, quote.last);
    }
    expect(transport.closed, isTrue);
  });

  test('ETF 也无数据时只补查一次，不在两个分类之间重复查询', () async {
    final transport = _Transport((_) => _response(body: _emptyStocksFixture()));
    expect(await _adapter(transport).fetch([_sofxRequest()]), isEmpty);
    expect(transport.uris.map((uri) => uri.queryParameters['assetclass']), [
      'stocks',
      'etf',
    ]);
    expect(transport.closed, isTrue);
  });

  test('多个 ETF 合约补查仍最多三个在途请求，互不混用标的价格', () async {
    var active = 0, maximumActive = 0;
    final transport = _Transport((uri) async {
      active++;
      if (active > maximumActive) maximumActive = active;
      try {
        // 让其他工作协程有机会进入，真实并发上限由未完成的请求数量观察。
        await Future<void>.delayed(Duration.zero);
        final root = uri.path.split('/')[3].toUpperCase();
        return _response(
          body: uri.queryParameters['assetclass'] == 'stocks'
              ? _emptyStocksFixture()
              : _forSymbol(root),
        );
      } finally {
        active--;
      }
    });
    final requests = _many(8);
    final quotes = await _adapter(transport).fetch(requests);
    expect(
      quotes.map((quote) => quote.securityId),
      unorderedEquals(requests.map((request) => request.securityId)),
    );
    expect(transport.uris, hasLength(16));
    expect(maximumActive, inInclusiveRange(2, 3));
    expect(active, 0);
    expect(transport.closed, isTrue);
  });

  test('ETF 详情仍校验完整合约与正价格，不能借用其他合约或标的价格', () async {
    for (final wrongIdentity in [true, false]) {
      final value = jsonDecode(_sofxFixture()) as Map<String, Object?>;
      if (wrongIdentity) {
        _mapAt(value, ['data', 'optionChainPutData'])['header'] =
            'Put <br>SOFX 261218P00010000';
      } else {
        _mapAt(value, [
          'data',
          'optionChainPutData',
          'optionChainListData',
          'LastSale',
        ])['value'] = '0';
      }
      final transport = _Transport(
        (uri) => _response(
          body: uri.queryParameters['assetclass'] == 'stocks'
              ? _emptyStocksFixture()
              : jsonEncode(value),
        ),
      );
      expect(await _adapter(transport).fetch([_sofxRequest()]), isEmpty);
      expect(transport.uris, hasLength(2));
    }
  });

  test('股票分类 HTTP 失败或无效业务正文不触发 ETF 补查', () async {
    for (final status in [401, 403, 429, 500]) {
      final transport = _Transport(
        (_) => _response(status: status, body: _emptyStocksFixture()),
      );
      expect(await _adapter(transport).fetch([_sofxRequest()]), isEmpty);
      expect(transport.uris, hasLength(1), reason: 'HTTP $status');
    }
    for (final body in [
      'not-json',
      '{"data":null,"status":{"rCode":500}}',
      '{"data":null,"status":{"rCode":400}}',
      '{"status":{"rCode":200}}',
      '{"data":[],"status":{"rCode":200}}',
    ]) {
      final transport = _Transport((_) => _response(body: body));
      expect(await _adapter(transport).fetch([_sofxRequest()]), isEmpty);
      expect(transport.uris, hasLength(1), reason: body);
    }
  });

  test('ETF 拒绝或限流同样暂停后续批次，并保留 Retry-After', () async {
    for (final status in [401, 403, 429]) {
      var now = _now;
      final transport = _Transport(
        (uri) => uri.queryParameters['assetclass'] == 'stocks'
            ? _response(body: _emptyStocksFixture())
            : _response(status: status, retryAfter: '600'),
      );
      final adapter = NasdaqOptionQuoteAdapter(
        transportFactory: () => transport,
        clock: () => now,
      );
      expect(await adapter.fetch([_sofxRequest()]), isEmpty);
      expect(transport.uris, hasLength(2));
      now = _now.add(const Duration(minutes: 9, seconds: 59));
      expect(await adapter.fetch([_request()]), isEmpty);
      expect(transport.uris, hasLength(2));
      now = _now.add(const Duration(minutes: 10));
      expect(await adapter.fetch([_sofxRequest()]), isEmpty);
      expect(transport.uris, hasLength(4));
    }
  });

  test('股票响应返回前取消会话，不再启动 ETF 补查', () async {
    var current = true;
    final response = Completer<NasdaqOptionQuoteResponse>();
    final transport = _Transport((_) => response.future);
    final pending = _adapter(
      transport,
    ).fetchCancellable([_sofxRequest()], isCurrent: () => current);
    expect(transport.uris, hasLength(1));
    current = false;
    response.complete(_response(body: _emptyStocksFixture()));
    expect(await pending, isEmpty);
    expect(transport.uris, hasLength(1));
    expect(transport.closed, isTrue);
  });

  test('ETF 补查在途时取消会话，迟到价格不得采用', () async {
    var current = true;
    final etfStarted = Completer<void>();
    final response = Completer<NasdaqOptionQuoteResponse>();
    final transport = _Transport((uri) {
      if (uri.queryParameters['assetclass'] == 'stocks') {
        return _response(body: _emptyStocksFixture());
      }
      etfStarted.complete();
      return response.future;
    });
    final pending = _adapter(
      transport,
    ).fetchCancellable([_sofxRequest()], isCurrent: () => current);
    await etfStarted.future;
    current = false;
    response.complete(_response(body: _sofxFixture()));
    expect(await pending, isEmpty);
    expect(transport.uris, hasLength(2));
    expect(transport.closed, isTrue);
  });

  test('股票与 ETF 响应共用累计字节预算，不给补查重置下载额度', () async {
    final etfBody = _sofxFixture();
    final etfBytes = utf8.encode(etfBody).length;
    // 空白仍是合法 JSON 尾部；两个响应单独合格，累计大小刚好超出一字节。
    final stocksBody = _emptyStocksFixture().padRight(
      NasdaqOptionQuoteAdapter.maximumBytes - etfBytes + 1,
      ' ',
    );
    for (final declaredLength in [true, false]) {
      final transport = _Transport(
        (uri) => uri.queryParameters['assetclass'] == 'stocks'
            ? _response(body: stocksBody)
            : _response(
                body: etfBody,
                contentLength: declaredLength ? etfBytes : -1,
              ),
      );
      expect(await _adapter(transport).fetch([_sofxRequest()]), isEmpty);
      expect(transport.uris, hasLength(2));
      expect(transport.closed, isTrue);
    }
  });

  testWidgets('股票与 ETF 补查共用总超时，不给第二次请求重新计时', (tester) async {
    final stocksResponse = Completer<NasdaqOptionQuoteResponse>();
    final etfResponse = Completer<NasdaqOptionQuoteResponse>();
    final transport = _Transport(
      (uri) => uri.queryParameters['assetclass'] == 'stocks'
          ? stocksResponse.future
          : etfResponse.future,
    );
    final pending = _adapter(
      transport,
      timeout: const Duration(milliseconds: 100),
    ).fetch([_sofxRequest()]);
    var completed = false;
    unawaited(
      pending.then((_) {
        completed = true;
      }),
    );
    await tester.pump(const Duration(milliseconds: 60));
    stocksResponse.complete(_response(body: _emptyStocksFixture()));
    await tester.pump();
    expect(transport.uris, hasLength(2));
    await tester.pump(const Duration(milliseconds: 39));
    expect(completed, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(completed, isTrue);
    expect(await pending, isEmpty);
    expect(transport.closed, isTrue);
    etfResponse.complete(_response(body: _sofxFixture()));
    await tester.pump();
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
      final transport = _Transport((_) => _response(body: body));
      expect(
        await _adapter(transport).fetch([_request()]),
        isEmpty,
        reason: '$header',
      );
      expect(transport.uris, hasLength(1));
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
      final transport = _Transport((_) => _response(body: body));
      expect(
        await _adapter(transport).fetch([_request()]),
        isEmpty,
        reason: '$price',
      );
      expect(transport.uris, hasLength(1));
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
    // B 的股票分类为空，因此只为 B 增加一次 ETF 查询，其余三项直接完成。
    expect(transport.uris, hasLength(5));
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
    final etfUri = uri.replace(
      path: '/api/quote/sofx/option-chain',
      queryParameters: {
        'assetclass': 'etf',
        'recordID': 'SOFX--261218C00009000',
      },
    );
    expect((await transport.get(etfUri)).statusCode, 200);
    expect(client.uris, [uri, etfUri]);
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
      uri.replace(
        queryParameters: {
          'assetclass': 'funds',
          'recordID': 'AVGO--261109C00265000',
        },
      ),
      uri.replace(
        queryParameters: {
          'assetclass': ['stocks', 'etf'],
          'recordID': 'AVGO--261109C00265000',
        },
      ),
    ]) {
      await expectLater(transport.get(invalid), throwsFormatException);
    }
    expect(client.uris, hasLength(2));
    transport.close();
    expect(client.forceClosed, isTrue);
  });
}
