import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_decimal.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/amount_format.dart' as amount_format;
import 'package:verifin/app/currency_math.dart';
import 'support/investment_fixture.dart';

void main() {
  test('每股报价保留八位小数，单位跟随偏好且零值无负号', () {
    final oldMultiple = amount_format.activeBookUsesMultipleCurrencies;
    final oldHide = amount_format.hideUnitInSingleCurrency;
    final oldStyle = amount_format.moneyUnitStyle;
    try {
      amount_format.hideUnitInSingleCurrency = true;
      amount_format.activeBookUsesMultipleCurrencies = false;
      expect(formatUserSecurityPrice('0.00000001', 'USD'), '0.00000001');
      expect(formatUserSecurityPrice('-0.00000000', 'USD'), '0');
      amount_format.activeBookUsesMultipleCurrencies = true;
      amount_format.moneyUnitStyle = MoneyUnitStyle.code;
      expect(
        formatUserSecurityPrice('330.12345678', 'USD'),
        'USD 330.12345678',
      );
    } finally {
      amount_format.activeBookUsesMultipleCurrencies = oldMultiple;
      amount_format.hideUnitInSingleCurrency = oldHide;
      amount_format.moneyUnitStyle = oldStyle;
    }
  });
  test('十进制精确量价、对称舍入、非法输入及八位边界', () {
    expect(
      (InvestmentDecimal.parse('0.1') + InvestmentDecimal.parse('0.2'))
          .toString(),
      '0.3',
    );
    expect(InvestmentDecimal.parse('-0.00000000').toString(), '0');
    expect(
      InvestmentDecimal.parse(
        '0.125',
      ).moneyProduct(InvestmentDecimal.parse('80'), 2).toString(),
      '10',
    );
    expect(
      InvestmentDecimal.parse(
        '0.49999999',
      ).moneyProduct(InvestmentDecimal.parse('0.01'), 2).toString(),
      '0',
    );
    expect(InvestmentDecimal.parse('-1.005').rounded(2).toString(), '-1.01');
    for (final invalid in [
      'NaN',
      'Infinity',
      '1e3',
      '0.000000001',
      '1000000000000',
      '',
    ]) {
      expect(() => InvestmentDecimal.parse(invalid), throwsFormatException);
    }
  });

  test('B03 博通买卖费用只扣一次，部分成本保留到分', () {
    final buy = stockEventFixture(
      'buy',
      StockEventKind.buy,
      '10',
      '300',
      fee: '1',
    );
    final sell = stockEventFixture(
      'sell',
      StockEventKind.sell,
      '4',
      '330',
      fee: '1',
      sequence: 2,
      day: 3,
    );
    final p = portfolioFixture(events: [sell, buy]);
    final result = projectStocks(p), value = valueStocks(p, projectStocks(p));
    expect(result.cashMovements['buy'].toString(), '-3001');
    expect(result.cashMovements['sell'].toString(), '1319');
    expect(result.positions.single.quantity.toString(), '6');
    expect(result.positions.single.cost.toString(), '1800.6');
    expect(result.realized.toString(), '118.6');
    expect(value.marketValue.toString(), '1980');
    expect(value.unrealized.toString(), '179.4');
  });

  test('A03 加仓后采用移动加权成本', () {
    final p = portfolioFixture(
      price: '55',
      events: [
        stockEventFixture('a', StockEventKind.buy, '100', '50', fee: '5'),
        stockEventFixture(
          'b',
          StockEventKind.sell,
          '40',
          '55',
          fee: '2',
          sequence: 2,
          day: 3,
        ),
        stockEventFixture(
          'c',
          StockEventKind.buy,
          '20',
          '60',
          fee: '1',
          sequence: 3,
          day: 4,
        ),
      ],
    );
    final projection = projectStocks(p);
    expect(projection.positions.single.quantity.toString(), '80');
    expect(projection.positions.single.cost.toString(), '4204');
    expect(projection.realized.toString(), '196');
    expect(valueStocks(p, projection).unrealized.toString(), '196');
  });

  test('碎股三次平仓释放全部成本，不残留负零', () {
    final result = projectStocks(
      portfolioFixture(
        events: [
          stockEventFixture('a', StockEventKind.buy, '0.125', '80'),
          stockEventFixture(
            'b',
            StockEventKind.sell,
            '0.025',
            '88',
            sequence: 2,
            day: 3,
          ),
          stockEventFixture(
            'c',
            StockEventKind.sell,
            '0.05',
            '88',
            sequence: 3,
            day: 4,
          ),
          stockEventFixture(
            'd',
            StockEventKind.sell,
            '0.05',
            '88',
            sequence: 4,
            day: 5,
          ),
        ],
      ),
    );
    expect(result.positions, isEmpty);
    expect(result.realized.toString(), '1');
  });

  test('未知成本不制造盈利，缺价不算零，空仓结果为零', () {
    final p = portfolioFixture(
      opening: [
        StockHolding(securityId: avgoFixture.id, short: false, quantity: '100'),
      ],
    );
    expect(valueStocks(p, projectStocks(p)).unrealized, isNull);
    final noPrice = p.copyWith(manualPrices: {});
    expect(valueStocks(noPrice, projectStocks(noPrice)).marketValue, isNull);
    expect(
      valueStocks(
        portfolioFixture(),
        projectStocks(portfolioFixture()),
      ).marketValue.toString(),
      '0',
    );
  });

  test('卖空所得与回补义务分开，回补后已实现收益正确', () {
    final p = portfolioFixture(
      price: '55',
      events: [stockEventFixture('a', StockEventKind.shortSell, '10', '50')],
    );
    expect(projectStocks(p).cashMovements['a'].toString(), '500');
    expect(valueStocks(p, projectStocks(p)).marketValue.toString(), '-550');
    expect(valueStocks(p, projectStocks(p)).unrealized.toString(), '-50');
    final closed = p.copyWith(
      events: [
        ...p.events,
        stockEventFixture(
          'b',
          StockEventKind.cover,
          '10',
          '40',
          sequence: 2,
          day: 3,
        ),
      ],
    );
    expect(projectStocks(closed).positions, isEmpty);
    expect(projectStocks(closed).realized.toString(), '100');
  });

  test('股息税费、拆股总成本及比例边界', () {
    final p = portfolioFixture(
      opening: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '100',
          cost: '5000',
        ),
      ],
      price: '25',
      events: [
        stockEventFixture('d', StockEventKind.dividend, '0', '100', fee: '10'),
        stockEventFixture(
          's',
          StockEventKind.split,
          '2',
          '1',
          sequence: 2,
          day: 3,
        ),
      ],
    );
    final projection = projectStocks(p);
    expect(projection.income.toString(), '90');
    expect(projection.positions.single.quantity.toString(), '200');
    expect(projection.positions.single.cost.toString(), '5000');
    expect(projection.cashMovements['s'].toString(), '0');
    expect(
      () => InvestmentDecimal.parse(
        '1',
      ).split(InvestmentDecimal.parse('1'), InvestmentDecimal.parse('3')),
      throwsFormatException,
    );
  });

  test('超量卖出、悬空证券、重复序号及期初前事件拒绝', () {
    expect(
      () => projectStocks(
        portfolioFixture(
          events: [
            stockEventFixture(
              'split-fee',
              StockEventKind.split,
              '2',
              '1',
              fee: '1',
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => projectStocks(
        portfolioFixture(
          events: [stockEventFixture('x', StockEventKind.sell, '1', '2')],
        ),
      ),
      throwsFormatException,
    );
    final a = stockEventFixture('a', StockEventKind.buy, '1', '2');
    expect(
      () => projectStocks(
        portfolioFixture(
          events: [a, stockEventFixture('b', StockEventKind.buy, '1', '2')],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () =>
          projectStocks(portfolioFixture(events: [a]).copyWith(securities: [])),
      throwsFormatException,
    );
    expect(
      () => projectStocks(
        portfolioFixture(
          events: [
            stockEventFixture('early', StockEventKind.buy, '1', '2', day: 0),
          ],
        ),
      ),
      throwsFormatException,
    );
  });
}
