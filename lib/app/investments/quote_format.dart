import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 按 [context] 的应用语言展示 [time]，转换为设备时区并显示时区名。
/// 来源时刻和抓取时刻都用此格式，但调用方必须明确不同标签，不据此宣称实时。
/// [includeSeconds] 供行情刷新页显示秒，便于分辨一分钟内多次手动获取；
/// 默认关闭以保留历史估值等既有分钟级排版，日期和时间均按当前语言格式化。
/// [compact] 供持仓卡等次级信息区使用带年份的本地化短日期，不显示冗长星期；
/// 默认 false 保持其他页面的完整日期。两种模式均保留原时刻、设备时区及时间精度。
/// [dateOnly] 为来源仅有净值日期时使用；保留传入年月日，不转换设备时区、不显示时刻。
String formatQuoteTime(
  BuildContext context,
  DateTime time, {
  bool includeSeconds = false,
  bool compact = false,
  bool dateOnly = false,
}) {
  final material = MaterialLocalizations.of(context);
  final locale = Localizations.localeOf(context).toString();
  if (dateOnly) {
    final civil = DateTime(time.year, time.month, time.day);
    return compact
        ? DateFormat.yMd(locale).format(civil)
        : material.formatFullDate(civil);
  }
  final local = time.toLocal();
  final date = compact
      ? DateFormat.yMd(locale).format(local)
      : material.formatFullDate(local);
  final formatted = includeSeconds
      ? DateFormat.jms(locale).format(local)
      : material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  return '$date $formatted ${local.timeZoneName}';
}
