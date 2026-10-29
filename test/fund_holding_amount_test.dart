import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_amount_math.dart';

/// 创建已有持仓的只读预览；[quantity] 是用户实际份额，不允许由成本或最新净值代替输入。
/// [cost] 为原币成本，[nav] 为所选净值，[currency] 仅决定市值及浮盈的现金舍入精度。
FundHoldingAmountResult _holding({
  String cost = '1401.31',
  String quantity = '12.77',
  String nav = '109.8290',
  String currency = 'USD',
}) => calculateFundOpeningByQuantity(
  cost: cost,
  quantity: quantity,
  nav: nav,
  currencyCode: currency,
);

/// 验证持仓份额是实际事实，浮盈由份额乘净值减成本得到；不需要手动填写报告盈亏。
void main() {
  test('实际份额与成本及净值直接生成市值和浮盈，无需报告盈亏', () {
    final result = _holding();
    expect(result.currencyCode, 'USD');
    expect(result.cost.toString(), '1401.31');
    expect(result.quantity.toString(), '12.77');
    expect(result.confirmedQuantity?.toString(), '12.77');
    expect(result.quantityConfirmed, isTrue);
    expect(result.navText, '109.8290');
    expect(result.nav.toString(), '109.829');
    expect(result.marketValue.toString(), '1402.52');
    expect(result.pricedAmount.toString(), '1402.52');
    expect(result.unrealized.toString(), '1.21');
    expect(result.exactPriceAmount, '1402.51633');
    expect(
      (result.marketValue - result.cost).toString(),
      result.unrealized.toString(),
    );
  });

  test('净值上涨或下跌只改变市值和浮盈，不根据新净值重新反推实际份额', () {
    final rising = _holding(nav: '110');
    final falling = _holding(nav: '100');
    expect(rising.quantity.toString(), '12.77');
    expect(falling.quantity.toString(), '12.77');
    expect(rising.cost.toString(), '1401.31');
    expect(falling.cost.toString(), '1401.31');
    expect(rising.marketValue.toString(), '1404.7');
    expect(rising.unrealized.toString(), '3.39');
    expect(falling.marketValue.toString(), '1277');
    expect(falling.unrealized.toString(), '-124.31');
    expect(rising.quantityConfirmed, isTrue);
    expect(falling.quantityConfirmed, isTrue);
  });

  test('修改实际成本只改变成本及盈亏，不能从新成本推导新的份额', () {
    final original = _holding(nav: '100');
    final corrected = _holding(nav: '100', cost: '1000');
    expect(corrected.quantity.toString(), original.quantity.toString());
    expect(corrected.marketValue.toString(), original.marketValue.toString());
    expect(corrected.quantity.toString(), '12.77');
    expect(corrected.marketValue.toString(), '1277');
    expect(corrected.unrealized.toString(), '277');
    expect(corrected.quantityConfirmed, isTrue);
  });

  test('零成本已知持仓和负未实现盈亏都可以直接表达，不生成额外本金', () {
    final gift = _holding(cost: '0', quantity: '5', nav: '2');
    expect(gift.cost.toString(), '0');
    expect(gift.marketValue.toString(), '10');
    expect(gift.unrealized.toString(), '10');
    final loss = _holding(cost: '12', quantity: '5', nav: '2');
    expect(loss.cost.toString(), '12');
    expect(loss.marketValue.toString(), '10');
    expect(loss.unrealized.toString(), '-2');
    expect(loss.quantity.toString(), '5');
  });

  test('量价乘积按原币现金精度只舍入一次，实际份额与原始净值仍完整保留', () {
    final halfCent = _holding(cost: '1', quantity: '1', nav: '1.005');
    expect(halfCent.quantity.toString(), '1');
    expect(halfCent.navText, '1.005');
    expect(halfCent.marketValue.toString(), '1.01');
    expect(halfCent.pricedAmount.toString(), '1.01');
    expect(halfCent.unrealized.toString(), '0.01');
    expect(halfCent.exactPriceAmount, '1.005');
    final eightDigits = _holding(
      cost: '1',
      quantity: '0.99999999',
      nav: '1.00000001',
    );
    expect(eightDigits.quantity.toString(), '0.99999999');
    expect(eightDigits.marketValue.toString(), '1');
    expect(eightDigits.unrealized.toString(), '0');
    expect(eightDigits.exactPriceAmount, '0.9999999999999999');
  });

  test('币种控制现金舍入而不限制实际份额的小数位，成本仍须符合原币精度', () {
    final yen = _holding(
      cost: '100',
      quantity: '1',
      nav: '100.5',
      currency: ' jpy ',
    );
    expect(yen.currencyCode, 'JPY');
    expect(yen.marketValue.toString(), '101');
    expect(yen.unrealized.toString(), '1');
    final dinar = _holding(
      cost: '1.234',
      quantity: '1.1111',
      nav: '2',
      currency: 'KWD',
    );
    expect(dinar.quantity.toString(), '1.1111');
    expect(dinar.marketValue.toString(), '2.222');
    expect(dinar.pricedAmount.toString(), '2.222');
    expect(dinar.unrealized.toString(), '0.988');
  });

  test('实际微小份额允许现金舍入市值为零，不能因反推目标为零而丢掉份额', () {
    final result = _holding(
      cost: '0',
      quantity: '0.00000001',
      nav: '0.00000001',
    );
    expect(result.quantity.toString(), '0.00000001');
    expect(result.quantityConfirmed, isTrue);
    expect(result.marketValue.toString(), '0');
    expect(result.pricedAmount.toString(), '0');
    expect(result.unrealized.toString(), '0');
    expect(result.exactPriceAmount, '0.0000000000000001');
  });

  test('等值尾零与外层空白允许，成本和浮盈的负零规范化而不改真实数量', () {
    final result = _holding(
      cost: ' -0.00000000 ',
      quantity: ' 1.00000000 ',
      nav: ' 2.0000 ',
    );
    expect(result.cost.toString(), '0');
    expect(result.quantity.toString(), '1');
    expect(result.navText, '2.0000');
    expect(result.marketValue.toString(), '2');
    expect(result.unrealized.toString(), '2');
    expect(result.quantityConfirmed, isTrue);
  });

  for (final invalid in <String, void Function()>{
    '缺少实际份额时不能按成本净值自动补造': () => _holding(quantity: ''),
    '实际份额为零': () => _holding(quantity: '0'),
    '实际份额为负': () => _holding(quantity: '-1'),
    '实际份额超过八位小数': () => _holding(quantity: '1.000000001'),
    '实际份额使用指数': () => _holding(quantity: '1e2'),
    '实际份额超过十二位整数': () => _holding(quantity: '1000000000000'),
    '成本缺失': () => _holding(cost: ''),
    '成本为负': () => _holding(cost: '-1'),
    '美元成本超现金精度': () => _holding(cost: '1.001'),
    '日元成本带非零小数': () => _holding(cost: '100.1', currency: 'JPY'),
    '三位现金币种成本超精度': () => _holding(cost: '1.2345', currency: 'KWD'),
    '净值缺失': () => _holding(nav: ''),
    '净值为零': () => _holding(nav: '0'),
    '净值为负': () => _holding(nav: '-1'),
    '净值超过八位小数': () => _holding(nav: '1.000000001'),
    '未知币种': () => _holding(currency: 'TEST'),
    '空币种': () => _holding(currency: ''),
    '实际量价乘积溢出': () => _holding(quantity: '999999999999', nav: '999999999999'),
  }.entries) {
    test('拒绝${invalid.key}，不回退为推算份额或零持仓', () {
      expect(invalid.value, throwsFormatException);
    });
  }
}
