/// Alpaca 官方 OPRA 期权行情；凭证只留当前进程，未配置时不发请求。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';
import '../models/option_contract.dart';
import 'investment_decimal.dart';
import 'market_quote.dart';

const _occPattern = r'([A-Z]{1,6})(\d{6})([CP])(\d{8})';

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

/// 固定官方域名与 OPRA 参数，不跟随重定向或向其他主机发送凭证。
class AlpacaHttpOptionQuoteTransport implements AlpacaOptionQuoteTransport {
  /// [client] 仅用于验证 HTTP 配置；生产创建独立且没有历史会话的客户端。
  AlpacaHttpOptionQuoteTransport({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
    _client.findProxy = (_) => 'DIRECT';
  }

  final HttpClient _client;

  @override
  Future<AlpacaOptionQuoteResponse> get(
    Uri uri, {
    required String keyId,
    required String secretKey,
  }) async {
    final query = uri.queryParametersAll;
    final symbols = query['symbols'];
    if (uri.scheme != 'https' ||
        uri.host != 'data.alpaca.markets' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.path != '/v1beta1/options/snapshots' ||
        query.length != 2 ||
        query['feed']?.length != 1 ||
        query['feed']?.single != 'opra' ||
        symbols == null ||
        symbols.length != 1 ||
        !RegExp(
          '^$_occPattern(?:,$_occPattern){0,19}\$',
        ).hasMatch(symbols.single) ||
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
/// 官方 snapshots 文档要求明确 feed=opra；不降级为修改过价格的 indicative。
class AlpacaOptionQuoteAdapter extends MarketQuoteAdapter {
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
    'Alpaca OPRA',
    approved: false,
    researchOnly: true,
    reviewNote: '需要用户配置具备 OPRA 行情权限的凭证；未取得真实凭证联网验证',
  );

  @override
  bool supports(MarketQuoteRequest request) =>
      configured && _contractSymbol(request) != null;

  /// 每批二十个公开合约；任何拒绝均原地失败，不重试、不更换来源或 feed。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
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
    AlpacaOptionQuoteTransport? transport;
    try {
      final current =
          transportFactory?.call() ?? AlpacaHttpOptionQuoteTransport();
      transport = current;
      _active.add(current);
      final result = await _readBatch(
        current,
        selected,
      ).timeout(requestTimeout);
      return revision == _revision ? result : const [];
    } on AlpacaOptionQuoteException {
      if (revision != _revision) return const [];
      rethrow;
    } catch (_) {
      // 底层异常可能回显请求或响应；统一安全提示，由同步层记录并显示失败。
      if (revision != _revision) return const [];
      throw const AlpacaOptionQuoteException('Alpaca 行情读取失败或超过十五秒');
    } finally {
      if (transport != null) {
        _active.remove(transport);
        transport.close();
      }
    }
  }

  Future<List<MarketQuote>> _readBatch(
    AlpacaOptionQuoteTransport transport,
    Map<String, MarketQuoteRequest> selected,
  ) async {
    final response = await transport.get(
      Uri.https('data.alpaca.markets', '/v1beta1/options/snapshots', {
        'symbols': selected.keys.join(','),
        'feed': 'opra',
      }),
      keyId: _keyId,
      secretKey: _secretKey,
    );
    if (response.statusCode != HttpStatus.ok) {
      throw AlpacaOptionQuoteException(
        'Alpaca 行情请求失败：HTTP ${response.statusCode}',
      );
    }
    if (response.contentLength > maximumBytes) {
      throw const AlpacaOptionQuoteException('Alpaca 行情响应超过大小上限');
    }
    final bytes = <int>[];
    await for (final chunk in response.body) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const AlpacaOptionQuoteException('Alpaca 行情响应超过大小上限');
      }
      bytes.addAll(chunk);
    }
    final decoded = _decodeNumberText(utf8.decode(bytes));
    if (decoded is! Map<String, Object?> ||
        decoded['snapshots'] is! Map<String, Object?>) {
      throw const AlpacaOptionQuoteException('Alpaca 行情响应缺少合约快照');
    }
    if (decoded['next_page_token'] != null &&
        decoded['next_page_token'] != '') {
      // 二十个请求小于官方默认一百条上限；异常分页不能被误报为完整刷新。
      throw const AlpacaOptionQuoteException('Alpaca 行情响应仍有分页，未采用不完整快照');
    }
    final snapshots = decoded['snapshots']! as Map<String, Object?>;
    final fetchedAt = _clock().toUtc();
    final results = <MarketQuote>[];
    for (final entry in selected.entries) {
      final snapshot = snapshots[entry.key];
      if (snapshot is! Map<String, Object?>) continue;
      final bidAsk = snapshot['latestQuote'], trade = snapshot['latestTrade'];
      final quoteFields = bidAsk is Map<String, Object?>
          ? bidAsk
          : const <String, Object?>{};
      final tradeFields = trade is Map<String, Object?>
          ? trade
          : const <String, Object?>{};
      final quotedAt = _sourceTime(quoteFields['t'], fetchedAt);
      final quote = MarketQuote(
        securityId: entry.value.securityId,
        source: capability.id,
        currency: 'USD',
        unit: QuotePriceUnit.premiumUnit,
        fetchedAt: fetchedAt,
        bid: _price(quoteFields['bp']),
        ask: _price(quoteFields['ap']),
        last: _price(tradeFields['p']),
        bidAt: quotedAt,
        askAt: quotedAt,
        lastAt: _sourceTime(tradeFields['t'], fetchedAt),
      );
      if (quote.reference(entry.value, fetchedAt) != null) results.add(quote);
    }
    return results;
  }

  /// 不按标的价格、乘数或名称猜合约；调整根、类别股及其他市场等待独立核对。
  static String? _contractSymbol(MarketQuoteRequest request) {
    if (!request.option ||
        request.fund ||
        request.market != StockMarket.us ||
        request.currency != 'USD' ||
        request.symbol.startsWith('TEST')) {
      return null;
    }
    final match = RegExp('^$_occPattern\$').firstMatch(request.symbol);
    if (match == null || match[1] != request.optionUnderlyingSymbol) {
      return null;
    }
    final date = match[2]!;
    final year = 2000 + int.parse(date.substring(0, 2));
    final month = int.parse(date.substring(2, 4)),
        day = int.parse(date.substring(4, 6));
    final expiry = DateTime.utc(year, month, day);
    if (expiry.year != year ||
        expiry.month != month ||
        expiry.day != day ||
        request.optionExpiry !=
            '$year-${date.substring(2, 4)}-${date.substring(4, 6)}' ||
        request.optionRight !=
            (match[3] == 'C' ? OptionRight.call : OptionRight.put) ||
        request.optionStrike == null) {
      return null;
    }
    try {
      final strike = InvestmentDecimal.parse(request.optionStrike!);
      if (strike.units <= BigInt.zero ||
          strike.units != BigInt.parse(match[4]!) * BigInt.from(100000)) {
        return null;
      }
    } on FormatException {
      return null;
    }
    return request.symbol;
  }
}

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
  jsonDecode(text);
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
  return jsonDecode(output.toString());
}
