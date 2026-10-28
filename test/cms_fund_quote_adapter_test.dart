import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/investments/cms_fund_quote_adapter.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
final _capturedAt = DateTime.utc(2026, 10, 28, 2, 41, 45);

/// 读取实际匿名 POST 捕获的 33117 字节 JSON；测试从不访问真实网络。
List<int> _fixtureBytes() => File(
  'test/fixtures/investments/cms_usd_money_market_20261028.json',
).readAsBytesSync();

/// 从真实夹具解析一份可修改副本，避免错误用例互相污染或重造理想化基金响应。
Map<String, Object?> _fixtureJson() =>
    jsonDecode(utf8.decode(_fixtureBytes())) as Map<String, Object?>;

/// 提取夹具的结果对象；[root] 为本用例独占的原始 JSON 副本。
Map<String, Object?> _result(Map<String, Object?> root) =>
    root['result']! as Map<String, Object?>;

/// 找到真实夹具的 B 类向量；[result] 仍保留其他类别，包括 P 类历史 null。
Map<String, Object?> _bSeries(Map<String, Object?> result) =>
    (result['fundClassDataList']! as List<Object?>)
        .whereType<Map<String, Object?>>()
        .singleWhere((series) => series['name'] == 'B类');

/// 在真实响应结构上施加局部改动；[change] 只改当前副本，用于模拟错误来源字段。
List<int> _changedFixture(void Function(Map<String, Object?>) change) {
  final root = _fixtureJson();
  change(root);
  return utf8.encode(jsonEncode(root));
}

/// 包装原始字节为尚未读取的响应；[status] 和 [contentLength] 不会被改写成成功值。
CmsFundQuoteResponse _response({
  List<int>? bytes,
  int status = 200,
  int contentLength = -1,
}) => CmsFundQuoteResponse(
  statusCode: status,
  contentLength: contentLength,
  body: Stream.value(bytes ?? _fixtureBytes()),
);

/// 只记录地址、正文和关闭动作的本地传输；响应由 [respond] 提供，不创建套接字。
class _FixtureTransport implements CmsFundQuoteTransport {
  /// [respond] 可模拟实际字节、HTTP 失败、连接挂起；[onClose] 释放用例自己的流。
  _FixtureTransport(this.respond, {this.onClose});

  final FutureOr<CmsFundQuoteResponse> Function(Uri, List<int>) respond;
  final void Function()? onClose;
  final List<({Uri uri, List<int> body})> requests = [];
  bool closed = false;

  /// 捕获实际公开参数，再交给本用例响应函数；[body] 复制后保存，防止事后改写证据。
  @override
  Future<CmsFundQuoteResponse> post(Uri uri, List<int> body) async {
    requests.add((uri: uri, body: List<int>.of(body)));
    return respond(uri, body);
  }

  /// 标记传输已终止，并调用可选的响应流清理；不会操作设备或其他请求。
  @override
  void close() {
    closed = true;
    onClose?.call();
  }
}

/// 把测试传输和固定抓取时刻注入适配器；[transport] 始终是当前用例自己的对象。
CmsFundQuoteAdapter _adapter(_FixtureTransport transport) =>
    CmsFundQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _capturedAt,
    );

/// 创建两个连续来源日的只读净值，供缓存和当前报价的末点一致性测试复用。
FundNavHistory _shortHistory() => FundNavHistory([
  FundNavPoint(date: DateTime.utc(2026, 10, 26), price: '109.8060'),
  FundNavPoint(date: DateTime.utc(2026, 10, 27), price: '109.8150'),
]);

/// 把 [history] 绑定为公开观察；其余参数只用于制造品种、单位、日期或末点不一致。
/// [fetchedAt] 是真实瞬时抓取时间，[date] 则只是来源的 UTC 年月日载体。
MarketQuote _historicalQuote(
  FundNavHistory history, {
  StockSecurity security = _fund,
  QuotePriceUnit unit = QuotePriceUnit.fundUnit,
  bool dateOnly = true,
  String price = '109.8150',
  DateTime? date,
  DateTime? fetchedAt,
}) => MarketQuote(
  securityId: security.id,
  source: CmsFundQuoteAdapter.sourceId,
  currency: security.currencyCode,
  unit: unit,
  fetchedAt: fetchedAt ?? _capturedAt,
  last: price,
  lastAt: date ?? DateTime.utc(2026, 10, 27),
  dateOnly: dateOnly,
  navHistory: history,
);

/// 生成按日递增的合成边界点；[index] 只为验证数组上限，不冒充该基金的真实净值。
FundNavPoint _boundaryPoint(int index) {
  final calendarDate = addCalendarDays(DateTime(2000, 1, 1), index);
  return FundNavPoint(
    date: DateTime.utc(calendarDate.year, calendarDate.month, calendarDate.day),
    price: '100',
  );
}

/// 验证错误来源字段整批失败并关闭连接；[change] 在真实夹具上构造一个局部错误。
Future<void> _expectInvalid(void Function(Map<String, Object?>) change) async {
  final transport = _FixtureTransport(
    (_, _) => _response(bytes: _changedFixture(change)),
  );
  await expectLater(
    _adapter(transport).fetch([MarketQuoteRequest(_fund)]),
    throwsFormatException,
  );
  expect(transport.requests, hasLength(1));
  expect(transport.closed, isTrue);
}

/// 记录生产传输会触碰的 HTTP 头；预放旧凭证，检查请求前必须明确删除。
class _RecordingHeaders implements HttpHeaders {
  final values = <String, Object>{
    HttpHeaders.cookieHeader: '旧会话不得发送',
    HttpHeaders.authorizationHeader: '旧授权不得发送',
    HttpHeaders.proxyAuthorizationHeader: '旧代理授权不得发送',
    HttpHeaders.userAgentHeader: '保持原有客户端标识',
  };
  @override
  ContentType? contentType;

  /// 保存指定头的内存值，供测试核对 Accept 等公开协议字段。
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  /// 删除指定头；[name] 使用生产 HttpHeaders 常量，不向外发送任何内容。
  @override
  void removeAll(String name) => values.remove(name.toLowerCase());

  /// 没有用到的 HTTP 能力保留未实现，避免替身意外掩盖生产代码的新依赖。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 仅提供预设状态及可取消的字节流，不模拟服务器重定向、会话或额外网络请求。
class _RecordingResponse extends Stream<List<int>>
    implements HttpClientResponse {
  /// [statusCode] 和 [bytes] 是该用例交给生产传输的原始响应。
  _RecordingResponse(this.statusCode, this.bytes);

  @override
  final int statusCode;
  final List<int> bytes;

  /// 返回已知的实际字节数，验证生产传输没有丢弃来源长度信息。
  @override
  int get contentLength => bytes.length;

  /// 按 Stream 契约转发一次字节响应；调用方可取消，不预先解析来源正文。
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

  /// 本用例不需要的响应元数据不做虚构实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录生产 POST 请求的正文和配置，不访问真实基金网站。
class _RecordingRequest implements HttpClientRequest {
  /// [response] 为 close 后唯一返回的响应，不隐藏任何重试行为。
  _RecordingRequest(this.response);

  final HttpClientResponse response;
  final bytes = <int>[];
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  int contentLength = -1;
  @override
  final _RecordingHeaders headers = _RecordingHeaders();
  @override
  final List<Cookie> cookies = [Cookie('old_session', 'discard')];

  /// 保存本次实际写入的正文，验证只发送固定公开基金参数而没有任何持仓数据。
  @override
  void add(List<int> data) => bytes.addAll(data);

  /// 结束本地请求并返回指定响应，测试不建立连接。
  @override
  Future<HttpClientResponse> close() async => response;

  /// 未使用的请求功能保持未实现，防止测试替身变成第二套 HTTP 实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 把生产 HTTP 传输绑定到内存记录器，检查固定地址、匿名参数及强制关闭。
class _RecordingClient implements HttpClient {
  /// [request] 是 postUrl 返回的唯一请求；客户端不持有真实网络连接。
  _RecordingClient(this.request);

  final _RecordingRequest request;
  final List<Uri> urls = [];
  @override
  Duration? connectionTimeout;
  bool forceClosed = false;

  /// 记录生产传输实际访问的 URL，不接受用例之外的隐藏网络路径。
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    urls.add(url);
    return request;
  }

  /// 记录是否强制关闭，用于确认超时和结束时会终止底层请求。
  @override
  void close({bool force = false}) => forceClosed = force;

  /// 其他客户端能力保持未实现；若生产代码新增证书绕过等操作，本替身不会默认放行。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 注册真实净值响应、严格身份/日期/价格校验，以及匿名传输的资源和关闭边界。
void main() {
  test('真实官网响应保留 B 类原始净值、基金单位、源日期和独立抓取时间', () async {
    final transport = _FixtureTransport((_, _) => _response());
    final adapter = _adapter(transport);
    final request = MarketQuoteRequest(_fund);
    final quote = (await adapter.fetch([request])).single;

    expect(adapter.capability.id, 'CMS Asset Management (HK)');
    expect(adapter.capability.approved, isFalse);
    expect(adapter.capability.researchOnly, isTrue);
    expect(transport.requests, hasLength(1));
    expect(
      transport.requests.single.uri.toString(),
      'https://cms.cmschina.com.hk/api/v1/fund/netVal-info',
    );
    expect(jsonDecode(utf8.decode(transport.requests.single.body)), {
      'lang': 'zh-CN',
      'fundName': 'CMS_USD_Money_Market_Fund',
    });
    expect(quote.securityId, request.securityId);
    expect(quote.source, 'CMS Asset Management (HK)');
    expect(quote.currency, 'USD');
    expect(quote.unit, QuotePriceUnit.fundUnit);
    expect(quote.last, '109.8150');
    expect(quote.lastAt, DateTime.utc(2026, 10, 27));
    expect(quote.dateOnly, isTrue);
    expect(quote.navHistory!.points, hasLength(543));
    expect(quote.navHistory!.points.first.date, DateTime.utc(2024, 8, 9));
    expect(quote.navHistory!.points.first.price, '100');
    expect(quote.navHistory!.points.last.date, quote.lastAt);
    expect(quote.navHistory!.points.last.price, '109.8150');
    expect(quote.fetchedAt, _capturedAt);
    expect(quote.bid, isNull);
    expect(quote.ask, isNull);
    expect(quote.delayMinutes, isNull);
    expect(quote.tradeState, QuoteTradeState.unknown);
    expect(transport.closed, isTrue);

    final result = _result(_fixtureJson());
    expect(result['dateList'], hasLength(543));
    expect(_bSeries(result)['key'], 'B');
    final pSeries = (result['fundClassDataList']! as List<Object?>)
        .whereType<Map<String, Object?>>()
        .singleWhere((series) => series['name'] == 'P类');
    expect(
      (pSeries['data']! as List<Object?>).where((value) => value == null),
      hasLength(461),
    );
  });

  test('基金身份、股票、期权、其他份额和错币种不会进入支持范围', () async {
    var created = 0;
    final adapter = CmsFundQuoteAdapter(
      transportFactory: () {
        created++;
        return _FixtureTransport((_, _) => _response());
      },
    );
    final unsupported = [
      const StockSecurity(
        symbol: 'HK0001039582',
        name: '相同代码的股票身份',
        market: StockMarket.hk,
        currencyCode: 'USD',
      ),
      const StockSecurity(
        symbol: 'HK0001039574',
        name: 'A 类不能混作 B 类',
        market: StockMarket.hk,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      const StockSecurity(
        symbol: 'hk0001039582',
        name: '没有核对的小写代码',
        market: StockMarket.hk,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      const StockSecurity(
        symbol: 'HK0001039582',
        name: '错误市场',
        market: StockMarket.cn,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      const StockSecurity(
        symbol: 'HK0001039582',
        name: '错误币种',
        market: StockMarket.hk,
        currencyCode: 'HKD',
        type: InvestmentSecurityType.fund,
      ),
      StockSecurity(
        symbol: 'HK0001039582',
        name: '基金代码不能变成期权',
        market: StockMarket.hk,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
        option: optionFixture().option,
      ),
      optionFixture(),
    ];
    for (final security in unsupported) {
      expect(adapter.supports(MarketQuoteRequest(security)), isFalse);
    }
    expect(
      await adapter.fetch(unsupported.map(MarketQuoteRequest.new).toList()),
      isEmpty,
    );
    expect(await adapter.fetch([]), isEmpty);
    expect(created, 0);
  });

  test('二十个重复身份只发一次 POST 并返回一份原身份净值', () async {
    final transport = _FixtureTransport((_, _) => _response());
    final quotes = await _adapter(
      transport,
    ).fetch(List.generate(20, (_) => MarketQuoteRequest(_fund)));
    expect(quotes, hasLength(1));
    expect(transport.requests, hasLength(1));
    expect(quotes.single.securityId, _fund.id);
  });

  test('完整真实净值历史可往返缓存，日期精度、尾零和每个点保持不变', () async {
    final transport = _FixtureTransport((_, _) => _response());
    final quote = (await _adapter(
      transport,
    ).fetch([MarketQuoteRequest(_fund)])).single;
    final json = quote.toJson();
    final historyJson = json['navHistory']! as List<Object?>;
    expect(historyJson, hasLength(543));
    expect(historyJson.first, {'date': '2024-08-09', 'price': '100'});
    expect(historyJson.last, {'date': '2026-10-27', 'price': '109.8150'});
    final restored = MarketQuote.fromJson(
      jsonDecode(jsonEncode(json)) as Map<String, Object?>,
    );
    expect(restored.toJson(), json);
    expect(restored.navHistory!.points.last.price, '109.8150');
    expect(restored.last, '109.8150');
    expect(
      restored.reference(MarketQuoteRequest(_fund), _capturedAt)?.price,
      '109.815',
    );
  });

  test('旧缓存没有净值历史字段时仍可恢复，不生成空历史或虚构过往净值', () {
    final legacyFund = MarketQuote(
      securityId: _fund.id,
      source: CmsFundQuoteAdapter.sourceId,
      currency: 'USD',
      unit: QuotePriceUnit.fundUnit,
      fetchedAt: _capturedAt,
      last: '109.8150',
      lastAt: DateTime.utc(2026, 10, 27),
      dateOnly: true,
    );
    expect(legacyFund.toJson(), isNot(contains('navHistory')));
    final restoredFund = MarketQuote.fromJson(legacyFund.toJson());
    expect(restoredFund.navHistory, isNull);
    expect(
      restoredFund.reference(MarketQuoteRequest(_fund), _capturedAt),
      isNotNull,
    );
    final legacyStock = MarketQuote(
      securityId: avgoFixture.id,
      source: '旧版本地股票夹具',
      currency: 'USD',
      unit: QuotePriceUnit.share,
      fetchedAt: _capturedAt,
      last: '100',
      lastAt: _capturedAt,
    );
    expect(legacyStock.toJson(), isNot(contains('dateOnly')));
    expect(legacyStock.toJson(), isNot(contains('navHistory')));
    final restoredStock = MarketQuote.fromJson(legacyStock.toJson());
    expect(restoredStock.dateOnly, isFalse);
    expect(restoredStock.navHistory, isNull);
    expect(
      restoredStock.reference(MarketQuoteRequest(avgoFixture), _capturedAt),
      isNotNull,
    );
  });

  test('净值历史复制输入并公开不可变点列表，调用方不能改写缓存依据', () {
    final input = [..._shortHistory().points];
    final history = FundNavHistory(input);
    input.clear();
    expect(history.points, hasLength(2));
    expect(() => history.points.clear(), throwsUnsupportedError);
    expect(() => history.points.add(_boundaryPoint(0)), throwsUnsupportedError);
  });

  test('净值历史拒绝空、重复、倒序、非法UTC载体和非正精确数', () {
    expect(() => FundNavHistory([]), throwsFormatException);
    final valid = _shortHistory().points;
    expect(
      () => FundNavHistory([valid.first, valid.first]),
      throwsFormatException,
    );
    expect(() => FundNavHistory(valid.reversed), throwsFormatException);
    for (final point in [
      FundNavPoint(date: DateTime(2026, 10, 27), price: '100'),
      FundNavPoint(date: DateTime.utc(2026, 10, 27, 1), price: '100'),
      FundNavPoint(date: DateTime.utc(1899, 1, 1), price: '100'),
      FundNavPoint(date: DateTime.utc(10000, 1, 1), price: '100'),
      for (final price in ['0', '-1', 'NaN', '1e2', ' 100', '1.123456789'])
        FundNavPoint(date: DateTime.utc(2026, 10, 27), price: price),
    ]) {
      expect(() => FundNavHistory([point]), throwsFormatException);
      expect(point.toJson, throwsFormatException);
    }
  });

  test('净值历史点缓存拒绝溢出日期、隐藏时间和不含精确数字文本的字段', () {
    for (final json in <Object?>[
      null,
      [],
      {'date': '2026-02-30', 'price': '100'},
      {'date': '2026-13-01', 'price': '100'},
      {'date': '2026-00-01', 'price': '100'},
      {'date': '2026-10-00', 'price': '100'},
      {'date': '1899-01-01', 'price': '100'},
      {'date': '10000-01-01', 'price': '100'},
      {'date': '2026-10-27T00:00:00Z', 'price': '100'},
      {'date': '20261027', 'price': '100'},
      {'date': '2026-10-27', 'price': null},
      {'date': '2026-10-27', 'price': 100},
      {'date': null, 'price': '100'},
    ]) {
      expect(() => FundNavPoint.fromJson(json), throwsFormatException);
    }
    for (final json in <Object?>[
      null,
      {},
      [],
      [null],
      [
        {'date': '2026-10-27', 'price': '100'},
        {'date': '2026-10-27', 'price': '101'},
      ],
    ]) {
      expect(() => FundNavHistory.fromJson(json), throwsFormatException);
    }
  });

  test('历史最多四千零九十六点，超限Iterable提前停止且缓存数组先检查长度', () {
    final maximum = FundNavHistory.maximumPoints;
    final allowed = FundNavHistory(List.generate(maximum, _boundaryPoint));
    expect(allowed.points, hasLength(maximum));
    var consumed = 0;

    /// 模拟超过上限的来源序列，计数用于确认构造器没有先无限制 materialize 全部点。
    Iterable<FundNavPoint> tooMany() sync* {
      for (var index = 0; index < maximum + 100; index++) {
        consumed++;
        yield _boundaryPoint(index);
      }
    }

    expect(() => FundNavHistory(tooMany()), throwsFormatException);
    expect(consumed, maximum + 1);
    expect(
      () => FundNavHistory.fromJson(List<Object?>.filled(maximum + 1, null)),
      throwsFormatException,
    );
  });

  test('完整历史只能用于日期型基金单位，末点必须与最新日期及净值一致', () {
    final history = _shortHistory();
    final invalid = [
      _historicalQuote(history, dateOnly: false),
      _historicalQuote(history, unit: QuotePriceUnit.share),
      _historicalQuote(history, date: DateTime.utc(2026, 10, 26)),
      _historicalQuote(history, price: '109.8160'),
      _historicalQuote(history, price: ' 109.8150'),
      _historicalQuote(history, fetchedAt: DateTime.utc(2026, 10, 25, 12)),
    ];
    for (final quote in invalid) {
      expect(quote.reference(MarketQuoteRequest(_fund), _capturedAt), isNull);
      expect(quote.toJson, throwsFormatException);
    }
    final stock = _historicalQuote(
      history,
      security: avgoFixture,
      unit: QuotePriceUnit.share,
      dateOnly: false,
    );
    expect(
      stock.reference(MarketQuoteRequest(avgoFixture), _capturedAt),
      isNull,
    );
    final option = optionFixture();
    expect(
      _historicalQuote(
        history,
        security: option,
        unit: QuotePriceUnit.premiumUnit,
        dateOnly: false,
      ).reference(MarketQuoteRequest(option), _capturedAt),
      isNull,
    );
  });

  test('带完整历史的缓存拒绝错误单位、隐藏时刻、末点不符与未来净值日', () {
    final changes = <void Function(Map<String, Object?>)>[
      (json) => json['dateOnly'] = false,
      (json) => json['unit'] = 'share',
      (json) => json['last'] = '109.8160',
      (json) => json['lastAt'] = '2026-10-27T01:00:00.000Z',
      (json) => json['lastAt'] = '2026-10-27T00:00:00Z',
      (json) => json['navHistory'] = '不是数组',
      (json) {
        final points = json['navHistory']! as List<Object?>;
        (points.last! as Map<String, Object?>)['price'] = '109.8160';
      },
      (json) {
        final points = json['navHistory']! as List<Object?>;
        (points.last! as Map<String, Object?>)['date'] = '2026-10-29';
        json['lastAt'] = '2026-10-29T00:00:00.000Z';
      },
    ];
    for (final change in changes) {
      final json =
          jsonDecode(jsonEncode(_historicalQuote(_shortHistory()).toJson()))
              as Map<String, Object?>;
      change(json);
      expect(() => MarketQuote.fromJson(json), throwsFormatException);
    }
  });

  test('香港已进入次日时可接受当日历史，不把UTC日期载体当成未来报价时刻', () {
    final history = FundNavHistory([
      FundNavPoint(date: DateTime.utc(2026, 10, 27), price: '109.8150'),
    ]);
    final instant = DateTime.utc(2026, 10, 26, 16, 30);
    final quote = _historicalQuote(history, fetchedAt: instant);
    expect(
      quote.reference(MarketQuoteRequest(_fund), instant)?.price,
      '109.815',
    );
    expect(
      MarketQuote.fromJson(quote.toJson()).navHistory!.points,
      hasLength(1),
    );
  });

  test('超过二十个输入身份在创建连接前拒绝，不静默截取', () async {
    var created = 0;
    final adapter = CmsFundQuoteAdapter(
      transportFactory: () {
        created++;
        return _FixtureTransport((_, _) => _response());
      },
    );
    await expectLater(
      adapter.fetch(List.generate(21, (_) => MarketQuoteRequest(_fund))),
      throwsFormatException,
    );
    expect(created, 0);
  });

  test('非零、缺失和非整型状态码不会被当作来源成功', () async {
    for (final code in <Object?>[1, -1, null, '0', 0.0]) {
      await _expectInvalid((root) => root['code'] = code);
    }
  });

  test('缺少结果、日期、份额或最新摘要时明确失败', () async {
    await _expectInvalid((root) => root['result'] = null);
    for (final key in ['dateList', 'fundClassDataList', 'lastValMap']) {
      await _expectInvalid((root) => _result(root).remove(key));
    }
    await _expectInvalid((root) => _result(root)['dateList'] = []);
  });

  test('缺失、重名或数据向量非法的 B 类不会借用其他类别', () async {
    await _expectInvalid((root) {
      (_result(root)['fundClassDataList']! as List<Object?>).removeWhere(
        (series) => series is Map<String, Object?> && series['name'] == 'B类',
      );
    });
    await _expectInvalid((root) {
      final result = _result(root);
      (result['fundClassDataList']! as List<Object?>).add(
        Map<String, Object?>.of(_bSeries(result)),
      );
    });
    await _expectInvalid((root) => _bSeries(_result(root))['data'] = null);
    await _expectInvalid((root) {
      (_bSeries(_result(root))['data']! as List<Object?>).removeLast();
    });
    await _expectInvalid((root) {
      (_bSeries(_result(root))['data']! as List<Object?>).add('109.8150');
    });
    await _expectInvalid((root) {
      final result = _result(root);
      result['dateList'] = List<Object?>.filled(
        FundNavHistory.maximumPoints + 1,
        '20240809',
      );
      _bSeries(result)['data'] = List<Object?>.filled(
        FundNavHistory.maximumPoints + 1,
        '100',
      );
    });
  });

  test('B 类的来源键和名称必须一致，重复 B 键即使名称不同也拒绝', () async {
    await _expectInvalid((root) => _bSeries(_result(root))['key'] = 'A');
    await _expectInvalid((root) => _bSeries(_result(root))['name'] = 'A类');
    await _expectInvalid((root) => _bSeries(_result(root)).remove('key'));
    await _expectInvalid((root) {
      final result = _result(root);
      (result['fundClassDataList']! as List<Object?>).add({
        ..._bSeries(result),
        'name': '另一个名称不能掩盖重复 B 键',
      });
    });
  });

  for (final value in <Object?>[
    null,
    100,
    '',
    '0',
    '-0',
    '-1',
    'NaN',
    'Infinity',
    '1e3',
    ' 100',
    '100 ',
    '1.123456789',
    '1000000000000',
  ]) {
    test('历史 B 类净值缺失或非法时不补零、不截精度：$value', () async {
      await _expectInvalid((root) {
        (_bSeries(_result(root))['data']! as List<Object?>)[1] = value;
      });
    });
  }

  for (final value in <Object?>[
    null,
    20240812,
    '',
    '2024-08-12',
    '20240230',
    '20241301',
    '20240012',
    '20240800',
    '18990812',
  ]) {
    test('源日历日缺失或溢出不被自动归一为有效日期：$value', () async {
      await _expectInvalid((root) {
        (_result(root)['dateList']! as List<Object?>)[1] = value;
      });
    });
  }

  test('日期必须严格升序，重复、倒序和未来日期一律拒绝', () async {
    await _expectInvalid((root) {
      final dates = _result(root)['dateList']! as List<Object?>;
      dates[1] = dates[0];
    });
    await _expectInvalid((root) {
      final dates = _result(root)['dateList']! as List<Object?>;
      final first = dates[0];
      dates[0] = dates[1];
      dates[1] = first;
    });
    await _expectInvalid((root) {
      final result = _result(root);
      final dates = result['dateList']! as List<Object?>;
      dates[dates.length - 1] = '20261029';
      result['lastUpdate'] = '20261029';
    });
  });

  test('最新日期和 B 类摘要必须存在且与历史末点一致', () async {
    for (final date in <Object?>[null, '', '20260230', '20261028']) {
      await _expectInvalid((root) => _result(root)['lastUpdate'] = date);
    }
    for (final value in <Object?>[null, 109.815, '', '0', '109.8160']) {
      await _expectInvalid((root) {
        (_result(root)['lastValMap']! as Map<String, Object?>)['B'] = value;
      });
    }
    await _expectInvalid((root) {
      (_result(root)['lastValMap']! as Map<String, Object?>).remove('B');
    });
  });

  test('数值相等但尾零精度不同的摘要保留原始数字文本', () async {
    final transport = _FixtureTransport(
      (_, _) => _response(
        bytes: _changedFixture((root) {
          (_result(root)['lastValMap']! as Map<String, Object?>)['B'] =
              '109.81500000';
        }),
      ),
    );
    final quote = (await _adapter(
      transport,
    ).fetch([MarketQuoteRequest(_fund)])).single;
    expect(quote.last, '109.81500000');
  });

  test('畸形 UTF-8、JSON 和非对象响应不执行文本或产生净值', () async {
    for (final bytes in [
      [255],
      utf8.encode('throw new Error("不得执行来源文本")'),
      utf8.encode('[]'),
      utf8.encode('null'),
    ]) {
      final transport = _FixtureTransport((_, _) => _response(bytes: bytes));
      await expectLater(
        _adapter(transport).fetch([MarketQuoteRequest(_fund)]),
        throwsFormatException,
      );
      expect(transport.closed, isTrue);
    }
  });

  for (final status in [301, 302, 401, 403, 429, 500]) {
    test('HTTP $status 不跳转、不重试且关闭连接', () async {
      final transport = _FixtureTransport((_, _) => _response(status: status));
      await expectLater(
        _adapter(transport).fetch([MarketQuoteRequest(_fund)]),
        throwsA(isA<HttpException>()),
      );
      expect(transport.requests, hasLength(1));
      expect(transport.closed, isTrue);
    });
  }

  test('建连失败会关闭传输且不换身份重试', () async {
    final transport = _FixtureTransport(
      (_, _) => throw const SocketException('本地模拟网络失败'),
    );
    await expectLater(
      _adapter(transport).fetch([MarketQuoteRequest(_fund)]),
      throwsA(isA<SocketException>()),
    );
    expect(transport.requests, hasLength(1));
    expect(transport.closed, isTrue);
  });

  test('连接阶段挂起仍受整批总时限约束，超时实际关闭传输', () async {
    final pending = Completer<CmsFundQuoteResponse>();
    final transport = _FixtureTransport((_, _) => pending.future);
    final adapter = CmsFundQuoteAdapter(
      transportFactory: () => transport,
      requestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      adapter.fetch([MarketQuoteRequest(_fund)]),
      throwsA(isA<TimeoutException>()),
    );
    expect(transport.closed, isTrue);
    pending.complete(_response());
  });

  test('响应流停滞同样受总时限约束，并由关闭传输释放流', () async {
    final controller = StreamController<List<int>>();
    final transport = _FixtureTransport(
      (_, _) => CmsFundQuoteResponse(statusCode: 200, body: controller.stream),
      onClose: () => unawaited(controller.close()),
    );
    final adapter = CmsFundQuoteAdapter(
      transportFactory: () => transport,
      requestTimeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      adapter.fetch([MarketQuoteRequest(_fund)]),
      throwsA(isA<TimeoutException>()),
    );
    expect(transport.closed, isTrue);
    expect(controller.isClosed, isTrue);
  });

  test('声明超大响应时不读取正文，未知长度时逐块累计并及时取消', () async {
    var consumed = false;
    final declaredTransport = _FixtureTransport(
      (_, _) => CmsFundQuoteResponse(
        statusCode: 200,
        contentLength: CmsFundQuoteAdapter.maximumBytes + 1,
        body: Stream<List<int>>.value(_fixtureBytes()).map((bytes) {
          consumed = true;
          return bytes;
        }),
      ),
    );
    await expectLater(
      _adapter(declaredTransport).fetch([MarketQuoteRequest(_fund)]),
      throwsFormatException,
    );
    expect(consumed, isFalse);
    expect(declaredTransport.closed, isTrue);

    var readAfterLimit = false;

    /// 前两块累计超限后必须取消订阅，不应再读取后面的源字节。
    Stream<List<int>> oversizedBody() async* {
      yield List<int>.filled(CmsFundQuoteAdapter.maximumBytes, 32);
      yield [32];
      readAfterLimit = true;
      yield _fixtureBytes();
    }

    final streamingTransport = _FixtureTransport(
      (_, _) => CmsFundQuoteResponse(statusCode: 200, body: oversizedBody()),
    );
    await expectLater(
      _adapter(streamingTransport).fetch([MarketQuoteRequest(_fund)]),
      throwsFormatException,
    );
    expect(readAfterLimit, isFalse);
    expect(streamingTransport.closed, isTrue);
  });

  test('恰好五百一十二 KiB 的有效响应允许解析，不多减一字节', () async {
    final fixture = _fixtureBytes();
    final padded = [
      ...fixture,
      ...List<int>.filled(
        CmsFundQuoteAdapter.maximumBytes - fixture.length,
        32,
      ),
    ];
    final transport = _FixtureTransport(
      (_, _) => _response(bytes: padded, contentLength: padded.length),
    );
    final quotes = await _adapter(transport).fetch([MarketQuoteRequest(_fund)]);
    expect(quotes.single.last, '109.8150');
    expect(transport.closed, isTrue);
  });

  test('生产 HTTP 固定匿名 JSON POST，不跳转、不带旧凭证且不改 User-Agent', () async {
    final request = _RecordingRequest(_RecordingResponse(200, _fixtureBytes()));
    final client = _RecordingClient(request);
    final adapter = CmsFundQuoteAdapter(
      transportFactory: () => CmsFundHttpQuoteTransport(client: client),
      clock: () => _capturedAt,
    );
    expect(await adapter.fetch([MarketQuoteRequest(_fund)]), hasLength(1));
    expect(
      client.urls.single,
      Uri.parse('https://cms.cmschina.com.hk/api/v1/fund/netVal-info'),
    );
    expect(utf8.decode(request.bytes), CmsFundQuoteAdapter.requestBody);
    expect(request.contentLength, request.bytes.length);
    expect(request.headers.contentType?.mimeType, 'application/json');
    expect(
      request.headers.values[HttpHeaders.acceptHeader],
      'application/json',
    );
    expect(request.followRedirects, isFalse);
    expect(request.persistentConnection, isFalse);
    expect(request.cookies, isEmpty);
    for (final header in [
      HttpHeaders.cookieHeader,
      HttpHeaders.authorizationHeader,
      HttpHeaders.proxyAuthorizationHeader,
    ]) {
      expect(request.headers.values, isNot(contains(header)));
    }
    expect(request.headers.values[HttpHeaders.userAgentHeader], '保持原有客户端标识');
    expect(client.forceClosed, isTrue);
  });

  test('生产传输在建连前拒绝其他主机、协议、端口、凭证、路径及任意正文', () async {
    final client = _RecordingClient(
      _RecordingRequest(_RecordingResponse(200, _fixtureBytes())),
    );
    final transport = CmsFundHttpQuoteTransport(client: client);
    final body = utf8.encode(CmsFundQuoteAdapter.requestBody);
    for (final url in [
      'http://cms.cmschina.com.hk/api/v1/fund/netVal-info',
      'https://example.com/api/v1/fund/netVal-info',
      'https://cms.cmschina.com.hk:444/api/v1/fund/netVal-info',
      'https://user:secret@cms.cmschina.com.hk/api/v1/fund/netVal-info',
      'https://cms.cmschina.com.hk/api/v1/fund/netVal-info?extra=1',
      'https://cms.cmschina.com.hk/api/v1/fund/netVal-info#extra',
      'https://cms.cmschina.com.hk/api/v1/fund/netVal-export',
    ]) {
      await expectLater(
        transport.post(Uri.parse(url), body),
        throwsFormatException,
      );
    }
    await expectLater(
      transport.post(
        Uri.parse('https://cms.cmschina.com.hk/api/v1/fund/netVal-info'),
        utf8.encode('{"fundName":"不能自定义其他基金"}'),
      ),
      throwsFormatException,
    );
    expect(client.urls, isEmpty);
    transport.close();
    expect(client.forceClosed, isTrue);
  });

  test('构造器不允许关闭总时限或放宽十五秒上限', () {
    for (final timeout in [
      Duration.zero,
      const Duration(milliseconds: -1),
      const Duration(seconds: 16),
    ]) {
      expect(
        () => CmsFundQuoteAdapter(requestTimeout: timeout),
        throwsArgumentError,
      );
    }
  });
}
