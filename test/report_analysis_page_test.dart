import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('看板可进入统计分析页并切换维度与范围', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final now = DateTime.now();
    controller
      ..addEntry(
        LedgerEntry(
          id: 'exp-1',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 120,
          categoryId: 'dining',
          accountId: 'cash-report',
          note: '',
          occurredAt: now,
        ),
      )
      ..addEntry(
        LedgerEntry(
          id: 'inc-1',
          bookId: controller.activeBook.id,
          type: EntryType.income,
          amount: 5000,
          categoryId: 'salary',
          accountId: 'cash-report',
          note: '',
          occurredAt: now,
        ),
      )
      ..dispose();

    await pumpApp(tester, store);
    await tapBottomTab(tester, 2);
    await tester.pumpAndSettle();

    // 打开统计分析页。
    await tester.tap(find.byTooltip('统计分析'));
    await tester.pumpAndSettle();

    expect(find.text('统计分析'), findsOneWidget);
    expect(find.text('收支概览'), findsOneWidget);
    // 本月范围显示同比/环比对比卡。
    expect(find.text('同比 · 环比'), findsOneWidget);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('分类排行'),
      250,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    // 默认支出维度显示餐饮分类。
    expect(find.text('餐饮'), findsWidgets);

    // 切换到收入维度，分类排行显示工资。（「收入」同时出现在概览标签与维度切换，取切换段）
    await tester.tap(find.text('收入').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('工资'),
      250,
      scrollable: scrollable,
    );
    expect(find.text('工资'), findsWidgets);

    // 时间口径超过四项后使用锚点菜单；打开当前「本月」触发器后选择「本年」。
    await tester.scrollUntilVisible(
      find.byKey(const Key('report_range_selector')),
      -250,
      scrollable: scrollable,
    );
    await tester.tap(find.byKey(const Key('report_range_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本年').last);
    await tester.pumpAndSettle();
    // 回到顶部（头部标题带出副标题）确认范围标签更新为年份，且同比/环比卡消失。
    await tester.scrollUntilVisible(
      find.text('统计分析'),
      -250,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('${now.year}年'), findsWidgets);
    expect(find.text('同比 · 环比'), findsNothing);
  });

  testWidgets('统计分析页可切换分类/子分类/标签维度并下钻', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final now = DateTime.now();
    // 在「餐饮」下建子分类「午餐」。
    controller.addCategory(
      type: EntryType.expense,
      label: '午餐',
      iconCode: 'dining',
      parentId: 'dining',
    );
    final lunchId = controller.categories.firstWhere((c) => c.label == '午餐').id;
    final tagId = controller.addTag('工作')!;
    controller
      ..addEntry(
        LedgerEntry(
          id: 'sub-1',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 60,
          categoryId: lunchId,
          accountId: '',
          note: '',
          occurredAt: now,
          tagIds: <String>[tagId],
        ),
      )
      ..dispose();

    await pumpApp(tester, store);
    await tapBottomTab(tester, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('统计分析'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    // 排行维度超过四项后使用锚点菜单；切到「子分类」后出现「午餐」。
    await tester.scrollUntilVisible(
      find.byKey(const Key('report_grouping_selector')),
      250,
      scrollable: scrollable,
    );
    await tester.ensureVisible(
      find.byKey(const Key('report_grouping_selector')),
    );
    await tester.pumpAndSettle();
    await tester.drag(scrollable, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('report_grouping_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('子分类').last);
    await tester.pumpAndSettle();
    expect(find.text('午餐'), findsWidgets);

    // 切到「标签」维度 → 出现标签「工作」与排行标题。
    await tester.tap(find.byKey(const Key('report_grouping_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签 / 项目 / 场景').last);
    await tester.pumpAndSettle();
    expect(find.text('标签排行'), findsOneWidget);
    expect(find.text('工作'), findsWidgets);

    // 回「分类」维度，点「餐饮」行下钻 → 弹层出现「午餐」。
    await tester.tap(find.byKey(const Key('report_grouping_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分类').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('餐饮'),
      250,
      scrollable: scrollable,
    );
    // 新增周期翻页器后排行行可能只露出底边；再上移一点保证整行处于可点击区域。
    await tester.drag(scrollable, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('餐饮').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('的子分类'), findsOneWidget);
    expect(find.text('午餐'), findsWidgets);
  });

  /// 造两笔不同分类的支出（「餐饮/午餐」子分类 + 「交通」），供跳转筛选断言：
  /// 跳到餐饮时应只见「工作餐」、不见「公交」。
  Future<void> seedDrillEntries(VeriFinController controller) async {
    final now = DateTime.now();
    controller.addCategory(
      type: EntryType.expense,
      label: '午餐',
      iconCode: 'dining',
      parentId: 'dining',
    );
    final lunchId = controller.categories.firstWhere((c) => c.label == '午餐').id;
    controller
      ..addEntry(
        LedgerEntry(
          id: 'drill-lunch',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 60,
          categoryId: lunchId,
          accountId: '',
          note: '工作餐',
          occurredAt: now,
        ),
      )
      ..addEntry(
        LedgerEntry(
          id: 'drill-bus',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 12,
          categoryId: 'transport',
          accountId: '',
          note: '公交',
          occurredAt: now,
        ),
      )
      ..dispose();
  }

  testWidgets('统计分析页分类下钻可「查看交易」跳到按该分类预筛的交易列表', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    await seedDrillEntries(await makeController(store));

    await pumpApp(tester, store);
    await tapBottomTab(tester, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('统计分析'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('餐饮'),
      250,
      scrollable: scrollable,
    );
    await tester.drag(scrollable, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('餐饮').last);
    await tester.pumpAndSettle();

    // 弹层底部「查看交易」→ 跳到交易列表，已按「餐饮」（含子分类）预筛。
    await tester.tap(find.text('查看交易'));
    await tester.pumpAndSettle();
    expect(find.text('工作餐'), findsOneWidget);
    expect(find.text('公交'), findsNothing);
  });

  testWidgets('统计分析页子分类维度点行直接跳到该分类的交易列表', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    await seedDrillEntries(await makeController(store));

    await pumpApp(tester, store);
    await tapBottomTab(tester, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('统计分析'));
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('report_grouping_selector')),
      250,
      scrollable: scrollable,
    );
    await tester.tap(find.byKey(const Key('report_grouping_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('子分类').last);
    await tester.pumpAndSettle();

    // 点「午餐」排行行 → 直接跳到按「午餐」预筛的交易列表。
    await tester.tap(find.text('午餐').last);
    await tester.pumpAndSettle();
    expect(find.text('工作餐'), findsOneWidget);
    expect(find.text('公交'), findsNothing);
  });

  testWidgets('统计分析页可查看季度、账户与商户维度', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final now = DateTime.now();
    const account = Account(
      id: 'report-cash',
      bookId: 'default',
      name: '日常现金',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 0,
      iconCode: 'cash',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    controller
      ..addAccount(account)
      ..addEntry(
        LedgerEntry(
          id: 'merchant-entry',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 42,
          categoryId: 'dining',
          accountId: account.id,
          note: '早餐',
          occurredAt: now,
          sourceRecords: <EntrySourceRecord>[
            EntrySourceRecord(
              id: 'merchant-source',
              sourceId: 'bank',
              fingerprint: 'merchant-fingerprint',
              importedAt: now,
              transactionDate: now,
              amount: 42,
              currencyCode: 'CNY',
              merchant: '麦当劳',
            ),
          ],
        ),
      )
      ..dispose();

    await pumpApp(tester, store);
    await tapBottomTab(tester, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('统计分析'));
    await tester.pumpAndSettle();

    // 切到自然季度后，页头与周期翻页器都显示当前季度标签。
    await tester.tap(find.byKey(const Key('report_range_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本季').last);
    await tester.pumpAndSettle();
    final quarter = ((now.month - 1) ~/ 3) + 1;
    expect(find.textContaining('${now.year}年第$quarter季度'), findsWidgets);

    final groupingSelector = find.byKey(const Key('report_grouping_selector'));
    // 统计页嵌在根导航中，滚动该筛选器所属的 ListView。
    final scrollable = find
        .ancestor(of: groupingSelector, matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(
      groupingSelector,
      250,
      scrollable: scrollable,
    );
    await tester.drag(scrollable, const Offset(0, -180));
    await tester.pumpAndSettle();

    // 账户维度展示实际账户名及排行标题。
    await tester.tap(groupingSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('账户').last);
    await tester.pumpAndSettle();
    expect(find.text('账户排行'), findsOneWidget);
    expect(find.text('日常现金'), findsOneWidget);

    // 商户维度只读取结构化证据，并显示识别出的商户。
    await tester.ensureVisible(groupingSelector);
    await tester.pumpAndSettle();
    await tester.drag(scrollable, const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(groupingSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('商户').last);
    await tester.pumpAndSettle();
    expect(find.text('商户排行'), findsOneWidget);
    expect(find.text('麦当劳'), findsOneWidget);
  });

  testWidgets('统计分析页可切换到指定信用主体的当前账期', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final now = DateTime.now();
    final saved = await controller.addAccountDraft(
      Account(
        id: 'report-credit-card',
        bookId: controller.activeBook.id,
        name: '测试信用卡',
        type: AccountType.creditCard,
        groupId: null,
        initialBalance: 0,
        iconCode: 'credit_card',
        note: '',
        includeInAssets: true,
        hidden: false,
        statementDay: 25,
        dueDay: 13,
      ),
    );
    expect(saved, isTrue);
    final currentCycle = currentBillingCycle(25, now);
    final previousAnchor = DateTime(
      now.year,
      now.month - 1,
      now.day.clamp(1, 28),
    );
    final previousCycle = currentBillingCycle(25, previousAnchor);
    final lastYearCycle = currentBillingCycle(
      25,
      DateTime(now.year - 1, now.month, now.day.clamp(1, 28)),
    );
    controller
      ..addEntry(
        LedgerEntry(
          id: 'cycle-entry',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 4047,
          categoryId: 'dining',
          accountId: 'report-credit-card',
          note: '账期消费',
          occurredAt: now,
          billingCycleId: billingCycleIdFor(currentCycle.end),
        ),
      )
      ..addEntry(
        LedgerEntry(
          id: 'previous-cycle-entry',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 3704,
          categoryId: 'dining',
          accountId: 'report-credit-card',
          note: '上账期消费',
          occurredAt: previousCycle.start,
          billingCycleId: billingCycleIdFor(previousCycle.end),
        ),
      )
      ..addEntry(
        LedgerEntry(
          id: 'last-year-cycle-entry',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 3500,
          categoryId: 'dining',
          accountId: 'report-credit-card',
          note: '去年同期账期消费',
          occurredAt: lastYearCycle.start,
          billingCycleId: billingCycleIdFor(lastYearCycle.end),
        ),
      )
      ..dispose();

    await pumpApp(tester, store);
    await tapBottomTab(tester, 2);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('统计分析'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('report_range_selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账期').last);
    await tester.pumpAndSettle();

    expect(find.text('测试信用卡'), findsWidgets);
    expect(find.text('账期消费'), findsNothing);
    expect(find.textContaining('4047'), findsWidgets);

    // 账期对比显示本期、上期与去年同期的绝对金额；4047 相对 3704 增加 343，
    // 环比约 +9.3%。显式账期 id 保证测试同时覆盖银行确认归属优先于发生日期。
    await tester.ensureVisible(
      find.byKey(const Key('billing_cycle_comparison_card')),
    );
    await tester.pumpAndSettle();
    expect(find.text('账期同比 · 环比'), findsOneWidget);
    expect(find.text('上账期净消费'), findsOneWidget);
    expect(find.text('去年同期账期'), findsOneWidget);
    expect(find.textContaining('增加 343'), findsOneWidget);
    expect(find.textContaining('+9.3%'), findsOneWidget);

    // 前翻一期必须连续，不能因为把锚点重置为月初而跳过中间账期。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('上一段'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '${previousCycle.start.month}月${previousCycle.start.day}日 - '
        '${previousCycle.end.month}月${previousCycle.end.day}日',
      ),
      findsOneWidget,
    );
  });
}
