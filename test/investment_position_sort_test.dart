import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_decimal.dart';
import 'package:verifin/app/investments/investment_position_sort.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 构造相互独立的本地证券身份；[symbol] 是测试标识，不向真实行情来源发送。
/// [fund] 为 true 时使用真实基金类型，以核对份额与股票共用估值的行为。
StockSecurity _security(String symbol, {bool fund = false}) => StockSecurity(
  symbol: symbol,
  name: '持仓排序示例 $symbol',
  market: fund ? StockMarket.hk : StockMarket.us,
  currencyCode: 'USD',
  type: fund ? InvestmentSecurityType.fund : InvestmentSecurityType.stock,
);

/// 构造已重放的单项持仓；[cost] 为剩余总成本或空头净开仓所得，null 明确表示未知。
/// [quantity] 为精确股数、份额或期权张数；[short] 决定盈亏方向，不改变数量的正号。
StockPosition _position(
  StockSecurity security, {
  String quantity = '1',
  String? cost,
  bool short = false,
}) => StockPosition(
  security.id,
  short,
  InvestmentDecimal.parse(quantity),
  cost == null ? null : InvestmentDecimal.parse(cost),
);

/// 将固定证券与参考价装入隔离组合；[prices] 的键为证券 ID，省略键表示缺价。
/// 仅为只读排序提供身份和价格，不生成交易、账户现金变化或网络请求。
InvestmentPortfolio _portfolio(
  List<StockSecurity> securities,
  Map<String, String> prices,
) => InvestmentPortfolio(
  accountId: 'sort-account',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime(2026, 10, 1),
  openingCash: '0',
  securities: securities,
  manualPrices: prices,
);

/// 验证排序方向、未知值、稳定性及股票、基金、期权的同一估值口径。
/// 无参数、无返回值；全部使用固定事实，运行时不会访问用户数据或真实行情。
void main() {
  test('四种金额排序保留盈亏正负号，空头市值按正回补义务比较', () {
    final lossSecurity = _security('LOSS');
    final gainSecurity = _security('GAIN');
    final shortSecurity = _security('SHORT');
    final zeroSecurity = _security('ZERO');
    final loss = _position(lossSecurity, cost: '250');
    final gain = _position(gainSecurity, cost: '250');
    final short = _position(shortSecurity, cost: '400', short: true);
    final zero = _position(zeroSecurity, cost: '50');
    final original = [loss, short, gain, zero];
    final portfolio = _portfolio(
      [lossSecurity, gainSecurity, shortSecurity, zeroSecurity],
      {
        lossSecurity.id: '100',
        gainSecurity.id: '300',
        shortSecurity.id: '200',
        zeroSecurity.id: '50',
      },
    );
    final expected = {
      InvestmentPositionSortOrder.marketValueDesc: [gain, short, loss, zero],
      InvestmentPositionSortOrder.marketValueAsc: [zero, loss, short, gain],
      InvestmentPositionSortOrder.unrealizedDesc: [short, gain, zero, loss],
      InvestmentPositionSortOrder.unrealizedAsc: [loss, zero, gain, short],
    };
    for (final entry in expected.entries) {
      expect(
        sortedInvestmentPositions(portfolio, original, entry.key),
        entry.value,
        reason: entry.key.name,
      );
    }
    expect(original, [loss, short, gain, zero]);
    expect(loss.quantity.toString(), '1');
    expect(loss.cost.toString(), '250');
    expect(portfolio.manualPrices[lossSecurity.id], '100');
  });

  test('默认顺序返回独立列表，空持仓在所有选项下均为空', () {
    final security = _security('ORIGINAL');
    final position = _position(security);
    final original = [position];
    final portfolio = _portfolio([security], {});
    final sorted = sortedInvestmentPositions(
      portfolio,
      original,
      InvestmentPositionSortOrder.original,
    );
    expect(sorted, original);
    expect(identical(sorted, original), isFalse);
    sorted.clear();
    expect(original, [position]);
    for (final order in InvestmentPositionSortOrder.values) {
      expect(sortedInvestmentPositions(portfolio, [], order), isEmpty);
    }
  });

  test('缺价与未知成本始终置尾，已知零值不按未知值处理', () {
    final noPriceSecurity = _security('NO-PRICE');
    final noCostSecurity = _security('NO-COST');
    final zeroSecurity = _security('KNOWN-ZERO');
    final noPrice = _position(noPriceSecurity, cost: '10');
    final noCost = _position(noCostSecurity);
    final zero = _position(zeroSecurity, cost: '0');
    final original = [noPrice, noCost, zero];
    final portfolio = _portfolio(
      [noPriceSecurity, noCostSecurity, zeroSecurity],
      {noCostSecurity.id: '10', zeroSecurity.id: '0'},
    );
    expect(
      sortedInvestmentPositions(
        portfolio,
        original,
        InvestmentPositionSortOrder.marketValueAsc,
      ),
      [zero, noCost, noPrice],
    );
    expect(
      sortedInvestmentPositions(
        portfolio,
        original,
        InvestmentPositionSortOrder.marketValueDesc,
      ),
      [noCost, zero, noPrice],
    );
    for (final order in [
      InvestmentPositionSortOrder.unrealizedAsc,
      InvestmentPositionSortOrder.unrealizedDesc,
    ]) {
      expect(sortedInvestmentPositions(portfolio, original, order), [
        zero,
        noPrice,
        noCost,
      ]);
    }
    expect(valueStockPosition(portfolio, noPrice).marketValue, isNull);
    expect(valueStockPosition(portfolio, noPrice).unrealized, isNull);
    expect(valueStockPosition(portfolio, noCost).marketValue.toString(), '10');
    expect(valueStockPosition(portfolio, noCost).unrealized, isNull);
  });

  test('相等金额与全部未知金额均按原顺序排列', () {
    final securities = [
      for (var index = 0; index < 40; index++) _security('TIE-$index'),
    ];
    final positions = [
      for (final security in securities) _position(security, cost: '10'),
    ];
    final known = _portfolio(securities, {
      for (final security in securities) security.id: '12',
    });
    final unknown = _portfolio(securities, {});
    for (final order in InvestmentPositionSortOrder.values) {
      expect(sortedInvestmentPositions(known, positions, order), positions);
      expect(sortedInvestmentPositions(unknown, positions, order), positions);
    }
  });

  test('碎股份额先按现金精度估值，排序不比较未经舍入的量价乘积', () {
    final firstSecurity = _security('FIRST');
    final secondSecurity = _security('SECOND');
    final thirdSecurity = _security('THIRD');
    final first = _position(firstSecurity, quantity: '0.50000001', cost: '0');
    final second = _position(secondSecurity, quantity: '0.49999999', cost: '0');
    final third = _position(thirdSecurity, quantity: '0.5', cost: '0');
    final portfolio = _portfolio(
      [firstSecurity, secondSecurity, thirdSecurity],
      {
        firstSecurity.id: '0.01',
        secondSecurity.id: '0.01',
        thirdSecurity.id: '0.01',
      },
    );
    expect(valueStockPosition(portfolio, first).marketValue.toString(), '0.01');
    expect(valueStockPosition(portfolio, second).marketValue.toString(), '0');
    expect(valueStockPosition(portfolio, third).marketValue.toString(), '0.01');
    expect(
      sortedInvestmentPositions(portfolio, [
        third,
        second,
        first,
      ], InvestmentPositionSortOrder.marketValueDesc),
      [third, first, second],
    );
  });

  test('基金份额与非标准乘数期权沿用同一市值和盈亏口径', () {
    final option = optionFixture(multiplier: '25');
    final fund = _security('FUND', fund: true);
    final stock = _position(avgoFixture, cost: '60');
    final optionShort = _position(
      option,
      quantity: '2',
      cost: '70',
      short: true,
    );
    final fundLong = _position(fund, quantity: '4', cost: '4');
    final portfolio = _portfolio(
      [avgoFixture, option, fund],
      {avgoFixture.id: '65', option.id: '1.2345', fund.id: '1.005'},
    );
    final optionValue = valueStockPosition(portfolio, optionShort);
    final fundValue = valueStockPosition(portfolio, fundLong);
    expect(optionValue.marketValue.toString(), '61.73');
    expect(optionValue.unrealized.toString(), '8.27');
    expect(fundValue.marketValue.toString(), '4.02');
    expect(fundValue.unrealized.toString(), '0.02');
    expect(
      sortedInvestmentPositions(portfolio, [
        optionShort,
        fundLong,
        stock,
      ], InvestmentPositionSortOrder.marketValueDesc),
      [stock, optionShort, fundLong],
    );
    expect(
      sortedInvestmentPositions(portfolio, [
        stock,
        fundLong,
        optionShort,
      ], InvestmentPositionSortOrder.unrealizedDesc),
      [optionShort, stock, fundLong],
    );
  });

  test('采用的新参考价改变展示顺序，原组合与持仓不被覆写', () {
    final firstSecurity = _security('FIRST-PRICE');
    final secondSecurity = _security('SECOND-PRICE');
    final first = _position(firstSecurity, cost: '10');
    final second = _position(secondSecurity, cost: '10');
    final portfolio = _portfolio(
      [firstSecurity, secondSecurity],
      {firstSecurity.id: '12', secondSecurity.id: '15'},
    );
    final repriced = portfolio.copyWith(
      manualPrices: {firstSecurity.id: '20', secondSecurity.id: '15'},
      marketPriceIds: {firstSecurity.id},
    );
    final positions = [first, second];
    for (final order in [
      InvestmentPositionSortOrder.marketValueDesc,
      InvestmentPositionSortOrder.unrealizedDesc,
    ]) {
      expect(sortedInvestmentPositions(portfolio, positions, order), [
        second,
        first,
      ]);
      expect(sortedInvestmentPositions(repriced, positions, order), [
        first,
        second,
      ]);
    }
    expect(portfolio.manualPrices[firstSecurity.id], '12');
    expect(first.cost.toString(), '10');
    expect(positions, [first, second]);
  });

  test('账户汇总复用单项估值后仍保留多空净额和未知成本语义', () {
    final longSecurity = _security('LONG-SUM');
    final shortSecurity = _security('SHORT-SUM');
    final portfolio =
        _portfolio(
          [longSecurity, shortSecurity],
          {longSecurity.id: '60', shortSecurity.id: '20'},
        ).copyWith(
          openingHoldings: [
            StockHolding(
              securityId: longSecurity.id,
              short: false,
              quantity: '1',
              cost: '50',
            ),
            StockHolding(
              securityId: shortSecurity.id,
              short: true,
              quantity: '1',
              cost: '25',
            ),
          ],
        );
    final projection = projectStocks(portfolio);
    final aggregate = valueStocks(portfolio, projection);
    expect(aggregate.marketValue.toString(), '40');
    expect(aggregate.unrealized.toString(), '15');
    projection.positions.last.cost = null;
    final unknownCost = valueStocks(portfolio, projection);
    expect(unknownCost.marketValue.toString(), '40');
    expect(unknownCost.unrealized, isNull);
    final noPrice = valueStocks(
      portfolio.copyWith(manualPrices: {longSecurity.id: '60'}),
      projection,
    );
    expect(noPrice.marketValue, isNull);
    expect(noPrice.unrealized, isNull);
  });
}
