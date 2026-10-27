import 'dart:async';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/tencent_quote_adapter.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/timezone_database.dart';

import 'support/investment_fixture.dart';

const _cosco = StockSecurity(
  symbol: '600026',
  name: '中远海能',
  market: StockMarket.cn,
  currencyCode: 'CNY',
);
const _tencent = StockSecurity(
  symbol: '00700',
  name: '腾讯控股',
  market: StockMarket.hk,
  currencyCode: 'HKD',
);
const _avgo = StockSecurity(
  symbol: 'AVGO',
  name: '博通',
  market: StockMarket.us,
  currencyCode: 'USD',
);
const _goog = StockSecurity(
  symbol: 'GOOG',
  name: '谷歌',
  market: StockMarket.us,
  currencyCode: 'USD',
);
final _capturedAt = DateTime.utc(2026, 10, 27, 2, 35);

/// 读取真实公开 GBK 响应；样例捕获时间固定，测试不会联网或假设这是今天的价格。
List<int> _fixtureBytes() => File(
  'test/fixtures/investments/tencent_stocks_20261027.gbk',
).readAsBytesSync();

/// 修改单行公开样例的指定字段，以覆盖真实格式上的身份、价格和时间边界。
/// [queryCode] 是来源请求代码；[index] 是字段位置，[value] 是本用例注入的异常或边界输入。
String _withField(String queryCode, int index, String value) {
  final text = gbk.decode(_fixtureBytes());
  return text
      .split(RegExp(r'\r?\n'))
      .map((line) {
        if (!line.startsWith('v_$queryCode="')) return line;
        final fields = line
            .substring(line.indexOf('"') + 1, line.lastIndexOf('"'))
            .split('~');
        fields[index] = value;
        return 'v_$queryCode="${fields.join('~')}";';
      })
      .join('\n');
}

/// 构造尚未读取的响应流；[text] 为空时保留原始 GBK 字节，状态码不改写为成功。
TencentQuoteResponse _response({String? text, int status = 200}) =>
    TencentQuoteResponse(
      statusCode: status,
      body: Stream.value(text == null ? _fixtureBytes() : gbk.encode(text)),
    );

/// 捕获请求及关闭动作的本地传输，响应由 [respond] 提供，从不访问互联网。
class _FixtureTransport implements TencentQuoteTransport {
  /// [respond] 可返回真实样例、故障或永不完成的 Future，以验证总时限与强制关闭。
  _FixtureTransport(this.respond, {this.onClose});
  final FutureOr<TencentQuoteResponse> Function(Uri) respond;
  final void Function()? onClose;
  final List<Uri> requests = [];
  bool closed = false;

  /// 保存实际地址再返回本地响应，供测试检查固定主机和最小公开身份。
  @override
  Future<TencentQuoteResponse> get(Uri uri) async {
    requests.add(uri);
    return respond(uri);
  }

  /// 记录关闭且释放用例控制的响应流，不操作设备或其他连接。
  @override
  void close() {
    closed = true;
    onClose?.call();
  }
}

/// HTTP 参数的最小记录器，用于核对生产传输确实关闭重定向和凭证。
class _RecordingHeaders implements HttpHeaders {
  final values = <String, Object>{
    HttpHeaders.cookieHeader: '旧会话不得发送',
    HttpHeaders.authorizationHeader: '旧凭证不得发送',
  };

  /// [name]/[value] 保存为内存字段，不向外发送；大小写参数不影响本用例语义。
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  /// 删除指定测试字段，以验证显式移除 Cookie 和 Authorization。
  @override
  void removeAll(String name) => values.remove(name.toLowerCase());

  /// 非本用例所需的 HttpHeaders 能力保持未实现，防止测试意外依赖额外行为。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 只暴露被生产传输实际使用的状态及字节流，不模拟浏览器或自动重定向。
class _RecordingResponse extends Stream<List<int>>
    implements HttpClientResponse {
  /// [statusCode] 和 [bytes] 是当前用例的实际传输输入。
  _RecordingResponse(this.statusCode, this.bytes);
  @override
  final int statusCode;
  final List<int> bytes;

  /// 按 Stream 契约转发一次字节响应，允许读取方取消，避免先解析后才测传输限制。
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// 未使用的响应元数据不做虚构实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可检查请求配置的本地 HttpClientRequest，不连接任何端点。
class _RecordingRequest implements HttpClientRequest {
  /// [response] 是当前用例预先指定的响应。
  _RecordingRequest(this.response);
  final HttpClientResponse response;
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  final _RecordingHeaders headers = _RecordingHeaders();
  @override
  final List<Cookie> cookies = [Cookie('old_session', 'discard')];

  /// 仅返回预设响应，无隐藏的第二次请求或状态码重试。
  @override
  Future<HttpClientResponse> close() async => response;

  /// 未使用的请求能力保持未实现，限制测试替身的职责。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 将生产 HTTP 传输绑定到记录器，检查地址、请求配置及强制关闭行为。
class _RecordingClient implements HttpClient {
  /// [request] 是被 getUrl 返回的唯一请求，实际网络不会参与测试。
  _RecordingClient(this.request);
  final _RecordingRequest request;
  final List<Uri> urls = [];
  @override
  Duration? connectionTimeout;
  bool forceClosed = false;

  /// 记录请求地址，供调用方检查没有改用其他协议、主机或参数。
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return request;
  }

  /// 记录是否使用强制关闭；测试不持有真实套接字。
  @override
  void close({bool force = false}) => forceClosed = force;

  /// 未使用的客户端能力保持未实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 注册真实样例、身份/时间边界及传输资源约束；没有真实行情网络或设备副作用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTimezoneDatabase);

  test('真实四股响应校验代码、原币、每股价格和真实源时间，抓取时间独立', () async {
    final transport = _FixtureTransport((_) => _response());
    final adapter = TencentQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _capturedAt,
    );
    expect(adapter.capability.approved, isFalse);
    expect(adapter.capability.researchOnly, isTrue);
    final requests = [
      _cosco,
      _tencent,
      _avgo,
      _goog,
    ].map(MarketQuoteRequest.new).toList();
    final quotes = await adapter.fetch(requests);
    expect(quotes, hasLength(4));
    expect(
      transport.requests.single.toString(),
      'https://qt.gtimg.cn/q=sh600026,hk00700,usAVGO,usGOOG',
    );
    expect(transport.closed, isTrue);
    const prices = ['19.45', '386.6', '329.17', '314.19'];
    final times = [
      DateTime.utc(2026, 10, 27, 2, 34, 24),
      DateTime.utc(2026, 10, 27, 2, 19, 17),
      DateTime.utc(2026, 10, 26, 20, 0, 1),
      DateTime.utc(2026, 10, 26, 20, 0, 1),
    ];
    for (var index = 0; index < quotes.length; index++) {
      final quote = quotes[index], request = requests[index];
      expect(quote.securityId, request.securityId);
      expect(quote.source, 'Tencent Finance');
      expect(quote.currency, request.currency);
      expect(quote.unit, QuotePriceUnit.share);
      expect(quote.last, prices[index]);
      expect(quote.lastAt, times[index]);
      expect(quote.fetchedAt, _capturedAt);
      expect(quote.tradeState, QuoteTradeState.unknown);
      expect(quote.delayMinutes, isNull);
      expect(quote.reference(request, _capturedAt)?.price, prices[index]);
    }
  });

  test('同一股票去重；不支持的代码与所有期权不会进入公开请求', () async {
    var created = 0;
    final transport = _FixtureTransport((_) => _response());
    final adapter = TencentQuoteAdapter(
      transportFactory: () {
        created++;
        return transport;
      },
      clock: () => _capturedAt,
    );
    final unsupported = [
      const StockSecurity(
        symbol: 'MSFT',
        name: '未核对美股',
        market: StockMarket.us,
        currencyCode: 'USD',
      ),
      const StockSecurity(
        symbol: '700',
        name: '缺前导零',
        market: StockMarket.hk,
        currencyCode: 'HKD',
      ),
      const StockSecurity(
        symbol: '80700',
        name: '人民币柜台',
        market: StockMarket.hk,
        currencyCode: 'HKD',
      ),
      const StockSecurity(
        symbol: '600026',
        name: '错币种',
        market: StockMarket.cn,
        currencyCode: 'USD',
      ),
      const StockSecurity(
        symbol: 'TEST-TCH-CALL',
        name: '本地示例',
        market: StockMarket.hk,
        currencyCode: 'HKD',
      ),
      StockSecurity(
        symbol: 'TCH-20261230-C-440',
        name: '期权',
        market: StockMarket.hk,
        currencyCode: 'HKD',
        option: optionFixture().option,
      ),
    ].map(MarketQuoteRequest.new).toList();
    expect(unsupported.every((request) => !adapter.supports(request)), isTrue);
    expect(await adapter.fetch(unsupported), isEmpty);
    expect(await adapter.fetch(const []), isEmpty);
    expect(created, 0);
    final result = await adapter.fetch([
      ...unsupported,
      MarketQuoteRequest(_tencent),
      MarketQuoteRequest(_tencent),
    ]);
    expect(created, 1);
    expect(transport.requests.single.path, '/q=hk00700');
    expect(result.single.securityId, _tencent.id);
  });

  test('超过二十个输入身份在创建连接前拒绝，不静默截取后继续请求', () async {
    var created = 0;
    final adapter = TencentQuoteAdapter(
      transportFactory: () {
        created++;
        return _FixtureTransport((_) => _response());
      },
    );
    await expectLater(
      adapter.fetch(List.generate(21, (_) => MarketQuoteRequest(_cosco))),
      throwsFormatException,
    );
    expect(created, 0);
  });

  for (final change in [
    (code: 'sh600026', index: 2, value: '600027'),
    (code: 'sh600026', index: 0, value: '51'),
    (code: 'sh600026', index: 82, value: 'USD'),
    (code: 'hk00700', index: 2, value: '700'),
    (code: 'hk00700', index: 75, value: 'CNY'),
    (code: 'usAVGO', index: 2, value: 'AVGO.N'),
    (code: 'usAVGO', index: 35, value: 'HKD'),
  ]) {
    test('错误证券、市场或原币不进入有效报价 ${change.code}/${change.index}', () async {
      final source = switch (change.code) {
        'hk00700' => _tencent,
        'usAVGO' => _avgo,
        _ => _cosco,
      };
      final transport = _FixtureTransport(
        (_) => _response(
          text: _withField(change.code, change.index, change.value),
        ),
      );
      final adapter = TencentQuoteAdapter(
        transportFactory: () => transport,
        clock: () => _capturedAt,
      );
      expect(await adapter.fetch([MarketQuoteRequest(source)]), isEmpty);
      expect(transport.closed, isTrue);
    });
  }

  for (final value in [
    '',
    '0',
    '-1',
    'NaN',
    'Infinity',
    '1e3',
    '1.123456789',
  ]) {
    test('无效成交价不伪造零或截断精度：$value', () async {
      final transport = _FixtureTransport(
        (_) => _response(text: _withField('sh600026', 3, value)),
      );
      final adapter = TencentQuoteAdapter(
        transportFactory: () => transport,
        clock: () => _capturedAt,
      );
      expect(await adapter.fetch([MarketQuoteRequest(_cosco)]), isEmpty);
    });
  }

  for (final value in [
    '',
    '20261027',
    '20260230093000',
    '20261027240000',
    '20261027110000',
  ]) {
    test('缺失、非法或未来源时间不使用抓取时间补值：$value', () async {
      final transport = _FixtureTransport(
        (_) => _response(text: _withField('sh600026', 30, value)),
      );
      final adapter = TencentQuoteAdapter(
        transportFactory: () => transport,
        clock: () => _capturedAt,
      );
      expect(await adapter.fetch([MarketQuoteRequest(_cosco)]), isEmpty);
    });
  }

  for (final sample in [
    (raw: '2026-01-12 16:00:01', utc: DateTime.utc(2026, 1, 12, 21, 0, 1)),
    (raw: '2026-07-13 16:00:01', utc: DateTime.utc(2026, 7, 13, 20, 0, 1)),
  ]) {
    test('美股纽约源时间正确换算冬夏令时 ${sample.raw}', () async {
      final transport = _FixtureTransport(
        (_) => _response(text: _withField('usAVGO', 30, sample.raw)),
      );
      final adapter = TencentQuoteAdapter(
        transportFactory: () => transport,
        clock: () => DateTime.utc(2027, 1),
      );
      final quotes = await adapter.fetch([MarketQuoteRequest(_avgo)]);
      expect(quotes.single.lastAt, sample.utc);
    });
  }
  test('美股春季跳时的不存在时刻不被归一成另一有效报价时间', () async {
    final transport = _FixtureTransport(
      (_) => _response(text: _withField('usAVGO', 30, '2026-03-08 02:30:00')),
    );
    final adapter = TencentQuoteAdapter(
      transportFactory: () => transport,
      clock: () => DateTime.utc(2027, 1),
    );
    expect(await adapter.fetch([MarketQuoteRequest(_avgo)]), isEmpty);
  });
  test('美股秋季回拨重复时刻缺偏移时不猜测对应UTC时间', () async {
    final transport = _FixtureTransport(
      (_) => _response(text: _withField('usAVGO', 30, '2026-11-01 01:30:00')),
    );
    final adapter = TencentQuoteAdapter(
      transportFactory: () => transport,
      clock: () => DateTime.utc(2027, 1),
    );
    expect(await adapter.fetch([MarketQuoteRequest(_avgo)]), isEmpty);
  });

  test('畸形、缺字段或重复响应行都不会执行文本或接受歧义价格', () async {
    for (final text in [
      'v_sh600026="1~缺失字段";',
      'throw new Error("不得执行来源文本")',
      '${gbk.decode(_fixtureBytes())}\n${gbk.decode(_fixtureBytes())}',
    ]) {
      final transport = _FixtureTransport((_) => _response(text: text));
      final adapter = TencentQuoteAdapter(
        transportFactory: () => transport,
        clock: () => _capturedAt,
      );
      expect(await adapter.fetch([MarketQuoteRequest(_cosco)]), isEmpty);
    }
  });

  for (final status in [301, 302, 401, 403, 429, 500]) {
    test('HTTP $status 不绕过、不自动重试且关闭连接', () async {
      final transport = _FixtureTransport((_) => _response(status: status));
      final adapter = TencentQuoteAdapter(
        transportFactory: () => transport,
        clock: () => _capturedAt,
      );
      await expectLater(
        adapter.fetch([MarketQuoteRequest(_cosco)]),
        throwsA(isA<HttpException>()),
      );
      expect(transport.requests, hasLength(1));
      expect(transport.closed, isTrue);
    });
  }

  test('连接阶段总超时会关闭传输，不能只停止等待而留下网络请求', () async {
    final pending = Completer<TencentQuoteResponse>();
    final transport = _FixtureTransport((_) => pending.future);
    final adapter = TencentQuoteAdapter(
      transportFactory: () => transport,
      requestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      adapter.fetch([MarketQuoteRequest(_cosco)]),
      throwsA(isA<TimeoutException>()),
    );
    expect(transport.closed, isTrue);
    pending.complete(_response());
  });

  test('响应流停滞同样受总时限约束并被关闭', () async {
    final controller = StreamController<List<int>>();
    final transport = _FixtureTransport(
      (_) => TencentQuoteResponse(statusCode: 200, body: controller.stream),
      onClose: () => unawaited(controller.close()),
    );
    final adapter = TencentQuoteAdapter(
      transportFactory: () => transport,
      requestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      adapter.fetch([MarketQuoteRequest(_cosco)]),
      throwsA(isA<TimeoutException>()),
    );
    expect(transport.closed, isTrue);
    expect(controller.isClosed, isTrue);
  });

  test('累计超过五百一十二KiB立即停止读取并关闭连接', () async {
    final transport = _FixtureTransport(
      (_) => TencentQuoteResponse(
        statusCode: 200,
        body: Stream.fromIterable([
          List<int>.filled(TencentQuoteAdapter.maximumBytes, 65),
          [66],
        ]),
      ),
    );
    final adapter = TencentQuoteAdapter(transportFactory: () => transport);
    await expectLater(
      adapter.fetch([MarketQuoteRequest(_cosco)]),
      throwsFormatException,
    );
    expect(transport.closed, isTrue);
  });

  test('生产HTTP配置固定HTTPS、禁止跳转和持久连接、不携带旧Cookie或凭证', () async {
    final request = _RecordingRequest(_RecordingResponse(200, _fixtureBytes()));
    final client = _RecordingClient(request);
    final adapter = TencentQuoteAdapter(
      transportFactory: () => TencentHttpQuoteTransport(client: client),
      clock: () => _capturedAt,
    );
    expect(await adapter.fetch([MarketQuoteRequest(_cosco)]), hasLength(1));
    expect(client.urls.single, Uri.parse('https://qt.gtimg.cn/q=sh600026'));
    expect(request.followRedirects, isFalse);
    expect(request.persistentConnection, isFalse);
    expect(request.cookies, isEmpty);
    expect(request.headers.values, isNot(contains(HttpHeaders.cookieHeader)));
    expect(
      request.headers.values,
      isNot(contains(HttpHeaders.authorizationHeader)),
    );
    expect(
      request.headers.values[HttpHeaders.userAgentHeader],
      contains('VeriFin'),
    );
    expect(client.forceClosed, isTrue);
  });

  test('HTTP传输拒绝任意主机、明文协议、非标准端口、凭证和附加参数', () async {
    final client = _RecordingClient(
      _RecordingRequest(_RecordingResponse(200, _fixtureBytes())),
    );
    final transport = TencentHttpQuoteTransport(client: client);
    for (final url in [
      'http://qt.gtimg.cn/q=sh600026',
      'https://example.com/q=sh600026',
      'https://qt.gtimg.cn:444/q=sh600026',
      'https://user:secret@qt.gtimg.cn/q=sh600026',
      'https://qt.gtimg.cn/q=sh600026?other=1',
      'https://qt.gtimg.cn/q=sh600026#fragment',
      'https://qt.gtimg.cn/q=TEST-TCH-CALL',
    ]) {
      await expectLater(transport.get(Uri.parse(url)), throwsFormatException);
    }
    expect(client.urls, isEmpty);
    transport.close();
  });
}
