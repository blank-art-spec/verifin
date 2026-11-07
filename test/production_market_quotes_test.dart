import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/cms_fund_quote_adapter.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/nasdaq_option_quote_adapter.dart';
import 'package:verifin/app/investments/production_market_quotes.dart';
import 'package:verifin/app/investments/tencent_quote_adapter.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

const _stock = StockSecurity(
  symbol: '00700',
  name: '腾讯控股',
  market: StockMarket.hk,
  currencyCode: 'HKD',
);
const _fund = StockSecurity(
  symbol: CmsFundQuoteAdapter.supportedIsin,
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
final _time = DateTime.utc(2026, 10, 28, 2, 41, 45);

/// 固定持仓只供本地传输测试，后备价与采用选择不会因查询自动修改。
InvestmentPortfolio _holding(StockSecurity security) => InvestmentPortfolio(
  accountId: 'production-source-${security.currencyCode}',
  bookId: defaultLedgerBookId,
  currencyCode: security.currencyCode,
  openedAt: DateTime.utc(2026, 10, 1),
  openingCash: '1000',
  securities: [security],
  openingHoldings: [
    StockHolding(
      securityId: security.id,
      short: false,
      quantity: '2',
      cost: '600',
    ),
  ],
  manualPrices: {security.id: '300'},
);

/// 读取既有真实响应夹具，测试不会向来源发出任何网络请求。
List<int> _bytes(String name) =>
    File('test/fixtures/investments/$name').readAsBytesSync();

/// 捕获工厂实际适配器的地址，按用例返回本地字节或延迟响应。
class _StockTransport implements TencentQuoteTransport {
  _StockTransport(this.respond);
  final FutureOr<List<int>> Function() respond;
  final requests = <Uri>[];
  bool closed = false;

  @override
  Future<TencentQuoteResponse> get(Uri uri) async {
    requests.add(uri);
    return TencentQuoteResponse(
      statusCode: 200,
      body: Stream.value(await respond()),
    );
  }

  @override
  void close() => closed = true;
}

/// 记录固定基金地址及正文，保留真实解析器与净值历史校验。
class _FundTransport implements CmsFundQuoteTransport {
  final requests = <({Uri uri, String body})>[];
  bool closed = false;

  @override
  Future<CmsFundQuoteResponse> post(Uri uri, List<int> body) async {
    requests.add((uri: uri, body: utf8.decode(body)));
    return CmsFundQuoteResponse(
      statusCode: 200,
      body: Stream.value(_bytes('cms_usd_money_market_20261028.json')),
    );
  }

  @override
  void close() => closed = true;
}

void main() {
  useTestDatabases();

  test('主应用无参数接入固定来源，通用控制器仍为空且未授权', () async {
    final client = buildProductionMarketQuoteClient();
    expect(client.hasAvailableSources, isTrue);
    expect(client.adapters, hasLength(3));
    expect(
      client.adapterFor(MarketQuoteRequest(_stock)),
      isA<TencentQuoteAdapter>(),
    );
    expect(
      client.adapterFor(MarketQuoteRequest(_fund)),
      isA<CmsFundQuoteAdapter>(),
    );
    expect(client.adapterFor(MarketQuoteRequest(optionFixture())), isNull);
    expect(
      client.adapterFor(
        MarketQuoteRequest.usOptionSymbol('AVGO261109C00265000'),
      ),
      isA<NasdaqOptionQuoteAdapter>(),
    );
    expect(client.hasApprovedSources, isFalse);
    expect(const MarketQuoteClient().adapters, isEmpty);
    final controller = await makeController();
    addTearDown(controller.dispose);
    expect(controller.investmentQuoteSync.client.adapters, isEmpty);
    expect(controller.investmentQuoteSync.state.value.enabled, isFalse);
  });

  for (final security in [_stock, _fund]) {
    test('${security.symbol} 默认不联网，授权后通过固定真实解析器获取参考价', () async {
      final stock = _StockTransport(
        () => _bytes('tencent_stocks_20261027.gbk'),
      );
      final fund = _FundTransport();
      var connections = 0;
      final client = buildProductionMarketQuoteClient(
        tencentTransportFactory: () {
          connections++;
          return stock;
        },
        cmsTransportFactory: () {
          connections++;
          return fund;
        },
        clock: () => _time,
      );
      final portfolio = _holding(security);
      final before = portfolio.toJson();
      final sync = InvestmentQuoteSync(
        store: LocalKeyValueStore(),
        client: client,
        clock: () => _time,
      );
      addTearDown(sync.dispose);
      sync.reconcile([portfolio]);
      sync.setVisible(portfolio);
      expect(sync.state.value.enabled, isFalse);
      expect(sync.state.value.automatic, isFalse);
      expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
      expect(connections, 0);

      expect(await sync.configure(enabled: true, automatic: false), isTrue);
      expect(connections, 0);
      expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
      expect(connections, 1);
      final quote = sync.quotesFor(portfolio)[security.id]!;
      expect(quote.currency, security.currencyCode);
      expect(quote.fetchedAt, _time);
      if (security.isFund) {
        expect(quote.last, '109.8150');
        expect(quote.lastAt, DateTime.utc(2026, 10, 27));
        expect(quote.dateOnly, isTrue);
        expect(quote.unit, QuotePriceUnit.fundUnit);
        expect(quote.navHistory!.points.last.price, quote.last);
        expect(
          fund.requests.single.uri.toString(),
          'https://cms.cmschina.com.hk/api/v1/fund/netVal-info',
        );
        expect(fund.requests.single.body, CmsFundQuoteAdapter.requestBody);
        expect(fund.closed, isTrue);
        expect(stock.requests, isEmpty);
      } else {
        expect(quote.last, '386.6');
        expect(quote.lastAt, DateTime.utc(2026, 10, 27, 2, 19, 17));
        expect(quote.unit, QuotePriceUnit.share);
        expect(
          stock.requests.single.toString(),
          'https://qt.gtimg.cn/q=hk00700',
        );
        expect(stock.closed, isTrue);
        expect(fund.requests, isEmpty);
      }
      expect(portfolio.toJson(), before);
      expect(await sync.configure(enabled: false, automatic: false), isTrue);
      expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
      expect(connections, 1);
    });
  }

  test('工厂接入不会放宽响应身份校验，错误代码保留手填后备价', () async {
    final stock = _StockTransport(
      () => gbk.encode(
        gbk
            .decode(_bytes('tencent_stocks_20261027.gbk'))
            .replaceFirst('腾讯控股~00700~', '腾讯控股~00005~'),
      ),
    );
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: buildProductionMarketQuoteClient(
        tencentTransportFactory: () => stock,
        clock: () => _time,
      ),
      clock: () => _time,
    );
    addTearDown(sync.dispose);
    final portfolio = _holding(_stock);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(portfolio.manualPrices[_stock.id], '300');
    expect(stock.closed, isTrue);
  });

  test('请求进行中关闭联网，晚到的公开响应不进入缓存', () async {
    final pending = Completer<List<int>>();
    final started = Completer<void>();
    final stock = _StockTransport(() {
      started.complete();
      return pending.future;
    });
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: buildProductionMarketQuoteClient(
        tencentTransportFactory: () => stock,
        clock: () => _time,
      ),
      clock: () => _time,
    );
    addTearDown(sync.dispose);
    final portfolio = _holding(_stock);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    final refreshing = sync.refresh(portfolio, isCurrent: () => true);
    await started.future;
    expect(await sync.configure(enabled: false, automatic: false), isTrue);
    pending.complete(_bytes('tencent_stocks_20261027.gbk'));
    expect(await refreshing, isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(portfolio.manualPrices[_stock.id], '300');
    expect(stock.closed, isTrue);
  });
}
