import 'package:flutter/material.dart';

import 'category_tree.dart';
import 'model_lookup.dart';
import 'ledger_math.dart';
import 'models.dart';
import '../l10n/app_localizations.dart';

/// 报表分析的时间范围类型。
///
/// [billingCycle] 由信用主体的账单日规则推导；[month]、[quarter]、[year]
/// 都是自然日历周期；[custom] 保留用户手选任意闭区间的能力。
enum ReportRangeMode { billingCycle, month, quarter, year, custom }

/// 分析范围：按「天」的闭区间 [start, end]（都取 date-only，end 含当天）。
@immutable
class ReportRange {
  ReportRange({
    required this.mode,
    required DateTime start,
    required DateTime end,
  }) : start = dateOnly(start.isAfter(end) ? end : start),
       end = dateOnly(start.isAfter(end) ? start : end);

  final ReportRangeMode mode;
  final DateTime start;
  final DateTime end;

  /// 单月范围（自然月首日到末日）。
  factory ReportRange.month(DateTime month) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(
      month.year,
      month.month,
      DateUtils.getDaysInMonth(month.year, month.month),
    );
    return ReportRange(mode: ReportRangeMode.month, start: start, end: end);
  }

  /// 自然季度范围（季度首月 1 日到季度末月最后一天）。
  factory ReportRange.quarter(DateTime date) {
    final window = quarterWindowFor(date);
    return ReportRange(
      mode: ReportRangeMode.quarter,
      start: window.start,
      end: window.end,
    );
  }

  /// 信用主体账期范围。
  ///
  /// [window] 由 `currentBillingCycle` 等信用账期纯函数产生；这里仍重新走构造器的
  /// date-only 与起止纠正，避免外部带时分秒后让区间边界漏掉交易。
  factory ReportRange.billingCycle(DateWindow window) {
    return ReportRange(
      mode: ReportRangeMode.billingCycle,
      start: window.start,
      end: window.end,
    );
  }

  /// 整年范围（1 月 1 日到 12 月 31 日）。
  factory ReportRange.year(int year) {
    return ReportRange(
      mode: ReportRangeMode.year,
      start: DateTime(year, 1, 1),
      end: DateTime(year, 12, 31),
    );
  }

  /// 自定义范围。
  factory ReportRange.custom(DateTime start, DateTime end) {
    return ReportRange(mode: ReportRangeMode.custom, start: start, end: end);
  }

  DateWindow get window => DateWindow(start: start, end: end);

  /// 含起止的天数。
  int get dayCount => calendarDaysBetween(start, end) + 1;

  /// 展示用文案（按当前语言格式化）。自定义范围同年用「月日」，跨年改用「年+月」，
  /// 否则省略年份后无法区分起止年份。
  String label(AppLocalizations l10n) {
    switch (mode) {
      case ReportRangeMode.billingCycle:
        return '${l10n.dateMonthDay(start)} - ${l10n.dateMonthDay(end)}';
      case ReportRangeMode.month:
        return l10n.yearMonth(start);
      case ReportRangeMode.quarter:
        return l10n.statQuarterRange(start.year, quarterOfMonth(start.month));
      case ReportRangeMode.year:
        return l10n.yearLabel(start.year);
      case ReportRangeMode.custom:
        return start.year == end.year
            ? '${l10n.dateMonthDay(start)} - ${l10n.dateMonthDay(end)}'
            : '${l10n.yearMonth(start)} - ${l10n.yearMonth(end)}';
    }
  }
}

/// 范围内的收支汇总（转账不计）。
@immutable
class ReportSummary {
  const ReportSummary({
    required this.income,
    required this.expense,
    required this.incomeCount,
    required this.expenseCount,
  });

  final double income;
  final double expense;
  final int incomeCount;
  final int expenseCount;

  double get net => income - expense;
  int get entryCount => incomeCount + expenseCount;

  static const empty = ReportSummary(
    income: 0,
    expense: 0,
    incomeCount: 0,
    expenseCount: 0,
  );
}

/// 汇总一批交易的收入 / 支出净额与笔数（按 [LedgerEntry.netAmount]）。
ReportSummary reportSummary(Iterable<LedgerEntry> entries) {
  var income = 0.0;
  var expense = 0.0;
  var incomeCount = 0;
  var expenseCount = 0;
  for (final entry in entries) {
    switch (entry.type) {
      case EntryType.income:
        income += entry.netAmount;
        incomeCount += 1;
      case EntryType.expense:
        expense += entry.netAmount;
        expenseCount += 1;
      case EntryType.transfer:
        break;
      case EntryType.refund:
        // 退款不计入收支汇总——冲减已体现在原支出净额里，再计一次即重复。
        break;
    }
  }
  return ReportSummary(
    income: income,
    expense: expense,
    incomeCount: incomeCount,
    expenseCount: expenseCount,
  );
}

/// 环比 / 同比对比结果。
///
/// 字段名保留最早自然月报表的命名以兼容既有调用方；信用账期通过
/// [reportPeriodComparison] 使用时，[previousMonth] 表示上账期，
/// [sameMonthLastYear] 表示去年同期账期。
@immutable
class ReportComparison {
  const ReportComparison({
    required this.current,
    required this.previousMonth,
    required this.sameMonthLastYear,
  });

  final ReportSummary current;

  /// 上月（用于环比）。
  final ReportSummary previousMonth;

  /// 去年同月（用于同比）。
  final ReportSummary sameMonthLastYear;
}

/// 计算 [month] 所在自然月与上月、去年同月的收支汇总，用于同比 / 环比。
ReportComparison reportMonthlyComparison(
  Iterable<LedgerEntry> entries,
  DateTime month,
) {
  final list = entries is List<LedgerEntry> ? entries : entries.toList();
  ReportSummary summaryOfMonth(DateTime m) =>
      reportSummary(entriesInWindow(list, ReportRange.month(m).window));
  final base = DateTime(month.year, month.month);
  return ReportComparison(
    current: summaryOfMonth(base),
    previousMonth: summaryOfMonth(DateTime(base.year, base.month - 1)),
    sameMonthLastYear: summaryOfMonth(DateTime(base.year - 1, base.month)),
  );
}

/// 把调用方已经按三个可比较周期筛好的交易汇总成统一对比结果。
///
/// 自然月可直接用 [reportMonthlyComparison]；信用账期必须先按信用主体、正式账单边界
/// 和 `billingCycleId` 分别筛出本期、上期、去年同期，不能把账单日不同的周期退化成
/// 自然月。本方法只负责一致地汇总三个集合，不猜测任何周期边界。
ReportComparison reportPeriodComparison({
  required Iterable<LedgerEntry> currentEntries,
  required Iterable<LedgerEntry> previousEntries,
  required Iterable<LedgerEntry> samePeriodLastYearEntries,
}) {
  return ReportComparison(
    current: reportSummary(currentEntries),
    // ReportComparison 的字段名源于最早的自然月报表；在通用周期场景中，该字段表达
    // “紧邻的上一周期”，保留旧名以兼容 AI 查询和现有调用方。
    previousMonth: reportSummary(previousEntries),
    sameMonthLastYear: reportSummary(samePeriodLastYearEntries),
  );
}

/// 变化率（当前相对基准）。基准为 0 时无法计算百分比，返回 null。
/// 以基准的绝对值为分母，保证金额符号语义正确。
double? changeRatio(double current, double previous) {
  if (previous.abs() < 0.005) {
    return null;
  }
  return (current - previous) / previous.abs();
}

/// 变化率的展示文案：如 `+12.3%`、`-8.0%`；无法计算（基准为 0）时返回 `—`。
String formatChangeRatio(double? ratio) {
  if (ratio == null) {
    return '—';
  }
  final percent = ratio * 100;
  if (percent.abs() < 0.05) {
    return '0%';
  }
  final sign = percent > 0 ? '+' : '-';
  return '$sign${percent.abs().toStringAsFixed(1)}%';
}

/// 某维度（支出 / 收入）的分类统计项，金额归总到顶级祖先分类。
@immutable
class ReportCategoryStat {
  const ReportCategoryStat({
    required this.categoryId,
    required this.category,
    required this.amount,
    required this.percent,
    required this.count,
  });

  /// 聚合分组用的原始 key（顶级排行为 rootId，子分类视图为交易自身 categoryId）。
  /// **下钻取数须用它，而非 [category].id**——当 key 指向已删除/悬空分类时，[category]
  /// 是「已删除分类」占位、其 id 不等于本 key，用占位 id 下钻会 scope 到错误的分类树。
  final String categoryId;
  final Category category;
  final double amount;
  final double percent;
  final int count;
}

/// 按顶级分类聚合指定类型的交易金额（净额），降序返回。[type] 只支持支出 / 收入。
List<ReportCategoryStat> reportCategoryStats(
  Iterable<LedgerEntry> entries,
  List<Category> categories,
  EntryType type,
) {
  final totals = <String, double>{};
  final counts = <String, int>{};
  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    final rootId = rootIdOf(categories, entry.categoryId);
    totals.update(
      rootId,
      (value) => value + entry.netAmount,
      ifAbsent: () => entry.netAmount,
    );
    counts.update(rootId, (value) => value + 1, ifAbsent: () => 1);
  }
  final total = totals.values.fold<double>(0, (sum, value) => sum + value);
  final stats =
      totals.entries
          .map(
            (entry) => ReportCategoryStat(
              categoryId: entry.key,
              category: categoryByIdFrom(categories, entry.key),
              amount: entry.value,
              percent: total <= 0 ? 0 : entry.value / total,
              count: counts[entry.key] ?? 0,
            ),
          )
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
  return stats;
}

/// 按交易**自身分类**（叶子/记账时所选分类，不上卷到顶级）聚合金额，降序返回。
/// 用于分类统计的「子分类」视图。[type] 只支持支出 / 收入。
List<ReportCategoryStat> reportCategoryStatsByOwn(
  Iterable<LedgerEntry> entries,
  List<Category> categories,
  EntryType type,
) {
  final totals = <String, double>{};
  final counts = <String, int>{};
  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    totals.update(
      entry.categoryId,
      (value) => value + entry.netAmount,
      ifAbsent: () => entry.netAmount,
    );
    counts.update(entry.categoryId, (value) => value + 1, ifAbsent: () => 1);
  }
  final total = totals.values.fold<double>(0, (sum, value) => sum + value);
  final stats =
      totals.entries
          .map(
            (entry) => ReportCategoryStat(
              categoryId: entry.key,
              category: categoryByIdFrom(categories, entry.key),
              amount: entry.value,
              percent: total <= 0 ? 0 : entry.value / total,
              count: counts[entry.key] ?? 0,
            ),
          )
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
  return stats;
}

/// 某顶级分类 [rootId] 的下钻拆分：只取归属该顶级分类的交易，按其自身分类聚合
/// （子分类各成一行；直接记在顶级分类上的归为「顶级分类」自己那行）。占比相对该
/// 顶级分类的合计。[type] 只支持支出 / 收入。
List<ReportCategoryStat> reportCategoryChildStats(
  Iterable<LedgerEntry> entries,
  List<Category> categories,
  String rootId,
  EntryType type,
) {
  final scoped = entries.where(
    (entry) =>
        entry.type == type && rootIdOf(categories, entry.categoryId) == rootId,
  );
  return reportCategoryStatsByOwn(scoped, categories, type);
}

/// 某维度（支出 / 收入）下按标签聚合。每笔交易计入其携带的**每个**标签，故各标签
/// 金额之和可能超过该维度总额；[percent] 为该标签金额占该维度总额的比例。
@immutable
class ReportTagStat {
  const ReportTagStat({
    required this.tag,
    required this.amount,
    required this.percent,
    required this.count,
  });

  final Tag tag;
  final double amount;
  final double percent;
  final int count;
}

/// 按标签聚合指定类型（支出 / 收入）的交易金额（净额），降序返回。
List<ReportTagStat> reportTagStats(
  Iterable<LedgerEntry> entries,
  List<Tag> tags,
  EntryType type,
) {
  final tagById = <String, Tag>{for (final tag in tags) tag.id: tag};
  final totals = <String, double>{};
  final counts = <String, int>{};
  var dimensionTotal = 0.0;
  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    dimensionTotal += entry.netAmount;
    final canonicalIds = entry.tagIds
        .map((id) => canonicalTagOf(id, tags)?.id)
        .whereType<String>()
        .toSet();
    for (final tagId in canonicalIds) {
      if (!tagById.containsKey(tagId)) {
        continue;
      }
      totals.update(
        tagId,
        (value) => value + entry.netAmount,
        ifAbsent: () => entry.netAmount,
      );
      counts.update(tagId, (value) => value + 1, ifAbsent: () => 1);
    }
  }
  final stats =
      totals.entries
          .map(
            (entry) => ReportTagStat(
              tag: tagById[entry.key]!,
              amount: entry.value,
              percent: dimensionTotal <= 0 ? 0 : entry.value / dimensionTotal,
              count: counts[entry.key] ?? 0,
            ),
          )
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
  return stats;
}

/// 多维交叉筛选：同一维度内任一标签命中即可，不同维度与分类条件均需同时命中。
/// 合并标签先解析到最终 id，故旧交易无须改写也能进入新名称的统计。
List<LedgerEntry> filterEntriesByTagDimensions(
  Iterable<LedgerEntry> entries,
  List<Tag> tags,
  List<String> selectedTagIds, {
  List<Category> categories = const <Category>[],
  String? categoryId,
}) {
  final requiredGroups = <String, Set<String>>{};
  for (final id in selectedTagIds) {
    final tag = canonicalTagOf(id, tags);
    if (tag != null) {
      requiredGroups.putIfAbsent(tag.groupId, () => <String>{}).add(tag.id);
    }
  }
  return entries
      .where((entry) {
        if (categoryId != null &&
            entry.categoryId != categoryId &&
            !isDescendantOf(categories, entry.categoryId, categoryId)) {
          return false;
        }
        if (requiredGroups.isEmpty) return true;
        final actual = entry.tagIds
            .map((id) => canonicalTagOf(id, tags))
            .whereType<Tag>()
            .toList();
        for (final group in requiredGroups.entries) {
          if (!actual.any(
            (tag) => tag.groupId == group.key && group.value.contains(tag.id),
          )) {
            return false;
          }
        }
        return true;
      })
      .toList(growable: false);
}

/// 按账户维度聚合后的统计项。
///
/// 信用子账户会按 [creditAccountId] 合并为一个真实信用主体，因此人民币、美元等
/// 子账户不会在排行中重复出现。普通账户仍保持一账户一行；[accountIds] 记录该行
/// 实际覆盖的子账户，供后续筛选或下钻复用。
@immutable
class ReportAccountStat {
  const ReportAccountStat({
    required this.key,
    required this.label,
    required this.iconCode,
    required this.accountIds,
    required this.creditAccountId,
    required this.amount,
    required this.percent,
    required this.count,
  });

  final String key;
  final String label;
  final String iconCode;
  final List<String> accountIds;
  final String? creditAccountId;
  final double amount;
  final double percent;
  final int count;
}

/// 按普通账户 / 信用主体聚合指定类型的净额并降序返回。
///
/// [noAccountLabel] 由调用方按当前语言传入；空账户 id 作为真实的“无账户”分组，
/// 不得回退为首个账户。悬空账户引用保留为独立“已删除账户”组，便于发现脏数据。
List<ReportAccountStat> reportAccountStats(
  Iterable<LedgerEntry> entries,
  List<Account> accounts,
  List<CreditAccount> creditAccounts,
  EntryType type, {
  required String noAccountLabel,
  required String deletedAccountLabel,
}) {
  final accountById = <String, Account>{
    for (final account in accounts) account.id: account,
  };
  final creditById = <String, CreditAccount>{
    for (final credit in creditAccounts) credit.id: credit,
  };
  final totals = <String, double>{};
  final counts = <String, int>{};
  final labels = <String, String>{};
  final icons = <String, String>{};
  final groupedAccountIds = <String, Set<String>>{};
  final groupedCreditIds = <String, String?>{};
  var dimensionTotal = 0.0;

  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    dimensionTotal += entry.netAmount;
    final account = accountById[entry.accountId];
    final creditId = account?.creditAccountId;
    final credit = creditId == null ? null : creditById[creditId];
    final key = entry.accountId.isEmpty
        ? 'none'
        : credit == null
        ? 'account:${entry.accountId}'
        : 'credit:${credit.id}';
    final label = entry.accountId.isEmpty
        ? noAccountLabel
        : credit?.name ?? account?.name ?? deletedAccountLabel;
    totals.update(
      key,
      (value) => value + entry.netAmount,
      ifAbsent: () => entry.netAmount,
    );
    counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    labels[key] = label;
    icons.putIfAbsent(key, () => account?.iconCode ?? 'wallet');
    groupedCreditIds[key] = credit?.id;
    if (entry.accountId.isNotEmpty) {
      groupedAccountIds.putIfAbsent(key, () => <String>{}).add(entry.accountId);
    }
  }

  final stats =
      <ReportAccountStat>[
        for (final item in totals.entries)
          ReportAccountStat(
            key: item.key,
            label: labels[item.key]!,
            iconCode: icons[item.key]!,
            accountIds: List<String>.unmodifiable(
              groupedAccountIds[item.key] ?? const <String>{},
            ),
            creditAccountId: groupedCreditIds[item.key],
            amount: item.value,
            percent: dimensionTotal <= 0 ? 0 : item.value / dimensionTotal,
            count: counts[item.key] ?? 0,
          ),
      ]..sort((a, b) {
        final amountOrder = b.amount.compareTo(a.amount);
        return amountOrder != 0 ? amountOrder : a.label.compareTo(b.label);
      });
  return stats;
}

/// 按商户聚合后的统计项。
@immutable
class ReportMerchantStat {
  const ReportMerchantStat({
    required this.key,
    required this.label,
    required this.amount,
    required this.percent,
    required this.count,
  });

  /// 归一化后的商户键，供大小写与连续空白不同的来源证据合并。
  final String key;
  final String label;
  final double amount;
  final double percent;
  final int count;
}

/// 按外部来源证据中的商户名聚合指定类型的净额并降序返回。
///
/// 同一笔真实交易可能带手工、支付平台与银行多条证据，只取最后一条非空商户名，
/// 避免一笔消费被重复计入多个商户。没有结构化商户证据的交易不凭备注猜测商户，
/// 但占比分母仍是该维度全部交易金额，因此排行能如实表达“已识别商户占总消费”。
List<ReportMerchantStat> reportMerchantStats(
  Iterable<LedgerEntry> entries,
  EntryType type,
) {
  final totals = <String, double>{};
  final counts = <String, int>{};
  final labels = <String, String>{};
  var dimensionTotal = 0.0;
  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    dimensionTotal += entry.netAmount;
    final merchant = _merchantOf(entry);
    if (merchant == null) {
      continue;
    }
    final key = merchant.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    totals.update(
      key,
      (value) => value + entry.netAmount,
      ifAbsent: () => entry.netAmount,
    );
    counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    labels.putIfAbsent(key, () => merchant);
  }
  final stats =
      <ReportMerchantStat>[
        for (final item in totals.entries)
          ReportMerchantStat(
            key: item.key,
            label: labels[item.key]!,
            amount: item.value,
            percent: dimensionTotal <= 0 ? 0 : item.value / dimensionTotal,
            count: counts[item.key] ?? 0,
          ),
      ]..sort((a, b) {
        final amountOrder = b.amount.compareTo(a.amount);
        return amountOrder != 0 ? amountOrder : a.label.compareTo(b.label);
      });
  return stats;
}

/// 取交易最后一条非空结构化商户证据；返回 null 表示不能可靠识别商户。
String? _merchantOf(LedgerEntry entry) {
  for (final source in entry.sourceRecords.reversed) {
    final merchant = source.merchant.trim();
    if (merchant.isNotEmpty) {
      return merchant;
    }
  }
  return null;
}

/// 趋势颗粒度：短范围按天，长范围（跨多月/整年）按月。
enum ReportTrendGranularity { daily, monthly }

@immutable
class ReportTrendPoint {
  const ReportTrendPoint({
    required this.date,
    required this.value,
    required this.label,
  });

  final DateTime date;
  final double value;

  /// 坐标轴短标签。
  final String label;

  /// 数据气泡标题。
}

@immutable
class ReportTrend {
  const ReportTrend({required this.granularity, required this.points});

  final ReportTrendGranularity granularity;
  final List<ReportTrendPoint> points;

  List<double> get values =>
      points.map((point) => point.value).toList(growable: false);

  double get maxValue => points.fold<double>(
    0,
    (max, point) => point.value > max ? point.value : max,
  );
}

/// 自定义范围超过该天数后按月聚合；固定月/季/账期仍保留逐日观察能力。
const int _trendDailyDayLimit = 62;

/// 计算范围内指定类型的趋势序列。整年或较长自定义范围按月，其余按天。
///
/// [bucketDateOf] 只覆盖图表分桶日期，不修改交易；账期页用它把银行明确归入本期、
/// 但发生日刚好越过推导窗口的交易夹到最近边界，使曲线合计与账期汇总保持一致。
ReportTrend reportTrend(
  Iterable<LedgerEntry> entries,
  ReportRange range,
  EntryType type, {
  DateTime Function(LedgerEntry entry)? bucketDateOf,
}) {
  final useMonthly =
      range.mode == ReportRangeMode.year ||
      (range.mode == ReportRangeMode.custom &&
          range.dayCount > _trendDailyDayLimit);
  return useMonthly
      ? _monthlyTrend(entries, range, type, bucketDateOf: bucketDateOf)
      : _dailyTrend(entries, range, type, bucketDateOf: bucketDateOf);
}

/// 生成逐日趋势；[bucketDateOf] 可在不改写交易的前提下覆盖图表分桶日期。
ReportTrend _dailyTrend(
  Iterable<LedgerEntry> entries,
  ReportRange range,
  EntryType type, {
  DateTime Function(LedgerEntry entry)? bucketDateOf,
}) {
  final days = range.window.days;
  final values = List<double>.filled(days.length, 0);
  final index = <int, int>{};
  for (var i = 0; i < days.length; i += 1) {
    final day = days[i];
    index[_dayKey(day.year, day.month, day.day)] = i;
  }
  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    final date = bucketDateOf?.call(entry) ?? entry.occurredAt;
    final slot = index[_dayKey(date.year, date.month, date.day)];
    if (slot != null) {
      values[slot] += entry.netAmount;
    }
  }
  final points = <ReportTrendPoint>[
    for (var i = 0; i < days.length; i += 1)
      ReportTrendPoint(
        date: days[i],
        value: values[i],
        label: '${days[i].month}.${days[i].day}',
      ),
  ];
  return ReportTrend(granularity: ReportTrendGranularity.daily, points: points);
}

ReportTrend _monthlyTrend(
  Iterable<LedgerEntry> entries,
  ReportRange range,
  EntryType type, {
  DateTime Function(LedgerEntry entry)? bucketDateOf,
}) {
  // 生成从 start 月到 end 月（含）的连续月份桶。
  final months = <DateTime>[];
  var cursor = DateTime(range.start.year, range.start.month, 1);
  final last = DateTime(range.end.year, range.end.month, 1);
  var guard = 0;
  while (!cursor.isAfter(last) && guard < 600) {
    months.add(cursor);
    cursor = DateTime(cursor.year, cursor.month + 1, 1);
    guard += 1;
  }
  final values = List<double>.filled(months.length, 0);
  final index = <int, int>{};
  for (var i = 0; i < months.length; i += 1) {
    index[_monthKey(months[i].year, months[i].month)] = i;
  }
  final startDay = range.start;
  final endExclusive = addCalendarDays(range.end, 1);
  for (final entry in entries) {
    if (entry.type != type) {
      continue;
    }
    final date = bucketDateOf?.call(entry) ?? entry.occurredAt;
    if (date.isBefore(startDay) || !date.isBefore(endExclusive)) {
      continue;
    }
    final slot = index[_monthKey(date.year, date.month)];
    if (slot != null) {
      values[slot] += entry.netAmount;
    }
  }
  final singleYear = months.every((month) => month.year == range.start.year);
  final points = <ReportTrendPoint>[
    for (var i = 0; i < months.length; i += 1)
      ReportTrendPoint(
        date: months[i],
        value: values[i],
        label: singleYear
            ? '${months[i].month}'
            : '${months[i].year % 100}.${months[i].month}',
      ),
  ];
  return ReportTrend(
    granularity: ReportTrendGranularity.monthly,
    points: points,
  );
}

int _dayKey(int year, int month, int day) => (year * 100 + month) * 100 + day;

int _monthKey(int year, int month) => year * 100 + month;
