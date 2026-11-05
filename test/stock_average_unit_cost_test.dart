import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_decimal.dart';
import 'package:verifin/app/investments/stock_projection.dart';

void main() {
  test('碎股现金舍入产生的均价尾数收敛，保持相同的已存总成本', () {
    final cost = InvestmentDecimal.parse('567.60');
    final quantity = InvestmentDecimal.parse('1.7');
    final average = stockAverageUnitCost(cost, quantity, cashDigits: 2)!;
    expect(average.toString(), '333.88');
    expect(average.moneyProduct(quantity, 2).compareTo(cost), 0);
    expect(cost.toString(), '567.6');
  });

  for (final sample in [
    (cost: '341', quantity: '3', digits: 2, expected: '113.667'),
    (cost: '30.86', quantity: '2.5', digits: 2, expected: '12.344'),
    (cost: '123456.78', quantity: '1000000', digits: 2, expected: '0.12345678'),
    (
      cost: '333123456.78',
      quantity: '1000000',
      digits: 2,
      expected: '333.12345678',
    ),
    (cost: '31', quantity: '2.5', digits: 0, expected: '12.4'),
    (cost: '567.597', quantity: '1.7', digits: 3, expected: '333.8806'),
    (cost: '0', quantity: '1.7', digits: 2, expected: '0'),
  ]) {
    test('按现金精度${sample.digits}保留必要均价 ${sample.expected}', () {
      final cost = InvestmentDecimal.parse(sample.cost);
      final quantity = InvestmentDecimal.parse(sample.quantity);
      final average = stockAverageUnitCost(
        cost,
        quantity,
        cashDigits: sample.digits,
      )!;
      expect(average.toString(), sample.expected);
      expect(average.moneyProduct(quantity, sample.digits).compareTo(cost), 0);
    });
  }

  test('旧总额无法在八位内反乘还原时保留原有近似，不修改总额', () {
    final cost = InvestmentDecimal.parse('1.01');
    final quantity = InvestmentDecimal.parse('10000000');
    final average = stockAverageUnitCost(cost, quantity, cashDigits: 2)!;
    expect(average.toString(), '0.0000001');
    expect(average.moneyProduct(quantity, 2).toString(), '1');
    expect(cost.toString(), '1.01');
    expect(
      stockAverageUnitCost(
        InvestmentDecimal.parse('0.12345678'),
        InvestmentDecimal.parse('1'),
        cashDigits: 2,
      )?.toString(),
      '0.12345678',
    );
  });

  test('未知、极小碎股和超范围均价仍沿用既有边界', () {
    final one = InvestmentDecimal.parse('1');
    expect(stockAverageUnitCost(null, one, cashDigits: 2), isNull);
    expect(
      stockAverageUnitCost(one, InvestmentDecimal.zero, cashDigits: 2),
      isNull,
    );
    expect(stockAverageUnitCost(one, -one, cashDigits: 2), isNull);
    expect(
      stockAverageUnitCost(
        InvestmentDecimal.parse('0.01'),
        InvestmentDecimal.parse('100000000'),
        cashDigits: 2,
      )?.toString(),
      '0',
    );
    expect(
      stockAverageUnitCost(
        InvestmentDecimal.parse('10000'),
        InvestmentDecimal.parse('0.00000001'),
        cashDigits: 2,
      ),
      isNull,
    );
  });
}
