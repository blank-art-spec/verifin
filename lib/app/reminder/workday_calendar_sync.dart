import 'dart:convert';

import 'china_workday_calendar.dart';

/// 一条公开放假/补班记录；只描述日期，不包含账户、金额或设备身份信息。
class HolidayCalendarDay {
  /// [name] 是源文件的节日名，[date] 是 UTC 构造的日历日期，[isOffDay] 表示放假。
  const HolidayCalendarDay({
    required this.name,
    required this.date,
    required this.isOffDay,
  });

  final String name;
  final DateTime date;
  final bool isOffDay;

  /// 输出 holiday-cn 的原始字段结构，供本机缓存冷启动时重新进行完整校验。
  Map<String, Object?> toJson() => {
    'name': name,
    'date': _calendarDateKey(date),
    'isOffDay': isOffDay,
  };
}

/// 一份已通过结构与年度覆盖校验的 holiday-cn 公共年度文件。
/// 年份按国务院文件标题计算；下一年度文件可能调整上一年十二月的日期。
class HolidayCalendarDocument {
  /// 只能经 [parse] 创建，避免缓存或网络的未校验数据进入生产排程。
  const HolidayCalendarDocument._(this.year, this.papers, this.days);

  final int year;
  final List<String> papers;
  final List<HolidayCalendarDay> days;

  /// 核验 [json] 与 [expectedYear]：空占位返回 null；异常/不完整数据抛出中文错误。
  /// 要求七类全国节日均有本年放假记录，但允许中秋/国庆同名合并及普通连休周末省略。
  /// 公告链接限中国政府网 HTTPS；此校验不把第三方整理数据宣称为官方在线接口。
  static HolidayCalendarDocument? parse(
    Object? json, {
    required int expectedYear,
  }) {
    if (json is! Map<String, Object?> ||
        json['year'] != expectedYear ||
        json['year'] is! int ||
        expectedYear < 2000 ||
        expectedYear > 2199) {
      throw const FormatException('年度日历年份不匹配');
    }
    final papers = json['papers'];
    final days = json['days'];
    if (papers is! List || days is! List) {
      throw const FormatException('年度日历字段缺失');
    }
    if (papers.isEmpty && days.isEmpty) return null;
    if (papers.isEmpty ||
        papers.length > 8 ||
        days.length < 10 ||
        days.length > 100) {
      throw const FormatException('年度日历尚不完整或记录数量异常');
    }
    final sources = <String>[];
    for (final paper in papers) {
      final uri = paper is String ? Uri.tryParse(paper) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          !const {'www.gov.cn', 'gov.cn'}.contains(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.hasQuery ||
          uri.hasFragment ||
          !uri.path.startsWith('/zhengce/') ||
          !uri.path.endsWith('.htm')) {
        throw const FormatException('年度日历缺少可识别的国务院公告来源');
      }
      sources.add(paper as String);
    }
    final parsed = <HolidayCalendarDay>[];
    final seen = <String>{};
    final covered = <String>{};
    const holidays = {'元旦', '春节', '清明节', '劳动节', '端午节', '中秋节', '国庆节'};
    for (final item in days) {
      if (item is! Map<String, Object?> ||
          item['name'] is! String ||
          item['isOffDay'] is! bool ||
          item['date'] is! String) {
        throw const FormatException('年度日历包含无效记录');
      }
      final name = item['name']! as String;
      final raw = item['date']! as String;
      final date = DateTime.tryParse(raw);
      if (name.trim().isEmpty ||
          name.length > 40 ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw) ||
          date == null ||
          _calendarDateKey(date) != raw ||
          !seen.add(raw) ||
          !(date.year == expectedYear ||
              (date.year == expectedYear - 1 && date.month == 12))) {
        throw const FormatException('年度日历日期重复、越界或无效');
      }
      final off = item['isOffDay']! as bool;
      if (off && date.year == expectedYear) {
        covered.addAll(holidays.where(name.contains));
      }
      parsed.add(
        HolidayCalendarDay(
          name: name,
          date: DateTime.utc(date.year, date.month, date.day),
          isOffDay: off,
        ),
      );
    }
    if (!covered.containsAll(holidays)) {
      throw const FormatException('年度日历未覆盖全部全国节假日');
    }
    return HolidayCalendarDocument._(
      expectedYear,
      List.unmodifiable(sources),
      List.unmodifiable(parsed),
    );
  }

  /// 缓存原始字段而非仅缓存“工作日结果”，使冷启动能复核来源与全年覆盖。
  Map<String, Object?> toJson() => {
    'year': year,
    'papers': papers,
    'days': days.map((day) => day.toJson()).toList(),
  };
}

/// 下载操作结果；关闭状态下 force 也不能绕过用户的联网授权。
enum WorkdayCalendarSyncResult {
  updated,
  pending,
  partial,
  failed,
  skipped,
  disabled,
}

/// 全设备共用的日历更新偏好、有效缓存和上次检查状态，不进入账本备份。
class WorkdayCalendarSettings {
  /// [enabled] 默认关闭；[documents] 只保存已校验文件；[updating] 仅为运行时 UI 状态。
  /// [pendingYears]/[failedYears] 区分源文件未公布与网络/数据失败，已有缓存始终保留。
  const WorkdayCalendarSettings({
    this.enabled = false,
    this.documents = const {},
    this.checkedAt,
    this.pendingYears = const {},
    this.failedYears = const {},
    this.updating = false,
  });

  final bool enabled;
  final Map<int, HolidayCalendarDocument> documents;
  final DateTime? checkedAt;
  final Set<int> pendingYears;
  final Set<int> failedYears;
  final bool updating;

  /// 合成实际使用的离线日历：下载年度覆盖同年内置数据，下一年十二月修订覆盖上一年。
  /// 只有完整年度才建立 coverage，零散跨年记录不会把未知的全年误标为可用。
  ChinaWorkdayCalendar get calendar {
    final result = {...mainlandChinaWorkdayCalendar.years};
    final ordered = documents.keys.toList()..sort();
    for (final year in ordered) {
      final doc = documents[year]!;
      result[year] = ChinaWorkdayYear(
        holidays: Set.unmodifiable(
          doc.days
              .where((day) => day.date.year == year && day.isOffDay)
              .map((day) => day.date.month * 100 + day.date.day),
        ),
        workdays: Set.unmodifiable(
          doc.days
              .where((day) => day.date.year == year && !day.isOffDay)
              .map((day) => day.date.month * 100 + day.date.day),
        ),
        sourceUrl: doc.papers.first,
      );
    }
    for (final year in ordered) {
      final doc = documents[year]!;
      for (final day in doc.days.where((day) => day.date.year != year)) {
        final previous = result[day.date.year];
        if (previous == null) continue;
        final code = day.date.month * 100 + day.date.day;
        final holidays = {...previous.holidays}..remove(code);
        final workdays = {...previous.workdays}..remove(code);
        if (day.isOffDay) {
          holidays.add(code);
        } else {
          workdays.add(code);
        }
        result[day.date.year] = ChinaWorkdayYear(
          holidays: Set.unmodifiable(holidays),
          workdays: Set.unmodifiable(workdays),
          sourceUrl: doc.papers.first,
        );
      }
    }
    return ChinaWorkdayCalendar(years: Map.unmodifiable(result));
  }

  /// 复制设置与检查结果；不传的字段保持当前值，集合在调用方提交前固定为只读。
  WorkdayCalendarSettings copyWith({
    bool? enabled,
    Map<int, HolidayCalendarDocument>? documents,
    DateTime? checkedAt,
    Set<int>? pendingYears,
    Set<int>? failedYears,
    bool? updating,
  }) => WorkdayCalendarSettings(
    enabled: enabled ?? this.enabled,
    documents: Map.unmodifiable(documents ?? this.documents),
    checkedAt: checkedAt ?? this.checkedAt,
    pendingYears: Set.unmodifiable(pendingYears ?? this.pendingYears),
    failedYears: Set.unmodifiable(failedYears ?? this.failedYears),
    updating: updating ?? this.updating,
  );

  /// 设备 KV 的版本化快照；运行中标记不持久化，进程退出后不会永久显示加载中。
  Map<String, Object?> toJson() => {
    'version': 1,
    'enabled': enabled,
    'documents': documents.values.map((doc) => doc.toJson()).toList(),
    'checkedAt': checkedAt?.toIso8601String(),
    'pendingYears': pendingYears.toList()..sort(),
    'failedYears': failedYears.toList()..sort(),
  };

  /// 冷启动复核 [raw] 的大小、版本和每个下载年度；损坏时由 Controller 记录并停用联网。
  static WorkdayCalendarSettings decode(String? raw) {
    if (raw == null) return const WorkdayCalendarSettings();
    if (raw.length > 400000) throw const FormatException('本地日历缓存过大');
    // 解码放在文件末尾的独立 helper，避免把网络响应与设备配置混为同一个入口。
    return _decodeSettings(raw);
  }
}

/// 将 [date] 编码成稳定的 ISO 日历键，仅用于协议与持久化，不用于界面日期展示。
String _calendarDateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 解码设备配置 [raw]；任何一个年度或状态字段损坏都不扩大联网授权。
WorkdayCalendarSettings _decodeSettings(String raw) {
  final json = jsonDecode(raw);
  if (json is! Map<String, Object?> ||
      json['version'] != 1 ||
      json['enabled'] is! bool ||
      json['documents'] is! List) {
    throw const FormatException('本地日历配置结构错误');
  }
  final source = json['documents']! as List;
  if (source.length > 5) throw const FormatException('本地日历缓存年份过多');
  final documents = <int, HolidayCalendarDocument>{};
  for (final item in source) {
    if (item is! Map<String, Object?> || item['year'] is! int) {
      throw const FormatException('本地日历年份无效');
    }
    final year = item['year']! as int;
    final doc = HolidayCalendarDocument.parse(item, expectedYear: year);
    if (doc == null || documents.containsKey(year)) {
      throw const FormatException('本地日历为空或年份重复');
    }
    documents[year] = doc;
  }
  final checkedAt = json['checkedAt'];
  if (checkedAt != null &&
      (checkedAt is! String || DateTime.tryParse(checkedAt) == null)) {
    throw const FormatException('本地日历检查时间无效');
  }
  return WorkdayCalendarSettings(
    enabled: json['enabled']! as bool,
    documents: Map.unmodifiable(documents),
    checkedAt: checkedAt == null ? null : DateTime.parse(checkedAt as String),
    pendingYears: _decodeYearSet(json['pendingYears']),
    failedYears: _decodeYearSet(json['failedYears']),
  );
}

/// 读取检查状态中的年份集合 [raw]，不接受重复、非整数或过多记录。
Set<int> _decodeYearSet(Object? raw) {
  if (raw is! List ||
      raw.length > 5 ||
      raw.any((year) => year is! int || year < 2000 || year > 2199)) {
    throw const FormatException('日历检查状态年份无效');
  }
  final result = raw.cast<int>().toSet();
  if (result.length != raw.length) throw const FormatException('日历检查状态年份重复');
  return Set.unmodifiable(result);
}
