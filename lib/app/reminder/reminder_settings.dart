import 'dart:convert';

/// 本机提醒配置。
///
/// [enabled] 保留原有“每日记账提醒”语义；信用账户相关提醒分别显式开关，避免升级后
/// 在用户未授权的情况下突然发送新类型通知。配置存 KV（`verifin.reminder.v1`），
/// 不进 JSON 备份，因为通知权限、后台限制和合适的触发时刻都属于设备本地偏好。
class ReminderSettings {
  const ReminderSettings({
    this.enabled = false,
    this.cycleBudgetEnabled = false,
    this.statementDateEnabled = false,
    this.repaymentDueEnabled = false,
    this.advanceDays = 3,
    this.hour = 21,
    this.minute = 0,
  });

  /// 是否开启每日记账提醒。
  final bool enabled;

  /// 是否开启信用账户账期预算 80% / 达到 / 超出三级预警。
  final bool cycleBudgetEnabled;

  /// 是否在信用账户出账日前发送提醒。
  final bool statementDateEnabled;

  /// 是否在正式账单还款日前发送提醒。
  final bool repaymentDueEnabled;

  /// 出账日和还款日提前提醒的日历日数，限制为 0–30。
  final int advanceDays;

  /// 提醒时刻（24 小时制）。
  final int hour;
  final int minute;

  static const ReminderSettings disabled = ReminderSettings();

  /// 任一通知类型已开启时为 true，供权限申请和设置入口摘要共用。
  bool get hasAnyEnabled =>
      enabled ||
      cycleBudgetEnabled ||
      statementDateEnabled ||
      repaymentDueEnabled;

  /// 复制配置，并只替换调用方明确传入的字段。
  ReminderSettings copyWith({
    bool? enabled,
    bool? cycleBudgetEnabled,
    bool? statementDateEnabled,
    bool? repaymentDueEnabled,
    int? advanceDays,
    int? hour,
    int? minute,
  }) {
    return ReminderSettings(
      enabled: enabled ?? this.enabled,
      cycleBudgetEnabled: cycleBudgetEnabled ?? this.cycleBudgetEnabled,
      statementDateEnabled: statementDateEnabled ?? this.statementDateEnabled,
      repaymentDueEnabled: repaymentDueEnabled ?? this.repaymentDueEnabled,
      advanceDays: advanceDays ?? this.advanceDays,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
    );
  }

  /// 展示用的 `HH:mm` 文案。
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// 从 [from] 起下一次触发时刻：今天该时刻若已过则顺延到明天。
  ///
  /// 顺延按「日历日 +1」构造而非 `add(Duration(days: 1))`——后者是绝对 24 小时，
  /// 跨夏令时切换会把提醒推到次日的 hour±1，用户设 21:00 却在 20:00/22:00 响。
  DateTime nextFireTime(DateTime from) {
    final candidate = DateTime(from.year, from.month, from.day, hour, minute);
    if (candidate.isAfter(from)) {
      return candidate;
    }
    return DateTime(from.year, from.month, from.day + 1, hour, minute);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'cycleBudgetEnabled': cycleBudgetEnabled,
    'statementDateEnabled': statementDateEnabled,
    'repaymentDueEnabled': repaymentDueEnabled,
    'advanceDays': advanceDays,
    'hour': hour,
    'minute': minute,
  };

  /// 从设备 KV 读取配置；旧版本没有信用提醒字段时一律回退为关闭，保持升级无打扰。
  factory ReminderSettings.fromJson(Map<String, dynamic> json) {
    final rawHour = (json['hour'] as num?)?.toInt() ?? 21;
    final rawMinute = (json['minute'] as num?)?.toInt() ?? 0;
    final rawAdvanceDays = (json['advanceDays'] as num?)?.toInt() ?? 3;
    return ReminderSettings(
      enabled: json['enabled'] as bool? ?? false,
      cycleBudgetEnabled: json['cycleBudgetEnabled'] as bool? ?? false,
      statementDateEnabled: json['statementDateEnabled'] as bool? ?? false,
      repaymentDueEnabled: json['repaymentDueEnabled'] as bool? ?? false,
      advanceDays: rawAdvanceDays.clamp(0, 30),
      hour: rawHour.clamp(0, 23),
      minute: rawMinute.clamp(0, 59),
    );
  }

  /// 编码为 KV 使用的紧凑 JSON 字符串。
  String encode() => jsonEncode(toJson());

  /// 解码设备 KV；空值或损坏内容安全回退为全部关闭。
  static ReminderSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return disabled;
    }
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        return ReminderSettings.fromJson(json);
      }
    } catch (_) {
      // 解析失败按未开启处理。
    }
    return disabled;
  }

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.cycleBudgetEnabled == cycleBudgetEnabled &&
      other.statementDateEnabled == statementDateEnabled &&
      other.repaymentDueEnabled == repaymentDueEnabled &&
      other.advanceDays == advanceDays &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(
    enabled,
    cycleBudgetEnabled,
    statementDateEnabled,
    repaymentDueEnabled,
    advanceDays,
    hour,
    minute,
  );
}
