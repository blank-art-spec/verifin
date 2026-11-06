import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_security_search.dart';
import 'package:verifin/app/investments/security_search.dart';
import 'package:verifin/app/models.dart';

/// 用真实官网片段或故障字节流替代网络，并记录请求是否完整释放。
class _FundTransport implements SecuritySearchTransport {
  /// [body] 可模拟分块及永不结束的响应；[status] 可模拟来源拒绝。
  _FundTransport(this.body, {this.status = 200});

  final Stream<List<int>> body;
  final int status;
  Uri? requested;
  bool closed = false;

  /// 仅记录 [uri] 并返回测试响应，不向任何远端发送请求。
  @override
  Future<SecuritySearchResponse> get(Uri uri) async {
    requested = uri;
    return SecuritySearchResponse(statusCode: status, body: body);
  }

  /// 保存关闭状态，验证正常、超时及解析失败都释放连接。
  @override
  void close() => closed = true;
}

/// 在内存中保存 HTTP 头，初始模拟旧凭证以验证生产传输会主动移除。
class _Headers implements HttpHeaders {
  final values = <String, Object>{
    HttpHeaders.cookieHeader: '旧会话',
    HttpHeaders.authorizationHeader: '旧凭证',
  };

  /// 记录 [name] 对应的 [value]，保持标准 HTTP 头大小写无关语义。
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value;

  /// 移除 [name]，让测试可以核对请求没有携带认证信息。
  @override
  void removeAll(String name) => values.remove(name.toLowerCase());

  /// 不实现本次请求无需使用的其他 HTTP 头接口。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 提供请求配置测试需要的成功状态，不产生真实网络流。
class _Response implements HttpClientResponse {
  @override
  int get statusCode => 200;

  /// 测试不会读取此响应，只检查请求的安全配置。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录传输是否禁止重定向、长连接和凭证。
class _Request implements HttpClientRequest {
  @override
  bool followRedirects = true;
  @override
  bool persistentConnection = true;
  @override
  final _Headers headers = _Headers();
  @override
  final cookies = [Cookie('old', 'session')];

  /// 返回固定状态，不建立任何外部连接。
  @override
  Future<HttpClientResponse> close() async => _Response();

  /// 不实现生产传输没有使用的请求能力。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录生产传输选择的地址，让白名单拒绝可在创建请求之前得到验证。
class _Client implements HttpClient {
  final urls = <Uri>[];
  final request = _Request();
  @override
  Duration? connectionTimeout;
  bool forced = false;

  /// 保存 [url] 并返回内存请求；测试套件本身完全离线。
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return request;
  }

  /// 保存 [force] 以核对连接关闭是否立即中断读取。
  @override
  void close({bool force = false}) => forced = force;

  /// 不实现生产代码没有使用的网络客户端能力。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 读取 2026-11-06 真实官方身份资料片段；[usd] 选择美元或港元产品。
String _cmsFixture({bool usd = true}) => File(
  'test/fixtures/investments/${usd ? 'cms_fund' : 'cms_hkd_fund'}_identity_20261106.html',
).readAsStringSync();

/// 读取同一天保存的惠理真实份额表，只用于身份与币种，不把表中净值带入结果。
String _valuePartnersFixture() => File(
  'test/fixtures/investments/value_partners_fund_identity_20261106.html',
).readAsStringSync();

/// 将 [html] 作为来源 UTF-8 响应，仍经过客户端完整流读取和解析流程。
_FundTransport _htmlTransport(String html) =>
    _FundTransport(Stream.value(utf8.encode(html)));

/// 使用真实官网夹具和故障注入核对基金身份、份额币种及网络边界。
void main() {
  test('官方美元四类ISIN分别返回真实基金身份，不把其他份额当成B类', () async {
    for (final entry in {
      'HK0001039574': 'A',
      'HK0001039582': 'B',
      'HK0001039590': 'I',
      'HK0001039608': 'M',
    }.entries) {
      final transport = _htmlTransport(_cmsFixture());
      final result =
          await FundSecuritySearchClient(
            transportFactory: () => transport,
          ).search(
            ' ${entry.key.toLowerCase()} ',
            market: StockMarket.hk,
            currencyCode: 'USD',
          );
      expect(result, hasLength(1));
      expect(result.single.id, 'hk:fund:${entry.key}');
      expect(
        result.single.name,
        'CMS USD Money Market Fund Class ${entry.value}',
      );
      expect(result.single.currencyCode, 'USD');
      expect(result.single.option, isNull);
      expect(transport.requested!.queryParameters, {'view': 'NPCF'});
      expect(transport.requested.toString(), isNot(contains(entry.key)));
      expect(transport.closed, isTrue);
    }
  });

  test('港元基金按每一类ISIN及份额币种识别，不因为名称含货币市场推断美元', () async {
    for (final entry in {
      'HK0000890803': 'A',
      'HK0000890811': 'B',
      'HK0000890829': 'I',
    }.entries) {
      final transport = _htmlTransport(_cmsFixture(usd: false));
      final result = await FundSecuritySearchClient(
        transportFactory: () => transport,
      ).search(entry.key, market: StockMarket.hk, currencyCode: 'HKD');
      expect(result.single.name, 'CMS Money Market Fund Class ${entry.value}');
      expect(result.single.currencyCode, 'HKD');
      expect(transport.requested!.queryParameters, {'view': 'CMMF'});
    }
  });

  test('未知ISIN、基础币种不符及份额币种不符均不能产生候选', () async {
    for (final sample in [
      (
        html: _cmsFixture().replaceAll('HK0001039582', 'HK0000000000'),
        symbol: 'HK0001039582',
      ),
      (
        html: _cmsFixture().replaceFirst('>USD</td>', '>EUR</td>'),
        symbol: 'HK0001039582',
      ),
      (
        html: _cmsFixture().replaceFirst(
          '>USD 101.359</td>',
          '>HKD 101.359</td>',
        ),
        symbol: 'HK0001039582',
      ),
      (
        html: _cmsFixture().replaceFirst(
          'NAV per Unit - Class B',
          'NAV per Unit - Class X',
        ),
        symbol: 'HK0001039582',
      ),
    ]) {
      final transport = _htmlTransport(sample.html);
      final result = await FundSecuritySearchClient(
        transportFactory: () => transport,
      ).search(sample.symbol, market: StockMarket.hk, currencyCode: 'USD');
      expect(result, isEmpty);
      expect(transport.closed, isTrue);
    }
  });

  test('脚本注释或导航里的代码不能伪装成基金身份，重复份额身份被拒绝', () async {
    final source = _cmsFixture().replaceAll('HK0001039582', 'HK0000000000');
    for (final html in [
      '$source<script>Class Z HK0001039582</script>',
      '$source<!-- Class Z HK0001039582 -->',
      '$source<div>Class Z HK0001039582</div>',
    ]) {
      final result = await FundSecuritySearchClient(
        transportFactory: () => _htmlTransport(html),
      ).search('HK0001039582', market: StockMarket.hk, currencyCode: 'USD');
      expect(result, isEmpty);
    }
    final duplicated = _cmsFixture().replaceFirst(
      'HK0001039574',
      'HK0001039582',
    );
    final result = await FundSecuritySearchClient(
      transportFactory: () => _htmlTransport(duplicated),
    ).search('HK0001039582', market: StockMarket.hk, currencyCode: 'USD');
    expect(result, isEmpty);
  });

  test('惠理同一美元货币基金内的美元与港元份额按独立币种列识别', () async {
    for (final entry in {
      'HK0000945037': ('A', 'USD'),
      'HK0000961927': ('B', 'USD'),
      'HK0000945029': ('A', 'HKD'),
      'HK0000961919': ('B', 'HKD'),
      'HK0000945045': ('D', 'HKD'),
    }.entries) {
      final transport = _htmlTransport(_valuePartnersFixture());
      final result = await FundSecuritySearchClient(
        transportFactory: () => transport,
      ).search(entry.key, market: StockMarket.hk, currencyCode: entry.value.$2);
      expect(result.single.id, 'hk:fund:${entry.key}');
      expect(result.single.currencyCode, entry.value.$2);
      expect(
        result.single.name,
        endsWith('Class ${entry.value.$1} ${entry.value.$2} Unhedged Acc'),
      );
      expect(transport.requested!.host, 'www.valuepartners-group.com');
      expect(transport.requested!.hasQuery, isFalse);
      expect(transport.closed, isTrue);
    }
  });

  test('惠理查询精确匹配ISIN，不接受币种不符、重复身份或其他基金分组的相同代码', () async {
    for (final sample in [
      (html: _valuePartnersFixture(), symbol: 'HK0000000000', currency: 'USD'),
      (html: _valuePartnersFixture(), symbol: 'HK0000945029', currency: 'USD'),
      (
        html: _valuePartnersFixture().replaceAll(
          'HK0000961927',
          'HK0000945037',
        ),
        symbol: 'HK0000945037',
        currency: 'USD',
      ),
      (
        html:
            '${_valuePartnersFixture().replaceFirst('HK0000945037', 'HK0000000000')}'
            '<h1>其他基金</h1><table class="fund-list-table"><tr><td>Class A USD Unhedged Acc</td><td>USD</td><td>1</td><td>日期</td><td>-</td><td>HK0000945037</td><td>代号</td></tr></table>',
        symbol: 'HK0000945037',
        currency: 'USD',
      ),
    ]) {
      final result =
          await FundSecuritySearchClient(
            transportFactory: () => _htmlTransport(sample.html),
          ).search(
            sample.symbol,
            market: StockMarket.hk,
            currencyCode: sample.currency,
          );
      expect(result, isEmpty);
    }
  });

  test('惠理产品链接、分组标题或表头变化时明确失败，不能按错列回填资料', () async {
    for (final html in [
      _valuePartnersFixture().replaceAll('data-id="vpmm"', 'data-id="unknown"'),
      _valuePartnersFixture().replaceAll(
        '/value-partners-usd-money-market-fund/',
        '/other-fund/',
      ),
      _valuePartnersFixture().replaceFirst(
        '<th>Currency</th>',
        '<th>Unknown</th>',
      ),
    ]) {
      await expectLater(
        FundSecuritySearchClient(
          transportFactory: () => _htmlTransport(html),
        ).search('HK0000945037', market: StockMarket.hk, currencyCode: 'USD'),
        throwsFormatException,
      );
    }
  });

  test('空代码与不支持的市场币种不联网，非法ISIN清楚失败', () async {
    var connections = 0;
    final client = FundSecuritySearchClient(
      transportFactory: () {
        connections++;
        return _htmlTransport(_cmsFixture());
      },
    );
    expect(
      await client.search('', market: StockMarket.hk, currencyCode: 'USD'),
      isEmpty,
    );
    expect(
      await client.search(
        'HK0001039582',
        market: StockMarket.us,
        currencyCode: 'USD',
      ),
      isEmpty,
    );
    expect(
      await client.search(
        'HK0001039582',
        market: StockMarket.hk,
        currencyCode: 'CNY',
      ),
      isEmpty,
    );
    for (final query in [
      '000198',
      '招商美元',
      'HK0001039582\nX',
      'https://example.com',
    ]) {
      await expectLater(
        client.search(query, market: StockMarket.hk, currencyCode: 'USD'),
        throwsFormatException,
      );
    }
    expect(connections, 0);
  });

  test('HTTP拒绝和非资料页不得假装成未找到，失败后释放传输', () async {
    for (final transport in [
      _FundTransport(Stream.value([]), status: 403),
      _htmlTransport('<html>服务暂不可用</html>'),
      _FundTransport(Stream.value([0xff])),
    ]) {
      await expectLater(
        FundSecuritySearchClient(
          transportFactory: () => transport,
        ).search('HK0001039582', market: StockMarket.hk, currencyCode: 'USD'),
        throwsA(anyOf(isA<HttpException>(), isA<FormatException>())),
      );
      expect(transport.closed, isTrue);
    }
  });

  test('分块超限时立即停止后续读取，超时也关闭连接', () async {
    var readAfterLimit = false;

    /// 在超限块之后设置标记，验证客户端不会继续读完整个来源。
    Stream<List<int>> oversized() async* {
      yield List.filled(FundSecuritySearchClient.maximumBytes, 32);
      yield [32];
      readAfterLimit = true;
      yield [32];
    }

    final huge = _FundTransport(oversized());
    await expectLater(
      FundSecuritySearchClient(
        transportFactory: () => huge,
      ).search('HK0001039582', market: StockMarket.hk, currencyCode: 'USD'),
      throwsFormatException,
    );
    expect(readAfterLimit, isFalse);
    expect(huge.closed, isTrue);
    final pending = StreamController<List<int>>();
    final slow = _FundTransport(pending.stream);
    await expectLater(
      FundSecuritySearchClient(
        transportFactory: () => slow,
        requestTimeout: const Duration(milliseconds: 5),
      ).search('HK0001039582', market: StockMarket.hk, currencyCode: 'USD'),
      throwsA(isA<TimeoutException>()),
    );
    expect(slow.closed, isTrue);
    await pending.close();
  });

  test('生产传输拒绝非官方地址及额外参数，允许请求不携带凭证且不跟随跳转', () async {
    final client = _Client();
    final transport = FundSecuritySearchTransport(client: client);
    for (final address in [
      'http://www.cmschina.com.hk/en/AM/FundProduct?view=NPCF',
      'https://www.cmschina.com.hk.evil.example/en/AM/FundProduct?view=NPCF',
      'https://user:password@www.cmschina.com.hk/en/AM/FundProduct?view=NPCF',
      'https://www.cmschina.com.hk:8443/en/AM/FundProduct?view=NPCF',
      'https://www.cmschina.com.hk/en/AM/FundProduct?view=NPCF#fragment',
      'https://www.cmschina.com.hk/en/AM/FundProduct?view=NPCF&account=private',
      'https://www.cmschina.com.hk/en/AM/FundProduct?view=NPCF&view=CMMF',
      'https://www.cmschina.com.hk/en/AM/FundProduct?view=unknown',
      'https://www.valuepartners-group.com/en/products-services/funds/?account=private',
      'https://www.valuepartners-group.com/en/other/',
      'https://www.valuepartners-group.com.evil.example/en/products-services/funds/',
    ]) {
      await expectLater(
        transport.get(Uri.parse(address)),
        throwsFormatException,
      );
    }
    expect(client.urls, isEmpty);
    final uri = Uri.https('www.cmschina.com.hk', '/en/AM/FundProduct', {
      'view': 'NPCF',
    });
    await transport.get(uri);
    expect(client.urls, [uri]);
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
    final valuePartners = Uri.https(
      'www.valuepartners-group.com',
      '/en/products-services/funds/',
    );
    await transport.get(valuePartners);
    expect(client.urls, [uri, valuePartners]);
    transport.close();
    expect(client.forced, isTrue);
  });
}
