/// Nasdaq 公开期权详情；仅查询公开合约，不使用账号、密钥或浏览器登录态。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';
import '../models/option_contract.dart';
import 'investment_decimal.dart';
import 'market_quote.dart';
import 'us_option_symbol.dart';

/// 保留流式响应，以便在下载期间执行整批大小限制。
class NasdaqOptionQuoteResponse {
  const NasdaqOptionQuoteResponse({
    required this.statusCode,
    required this.body,
    this.contentLength = -1,
    this.retryAfter,
  });

  final int statusCode, contentLength;
  final Stream<List<int>> body;
  final String? retryAfter;
}

/// 每批独立连接；构造及配置不发请求。
abstract class NasdaqOptionQuoteTransport {
  Future<NasdaqOptionQuoteResponse> get(Uri uri);
  void close();
}

typedef NasdaqOptionQuoteTransportFactory =
    NasdaqOptionQuoteTransport Function();

/// 固定官方 HTTPS 详情入口，不携带 Cookie/认证头，不跟随跳转。
class NasdaqHttpOptionQuoteTransport implements NasdaqOptionQuoteTransport {
  NasdaqHttpOptionQuoteTransport({
    HttpClient? client,
    Duration connectionTimeout = const Duration(seconds: 10),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = connectionTimeout;
    _client.maxConnectionsPerHost = 3;
  }

  final HttpClient _client;

  /// 请求 [uri] 指定的公开合约详情，只接受固定 Nasdaq 主机与路径。
  /// 资产类别限定为 stocks 或 etf；两者共享相同合约参数，不能借此请求任意接口。
  /// recordID 的根代码段固定占六位，不足部分用连字符补齐，后接到期日、C 和行权价。
  /// 返回流式正文供上层累计大小，不携带认证信息，也不自动跟随重定向。
  @override
  Future<NasdaqOptionQuoteResponse> get(Uri uri) async {
    final query = uri.queryParametersAll;
    // 先取单值时避免 .single 对重复参数抛出无关异常；下方仍统一拒绝重复参数。
    final recordIds = query['recordID'];
    final recordId = recordIds != null && recordIds.length == 1
        ? recordIds.single
        : '';
    if (uri.scheme != 'https' ||
        uri.host != 'api.nasdaq.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !RegExp(
          r'^/api/quote/[a-z][a-z0-9.]{0,9}/option-chain$',
        ).hasMatch(uri.path) ||
        query.length != 2 ||
        query.values.any((values) => values.length != 1) ||
        !const ['stocks', 'etf'].contains(query['assetclass']?.single) ||
        recordId.length != 21 ||
        !RegExp(r'^[A-Z][A-Z0-9.]{0,5}-{0,5}\d{6}C\d{8}$').hasMatch(recordId)) {
      throw const FormatException('Nasdaq 行情地址不在允许范围');
    }
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'VeriFin/1.19.9 public-data-evaluation',
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    return NasdaqOptionQuoteResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength,
      body: response,
      retryAfter: const [401, 403, 429].contains(response.statusCode)
          ? response.headers.value(HttpHeaders.retryAfterHeader)
          : null,
    );
  }

  @override
  void close() => _client.close(force: true);
}

/// 全部身份一致的美元美股期权可尝试查询；没有个别标的或持仓数量白名单。
/// 返回最近成交价观察，源字段时间未知，不把页面 timeStamp 当成交时间。
class NasdaqOptionQuoteAdapter extends MarketQuoteAdapter {
  NasdaqOptionQuoteAdapter({
    this.transportFactory,
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 15)) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
  }

  static const sourceId = 'Nasdaq Options';
  static const maximumBytes = 512 * 1024;
  static const maximumSecurities = 20;
  final NasdaqOptionQuoteTransportFactory? transportFactory;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  DateTime? _blockedUntil;

  /// 拒绝/限流后暂停该来源，覆盖同一轮后续批次及其他账户，避免换批继续请求。
  bool get _blocked =>
      _blockedUntil != null && _clock().isBefore(_blockedUntil!);

  @override
  QuoteSourceCapability get capability => const QuoteSourceCapability(
    sourceId,
    approved: false,
    researchOnly: true,
    reviewNote: '匿名公开期权详情；成交时间未知，接口可用性不代表供应方使用许可',
  );

  @override
  bool get retainQuotesOnFailure => false;

  @override
  bool supports(MarketQuoteRequest request) => _identity(request) != null;

  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) =>
      fetchCancellable(requests, isCurrent: () => true);

  /// Call/Put 共用一次详情请求，最多三个在途请求；整批共用时间与字节预算。
  /// [requests] 只包含待查公开合约身份；[isCurrent] 表示本轮会话仍允许联网及采用结果。
  /// 合约根按 Nasdaq 详情链接补到六位，不能为所有根固定追加两个连字符。
  /// stocks 成功但明确返回 data=null 时，仅改资产类别补查一次 etf，不保存类别推断。
  /// 两次请求仍共享整批预算；单合约失败保留其他成功结果，拒绝或限流停止后续请求。
  @override
  Future<List<MarketQuote>> fetchCancellable(
    List<MarketQuoteRequest> requests, {
    required bool Function() isCurrent,
  }) async {
    if (requests.length > maximumSecurities) {
      throw const FormatException('Nasdaq 行情单批合约数量超过上限');
    }
    final grouped = <Uri, List<MarketQuoteRequest>>{};
    final seen = <String>{};
    for (final request in requests) {
      if (!seen.add(request.securityId)) continue;
      final identity = _identity(request);
      if (identity == null) continue;
      final uri = Uri.https(
        'api.nasdaq.com',
        '/api/quote/${identity.underlying.toLowerCase()}/option-chain',
        {
          'assetclass': 'stocks',
          'recordID':
              '${identity.root.padRight(6, '-')}${identity.date}C${identity.strike}',
        },
      );
      grouped.putIfAbsent(uri, () => []).add(request);
    }
    if (grouped.isEmpty || !isCurrent() || _blocked) return const [];
    final transport =
        transportFactory?.call() ?? NasdaqHttpOptionQuoteTransport();
    final work = grouped.entries.toList();
    final results = <MarketQuote>[];
    var next = 0, received = 0;
    var stopped = false;

    /// 同时核对本批停止标记、来源暂停和调用方会话，所有首次与补查请求均受此门禁。
    bool current() => !stopped && !_blocked && isCurrent();

    /// 获取 [uri] 的完整 JSON 对象；首次 stocks 与补查 etf 共用连接和累计字节预算。
    /// HTTP 失败、取消、拒绝或超限返回 null；格式异常交由所属合约的 worker 降级。
    /// 此处不判断资产类别，只有上层确认的正常空数据响应才能触发一次 etf 补查。
    Future<Map?> loadResponse(Uri uri) async {
      if (!current()) return null;
      final response = await transport.get(uri);
      if (!current()) {
        await response.body.listen(null).cancel();
        return null;
      }
      if (const [401, 403, 429].contains(response.statusCode)) {
        final now = _clock();
        var until = now.add(const Duration(minutes: 5));
        final retry = response.retryAfter?.trim();
        if (retry != null) {
          try {
            final requested = RegExp(r'^\d{1,9}$').hasMatch(retry)
                ? now.add(Duration(seconds: int.parse(retry)))
                : HttpDate.parse(retry);
            if (requested.isAfter(until)) until = requested;
          } on FormatException {
            // 不合法等待字段使用保守的五分钟等待，不立即重试来源拒绝。
          }
        }
        _blockedUntil = until;
        stopped = true;
        await response.body.listen(null).cancel();
        return null;
      }
      if (response.statusCode != 200) {
        await response.body.listen(null).cancel();
        return null;
      }
      if (response.contentLength > maximumBytes - received) {
        stopped = true;
        await response.body.listen(null).cancel();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.body) {
        if (!current()) return null;
        received += chunk.length;
        if (received > maximumBytes) {
          stopped = true;
          return null;
        }
        bytes.addAll(chunk);
      }
      if (!current()) return null;
      final json = jsonDecode(utf8.decode(bytes));
      return json is Map ? json : null;
    }

    /// 顺序处理分配给当前工作协程的合约组，同一组 Call/Put 共用首次及补查响应。
    /// etf 补查在当前协程内等待，不另增并发，也不重置外层整批超时和字节计数。
    Future<void> worker() async {
      while (current() && next < work.length) {
        final item = work[next++];
        try {
          var json = await loadResponse(item.key);
          if (json == null || !current()) continue;
          final stockStatus = json['status'];
          // 仅将来源成功且明确为空视为类别可能不符；缺字段、业务错误、已有详情但
          // 缺价或合约不匹配均不补查，避免把普通失败扩大成重复请求。
          if (stockStatus is Map &&
              stockStatus['rCode'] == 200 &&
              json.containsKey('data') &&
              json['data'] == null) {
            json = await loadResponse(
              item.key.replace(
                queryParameters: {
                  ...item.key.queryParameters,
                  'assetclass': 'etf',
                },
              ),
            );
            if (json == null || !current()) continue;
          }
          final status = json['status'];
          if (status is! Map ||
              status['rCode'] != 200 ||
              json['data'] is! Map) {
            continue;
          }
          final data = json['data'] as Map;
          final fetchedAt = _clock().toUtc();
          for (final request in item.value) {
            final quote = _quote(data, request, fetchedAt);
            if (quote != null) results.add(quote);
          }
        } catch (_) {
          // 单合约网络/格式失败按缺价降级；同步层反馈并保留手填，不记录响应或隐私。
        }
      }
    }

    try {
      await Future.wait(
        List.generate(work.length.clamp(1, 3), (_) => worker()),
      ).timeout(requestTimeout);
    } on TimeoutException {
      // 已完成的有效报价可以采用，余下合约回到手填；关闭连接阻止迟到结果。
    } finally {
      stopped = true;
      transport.close();
    }
    return isCurrent() ? List.unmodifiable(results) : const [];
  }

  /// 标题中的完整合约必须精确匹配；页面时间、标的时间与抓取时刻均非成交时间。
  static MarketQuote? _quote(
    Map data,
    MarketQuoteRequest request,
    DateTime fetchedAt,
  ) {
    final call = request.optionRight == OptionRight.call;
    final side = data[call ? 'optionChainCallData' : 'optionChainPutData'];
    if (side is! Map || side['header'] is! String) return null;
    final header = (side['header'] as String).replaceAll(
      RegExp(r'<[^>]*>'),
      ' ',
    );
    final match = RegExp(
      r'^(Call|Put)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(header.trim());
    if (match == null ||
        match[1]!.toLowerCase() != (call ? 'call' : 'put') ||
        match[2]!.replaceAll(RegExp(r'\s+'), '').toUpperCase() !=
            request.symbol.toUpperCase()) {
      return null;
    }
    final fields = side['optionChainListData'];
    if (fields is! Map || fields['LastSale'] is! Map) return null;
    final lastSale = fields['LastSale'] as Map;
    final raw = lastSale['value'];
    if (raw is! String ||
        !RegExp(
          r'^(?:\d{1,12}|\d{1,3}(?:,\d{3}){1,3})(?:\.\d{1,8})?$',
        ).hasMatch(raw)) {
      return null;
    }
    final price = raw.replaceAll(',', '');
    if (InvestmentDecimal.parse(price).units <= BigInt.zero) return null;
    return MarketQuote(
      securityId: request.securityId,
      source: sourceId,
      currency: 'USD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: fetchedAt,
      last: price,
      sourceTimeUnknown: true,
    );
  }
}

/// 只验证公开身份一致性，不据代码推断挂牌、乘数或交割条款。
/// 数字调整根可以查询，但真实标的来自已有配置，不能把调整根冒充普通股。
/// [request] 须给出美元美股期权的完整代码及已确认标的；返回根、真实标的、日期与行权价。
/// Nasdaq 根字段最多六位；已明确的 .A/.B 类别股可使用去点后的合约根，标的路径仍保留点。
/// 不从 BRKB 等裸根反推 BRK.B，也不改写已保存的证券代码或合约身份。
({String root, String underlying, String date, String strike})? _identity(
  MarketQuoteRequest request,
) {
  if (!request.option ||
      request.fund ||
      request.market != StockMarket.us ||
      request.currency != 'USD' ||
      request.symbol.toUpperCase().startsWith('TEST')) {
    return null;
  }
  final match = RegExp(
    r'^([A-Z][A-Z0-9.]{0,5})(\d{6})([CP])(\d{8})$',
  ).firstMatch(request.symbol.toUpperCase());
  final underlying = request.optionUnderlyingSymbol;
  if (match == null || underlying == null) {
    return null;
  }
  // 与草稿请求共用普通根及明确类别股的校验，避免页面和刷新适配器采用不同身份。
  // 已保存的数字调整根继续使用用户确认的标的关系，完整响应合约仍须精确匹配。
  if (!matchesUsOptionUnderlying(
    match[1]!,
    underlying,
    allowAdjustedRoot: true,
  )) {
    return null;
  }
  final date = match[2]!;
  final year = 2000 + int.parse(date.substring(0, 2));
  final month = int.parse(date.substring(2, 4)),
      day = int.parse(date.substring(4));
  final expiry = DateTime.utc(year, month, day);
  if (expiry.year != year ||
      expiry.month != month ||
      expiry.day != day ||
      request.optionExpiry !=
          '$year-${date.substring(2, 4)}-${date.substring(4)}' ||
      request.optionRight !=
          (match[3] == 'C' ? OptionRight.call : OptionRight.put) ||
      request.optionStrike == null) {
    return null;
  }
  try {
    final strike = BigInt.parse(match[4]!);
    if (strike <= BigInt.zero ||
        InvestmentDecimal.parse(request.optionStrike!).units !=
            strike * BigInt.from(100000)) {
      return null;
    }
  } on FormatException {
    return null;
  }
  return (
    root: match[1]!,
    underlying: underlying,
    date: date,
    strike: match[4]!,
  );
}
