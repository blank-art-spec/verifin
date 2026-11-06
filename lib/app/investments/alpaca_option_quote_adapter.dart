/// Alpaca 免费 OPRA 延迟成交行情；凭证只留当前进程，未配置时不发请求。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';
import 'investment_decimal.dart';
import 'market_quote.dart';
import 'us_option_symbol.dart';

/// 未读取的原始响应；适配器累计字节后再解析，避免先完整下载才检查大小。
class AlpacaOptionQuoteResponse {
  const AlpacaOptionQuoteResponse({
    required this.statusCode,
    required this.body,
    this.contentLength = -1,
  });

  final int statusCode, contentLength;
  final Stream<List<int>> body;
}

/// 每批独占的只读传输，只有已经核对的公开合约代码会出现在地址中。
abstract class AlpacaOptionQuoteTransport {
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  });

  /// 正常结束、撤销或超时都关闭连接；实现须允许重复调用。
  void close();
}

typedef AlpacaOptionQuoteTransportFactory =
    AlpacaOptionQuoteTransport Function();

/// 固定官方历史成交地址与有界查询参数，不跟随重定向或向其他主机发送凭证。
class AlpacaHttpOptionQuoteTransport implements AlpacaOptionQuoteTransport {
  /// [client] 仅用于验证 HTTP 配置；生产创建独立且没有历史会话的客户端。
  AlpacaHttpOptionQuoteTransport({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
    _client.findProxy = (_) => 'DIRECT';
  }

  final HttpClient _client;

  /// [uri] 只能包含一个标准合约、明确起止时间、倒序及受控分页参数。
  /// [keyId]/[secretKey] 只写认证头；历史成交接口没有 feed 参数，不能误接 indicative。
  @override
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  }) async {
    if (uri.scheme != 'https' ||
        uri.host != 'data.alpaca.markets' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path != '/v1beta1/options/trades' ||
        !_validHistoryQuery(uri.queryParametersAll) ||
        !_validCredential(keyId) ||
        !_validCredential(secretKey)) {
      throw const FormatException('Alpaca 行情地址、参数或凭证格式不合法');
    }
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set('APCA-API-KEY-ID', keyId);
    request.headers.set('APCA-API-SECRET-KEY', secretKey);
    final response = await request.close();
    return AlpacaOptionQuoteResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength,
      body: response,
    );
  }

  @override
  void close() => _client.close(force: true);
}

/// 同步层可记录的安全错误，不包含请求头、凭证、响应正文或原始网络异常。
class AlpacaOptionQuoteException implements Exception {
  const AlpacaOptionQuoteException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 仅接标准字母根且与用户公开合约资料完全一致的 OCC 身份。
/// 免费历史接口只读十五分钟前的真实 OPRA 成交，不接修改过价格的 indicative。
/// 官方协议与成交条件说明分别见 optiontrades、market-data-faq：
/// https://docs.alpaca.markets/us/reference/optiontrades
/// https://docs.alpaca.markets/us/docs/market-data-faq#how-are-option-bars-aggregated
class AlpacaOptionQuoteAdapter extends MarketQuoteAdapter {
  /// [transportFactory] 注入只读传输以验证边界；[clock] 注入查询截止及抓取时刻。
  AlpacaOptionQuoteAdapter({this.transportFactory, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AlpacaOptionQuoteTransportFactory? transportFactory;
  final DateTime Function() _clock;
  final _active = <AlpacaOptionQuoteTransport>{};
  String _keyId = '', _secretKey = '';
  int _revision = 0;

  static const maximumBytes = 512 * 1024;
  static const maximumSecurities = 20;
  static const requestTimeout = Duration(seconds: 15);
  static const pageSize = 100;
  static const maximumPagesPerSecurity = 3;
  static const minimumDelay = Duration(minutes: 15);
  static const cutoffSafetyMargin = Duration(minutes: 1);

  /// 查询的是滚动的绝对时间窗口，并非“七个本地日历日”；用小时明确其含义。
  /// 一百六十八小时可以覆盖普通周末及短假期，无近期成交时不无界追溯。
  static const historyLookback = Duration(hours: 168);

  bool get configured => _keyId.isNotEmpty && _secretKey.isNotEmpty;

  /// 适配器只持有内存凭证，设备加密保存由 Controller 负责。
  /// 双空明确清除，单项缺失不改变原配置，变化时撤销在途观察。
  void configure({required String keyId, required String secretKey}) {
    final key = keyId.trim(), secret = secretKey.trim();
    if (key.isEmpty != secret.isEmpty ||
        (key.isNotEmpty && !_validCredential(key)) ||
        (secret.isNotEmpty && !_validCredential(secret))) {
      throw const FormatException('Alpaca 凭证格式不合法');
    }
    final clear = key.isEmpty && secret.isEmpty;
    _keyId = clear ? '' : key;
    _secretKey = clear ? '' : secret;
    _revision++;
    for (final transport in _active.toList()) {
      transport.close();
    }
  }

  @override
  QuoteSourceCapability get capability => const QuoteSourceCapability(
    'Alpaca OPRA Delayed',
    approved: false,
    researchOnly: true,
    reviewNote: '使用免费历史成交接口，至少延迟十五分钟；真实凭证与手机联网仍待验证',
  );

  @override
  bool supports(MarketQuoteRequest request) =>
      configured && _contractSymbol(request) != null;

  /// [requests] 每批至多二十个公开合约，各自倒序查询，避免分页偏向第一只合约。
  /// 整批共用十五秒和五百一十二 KiB 预算；任何拒绝均原地失败，不换来源。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) =>
      _fetch(requests, isCurrent: () => true);

  /// [isCurrent] 由同步器表达联网开关、前后台和账本状态，取消后不得发后续请求。
  /// 未携带此回调的直接调用仍通过 [fetch] 保留相同预算和凭证修订保护。
  @override
  Future<List<MarketQuote>> fetchCancellable(
    List<MarketQuoteRequest> requests, {
    required bool Function() isCurrent,
  }) => _fetch(requests, isCurrent: isCurrent);

  /// 统一两种入口的执行生命周期；[isCurrent] 与本地超时、凭证修订共同决定有效性。
  Future<List<MarketQuote>> _fetch(
    List<MarketQuoteRequest> requests, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return const [];
    if (requests.length > maximumSecurities) {
      throw const AlpacaOptionQuoteException('Alpaca 行情单批合约数量超过上限');
    }
    if (!configured) return const [];
    final selected = <String, MarketQuoteRequest>{};
    for (final request in requests) {
      final symbol = _contractSymbol(request);
      if (symbol != null) selected.putIfAbsent(symbol, () => request);
    }
    if (selected.isEmpty) return const [];
    final revision = _revision;
    var active = true;

    /// 超时结束或凭证修改后，旧异步任务不得继续发下一页或下一合约的请求。
    bool current() => active && revision == _revision && isCurrent();

    AlpacaOptionQuoteTransport? transport;
    try {
      final currentTransport =
          transportFactory?.call() ?? AlpacaHttpOptionQuoteTransport();
      transport = currentTransport;
      _active.add(currentTransport);
      final result = await _readBatch(
        currentTransport,
        selected,
        keyId: _keyId,
        secretKey: _secretKey,
        isCurrent: current,
      ).timeout(requestTimeout);
      return current() ? result : const [];
    } on AlpacaOptionQuoteException {
      if (!current()) return const [];
      rethrow;
    } catch (_) {
      // 底层异常可能回显请求或响应；统一安全提示，由同步层记录并显示失败。
      if (!current()) return const [];
      throw const AlpacaOptionQuoteException('Alpaca 行情读取失败或超过十五秒');
    } finally {
      active = false;
      if (transport != null) {
        _active.remove(transport);
        transport.close();
      }
    }
  }

  /// [selected] 是已校对的合约身份；[keyId]/[secretKey] 固定为本批开始时的凭证。
  /// [isCurrent] 在每次等待后检查撤销状态，禁止超时后的任务继续遍历分页。
  /// 返回价格仅是时间窗口内的最近可信成交，不代表实时买卖价或保证成交的价格。
  Future<List<MarketQuote>> _readBatch(
    AlpacaOptionQuoteTransport transport,
    Map<String, MarketQuoteRequest> selected, {
    required String keyId,
    required String secretKey,
    required bool Function() isCurrent,
  }) async {
    final end = _clock().toUtc().subtract(minimumDelay + cutoffSafetyMargin);
    final start = end.subtract(historyLookback);
    var receivedBytes = 0;
    final results = <MarketQuote>[];
    for (final entry in selected.entries) {
      String? token;
      final seenTokens = <String>{};
      DateTime? previousTime;
      for (var page = 0; page < maximumPagesPerSecurity; page++) {
        if (!isCurrent()) return const [];
        final response = await transport.get(
          Uri.https('data.alpaca.markets', '/v1beta1/options/trades', {
            'symbols': entry.key,
            'start': start.toIso8601String(),
            'end': end.toIso8601String(),
            'sort': 'desc',
            'limit': '$pageSize',
            // 空游标省略该参数；有值时由 Uri 统一转义，仍只访问固定地址。
            'page_token': ?token,
          }),
          keyId: keyId,
          secretKey: secretKey,
        );
        if (!isCurrent()) return const [];
        if (response.statusCode != HttpStatus.ok) {
          throw AlpacaOptionQuoteException(
            'Alpaca 行情请求失败：HTTP ${response.statusCode}',
          );
        }
        if (response.contentLength > maximumBytes - receivedBytes) {
          throw const AlpacaOptionQuoteException('Alpaca 行情响应超过大小上限');
        }
        final bytes = <int>[];
        await for (final chunk in response.body) {
          if (!isCurrent()) return const [];
          receivedBytes += chunk.length;
          if (receivedBytes > maximumBytes) {
            throw const AlpacaOptionQuoteException('Alpaca 行情响应超过大小上限');
          }
          bytes.addAll(chunk);
        }
        if (!isCurrent()) return const [];
        final decoded = _decodeNumberText(utf8.decode(bytes));
        if (decoded is! Map<String, Object?> ||
            decoded['trades'] is! Map<String, Object?> ||
            (decoded['currency'] != null && decoded['currency'] != 'USD')) {
          throw const AlpacaOptionQuoteException('Alpaca 行情响应缺少有效的美元成交列表');
        }
        final rows = (decoded['trades']! as Map<String, Object?>)[entry.key];
        if (rows != null && (rows is! List || rows.length > pageSize)) {
          throw const AlpacaOptionQuoteException('Alpaca 行情成交列表格式或数量不合法');
        }
        final fetchedAt = _clock().toUtc();
        MarketQuote? latest;
        for (final raw in rows as List? ?? const []) {
          if (raw is! Map<String, Object?>) continue;
          final time = _sourceTime(raw['t'], fetchedAt);
          if (time == null || time.isBefore(start) || time.isAfter(end)) {
            continue;
          }
          // 单合约倒序是“找到首个有效值即可停止分页”的依据，不能接受乱序响应。
          if (previousTime != null && time.isAfter(previousTime)) {
            throw const AlpacaOptionQuoteException('Alpaca 行情成交时间没有按倒序排列');
          }
          previousTime = time;
          if (latest != null || !_updatesTradePrice(raw['c'])) continue;
          final price = _price(raw['p']);
          final size = raw['s'];
          if (price == null ||
              size is! String ||
              !RegExp(r'^[1-9]\d{0,15}$').hasMatch(size)) {
            continue;
          }
          final quote = MarketQuote(
            securityId: entry.value.securityId,
            source: capability.id,
            currency: 'USD',
            unit: QuotePriceUnit.premiumUnit,
            fetchedAt: fetchedAt,
            last: price,
            lastAt: time,
            delayMinutes: 15,
          );
          if (quote.reference(entry.value, fetchedAt) != null) latest = quote;
        }
        if (latest != null) {
          results.add(latest);
          break;
        }
        final next = decoded['next_page_token'];
        if (next == null || next == '') break;
        if (next is! String ||
            !_validPageToken(next) ||
            !seenTokens.add(next) ||
            page == maximumPagesPerSecurity - 1) {
          throw const AlpacaOptionQuoteException('Alpaca 行情分页无效或超过上限');
        }
        token = next;
      }
    }
    return results;
  }

  /// 不按标的价格、乘数或名称猜合约；调整根、类别股及其他市场等待独立核对。
  static String? _contractSymbol(MarketQuoteRequest request) {
    if (!request.option ||
        request.fund ||
        request.market != StockMarket.us ||
        request.currency != 'USD') {
      return null;
    }
    final identity = parseUsOptionSymbol(request.symbol);
    if (identity == null ||
        identity.underlyingSymbol != request.optionUnderlyingSymbol) {
      return null;
    }
    if (request.optionExpiry != identity.expiry ||
        request.optionRight != identity.right ||
        request.optionStrike == null) {
      return null;
    }
    try {
      final strike = InvestmentDecimal.parse(request.optionStrike!);
      if (strike.units <= BigInt.zero ||
          strike.units != identity.strikeThousandths * BigInt.from(100000)) {
        return null;
      }
    } on FormatException {
      return null;
    }
    return request.symbol;
  }
}

/// [query] 仅允许历史成交端点的六种已核对参数，每个参数最多出现一次。
/// 固定一只合约及倒序分页，查询窗口不超过一百六十八小时，避免全市场或无界下载。
bool _validHistoryQuery(Map<String, List<String>> query) {
  const required = {'symbols', 'start', 'end', 'sort', 'limit'};
  if (!query.keys.toSet().containsAll(required) ||
      query.keys.any((key) => !required.contains(key) && key != 'page_token') ||
      query.values.any((values) => values.length != 1)) {
    return false;
  }
  final symbol = query['symbols']!.single;
  final start = _canonicalRequestTime(query['start']!.single);
  final end = _canonicalRequestTime(query['end']!.single);
  final token = query['page_token']?.single;
  return parseUsOptionSymbol(symbol) != null &&
      query['sort']!.single == 'desc' &&
      query['limit']!.single == '${AlpacaOptionQuoteAdapter.pageSize}' &&
      start != null &&
      end != null &&
      start.isBefore(end) &&
      end.difference(start) <= AlpacaOptionQuoteAdapter.historyLookback &&
      !end.isAfter(
        DateTime.now().toUtc().subtract(AlpacaOptionQuoteAdapter.minimumDelay),
      ) &&
      (token == null || _validPageToken(token));
}

/// [raw] 必须是适配器生成的标准 UTC 文本；回转比较同时拒绝日期溢出和未知时区。
DateTime? _canonicalRequestTime(String raw) {
  final parsed = DateTime.tryParse(raw);
  return parsed != null && parsed.isUtc && parsed.toIso8601String() == raw
      ? parsed
      : null;
}

/// [token] 是官方响应提供的不透明游标；只限制长度和控制字符，不解释或执行其内容。
/// 交给 Uri 编码后仍只发送至固定历史成交地址，不能变成另一主机或额外查询参数。
bool _validPageToken(String token) =>
    token.isNotEmpty &&
    token.length <= 2048 &&
    RegExp(r'^[\x21-\x7e]+$').hasMatch(token);

/// [condition] 使用官方“期权”成交条件表，不复用股票同名字母的另一套含义。
/// 仅接纳可更新分钟收盘价格的已知条件：H/I/J/S、a–s，以及延长交易时段 v。
/// A–G 的取消/迟报/乱序、t/u 的仅数量更新及未知条件不能充当最新有效成交。
bool _updatesTradePrice(Object? condition) =>
    condition is String && RegExp(r'^[HIJSa-sv]$').hasMatch(condition);

/// 只接受可安全作为 HTTP 请求头的非空 ASCII 凭证，不把输入值写进异常。
bool _validCredential(String value) =>
    value.isNotEmpty &&
    value.length <= 512 &&
    RegExp(r'^[\x21-\x7e]+$').hasMatch(value);

/// 报价保留来源十进制文本，不经过 double；超过八位小数或指数写法保守拒绝。
String? _price(Object? raw) {
  if (raw is! String) return null;
  try {
    final value = InvestmentDecimal.parse(raw);
    return value.units < BigInt.zero ? null : raw;
  } on FormatException {
    return null;
  }
}

/// 只认带时区的 RFC3339 来源时刻；拒绝日期溢出、缺失时区及明显未来时间。
DateTime? _sourceTime(Object? raw, DateTime fetchedAt) {
  if (raw is! String) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(raw);
  if (match == null) return null;
  final values = [for (var i = 1; i <= 6; i++) int.parse(match[i]!)];
  final day = DateTime.utc(values[0], values[1], values[2]);
  if (day.year != values[0] ||
      day.month != values[1] ||
      day.day != values[2] ||
      values[3] > 23 ||
      values[4] > 59 ||
      values[5] > 59) {
    return null;
  }
  final zone = match[7]!;
  if (zone != 'Z' &&
      (int.parse(zone.substring(1, 3)) > 23 ||
          int.parse(zone.substring(4, 6)) > 59)) {
    return null;
  }
  final value = DateTime.tryParse(raw)?.toUtc();
  return value == null ||
          value.isAfter(fetchedAt.add(const Duration(minutes: 5)))
      ? null
      : value;
}

/// 有界响应中的 JSON 数字先保存为原文本，再用标准解析器校验结构。
/// 字符串及反斜杠转义原样保留，不执行响应，也不让 JSON double 舍入价格。
Object? _decodeNumberText(String text) {
  // 只做原始 JSON 语法验证，丢弃其数值结果；价格只来自后续原文本解析。
  // 因此非法的数字对象键不会在加引号后被意外接纳。
  final original = jsonDecode(text);
  final output = StringBuffer();
  final number = RegExp(r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?');
  var cursor = 0;
  while (cursor < text.length) {
    final start = cursor;
    if (text.codeUnitAt(cursor) == 34) {
      cursor++;
      while (cursor < text.length) {
        final code = text.codeUnitAt(cursor++);
        if (code == 92 && cursor < text.length) {
          cursor++;
        } else if (code == 34) {
          break;
        }
      }
      output.write(text.substring(start, cursor));
    } else {
      final match = number.matchAsPrefix(text, cursor);
      if (match != null) {
        output.write(jsonEncode(match[0]));
        cursor = match.end;
      } else {
        output.write(text[cursor++]);
      }
    }
  }
  final decoded = jsonDecode(output.toString());
  // 只有量价需要保留数字原文；分页游标保持原始类型，防止数字被误认成合法字符串。
  if (original is Map<String, Object?> && decoded is Map<String, Object?>) {
    decoded['next_page_token'] = original['next_page_token'];
  }
  return decoded;
}
