import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/demo_data.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/report_analysis.dart';

LedgerEntry entry({
  required String id,
  required EntryType type,
  required double amount,
  required String categoryId,
  required DateTime occurredAt,
  double refundedAmount = 0,
  String accountId = 'cash',
  List<EntrySourceRecord> sourceRecords = const <EntrySourceRecord>[],
}) {
  return LedgerEntry(
    id: id,
    bookId: 'default',
    type: type,
    amount: amount,
    categoryId: categoryId,
    accountId: accountId,
    note: '',
    occurredAt: occurredAt,
    refundedAmount: refundedAmount,
    sourceRecords: sourceRecords,
  );
}

void main() {
  final categories = defaultCategories;

  group('ReportRange', () {
    test('month range covers whole natural month', () {
      final range = ReportRange.month(DateTime(2026, 2, 15));
      expect(range.start, DateTime(2026, 2, 1));
      expect(range.end, DateTime(2026, 2, 28));
      expect(range.dayCount, 28);
      expect(range.mode, ReportRangeMode.month);
    });

    test('year range covers whole year', () {
      final range = ReportRange.year(2026);
      expect(range.start, DateTime(2026, 1, 1));
      expect(range.end, DateTime(2026, 12, 31));
      expect(range.dayCount, 365);
    });

    test('quarter range covers the full natural quarter', () {
      final range = ReportRange.quarter(DateTime(2026, 5, 20));
      expect(range.start, DateTime(2026, 4, 1));
      expect(range.end, DateTime(2026, 6, 30));
      expect(range.mode, ReportRangeMode.quarter);
    });

    test('billing cycle preserves and normalizes the supplied window', () {
      final range = ReportRange.billingCycle(
        DateWindow(
          start: DateTime(2026, 4, 26, 8),
          end: DateTime(2026, 5, 25, 23, 59),
        ),
      );
      expect(range.start, DateTime(2026, 4, 26));
      expect(range.end, DateTime(2026, 5, 25));
      expect(range.mode, ReportRangeMode.billingCycle);
    });

    test('custom range normalizes reversed bounds and strips time', () {
      final range = ReportRange.custom(
        DateTime(2026, 3, 10, 23, 59),
        DateTime(2026, 3, 1, 8),
      );
      expect(range.start, DateTime(2026, 3, 1));
      expect(range.end, DateTime(2026, 3, 10));
      expect(range.dayCount, 10);
    });
  });

  test('reportSummary nets income and expense, ignores transfer', () {
    final entries = <LedgerEntry>[
      entry(
        id: 'a',
        type: EntryType.income,
        amount: 1000,
        categoryId: 'salary',
        occurredAt: DateTime(2026, 5, 1),
      ),
      entry(
        id: 'b',
        type: EntryType.expense,
        amount: 300,
        categoryId: 'dining',
        occurredAt: DateTime(2026, 5, 2),
        refundedAmount: 100,
      ),
      LedgerEntry(
        id: 'c',
        bookId: 'default',
        type: EntryType.transfer,
        amount: 500,
        categoryId: 'transfer_out',
        accountId: 'cash',
        toAccountId: 'bank',
        note: '',
        occurredAt: DateTime(2026, 5, 3),
      ),
    ];
    final summary = reportSummary(entries);
    expect(summary.income, 1000);
    expect(summary.expense, 200); // 300 - 100 refunded
    expect(summary.net, 800);
    expect(summary.incomeCount, 1);
    expect(summary.expenseCount, 1);
    expect(summary.entryCount, 2);
  });

  test('reportCategoryStats aggregates by type and sorts desc', () {
    final entries = <LedgerEntry>[
      entry(
        id: 'e1',
        type: EntryType.expense,
        amount: 100,
        categoryId: 'dining',
        occurredAt: DateTime(2026, 5, 1),
      ),
      entry(
        id: 'e2',
        type: EntryType.expense,
        amount: 300,
        categoryId: 'transport',
        occurredAt: DateTime(2026, 5, 2),
      ),
      entry(
        id: 'i1',
        type: EntryType.income,
        amount: 5000,
        categoryId: 'salary',
        occurredAt: DateTime(2026, 5, 3),
      ),
    ];
    final expenseStats = reportCategoryStats(
      entries,
      categories,
      EntryType.expense,
    );
    expect(expenseStats.length, 2);
    expect(expenseStats.first.category.id, 'transport');
    expect(expenseStats.first.amount, 300);
    expect(expenseStats.first.percent, closeTo(0.75, 1e-9));

    final incomeStats = reportCategoryStats(
      entries,
      categories,
      EntryType.income,
    );
    expect(incomeStats.length, 1);
    expect(incomeStats.first.category.id, 'salary');
    expect(incomeStats.first.percent, closeTo(1.0, 1e-9));
  });

  group('子分类统计', () {
    // 餐饮(顶级) → 午餐 / 晚餐(子分类)，加一个 transport 顶级。
    const treeCategories = <Category>[
      Category(
        id: 'dining',
        label: '餐饮',
        type: EntryType.expense,
        iconCode: 'dining',
      ),
      Category(
        id: 'lunch',
        label: '午餐',
        type: EntryType.expense,
        iconCode: 'dining',
        parentId: 'dining',
      ),
      Category(
        id: 'dinner',
        label: '晚餐',
        type: EntryType.expense,
        iconCode: 'dining',
        parentId: 'dining',
      ),
      Category(
        id: 'transport',
        label: '交通',
        type: EntryType.expense,
        iconCode: 'transport',
      ),
    ];
    final treeEntries = <LedgerEntry>[
      entry(
        id: 'l1',
        type: EntryType.expense,
        amount: 30,
        categoryId: 'lunch',
        occurredAt: DateTime(2026, 5, 1),
      ),
      entry(
        id: 'd1',
        type: EntryType.expense,
        amount: 50,
        categoryId: 'dinner',
        occurredAt: DateTime(2026, 5, 2),
      ),
      entry(
        id: 'p1',
        type: EntryType.expense,
        amount: 20,
        categoryId: 'dining',
        occurredAt: DateTime(2026, 5, 3),
      ),
      entry(
        id: 't1',
        type: EntryType.expense,
        amount: 100,
        categoryId: 'transport',
        occurredAt: DateTime(2026, 5, 4),
      ),
    ];

    test('reportCategoryStats 顶级：餐饮汇总子分类，共 100', () {
      final stats = reportCategoryStats(
        treeEntries,
        treeCategories,
        EntryType.expense,
      );
      final dining = stats.firstWhere((s) => s.category.id == 'dining');
      expect(dining.amount, 100); // 30 + 50 + 20
      expect(dining.count, 3);
    });

    test('reportCategoryStatsByOwn 子分类：午餐/晚餐/餐饮各成一行', () {
      final stats = reportCategoryStatsByOwn(
        treeEntries,
        treeCategories,
        EntryType.expense,
      );
      final ids = stats.map((s) => s.category.id).toSet();
      expect(
        ids,
        containsAll(<String>['lunch', 'dinner', 'dining', 'transport']),
      );
      expect(stats.firstWhere((s) => s.category.id == 'lunch').amount, 30);
    });

    test('reportCategoryChildStats 下钻：只含餐饮下的拆分（含直接记在餐饮的）', () {
      final children = reportCategoryChildStats(
        treeEntries,
        treeCategories,
        'dining',
        EntryType.expense,
      );
      final ids = children.map((s) => s.category.id).toSet();
      expect(ids, <String>{'lunch', 'dinner', 'dining'});
      expect(ids.contains('transport'), isFalse);
      // 晚餐占餐饮合计 50/100。
      expect(
        children.firstWhere((s) => s.category.id == 'dinner').percent,
        closeTo(0.5, 1e-9),
      );
    });
  });

  group('标签统计', () {
    LedgerEntry tagged(String id, double amount, List<String> tagIds) {
      return LedgerEntry(
        id: id,
        bookId: 'default',
        type: EntryType.expense,
        amount: amount,
        categoryId: 'dining',
        accountId: 'cash',
        note: '',
        occurredAt: DateTime(2026, 5, 1),
        tagIds: tagIds,
      );
    }

    const tags = <Tag>[
      Tag(id: 'work', label: '工作'),
      Tag(id: 'food', label: '吃饭'),
    ];

    test('每笔计入其每个标签，占比相对维度总额（可重叠）', () {
      final entries = <LedgerEntry>[
        tagged('a', 100, <String>['work', 'food']),
        tagged('b', 100, <String>['work']),
        tagged('c', 100, <String>[]),
      ];
      final stats = reportTagStats(entries, tags, EntryType.expense);
      final work = stats.firstWhere((s) => s.tag.id == 'work');
      final food = stats.firstWhere((s) => s.tag.id == 'food');
      expect(work.amount, 200); // a + b
      expect(work.count, 2);
      // 维度总额 = 300（含无标签的 c）；work 占比 200/300。
      expect(work.percent, closeTo(200 / 300, 1e-9));
      expect(food.amount, 100);
      // 降序：work 在前。
      expect(stats.first.tag.id, 'work');
    });
  });

  group('账户与商户统计', () {
    const accounts = <Account>[
      Account(
        id: 'cny-card',
        bookId: 'default',
        name: '招商人民币',
        type: AccountType.creditCard,
        groupId: null,
        initialBalance: 0,
        iconCode: 'credit_card',
        note: '',
        includeInAssets: true,
        hidden: false,
        creditAccountId: 'cmb',
      ),
      Account(
        id: 'usd-card',
        bookId: 'default',
        name: '招商美元',
        type: AccountType.creditCard,
        groupId: null,
        initialBalance: 0,
        iconCode: 'credit_card',
        note: '',
        includeInAssets: true,
        hidden: false,
        currencyCode: 'USD',
        creditAccountId: 'cmb',
      ),
      Account(
        id: 'cash',
        bookId: 'default',
        name: '现金',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 0,
        iconCode: 'cash',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    ];
    const credits = <CreditAccount>[
      CreditAccount(
        id: 'cmb',
        bookId: 'default',
        name: '招商信用卡',
        institution: '招商银行',
        cardLast4: '4185',
        currencyCode: 'CNY',
        creditLimit: 50000,
        statementDay: 25,
        dueRuleType: CreditDueRuleType.fixedDay,
        dueDay: 13,
        daysAfterStatement: null,
        cycleBudget: 4000,
      ),
    ];

    test('credit currency child accounts merge into one subject row', () {
      final entries = <LedgerEntry>[
        entry(
          id: 'cny',
          type: EntryType.expense,
          amount: 120,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 5, 1),
          accountId: 'cny-card',
        ),
        entry(
          id: 'usd',
          type: EntryType.expense,
          amount: 80,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 5, 2),
          accountId: 'usd-card',
        ),
        entry(
          id: 'cash',
          type: EntryType.expense,
          amount: 50,
          categoryId: 'transport',
          occurredAt: DateTime(2026, 5, 3),
        ),
      ];
      final stats = reportAccountStats(
        entries,
        accounts,
        credits,
        EntryType.expense,
        noAccountLabel: '无账户',
        deletedAccountLabel: '已删除账户',
      );
      final credit = stats.firstWhere((stat) => stat.creditAccountId == 'cmb');
      expect(credit.label, '招商信用卡');
      expect(credit.amount, 200);
      expect(credit.count, 2);
      expect(credit.accountIds, containsAll(<String>['cny-card', 'usd-card']));
      expect(credit.percent, closeTo(0.8, 1e-9));
    });

    test(
      'merchant names normalize whitespace and use all spending as share base',
      () {
        EntrySourceRecord source(String id, String merchant) =>
            EntrySourceRecord(
              id: id,
              sourceId: 'bank',
              fingerprint: 'fp-$id',
              importedAt: DateTime(2026, 5, 4),
              transactionDate: DateTime(2026, 5, 4),
              amount: 50,
              currencyCode: 'CNY',
              merchant: merchant,
            );
        final entries = <LedgerEntry>[
          entry(
            id: 'm1',
            type: EntryType.expense,
            amount: 50,
            categoryId: 'dining',
            occurredAt: DateTime(2026, 5, 4),
            sourceRecords: <EntrySourceRecord>[source('1', '麦当劳')],
          ),
          entry(
            id: 'm2',
            type: EntryType.expense,
            amount: 30,
            categoryId: 'dining',
            occurredAt: DateTime(2026, 5, 5),
            sourceRecords: <EntrySourceRecord>[source('2', '  麦当劳  ')],
          ),
          entry(
            id: 'unknown',
            type: EntryType.expense,
            amount: 20,
            categoryId: 'dining',
            occurredAt: DateTime(2026, 5, 6),
          ),
        ];
        final stats = reportMerchantStats(entries, EntryType.expense);
        expect(stats, hasLength(1));
        expect(stats.single.label, '麦当劳');
        expect(stats.single.amount, 80);
        expect(stats.single.count, 2);
        expect(stats.single.percent, closeTo(0.8, 1e-9));
      },
    );
  });

  group('reportMonthlyComparison & changeRatio', () {
    test('changeRatio uses base magnitude and guards zero base', () {
      expect(changeRatio(120, 100), closeTo(0.2, 1e-9));
      expect(changeRatio(80, 100), closeTo(-0.2, 1e-9));
      expect(changeRatio(50, 0), isNull);
    });

    test('formatChangeRatio renders sign and dash for null', () {
      expect(formatChangeRatio(0.123), '+12.3%');
      expect(formatChangeRatio(-0.08), '-8.0%');
      expect(formatChangeRatio(null), '—');
      expect(formatChangeRatio(0), '0%');
    });

    test('comparison pulls current, previous month and last year', () {
      final entries = <LedgerEntry>[
        entry(
          id: 'cur',
          type: EntryType.expense,
          amount: 300,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 5, 10),
        ),
        entry(
          id: 'prev',
          type: EntryType.expense,
          amount: 200,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 4, 10),
        ),
        entry(
          id: 'yoy',
          type: EntryType.expense,
          amount: 150,
          categoryId: 'dining',
          occurredAt: DateTime(2025, 5, 10),
        ),
      ];
      final cmp = reportMonthlyComparison(entries, DateTime(2026, 5, 20));
      expect(cmp.current.expense, 300);
      expect(cmp.previousMonth.expense, 200);
      expect(cmp.sameMonthLastYear.expense, 150);
      expect(
        changeRatio(cmp.current.expense, cmp.previousMonth.expense),
        closeTo(0.5, 1e-9),
      );
    });

    test('january previous month rolls into last december', () {
      final entries = <LedgerEntry>[
        entry(
          id: 'dec',
          type: EntryType.income,
          amount: 1000,
          categoryId: 'salary',
          occurredAt: DateTime(2025, 12, 5),
        ),
      ];
      final cmp = reportMonthlyComparison(entries, DateTime(2026, 1, 15));
      expect(cmp.previousMonth.income, 1000);
    });

    test('generic period comparison keeps caller-defined billing cycles', () {
      final comparison = reportPeriodComparison(
        currentEntries: <LedgerEntry>[
          entry(
            id: 'cycle-current',
            type: EntryType.expense,
            amount: 4047,
            categoryId: 'dining',
            occurredAt: DateTime(2026, 9, 28),
          ),
        ],
        previousEntries: <LedgerEntry>[
          entry(
            id: 'cycle-previous',
            type: EntryType.expense,
            amount: 3704,
            categoryId: 'dining',
            occurredAt: DateTime(2026, 8, 28),
          ),
        ],
        samePeriodLastYearEntries: <LedgerEntry>[
          entry(
            id: 'cycle-last-year',
            type: EntryType.expense,
            amount: 3500,
            categoryId: 'dining',
            occurredAt: DateTime(2025, 9, 28),
          ),
        ],
      );

      expect(comparison.current.expense, 4047);
      expect(comparison.previousMonth.expense, 3704);
      expect(comparison.sameMonthLastYear.expense, 3500);
      expect(
        changeRatio(
          comparison.current.expense,
          comparison.previousMonth.expense,
        ),
        closeTo(343 / 3704, 1e-9),
      );
    });
  });

  group('reportTrend', () {
    test('short custom range is daily and buckets by day', () {
      final range = ReportRange.custom(
        DateTime(2026, 5, 1),
        DateTime(2026, 5, 5),
      );
      final entries = <LedgerEntry>[
        entry(
          id: 'e1',
          type: EntryType.expense,
          amount: 40,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 5, 2, 10),
        ),
        entry(
          id: 'e2',
          type: EntryType.expense,
          amount: 60,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 5, 2, 20),
        ),
        entry(
          id: 'skip',
          type: EntryType.income,
          amount: 999,
          categoryId: 'salary',
          occurredAt: DateTime(2026, 5, 2),
        ),
      ];
      final trend = reportTrend(entries, range, EntryType.expense);
      expect(trend.granularity, ReportTrendGranularity.daily);
      expect(trend.points.length, 5);
      expect(trend.values[1], 100); // May 2 = 40 + 60
      expect(trend.maxValue, 100);
    });

    test('year range is monthly with 12 buckets', () {
      final range = ReportRange.year(2026);
      final entries = <LedgerEntry>[
        entry(
          id: 'jan',
          type: EntryType.expense,
          amount: 200,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 1, 15),
        ),
        entry(
          id: 'dec',
          type: EntryType.expense,
          amount: 500,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 12, 31),
        ),
        entry(
          id: 'other-year',
          type: EntryType.expense,
          amount: 999,
          categoryId: 'dining',
          occurredAt: DateTime(2025, 12, 31),
        ),
      ];
      final trend = reportTrend(entries, range, EntryType.expense);
      expect(trend.granularity, ReportTrendGranularity.monthly);
      expect(trend.points.length, 12);
      expect(trend.values.first, 200);
      expect(trend.values.last, 500);
    });

    test('range spanning several months aggregates monthly', () {
      final range = ReportRange.custom(
        DateTime(2026, 1, 1),
        DateTime(2026, 4, 30),
      );
      final entries = <LedgerEntry>[
        entry(
          id: 'feb',
          type: EntryType.expense,
          amount: 80,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 2, 10),
        ),
      ];
      final trend = reportTrend(entries, range, EntryType.expense);
      expect(trend.granularity, ReportTrendGranularity.monthly);
      expect(trend.points.length, 4);
      expect(trend.values[1], 80);
    });

    test('quarter range keeps daily buckets for detailed trend inspection', () {
      final range = ReportRange.quarter(DateTime(2026, 5, 1));
      final trend = reportTrend(
        <LedgerEntry>[
          entry(
            id: 'apr',
            type: EntryType.expense,
            amount: 42,
            categoryId: 'dining',
            occurredAt: DateTime(2026, 4, 15),
          ),
        ],
        range,
        EntryType.expense,
      );
      expect(trend.granularity, ReportTrendGranularity.daily);
      expect(trend.points, hasLength(91));
      expect(trend.values.reduce((a, b) => a + b), 42);
    });

    test(
      'custom bucket date keeps explicitly assigned cycle entries in chart',
      () {
        final range = ReportRange.billingCycle(
          DateWindow(start: DateTime(2026, 4, 26), end: DateTime(2026, 5, 25)),
        );
        final assigned = entry(
          id: 'statement-day',
          type: EntryType.expense,
          amount: 88,
          categoryId: 'dining',
          occurredAt: DateTime(2026, 4, 25),
        );
        final trend = reportTrend(
          <LedgerEntry>[assigned],
          range,
          EntryType.expense,
          // 真实账期页会仅对已由 billingCycleId 纳入本期、但日期越界的点做同样夹取。
          bucketDateOf: (_) => range.start,
        );
        expect(trend.values.first, 88);
        expect(trend.values.reduce((a, b) => a + b), 88);
      },
    );
  });
}
