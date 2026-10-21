/// 中国大陆全国统一放假、调休安排的离线日历。
///
/// 数据只维护在 Dart 端，经账户提醒桥同步给 Android 私有存储；原生不再维护
/// 第二套日期。年度通知公布后补充新年份、核对来源并随应用更新，不联网猜测日期。
/// 不包含地方节日、单位排班和个人请假，日期沿用设备当前时区的日历日期。
class ChinaWorkdayCalendar {
  /// [years] 按完整年份保存已经核对的全年安排；缺失年份必须返回未知。
  const ChinaWorkdayCalendar({required this.years});

  final Map<int, ChinaWorkdayYear> years;

  /// 返回已有数据的年份，供设置页说明覆盖范围；排序后的列表不能修改。
  List<int> get supportedYears =>
      List<int>.unmodifiable(years.keys.toList()..sort());

  /// 判断 [date] 是否上班：补班优先、放假其次，其他日期按周一至周五。
  /// 返回 null 表示缺少年份数据，调用方必须应用用户明确选择的缺失策略。
  bool? isWorkday(DateTime date) {
    final year = years[date.year];
    if (year == null) return null;
    final monthDay = date.month * 100 + date.day;
    if (year.workdays.contains(monthDay)) return true;
    if (year.holidays.contains(monthDay)) return false;
    return date.weekday <= DateTime.friday;
  }

  /// 输出原生可独立读取的版本化快照；日期编码为“月 × 100 + 日”，如 1010。
  /// 该公共日历没有账目或账户信息，不写入用户账本备份。
  Map<String, Object?> toJson() => {
    'version': 1,
    'years': {
      for (final entry in years.entries)
        entry.key.toString(): {
          'holidays': entry.value.holidays.toList()..sort(),
          'workdays': entry.value.workdays.toList()..sort(),
        },
    },
  };
}

/// 单个年份的全年日历例外；集合包括连休中的普通周末，便于逐日核对官方通知。
class ChinaWorkdayYear {
  /// [holidays] 为全部放假日期，[workdays] 为周末补班日期，均使用月日整数。
  /// [sourceUrl] 保存官方依据，新增年份时须同时补充相应回归用例。
  const ChinaWorkdayYear({
    required this.holidays,
    required this.workdays,
    required this.sourceUrl,
  });

  final Set<int> holidays;
  final Set<int> workdays;
  final String sourceUrl;
}

/// 已核对的内置日历；2026 年依据国办发明电〔2025〕7号。
/// 中国政府网原文：https://www.gov.cn/zhengce/content/202511/content_7047090.htm
/// 同文政府转载见 sourceUrl；禁止仅凭农历或节日名称推算实际调休安排。
const mainlandChinaWorkdayCalendar = ChinaWorkdayCalendar(
  years: {
    2026: ChinaWorkdayYear(
      holidays: {
        101, 102, 103, // 元旦：1 月 1—3 日。
        215, 216, 217, 218, 219, 220, 221, 222, 223, // 春节：2 月 15—23 日。
        404, 405, 406, // 清明节：4 月 4—6 日。
        501, 502, 503, 504, 505, // 劳动节：5 月 1—5 日。
        619, 620, 621, // 端午节：6 月 19—21 日。
        925, 926, 927, // 中秋节：9 月 25—27 日。
        1001, 1002, 1003, 1004, 1005, 1006, 1007, // 国庆节：10 月 1—7 日。
      },
      workdays: {104, 214, 228, 509, 920, 1010},
      sourceUrl:
          'https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html',
    ),
  },
);
