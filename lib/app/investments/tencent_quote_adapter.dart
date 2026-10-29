/// 腾讯公开股票报价的诊断适配器；未通过发布使用条件核对，不自动用于正式渠道。
library;

import 'dart:async';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/investment.dart';
import '../timezone_database.dart';
import 'investment_decimal.dart';
import 'market_quote.dart';

/// 一次腾讯 HTTP 响应；[body] 保持字节流，读取方可在超限时立即停止。
class TencentQuoteResponse {
  /// [statusCode] 是原始 HTTP 状态；[body] 尚未完整读取，不能预先把大响应放入内存。
  const TencentQuoteResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Stream<List<int>> body;
}

/// 单批请求持有的传输连接；每次 fetch 独立创建，超时或结束后必须关闭。
abstract class TencentQuoteTransport {
  /// 对固定腾讯地址发起请求；[uri] 只包含经过校验的公开证券代码。
  Future<TencentQuoteResponse> get(Uri uri);

  /// 立即终止当前连接及尚未读完的响应；无返回值，允许重复调用。
  void close();
}

/// 创建一次批量请求独占的传输；测试可注入字节流，不需要访问真实网络。
typedef TencentQuoteTransportFactory = TencentQuoteTransport Function();

/// 生产 HTTP 传输只访问 qt.gtimg.cn；调用方负责在整批超时与 finally 中关闭。
class TencentHttpQuoteTransport implements TencentQuoteTransport {
  /// [client] 仅供测试核对请求参数；生产留空创建无历史 Cookie 的独立客户端。
  /// [connectionTimeout] 是连接阶段上限；整批十五秒上限由适配器统一管理。
  TencentHttpQuoteTransport({
    HttpClient? client,
    Duration connectionTimeout = const Duration(seconds: 10),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = connectionTimeout;
  }

  final HttpClient _client;

  /// 检查 HTTPS 主机、端口及有界股票路径后请求，不跟随重定向，也不携带凭证。
  /// [uri] 格式为 https://qt.gtimg.cn/q=sh600026,hk00700，拒绝其他主机或查询参数。
  @override
  Future<TencentQuoteResponse> get(Uri uri) async {
    final validPath = RegExp(
      r'^/q=(?:(?:sh|sz)\d{6}|hk\d{5}|us(?:AVGO|GOOG))(?:,(?:(?:sh|sz)\d{6}|hk\d{5}|us(?:AVGO|GOOG))){0,19}$',
    );
    if (uri.scheme != 'https' ||
        uri.host != 'qt.gtimg.cn' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !validPath.hasMatch(uri.path)) {
      throw const FormatException('腾讯行情地址不在允许范围');
    }
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'VeriFin public-stock-research',
    );
    request.headers.set(HttpHeaders.acceptHeader, 'text/plain');
    final response = await request.close();
    return TencentQuoteResponse(
      statusCode: response.statusCode,
      body: response,
    );
  }

  /// 强制关闭本批客户端，取消等待中的连接与响应流，避免超时后继续下载。
  @override
  void close() => _client.close(force: true);
}

/// 仅供明确启用的独立诊断包测试真实股票，期权及本地 TEST 代码始终不受支持。
class TencentQuoteAdapter extends MarketQuoteAdapter {
  /// [transportFactory] 为每批创建独立连接；[clock] 提供实际抓取时刻，测试可固定。
  /// [requestTimeout] 用于较短的故障测试，生产默认十五秒，不能放宽此网络上限。
  TencentQuoteAdapter({
    this.transportFactory,
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 15)) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        '请求时限须在十五秒以内',
      );
    }
  }

  final TencentQuoteTransportFactory? transportFactory;
  final DateTime Function() _clock;
  final Duration requestTimeout;

  static const maximumBytes = 512 * 1024;
  static const maximumSecurities = 20;

  /// 明确保留研究状态；只有诊断渠道和显式研究构建参数组合允许客户端选用。
  @override
  QuoteSourceCapability get capability => const QuoteSourceCapability(
    'Tencent Finance',
    approved: false,
    researchOnly: true,
    reviewNote: '公开股票来源仅供诊断验证，发布使用条件待核对',
  );

  /// 核对实际股票身份及原币；沪市 6、深市 0/3 开头，港股只接港元普通代码。
  /// 美股首批只支持已核对的 AVGO/GOOG，不据这两只样例宣称完整美股覆盖。
  /// [request] 不包含账户或持仓数量；期权、TEST、人民币港股柜台及未知市场不发请求。
  @override
  bool supports(MarketQuoteRequest request) => _queryCode(request) != null;

  /// 合并最多二十个证券为一次公开请求，流式累计五百一十二 KiB、整批十五秒内结束。
  /// [requests] 中不支持的证券不会发送；全部不支持或空集合时不创建任何网络连接。
  /// 返回值仅含身份、原币、价格及源时间均有效的观察，缺价不伪造成零价。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
    if (requests.length > maximumSecurities) {
      throw const FormatException('腾讯行情单批证券数量超过上限');
    }
    final selected = <String, MarketQuoteRequest>{};
    for (final request in requests) {
      final code = _queryCode(request);
      if (code != null) selected.putIfAbsent(code, () => request);
    }
    if (selected.isEmpty) return const [];
    TencentQuoteTransport? transport;
    var cancelled = false;

    /// 时区准备和传输属于同一个批次时限；超时后晚完成的资产读取不能再发起请求。
    Future<List<MarketQuote>> readPreparedBatch() async {
      if (selected.values.any((request) => request.market == StockMarket.us)) {
        // 美股源时间是纽约当地时间；读取已有压缩资产，不固定减四/五小时猜夏令时。
        await ensureTimezoneDatabase();
      }
      if (cancelled) return const [];
      final current = transportFactory?.call() ?? TencentHttpQuoteTransport();
      transport = current;
      return _readBatch(current, selected);
    }

    try {
      return await readPreparedBatch().timeout(requestTimeout);
    } finally {
      // Future.timeout 本身不会取消底层 I/O，这里强制关闭本批连接及响应流。
      cancelled = true;
      transport?.close();
    }
  }

  /// 请求固定主机并按字节预算读取；[selected] 为已校验且去重的来源代码映射。
  /// HTTP 拒绝、重定向和超限直接失败，不尝试绕过或换来源身份重试。
  Future<List<MarketQuote>> _readBatch(
    TencentQuoteTransport transport,
    Map<String, MarketQuoteRequest> selected,
  ) async {
    final uri = Uri.https('qt.gtimg.cn', '/q=${selected.keys.join(',')}');
    final response = await transport.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('腾讯行情请求失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.body) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const FormatException('腾讯行情响应超过五百一十二 KiB 上限');
      }
      bytes.addAll(chunk);
    }
    return _parseRows(gbk.decode(bytes), selected, _clock().toUtc());
  }

  /// 将证券映射到严格的公开股票代码；返回 null 表示不支持，调用方不能猜市场。
  /// [request] 的 HKD/CNY 必须和市场相符；前导零保留在来源代码及证券 ID 中。
  static String? _queryCode(MarketQuoteRequest request) {
    if (request.option ||
        request.fund ||
        request.symbol.toUpperCase().startsWith('TEST-')) {
      return null;
    }
    if (request.market == StockMarket.cn &&
        request.currency == 'CNY' &&
        RegExp(r'^[036]\d{5}$').hasMatch(request.symbol)) {
      return '${request.symbol.startsWith('6') ? 'sh' : 'sz'}${request.symbol}';
    }
    if (request.market == StockMarket.hk &&
        request.currency == 'HKD' &&
        RegExp(r'^0\d{4}$').hasMatch(request.symbol)) {
      return 'hk${request.symbol}';
    }
    if (request.market == StockMarket.us &&
        request.currency == 'USD' &&
        const {'AVGO', 'GOOG'}.contains(request.symbol)) {
      return 'us${request.symbol}';
    }
    return null;
  }

  /// 只解析返回文本，不执行其中的 JavaScript；重复行与未知行不能成为有效观察。
  /// [selected] 是本批允许的股票；[fetchedAt] 为真实抓取时间，不代替报价时间。
  static List<MarketQuote> _parseRows(
    String text,
    Map<String, MarketQuoteRequest> selected,
    DateTime fetchedAt,
  ) {
    final rows = <String, List<String>>{}, duplicated = <String>{};
    final rowPattern = RegExp(r'^v_([a-zA-Z0-9]+)="([^"\r\n]*)";$');
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final match = rowPattern.firstMatch(line.trim());
      if (match == null) continue;
      final code = match[1]!;
      if (!selected.containsKey(code)) continue;
      if (rows.containsKey(code)) duplicated.add(code);
      rows[code] = match[2]!.split('~');
    }
    final quotes = <MarketQuote>[];
    for (final item in selected.entries) {
      final fields = rows[item.key];
      if (fields == null || duplicated.contains(item.key)) continue;
      final request = item.value;
      final currencyIndex = switch (request.market) {
        StockMarket.us => 35,
        StockMarket.hk => 75,
        StockMarket.cn => 82,
      };
      final marketCode = switch (request.market) {
        StockMarket.us => '200',
        StockMarket.hk => '100',
        StockMarket.cn => item.key.startsWith('sh') ? '1' : '51',
      };
      final sourceSymbol = request.market == StockMarket.us
          ? '${request.symbol}.OQ'
          : request.symbol;
      if (fields.length <= currencyIndex ||
          fields[0].trim() != marketCode ||
          fields[2].trim() != sourceSymbol ||
          fields[currencyIndex].trim() != request.currency) {
        continue;
      }
      final time = _sourceTime(fields[30].trim(), market: request.market);
      if (time == null ||
          time.isAfter(fetchedAt.add(const Duration(minutes: 5)))) {
        continue;
      }
      try {
        final price = InvestmentDecimal.parse(fields[3]);
        if (price.units <= BigInt.zero) continue;
        final quote = MarketQuote(
          securityId: request.securityId,
          source: 'Tencent Finance',
          currency: request.currency,
          unit: QuotePriceUnit.share,
          fetchedAt: fetchedAt,
          last: price.toString(),
          lastAt: time,
        );
        if (quote.reference(request, fetchedAt) != null) quotes.add(quote);
      } on FormatException {
        // 单行外部量价字段异常属于可接受降级；不记录原始响应，也不影响其他股票。
      }
    }
    return List.unmodifiable(quotes);
  }

  /// 严格解析实际源时间；沪深/香港为 UTC+8，美股为 America/New_York（含夏令时）。
  /// [raw] 不允许缺时分秒；[market] 选择对应来源格式，非法日期或夏令时跳时返回 null。
  static DateTime? _sourceTime(String raw, {required StockMarket market}) {
    final pattern = switch (market) {
      StockMarket.us => RegExp(
        r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
      ),
      StockMarket.hk => RegExp(
        r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
      ),
      StockMarket.cn => RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$'),
    };
    final match = pattern.firstMatch(raw);
    if (match == null) return null;
    final values = [
      for (var index = 1; index <= 6; index++) int.parse(match[index]!),
    ];
    final wall = DateTime.utc(
      values[0],
      values[1],
      values[2],
      values[3],
      values[4],
      values[5],
    );
    if (values[0] < 2000 || !_matchesLocalParts(wall, values)) {
      return null;
    }
    if (market == StockMarket.us) {
      final location = tz.getLocation('America/New_York');
      final newYork = tz.TZDateTime(
        location,
        values[0],
        values[1],
        values[2],
        values[3],
        values[4],
        values[5],
      );
      if (!_matchesLocalParts(newYork, values)) {
        return null;
      }
      // 秋季回拨的同一当地时间会出现两次；源未给偏移时不能擅自选择其中一次。
      final before = tz.TZDateTime.from(
        newYork.toUtc().subtract(const Duration(hours: 1)),
        location,
      );
      final after = tz.TZDateTime.from(
        newYork.toUtc().add(const Duration(hours: 1)),
        location,
      );
      if (_matchesLocalParts(before, values) ||
          _matchesLocalParts(after, values)) {
        return null;
      }
      return newYork.toUtc();
    }
    // 此处是时区偏移的真实小时换算，不进行日历日加减。
    return wall.subtract(const Duration(hours: 8));
  }

  /// 比较 [time] 的当地年月日时分秒与已解析的六段 [parts]，检测日期归一及夏令时歧义。
  static bool _matchesLocalParts(DateTime time, List<int> parts) =>
      (time.year, time.month, time.day, time.hour, time.minute, time.second) ==
      (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
}
