import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_amount_math.dart';
import 'package:verifin/app/investments/investment_decimal.dart';

/// 109.8290 仅为固定数字夹具，不声称为测试运行日或用户实际确认日的基金净值。
const _fixtureNav = '109.8290';

/// 构造按金额买入的纯预览；[amount] 含 [fee]，不访问行情、Controller 或账目。
FundPurchaseAmountResult _purchase({
  String amount = '1401.31',
  String fee = '0',
  String nav = _fixtureNav,
  String currency = 'USD',
  int digits = 8,
  String? confirmed,
}) => calculateFundPurchaseByAmount(
  cashAmount: amount,
  fee: fee,
  nav: nav,
  currencyCode: currency,
  quantityDigits: digits,
  confirmedQuantity: confirmed,
);

/// 构造已有持仓反推；[profit] 可为负，[confirmed] 只核对份额，不改写成本或报告浮盈。
FundOpeningAmountResult _opening({
  String cost = '1401.31',
  String profit = '+1.20',
  String nav = _fixtureNav,
  String currency = 'USD',
  int digits = 8,
  String? confirmed,
}) => calculateFundOpeningByUnrealized(
  cost: cost,
  reportedUnrealized: profit,
  nav: nav,
  currencyCode: currency,
  quantityDigits: digits,
  confirmedQuantity: confirmed,
);

/// 注册真实金额示例、确认份额差异、各币种精度及非法边界的独立纯计算检查。
void main() {
  test('1401.31美元总扣款按固定确认净值推算参考份额，保留原始净值尾零和全部金额', () {
    final result = _purchase();
    expect(result.currencyCode, 'USD');
    expect(result.cashAmount.toString(), '1401.31');
    expect(result.fee.toString(), '0');
    expect(result.netAmount.toString(), '1401.31');
    expect(result.navText, '109.8290');
    expect(result.nav.toString(), '109.829');
    expect(result.quantityDigits, 8);
    expect(result.estimatedQuantity.toString(), '12.75901629');
    expect(result.quantity.toString(), '12.75901629');
    expect(result.confirmedQuantity, isNull);
    expect(result.quantityConfirmed, isFalse);
    expect(result.pricedAmount.toString(), '1401.31');
    expect(result.roundingDifference.toString(), '0');
    expect(result.exactPriceAmount, '1401.31000011441');
    expect(result.exactDifference, '-0.00000011441');
  });

  test('费用从已含费总扣款中扣除，不额外增加实际扣款', () {
    final result = _purchase(fee: '1');
    expect(result.cashAmount.toString(), '1401.31');
    expect(result.fee.toString(), '1');
    expect(result.netAmount.toString(), '1400.31');
    expect(result.quantity.toString(), '12.74991123');
    expect(result.pricedAmount.toString(), '1400.31');
    expect(result.exactDifference, '-0.00000047967');
    expect((result.netAmount + result.fee).toString(), '1401.31');
  });

  test('1401.31成本与1.20浮盈组成1402.51市值，反推份额仍未确认且不改成本', () {
    final result = _opening();
    expect(result.cost.toString(), '1401.31');
    expect(result.reportedUnrealized.toString(), '1.2');
    expect(result.marketValue.toString(), '1402.51');
    expect(result.estimatedQuantity.toString(), '12.76994236');
    expect(result.quantity.toString(), '12.76994236');
    expect(result.quantityConfirmed, isFalse);
    expect(result.pricedAmount.toString(), '1402.51');
    expect(result.exactPriceAmount, '1402.50999945644');
    expect(result.exactDifference, '0.00000054356');
  });

  test('负未实现盈亏减少目标市值，零成本已知赠与也能表达且不生成虚假本金', () {
    final loss = _opening(profit: '-1.20');
    expect(loss.marketValue.toString(), '1400.11');
    expect(loss.reportedUnrealized.toString(), '-1.2');
    final gift = _opening(cost: '0', profit: '10', nav: '2');
    expect(gift.cost.toString(), '0');
    expect(gift.marketValue.toString(), '10');
    expect(gift.quantity.toString(), '5');
  });

  test('确认份额可覆盖参考份额，现金差额明确保留且实际总扣款不被量价回写', () {
    final result = _purchase(confirmed: '12.77');
    expect(result.estimatedQuantity.toString(), '12.75901629');
    expect(result.confirmedQuantity?.toString(), '12.77');
    expect(result.quantity.toString(), '12.77');
    expect(result.quantityConfirmed, isTrue);
    expect(result.cashAmount.toString(), '1401.31');
    expect(result.netAmount.toString(), '1401.31');
    expect(result.pricedAmount.toString(), '1402.52');
    expect(result.roundingDifference.toString(), '-1.21');
    expect(result.exactPriceAmount, '1402.51633');
    expect(result.exactDifference, '-1.20633');
  });

  test('已有持仓采用确认份额后仍保留报告浮盈，并展示对应市值差异', () {
    final result = _opening(confirmed: '12.77');
    expect(result.quantityConfirmed, isTrue);
    expect(result.marketValue.toString(), '1402.51');
    expect(result.cost.toString(), '1401.31');
    expect(result.reportedUnrealized.toString(), '1.2');
    expect(result.pricedAmount.toString(), '1402.52');
    expect(result.roundingDifference.toString(), '-0.01');
    expect(result.exactDifference, '-0.00633');
  });

  test('确认份额量价落在半分时按现金单位四舍五入，原始半分差额仍可核对', () {
    final result = _purchase(amount: '1', nav: '1.005', confirmed: '1');
    expect(result.cashAmount.toString(), '1');
    expect(result.pricedAmount.toString(), '1.01');
    expect(result.roundingDifference.toString(), '-0.01');
    expect(result.exactPriceAmount, '1.005');
    expect(result.exactDifference, '-0.005');
  });

  test('现金看似相等但量价残差小于八位时仍保留十六位差额，不伪造精确一致', () {
    final result = _purchase(amount: '1', nav: '1.00000001');
    expect(result.quantity.toString(), '0.99999999');
    expect(result.pricedAmount.toString(), '1');
    expect(result.roundingDifference.toString(), '0');
    expect(result.exactPriceAmount, '0.9999999999999999');
    expect(result.exactDifference, '0.0000000000000001');
    expect(
      () => InvestmentDecimal.parse(result.exactDifference),
      throwsFormatException,
    );
  });

  test('份额精度零至八位使用同一精确除法，粗份额造成的现金差额不被丢弃', () {
    final hundredths = _purchase(amount: '1', nav: '3', digits: 2);
    expect(hundredths.quantity.toString(), '0.33');
    expect(hundredths.pricedAmount.toString(), '0.99');
    expect(hundredths.roundingDifference.toString(), '0.01');
    expect(hundredths.exactDifference, '0.01');
    final whole = _purchase(amount: '5', nav: '2', digits: 0);
    expect(whole.quantity.toString(), '3');
    expect(whole.pricedAmount.toString(), '6');
    expect(whole.roundingDifference.toString(), '-1');
    for (var digits = 0; digits <= 8; digits++) {
      final result = _purchase(amount: '10', nav: '2', digits: digits);
      expect(result.quantity.toString(), '5');
      expect(result.quantityDigits, digits);
      expect(result.exactDifference, '0');
    }
  });

  test('JPY零位和KWD三位现金精度分别校验，规范化币种不改变金额', () {
    final yen = _purchase(amount: '101', fee: '1', nav: '3', currency: ' jpy ');
    expect(yen.currencyCode, 'JPY');
    expect(yen.cashAmount.toString(), '101');
    expect(yen.netAmount.toString(), '100');
    expect(yen.pricedAmount.toString(), '100');
    final dinar = _purchase(
      amount: '1.234',
      fee: '0.001',
      nav: '2',
      currency: 'KWD',
    );
    expect(dinar.netAmount.toString(), '1.233');
    expect(dinar.quantity.toString(), '0.6165');
    expect(dinar.pricedAmount.toString(), '1.233');
    final opening = _opening(
      cost: '1.234',
      profit: '-0.001',
      nav: '2',
      currency: 'KWD',
    );
    expect(opening.marketValue.toString(), '1.233');
  });

  test('等值尾零与外层空白允许，负零按普通零输出且不会污染差额符号', () {
    final result = _purchase(
      amount: ' 1.23000000 ',
      fee: '-0.00000000',
      nav: ' 1.2300 ',
    );
    expect(result.cashAmount.toString(), '1.23');
    expect(result.fee.toString(), '0');
    expect(result.navText, '1.2300');
    expect(result.exactDifference, '0');
    expect(
      _opening(
        cost: '1',
        profit: ' +0.00 ',
        nav: '1',
      ).reportedUnrealized.toString(),
      '0',
    );
  });

  for (final call in <String, void Function()>{
    '美元扣款超现金精度': () => _purchase(amount: '1.001'),
    '美元费用超现金精度': () => _purchase(fee: '0.001'),
    '日元小数扣款': () => _purchase(amount: '1.1', currency: 'JPY'),
    '日元小数费用': () => _purchase(fee: '0.1', currency: 'JPY'),
    '科威特币种第四位非零': () => _purchase(amount: '1.2345', currency: 'KWD'),
    '持仓成本超现金精度': () => _opening(cost: '1.001'),
    '浮盈超现金精度': () => _opening(profit: '0.001'),
    '扣款为零': () => _purchase(amount: '0'),
    '扣款为负': () => _purchase(amount: '-1'),
    '费用为负': () => _purchase(fee: '-1'),
    '费用等于总扣款': () => _purchase(amount: '1', fee: '1'),
    '费用大于总扣款': () => _purchase(amount: '1', fee: '2'),
    '负成本': () => _opening(cost: '-1'),
    '市值为零': () => _opening(cost: '1', profit: '-1'),
    '市值为负': () => _opening(cost: '1', profit: '-2'),
    '份额精度负数': () => _purchase(digits: -1),
    '份额精度九位': () => _purchase(digits: 9),
    '零份额精度下不足最小份额': () => _purchase(amount: '1', nav: '100', digits: 0),
    '确认份额为零': () => _purchase(confirmed: '0'),
    '确认份额为负': () => _purchase(confirmed: '-1'),
    '确认份额超出所选精度': () => _purchase(confirmed: '1.001', digits: 2),
    '未知币种': () => _purchase(currency: 'TEST'),
    '空币种': () => _purchase(currency: ''),
    '市值相加溢出': () => _opening(cost: '999999999999.99', profit: '0.01'),
    '份额除法溢出': () => _purchase(amount: '999999999999.99', nav: '0.00000001'),
    '量价乘积溢出': () => _purchase(nav: '999999999999', confirmed: '999999999999'),
  }.entries) {
    test('拒绝${call.key}，不静默改变现金或份额', () {
      expect(call.value, throwsFormatException);
    });
  }

  for (final invalid in [
    '',
    'NaN',
    'Infinity',
    '1e2',
    '1,000',
    '1.123456789',
    '1000000000000',
  ]) {
    test('非法十进制文本明确拒绝：$invalid', () {
      expect(() => _purchase(amount: invalid), throwsFormatException);
      expect(() => _purchase(fee: invalid), throwsFormatException);
      expect(() => _purchase(nav: invalid), throwsFormatException);
      expect(() => _purchase(confirmed: invalid), throwsFormatException);
      expect(() => _opening(cost: invalid), throwsFormatException);
      expect(() => _opening(profit: invalid), throwsFormatException);
    });
  }

  for (final invalid in ['0', '-1']) {
    test('确认净值必须为正：$invalid', () {
      expect(() => _purchase(nav: invalid), throwsFormatException);
      expect(() => _opening(nav: invalid), throwsFormatException);
    });
  }

  for (final invalid in ['+-1', '++1', '+ 1', '+', '-+1']) {
    test('报告浮盈不接受混合符号或内部空白：$invalid', () {
      expect(() => _opening(profit: invalid), throwsFormatException);
    });
  }
}
