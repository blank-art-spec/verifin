/// 美股期权公开代码的语法解析；不查询挂牌状态，也不确认用户合约交割条款。
library;

import '../models/option_contract.dart';

/// 沿用已接入行情来源的标准字母根范围，不扩展调整根、类别股或其他市场。
const usOptionSymbolPattern = r'([A-Z]{1,6})(\d{6})([CP])(\d{8})';

/// 解析完整 [symbol] 的公开身份；日期必须真实存在、行权价必须为正，TEST 不外查。
/// 返回的 strikeThousandths 保留代码中的精确整数，不经浮点换算；不替用户确认规格。
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
