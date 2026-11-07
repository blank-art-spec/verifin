import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/nasdaq_option_quote_adapter.dart';
import 'package:verifin/app/investments/production_market_quotes.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';

class _NasdaqTransport implements NasdaqOptionQuoteTransport {
  _NasdaqTransport({this.available = true});
  bool available;
  final uris = <Uri>[];
  bool closed = false;

  @override
  Future<NasdaqOptionQuoteResponse> get(Uri uri) async {
    uris.add(uri);
    return NasdaqOptionQuoteResponse(
      statusCode: 200,
      body: Stream.value(
        available
            ? File(
                'test/fixtures/investments/nasdaq_option_detail_20261107.json',
              ).readAsBytesSync()
            : utf8.encode('{"data":null,"status":{"rCode":200}}'),
      ),
    );
  }

  @override
  void close() => closed = true;
}

/// 对应已保存的真实行情身份；数量、成本、乘数和后备价始终只是本地测试事实。
InvestmentPortfolio _nasdaqHolding() {
  final options = [
    for (final right in OptionRight.values)
      StockSecurity(
        symbol: right == OptionRight.call
            ? 'AVGO261109C00265000'
            : 'AVGO261109P00265000',
        name: '私有期权持仓',
        market: StockMarket.us,
        currencyCode: 'USD',
        option: OptionContract(
          underlyingId: avgoFixture.id,
          expiry: '2026-11-09',
          right: right,
          strike: '265',
          premiumMultiplier: right == OptionRight.call ? '100' : '10',
          settlement: OptionSettlement.unsupported,
          specification: '私有规格不发送',
        ),
      ),
  ];
  return InvestmentPortfolio(
    accountId: 'private-option-account',
    bookId: defaultLedgerBookId,
    currencyCode: 'USD',
    openedAt: DateTime.utc(2026, 10, 1),
    openingCash: '43210',
    securities: [avgoFixture, ...options],
    openingHoldings: [
      for (final option in options)
        StockHolding(
          securityId: option.id,
          short: false,
          quantity: '2',
          cost: '1111',
        ),
    ],
    manualPrices: {for (final option in options) option.id: '2'},
  );
}

/// 正式来源使用已保存的真实公开响应，不触达网络。
void main() {
  test('生产期权无需凭证，联网授权后查询并保留手填和真实账务', () async {
    final time = DateTime.utc(2026, 11, 7, 14);
    final transports = <_NasdaqTransport>[];
    final client = buildProductionMarketQuoteClient(
      tencentTransportFactory: () => throw StateError('不应连接股票来源'),
      cmsTransportFactory: () => throw StateError('不应连接基金来源'),
      nasdaqTransportFactory: () {
        final transport = _NasdaqTransport();
        transports.add(transport);
        return transport;
      },
      clock: () => time,
    );
    final portfolio = _nasdaqHolding();
    final before = portfolio.toJson();
    final call = portfolio.securities[1], put = portfolio.securities[2];
    expect(
      client.adapterFor(MarketQuoteRequest(call)),
      isA<NasdaqOptionQuoteAdapter>(),
    );
    final store = LocalKeyValueStore();
    final sync = InvestmentQuoteSync(
      store: store,
      client: client,
      clock: () => time,
    );
    addTearDown(sync.dispose);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(transports, isEmpty);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(transports, isEmpty);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(transports.single.uris, hasLength(1));
    expect(transports.single.closed, isTrue);
    final quotes = sync.quotesFor(portfolio);
    expect(quotes[call.id]!.last, '32.66');
    expect(quotes[put.id]!.last, '0.38');
    for (final quote in quotes.values) {
      expect(quote.source, 'Nasdaq Options');
      expect(quote.lastAt, isNull);
      expect(quote.sourceTimeUnknown, isTrue);
      expect(quote.fetchedAt, time);
    }
    expect(store.read('investment_quote_cache_v1'), contains('Nasdaq Options'));
    expect(portfolio.toJson(), before);
    expect(portfolio.marketPriceIds, isEmpty);
    expect(
      investmentCashBalance(portfolio: portfolio, entries: const []),
      43210,
    );
    final address = transports.single.uris.single.toString();
    for (final private in [portfolio.accountId, '43210', '1111', call.name]) {
      expect(address, isNot(contains(private)));
    }
  });

  test('Nasdaq 未挂牌或无价时保持手填，不需要补填API密钥', () async {
    final transport = _NasdaqTransport(available: false);
    final portfolio = _nasdaqHolding();
    final before = portfolio.toJson();
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: buildProductionMarketQuoteClient(
        tencentTransportFactory: () => throw StateError('不应连接股票来源'),
        cmsTransportFactory: () => throw StateError('不应连接基金来源'),
        nasdaqTransportFactory: () => transport,
      ),
    );
    addTearDown(sync.dispose);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(portfolio.toJson(), before);
    expect(transport.closed, isTrue);
  });

  test('Nasdaq 参考价逐项采用且只乘一次，刷新缺价后恢复手填估值', () async {
    final transport = _NasdaqTransport();
    final client = buildProductionMarketQuoteClient(
      tencentTransportFactory: () => throw StateError('不应连接股票来源'),
      cmsTransportFactory: () => throw StateError('不应连接基金来源'),
      nasdaqTransportFactory: () => transport,
    );
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: client,
    );
    addTearDown(controller.dispose);
    final account = investmentAccountFixture();
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    final fixture = _nasdaqHolding();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: fixture.openingCash,
        openedAt: fixture.openedAt,
        securities: fixture.securities,
        openingHoldings: fixture.openingHoldings,
        manualPrices: fixture.manualPrices,
      ),
      isTrue,
    );
    final call = fixture.securities[1], put = fixture.securities[2];
    final initial = controller.investmentFor(account.id)!;
    final facts = initial.toJson()..remove('marketPriceIds');
    final sync = controller.investmentQuoteSync;
    sync.setVisible(initial);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(await sync.refresh(initial, isCurrent: () => true), isTrue);
    expect(controller.accountAssetValue(account), 43650);
    for (final security in [call, put]) {
      expect(
        await controller.setInvestmentMarketPrice(
          account.id,
          security.id,
          true,
        ),
        isTrue,
      );
    }
    var portfolio = controller.investmentFor(account.id)!;
    expect(controller.pricedInvestmentPortfolio(portfolio).manualPrices, {
      call.id: '32.66',
      put.id: '0.38',
    });
    // 43210 + 2 张 × 100 × 32.66 + 2 张 × 10 × 0.38。
    expect(controller.accountAssetValue(account), 49749.6);
    expect(controller.accountBalance(account), 43210);
    transport.available = false;
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    portfolio = controller.investmentFor(account.id)!;
    expect(controller.accountAssetValue(account), 43650);
    expect(controller.pricedInvestmentPortfolio(portfolio).manualPrices, {
      call.id: '2',
      put.id: '2',
    });
    expect(portfolio.toJson()..remove('marketPriceIds'), facts);
  });
}
