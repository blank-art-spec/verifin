import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/security_search.dart';
import 'package:verifin/app/models.dart';

/// 以本地字节流模拟一次搜索，记录允许公开的请求地址，不访问真实网络。
class _SearchTransport implements SecuritySearchTransport {
  /// [body] 可用来模拟分块、超限和迟迟不结束的来源；[status] 模拟 HTTP 拒绝。
  _SearchTransport({required this.body, this.status = 200});

  final Stream<List<int>> body;
  final int status;
  Uri? requested;
  var closed = false;

  /// 保留 [uri] 供断言，仅返回本地响应而不创建套接字。
  @override
  Future<SecuritySearchResponse> get(Uri uri) async {
    requested = uri;
    return SecuritySearchResponse(statusCode: status, body: body);
  }

  /// 标记本次连接已释放，超时或失败均不得遗漏清理。
  @override
  void close() => closed = true;
}

/// 捕获生产传输实际移除及设置的请求头，初始凭证用于检验其不会被发送。
class _RequestHeaders implements HttpHeaders {
  final values = <String, Object>{
    HttpHeaders.cookieHeader: '旧会话',
    HttpHeaders.authorizationHeader: '旧凭证',
  };

  /// 将 [name] 和 [value] 存在内存，保持 HTTP 头名大小写无关的语义。
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;

  /// 从内存删除 [name]，供测试确认敏感头确实清除。
  @override
  void removeAll(String name) => values.remove(name.toLowerCase());

  /// 未被测试场景使用的头字段能力不作虚构实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 提供生产传输所需的最小状态码，测试不读取或连接真实响应流。
class _HttpResponse implements HttpClientResponse {
  /// 固定成功状态仅用于检查生产请求配置，不参加身份解析用例。
  @override
  int get statusCode => 200;

  /// 未使用的 HTTP 响应字段及流能力保持未实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 内存请求记录器，用来核对生产传输禁用重定向、持久连接及 Cookie 的实际行为。
class _HttpRequest implements HttpClientRequest {
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  final _RequestHeaders headers = _RequestHeaders();
  @override
  final List<Cookie> cookies = [Cookie('old', 'session')];

  /// 只返回预设的内存响应，不发送任何真实网络数据。
  @override
  Future<HttpClientResponse> close() async => _HttpResponse();

  /// 不为生产传输尚未使用的请求能力提供虚假实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 注入生产 HTTP 传输的地址记录器，白名单拒绝必须发生在 getUrl 之前。
class _HttpClient implements HttpClient {
  final urls = <Uri>[];
  final request = _HttpRequest();
  @override
  Duration? connectionTimeout;
  bool forceClosed = false;

  /// 记录 [url] 并返回唯一内存请求，测试可确认未访问其他主机或路径。
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return request;
  }

  /// 保留 [force]，核对生产传输采用可立即终止读取的关闭方式。
  @override
  void close({bool force = false}) => forceClosed = force;

  /// 未被本次传输调用的客户端能力保持未实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 将公开响应 [text] 转为 UTF-8 单块响应，测试走完整流读取和解析路径。
_SearchTransport _textTransport(String text) =>
    _SearchTransport(body: Stream.value(utf8.encode(text)));

/// 读取本轮真实匿名响应夹具，不把开发机的瞬时报价或用户账目作为测试数据。
Map<String, dynamic> _publicFixture() =>
    jsonDecode(
          File(
            'test/fixtures/investments/tencent_security_search_20261103.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

/// 用真实公开响应及故障流验证身份、币种、大小、超时和不执行脚本的网络边界。
void main() {
  test('生产传输在创建请求前拒绝非白名单主机、协议、端口及额外参数', () async {
    final client = _HttpClient();
    final transport = TencentSecuritySearchTransport(client: client);
    for (final address in [
      'http://smartbox.gtimg.cn/s3/?q=AVGO&t=all',
      'https://smartbox.gtimg.cn.evil.example/s3/?q=AVGO&t=all',
      'https://smartbox.gtimg.cn:8443/s3/?q=AVGO&t=all',
      'https://user:secret@smartbox.gtimg.cn/s3/?q=AVGO&t=all',
      'https://smartbox.gtimg.cn/other/?q=AVGO&t=all',
      'https://smartbox.gtimg.cn/s3/?q=AVGO&t=all#fragment',
      'https://smartbox.gtimg.cn/s3/?q=AVGO&t=all&account=x',
      'https://smartbox.gtimg.cn/s3/?q=AVGO&q=GOOG&t=all',
      'https://smartbox.gtimg.cn/s3/?q=AVGO&t=other',
      'https://smartbox.gtimg.cn/s3/?q=%0A&t=all',
    ]) {
      await expectLater(
        transport.get(Uri.parse(address)),
        throwsFormatException,
      );
    }
    expect(client.urls, isEmpty);
    transport.close();
    expect(client.forceClosed, isTrue);
  });

  test('生产传输仅请求允许地址并清除凭证，禁用重定向与持久连接', () async {
    final client = _HttpClient();
    final transport = TencentSecuritySearchTransport(client: client);
    final uri = Uri.https('smartbox.gtimg.cn', '/s3/', {'q': '腾讯', 't': 'all'});
    final response = await transport.get(uri);
    expect(response.statusCode, 200);
    expect(client.urls, [uri]);
    expect(client.connectionTimeout, const Duration(seconds: 8));
    expect(client.request.followRedirects, isFalse);
    expect(client.request.persistentConnection, isFalse);
    expect(client.request.cookies, isEmpty);
    expect(
      client.request.headers.values.containsKey(HttpHeaders.cookieHeader),
      isFalse,
    );
    expect(
      client.request.headers.values.containsKey(
        HttpHeaders.authorizationHeader,
      ),
      isFalse,
    );
    transport.close();
    expect(client.forceClosed, isTrue);
  });

  test('来源的 Unicode 转义和 UTF-8 中文字面值解码为相同身份，不猜 GBK', () async {
    final encodedForms = [
      r'v_hint="us~avgo.oq~\u535a\u901a~bt~GP"',
      'v_hint="us~avgo.oq~博通~bt~GP"',
    ];
    for (final body in encodedForms) {
      final transport = _textTransport(body);
      final result = await SecuritySearchClient(
        transportFactory: () => transport,
      ).search('博通', market: StockMarket.us, currencyCode: 'USD');
      expect(result.single.name, '博通');
      expect(result.single.symbol, 'AVGO');
    }
    final invalidUtf8 = _SearchTransport(body: Stream.value([0xff]));
    await expectLater(
      SecuritySearchClient(
        transportFactory: () => invalidUtf8,
      ).search('博通', market: StockMarket.us, currencyCode: 'USD'),
      throwsFormatException,
    );
    expect(invalidUtf8.closed, isTrue);
  });

  test('真实美股身份解码中文，只发编码后的搜索词，不携带账户或价格', () async {
    final fixture = _publicFixture();
    final transport = _textTransport(fixture['avgo'] as String);
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('  avgo  ', market: StockMarket.us, currencyCode: 'USD');
    expect(result.single.symbol, 'AVGO');
    expect(result.single.name, '博通');
    expect(result.single.id, 'us:stock:AVGO');
    expect(result.single.currencyCode, 'USD');
    expect(result.single.option, isNull);
    expect(result.single.isStock, isTrue);
    expect(transport.requested!.scheme, 'https');
    expect(transport.requested!.host, 'smartbox.gtimg.cn');
    expect(transport.requested!.path, '/s3/');
    expect(transport.requested!.queryParameters, {'q': 'avgo', 't': 'all'});
    expect(transport.closed, isTrue);
  });

  test('真实港股保留前导零，排除同次返回的基金及沪深证券', () async {
    final transport = _textTransport(_publicFixture()['00700'] as String);
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('00700', market: StockMarket.hk, currencyCode: 'HKD');
    expect(result.map((s) => s.symbol), ['00700']);
    expect(result.single.name, '腾讯控股');
  });

  test('真实沪深搜索排除同代码指数和基金，不能把上海指数当作深圳股票', () async {
    final transport = _textTransport(_publicFixture()['000001'] as String);
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('000001', market: StockMarket.cn, currencyCode: 'CNY');
    expect(result.map((s) => s.symbol), ['000001']);
    expect(result.single.name, '平安银行');
    expect(result.single.id, 'cn:stock:000001');
  });

  test('真实美股类别点号只去末尾交易所后缀，BRK.A 与 BRK.B 身份不同', () async {
    final transport = _textTransport(_publicFixture()['brk'] as String);
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('brk', market: StockMarket.us, currencyCode: 'USD');
    expect(result.map((s) => s.symbol), containsAll(['BRK.A', 'BRK.B']));
    expect(result.any((s) => s.market != StockMarket.us), isFalse);
  });

  test('真实中文查询排除港股人民币柜台和权证，中文只作为 URI 查询数据', () async {
    final transport = _textTransport(_publicFixture()['腾讯'] as String);
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('腾讯', market: StockMarket.hk, currencyCode: 'HKD');
    expect(result.map((s) => s.symbol), ['00700', '01698']);
    expect(transport.requested!.queryParameters['q'], '腾讯');
    expect(transport.requested!.toString(), contains('%E8%85%BE%E8%AE%AF'));
  });

  test('无结果返回空集合；空词与不匹配币种不创建传输', () async {
    var opened = 0;
    final client = SecuritySearchClient(
      transportFactory: () {
        opened++;
        return _textTransport(_publicFixture()['none'] as String);
      },
    );
    expect(
      await client.search('  ', market: StockMarket.us, currencyCode: 'USD'),
      isEmpty,
    );
    expect(
      await client.search('AVGO', market: StockMarket.us, currencyCode: 'HKD'),
      isEmpty,
    );
    expect(opened, 0);
    expect(
      await client.search(
        'NORESULT',
        market: StockMarket.us,
        currencyCode: 'USD',
      ),
      isEmpty,
    );
    expect(opened, 1);
  });

  test('超长或包含控制字符的搜索词在创建传输前拒绝', () async {
    var opened = 0;
    final client = SecuritySearchClient(
      transportFactory: () {
        opened++;
        return _textTransport('v_hint="N";');
      },
    );
    for (final query in ['a' * 65, 'AV\nGO']) {
      await expectLater(
        client.search(query, market: StockMarket.us, currencyCode: 'USD'),
        throwsFormatException,
      );
    }
    expect(opened, 0);
  });

  test('只接受纯字符串赋值，额外脚本与非法 Unicode 不会被执行或接纳', () async {
    for (final body in [
      'v_hint="us~avgo.oq~博通~bt~GP";alert(1)',
      'v_other="us~avgo.oq~博通~bt~GP";',
      r'v_hint="us~avgo.oq~\uZZZZ~bt~GP";',
    ]) {
      final transport = _textTransport(body);
      await expectLater(
        SecuritySearchClient(
          transportFactory: () => transport,
        ).search('AVGO', market: StockMarket.us, currencyCode: 'USD'),
        throwsFormatException,
      );
      expect(transport.closed, isTrue);
    }
  });

  test('候选按稳定身份去重，未知市场、后缀和不支持的类别标记不接纳', () async {
    final rows = [
      'us~avgo.oq~博通~bt~GP',
      'us~AVGO.OQ~重复~cf~GP',
      'us~avgo.unknown~未知交易所~wz~GP',
      'us~qqq.oq~基金~jj~KJ',
      'hk~00700~腾讯~tx~GP',
      'us~foo.oq~~f~GP',
      'bad-row',
    ].join('^');
    final transport = _textTransport('v_hint=${jsonEncode(rows)};');
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('av', market: StockMarket.us, currencyCode: 'USD');
    expect(result.map((s) => s.symbol), ['AVGO']);
    expect(result.single.name, '博通');
  });

  test('拒绝 HTTP 访问失败，不重试且始终关闭连接', () async {
    final transport = _SearchTransport(body: const Stream.empty(), status: 403);
    await expectLater(
      SecuritySearchClient(
        transportFactory: () => transport,
      ).search('AVGO', market: StockMarket.us, currencyCode: 'USD'),
      throwsA(isA<HttpException>()),
    );
    expect(transport.closed, isTrue);
  });

  test('候选结果有界，来源即使返回更多证券也只保留前二十项', () async {
    final rows = List.generate(
      30,
      (index) => 'us~STOCK$index.oq~公开示例$index~s~GP',
    ).join('^');
    final transport = _textTransport('v_hint=${jsonEncode(rows)};');
    final result = await SecuritySearchClient(
      transportFactory: () => transport,
    ).search('STOCK', market: StockMarket.us, currencyCode: 'USD');
    expect(result.length, SecuritySearchClient.maximumResults);
    expect(result.first.symbol, 'STOCK0');
    expect(result.last.symbol, 'STOCK19');
  });

  test('流式响应超限立即停止，拒绝等完整下载后再判断大小', () async {
    var laterChunkRead = false;

    /// 第二块已超过上限，第三块不应被解析器继续读取。
    Stream<List<int>> oversized() async* {
      yield List.filled(SecuritySearchClient.maximumBytes, 32);
      yield [32];
      laterChunkRead = true;
      yield [32];
    }

    final transport = _SearchTransport(body: oversized());
    await expectLater(
      SecuritySearchClient(
        transportFactory: () => transport,
      ).search('AVGO', market: StockMarket.us, currencyCode: 'USD'),
      throwsFormatException,
    );
    expect(laterChunkRead, isFalse);
    expect(transport.closed, isTrue);
  });

  test('总时限覆盖等待响应内容，超时关闭连接且不返回晚到候选', () async {
    final pending = StreamController<List<int>>();
    final transport = _SearchTransport(body: pending.stream);
    final client = SecuritySearchClient(
      transportFactory: () => transport,
      requestTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(
      client.search('AVGO', market: StockMarket.us, currencyCode: 'USD'),
      throwsA(isA<TimeoutException>()),
    );
    expect(transport.closed, isTrue);
    pending.add(utf8.encode('v_hint="us~avgo.oq~博通~bt~GP";'));
    await pending.close();
  });
}
