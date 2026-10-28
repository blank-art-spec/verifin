/// 基金按金额买入和已有持仓录入的精确预览；不联网、不确认交易、不改写实际现金。
library;

import '../currency_catalog.dart';
import 'investment_decimal.dart';

/// 两个金额入口共同返回的精确量价结果；只是输入预览，不代表券商已经确认份额。
sealed class FundAmountResult {
  /// [details] 由本文件的共同计算入口生成，包含已校验的币种、净值、份额和差额。
  /// 构造保持私有，防止调用方跳过现金精度、正数和溢出校验后伪造计算结果。
  FundAmountResult._(_FundQuantityFields details)
    : currencyCode = details.currencyCode,
      quantityDigits = details.quantityDigits,
      navText = details.navText,
      nav = details.nav,
      estimatedQuantity = details.estimatedQuantity,
      confirmedQuantity = details.confirmedQuantity,
      quantity = details.quantity,
      pricedAmount = details.pricedAmount,
      roundingDifference = details.roundingDifference,
      exactPriceAmount = details.exactPriceAmount,
      exactDifference = details.exactDifference;

  /// 规范化的原币代码，以及本次明确选择的份额小数位数（0 至 8）。
  final String currencyCode;
  final int quantityDigits;

  /// [navText] 保留去除首尾空白后的净值原文和尾零；[nav] 用于八位精确运算。
  final String navText;
  final InvestmentDecimal nav;

  /// [estimatedQuantity] 是目标净金额除以净值后的参考份额，不等于券商确认份额。
  /// [confirmedQuantity] 仅在调用方明确提供时存在；[quantity] 优先采用该确认值。
  final InvestmentDecimal estimatedQuantity, quantity;
  final InvestmentDecimal? confirmedQuantity;

  /// 采用份额乘净值后，直接按原币最小单位四舍五入的量价金额。
  /// 不能用该值覆盖用户输入的实际总扣款、期初成本或报告市值。
  final InvestmentDecimal pricedAmount;

  /// 目标净金额或目标市值减去 [pricedAmount]；正数表示目标金额较大。
  /// 它按现金精度表达，确认份额与金额不匹配时必须由调用方展示并处理。
  final InvestmentDecimal roundingDifference;

  /// 采用份额和净值的十六位精确乘积，以及目标金额减该乘积的精确差额文本。
  /// 即使差额小于一分钱或超出八位小数，仍保留而不伪装成完全相等；无指数和负零。
  final String exactPriceAmount, exactDifference;

  /// 仅表示调用方提供了确认份额；不能据此推断成交、资金扣款或分红已经发生。
  bool get quantityConfirmed => confirmedQuantity != null;
}

/// 按总扣款和确认净值反推基金份额的精确预览，实际总扣款始终保留输入值。
final class FundPurchaseAmountResult extends FundAmountResult {
  /// [cashAmount] 为实际总扣款，[fee] 为其中费用，[netAmount] 为用于申购的净金额。
  /// [details] 是共同的份额与量价差额结果；这里只组合结果，不再次舍入现金。
  FundPurchaseAmountResult._({
    required this.cashAmount,
    required this.fee,
    required this.netAmount,
    required _FundQuantityFields details,
  }) : super._(details);

  final InvestmentDecimal cashAmount, fee, netAmount;
}

/// 从已有持仓成本、报告浮盈及对应净值反推参考份额；浮盈不是一笔收入。
final class FundOpeningAmountResult extends FundAmountResult {
  /// [cost] 为原币成本，[reportedUnrealized] 为用户报告的未实现盈亏，
  /// [marketValue] 为二者之和；[details] 用于显示反推份额与确认份额之间的金额差异。
  FundOpeningAmountResult._({
    required this.cost,
    required this.reportedUnrealized,
    required this.marketValue,
    required _FundQuantityFields details,
  }) : super._(details);

  final InvestmentDecimal cost, reportedUnrealized, marketValue;
}

/// 按含费总扣款计算参考申购份额，返回值不会自动创建成交或改变真实扣款。
///
/// [cashAmount] 是原币实际总扣款，[fee] 是已包含在总扣款内的非负费用；二者都必须
/// 符合 [currencyCode] 的最小现金单位，超精度拒绝而非静默舍入，等值尾零允许保留。
/// 净申购额为总扣款减费用，必须大于零。所有金额及净值使用精确十进制文本。
///
/// [nav] 应是对应成交确认日的每份净值，不在本函数查找或假定为最新净值。
/// [quantityDigits] 决定参考份额的四舍五入精度，允许 0 至 8 位，默认 8 位。
/// [confirmedQuantity] 可由券商后续确认值覆盖参考份额，但同样要求正数且不超份额精度。
/// 金额与量价不一致时返回明确差额，不能调整 [cashAmount] 来掩盖差异。
FundPurchaseAmountResult calculateFundPurchaseByAmount({
  required String cashAmount,
  required String nav,
  required String currencyCode,
  String fee = '0',
  int quantityDigits = 8,
  String? confirmedQuantity,
}) {
  final currency = _fundCashCurrency(currencyCode);
  final cash = _fundCashValue(cashAmount, currency.digits, '总扣款金额');
  final expense = _fundCashValue(fee, currency.digits, '申购费用');
  if (cash.units <= BigInt.zero ||
      expense.units < BigInt.zero ||
      expense.compareTo(cash) >= 0) {
    throw const FormatException('总扣款须大于零，费用须非负且小于总扣款');
  }
  final net = cash - expense;
  return FundPurchaseAmountResult._(
    cashAmount: cash,
    fee: expense,
    netAmount: net,
    details: _calculateFundQuantity(
      targetAmount: net,
      navText: nav,
      currencyCode: currency.code,
      cashDigits: currency.digits,
      quantityDigits: quantityDigits,
      confirmedQuantity: confirmedQuantity,
    ),
  );
}

/// 按已有持仓的成本与报告浮盈计算参考市值及份额，不把浮盈写作收入。
///
/// [cost] 是已经发生的原币成本，可为零但不能为负；[reportedUnrealized] 是同一原币的
/// 未实现盈亏，可正可负，也接受显式正号，例如 `+1.20`。两者都必须符合 [currencyCode]
/// 的现金精度，和得到的目标市值必须大于零且不溢出既有十二位整数范围。
///
/// [nav] 必须与报告浮盈的观察日期对应；仅凭已经四舍五入的浮盈反推的份额仍为参考值。
/// [quantityDigits] 控制 0 至 8 位份额精度，[confirmedQuantity] 用于券商确认份额核对。
/// 确认份额改变时保留原始成本、报告浮盈与目标市值，通过差额展示不一致，不默默改账。
FundOpeningAmountResult calculateFundOpeningByUnrealized({
  required String cost,
  required String reportedUnrealized,
  required String nav,
  required String currencyCode,
  int quantityDigits = 8,
  String? confirmedQuantity,
}) {
  final currency = _fundCashCurrency(currencyCode);
  final principal = _fundCashValue(cost, currency.digits, '持仓成本');
  final profit = _fundCashValue(
    reportedUnrealized,
    currency.digits,
    '报告未实现盈亏',
    allowPlus: true,
  );
  if (principal.units < BigInt.zero) {
    throw const FormatException('持仓成本不能为负数');
  }
  final marketValue = principal + profit;
  _requireFundAmountRange(marketValue, '持仓市值');
  if (marketValue.units <= BigInt.zero) {
    throw const FormatException('成本与未实现盈亏之和必须大于零');
  }
  return FundOpeningAmountResult._(
    cost: principal,
    reportedUnrealized: profit,
    marketValue: marketValue,
    details: _calculateFundQuantity(
      targetAmount: marketValue,
      navText: nav,
      currencyCode: currency.code,
      cashDigits: currency.digits,
      quantityDigits: quantityDigits,
      confirmedQuantity: confirmedQuantity,
    ),
  );
}

/// 供两个结果共用的已校验量价字段，避免两个入口采用不同的精度或差额方向。
typedef _FundQuantityFields = ({
  String currencyCode,
  int quantityDigits,
  String navText,
  InvestmentDecimal nav,
  InvestmentDecimal estimatedQuantity,
  InvestmentDecimal? confirmedQuantity,
  InvestmentDecimal quantity,
  InvestmentDecimal pricedAmount,
  InvestmentDecimal roundingDifference,
  String exactPriceAmount,
  String exactDifference,
});

/// 从离线目录解析 [code] 的规范代码和现金精度；未知币种不回退为美元。
/// 当前八位十进制模型无法表示的币种精度明确拒绝，避免未来扩展目录时静默降精度。
({String code, int digits}) _fundCashCurrency(String code) {
  final currency = CurrencyCatalog.find(code);
  if (currency == null || currency.minorUnit < 0 || currency.minorUnit > 8) {
    throw const FormatException('基金金额的币种或现金精度不受支持');
  }
  return (code: currency.code, digits: currency.minorUnit);
}

/// 严格读取 [text] 为原币现金；[digits] 是币种最小单位，[label] 用于中文校验提示。
/// [allowPlus] 只为报告浮盈接受显式正号，不扩展净值、金额与份额的普通数字语法。
/// 等值尾零不改变金额精度；确有更小现金单位的非零数字时拒绝，不替用户改变实际金额。
InvestmentDecimal _fundCashValue(
  String text,
  int digits,
  String label, {
  bool allowPlus = false,
}) {
  var normalized = text.trim();
  if (allowPlus && normalized.startsWith('+')) {
    normalized = normalized.substring(1);
    if (normalized.startsWith('-') || normalized != normalized.trim()) {
      throw FormatException('$label 不能混用正负号或在符号后插入空白');
    }
  }
  final value = InvestmentDecimal.parse(normalized);
  _requireFundAmountRange(value, label);
  if (value.rounded(digits).compareTo(value) != 0) {
    throw FormatException('$label 超过该币种的现金精度');
  }
  return value;
}

/// 统一核对 [value] 的精确绝对值须小于一万亿元或一万亿份；[label] 标识错误字段。
/// 运算后的 BigInt 可能超过输入解析上限，必须再次验证，不能等显示时才失败或转为无穷值。
void _requireFundAmountRange(InvestmentDecimal value, String label) {
  final limit = BigInt.from(1000000000000) * InvestmentDecimal.scale;
  if (value.units.abs() >= limit) {
    throw FormatException('$label 超出十二位整数的支持范围');
  }
}

/// 用已校验的正 [targetAmount] 除以 [navText]，按 [quantityDigits] 求参考份额。
/// [currencyCode]/[cashDigits] 仅控制现金结果的单位与舍入，不改变净值精度。
/// [confirmedQuantity] 存在时采用确认值算量价，同时仍保留反推份额和所有原始目标金额。
/// 两个八位定点数的乘积以十六位 BigInt 保存，再分别生成现金金额和完整残差文本。
_FundQuantityFields _calculateFundQuantity({
  required InvestmentDecimal targetAmount,
  required String navText,
  required String currencyCode,
  required int cashDigits,
  required int quantityDigits,
  required String? confirmedQuantity,
}) {
  if (quantityDigits < 0 || quantityDigits > 8) {
    throw const FormatException('基金份额精度须为零至八位小数');
  }
  final nav = InvestmentDecimal.parse(navText);
  if (nav.units <= BigInt.zero) {
    throw const FormatException('基金确认净值必须大于零');
  }
  final estimated = targetAmount.allocated(
    InvestmentDecimal.parse('1'),
    nav,
    quantityDigits,
  );
  _requireFundAmountRange(estimated, '参考份额');
  if (estimated.units <= BigInt.zero) {
    throw const FormatException('申购金额在当前份额精度下不足一个有效单位');
  }
  final confirmed = confirmedQuantity == null
      ? null
      : InvestmentDecimal.parse(confirmedQuantity);
  if (confirmed != null &&
      (confirmed.units <= BigInt.zero ||
          confirmed.rounded(quantityDigits).compareTo(confirmed) != 0)) {
    throw const FormatException('确认份额须为正数且符合所选份额精度');
  }
  final quantity = confirmed ?? estimated;
  final priced = quantity.moneyProduct(nav, cashDigits);
  _requireFundAmountRange(priced, '份额与净值的量价金额');
  final difference = targetAmount - priced;
  _requireFundAmountRange(difference, '量价金额差额');
  final exactProduct = quantity.units * nav.units;
  final exactDifference =
      targetAmount.units * InvestmentDecimal.scale - exactProduct;
  return (
    currencyCode: currencyCode,
    quantityDigits: quantityDigits,
    navText: navText.trim(),
    nav: nav,
    estimatedQuantity: estimated,
    confirmedQuantity: confirmed,
    quantity: quantity,
    pricedAmount: priced,
    roundingDifference: difference,
    exactPriceAmount: _fundScaledText(exactProduct, 16),
    exactDifference: _fundScaledText(exactDifference, 16),
  );
}

/// 将 [units] 视为缩放 [digits] 位的精确整数，生成不含指数、负零或多余尾零的文本。
/// 此处用于十六位量价乘积及差额，不能先压成八位 InvestmentDecimal 再格式化。
String _fundScaledText(BigInt units, int digits) {
  final scale = BigInt.from(10).pow(digits);
  final absolute = units.abs();
  final integer = absolute ~/ scale;
  final fraction = (absolute % scale)
      .toString()
      .padLeft(digits, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${units.isNegative ? '-' : ''}$integer${fraction.isEmpty ? '' : '.$fraction'}';
}
