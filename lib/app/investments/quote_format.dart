import 'package:flutter/material.dart';

/// 按 [context] 的应用语言展示 [time]，转换为设备时区并显示时区名。
/// 来源时刻和抓取时刻都用此格式，但调用方必须明确不同标签，不据此宣称实时。
String formatQuoteTime(BuildContext context, DateTime time) {
  final local = time.toLocal(), material = MaterialLocalizations.of(context);
  return '${material.formatFullDate(local)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))} ${local.timeZoneName}';
}
