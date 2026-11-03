import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_security_suggestions.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 创建纯数据候选组合；[book]、[currency] 用于验证读取边界，不连接数据库或网络。
InvestmentPortfolio _portfolio(
  String account,
  List<StockSecurity> securities, {
  String book = defaultLedgerBookId,
  String currency = 'USD',
  Map<String, String> prices = const {},
}) => InvestmentPortfolio(
  accountId: account,
  bookId: book,
  currencyCode: currency,
  openedAt: DateTime(2026, 10, 1),
  openingCash: '0',
  securities: securities,
  manualPrices: prices,
);

/// 本地身份排序、跨账本/币种隔离及远端身份合并的纯计算验证。
void main() {
  test('同代码当前账户优先，其他账户不能贡献参考价', () {
    const goog = StockSecurity(
      symbol: 'GOOG',
      name: 'Alphabet',
      market: StockMarket.us,
      currencyCode: 'USD',
    );
    const otherAvgo = StockSecurity(
      symbol: 'avgo',
      name: '其他账户旧名称',
      market: StockMarket.us,
      currencyCode: 'USD',
    );
    final results = collectInvestmentSecuritySuggestions(
      portfolios: [
        _portfolio('other', [otherAvgo, goog], prices: {goog.id: '999'}),
        _portfolio('current', [avgoFixture], prices: {avgoFixture.id: '330'}),
      ],
      bookId: defaultLedgerBookId,
      accountId: 'current',
      currencyCode: 'USD',
      market: StockMarket.us,
      type: InvestmentSecurityType.stock,
    );
    expect(results.map((value) => value.security.symbol), ['AVGO', 'GOOG']);
    expect(results.first.security.name, '博通');
    expect(results.first.referencePrice, '330');
    expect(results.last.referencePrice, isNull);
    expect(
      matchInvestmentSecuritySuggestions(results, ' aV ').single,
      results.first,
    );
    expect(
      matchInvestmentSecuritySuggestions(results, '博通').single,
      results.first,
    );
    expect(
      matchInvestmentSecuritySuggestions(results, 'ALPHA').single,
      results.last,
    );
    expect(matchInvestmentSecuritySuggestions(results, '未知代码'), isEmpty);
  });

  test('严格隔离账本、组合币种、证券币种、市场、品种和期权', () {
    const hk = StockSecurity(
      symbol: '00700',
      name: '腾讯',
      market: StockMarket.hk,
      currencyCode: 'HKD',
    );
    const fund = StockSecurity(
      symbol: 'TEST-FUND',
      name: '基金',
      market: StockMarket.us,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    final portfolios = [
      _portfolio('other-book', [avgoFixture], book: 'other'),
      _portfolio('wrong-portfolio-currency', [avgoFixture], currency: 'HKD'),
      _portfolio('current', [avgoFixture, hk, fund, optionFixture()]),
    ];
    final results = collectInvestmentSecuritySuggestions(
      portfolios: portfolios,
      bookId: defaultLedgerBookId,
      accountId: 'current',
      currencyCode: 'USD',
      market: StockMarket.us,
      type: InvestmentSecurityType.stock,
    );
    expect(results.map((value) => value.security), [avgoFixture]);
    final hongKong = collectInvestmentSecuritySuggestions(
      portfolios: [
        _portfolio('hkd', [hk], currency: 'HKD'),
      ],
      bookId: defaultLedgerBookId,
      accountId: 'hkd',
      currencyCode: 'HKD',
      market: StockMarket.hk,
      type: InvestmentSecurityType.stock,
    );
    expect(hongKong.single.security.symbol, '00700');
  });

  test('远端拼音匹配可展示，去重仍保留本地资料且不引入远端价格', () {
    const remote = StockSecurity(
      symbol: 'AVGO',
      name: 'Broadcom',
      market: StockMarket.us,
      currencyCode: 'USD',
    );
    final results = collectInvestmentSecuritySuggestions(
      portfolios: [
        _portfolio('current', [avgoFixture], prices: {avgoFixture.id: '330'}),
      ],
      bookId: defaultLedgerBookId,
      accountId: 'current',
      currencyCode: 'USD',
      market: StockMarket.us,
      type: InvestmentSecurityType.stock,
      remoteSecurities: [remote],
      remoteQuery: 'bt',
    );
    expect(results, hasLength(1));
    expect(results.single.security.name, '博通');
    expect(results.single.referencePrice, '330');
    expect(matchInvestmentSecuritySuggestions(results, 'bt'), hasLength(1));
    expect(matchInvestmentSecuritySuggestions(results, 'tx'), isEmpty);
  });
}
