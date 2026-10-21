import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/reminder/account_entry_reminder.dart';
import 'package:verifin/app/reminder/china_workday_calendar.dart';

/// 核对官方放假安排、补班、未知年度及发送/确认共用的日期规则；由用户手动运行。
void main() {
  const calendar = mainlandChinaWorkdayCalendar;
  const rule = AccountEntryReminder(
    id: 'workday-rule',
    accountId: 'account',
    bookId: 'book',
    currencyCode: 'CNY',
    repeatMode: AccountReminderRepeatMode.chinaWorkdays,
    weekdays: [],
  );

  test('2026 年七段官方连休中的每一天均不提醒', () {
    // 依据国办发明电〔2025〕7号，逐日检查，防止只排除法定节日本身、漏掉调休日。
    final ranges = [
      (DateTime(2026, 1, 1), DateTime(2026, 1, 3)),
      (DateTime(2026, 2, 15), DateTime(2026, 2, 23)),
      (DateTime(2026, 4, 4), DateTime(2026, 4, 6)),
      (DateTime(2026, 5, 1), DateTime(2026, 5, 5)),
      (DateTime(2026, 6, 19), DateTime(2026, 6, 21)),
      (DateTime(2026, 9, 25), DateTime(2026, 9, 27)),
      (DateTime(2026, 10, 1), DateTime(2026, 10, 7)),
    ];
    var count = 0;
    for (final (start, end) in ranges) {
      for (
        var date = start;
        !date.isAfter(end);
        date = addCalendarDays(date, 1)
      ) {
        expect(calendar.isWorkday(date), isFalse, reason: '$date');
        expect(rule.matchesDate(date), isFalse, reason: '$date');
        count++;
      }
    }
    expect(count, 33);
    expect(calendar.years[2026]!.holidays.length, count);
  });

  test('六个周末补班日独立于自定义星期，普通周末仍跳过', () {
    for (final date in [
      DateTime(2026, 1, 4),
      DateTime(2026, 2, 14),
      DateTime(2026, 2, 28),
      DateTime(2026, 5, 9),
      DateTime(2026, 9, 20),
      DateTime(2026, 10, 10),
    ]) {
      expect(date.weekday, greaterThan(DateTime.friday));
      expect(rule.matchesDate(date), isTrue, reason: '$date');
    }
    expect(rule.matchesDate(DateTime(2026, 10, 11)), isFalse);
    expect(rule.matchesDate(DateTime(2026, 10, 12, 23, 59)), isTrue);
    expect(rule.matchesDate(DateTime(2026, 12, 31)), isTrue);
    expect(calendar.supportedYears, [2026]);
  });

  test('未知年度默认暂停，只有用户明确选择才按周一至周五降级', () {
    final monday = DateTime(2027, 1, 4);
    final saturday = DateTime(2027, 1, 2);
    expect(calendar.isWorkday(monday), isNull);
    expect(rule.hasMissingCalendar(monday), isTrue);
    expect(rule.matchesDate(monday), isFalse);
    expect(rule.matchesDate(saturday), isFalse);
    final fallback = rule.copyWith(
      missingCalendarPolicy: MissingWorkdayCalendarPolicy.weekdays,
    );
    expect(fallback.matchesDate(monday), isTrue);
    expect(fallback.matchesDate(saturday), isFalse);
    // 年度数据已经存在时仍须跳过节假日，不得把降级策略用于所有年份。
    expect(fallback.matchesDate(DateTime(2026, 10, 1)), isFalse);
    expect(fallback.matchesDate(DateTime(2026, 10, 10)), isTrue);
  });

  test('自定义星期保持旧口径，不受年度日历或缺失策略影响', () {
    final weekly = rule.copyWith(
      repeatMode: AccountReminderRepeatMode.weekdays,
      weekdays: [1, 2, 3, 4, 5],
    );
    expect(weekly.matchesDate(DateTime(2026, 10, 1)), isTrue);
    expect(weekly.matchesDate(DateTime(2026, 10, 10)), isFalse);
    expect(weekly.matchesDate(DateTime(2027, 1, 4)), isTrue);
    expect(weekly.hasMissingCalendar(DateTime(2027, 1, 4)), isFalse);
  });

  test('原生快照使用同一日历，明确版本和全年覆盖，且可稳定 JSON 往返', () {
    final snapshot = calendar.toJson();
    expect(snapshot['version'], 1);
    final years = snapshot['years']! as Map<String, Object?>;
    final year = years['2026']! as Map<String, Object?>;
    expect(year['holidays'], containsAll([101, 215, 223, 1001, 1007]));
    expect(year['workdays'], [104, 214, 228, 509, 920, 1010]);
    expect(jsonDecode(jsonEncode(snapshot)), snapshot);
    expect(
      calendar.years[2026]!.sourceUrl,
      startsWith('https://www.beijing.gov.cn/'),
    );
  });
}
