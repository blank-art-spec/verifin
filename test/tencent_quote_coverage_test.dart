import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/tencent_quote_adapter.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/timezone_database.dart';

final _observedAt = DateTime.utc(2026, 11, 9, 8);

/// 创建公开证券请求；[symbol] 保留完整代码，[market] 与 [currency] 明确实际市场、币种。
/// 本文件沿用交易所证券的股票入口，不把交易所成交价当作场外基金单位净值。
MarketQuoteRequest _request(
  String symbol, {
  StockMarket market = StockMarket.us,
  String currency = 'USD',
}) => MarketQuoteRequest(
  StockSecurity(
    symbol: symbol,
    name: '不向行情来源发送的名称',
    market: market,
    currencyCode: currency,
  ),
);

/// 读取 [name] 指定的本轮原始 GBK 夹具；调用处只传入仓库内固定文件名。
/// 返回字节与真实响应一致，不联网、不改写历史报价或来源时间。
List<int> _fixture(String name) =>
    File('test/fixtures/investments/${name}_20261109.gbk').readAsBytesSync();

/// 合并本轮美港、优先股、内地三份真实响应，用于核对混合批次的独立身份。
/// 每份原始文件均以换行结尾，拼接不会改变任一证券的字段或编码。
List<int> _allFixtureBytes() => [
  ..._fixture('tencent_us_hk'),
  ..._fixture('tencent_us_preferred'),
  ..._fixture('tencent_mainland'),
];

/// 修改真实响应中 [queryCode] 对应行的单个字段，构造明确的拒收边界。
/// [fieldIndex] 是腾讯字段位置，[replacement] 仅用于离线故障注入，不声称为市场事实。
List<int> _changedField(String queryCode, int fieldIndex, String replacement) =>
    gbk.encode(
      gbk
          .decode(_allFixtureBytes())
          .split(RegExp(r'\r?\n'))
          .map((line) {
            if (!line.startsWith('v_$queryCode="')) return line;
            final fields = line
                .substring(line.indexOf('"') + 1, line.lastIndexOf('"'))
                .split('~');
            fields[fieldIndex] = replacement;
            return 'v_$queryCode="${fields.join('~')}";';
          })
          .join('\n'),
    );

/// 只返回本地字节的传输替身，记录实际查询地址以防代码、市场或隐私字段被改写。
class _FixtureTransport implements TencentQuoteTransport {
  /// [bytes] 为固定公开响应，读取时仍通过流交给适配器执行原有校验。
  _FixtureTransport(this.bytes);

  final List<int> bytes;
  final uris = <Uri>[];
  bool closed = false;

  /// 保存 [uri] 后返回 HTTP 成功字节流；不会创建网络连接。
  @override
  Future<TencentQuoteResponse> get(Uri uri) async {
    uris.add(uri);
    return TencentQuoteResponse(statusCode: 200, body: Stream.value(bytes));
  }

  /// 标记本批资源已释放，用于检查成功及缺价路径都结束连接生命周期。
  @override
  void close() => closed = true;
}

/// 构造固定观察时间的适配器；[transport] 只负责提供本地原始响应。
TencentQuoteAdapter _adapter(_FixtureTransport transport) =>
    TencentQuoteAdapter(
      transportFactory: () => transport,
      clock: () => _observedAt,
    );

/// 在真正创建 HTTP 请求前终止的替身，专门检查生产传输的地址白名单。
class _GuardClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  final uris = <Uri>[];

  /// 能到达 [uri] 表示已通过生产白名单；随后抛出固定离线异常，保证绝不联网。
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    uris.add(uri);
    throw StateError('白名单检查已通过，离线测试停止连接');
  }

  /// 本替身没有真实连接；[force] 只为满足生产传输关闭接口。
  @override
  void close({bool force = false}) {}

  /// 未实现成员不应被本组测试访问；[invocation] 交由默认行为明确报错。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 注册已证实覆盖遗漏及边界检查，全部引用公开响应夹具，不访问真实网络。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTimezoneDatabase);

  test('AM 普通股、PS ADR、短横线优先股及港股 ETF 采用各自真实成交价', () async {
    final transport = _FixtureTransport(_allFixtureBytes());
    final adapter = _adapter(transport);
    final expected = {
      _request('UEC'): '6.92',
      _request('BTG'): '5.4',
      _request('TCEHY'): '53.66',
      _request('SPY'): '735.29',
      _request('BRK.B'): '570.89',
      _request('BAC-L'): '1144.05',
      _request('02800', market: StockMarket.hk, currency: 'HKD'): '24.64',
      _request('03033', market: StockMarket.hk, currency: 'HKD'): '3.976',
    };
    for (final request in expected.keys) {
      expect(adapter.supports(request), isTrue, reason: request.symbol);
    }
    final quotes = await adapter.fetch(expected.keys.toList());
    final byId = {for (final quote in quotes) quote.securityId: quote};
    expect(quotes, hasLength(expected.length));
    for (final item in expected.entries) {
      final quote = byId[item.key.securityId]!;
      expect(quote.last, item.value, reason: item.key.symbol);
      expect(quote.currency, item.key.currency);
      expect(quote.unit, QuotePriceUnit.share);
      expect(quote.lastAt, isNotNull);
      expect(quote.fetchedAt, _observedAt);
      expect(quote.reference(item.key, _observedAt)?.price, item.value);
    }
    expect(
      byId[_request('TCEHY').securityId]!.lastAt,
      DateTime.utc(2026, 11, 6, 21, 0, 1),
    );
    expect(
      transport.uris.single.toString(),
      'https://qt.gtimg.cn/q=usUEC,usBTG,usTCEHY,usSPY,usBRK.B,usBAC-L,hk02800,hk03033',
    );
    expect(transport.closed, isTrue);
  });

  test('沪深 ETF、LOF 与北交所代码保留实际市场身份及 CNY 每份成交价', () async {
    final transport = _FixtureTransport(_fixture('tencent_mainland'));
    final adapter = _adapter(transport);
    const prices = {
      '600026': '17.7',
      '510300': '4.13',
      '588000': '1.327',
      '513100': '2.142',
      '159915': '2.472',
      '159001': '100',
      '161725': '0.583',
      '920076': '12.2',
    };
    final requests = [
      for (final symbol in prices.keys)
        _request(symbol, market: StockMarket.cn, currency: 'CNY'),
    ];
    for (final request in requests) {
      expect(adapter.supports(request), isTrue, reason: request.symbol);
    }
    final quotes = await adapter.fetch(requests);
    final byId = {for (final quote in quotes) quote.securityId: quote};
    expect(quotes, hasLength(prices.length));
    for (final request in requests) {
      final quote = byId[request.securityId]!;
      expect(quote.last, prices[request.symbol]);
      expect(quote.currency, 'CNY');
      expect(quote.unit, QuotePriceUnit.share);
      expect(
        quote.reference(request, _observedAt)?.price,
        prices[request.symbol],
      );
    }
    expect(
      byId[requests.last.securityId]!.lastAt,
      DateTime.utc(2026, 11, 9, 7, 14, 2),
    );
    expect(
      transport.uris.single.path,
      '/q=sh600026,sh510300,sh588000,sh513100,sz159915,sz159001,sz161725,bj920076',
    );
    expect(transport.closed, isTrue);
  });

  test('美港与内地证券同批按完整身份和原币解析，错误币种不发送', () async {
    final transport = _FixtureTransport(_allFixtureBytes());
    final requests = [
      _request('TCEHY'),
      _request('02800', market: StockMarket.hk, currency: 'HKD'),
      _request('510300', market: StockMarket.cn, currency: 'CNY'),
      _request('920076', market: StockMarket.cn, currency: 'CNY'),
      _request('BAC-L', currency: 'HKD'),
      _request('510300', market: StockMarket.cn, currency: 'USD'),
      _request('02800', market: StockMarket.hk, currency: 'USD'),
    ];
    final quotes = await _adapter(transport).fetch(requests);
    expect(
      quotes.map((quote) => quote.securityId),
      unorderedEquals(requests.take(4).map((request) => request.securityId)),
    );
    expect(transport.uris.single.path, '/q=usTCEHY,hk02800,sh510300,bj920076');
  });

  test('扩展场内基金号段不把债券、人民币港股柜台或未知类别当作股票查询', () async {
    final transport = _FixtureTransport(_allFixtureBytes());
    final adapter = _adapter(transport);
    final unsupported = [
      for (final symbol in [
        '100001',
        '110001',
        '120001',
        '130001',
        '190001',
        '900001',
        '519001',
        '519888',
        '521001',
        '522001',
        '523001',
        '524001',
        '580027',
        '582027',
        '520499',
        '506100',
        '508000',
      ])
        _request(symbol, market: StockMarket.cn, currency: 'CNY'),
      _request('80700', market: StockMarket.hk, currency: 'CNY'),
      _request('BAC-LONG'),
      _request('BRK.AA'),
    ];
    for (final request in unsupported) {
      expect(adapter.supports(request), isFalse, reason: request.symbol);
    }
    expect(await adapter.fetch(unsupported), isEmpty);
    expect(transport.uris, isEmpty);
  });

  test('新增代码范围的原生传输白名单保持固定主机且不接收额外后缀', () async {
    final client = _GuardClient();
    final transport = TencentHttpQuoteTransport(client: client);
    final accepted = Uri.parse(
      'https://qt.gtimg.cn/q=sh510300,sz159915,bj920076,usBAC-L,usTCEHY',
    );
    await expectLater(transport.get(accepted), throwsStateError);
    expect(client.uris, [accepted]);
    for (final uri in [
      accepted.replace(host: 'example.com'),
      accepted.replace(query: 'account=private'),
      Uri.parse('https://qt.gtimg.cn/q=usBAC-L.N'),
      Uri.parse('https://qt.gtimg.cn/q=usBAC--L'),
      Uri.parse('https://qt.gtimg.cn/q=usBAC-LONG'),
      Uri.parse('https://qt.gtimg.cn/q=usTCEHY.PS'),
    ]) {
      await expectLater(transport.get(uri), throwsFormatException);
    }
    expect(client.uris, [accepted]);
    transport.close();
  });

  final rejectionCases = [
    for (final sourceType in ['KJ', 'ZQ', 'QZ', 'GP-A', 'GP', ''])
      (
        code: 'sh510300',
        request: _request('510300', market: StockMarket.cn, currency: 'CNY'),
        index: 61,
        value: sourceType,
      ),
    (
      code: 'sz159915',
      request: _request('159915', market: StockMarket.cn, currency: 'CNY'),
      index: 61,
      value: 'KJ',
    ),
    (
      code: 'bj920076',
      request: _request('920076', market: StockMarket.cn, currency: 'CNY'),
      index: 61,
      value: 'ZQ',
    ),
    (code: 'usUEC', request: _request('UEC'), index: 2, value: 'BTG.AM'),
    (code: 'usUEC', request: _request('UEC'), index: 56, value: 'GP-W'),
    (code: 'usUEC', request: _request('UEC'), index: 56, value: ''),
    (
      code: 'usTCEHY',
      request: _request('TCEHY'),
      index: 2,
      value: 'TCEHY.UNKNOWN',
    ),
    (code: 'usTCEHY', request: _request('TCEHY'), index: 35, value: 'HKD'),
    (code: 'usTCEHY', request: _request('TCEHY'), index: 56, value: 'GP-ETF'),
    (code: 'usBAC-L', request: _request('BAC-L'), index: 2, value: 'BAC.N'),
    (
      code: 'bj920076',
      request: _request('920076', market: StockMarket.cn, currency: 'CNY'),
      index: 0,
      value: '51',
    ),
    (
      code: 'sh510300',
      request: _request('510300', market: StockMarket.cn, currency: 'CNY'),
      index: 82,
      value: 'USD',
    ),
    (
      code: 'sz159915',
      request: _request('159915', market: StockMarket.cn, currency: 'CNY'),
      index: 30,
      value: '',
    ),
    (
      code: 'sz161725',
      request: _request('161725', market: StockMarket.cn, currency: 'CNY'),
      index: 3,
      value: '0',
    ),
  ];
  for (final sample in rejectionCases) {
    test(
      '扩展覆盖仍拒绝错误身份、类型、币种或缺价 ${sample.code}/${sample.index}/${sample.value}',
      () async {
        final transport = _FixtureTransport(
          _changedField(sample.code, sample.index, sample.value),
        );
        expect(await _adapter(transport).fetch([sample.request]), isEmpty);
        expect(transport.uris, hasLength(1));
        expect(transport.closed, isTrue);
      },
    );
  }
}
