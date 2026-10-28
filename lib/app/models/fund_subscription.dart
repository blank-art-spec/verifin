/// 基金申购的阶段事实；申请、付款、确认和收益起算各自独立，不根据预计日期伪造确认。
library;

/// 已由券商确认的单位净值与份额；确认回执时刻不等于净值日或收益起算日。
class FundSubscriptionConfirmation {
  /// [confirmedAt] 是收到或录入确认回执的真实时刻，可以晚于已经发生的经济生效日。
  /// [navDate]、[earningStartDate] 是香港年月日的 UTC 零点载体，没有日内报价含义。
  /// [nav] 为确认净值原始十进制文本，[quantity] 为确认份额；总成本由所属申购的实际扣款决定。
  const FundSubscriptionConfirmation({
    required this.confirmedAt,
    required this.navDate,
    required this.earningStartDate,
    required this.nav,
    required this.quantity,
  });

  final DateTime confirmedAt, navDate, earningStartDate;
  final String nav, quantity;

  /// 保存已确认事实；真实时刻统一存 UTC，纯日期只保存年月日，不混淆设备时区。
  Map<String, Object?> toJson() => {
    'confirmedAt': confirmedAt.toUtc().toIso8601String(),
    'navDate': fundCalendarDateToJson(navDate),
    'earningStartDate': fundCalendarDateToJson(earningStartDate),
    'nav': nav,
    'quantity': quantity,
  };

  /// 从 SQLite 聚合或备份读取确认；[json] 字段类型错误、假日期或无效时刻直接拒绝。
  factory FundSubscriptionConfirmation.fromJson(Map<String, Object?> json) =>
      FundSubscriptionConfirmation(
        confirmedAt: _requiredInstant(json, 'confirmedAt'),
        navDate: fundCalendarDateFromJson(json['navDate']),
        earningStartDate: fundCalendarDateFromJson(json['earningStartDate']),
        nav: _requiredString(json, 'nav'),
        quantity: _requiredString(json, 'quantity'),
      );
}

/// 一笔申购的不可变阶段事实；付款和退款是同一事实内的实际资金腿，不复制为日常流水。
class FundSubscription {
  /// [id] 为稳定幂等键，[securityId] 必须指向所属投资账户内同币种的基金。
  /// [requestedAt] 是实际申请时刻，[cashAmount] 是实际总扣款金额（包括 [fee]）。
  /// [paidAt] 缺失表示尚未确认扣款；[expectedConfirmationDate] 只作预计，不触发持仓。
  /// [confirmation] 保存实际确认及逐笔收益起算日；已确认申请不可同时取消或退款。
  /// [cancelledAt] 表示申请已撤销；已扣款时仍保留待退款资产，直到 [refundedAt] 实际到账。
  /// [refundAmount] 是实际退回金额，只有退款到账时填写；[note] 为用户自己的说明。
  const FundSubscription({
    required this.id,
    required this.securityId,
    required this.requestedAt,
    required this.cashAmount,
    this.fee = '0',
    this.paidAt,
    this.expectedConfirmationDate,
    this.confirmation,
    this.cancelledAt,
    this.refundedAt,
    this.refundAmount,
    this.note = '',
  });

  final String id, securityId, cashAmount, fee, note;
  final DateTime requestedAt;
  final DateTime? paidAt, expectedConfirmationDate, cancelledAt, refundedAt;
  final String? refundAmount;
  final FundSubscriptionConfirmation? confirmation;

  static const _unchanged = Object();

  /// 返回编辑后的新申请，不修改原对象。
  /// 非空基础参数缺省时保留原值；可空参数不传时保留，明确传 null 时清除该阶段事实。
  /// 例如 `copyWith(paidAt: null)` 只改草稿，能否撤回已确认扣款仍由 Controller 完整校验。
  FundSubscription copyWith({
    String? securityId,
    DateTime? requestedAt,
    String? cashAmount,
    String? fee,
    Object? paidAt = _unchanged,
    Object? expectedConfirmationDate = _unchanged,
    Object? confirmation = _unchanged,
    Object? cancelledAt = _unchanged,
    Object? refundedAt = _unchanged,
    Object? refundAmount = _unchanged,
    String? note,
  }) => FundSubscription(
    id: id,
    securityId: securityId ?? this.securityId,
    requestedAt: requestedAt ?? this.requestedAt,
    cashAmount: cashAmount ?? this.cashAmount,
    fee: fee ?? this.fee,
    paidAt: identical(paidAt, _unchanged) ? this.paidAt : paidAt as DateTime?,
    expectedConfirmationDate: identical(expectedConfirmationDate, _unchanged)
        ? this.expectedConfirmationDate
        : expectedConfirmationDate as DateTime?,
    confirmation: identical(confirmation, _unchanged)
        ? this.confirmation
        : confirmation as FundSubscriptionConfirmation?,
    cancelledAt: identical(cancelledAt, _unchanged)
        ? this.cancelledAt
        : cancelledAt as DateTime?,
    refundedAt: identical(refundedAt, _unchanged)
        ? this.refundedAt
        : refundedAt as DateTime?,
    refundAmount: identical(refundAmount, _unchanged)
        ? this.refundAmount
        : refundAmount as String?,
    note: note ?? this.note,
  );

  /// 导出实际事实及预计日期；不保存可与付款、持仓不一致的第二份余额或当前盈亏。
  Map<String, Object?> toJson() => {
    'id': id,
    'securityId': securityId,
    'requestedAt': requestedAt.toUtc().toIso8601String(),
    'cashAmount': cashAmount,
    'fee': fee,
    if (paidAt != null) 'paidAt': paidAt!.toUtc().toIso8601String(),
    if (expectedConfirmationDate != null)
      'expectedConfirmationDate': fundCalendarDateToJson(
        expectedConfirmationDate!,
      ),
    if (confirmation != null) 'confirmation': confirmation!.toJson(),
    if (cancelledAt != null)
      'cancelledAt': cancelledAt!.toUtc().toIso8601String(),
    if (refundedAt != null) 'refundedAt': refundedAt!.toUtc().toIso8601String(),
    if (refundAmount != null) 'refundAmount': refundAmount,
    'note': note,
  };

  /// 严格读取阶段字段；缺省费用和备注保持兼容，状态与金额关系由聚合校验统一检查。
  factory FundSubscription.fromJson(Map<String, Object?> json) {
    final rawConfirmation = json['confirmation'];
    if (rawConfirmation != null && rawConfirmation is! Map<String, Object?>) {
      throw const FormatException('基金申购确认字段不是有效对象');
    }
    return FundSubscription(
      id: _requiredString(json, 'id'),
      securityId: _requiredString(json, 'securityId'),
      requestedAt: _requiredInstant(json, 'requestedAt'),
      cashAmount: _requiredString(json, 'cashAmount'),
      fee: _optionalString(json, 'fee') ?? '0',
      paidAt: _optionalInstant(json, 'paidAt'),
      expectedConfirmationDate: json['expectedConfirmationDate'] == null
          ? null
          : fundCalendarDateFromJson(json['expectedConfirmationDate']),
      confirmation: rawConfirmation == null
          ? null
          : FundSubscriptionConfirmation.fromJson(
              rawConfirmation as Map<String, Object?>,
            ),
      cancelledAt: _optionalInstant(json, 'cancelledAt'),
      refundedAt: _optionalInstant(json, 'refundedAt'),
      refundAmount: _optionalString(json, 'refundAmount'),
      note: _optionalString(json, 'note') ?? '',
    );
  }
}

/// 判断 [date] 是否为规范香港民用日载体：使用 UTC 年月日，拒绝隐藏时刻或本地时区。
bool isCanonicalFundDate(DateTime date) =>
    date.isUtc &&
    date.year >= 1900 &&
    date.year <= 9999 &&
    date.hour == 0 &&
    date.minute == 0 &&
    date.second == 0 &&
    date.millisecond == 0 &&
    date.microsecond == 0;

/// 将真实时刻 [instant] 转成香港日历日期；返回 UTC 日期载体，不依赖设备当前时区。
/// 香港固定偏移八小时；这里使用时区偏移，不使用二十四小时绝对时长推算日历天数。
DateTime hongKongFundDate(DateTime instant) {
  final hongKong = instant.toUtc().add(const Duration(hours: 8));
  final date = DateTime.utc(hongKong.year, hongKong.month, hongKong.day);
  if (!isCanonicalFundDate(date)) throw const FormatException('基金香港日期超出支持范围');
  return date;
}

/// 返回香港民用日 [date] 开始的真实 UTC 时刻；[date] 必须是规范纯日期载体。
/// 用日历字段构造前一天十六时，不受设备时区或夏令时影响，不假定来源于午夜公布净值。
DateTime hongKongFundDayStart(DateTime date) {
  if (!isCanonicalFundDate(date)) {
    throw const FormatException('基金日期必须使用 UTC 纯日期');
  }
  return DateTime.utc(date.year, date.month, date.day, -8);
}

/// 将纯日期 [date] 保存为 YYYY-MM-DD；这是机器存储格式，不供界面直接拼接展示。
String fundCalendarDateToJson(DateTime date) {
  if (!isCanonicalFundDate(date)) {
    throw const FormatException('基金日期必须使用 UTC 纯日期');
  }
  return date.toIso8601String().substring(0, 10);
}

/// 读取严格 YYYY-MM-DD 的 [value]；显式核对年月日，拒绝 DateTime 的溢出自动归一。
DateTime fundCalendarDateFromJson(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('基金日期字段必须是 YYYY-MM-DD');
  }
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  final date = DateTime.utc(year, month, day);
  if (!isCanonicalFundDate(date) ||
      date.year != year ||
      date.month != month ||
      date.day != day) {
    throw const FormatException('基金日期不是有效公历日');
  }
  return date;
}

/// 从 [json] 读取必填文本 [key]；数字必须保留文本，不能将浮点 JSON 数值悄悄转成价格。
String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('基金申购字段 $key 缺少有效文本');
  return value;
}

/// 读取可空文本 [key]；缺失保留 null，存在但类型不合法时拒绝整个申购事实。
String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('基金申购字段 $key 不是有效文本');
  return value;
}

/// 读取必填真实时刻 [key]，严格检查公历字段和显式 ISO 时区，最后统一为 UTC。
/// 新申购没有旧版无时区数据需要兼容；缺少时区会随设备地点改变经济事实，因此直接拒绝。
DateTime _requiredInstant(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final fields = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(?:Z|[+-](\d{2}):(\d{2}))$',
  ).firstMatch(value);
  if (fields == null) throw FormatException('基金申购时刻 $key 格式不合法');
  fundCalendarDateFromJson(value.substring(0, 10));
  if (int.parse(fields[4]!) > 23 ||
      int.parse(fields[5]!) > 59 ||
      int.parse(fields[6]!) > 59) {
    throw FormatException('基金申购时刻 $key 不是有效时分秒');
  }
  if (fields[7] != null &&
      (int.parse(fields[7]!) > 23 || int.parse(fields[8]!) > 59)) {
    throw FormatException('基金申购时刻 $key 的时区偏移不合法');
  }
  // 上面的日期解析仅验证输入的民用年月日；真正的时间由其显式时区解释。
  final instant = DateTime.tryParse(value);
  if (instant == null) throw FormatException('基金申购时刻 $key 无法解析');
  return instant.toUtc();
}

/// 读取可空真实时刻 [key]；未发生的付款、取消或退款不会由当前时刻补齐。
DateTime? _optionalInstant(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _requiredInstant(json, key);
