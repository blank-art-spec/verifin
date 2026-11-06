/// 用户主动查询香港基金的公开身份；不采用网页价格、不改变行情设置，也不写入账目。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';
import 'security_search.dart';

/// 单次基金资料查询的 HTTP 传输，只允许已经核对的官方公开资料页。
class FundSecuritySearchTransport implements SecuritySearchTransport {
  /// [client] 供测试核对请求配置；生产为每次查询创建独立、无凭证的客户端。
  FundSecuritySearchTransport({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
  }

  final HttpClient _client;

  /// 核对 [uri] 的协议、主机、路径及固定产品参数后发出匿名 GET。
  /// 查询 ISIN 只在本机筛选公开资料，账号、持仓、Cookie 和认证头均不发送。
  @override
  Future<SecuritySearchResponse> get(Uri uri) async {
    final cmsPage =
        uri.host == 'www.cmschina.com.hk' &&
        uri.path == '/en/AM/FundProduct' &&
        uri.queryParametersAll.length == 1 &&
        uri.queryParametersAll.values.every((values) => values.length == 1) &&
        const {'NPCF', 'CMMF'}.contains(uri.queryParameters['view']);
    final valuePartnersPage =
        uri.host == 'www.valuepartners-group.com' &&
        uri.path == '/en/products-services/funds/' &&
        !uri.hasQuery;
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (!cmsPage && !valuePartnersPage)) {
      throw const FormatException('基金资料查询地址不在允许范围');
    }
    final request = await _client.getUrl(uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.cookies.clear();
    request.headers.removeAll(HttpHeaders.cookieHeader);
    request.headers.removeAll(HttpHeaders.authorizationHeader);
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    request.headers.set(HttpHeaders.userAgentHeader, 'VeriFin fund-search');
    final response = await request.close();
    return SecuritySearchResponse(
      statusCode: response.statusCode,
      body: response,
    );
  }

  /// 完成、失败及超时后立即关闭连接，避免停止等待后仍继续接收网页。
  @override
  void close() => _client.close(force: true);
}

/// 按完整 ISIN 核对香港基金身份；构造及输入变化不会联网。
class FundSecuritySearchClient {
  /// [transportFactory] 注入无网络测试响应；[requestTimeout] 覆盖请求和全部读取，
  /// 只允许缩短默认十秒时限。资料仅用来补全身份，不把历史价格当成当前净值。
  FundSecuritySearchClient({
    this.transportFactory,
    this.requestTimeout = const Duration(seconds: 10),
  }) {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 10)) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        '基金查询时限须在十秒以内',
      );
    }
  }

  final SecuritySearchTransportFactory? transportFactory;
  final Duration requestTimeout;

  /// 惠理官方完整列表约 530 KiB；流读取仍有界，不能先完整下载后再判断。
  static const maximumBytes = 768 * 1024;

  /// 已核对的招商身份仅用来选择其官方产品页，返回资料仍必须来自实时响应。
  /// 其他代码查询惠理已核对的香港货币基金表，不因为没在本映射内而假造名称。
  static const _cmsCurrencies = {
    'HK0001039574': 'USD',
    'HK0001039582': 'USD',
    'HK0001039590': 'USD',
    'HK0001039608': 'USD',
    'HK0000890803': 'HKD',
    'HK0000890811': 'HKD',
    'HK0000890829': 'HKD',
  };

  /// 只查询 [query] 指定的完整 ISIN，按 [market] 和实际结算 [currencyCode] 筛选。
  /// 当前来源限招商香港美元/港元货币基金及惠理美元货币基金的 USD/HKD 份额；
  /// 未知代码返回空列表，不冒充全市场搜索。ISIN 仅在本机匹配，不发送给来源。
  /// 市场或币种不支持时不联网；查询成功仍需用户选择后才进入草稿，不携带价格和交易数据。
  Future<List<StockSecurity>> search(
    String query, {
    required StockMarket market,
    required String currencyCode,
  }) async {
    final symbol = query.trim().toUpperCase();
    if (symbol.isEmpty ||
        market != StockMarket.hk ||
        !const {'USD', 'HKD'}.contains(currencyCode)) {
      return const [];
    }
    if (!RegExp(r'^HK[A-Z0-9]{9}[0-9]$').hasMatch(symbol)) {
      throw const FormatException('请输入完整的香港基金 ISIN 代码');
    }
    final cmsCurrency = _cmsCurrencies[symbol];
    if (cmsCurrency != null && cmsCurrency != currencyCode) return const [];
    final uri = cmsCurrency == null
        ? Uri.https(
            'www.valuepartners-group.com',
            '/en/products-services/funds/',
          )
        : Uri.https('www.cmschina.com.hk', '/en/AM/FundProduct', {
            'view': cmsCurrency == 'USD' ? 'NPCF' : 'CMMF',
          });
    final transport = transportFactory?.call() ?? FundSecuritySearchTransport();
    try {
      return await _read(transport, uri, symbol, currencyCode).timeout(
        requestTimeout,
        onTimeout: () {
          transport.close();
          throw TimeoutException('基金资料查询超时');
        },
      );
    } finally {
      transport.close();
    }
  }

  /// 从 [transport] 流式读取 [uri]，累计超过上限立即中止；只解析精确 [symbol]。
  /// [currencyCode] 是本地筛选条件，必须与官网对应份额的明确币种一致；
  /// 招商同币种产品还核对基础币种，惠理多币种份额不得用产品基础币种替代份额币种。
  Future<List<StockSecurity>> _read(
    SecuritySearchTransport transport,
    Uri uri,
    String symbol,
    String currencyCode,
  ) async {
    final response = await transport.get(uri);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('基金资料查询失败：HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.body) {
      if (bytes.length + chunk.length > maximumBytes) {
        throw const FormatException('基金资料响应超过七百六十八 KiB 上限');
      }
      bytes.addAll(chunk);
    }
    final html = utf8.decode(bytes);
    return uri.host == 'www.cmschina.com.hk'
        ? _parseCms(html, symbol, currencyCode)
        : _parseValuePartners(html, symbol, currencyCode);
  }

  /// 仅提取 [html] 内已核对的基金名称、ISIN 份额行及其币种，绝不执行脚本。
  /// 资料页含过时价格，本方法只取价格行明确标注的份额币种，完全不读取数值或日期。
  /// [symbol] 必须精确命中 ISIN 表；无法证明份额币种时返回空列表，不按名称猜测。
  static List<StockSecurity> _parseCms(
    String html,
    String symbol,
    String currencyCode,
  ) {
    final safe = _withoutScripts(html);
    final expectedName = currencyCode == 'USD'
        ? 'CMS USD Money Market Fund'
        : 'CMS Money Market Fund';
    final selectedName = RegExp(
      r'''<div\b[^>]*\bclass=["']fundProductMenuSelect\s+sel["'][^>]*>([^<]+)</div\s*>''',
      caseSensitive: false,
    ).firstMatch(safe);
    if (selectedName == null || _text(selectedName[1]!) != expectedName) {
      throw const FormatException('基金资料页无法核实当前产品名称');
    }
    final text = _text(safe);
    final infoStart = text.indexOf('Fund Information');
    final isinStart = text.indexOf('ISIN Code', infoStart < 0 ? 0 : infoStart);
    final isinEnd = text.indexOf(
      'Bloomberg Code',
      isinStart < 0 ? 0 : isinStart,
    );
    if (infoStart < 0 || isinStart < infoStart || isinEnd < isinStart) {
      throw const FormatException('基金资料页缺少可核对的 ISIN 表');
    }
    final information = text.substring(infoStart, isinStart);
    if (!information.contains('Base Currency $currencyCode Fund Structure')) {
      return const [];
    }
    final identities = RegExp(r'Class ([A-Z]) (HK[A-Z0-9]{9}[0-9])\b')
        .allMatches(text.substring(isinStart, isinEnd))
        .where((match) => match[2] == symbol)
        .toList();
    if (identities.length != 1) return const [];
    final shareClass = identities.single[1]!;
    final priceSection = text.substring(0, infoStart);
    final currencies = RegExp(
      'NAV per Unit - Class $shareClass ([A-Z]{3})\\b',
    ).allMatches(priceSection).map((match) => match[1]!).toSet();
    if (currencies.length != 1 || currencies.single != currencyCode) {
      return const [];
    }
    return [
      StockSecurity(
        symbol: symbol,
        name: '$expectedName Class $shareClass',
        market: StockMarket.hk,
        currencyCode: currencyCode,
        type: InvestmentSecurityType.fund,
      ),
    ];
  }

  /// 仅解析惠理 [html] 内 vpmm 对应的香港美元货币基金表，匹配精确 [symbol]。
  /// 基金根据香港法律成立的信托身份已由官方 KFS 核对；不扩展到目录中的其他基金：
  /// https://www.valuepartners-group.com/ftp/files/reports/vpmm/006_kfs/eng/vpmm_kfs_2025-08-11_en.pdf
  /// 每行以独立 Currency 列核对 [currencyCode]，不把基金名中的 USD 当成所有份额币种。
  static List<StockSecurity> _parseValuePartners(
    String html,
    String symbol,
    String currencyCode,
  ) {
    final safe = _withoutScripts(html);
    const fundName =
        'Value Partners Fund Series - Value Partners USD Money Market Fund';
    const productUrl =
        'https://www.valuepartners-group.com/en/investment-solutions/institutional-funds/value-partners-usd-money-market-fund/';
    final headings =
        RegExp(r'<h1\b[^>]*>([\s\S]*?)</h1\s*>', caseSensitive: false)
            .allMatches(safe)
            .where(
              (heading) =>
                  RegExp(
                    r'''\bdata-id\s*=\s*["']vpmm["']''',
                  ).hasMatch(heading[1]!) &&
                  RegExp(
                    'href\\s*=\\s*["\']${RegExp.escape(productUrl)}["\']',
                  ).hasMatch(heading[1]!) &&
                  _text(heading[1]!) == fundName,
            )
            .toList();
    if (headings.length != 1) {
      throw const FormatException('惠理资料页无法核实对应的香港货币基金');
    }
    final rest = safe.substring(headings.single.end);
    final nextHeading = RegExp(r'<h1\b', caseSensitive: false).firstMatch(rest);
    final section = nextHeading == null
        ? rest
        : rest.substring(0, nextHeading.start);
    final table = RegExp(
      r'''<table\b[^>]*\bclass=["'][^"']*\bfund-list-table\b[^"']*["'][^>]*>([\s\S]*?)</table\s*>''',
      caseSensitive: false,
    ).firstMatch(section);
    if (table == null) throw const FormatException('惠理资料页缺少基金份额表');
    final rows = RegExp(
      r'<tr\b[^>]*>([\s\S]*?)</tr\s*>',
      caseSensitive: false,
    ).allMatches(table[1]!).map((match) => match[1]!).toList();
    if (rows.isEmpty ||
        _cells(rows.first, 'th').join('|') !=
            'Share Classes|Currency|Latest NAV|Valuation date|Morningstar Rating|ISIN codes|Bloomberg tickers') {
      throw const FormatException('惠理基金资料表头已变化，无法核实字段含义');
    }
    final matching = rows
        .skip(1)
        .map((row) => _cells(row, 'td'))
        .where((cells) => cells.length == 7 && cells[5] == symbol)
        .toList();
    if (matching.length != 1) return const [];
    final cells = matching.single;
    if (cells[1] != currencyCode ||
        !RegExp(
          '^Class [A-Z] $currencyCode Unhedged Acc\$',
        ).hasMatch(cells[0])) {
      return const [];
    }
    return [
      StockSecurity(
        symbol: symbol,
        name: '$fundName - ${cells[0]}',
        market: StockMarket.hk,
        currencyCode: currencyCode,
        type: InvestmentSecurityType.fund,
      ),
    ];
  }

  /// 从单个表格 [row] 提取 [tag] 指定的 th/td 普通文字，保持真实列顺序。
  /// 仅由固定标签调用，不接受外部表达式；净值列即使存在也不转换为价格或收益。
  static List<String> _cells(String row, String tag) => RegExp(
    '<$tag\\b[^>]*>([\\s\\S]*?)</$tag\\s*>',
    caseSensitive: false,
  ).allMatches(row).map((match) => _text(match[1]!)).toList();

  /// 移除 [html] 的脚本、样式及注释，避免代码字符串或隐藏说明伪装成身份表。
  /// 不执行页面，也不加载其中图片、iframe、第三方分析或其他资源。
  static String _withoutScripts(String html) => html
      .replaceAll(
        RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'<style\b[^>]*>[\s\S]*?</style\s*>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  /// 将已移除脚本的 [html] 归并为普通文字，用于官方固定标签之间的身份匹配。
  /// 只处理已观察到的空白实体；不加载外部资源，不解释属性或执行 HTML。
  static String _text(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
