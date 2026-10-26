/// 历史参考价格的事实；手填与联网来源分开，不能用今天的价格覆盖。
class InvestmentPriceFact {
  /// [price] 是每股/每权利金单位价格；[quotedAt] 保留原报价时间。
  /// [manual] 为用户手填时 [source] 留空，界面通过本地化显示来源。
  const InvestmentPriceFact({
    required this.price,
    required this.quotedAt,
    this.source = '',
    this.manual = true,
  });
  final String price, source;
  final DateTime quotedAt;
  final bool manual;

  /// 精确价格以文本保存，不复制网络原始响应。
  Map<String, Object?> toJson() => {
    'price': price,
    'quotedAt': quotedAt.toIso8601String(),
    'source': source,
    'manual': manual,
  };

  /// 读取价格事实；完整性约束在聚合校验中统一检查。
  factory InvestmentPriceFact.fromJson(Map<String, Object?> json) =>
      InvestmentPriceFact(
        price: json['price'] as String,
        quotedAt: DateTime.parse(json['quotedAt'] as String),
        source: json['source'] as String,
        manual: json['manual'] as bool,
      );
}

/// 用户主动保存的估值依据，属于 SQLite 权威账目和完整备份范围。
class InvestmentValuationSnapshot {
  /// [capturedAt] 为实际保存时点，[revision] 是截至该时点账务事实的摘要。
  /// [rateToBase]/[rateDate] 固定当时汇率；缺汇率允许保存，但本位币结果不完整。
  InvestmentValuationSnapshot({
    required this.capturedAt,
    required this.revision,
    required this.baseCurrencyCode,
    required Map<String, InvestmentPriceFact> prices,
    this.rateToBase,
    this.rateDate,
  }) : prices = Map.unmodifiable(prices);
  final DateTime capturedAt;
  final String revision, baseCurrencyCode;
  final Map<String, InvestmentPriceFact> prices;
  final double? rateToBase;
  final DateTime? rateDate;

  /// 仅保存依据，不保存可与账务事实不一致的第二份可编辑净值。
  Map<String, Object?> toJson() => {
    'capturedAt': capturedAt.toIso8601String(),
    'revision': revision,
    'baseCurrencyCode': baseCurrencyCode,
    'prices': prices.map((key, value) => MapEntry(key, value.toJson())),
    'rateToBase': rateToBase,
    'rateDate': rateDate?.toIso8601String(),
  };

  /// 从 SQLite/备份还原；旧聚合没有此列表时由所属模型提供空默认值。
  factory InvestmentValuationSnapshot.fromJson(Map<String, Object?> json) =>
      InvestmentValuationSnapshot(
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        revision: json['revision'] as String,
        baseCurrencyCode: json['baseCurrencyCode'] as String,
        rateToBase: (json['rateToBase'] as num?)?.toDouble(),
        rateDate: json['rateDate'] == null
            ? null
            : DateTime.parse(json['rateDate'] as String),
        prices: (json['prices'] as Map).map(
          (key, value) => MapEntry(
            key as String,
            InvestmentPriceFact.fromJson(
              Map<String, Object?>.from(value as Map),
            ),
          ),
        ),
      );
}
