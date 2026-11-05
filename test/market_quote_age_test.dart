import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

void main() {
  final now = DateTime.utc(2026, 11, 5, 12);
  test('旧报价提示依据来源时间而非本次抓取时间，保留休市前可用估值', () {
    final request = MarketQuoteRequest(avgoFixture);
    MarketQuote quote(Duration age) => MarketQuote(
      securityId: avgoFixture.id,
      source: '本地测试',
      currency: 'USD',
      unit: QuotePriceUnit.share,
      fetchedAt: now,
      last: '100',
      lastAt: now.subtract(age),
    );
    expect(
      quote(const Duration(hours: 24)).isOlderThanOneDay(request, now),
      isFalse,
    );
    final old = quote(const Duration(hours: 24, seconds: 1));
    expect(old.isOlderThanOneDay(request, now), isTrue);
    expect(old.reference(request, now)!.price, '100');
    expect(
      quote(const Duration(minutes: -10)).isOlderThanOneDay(request, now),
      isFalse,
    );
  });

  test('期权按被采用双边价格较早时间提示，不能用较新成交时间掩盖旧买卖价', () {
    final security = optionFixture();
    final quote = MarketQuote(
      securityId: security.id,
      source: '本地测试',
      currency: 'USD',
      unit: QuotePriceUnit.premiumUnit,
      fetchedAt: now,
      bid: '2',
      ask: '4',
      bidAt: now.subtract(const Duration(days: 2)),
      askAt: now,
      last: '3.2',
      lastAt: now,
    );
    final request = MarketQuoteRequest(security);
    expect(quote.reference(request, now)!.midpoint, isTrue);
    expect(quote.isOlderThanOneDay(request, now), isTrue);
  });

  test('基金净值日期不误用股票二十四小时提示', () {
    const fund = StockSecurity(
      symbol: 'HK0000000001',
      name: '本地基金',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    final quote = MarketQuote(
      securityId: fund.id,
      source: '本地测试',
      currency: 'USD',
      unit: QuotePriceUnit.fundUnit,
      fetchedAt: now,
      last: '1',
      lastAt: DateTime.utc(2026, 11, 2),
      dateOnly: true,
    );
    expect(quote.isOlderThanOneDay(MarketQuoteRequest(fund), now), isFalse);
  });
}
