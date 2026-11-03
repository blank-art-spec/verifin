/// 仅检索公开证券身份，不获取价格、持仓或账户资料，也不改变参考行情来源准入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';

/// 一次身份搜索的响应；保留原始流，调用方可在超限时立即停止读取。
class SecuritySearchResponse {
  /// [statusCode] 是原始 HTTP 状态，[body] 不能预先完整下载后才检查大小。
  const SecuritySearchResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Stream<List<int>> body;
}

/// 单次搜索独占的连接；测试实现可返回固定公开夹具，不访问真实网络。
abstract interface class SecuritySearchTransport {
  /// 只请求经过白名单检查的 [uri]；不得跟随跳转或携带用户凭证。
  Future<SecuritySearchResponse> get(Uri uri);

  /// 关闭正在连接或读取的请求；调用方会在完成、失败及超时后调用，可重复执行。
  void close();
}

/// 每次主动搜索创建一份独立传输，避免不同查询共享 Cookie 或连接状态。
typedef SecuritySearchTransportFactory = SecuritySearchTransport Function();

/// 固定访问腾讯公开证券身份搜索，不发送账户、账本、数量、成本或备注。
class TencentSecuritySearchTransport implements SecuritySearchTransport {
  /// [client] 仅供测试注入；生产创建没有历史凭证的客户端，连接上限为八秒。
  TencentSecuritySearchTransport({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
  }

  final HttpClient _client;

  /// 核对 HTTPS、主机、路径和两个固定查询键后请求 [uri]；禁止重定向及认证头。
  /// 搜索词通过 Uri 编码，作为普通数据传输，不拼接到可执行脚本或其他地址中。
  @override
  Future<SecuritySearchResponse> get(Uri uri) async {
    final query = uri.queryParameters['q'];
    if (uri.scheme != 'https' ||
        uri.host != 'smartbox.gtimg.cn' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.path != '/s3/' ||
        uri.hasFragment ||
        uri.queryParametersAll.length != 2 ||
        uri.queryParametersAll.values.any((values) => values.length != 1) ||
        uri.queryParameters['t'] != 'all' ||
        query == null ||
        !_validQuery(query)) {
      throw const FormatException('证券搜索地址或参数不在允许范围');
    }
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.set(HttpHeaders.acceptHeader, 'text/plain');
    request.headers.set(HttpHeaders.userAgentHeader, 'VeriFin security-search');
    final response = await request.close();
    return SecuritySearchResponse(
      statusCode: response.statusCode,
      body: response,
    );
  }

  /// 强制关闭本次连接，超时后不继续下载，也不自动重试被拒绝的请求。
  @override
  void close() => _client.close(force: true);
}

/// 判断 [query] 是否是有界非空搜索文字；允许中文名称和代码中的点、短横线。
/// 控制字符和超长输入不发送，用户输入不会写入日志或本地缓存。
bool _validQuery(String query) =>
    query.trim().isNotEmpty &&
    query.length <= SecuritySearchClient.maximumQueryLength &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(query);

/// 用户主动触发的证券身份检索；构造及输入变化本身均不联网。
class SecuritySearchClient {
  /// [transportFactory] 注入单次传输；[requestTimeout] 覆盖连接和流读取的总时限，
  /// 只允许缩短默认十秒，不能放宽生产网络上限。客户端不持有 Controller 或账户。
  SecuritySearchClient({
    this.transportFactory,
    this.requestTimeout = const Duration(seconds: 10),
  }) {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 10)) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout', '搜索时限须在十秒以内');
    }
  }

  final SecuritySearchTransportFactory? transportFactory;
  final Duration requestTimeout;

  static const maximumQueryLength = 64;
  static const maximumBytes = 64 * 1024;
  static const maximumResults = 20;

  /// 搜索 [query] 的公开身份，按 [market] 和实际结算 [currencyCode] 筛选结果。
  /// 仅支持 USD 美股、HKD 港股及 CNY 沪深 A 股；不推断基金、期权或人民币港股。
  /// 空词或不支持的市场币种组合返回空列表且不创建连接；非法长词抛出格式错误。
  /// 返回候选不包含价格或交易事实，必须由用户选择核对，调用方负责显示失败反馈。
  /// 来源 GP 类别可能包括 ETF、单位或认股权证，不能视为普通股品种认证；
  /// 本接口仅补全身份，不提供基金净值、期权条款或当前挂牌状态保证。
  Future<List<StockSecurity>> search(
    String query, {
    required StockMarket market,
    required String currencyCode,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty || !_supportsCurrency(market, currencyCode)) {
      return const [];
    }
    if (!_validQuery(normalized)) {
      throw const FormatException('证券搜索词为空、过长或包含控制字符');
    }
    final uri = Uri.https('smartbox.gtimg.cn', '/s3/', {
      'q': normalized,
      't': 'all',
    });
    final transport =
        transportFactory?.call() ?? TencentSecuritySearchTransport();
    try {
      return await _read(transport, uri, market, currencyCode).timeout(
        requestTimeout,
        onTimeout: () {
          transport.close();
          throw TimeoutException('证券搜索超时');
        },
      );
    } finally {
      transport.close();
    }
  }

  /// 流式读取 [transport] 对 [uri] 的响应，累计超过 64 KiB 立即拒绝。
  /// [market]、[currencyCode] 仅用于本地结果筛选，不发送账务上下文到服务端。
  Future<List<StockSecurity>> _read(
    SecuritySearchTransport transport,
    Uri uri,
    StockMarket market,
    String currencyCode,
  ) async {
    final response = await transport.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('证券搜索请求失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.body) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const FormatException('证券搜索响应超过六十四 KiB 上限');
      }
      bytes.addAll(chunk);
    }
    return _parse(utf8.decode(bytes), market, currencyCode);
  }

  /// 只解析 [text] 的 v_hint 字符串赋值，绝不执行响应中的 JavaScript。
  /// 来源以转义 Unicode 表示中文，交给 JSON 字符串解码；拒绝额外语句及非法格式。
  /// 同一稳定身份仅返回一次，未知类别标记或字段不完整的行不会成为候选。
  static List<StockSecurity> _parse(
    String text,
    StockMarket market,
    String currencyCode,
  ) {
    final match = RegExp(
      r'^v_hint\s*=\s*("(?:[^"\\\r\n]|\\.)*")\s*;?$',
    ).firstMatch(text.trim());
    if (match == null) throw const FormatException('证券搜索响应格式无效');
    final payload = jsonDecode(match[1]!) as String;
    if (payload.isEmpty || payload == 'N') return const [];
    final securities = <String, StockSecurity>{};
    for (final row in payload.split('^')) {
      final fields = row.split('~');
      if (fields.length != 5 ||
          fields[2].trim().isEmpty ||
          fields[2].length > 160 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(fields[2])) {
        continue;
      }
      final symbol = _symbol(fields, market);
      if (symbol == null) continue;
      final security = StockSecurity(
        symbol: symbol,
        name: fields[2].trim(),
        market: market,
        currencyCode: currencyCode,
      );
      securities.putIfAbsent(security.id, () => security);
      if (securities.length >= maximumResults) break;
    }
    return List.unmodifiable(securities.values);
  }

  /// 核对 [fields] 的来源市场、类别标记及原代码，返回 [market] 的稳定身份代码。
  /// 港股保留五位前导零；美股只去掉已核对的交易所后缀，保留 BRK.B 等类别点号。
  /// 沪深只接 GP-A 系列，香港排除人民币柜台；拒绝明确标为 KJ/ZS/QZ 的行。
  /// GP 是上游的宽泛类别，不能据此承诺所有候选都是普通股，也不按名称猜品种。
  static String? _symbol(List<String> fields, StockMarket market) {
    final exchange = fields[0], raw = fields[1], kind = fields[4];
    switch (market) {
      case StockMarket.cn:
        if (!RegExp(r'^GP-A(?:-[A-Z]+)*$').hasMatch(kind)) return null;
        if (exchange == 'sh' && RegExp(r'^6\d{5}$').hasMatch(raw)) return raw;
        if (exchange == 'sz' && RegExp(r'^[03]\d{5}$').hasMatch(raw)) {
          return raw;
        }
        return null;
      case StockMarket.hk:
        if (exchange == 'hk' &&
            kind == 'GP' &&
            RegExp(r'^0\d{4}$').hasMatch(raw)) {
          return raw;
        }
        return null;
      case StockMarket.us:
        if (exchange != 'us' || kind != 'GP') return null;
        final identity = RegExp(
          r'^([a-zA-Z][a-zA-Z0-9.-]{0,19})\.(?:oq|n|am|ps)$',
          caseSensitive: false,
        ).firstMatch(raw);
        return identity?[1]?.toUpperCase();
    }
  }

  /// 检查 [market] 与 [currencyCode] 是否是已核对的查询组合，不猜测证券币种。
  static bool _supportsCurrency(StockMarket market, String currencyCode) =>
      switch (market) {
        StockMarket.us => currencyCode == 'USD',
        StockMarket.cn => currencyCode == 'CNY',
        StockMarket.hk => currencyCode == 'HKD',
      };
}
