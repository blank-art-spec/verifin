import 'dart:convert';
import 'dart:io';

import 'package:verifin/app/reminder/workday_calendar_sync.dart';

/// 读取从 holiday-cn 原样下载的 2026 年公开样例；每次返回独立对象便于负向修改。
Map<String, Object?> workdayCalendarFixture() =>
    jsonDecode(File('test/fixtures/holiday_cn/2026.json').readAsStringSync())
        as Map<String, Object?>;

/// 为固定时钟测试生成 [year] 的隔离输入，只改真实样例的年份部分。
/// 这不是该年的实际放假安排，不得作为生产数据或年度真实性证据。
Map<String, Object?> workdayCalendarFixtureForYear(int year) {
  final json = workdayCalendarFixture();
  json['year'] = year;
  for (final item in (json['days']! as List).cast<Map<String, Object?>>()) {
    item['date'] = (item['date']! as String).replaceFirst('2026-', '$year-');
  }
  return json;
}

/// 将公开样例或明确标注的隔离年份输入转成已验证模型，供控制器测试注入。
HolidayCalendarDocument workdayCalendarDocument([int year = 2026]) =>
    HolidayCalendarDocument.parse(
      workdayCalendarFixtureForYear(year),
      expectedYear: year,
    )!;
