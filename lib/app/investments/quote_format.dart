import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 按 [context] 的应用语言展示 [time]，转换为设备时区并显示时区名。
/// 来源时刻和抓取时刻都用此格式，但调用方必须明确不同标签，不据此宣称实时。
/// [includeSeconds] 供行情刷新页显示秒，便于分辨一分钟内多次手动获取；
/// 默认关闭以保留历史估值等既有分钟级排版，日期和时间均按当前语言格式化。
String formatQuoteTime(
  BuildContext context,
  DateTime time, {
  bool includeSeconds = false,
}) {
  final local = time.toLocal(), material = MaterialLocalizations.of(context);
  final formatted = includeSeconds
      ? DateFormat.jms(Localizations.localeOf(context).toString()).format(local)
      : material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
  return '${material.formatFullDate(local)} $formatted ${local.timeZoneName}';
}
