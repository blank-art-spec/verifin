/// 美股期权公开代码的语法解析；不查询挂牌状态，也不确认用户合约交割条款。
library;

import '../models/option_contract.dart';

/// 标准字母根语法不从裸根推断类别股点号；明确关系由 matchesUsOptionUnderlying 核对。
/// 本地自动解析仍不扩展数字调整根或其他市场。
const usOptionSymbolPattern = r'([A-Z]{1,6})(\d{6})([CP])(\d{8})';

/// 完整代码可以解析，但调用方明确提供的标的与合约根不一致。
/// 独立类型让表单保留“身份冲突”错误，不能当作非标准手填代码忽略。
class UsOptionUnderlyingMismatchException extends FormatException {
  /// 不把用户输入写入错误文本；界面须使用既有本地化身份冲突提示。
  const UsOptionUnderlyingMismatchException() : super('期权合约根与已明确的标的不一致');
}

/// 校验已明确的 [underlyingSymbol] 能否对应公开期权 [root]，不反推或补造标的。
/// 两者须为规范大写代码；普通根精确匹配，已知 .A/.B 类别允许去点后的根。
/// [allowAdjustedRoot] 仅供已保存合约沿用人工确认的数字调整根关系；草稿默认关闭。
/// 此函数只核对身份语法，不证明挂牌、乘数、交割条款或当前报价可用。
bool matchesUsOptionUnderlying(
  String root,
  String underlyingSymbol, {
  bool allowAdjustedRoot = false,
}) {
  if (!RegExp(r'^[A-Z][A-Z0-9.]{0,5}$').hasMatch(root) ||
      !RegExp(r'^[A-Z][A-Z0-9.]{0,9}$').hasMatch(underlyingSymbol)) {
    return false;
  }
  if (root == underlyingSymbol) return true;
  if (RegExp(r'^[A-Z]{1,5}\.[AB]$').hasMatch(underlyingSymbol) &&
      root == underlyingSymbol.replaceFirst('.', '')) {
    return true;
  }
  return allowAdjustedRoot && RegExp(r'\d').hasMatch(root);
}

/// 解析完整 [symbol] 的公开身份；日期必须真实存在、行权价必须为正，TEST 不外查。
/// 返回的 strikeThousandths 保留代码中的精确整数，不经浮点换算；不替用户确认规格。
/// 返回的 underlyingSymbol 是代码字母根，实际类别股关系须由明确标的另行匹配。
({
  String underlyingSymbol,
  String expiry,
  OptionRight right,
  BigInt strikeThousandths,
})?
parseUsOptionSymbol(String symbol) {
  if (symbol.startsWith('TEST')) return null;
  final match = RegExp('^$usOptionSymbolPattern\$').firstMatch(symbol);
  if (match == null) return null;
  final date = match[2]!;
  final year = 2000 + int.parse(date.substring(0, 2));
  final month = int.parse(date.substring(2, 4));
  final day = int.parse(date.substring(4, 6));
  final expiry = DateTime.utc(year, month, day);
  final strike = BigInt.parse(match[4]!);
  if (expiry.year != year ||
      expiry.month != month ||
      expiry.day != day ||
      strike <= BigInt.zero) {
    return null;
  }
  return (
    underlyingSymbol: match[1]!,
    expiry: '$year-${date.substring(2, 4)}-${date.substring(4, 6)}',
    right: match[3] == 'C' ? OptionRight.call : OptionRight.put,
    strikeThousandths: strike,
  );
}
