/// 联网检索取得的基金身份候选；仅供当前草稿核对，不进入账目或行情缓存。
library;

import '../models/investment.dart';

/// 保留来源明确给出的份额信息；缺失字段保持未知，不能按账户币种补猜。
class FundIdentityCandidate {
  /// [name] 是来源中的完整基金名称，包含其明确列出的份额说明。
  /// [shareClass] 与 [currencyCode] 缺失时仍可展示来源，但不能直接采用。
  const FundIdentityCandidate({
    required this.isin,
    required this.name,
    required this.sourceName,
    required this.sourceUrl,
    this.shareClass,
    this.currencyCode,
  });

  final String isin, name, sourceName;
  final Uri sourceUrl;
  final String? shareClass, currencyCode;

  /// 核对身份可完整表示为现有基金草稿；不将字段完整等同于供应方真实性保证。
  bool get hasCompleteIdentity =>
      RegExp(r'^[A-Z]{2}[A-Z0-9]{9}[0-9]$').hasMatch(isin) &&
      _validText(name, 160) &&
      _validText(shareClass, 160) &&
      currencyCode != null &&
      RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode!) &&
      _validText(sourceName, 160) &&
      sourceUrl.scheme == 'https' &&
      sourceUrl.host.isNotEmpty &&
      sourceUrl.userInfo.isEmpty;

  /// 确认后才转换成身份；[market] 由用户所选市场提供，不从 ISIN 前缀推断。
  StockSecurity toSecurity({required StockMarket market}) {
    if (!hasCompleteIdentity) {
      throw StateError('基金候选资料不完整，不能直接采用');
    }
    return StockSecurity(
      symbol: isin,
      name: name.trim(),
      market: market,
      currencyCode: currencyCode!,
      type: InvestmentSecurityType.fund,
    );
  }

  /// 身份文本沿用手工草稿边界，不允许隐藏控制符或超长名称进入表单。
  static bool _validText(String? text, int maximumLength) =>
      text != null &&
      text.trim().isNotEmpty &&
      text.length <= maximumLength &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(text);
}
