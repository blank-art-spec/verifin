/// 投资数量、报价及金额的精确十进制运算，不经过 double 做成本计算。
library;

/// 使用八位定点整数；现金在写入事件及展示边界再按币种最小单位舍入。
class InvestmentDecimal implements Comparable<InvestmentDecimal> {
  /// 内部构造：仅接受已经缩放八位的整数，外部输入统一使用 [parse]。
  const InvestmentDecimal._(this.units);

  final BigInt units;
  static final BigInt scale = BigInt.from(100000000);
  static final InvestmentDecimal zero = InvestmentDecimal._(BigInt.zero);

  /// 将普通十进制文本转为精确值；最多八位小数、十二位整数，拒绝指数和非有限数。
  /// [text] 可包含正负号及首尾空格；非法格式抛出 FormatException，不静默截断。
  factory InvestmentDecimal.parse(String text) {
    final value = text.trim();
    if (!RegExp(r'^-?\d{1,12}(\.\d{1,8})?$').hasMatch(value)) {
      throw const FormatException('请输入十二位整数、八位小数以内的有效数字');
    }
    final negative = value.startsWith('-');
    final parts = value.replaceFirst('-', '').split('.');
    final fraction = parts.length == 2 ? parts[1].padRight(8, '0') : '00000000';
    final raw = BigInt.parse(parts[0]) * scale + BigInt.parse(fraction);
    return InvestmentDecimal._(negative ? -raw : raw);
  }

  /// 精确相加；[other] 使用相同的八位缩放单位。
  InvestmentDecimal operator +(InvestmentDecimal other) =>
      InvestmentDecimal._(units + other.units);

  /// 精确相减；允许得到负现金或空头盈亏。
  InvestmentDecimal operator -(InvestmentDecimal other) =>
      InvestmentDecimal._(units - other.units);

  /// 返回相反数，零值始终保持普通零。
  InvestmentDecimal operator -() => InvestmentDecimal._(-units);

  /// 比较定点整数，避免碎股数量在 double 转换时出现误判。
  @override
  int compareTo(InvestmentDecimal other) => units.compareTo(other.units);

  /// 按 [digits] 位小数四舍五入；负值采用对称的绝对值舍入。
  InvestmentDecimal rounded(int digits) {
    if (digits < 0 || digits > 8) throw const FormatException('金额精度不合法');
    final quantum = BigInt.from(10).pow(8 - digits);
    return InvestmentDecimal._(_roundedDivide(units, quantum) * quantum);
  }

  /// 精确计算量价乘积后直接舍入至现金精度，避免先截八位产生二次舍入。
  /// [other] 通常为报价，[digits] 为结算币种 minor unit。
  InvestmentDecimal moneyProduct(InvestmentDecimal other, int digits) {
    final quantum = BigInt.from(10).pow(8 - digits);
    return InvestmentDecimal._(
      _roundedDivide(units * other.units, scale * quantum) * quantum,
    );
  }

  /// 按部分数量分摊成本；最后一笔由调用方直接释放全部成本以消除残余。
  InvestmentDecimal allocated(
    InvestmentDecimal part,
    InvestmentDecimal total,
    int digits,
  ) {
    if (total.units <= BigInt.zero) throw const FormatException('分摊总数量必须大于零');
    final quantum = BigInt.from(10).pow(8 - digits);
    return InvestmentDecimal._(
      _roundedDivide(units * part.units, total.units * quantum) * quantum,
    );
  }

  /// 按拆股比例精确换算数量；不可表示为八位小数时要求人工处理零碎股。
  InvestmentDecimal split(
    InvestmentDecimal numerator,
    InvestmentDecimal denominator,
  ) {
    if (numerator.units <= BigInt.zero || denominator.units <= BigInt.zero) {
      throw const FormatException('拆股比例必须大于零');
    }
    final product = units * numerator.units;
    if (product % denominator.units != BigInt.zero) {
      throw const FormatException('拆股后超过八位小数，请先记录零碎股处理');
    }
    return InvestmentDecimal._(product ~/ denominator.units);
  }

  /// 仅用于既有现金/格式化接口的边界；限制金额范围，不把 double 写回权威成本。
  double toDouble() {
    final result = units.toDouble() / scale.toDouble();
    if (!result.isFinite || result.abs() >= 1000000000000) {
      throw const FormatException('投资金额超出支持范围');
    }
    return result == 0 ? 0 : result;
  }

  /// 输出不含指数、负零和多余尾零的文本，直接用于 JSON/SQLite 持久化。
  @override
  String toString() {
    final absolute = units.abs();
    final integer = absolute ~/ scale;
    final fraction = (absolute % scale)
        .toString()
        .padLeft(8, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '${units.isNegative ? '-' : ''}$integer${fraction.isEmpty ? '' : '.$fraction'}';
  }

  /// 带符号的整数四舍五入；[denominator] 必须为正。
  static BigInt _roundedDivide(BigInt numerator, BigInt denominator) {
    final rounded =
        (numerator.abs() + denominator ~/ BigInt.two) ~/ denominator;
    return numerator.isNegative ? -rounded : rounded;
  }
}
