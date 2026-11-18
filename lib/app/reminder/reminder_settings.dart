import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 设备本地的时分，不含日期或时区；用于同一个日历日上的提醒时刻。
typedef ReminderTime = ({int hour, int minute});

/// 把提醒时分 [time] 格式化为页面统一使用的 24 小时制 `HH:mm`。
String formatReminderTime(ReminderTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// 本机提醒配置。
///
/// [enabled] 保留原有“每日记账提醒”语义；信用账户相关提醒分别显式开关，避免升级后
/// 在用户未授权的情况下突然发送新类型通知。配置存 KV（`verifin.reminder.v1`），
/// 不进 JSON 备份，因为通知权限、后台限制和合适的触发时刻都属于设备本地偏好。
class ReminderSettings {
  /// 新建一组全局设置；出账提醒默认提前 3 天，还款提醒默认在还款日当天。
  /// 信用主体未单独设置时，沿用全局还款日期和时刻。
  const ReminderSettings({
    this.enabled = false,
    this.cycleBudgetEnabled = false,
    this.statementDateEnabled = false,
    this.repaymentDueEnabled = false,
    this.statementAdvanceDays = _legacyDefaultAdvanceDays,
    this.defaultRepaymentAdvanceDays = 0,
    this.hour = 21,
    this.minute = 0,
  }) : _repaymentMinutes = const {},
       _repaymentAdvanceDays = const {};

  /// 两个映射都以信用主体 ID 为键，并复制为不可变数据。
  /// [repaymentMinutes] 是午夜起算的分钟数；[repaymentAdvanceDays] 是到期前的日历日数。
  ReminderSettings._({
    required this.enabled,
    required this.cycleBudgetEnabled,
    required this.statementDateEnabled,
    required this.repaymentDueEnabled,
    required this.statementAdvanceDays,
    required this.defaultRepaymentAdvanceDays,
    required this.hour,
    required this.minute,
    required Map<String, int> repaymentMinutes,
    required Map<String, int> repaymentAdvanceDays,
  }) : _repaymentMinutes = Map.unmodifiable(repaymentMinutes),
       _repaymentAdvanceDays = Map.unmodifiable(repaymentAdvanceDays);

  /// 是否开启每日记账提醒。
  final bool enabled;

  /// 是否开启信用账户账期预算 80% / 达到 / 超出三级预警。
  final bool cycleBudgetEnabled;

  /// 是否在信用账户出账日前发送提醒。
  final bool statementDateEnabled;

  /// 是否在正式账单还款日前发送提醒。
  final bool repaymentDueEnabled;

  /// 全局账单日提醒提前的日历日数，0 表示账单日当天。
  final int statementAdvanceDays;

  /// 未设置账户日期时，还款提醒提前的日历日数，0 表示还款日当天。
  final int defaultRepaymentAdvanceDays;

  /// 提醒时刻（24 小时制）。
  final int hour;
  final int minute;

  final Map<String, int> _repaymentMinutes;
  final Map<String, int> _repaymentAdvanceDays;

  /// 最多可提前的日历日数；0 表示还款日当天。
  static const maxAdvanceDays = 30;

  /// 旧版共用提前天数的默认值，也继续作为账单日提醒的默认值。
  static const _legacyDefaultAdvanceDays = 3;

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
    int? statementAdvanceDays,
    int? defaultRepaymentAdvanceDays,
    int? hour,
    int? minute,
  }) {
    return ReminderSettings._(
      enabled: enabled ?? this.enabled,
      cycleBudgetEnabled: cycleBudgetEnabled ?? this.cycleBudgetEnabled,
      statementDateEnabled: statementDateEnabled ?? this.statementDateEnabled,
      repaymentDueEnabled: repaymentDueEnabled ?? this.repaymentDueEnabled,
      statementAdvanceDays: statementAdvanceDays ?? this.statementAdvanceDays,
      defaultRepaymentAdvanceDays:
          defaultRepaymentAdvanceDays ?? this.defaultRepaymentAdvanceDays,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      repaymentMinutes: _repaymentMinutes,
      repaymentAdvanceDays: _repaymentAdvanceDays,
    );
  }

  /// 每日、出账及未单独设置的还款提醒共用的本地时刻。
  ReminderTime get defaultTime => (hour: hour, minute: minute);

  /// 返回 [creditAccountId] 单独设置的还款时刻；null 表示继承全局时刻。
  ReminderTime? repaymentTimeOverride(String creditAccountId) {
    final value = _repaymentMinutes[creditAccountId];
    return value == null ? null : (hour: value ~/ 60, minute: value % 60);
  }

  /// 复制设置并更新 [creditAccountId] 的还款时分；[time] 为 null 时恢复继承。
  /// 主体 ID 对应一张信用卡或一个信用平台；同一主体的币种子账户共享这一配置。
  ReminderSettings withRepaymentTime(
    String creditAccountId,
    ReminderTime? time,
  ) {
    if (time == repaymentTimeOverride(creditAccountId)) return this;
    final next = Map<String, int>.of(_repaymentMinutes);
    if (time == null) {
      next.remove(creditAccountId);
    } else {
      RangeError.checkValueInInterval(time.hour, 0, 23, 'hour');
      RangeError.checkValueInInterval(time.minute, 0, 59, 'minute');
      next[creditAccountId] = time.hour * 60 + time.minute;
    }
    return _withRepaymentOverrides(minutes: next);
  }

  /// 返回 [creditAccountId] 独立设置的提前天数；null 继承全局，0 表示当天。
  int? repaymentAdvanceDaysOverride(String creditAccountId) =>
      _repaymentAdvanceDays[creditAccountId];

  /// 返回 [creditAccountId] 实际使用的提前天数：账户覆盖优先，否则用全局还款日期。
  int effectiveRepaymentAdvanceDays(String creditAccountId) =>
      repaymentAdvanceDaysOverride(creditAccountId) ??
      defaultRepaymentAdvanceDays;

  /// 更新 [creditAccountId] 的还款提醒提前天数，保留时分覆盖和其他账户的配置。
  /// [days] 传 null 恢复继承；有效值为 0 至 [maxAdvanceDays] 的日历日数。
  ReminderSettings withRepaymentAdvanceDays(String creditAccountId, int? days) {
    if (days == repaymentAdvanceDaysOverride(creditAccountId)) return this;
    final next = Map<String, int>.of(_repaymentAdvanceDays);
    if (days == null) {
      next.remove(creditAccountId);
    } else {
      RangeError.checkValueInInterval(days, 0, maxAdvanceDays, 'days');
      next[creditAccountId] = days;
    }
    return _withRepaymentOverrides(days: next);
  }

  /// 只保留 [creditAccountIds] 对应的日期和时分覆盖，清理已删除或失效的主体。
  /// 两类覆盖都未改变时返回原对象，避免启动或账目变更时重复写入设备配置。
  ReminderSettings retainRepaymentOverrides(Iterable<String> creditAccountIds) {
    if (_repaymentMinutes.isEmpty && _repaymentAdvanceDays.isEmpty) return this;
    final valid = creditAccountIds.toSet();
    if (_repaymentMinutes.keys.every(valid.contains) &&
        _repaymentAdvanceDays.keys.every(valid.contains)) {
      return this;
    }
    return _withRepaymentOverrides(
      minutes: Map<String, int>.of(_repaymentMinutes)
        ..removeWhere((id, _) => !valid.contains(id)),
      days: Map<String, int>.of(_repaymentAdvanceDays)
        ..removeWhere((id, _) => !valid.contains(id)),
    );
  }

  /// 复制配置并替换指定映射；[minutes] 或 [days] 缺省时保留相应的旧映射。
  ReminderSettings _withRepaymentOverrides({
    Map<String, int>? minutes,
    Map<String, int>? days,
  }) => ReminderSettings._(
    enabled: enabled,
    cycleBudgetEnabled: cycleBudgetEnabled,
    statementDateEnabled: statementDateEnabled,
    repaymentDueEnabled: repaymentDueEnabled,
    statementAdvanceDays: statementAdvanceDays,
    defaultRepaymentAdvanceDays: defaultRepaymentAdvanceDays,
    hour: hour,
    minute: minute,
    repaymentMinutes: minutes ?? _repaymentMinutes,
    repaymentAdvanceDays: days ?? _repaymentAdvanceDays,
  );

  /// 展示用的 `HH:mm` 文案。
  String get timeLabel => formatReminderTime(defaultTime);

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

  /// 编码全局配置及各账户的日期和时刻；省略空映射以兼容旧版设备配置。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'cycleBudgetEnabled': cycleBudgetEnabled,
    'statementDateEnabled': statementDateEnabled,
    'repaymentDueEnabled': repaymentDueEnabled,
    'advanceDays': statementAdvanceDays,
    'defaultRepaymentAdvanceDays': defaultRepaymentAdvanceDays,
    'hour': hour,
    'minute': minute,
    if (_repaymentMinutes.isNotEmpty) 'repaymentMinutes': _repaymentMinutes,
    if (_repaymentAdvanceDays.isNotEmpty)
      'repaymentAdvanceDays': _repaymentAdvanceDays,
  };

  /// 从设备 KV 的 [json] 读取配置；旧版本缺少信用开关时仍按关闭处理。
  /// 旧版只存一项共用天数：旧默认 3 天仅保留为账单日默认，其他合法值视为
  /// 用户调整过的设置，两类提醒都继承。已经独立保存的还款日期优先。
  /// 缺失或无效的账户覆盖按字段继承全局，旧版保存的账户时分仍有效。
  factory ReminderSettings.fromJson(Map<String, dynamic> json) {
    final rawHour = (json['hour'] as num?)?.toInt() ?? 21;
    final rawMinute = (json['minute'] as num?)?.toInt() ?? 0;
    final legacyDays = json['advanceDays'];
    final statementDays = legacyDays is num
        ? legacyDays.toInt().clamp(0, maxAdvanceDays)
        : _legacyDefaultAdvanceDays;
    final repaymentDays = json['defaultRepaymentAdvanceDays'];
    final legacyCustomDays =
        legacyDays is int &&
            legacyDays >= 0 &&
            legacyDays <= maxAdvanceDays &&
            legacyDays != _legacyDefaultAdvanceDays
        ? legacyDays
        : 0;
    return ReminderSettings._(
      enabled: json['enabled'] as bool? ?? false,
      cycleBudgetEnabled: json['cycleBudgetEnabled'] as bool? ?? false,
      statementDateEnabled: json['statementDateEnabled'] as bool? ?? false,
      repaymentDueEnabled: json['repaymentDueEnabled'] as bool? ?? false,
      statementAdvanceDays: statementDays,
      defaultRepaymentAdvanceDays: repaymentDays is int
          ? repaymentDays.clamp(0, maxAdvanceDays)
          : legacyCustomDays,
      hour: rawHour.clamp(0, 23),
      minute: rawMinute.clamp(0, 59),
      repaymentMinutes: _readRepaymentOverrides(json['repaymentMinutes'], 1439),
      repaymentAdvanceDays: _readRepaymentOverrides(
        json['repaymentAdvanceDays'],
        maxAdvanceDays,
      ),
    );
  }

  /// 读取 [raw] 中的账户覆盖，只保留非空主体 ID 及 0 到 [maximum] 的整数。
  /// 单条异常数据只影响该条覆盖，不影响其他主体或另一类覆盖。
  static Map<String, int> _readRepaymentOverrides(Object? raw, int maximum) => {
    if (raw is Map<String, dynamic>)
      for (final MapEntry(:key, :value) in raw.entries)
        if (key.isNotEmpty && value is int && value >= 0 && value <= maximum)
          key: value,
  };

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

  /// 比较全局配置及各账户覆盖的内容；插入顺序不影响草稿是否有变更。
  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.cycleBudgetEnabled == cycleBudgetEnabled &&
      other.statementDateEnabled == statementDateEnabled &&
      other.repaymentDueEnabled == repaymentDueEnabled &&
      other.statementAdvanceDays == statementAdvanceDays &&
      other.defaultRepaymentAdvanceDays == defaultRepaymentAdvanceDays &&
      other.hour == hour &&
      other.minute == minute &&
      mapEquals(other._repaymentMinutes, _repaymentMinutes) &&
      mapEquals(other._repaymentAdvanceDays, _repaymentAdvanceDays);

  /// 对各账户的时刻和提前天数分别做无序哈希，保证与内容比较一致。
  @override
  int get hashCode => Object.hash(
    enabled,
    cycleBudgetEnabled,
    statementDateEnabled,
    repaymentDueEnabled,
    statementAdvanceDays,
    defaultRepaymentAdvanceDays,
    hour,
    minute,
    Object.hashAllUnordered(
      _repaymentMinutes.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
    Object.hashAllUnordered(
      _repaymentAdvanceDays.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
  );
}
