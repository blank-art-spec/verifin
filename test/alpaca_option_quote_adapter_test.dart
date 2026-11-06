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
  'test/fixtures/investments/alpaca_option_trades_official_example.json',
).readAsStringSync();

/// 构造本地的单笔成交；[price]/[time]/[condition]/[size] 可以传非法值验证拒绝路径。
Map<String, Object?> _trade({
  Object? price = '4.1',
  Object? time = '2024-04-22T19:40:00Z',
  Object? condition = 'I',
  Object? size = 1,
}) => {'p': price, 't': time, 'c': condition, 's': size, 'x': 'B'};

/// 生成明确标记为测试数据的成交响应；[next] 是下一页游标，不代表真实市场返回。
String _trades({String symbol = _symbol, List<Object?>? rows, Object? next}) =>
    jsonEncode({
      'trades': {
        symbol: rows ?? [_trade()],
      },
      'next_page_token': next,
    });

/// 使用测试时钟建立实际适配器允许的查询地址，供传输层边界验证复用。
Uri _historyUri({String symbol = _symbol}) {
  final end = _now.subtract(const Duration(minutes: 16));
  return Uri.https('data.alpaca.markets', '/v1beta1/options/trades', {
    'symbols': symbol,
    'start': end.subtract(const Duration(hours: 168)).toIso8601String(),
    'end': end.toIso8601String(),
    'sort': 'desc',
    'limit': '100',
  });
}

/// 返回可流式读取的测试响应；[contentLength] 独立覆盖声明大小边界。
AlpacaOptionQuoteResponse _response({
  String? body,
  int status = 200,
  int contentLength = -1,
}) => AlpacaOptionQuoteResponse(
  statusCode: status,
  contentLength: contentLength,
  body: Stream.value(utf8.encode(body ?? _trades())),
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

/// 为 [transport] 配置虚构凭证及固定时钟；不读取任何用户配置。
AlpacaOptionQuoteAdapter _adapter(_Transport transport) =>
    AlpacaOptionQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _now,
    )..configure(keyId: 'test-key', secretKey: 'test-secret');

/// 在文档结构上注入边界条件；此函数生成的值始终只是测试输入。
String _changed(void Function(Map<String, Object?>) mutate) {
  final map = jsonDecode(_trades()) as Map<String, Object?>;
  mutate(map);
  return jsonEncode(map);
}

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
    expect(adapter.capability.id, 'Alpaca OPRA Delayed');
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

  test('延迟成交使用单合约倒序时间窗，保留源时间且不生成买卖中间价', () async {
    final transport = _Transport((_) => _response());
    final adapter = _adapter(transport);
    final request = _request();
    final quote = (await adapter.fetch([request, request])).single;
    expect(quote.source, 'Alpaca OPRA Delayed');
    expect(quote.bid, isNull);
    expect(quote.ask, isNull);
    expect(quote.last, '4.1');
    expect(quote.lastAt, DateTime.parse('2024-04-22T19:40:00Z'));
    expect(quote.reference(request, _now)?.price, '4.1');
    expect(quote.reference(request, _now)?.midpoint, isFalse);
    expect(quote.unit, QuotePriceUnit.premiumUnit);
    expect(quote.delayMinutes, 15);
    expect(quote.tradeState, QuoteTradeState.unknown);
    expect(quote.fetchedAt, _now);
    expect(transport.closed, isTrue);
    expect(transport.uris, [_historyUri()]);
    expect(transport.key, 'test-key');
    expect(transport.secret, 'test-secret');
    expect(transport.uris.single.toString(), isNot(contains('test-secret')));
    expect(transport.uris.single.queryParameters.containsKey('feed'), isFalse);
  });

  test('官方成交示例的倒序单页变体验证协议，不冒充真实账户验证', () async {
    final data = jsonDecode(_example()) as Map<String, Object?>;
    final trades = data['trades']! as Map<String, Object?>;
    final symbol = trades.keys.single;
    trades[symbol] = (trades[symbol]! as List).reversed.toList();
    data['next_page_token'] = null;
    final transport = _Transport((_) => _response(body: jsonEncode(data)));
    final now = DateTime.utc(2024, 1, 18, 17);
    final adapter = AlpacaOptionQuoteAdapter(
      transportFactory: () => transport,
      clock: () => now,
    )..configure(keyId: 'test-key', secretKey: 'test-secret');
    final request = _request(
      symbol: symbol,
      expiry: '2024-01-12',
      strike: '182.5',
    );
    final quote = (await adapter.fetch([request])).single;
    expect(quote.last, '0.34');
    expect(quote.lastAt, DateTime.parse('2024-01-18T16:02:38.994758144Z'));
    expect(quote.reference(request, now)?.midpoint, isFalse);
  });

  test('保持数值token八位精度和尾零，不经过double或修改字符串转义', () async {
    final body = _trades().replaceFirst('"4.1"', '123456789012.12345680');
    final quote = (await _adapter(
      _Transport((_) => _response(body: body)),
    ).fetch([_request()])).single;
    expect(quote.last, '123456789012.12345680');
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

  test('二十只合约逐只查询，不被首合约的分页条数截断', () async {
    final requests = [
      for (final prefix in 'ABCDEFGHIJKLMNOPQRST'.split(''))
        _request(
          symbol: '${prefix}240426C00162500',
          underlying: 'us:stock:$prefix',
        ),
    ];
    final transport = _Transport(
      (uri) =>
          _response(body: _trades(symbol: uri.queryParameters['symbols']!)),
    );
    expect(await _adapter(transport).fetch(requests), hasLength(20));
    expect(transport.uris, hasLength(20));
    expect(
      transport.uris.map((uri) => uri.queryParameters['symbols']),
      requests.map((request) => request.symbol),
    );
    expect(
      transport.uris.every(
        (uri) => !uri.queryParameters['symbols']!.contains(','),
      ),
      isTrue,
    );
  });

  test('不匹配合约与空数据不会成为零价', () async {
    for (final body in [
      _trades(symbol: 'AAPL240426P00162500'),
      _trades(rows: []),
      '{"trades":{}}',
    ]) {
      expect(
        await _adapter(
          _Transport((_) => _response(body: body)),
        ).fetch([_request()]),
        isEmpty,
      );
    }
  });

  test('取消迟报及未知条件均跳过，采用下一笔可信成交', () async {
    for (final condition in [
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      't',
      'u',
      'Z',
      '',
      null,
    ]) {
      final body = _trades(
        rows: [
          _trade(
            condition: condition,
            price: '999',
            time: '2024-04-22T19:43:00Z',
          ),
          _trade(),
        ],
      );
      final quote = (await _adapter(
        _Transport((_) => _response(body: body)),
      ).fetch([_request()])).single;
      expect(quote.last, '4.1', reason: '$condition');
    }
    for (final condition in 'HIJSabcdefghijklmnopqrsv'.split('')) {
      final quote = (await _adapter(
        _Transport(
          (_) => _response(
            body: _trades(rows: [_trade(condition: condition)]),
          ),
        ),
      ).fetch([_request()])).single;
      expect(quote.last, '4.1', reason: condition);
    }
  });

  test('缺时间非法时区和窗口外成交不补造抓取时刻，区间两端均包含', () async {
    for (final time in [
      null,
      '2024-04-22T19:40:00',
      '2024-02-31T19:40:00Z',
      '2024-04-22T24:00:00Z',
      '2024-04-22T19:40:00+25:00',
      '2024-04-23T19:40:00Z',
      '2024-04-22T19:44:00.000001Z',
      '2024-04-15T19:43:59.999999Z',
    ]) {
      expect(
        await _adapter(
          _Transport(
            (_) => _response(
              body: _trades(rows: [_trade(time: time)]),
            ),
          ),
        ).fetch([_request()]),
        isEmpty,
        reason: '$time',
      );
    }
    for (final time in ['2024-04-22T19:44:00Z', '2024-04-15T19:44:00Z']) {
      expect(
        await _adapter(
          _Transport(
            (_) => _response(
              body: _trades(rows: [_trade(time: time)]),
            ),
          ),
        ).fetch([_request()]),
        hasLength(1),
      );
    }
  });

  test('周一仍能读取周五的真实旧成交，并提示超过二十四小时', () async {
    final transport = _Transport(
      (_) => _response(
        body: _trades(rows: [_trade(time: '2024-04-19T19:59:00Z')]),
      ),
    );
    final quote = (await _adapter(transport).fetch([_request()])).single;
    expect(quote.lastAt, DateTime.utc(2024, 4, 19, 19, 59));
    expect(quote.isOlderThanOneDay(_request(), _now), isTrue);
    expect(
      transport.uris.single.queryParameters['start'],
      '2024-04-15T19:44:00.000Z',
    );
  });

  test('零价负价非法精度及非正成交数量均不能进入估值', () async {
    for (final price in [0, -1, 1.123456789, 'NaN', '1e-8', null]) {
      expect(
        await _adapter(
          _Transport(
            (_) => _response(
              body: _trades(rows: [_trade(price: price)]),
            ),
          ),
        ).fetch([_request()]),
        isEmpty,
        reason: '$price',
      );
    }
    for (final size in [0, -1, 1.5, 'NaN', null]) {
      expect(
        await _adapter(
          _Transport(
            (_) => _response(
              body: _trades(rows: [_trade(size: size)]),
            ),
          ),
        ).fetch([_request()]),
        isEmpty,
        reason: '$size',
      );
    }
  });

  test('无合格成交才读下一页，找到首个可信成交后停止', () async {
    var calls = 0;
    final transport = _Transport((uri) {
      calls++;
      return _response(
        body: calls == 1
            ? _trades(
                rows: [_trade(condition: 'A', time: '2024-04-22T19:43:00Z')],
                next: 'page+/=2',
              )
            : _trades(next: 'unused-page'),
      );
    });
    expect((await _adapter(transport).fetch([_request()])).single.last, '4.1');
    expect(calls, 2);
    expect(transport.uris.last.queryParameters['page_token'], 'page+/=2');
    expect(transport.uris.last.host, 'data.alpaca.markets');
  });

  test('响应时间乱序不能假装已取得最近可信成交', () async {
    final transport = _Transport(
      (_) => _response(
        body: _trades(
          rows: [
            _trade(),
            _trade(time: '2024-04-22T19:43:00Z'),
          ],
        ),
      ),
    );
    await expectLater(
      _adapter(transport).fetch([_request()]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
  });

  test('分页游标须为有界文本，循环和超过三页均停止', () async {
    for (final next in [42, [], 'x' * 2049, 'bad\nvalue']) {
      final transport = _Transport(
        (_) => _response(
          body: _trades(rows: [], next: next),
        ),
      );
      await expectLater(
        _adapter(transport).fetch([_request()]),
        throwsA(isA<AlpacaOptionQuoteException>()),
      );
      expect(transport.uris, hasLength(1));
    }
    final repeating = _Transport(
      (_) => _response(
        body: _trades(rows: [], next: 'same'),
      ),
    );
    await expectLater(
      _adapter(repeating).fetch([_request()]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    expect(repeating.uris, hasLength(2));
    var count = 0;
    final endless = _Transport(
      (_) => _response(
        body: _trades(rows: [], next: 'page-${++count}'),
      ),
    );
    await expectLater(
      _adapter(endless).fetch([_request()]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    expect(endless.uris, hasLength(3));
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

  test('损坏JSON错误币种声明大小及流式超限均失败并关闭连接', () async {
    for (final body in [
      '{',
      '{"trades":[]}',
      '{"trades":{},"x":01}',
      '{"trades":{},"x":1e}',
      '{"trades":{},1:"invalid numeric key"}',
      '{"trades":{},"currency":"HKD"}',
      _trades(rows: List.filled(101, _trade())),
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

  test('五百一十二KiB预算由所有合约共享，不会每次请求重新计算', () async {
    final transport = _Transport((uri) {
      final map =
          jsonDecode(_trades(symbol: uri.queryParameters['symbols']!)) as Map;
      map['padding'] = 'x' * (300 * 1024);
      return _response(body: jsonEncode(map));
    });
    await expectLater(
      _adapter(transport).fetch([
        _request(),
        _request(symbol: 'AAPL240426P00162500', right: OptionRight.put),
      ]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    expect(transport.uris, hasLength(2));
    expect(transport.closed, isTrue);
  });

  testWidgets('整批超时关闭连接，晚响应不能再发下一合约请求', (tester) async {
    final pending = Completer<AlpacaOptionQuoteResponse>();
    final transport = _Transport((_) => pending.future);
    final expectation = expectLater(
      _adapter(transport).fetch([
        _request(),
        _request(symbol: 'AAPL240426P00162500', right: OptionRight.put),
      ]),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    await tester.pump(const Duration(seconds: 16));
    await expectation;
    expect(transport.closed, isTrue);
    pending.complete(_response());
    await tester.pump();
    expect(transport.uris, hasLength(1));
  });

  test('配置变化使旧结果及后续合约请求失效，超过批量上限不联网', () async {
    final pending = Completer<AlpacaOptionQuoteResponse>();
    final transport = _Transport((_) => pending.future);
    final adapter = _adapter(transport);
    await expectLater(
      adapter.fetch(List.filled(21, _request())),
      throwsA(isA<AlpacaOptionQuoteException>()),
    );
    expect(await adapter.fetch([_request(option: false)]), isEmpty);
    expect(transport.uris, isEmpty);
    final oldResult = adapter.fetch([
      _request(),
      _request(symbol: 'AAPL240426P00162500', right: OptionRight.put),
    ]);
    adapter.configure(keyId: 'new-key', secretKey: 'new-secret');
    expect(transport.closed, isTrue);
    pending.complete(_response());
    expect(await oldResult, isEmpty);
    expect(transport.uris, hasLength(1));
  });

  test('外部会话取消后不继续分页，也不产生旧结果', () async {
    var active = true;
    final pending = Completer<AlpacaOptionQuoteResponse>();
    final transport = _Transport((_) => pending.future);
    final adapter = _adapter(transport);
    final result = adapter.fetchCancellable([
      _request(),
    ], isCurrent: () => active);
    active = false;
    pending.complete(
      _response(
        body: _trades(rows: [], next: 'next'),
      ),
    );
    expect(await result, isEmpty);
    expect(transport.uris, hasLength(1));
    expect(transport.closed, isTrue);
    expect(
      await adapter.fetchCancellable([_request()], isCurrent: () => false),
      isEmpty,
    );
    expect(transport.uris, hasLength(1));
  });

  test('真实HTTP传输固定历史地址和参数，禁重定向代理及旧会话', () async {
    final client = _HttpClient();
    final transport = AlpacaHttpOptionQuoteTransport(client: client);
    final uri = _historyUri();
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
      uri.replace(path: '/v1beta1/options/snapshots'),
      uri.replace(
        queryParameters: {...uri.queryParameters, 'feed': 'indicative'},
      ),
      uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'symbols': '$_symbol,$_symbol',
        },
      ),
      uri.replace(queryParameters: {...uri.queryParameters, 'sort': 'asc'}),
      uri.replace(queryParameters: {...uri.queryParameters, 'limit': '10000'}),
      uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'start': '2024-02-31T00:00:00.000Z',
        },
      ),
      uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'start': '2024-01-01T00:00:00.000Z',
        },
      ),
      uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'end': DateTime.now().toUtc().toIso8601String(),
        },
      ),
      uri.replace(
        queryParameters: {...uri.queryParameters, 'page_token': 'bad\nvalue'},
      ),
      uri.replace(query: '${uri.query}&sort=desc'),
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
