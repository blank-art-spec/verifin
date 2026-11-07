import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';

/// 仅用于测试未知源时间的显式语义，不代表真实市场价格或真实来源许可。
MarketQuote _unknownQuote(
  StockSecurity security,
  DateTime fetchedAt, {
  String price = '4',
  bool unknown = true,
  DateTime? lastAt,
  String? bid,
}) => MarketQuote(
  securityId: security.id,
  source: '本地测试夹具',
  currency: security.currencyCode,
  unit: security.option != null
      ? QuotePriceUnit.premiumUnit
      : security.isFund
      ? QuotePriceUnit.fundUnit
      : QuotePriceUnit.share,
  fetchedAt: fetchedAt,
  last: price,
  lastAt: lastAt,
  bid: bid,
  sourceTimeUnknown: unknown,
);

void main() {
  setUpAll(sqfliteFfiInit);

  test('显式未知时间期权可作参考，缓存保留 null 而非抓取时间', () {
    final security = optionFixture();
    final now = DateTime.utc(2026, 11, 7);
    final request = MarketQuoteRequest(security);
    final quote = _unknownQuote(security, now);
    final value = quote.reference(request, now)!;
    expect(value.price, '4');
    expect(value.time, isNull);
    expect(value.midpoint, isFalse);
    expect(quote.sourceTimeUnknown, isTrue);
    expect(quote.lastAt, isNull);
    final restored = MarketQuote.fromJson(quote.toJson());
    expect(restored.sourceTimeUnknown, isTrue);
    expect(restored.fetchedAt, now);
    expect(restored.reference(request, now)!.time, isNull);
  });

  test('未知标记不放宽股票基金和原有缺时间验证，不接受伪造源时间或零价', () {
    final security = optionFixture();
    final now = DateTime.utc(2026, 11, 7);
    final request = MarketQuoteRequest(security);
    for (final quote in [
      _unknownQuote(security, now, unknown: false),
      _unknownQuote(security, now, lastAt: now),
      _unknownQuote(security, now, bid: '3'),
      _unknownQuote(security, now, price: '0'),
      _unknownQuote(security, now, price: '-1'),
      _unknownQuote(security, now.add(const Duration(minutes: 6))),
    ]) {
      expect(quote.reference(request, now), isNull);
    }
    const fund = StockSecurity(
      symbol: 'HK0000000001',
      name: '本地基金',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    for (final other in [avgoFixture, fund]) {
      expect(
        _unknownQuote(other, now).reference(MarketQuoteRequest(other), now),
        isNull,
      );
    }
  });

  test('旧历史价格事实默认保留已知时间，不添加新字段', () {
    final json = <String, Object?>{
      'price': '12.50',
      'quotedAt': '2026-11-06T18:00:00.000Z',
      'source': '原有来源',
      'manual': false,
    };
    final fact = InvestmentPriceFact.fromJson(json);
    expect(fact.sourceTimeUnknown, isFalse);
    expect(fact.fetchedAt, isNull);
    expect(fact.toJson(), json);
  });

  test('未知期权报价的历史依据经 SQLite 冷启动及 v18 备份保留真实未知', () async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repository = SqliteLedgerRepository(db);
    final security = optionFixture();
    final fetchedAt = DateTime.now().toUtc();
    final adapter = FixtureQuoteAdapter(
      (_) async => [_unknownQuote(security, fetchedAt)],
      support: (request) => request.securityId == security.id,
    );
    var controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repository,
      marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
    );
    try {
      final account = investmentAccountFixture();
      controller.addAccount(account);
      await controller.waitForPendingWrites();
      expect(
        await controller.enableInvestment(
          accountId: account.id,
          openingCash: '10000',
          openedAt: DateTime(2026, 10, 1),
          securities: [avgoFixture, security],
          openingHoldings: [
            StockHolding(
              securityId: security.id,
              short: false,
              quantity: '1',
              cost: '200',
            ),
          ],
          manualPrices: {security.id: '2'},
        ),
        isTrue,
      );
      final sync = controller.investmentQuoteSync;
      await sync.configure(enabled: true, automatic: false);
      final portfolio = controller.investmentFor(account.id)!;
      sync.setVisible(portfolio);
      expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
      expect(
        await controller.setInvestmentMarketPrice(
          account.id,
          security.id,
          true,
        ),
        isTrue,
      );
      expect(controller.accountAssetValue(account), 10400);
      expect(await controller.captureInvestmentValuation(account.id), isTrue);
      final saved = controller
          .investmentFor(account.id)!
          .valuationSnapshots
          .single;
      final fact = saved.prices[security.id]!;
      expect(fact.price, '4');
      expect(fact.quotedAt, isNull);
      expect(fact.sourceTimeUnknown, isTrue);
      expect(fact.fetchedAt, fetchedAt);
      expect(fact.manual, isFalse);
      expect(
        controller.investmentFor(account.id)!.manualPrices[security.id],
        '2',
      );
      final serialized = saved.toJson();
      controller.dispose();
      controller = await VeriFinController.create(
        LocalKeyValueStore(),
        repository: repository,
      );
      expect(
        controller
            .investmentFor(account.id)!
            .valuationSnapshots
            .single
            .toJson(),
        serialized,
      );
      final raw = controller.exportDataJson();
      expect((jsonDecode(raw) as Map)['version'], 18);
      controller.importDataJson(raw, dryRun: true);
      controller.importDataJson(raw);
      await controller.waitForPendingWrites();
      final restored = (await repository.loadInvestmentPortfolios())
          .single
          .valuationSnapshots
          .single;
      expect(restored.toJson(), serialized);
      // Controller 只接收当前聚合内的快照实例；仓储冷读对象用于验证落库内容。
      final currentSnapshot = controller
          .investmentFor(account.id)!
          .valuationSnapshots
          .single;
      expect(
        controller
            .investmentSnapshotValuation(account.id, currentSnapshot)!
            .amounts!
            .net,
        10400,
      );

      for (final mutation in <void Function(Map)>[
        (value) => value.remove('sourceTimeUnknown'),
        (value) => value.remove('fetchedAt'),
        (value) => value['quotedAt'] = fetchedAt.toIso8601String(),
        (value) => value['manual'] = true,
        (value) => value['dateOnly'] = true,
        (value) => value['fetchedAt'] = fetchedAt
            .add(const Duration(days: 1))
            .toIso8601String(),
      ]) {
        final invalid = jsonDecode(raw) as Map;
        final importedData = invalid['data'] as Map;
        final importedPortfolios = importedData['investmentPortfolios'] as List;
        final importedPortfolio = importedPortfolios.single as Map;
        final importedSnapshots =
            importedPortfolio['valuationSnapshots'] as List;
        final importedSnapshot = importedSnapshots.single as Map;
        final importedPrices = importedSnapshot['prices'] as Map;
        final importedFact = importedPrices[security.id] as Map;
        mutation(importedFact);
        expect(
          () => controller.importDataJson(jsonEncode(invalid), dryRun: true),
          throwsFormatException,
        );
        expect(
          controller
              .investmentFor(account.id)!
              .valuationSnapshots
              .single
              .toJson(),
          serialized,
        );
      }
    } finally {
      controller.dispose();
      await db.close();
    }
  });
}
