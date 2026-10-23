/// 用户确认的期权合约资料；不从股票代码或行情响应推断真实交割规格。
library;

import '../../l10n/app_localizations.dart';

enum OptionRight {
  call,
  put;

  /// 返回认购/认沽的本地化名称，不将多空方向混入合约身份。
  String label(AppLocalizations l) => this == call ? l.optionCall : l.optionPut;
}

enum OptionSettlement {
  physical,
  cash,
  unsupported;

  /// [unsupported] 保留非标准篮子等资料，禁止系统猜测或保存部分交割腿。
  String label(AppLocalizations l) => switch (this) {
    physical => l.optionPhysical,
    cash => l.optionCashSettlement,
    unsupported => l.optionUnsupported,
  };
}

/// 一份原币合约的权利及规格；静态资料与实际成交、冻结保证金分别保存。
class OptionContract {
  /// [underlyingId] 引用同账户的股票定义；[expiry] 是用户确认的 YYYY-MM-DD 到期交易日。
  /// [premiumMultiplier] 是每单位权利金乘数；[deliverableShares] 与 [exerciseCash]
  /// 分别是每张实际交割股数及行权现金总额，调整合约不能用行权价乘交割股数猜现金。
  /// [specification] 保留核对依据或待补事项；只有 [confirmed] 才允许结算。
  const OptionContract({
    required this.underlyingId,
    required this.expiry,
    required this.right,
    required this.strike,
    required this.premiumMultiplier,
    required this.settlement,
    this.deliverableShares = '0',
    this.exerciseCash = '0',
    this.specification = '',
    this.confirmed = false,
  });

  final String underlyingId, expiry, strike, premiumMultiplier;
  final String deliverableShares, exerciseCash, specification;
  final OptionRight right;
  final OptionSettlement settlement;
  final bool confirmed;

  /// 导出明确的用户输入，乘数、股数及行权现金绝不经 double 往返。
  Map<String, Object?> toJson() => {
    'underlyingId': underlyingId,
    'expiry': expiry,
    'right': right.name,
    'strike': strike,
    'premiumMultiplier': premiumMultiplier,
    'settlement': settlement.name,
    'deliverableShares': deliverableShares,
    'exerciseCash': exerciseCash,
    'specification': specification,
    'confirmed': confirmed,
  };

  /// 严格读取已保存规格；未知权利或结算类型不能回退为标准美股合约。
  factory OptionContract.fromJson(Map<String, Object?> json) => OptionContract(
    underlyingId: json['underlyingId'] as String,
    expiry: json['expiry'] as String,
    right: OptionRight.values.byName(json['right'] as String),
    strike: json['strike'] as String,
    premiumMultiplier: json['premiumMultiplier'] as String,
    settlement: OptionSettlement.values.byName(json['settlement'] as String),
    deliverableShares: json['deliverableShares'] as String,
    exerciseCash: json['exerciseCash'] as String,
    specification: json['specification'] as String,
    confirmed: json['confirmed'] as bool,
  );
}
