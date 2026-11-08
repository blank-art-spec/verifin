/// 用户主动按 ISIN 查询公开基金身份；结果需核对，不采用网页价格或写入账目。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/investment.dart';
import 'fund_identity_candidate.dart';
import 'security_search.dart';

/// 只表示用户输入的 ISIN 不合法，与来源响应格式变化分别处理。
class FundSearchInvalidIsinException implements Exception {
  const FundSearchInvalidIsinException();
}

/// ISO 6166 的十二位字母数字形状和 Luhn 校验位；不限制国家或基金公司。
bool isValidFundIsin(String value) {
  if (!RegExp(r'^[A-Z]{2}[A-Z0-9]{9}[0-9]$').hasMatch(value)) return false;
  final digits = value.codeUnits
      .map(
        (unit) =>
            unit >= 65 ? (unit - 55).toString() : String.fromCharCode(unit),
      )
      .join();
  var sum = 0;
  for (var index = 0; index < digits.length; index++) {
    var digit = digits.codeUnitAt(digits.length - index - 1) - 48;
    if (index.isOdd) digit *= 2;
    sum += digit ~/ 10 + digit % 10;
  }
  return sum % 10 == 0;
}

/// 单次基金资料传输；来源地址受约束，通用目录按任意有效 ISIN 查询。
class FundSecuritySearchTransport implements SecuritySearchTransport {
  /// [client] 供测试核对请求配置；生产为每次查询创建独立、无凭证的客户端。
  FundSecuritySearchTransport({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
  }

  final HttpClient _client;

  /// 核对 [uri] 的协议、主机、路径及固定产品参数后发出匿名 GET。
  /// 通用目录只接收 ISIN；账号、币种、持仓、Cookie 和认证头均不发送。
  @override
  Future<SecuritySearchResponse> get(Uri uri) async {
    final tigerIsin = uri.path.startsWith('/FUND/')
        ? uri.path.substring('/FUND/'.length)
        : '';
    final tigerPage =
        uri.host == 'www.laohu8.com' &&
        !uri.hasQuery &&
        isValidFundIsin(tigerIsin);
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
        (!tigerPage && !cmsPage && !valuePartnersPage)) {
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

/// 按完整 ISIN 查询跨公司基金目录；构造及输入变化不会联网。
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

  /// 这些映射只选择通用目录未收录时的补充官网，不限制通用 ISIN 查询。
  static const _cmsCurrencies = {
    'HK0001039574': 'USD',
    'HK0001039582': 'USD',
    'HK0001039590': 'USD',
    'HK0001039608': 'USD',
    'HK0000890803': 'HKD',
    'HK0000890811': 'HKD',
    'HK0000890829': 'HKD',
  };

  static const _valuePartnersCurrencies = {
    'HK0000945037': 'USD',
    'HK0000961927': 'USD',
    'HK0000945029': 'HKD',
    'HK0000961919': 'HKD',
    'HK0000945045': 'HKD',
  };

  /// 只向通用目录发送 [query] 的完整 ISIN，不发送账户上下文或猜测币种。
  /// [market]、[currencyCode] 保留调用契约；返回实际来源资料供页面核对，
  /// 币种不符也展示候选，不按国家前缀推断市场，不写入行情或交易。
  Future<List<FundIdentityCandidate>> search(
    String query, {
    required StockMarket market,
    required String currencyCode,
  }) async {
    final symbol = query.trim().toUpperCase();
    if (symbol.isEmpty) return const [];
    if (!isValidFundIsin(symbol)) throw const FundSearchInvalidIsinException();
    final transport = transportFactory?.call() ?? FundSecuritySearchTransport();
    var ended = false;
    try {
      return await _lookup(transport, symbol, () => ended).timeout(
        requestTimeout,
        onTimeout: () {
          ended = true;
          transport.close();
          throw TimeoutException('基金资料查询超时');
        },
      );
    } finally {
      ended = true;
      transport.close();
    }
  }

  /// 通用目录优先；已验证官网仅补充未收录、缺字段或暂时失败的既有基金。
  Future<List<FundIdentityCandidate>> _lookup(
    SecuritySearchTransport transport,
    String symbol,
    bool Function() hasEnded,
  ) async {
    List<FundIdentityCandidate> primary = const [];
    Object? primaryError;
    StackTrace? primaryStack;
    try {
      primary = await _read(
        transport,
        Uri.https('www.laohu8.com', '/FUND/$symbol'),
        symbol,
      );
      if (primary.any((candidate) => candidate.hasCompleteIdentity)) {
        return primary;
      }
    } catch (error, stack) {
      if (error is! IOException && error is! FormatException) rethrow;
      primaryError = error;
      primaryStack = stack;
    }
    // 总时限结束后，关闭中的主请求不能再触发补充请求。
    if (hasEnded()) return const [];
    final cmsCurrency = _cmsCurrencies[symbol];
    final officialCurrency = cmsCurrency ?? _valuePartnersCurrencies[symbol];
    if (officialCurrency != null) {
      final uri = cmsCurrency == null
          ? Uri.https(
              'www.valuepartners-group.com',
              '/en/products-services/funds/',
            )
          : Uri.https('www.cmschina.com.hk', '/en/AM/FundProduct', {
              'view': cmsCurrency == 'USD' ? 'NPCF' : 'CMMF',
            });
      try {
        final official = await _read(transport, uri, symbol, officialCurrency);
        if (official.isNotEmpty) return official;
      } catch (error) {
        if (error is! IOException && error is! FormatException) rethrow;
        if (primary.isEmpty) rethrow;
        // 已获得身份但缺字段时仍展示来源，让用户手工核对；不伪造补充资料。
      }
    }
    if (primary.isNotEmpty) return primary;
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStack!);
    }
    return const [];
  }

  /// 从 [transport] 流式读取 [uri]，累计超过上限立即中止；只解析精确 [symbol]。
  /// [currencyCode] 是本地筛选条件，必须与官网对应份额的明确币种一致；
  /// 招商同币种产品还核对基础币种，惠理多币种份额不得用产品基础币种替代份额币种。
  Future<List<FundIdentityCandidate>> _read(
    SecuritySearchTransport transport,
    Uri uri,
    String symbol, [
    String? currencyCode,
  ]) async {
    final response = await transport.get(uri);
    if (uri.host == 'www.laohu8.com' &&
        response.statusCode == HttpStatus.notFound) {
      await response.body.listen(null).cancel();
      return const [];
    }
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
    return switch (uri.host) {
      'www.laohu8.com' => _parseTiger(html, symbol, uri),
      'www.cmschina.com.hk' => _parseCms(html, symbol, currencyCode!),
      _ => _parseValuePartners(html, symbol, currencyCode!),
    };
  }

  /// 只读公开页面的身份 JSON，不执行脚本或采用价格；同时核对 code 与 symbol。
  static List<FundIdentityCandidate> _parseTiger(
    String html,
    String symbol,
    Uri sourceUrl,
  ) {
    final blocks = RegExp(
      r'''<textarea\b[^>]*\s+id\s*=\s*["']__APP_DATA__["'][^>]*>([\s\S]*?)</textarea\s*>''',
      caseSensitive: false,
    ).allMatches(_withoutScripts(html)).toList();
    if (blocks.length != 1) {
      throw const FormatException('基金目录缺少可核对的身份资料');
    }
    final data = jsonDecode(_decodeEntities(blocks.single[1]!));
    if (data is! Map<String, dynamic> ||
        data['fundInfo'] is! Map<String, dynamic>) {
      throw const FormatException('基金目录身份结构已变化');
    }
    final fund = data['fundInfo'] as Map<String, dynamic>;
    final name = fund['name'];
    final code = fund['code'];
    final identity = fund['symbol'];
    if (code != symbol ||
        (identity != null && identity is! String) ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim() == symbol ||
        name.length > 160 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('基金目录返回的身份与查询不一致');
    }
    RegExpMatch? currency;
    if (identity is String && identity.isNotEmpty && identity != symbol) {
      currency = RegExp(
        '^${RegExp.escape(symbol)}\\.([A-Z]{3})\$',
      ).firstMatch(identity);
      if (currency == null) {
        throw const FormatException('基金目录返回的份额标识与查询不一致');
      }
    }
    return [
      FundIdentityCandidate(
        isin: symbol,
        name: name.trim(),
        shareClass: _shareClass(name),
        currencyCode: currency?[1],
        sourceName: '老虎社区 / Tiger Community',
        sourceUrl: sourceUrl,
      ),
    ];
  }

  /// 只从名称的明确份额标记提取类别；不按基金公司、ISIN 或币种猜填。
  static String? _shareClass(String name) {
    final classes = <String>{};
    for (final pattern in [
      r'\bClass\s+([A-Z][A-Z0-9-]{0,11})\b',
      r'([A-Z][A-Z0-9-]{0,11})\s*[类類]',
      // 已观察到的中文“基金A 美元”结构，类别必须紧贴“基金”，不能将 USD 当类别。
      r'基金([A-Z][0-9]{0,2})\s+(?:美元|港元|港币|港幣|人民币|人民幣|欧元|歐元|英镑|英鎊|日元|澳元|加元|瑞郎|新加坡元)$',
      // 已观察到的国际名称如 "A" (EUR) INC；普通引号词不是份额类别。
      r'''["“]([A-Z][0-9]{0,2})["”]\s*\([A-Z]{3}\)\s+(?:ACC|INC|DIST)(?:\s|$)''',
    ]) {
      for (final match in RegExp(pattern).allMatches(name)) {
        classes.add(match[1]!);
      }
    }
    return classes.length == 1 ? classes.single : null;
  }

  /// 对 textarea 的 HTML 转义只解码一层，保持 JSON 字符串中的原始实体含义。
  static String _decodeEntities(String value) => value.replaceAllMapped(
    RegExp(r'&(?:quot|amp|apos|lt|gt|nbsp|#[0-9]{1,7}|#x[0-9a-fA-F]{1,6});'),
    (match) {
      final entity = match[0]!;
      const named = {
        '&quot;': '"',
        '&amp;': '&',
        '&apos;': "'",
        '&lt;': '<',
        '&gt;': '>',
        '&nbsp;': ' ',
      };
      if (named.containsKey(entity)) return named[entity]!;
      final hex = entity.startsWith('&#x');
      final point = int.tryParse(
        entity.substring(hex ? 3 : 2, entity.length - 1),
        radix: hex ? 16 : 10,
      );
      if (point == null ||
          point > 0x10ffff ||
          (point >= 0xd800 && point <= 0xdfff)) {
        throw const FormatException('基金目录包含无效文本编码');
      }
      return String.fromCharCode(point);
    },
  );

  /// 仅提取 [html] 内已核对的基金名称、ISIN 份额行及其币种，绝不执行脚本。
  /// 资料页含过时价格，本方法只取价格行明确标注的份额币种，完全不读取数值或日期。
  /// [symbol] 必须精确命中 ISIN 表；无法证明份额币种时返回空列表，不按名称猜测。
  static List<FundIdentityCandidate> _parseCms(
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
      FundIdentityCandidate(
        isin: symbol,
        name: '$expectedName Class $shareClass',
        shareClass: shareClass,
        currencyCode: currencyCode,
        sourceName: '招商证券资产管理 / CMS Asset Management',
        sourceUrl: Uri.https('www.cmschina.com.hk', '/en/AM/FundProduct', {
          'view': currencyCode == 'USD' ? 'NPCF' : 'CMMF',
        }),
      ),
    ];
  }

  /// 仅解析惠理 [html] 内 vpmm 对应的香港美元货币基金表，匹配精确 [symbol]。
  /// 基金根据香港法律成立的信托身份已由官方 KFS 核对；不扩展到目录中的其他基金：
  /// https://www.valuepartners-group.com/ftp/files/reports/vpmm/006_kfs/eng/vpmm_kfs_2025-08-11_en.pdf
  /// 每行以独立 Currency 列核对 [currencyCode]，不把基金名中的 USD 当成所有份额币种。
  static List<FundIdentityCandidate> _parseValuePartners(
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
      FundIdentityCandidate(
        isin: symbol,
        name: '$fundName - ${cells[0]}',
        shareClass: _shareClass(cells[0]),
        currencyCode: currencyCode,
        sourceName: '惠理 / Value Partners',
        sourceUrl: Uri.https(
          'www.valuepartners-group.com',
          '/en/products-services/funds/',
        ),
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
