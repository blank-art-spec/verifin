/// 招商资管香港美元货币基金的诊断净值来源；官网接口可用不等于取得发行使用许可。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';
import 'investment_decimal.dart';
import 'market_quote.dart';

/// 一次官网净值响应；正文保留为字节流，调用方能在超限时立即停止下载。
class CmsFundQuoteResponse {
  /// [statusCode] 为未经改写的 HTTP 状态；[body] 尚未完整读取。
  /// [contentLength] 为来源声明的字节数，未知时使用 -1；不能代替累计字节检查。
  const CmsFundQuoteResponse({
    required this.statusCode,
    required this.body,
    this.contentLength = -1,
  });

  final int statusCode, contentLength;
  final Stream<List<int>> body;
}

/// 每批查询独占的匿名传输；测试可注入本地响应，不依赖真实互联网。
abstract class CmsFundQuoteTransport {
  /// 向已经核对的官网地址发送 JSON；[uri] 和 [body] 均由适配器固定，不能来自用户。
  Future<CmsFundQuoteResponse> post(Uri uri, List<int> body);

  /// 立即关闭本批连接及未读完的响应；允许在正常完成、失败和超时后重复调用。
  void close();
}

/// 为一次 fetch 创建独立传输，避免复用其他查询、登录或账目操作的 Cookie 和凭证。
typedef CmsFundQuoteTransportFactory = CmsFundQuoteTransport Function();

/// 官网固定 HTTPS 匿名 POST；不改变证书校验，不跟随跳转，也不更换身份重试。
class CmsFundHttpQuoteTransport implements CmsFundQuoteTransport {
  /// [client] 仅用于测试核对请求配置；生产留空创建无历史会话的独立 HttpClient。
  /// [connectionTimeout] 限制建连阶段；包含下载与解析的总时限由适配器统一控制。
  CmsFundHttpQuoteTransport({
    HttpClient? client,
    Duration connectionTimeout = const Duration(seconds: 10),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = connectionTimeout;
  }

  final HttpClient _client;

  /// 校验固定主机、路径和公开基金参数后发送，不接受自定义端点或任意请求正文。
  /// [body] 必须等于官网实际使用的基金名称及简体中文语言参数；不发送账户或持仓。
  @override
  Future<CmsFundQuoteResponse> post(Uri uri, List<int> body) async {
    if (uri.scheme != 'https' ||
        uri.host != 'cms.cmschina.com.hk' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path != '/api/v1/fund/netVal-info' ||
        utf8.decode(body, allowMalformed: true) !=
            CmsFundQuoteAdapter.requestBody) {
      throw const FormatException('招商基金净值地址或请求参数不在允许范围');
    }
    final request = await _client.postUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.removeAll(HttpHeaders.proxyAuthorizationHeader);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    return CmsFundQuoteResponse(
      statusCode: response.statusCode,
      contentLength: response.contentLength,
      body: response,
    );
  }

  /// 强制终止本批客户端；Future.timeout 只停止等待，底层 I/O 必须在这里实际关闭。
  @override
  void close() => _client.close(force: true);
}

/// 仅核对招商美元货币市场基金 B 类，不按相似名称推断其他香港基金也受支持。
class CmsFundQuoteAdapter extends MarketQuoteAdapter {
  /// [transportFactory] 为每批提供独立连接；[clock] 返回真实抓取时刻，测试可固定。
  /// [requestTimeout] 只允许缩短故障测试时限，生产默认十五秒，不能提高上限。
  CmsFundQuoteAdapter({
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

  final CmsFundQuoteTransportFactory? transportFactory;
  final DateTime Function() _clock;
  final Duration requestTimeout;

  static const maximumBytes = 512 * 1024;
  static const maximumSecurities = 20;
  static const sourceId = 'CMS Asset Management (HK)';

  /// 响应本身不包含 ISIN 和币种，因此身份映射只能来自已经核对的一手产品定义。
  /// 官网 NPCF 模块将 B 类绑定 HK0001039582，并在价格表标记 USD：
  /// https://cms.cmschina.com.hk/js/70.e98f9.js 。不把 A/I/M/P 类混作 B 类。
  static const supportedIsin = 'HK0001039582';

  /// 官网同一模块实际使用的最小公开参数；不带用户账户、份额、成本、Cookie 或 Key。
  static const requestBody =
      '{"lang":"zh-CN","fundName":"CMS_USD_Money_Market_Fund"}';

  /// 尚未确认对外应用展示授权，继续保留研究门禁，不能因匿名请求成功而自动批准。
  @override
  QuoteSourceCapability get capability => const QuoteSourceCapability(
    sourceId,
    approved: false,
    researchOnly: true,
    reviewNote: '官网基金净值已核对身份、原币及源日期，发行使用条件仍待确认',
  );

  /// [request] 必须明确为香港、美元、指定 ISIN 的基金；股票、期权及其他份额不查询。
  @override
  bool supports(MarketQuoteRequest request) =>
      request.fund &&
      !request.option &&
      request.market == StockMarket.hk &&
      request.symbol == supportedIsin &&
      request.currency == 'USD';

  /// 整批最多二十个输入身份，去重后只发一次固定请求；空集合或全不支持时不建连接。
  /// 返回最新净值和同份额完整公开历史，供设备参考计算；不生成收入或账目历史快照。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
    if (requests.length > maximumSecurities) {
      throw const FormatException('招商基金净值单批证券数量超过上限');
    }
    final selected = <String, MarketQuoteRequest>{};
    for (final request in requests) {
      if (supports(request)) {
        selected.putIfAbsent(request.securityId, () => request);
      }
    }
    if (selected.isEmpty) return const [];
    final transport = transportFactory?.call() ?? CmsFundHttpQuoteTransport();
    try {
      return await _readBatch(transport, selected.values).timeout(
        requestTimeout,
        onTimeout: () =>
            throw TimeoutException('招商基金净值请求超过允许时限', requestTimeout),
      );
    } finally {
      // 成功、HTTP 拒绝、解析失败、超限及总超时均关闭，不留下继续下载的后台连接。
      transport.close();
    }
  }

  /// 向固定主机请求并流式累计字节；[selected] 仅含本批已经通过身份检查的请求。
  /// 拒绝和重定向直接失败，不携带登录态重试，也不切换主机、User-Agent 或证书规则。
  Future<List<MarketQuote>> _readBatch(
    CmsFundQuoteTransport transport,
    Iterable<MarketQuoteRequest> selected,
  ) async {
    final response = await transport.post(
      Uri.https('cms.cmschina.com.hk', '/api/v1/fund/netVal-info'),
      utf8.encode(requestBody),
    );
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('招商基金净值请求失败：HTTP ${response.statusCode}');
    }
    if (response.contentLength > maximumBytes) {
      throw const FormatException('招商基金净值响应超过五百一十二 KiB 上限');
    }
    final bytes = <int>[];
    await for (final chunk in response.body) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const FormatException('招商基金净值响应超过五百一十二 KiB 上限');
      }
      bytes.addAll(chunk);
    }
    final fetchedAt = _clock().toUtc();
    final latest = _parseLatest(bytes, fetchedAt);
    return [
      for (final request in selected)
        MarketQuote(
          securityId: request.securityId,
          source: sourceId,
          currency: 'USD',
          unit: QuotePriceUnit.fundUnit,
          last: latest.price,
          lastAt: latest.date,
          dateOnly: true,
          navHistory: latest.history,
          fetchedAt: fetchedAt,
        ),
    ];
  }

  /// 严格核对官方 JSON 的 B 类历史与最新摘要；[fetchedAt] 用于拒绝未来源日期。
  /// 日期使用 UTC 零点作为日历日载体，并不声称该日零点是来源公布或成交时刻。
  /// 完整历史只成为公开参考缓存，不回填 SQLite、交易或用户主动保存的账目快照。
  static ({String price, DateTime date, FundNavHistory history}) _parseLatest(
    List<int> bytes,
    DateTime fetchedAt,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('招商基金净值响应不是有效的 UTF-8 JSON');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['code'] is! int ||
        decoded['code'] != 0) {
      throw const FormatException('招商基金净值来源返回失败状态或缺少状态码');
    }
    final result = decoded['result'];
    if (result is! Map<String, Object?>) {
      throw const FormatException('招商基金净值响应缺少结果对象');
    }
    final dates = result['dateList'];
    final classes = result['fundClassDataList'];
    final lastValues = result['lastValMap'];
    if (dates is! List<Object?> ||
        dates.isEmpty ||
        dates.length > FundNavHistory.maximumPoints ||
        classes is! List<Object?> ||
        lastValues is! Map<String, Object?>) {
      throw const FormatException('招商基金净值响应缺少日期、份额或最新净值');
    }
    final bClasses = classes
        .whereType<Map<String, Object?>>()
        .where((series) => series['key'] == 'B' || series['name'] == 'B类')
        .toList();
    if (bClasses.length != 1 ||
        bClasses.single['key'] != 'B' ||
        bClasses.single['name'] != 'B类') {
      throw const FormatException('招商基金净值响应缺少唯一的 B 类份额');
    }
    final values = bClasses.single['data'];
    if (values is! List<Object?> || values.length != dates.length) {
      throw const FormatException('招商基金 B 类历史净值与日期数量不一致');
    }
    DateTime? previousDate;
    InvestmentDecimal? previousValue;
    final points = <FundNavPoint>[];
    // 香港采用 UTC+8；这里只判断源日历日是否在未来，不据此虚构日内报价时刻。
    final hongKongNow = fetchedAt.add(const Duration(hours: 8));
    final latestPossibleDate = DateTime.utc(
      hongKongNow.year,
      hongKongNow.month,
      hongKongNow.day,
    );
    for (var index = 0; index < dates.length; index++) {
      final date = _sourceDate(dates[index]);
      if ((previousDate != null && !date.isAfter(previousDate)) ||
          date.isAfter(latestPossibleDate)) {
        throw const FormatException('招商基金净值日期重复、倒序或晚于当前香港日期');
      }
      previousDate = date;
      previousValue = _positivePrice(values[index]);
      points.add(FundNavPoint(date: date, price: values[index]! as String));
    }
    final lastDate = _sourceDate(result['lastUpdate']);
    final lastValue = _positivePrice(lastValues['B']);
    if (lastDate != previousDate || lastValue.compareTo(previousValue!) != 0) {
      throw const FormatException('招商基金最新摘要与 B 类历史末点不一致');
    }
    return (
      price: lastValues['B']! as String,
      date: lastDate,
      history: FundNavHistory(points),
    );
  }

  /// 将来源 YYYYMMDD 文本验证为真实公历日；拒绝缺失、溢出及 DateTime 自动归一。
  /// [value] 必须是来源日期字符串，不能把抓取时间或本机时间拿来补缺失日期。
  static DateTime _sourceDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{8}$').hasMatch(value)) {
      throw const FormatException('招商基金净值源日期缺失或格式不合法');
    }
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(4, 6));
    final day = int.parse(value.substring(6, 8));
    final date = DateTime.utc(year, month, day);
    if (year < 1900 ||
        date.year != year ||
        date.month != month ||
        date.day != day) {
      throw const FormatException('招商基金净值源日期不是有效公历日');
    }
    return date;
  }

  /// 验证正数净值的原始文本并用八位定点数比较，不经 double 或尾零截断。
  /// [value] 为 B 类某日或最新净值；缺值、数值型 JSON、零、负数和超精度均拒绝。
  static InvestmentDecimal _positivePrice(Object? value) {
    if (value is! String ||
        !RegExp(r'^\d{1,12}(\.\d{1,8})?$').hasMatch(value)) {
      throw const FormatException('招商基金 B 类净值缺失或不是支持精度的数字文本');
    }
    final price = InvestmentDecimal.parse(value);
    if (price.units <= BigInt.zero) {
      throw const FormatException('招商基金 B 类净值必须为正数');
    }
    return price;
  }
}
