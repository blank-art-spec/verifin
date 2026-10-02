import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/chart_painters.dart';
import '../app/common_widgets.dart';
import '../app/credit_card.dart';
import '../app/ledger_math.dart';
import '../app/models.dart';
import '../app/report_analysis.dart';
import '../app/series_math.dart';
import '../app/veri_fin_controller.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'budget_pages.dart';
import 'sheets.dart';
import 'transactions_pages.dart';

/// 排行分组维度：分类树、标签（可表达项目/场景）、账户和结构化商户。
enum _ReportGrouping { topCategory, subCategory, tag, account, merchant }

/// 统计分析页：支持账期 / 月 / 季 / 年 / 自定义范围，支出与收入两个维度，
/// 展示收支汇总、趋势曲线与分类 / 标签 / 账户 / 商户排行。
class ReportAnalysisPage extends StatefulWidget {
  const ReportAnalysisPage({super.key});

  @override
  State<ReportAnalysisPage> createState() => _ReportAnalysisPageState();
}

class _ReportAnalysisPageState extends State<ReportAnalysisPage> {
  ReportRangeMode _rangeMode = ReportRangeMode.month;
  DateTime _periodAnchor = DateTime.now();
  late ReportRange _customRange = ReportRange.month(_periodAnchor);
  String? _selectedCreditAccountId;
  EntryType _dimension = EntryType.expense;
  _ReportGrouping _grouping = _ReportGrouping.topCategory;
  List<String> _selectedTagIds = <String>[];
  String? _selectedCategoryId;

  /// 选择多个维度标签；关闭弹层时保持当前交叉筛选。
  Future<void> _pickDimensionTags() async {
    final result = await pickEntryTags(
      context: context,
      selectedIds: _selectedTagIds,
    );
    if (!mounted || result == null) return;
    setState(() => _selectedTagIds = result);
  }

  /// 选择用于交叉筛选的分类，包含其全部后代分类。
  Future<void> _pickFilterCategory() async {
    final controller = VeriFinScope.of(context);
    final result = await showCategoryPickerSheet(
      context,
      categories: controller.categoriesForType(_dimension),
      selectedId: _selectedCategoryId ?? '',
      title: AppLocalizations.of(context).tagReportCategoryFilter,
    );
    if (!mounted || result == null) return;
    setState(() => _selectedCategoryId = result);
  }

  /// 选择任意闭区间；取消时保持原范围与模式不变。
  Future<void> _pickCustomRange(ReportRange currentRange) async {
    final now = DateTime.now();
    final initial = DateTimeRange(
      start: currentRange.start,
      end: currentRange.end.isAfter(now) ? now : currentRange.end,
    );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: initial,
      helpText: AppLocalizations.of(context).pickTimeRange,
      saveText: AppLocalizations.of(context).okLabel,
    );
    if (picked != null && mounted) {
      setState(() {
        _customRange = ReportRange.custom(picked.start, picked.end);
        _rangeMode = ReportRangeMode.custom;
      });
    }
  }

  /// 返回当前账本中可可靠推导账期、且至少有一个币种子账户的信用主体。
  List<CreditAccount> _eligibleCreditAccounts(VeriFinController controller) {
    final usedIds = controller.accounts
        .map((account) => account.creditAccountId)
        .whereType<String>()
        .toSet();
    return controller.creditAccounts
        .where(
          (credit) =>
              credit.hasCompleteCycleRule && usedIds.contains(credit.id),
        )
        .toList(growable: false);
  }

  /// 解析当前选中的信用主体；主体被删除或切换账本后安全回落到第一个可用项。
  CreditAccount? _selectedCreditAccount(List<CreditAccount> eligibleCredits) {
    for (final credit in eligibleCredits) {
      if (credit.id == _selectedCreditAccountId) {
        return credit;
      }
    }
    return eligibleCredits.firstOrNull;
  }

  /// 按选中的时间口径计算真实闭区间。
  ///
  /// 账期优先复用 Controller 的正式账单感知投影，避免只按账单日猜边界；若信用
  /// 主体在页面停留期间被删除，则回落自然月而不是抛异常。
  ReportRange _resolvedRange(
    VeriFinController controller,
    CreditAccount? selectedCredit,
  ) {
    return switch (_rangeMode) {
      ReportRangeMode.billingCycle when selectedCredit != null =>
        _billingCycleRange(controller, selectedCredit, _periodAnchor),
      ReportRangeMode.billingCycle => ReportRange.month(_periodAnchor),
      ReportRangeMode.month => ReportRange.month(_periodAnchor),
      ReportRangeMode.quarter => ReportRange.quarter(_periodAnchor),
      ReportRangeMode.year => ReportRange.year(_periodAnchor.year),
      ReportRangeMode.custom => _customRange,
    };
  }

  /// 按指定锚点解析一个信用账期，并复用 Controller 的正式账单感知口径。
  ///
  /// 账期对比会同时读取本期、上期和去年同期；把这段逻辑集中后，三段范围都能尊重
  /// 银行正式账单的真实 `periodEnd`，不会一处用正式账单、另一处又退回固定账单日。
  ReportRange _billingCycleRange(
    VeriFinController controller,
    CreditAccount creditAccount,
    DateTime anchor,
  ) {
    return ReportRange.billingCycle(
      controller.creditCycleOverview(creditAccount, now: anchor).cycle,
    );
  }

  /// 取当前范围内的交易；账期模式同时限定信用主体并尊重银行确认的账期 id。
  List<LedgerEntry> _entriesForRange(
    VeriFinController controller,
    ReportRange range,
    CreditAccount? selectedCredit, {
    required bool useBillingCycleRules,
  }) {
    if (!useBillingCycleRules || selectedCredit == null) {
      return entriesInWindow(controller.entries, range.window);
    }
    final childIds = controller.accounts
        .where((account) => account.creditAccountId == selectedCredit.id)
        .map((account) => account.id)
        .toSet();
    final cycleId = billingCycleIdFor(range.end);
    final start = dateOnly(range.start);
    final end = dateOnly(range.end);
    return controller.entries
        .where((entry) {
          if (!childIds.contains(entry.accountId)) {
            return false;
          }
          if (entry.billingCycleId != null) {
            return entry.billingCycleId == cycleId;
          }
          final occurred = dateOnly(entry.occurredAt);
          return !occurred.isBefore(start) && !occurred.isAfter(end);
        })
        .toList(growable: false);
  }

  /// 计算当前信用账期相对上账期（环比）和去年同期账期（同比）的净消费汇总。
  ///
  /// 锚点按月或按年平移且保留 1–28 日，确保 9/26–10/25 的上一期是
  /// 8/26–9/25，而不是因为锚点掉到月初跳过一期。每个周期再独立解析正式账单边界，
  /// 并通过 [_entriesForRange] 让银行确认的 `billingCycleId` 优先于发生日期。
  ReportComparison _billingCycleComparison(
    VeriFinController controller,
    CreditAccount selectedCredit,
    ReportRange currentRange,
  ) {
    final anchorDay = _periodAnchor.day.clamp(1, 28);
    final previousAnchor = DateTime(
      _periodAnchor.year,
      _periodAnchor.month - 1,
      anchorDay,
    );
    final samePeriodLastYearAnchor = DateTime(
      _periodAnchor.year - 1,
      _periodAnchor.month,
      anchorDay,
    );
    final previousRange = _billingCycleRange(
      controller,
      selectedCredit,
      previousAnchor,
    );
    final samePeriodLastYearRange = _billingCycleRange(
      controller,
      selectedCredit,
      samePeriodLastYearAnchor,
    );
    return reportPeriodComparison(
      currentEntries: _entriesForRange(
        controller,
        currentRange,
        selectedCredit,
        useBillingCycleRules: true,
      ),
      previousEntries: _entriesForRange(
        controller,
        previousRange,
        selectedCredit,
        useBillingCycleRules: true,
      ),
      samePeriodLastYearEntries: _entriesForRange(
        controller,
        samePeriodLastYearRange,
        selectedCredit,
        useBillingCycleRules: true,
      ),
    );
  }

  /// 返回趋势图使用的分桶日期。
  ///
  /// 银行可把账单日当天的交易显式归到下一账期，此时真实发生日会位于推导窗口外一日。
  /// 汇总仍按 `billingCycleId` 计入，图表则只把点夹到最近边界，保证趋势合计与汇总一致；
  /// [LedgerEntry.occurredAt] 本身不会被修改。
  DateTime _trendBucketDate(LedgerEntry entry, ReportRange range) {
    final occurred = dateOnly(entry.occurredAt);
    if (occurred.isBefore(range.start)) {
      return range.start;
    }
    if (occurred.isAfter(range.end)) {
      return range.end;
    }
    return occurred;
  }

  /// 切换时间口径；自定义范围需要先完成日期选择，取消不会改变当前状态。
  Future<void> _selectRangeMode(
    ReportRangeMode mode,
    ReportRange currentRange,
  ) async {
    if (mode == ReportRangeMode.custom) {
      await _pickCustomRange(currentRange);
      return;
    }
    setState(() {
      _rangeMode = mode;
      _periodAnchor = DateTime.now();
    });
  }

  /// 按当前固定周期前后翻页；自定义区间没有固定步长，因此不提供翻页。
  void _movePeriod(int direction) {
    setState(() {
      _periodAnchor = switch (_rangeMode) {
        // 账期锚点保留日号（最多 28，账单规则也限制为 1–28）：例如 9 月 28 日的
        // 9/26–10/25 账期向前一格应落到 8 月 28 日，从而得到 8/26–9/25；若重置
        // 为月初会错误跳成 7/26–8/25，直接漏掉一期。
        ReportRangeMode.billingCycle => DateTime(
          _periodAnchor.year,
          _periodAnchor.month + direction,
          _periodAnchor.day.clamp(1, 28),
        ),
        ReportRangeMode.month => DateTime(
          _periodAnchor.year,
          _periodAnchor.month + direction,
          1,
        ),
        ReportRangeMode.quarter => DateTime(
          _periodAnchor.year,
          _periodAnchor.month + direction * 3,
          1,
        ),
        ReportRangeMode.year => DateTime(_periodAnchor.year + direction, 1, 1),
        ReportRangeMode.custom => _periodAnchor,
      };
    });
  }

  /// 从动态信用主体列表中选择账期观察对象；取消时保持原选择。
  Future<void> _pickCreditAccount(
    List<CreditAccount> eligibleCredits,
    CreditAccount selectedCredit,
  ) async {
    final picked = await showOptionSheet<CreditAccount>(
      context: context,
      title: AppLocalizations.of(context).reportPickCreditAccount,
      values: eligibleCredits,
      selected: selectedCredit,
      labelOf: (credit) => credit.name,
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _selectedCreditAccountId = picked.id;
      _rangeMode = ReportRangeMode.billingCycle;
      _periodAnchor = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = VeriFinScope.of(context);
    final l10n = AppLocalizations.of(context);
    final eligibleCredits = _eligibleCreditAccounts(controller);
    final selectedCredit = _selectedCreditAccount(eligibleCredits);
    final effectiveMode =
        _rangeMode == ReportRangeMode.billingCycle && selectedCredit == null
        ? ReportRangeMode.month
        : _rangeMode;
    final range = _resolvedRange(controller, selectedCredit);
    final rangeEntries = _entriesForRange(
      controller,
      range,
      selectedCredit,
      useBillingCycleRules: effectiveMode == ReportRangeMode.billingCycle,
    );
    final entries = filterEntriesByTagDimensions(
      rangeEntries,
      controller.tags,
      _selectedTagIds,
      categories: controller.categories,
      categoryId: _selectedCategoryId,
    );
    final categories = controller.categories;
    final summary = reportSummary(entries);
    final trend = reportTrend(
      entries,
      range,
      _dimension,
      bucketDateOf: effectiveMode == ReportRangeMode.billingCycle
          ? (entry) => _trendBucketDate(entry, range)
          : null,
    );
    final categoryStats = _grouping == _ReportGrouping.subCategory
        ? reportCategoryStatsByOwn(entries, categories, _dimension)
        : reportCategoryStats(entries, categories, _dimension);
    final tagStats = reportTagStats(entries, controller.tags, _dimension);
    final accountStats = reportAccountStats(
      entries,
      controller.accounts,
      controller.creditAccounts,
      _dimension,
      noAccountLabel: l10n.noAccountLabel,
      deletedAccountLabel: l10n.deletedAccountLabel,
    );
    final merchantStats = reportMerchantStats(entries, _dimension);
    final dimensionColor = _dimension == EntryType.expense
        ? veriSemantic(context, veriExpense)
        : veriSemantic(context, veriIncome);
    final dimensionTotal = _dimension == EntryType.expense
        ? summary.expense
        : summary.income;

    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 40),
            children: <Widget>[
              VeriHeader(
                title: l10n.statAnalysisTitle,
                subtitle: currencyUnitSubtitle(
                  l10n,
                  effectiveMode == ReportRangeMode.billingCycle &&
                          selectedCredit != null
                      ? '${selectedCredit.name} · ${range.label(l10n)}'
                      : range.label(l10n),
                  controller.activeBook.baseCurrencyCode,
                ),
                showBack: true,
              ),
              const SizedBox(height: 10),
              _RangeSelector(
                values: <ReportRangeMode>[
                  if (eligibleCredits.isNotEmpty) ReportRangeMode.billingCycle,
                  ReportRangeMode.month,
                  ReportRangeMode.quarter,
                  ReportRangeMode.year,
                  ReportRangeMode.custom,
                ],
                selected: effectiveMode,
                onChanged: (mode) => unawaited(_selectRangeMode(mode, range)),
              ),
              if (effectiveMode == ReportRangeMode.billingCycle &&
                  selectedCredit != null) ...<Widget>[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilterPill(
                    icon: Icons.credit_card_outlined,
                    label: selectedCredit.name,
                    onTap: () => unawaited(
                      _pickCreditAccount(eligibleCredits, selectedCredit),
                    ),
                  ),
                ),
              ],
              if (effectiveMode != ReportRangeMode.custom) ...<Widget>[
                const SizedBox(height: 2),
                MonthSwitcher(
                  label: range.label(l10n),
                  onPrevious: () => _movePeriod(-1),
                  onNext: () => _movePeriod(1),
                  previousTooltip: l10n.prevRange,
                  nextTooltip: l10n.nextRange,
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilterPill(
                    icon: Icons.label_outline,
                    label: _selectedTagIds.isEmpty
                        ? l10n.tagReportDimensionFilter
                        : l10n.entryTagCount(_selectedTagIds.length),
                    onTap: _pickDimensionTags,
                  ),
                  FilterPill(
                    icon: Icons.category_outlined,
                    label: _selectedCategoryId == null
                        ? l10n.tagReportCategoryFilter
                        : controller.categoryPathLabel(_selectedCategoryId!),
                    onTap: _pickFilterCategory,
                  ),
                  if (_selectedTagIds.isNotEmpty || _selectedCategoryId != null)
                    TextButton(
                      onPressed: () => setState(() {
                        _selectedTagIds = <String>[];
                        _selectedCategoryId = null;
                      }),
                      child: Text(l10n.commonClear),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _SummaryCard(summary: summary),
              if (effectiveMode == ReportRangeMode.month) ...<Widget>[
                const SizedBox(height: 10),
                _ComparisonCard(
                  comparison: reportMonthlyComparison(
                    controller.entries,
                    range.start,
                  ),
                ),
              ] else if (effectiveMode == ReportRangeMode.billingCycle &&
                  selectedCredit != null) ...<Widget>[
                const SizedBox(height: 10),
                _BillingCycleComparisonCard(
                  comparison: _billingCycleComparison(
                    controller,
                    selectedCredit,
                    range,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              _DimensionToggle(
                dimension: _dimension,
                onChanged: (value) => setState(() {
                  _dimension = value;
                  _selectedCategoryId = null;
                }),
              ),
              const SizedBox(height: 10),
              _TrendCard(
                trend: trend,
                color: dimensionColor,
                total: dimensionTotal,
                dimension: _dimension,
              ),
              const SizedBox(height: 10),
              _GroupingSelector(
                grouping: _grouping,
                onChanged: (value) => setState(() => _grouping = value),
              ),
              const SizedBox(height: 10),
              switch (_grouping) {
                _ReportGrouping.tag => _TagRankCard(
                  stats: tagStats,
                  color: dimensionColor,
                  dimension: _dimension,
                ),
                _ReportGrouping.account => _AccountRankCard(
                  stats: accountStats,
                  color: dimensionColor,
                  dimension: _dimension,
                ),
                _ReportGrouping.merchant => _MerchantRankCard(
                  stats: merchantStats,
                  color: dimensionColor,
                  dimension: _dimension,
                ),
                _ReportGrouping.topCategory ||
                _ReportGrouping.subCategory => _CategoryRankCard(
                  stats: categoryStats,
                  color: dimensionColor,
                  dimension: _dimension,
                  // 顶级分类模式点行下钻看子分类拆分；子分类模式点行直接跳到
                  // 按该分类筛选的交易列表（与分类管理「查看交易」同一路径，
                  // 「未分类」等也能一键定位到交易去批量归类，issue #16）。
                  onTapCategory: _grouping == _ReportGrouping.topCategory
                      ? (stat) => _showCategoryDrill(
                          context,
                          entries,
                          categories,
                          stat,
                        )
                      : (stat) => _openCategoryEntries(stat.categoryId),
                ),
              },
            ],
          ),
        ),
      ),
    );
  }

  /// 跳到按 [categoryId]（含其子分类）筛选的交易列表——与分类管理「查看交易」
  /// 同一入口，便于从统计发现问题后直接去多选批量改分类。
  void _openCategoryEntries(String categoryId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransactionsPage(initialCategoryId: categoryId),
      ),
    );
  }

  /// 顶级分类下钻：底部弹层展示该分类下按子分类（记账所选分类）的拆分，
  /// 子分类行与底部「查看交易」都可跳到对应交易列表。
  Future<void> _showCategoryDrill(
    BuildContext context,
    List<LedgerEntry> entries,
    List<Category> categories,
    ReportCategoryStat stat,
  ) {
    final children = reportCategoryChildStats(
      entries,
      categories,
      // 用聚合原始 key 而非 stat.category.id：后者在「已删除分类」占位时 id 不等于 key，
      // 会把下钻 scope 到错误的分类树（历史「幽灵餐饮」下钻显示错误子列表的成因）。
      stat.categoryId,
      _dimension,
    );
    final color = _dimension == EntryType.expense
        ? veriSemantic(context, veriExpense)
        : veriSemantic(context, veriIncome);
    return showVeriContentSheet<void>(
      context: context,
      // 命名为 sheetContext 与外层页面 context 区分：跳转前先 pop 弹层（用
      // sheetContext），再用页面 context push 交易列表。
      builder: (sheetContext) {
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.72;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      CategoryIconBox(
                        iconCode: stat.category.iconCode,
                        color: color,
                        size: 30,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(
                            sheetContext,
                          ).subCategoryOf(stat.category.label),
                          style: Theme.of(sheetContext).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Text(
                        formatAmount(stat.amount),
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(
                              color: color,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: <Widget>[
                        for (final child in children)
                          _CategoryRankTile(
                            stat: child,
                            color: color,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              _openCategoryEntries(child.categoryId);
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: Text(
                        AppLocalizations.of(sheetContext).viewCategoryEntries,
                      ),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _openCategoryEntries(stat.categoryId);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 时间口径锚点菜单；五种选项超过分段控件上限，使用静态单选菜单避免窄屏挤压。
class _RangeSelector extends StatelessWidget {
  const _RangeSelector({
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final List<ReportRangeMode> values;
  final ReportRangeMode selected;
  final ValueChanged<ReportRangeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String labelOf(ReportRangeMode mode) => switch (mode) {
      ReportRangeMode.billingCycle => l10n.statementPeriodLabel,
      ReportRangeMode.month => l10n.thisMonth,
      ReportRangeMode.quarter => l10n.timeQuarter,
      ReportRangeMode.year => l10n.timeYear,
      ReportRangeMode.custom => l10n.customRange,
    };
    return VeriAnchoredChoice<ReportRangeMode>(
      values: values,
      selected: selected,
      idOf: (mode) => mode.name,
      labelOf: labelOf,
      iconOf: (mode) => switch (mode) {
        ReportRangeMode.billingCycle => Icons.credit_card_outlined,
        ReportRangeMode.month => Icons.calendar_view_month_outlined,
        ReportRangeMode.quarter => Icons.date_range_outlined,
        ReportRangeMode.year => Icons.calendar_today_outlined,
        ReportRangeMode.custom => Icons.edit_calendar_outlined,
      },
      onSelected: onChanged,
      semanticLabel: l10n.statRangeLabel,
      builder: (context, openMenu, menuOpen) => FilterPill(
        key: const Key('report_range_selector'),
        icon: Icons.calendar_month_outlined,
        label: labelOf(selected),
        onTap: openMenu,
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(title: AppLocalizations.of(context).overviewTitle),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _SummaryMetric(
                  label: AppLocalizations.of(context).entryTypeIncome,
                  value: formatIncomeAmount(summary.income),
                  color: veriSemantic(context, veriIncome),
                  count: summary.incomeCount,
                ),
              ),
              Expanded(
                child: _SummaryMetric(
                  label: AppLocalizations.of(context).entryTypeExpense,
                  value: formatExpenseAmount(summary.expense),
                  color: veriSemantic(context, veriExpense),
                  count: summary.expenseCount,
                ),
              ),
              Expanded(
                child: _SummaryMetric(
                  label: AppLocalizations.of(context).netLabel,
                  value: formatSignedAmount(summary.net),
                  color: summary.net >= 0
                      ? veriRoyal
                      : veriSemantic(context, veriExpense),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.color,
    this.count,
  });

  final String label;
  final String value;
  final Color color;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.48);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: muted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w900,
          ),
        ),
        if (count != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            AppLocalizations.of(context).entriesCount(count!),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: muted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

/// 同比 / 环比对比卡：收入、支出、结余分别对上月（环比）与去年同月（同比）的变化。
class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.comparison});

  final ReportComparison comparison;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.48);
    Widget headerCell(String text) => Expanded(
      flex: 3,
      child: Text(
        text,
        textAlign: TextAlign.end,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: muted,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(title: AppLocalizations.of(context).yoyMomTitle),
          const SizedBox(height: 4),
          Text(
            AppLocalizations.of(context).yoyMomDesc,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              const Expanded(flex: 4, child: SizedBox.shrink()),
              headerCell(AppLocalizations.of(context).momLabel),
              headerCell(AppLocalizations.of(context).yoyLabel),
            ],
          ),
          const SizedBox(height: 4),
          _ComparisonRow(
            label: AppLocalizations.of(context).entryTypeIncome,
            current: comparison.current.income,
            momBase: comparison.previousMonth.income,
            yoyBase: comparison.sameMonthLastYear.income,
            higherIsGood: true,
          ),
          _ComparisonRow(
            label: AppLocalizations.of(context).entryTypeExpense,
            current: comparison.current.expense,
            momBase: comparison.previousMonth.expense,
            yoyBase: comparison.sameMonthLastYear.expense,
            higherIsGood: false,
          ),
          _ComparisonRow(
            label: AppLocalizations.of(context).netLabel,
            current: comparison.current.net,
            momBase: comparison.previousMonth.net,
            yoyBase: comparison.sameMonthLastYear.net,
            higherIsGood: true,
          ),
        ],
      ),
    );
  }
}

/// 信用账期对比卡：直接展示本账期、上账期和去年同期的净消费金额，并给出绝对
/// 增减额与百分比。自然月沿用上方三指标表格；信用账期则采用更贴近还款场景的金额
/// 对照，用户无需只凭百分比反推“实际多花了多少钱”。
class _BillingCycleComparisonCard extends StatelessWidget {
  const _BillingCycleComparisonCard({required this.comparison});

  final ReportComparison comparison;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = comparison.current.expense;
    final previous = comparison.previousMonth.expense;
    final samePeriodLastYear = comparison.sameMonthLastYear.expense;
    return VeriCard(
      key: const Key('billing_cycle_comparison_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(title: l10n.billingCycleComparisonTitle),
          const SizedBox(height: 4),
          Text(
            l10n.billingCycleComparisonDesc,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.48),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          _BillingCycleComparisonRow(
            label: l10n.creditCycleNetSpending,
            amount: current,
          ),
          _BillingCycleComparisonRow(
            label: l10n.previousBillingCycleSpending,
            amount: previous,
            changeLabel: l10n.momLabel,
            changeText: _changeText(l10n, current, previous),
            changeColor: _changeColor(context, current, previous),
          ),
          _BillingCycleComparisonRow(
            label: l10n.sameBillingCycleLastYear,
            amount: samePeriodLastYear,
            changeLabel: l10n.yoyLabel,
            changeText: _changeText(l10n, current, samePeriodLastYear),
            changeColor: _changeColor(context, current, samePeriodLastYear),
          ),
        ],
      ),
    );
  }

  /// 将绝对差额与变化率组合为“增加 ¥343 · +9.3%”一类可读文案。
  String _changeText(AppLocalizations l10n, double current, double baseline) {
    final delta = current - baseline;
    final change = isZeroAmount(delta)
        ? l10n.reportChangeUnchanged
        : delta > 0
        ? l10n.reportChangeIncreased(formatAmount(delta.abs()))
        : l10n.reportChangeDecreased(formatAmount(delta.abs()));
    return l10n.reportChangeWithRatio(
      change,
      formatChangeRatio(changeRatio(current, baseline)),
    );
  }

  /// 对“消费”而言，增加表示压力上升，使用支出色；减少表示支出下降，使用收入色。
  Color _changeColor(BuildContext context, double current, double baseline) {
    final delta = current - baseline;
    if (isZeroAmount(delta)) {
      return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.48);
    }
    return delta > 0
        ? veriSemantic(context, veriExpense)
        : veriSemantic(context, veriIncome);
  }
}

/// 账期对比单行：左侧保留基准账期及金额，右侧展示本期相对该基准的变化。
class _BillingCycleComparisonRow extends StatelessWidget {
  const _BillingCycleComparisonRow({
    required this.label,
    required this.amount,
    this.changeLabel,
    this.changeText,
    this.changeColor,
  });

  final String label;
  final double amount;
  final String? changeLabel;
  final String? changeText;
  final Color? changeColor;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.48);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  // 账期净消费是“花了多少”的正值指标，与首页信用卡卡片一致，不加
                  // 普通支出流水的负号；增减方向另由右侧文案和语义色明确表达。
                  formatAmount(amount),
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          if (changeText != null)
            Expanded(
              flex: 6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    changeLabel!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: muted,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    changeText!,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: changeColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ComparisonRow extends StatelessWidget {
  const _ComparisonRow({
    required this.label,
    required this.current,
    required this.momBase,
    required this.yoyBase,
    required this.higherIsGood,
  });

  final String label;
  final double current;
  final double momBase;
  final double yoyBase;

  /// 上升是否为「好」（收入/结余上升为好，支出上升为差），决定颜色。
  final bool higherIsGood;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  formatSignedAmount(current),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.52),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          _ChangeCell(
            ratio: changeRatio(current, momBase),
            higherIsGood: higherIsGood,
          ),
          _ChangeCell(
            ratio: changeRatio(current, yoyBase),
            higherIsGood: higherIsGood,
          ),
        ],
      ),
    );
  }
}

class _ChangeCell extends StatelessWidget {
  const _ChangeCell({required this.ratio, required this.higherIsGood});

  final double? ratio;
  final bool higherIsGood;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.44);
    Color color = muted;
    if (ratio != null && ratio!.abs() >= 0.0005) {
      final rising = ratio! > 0;
      final good = rising == higherIsGood;
      color = good
          ? veriSemantic(context, veriIncome)
          : veriSemantic(context, veriExpense);
    }
    return Expanded(
      flex: 3,
      child: Text(
        formatChangeRatio(ratio),
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DimensionToggle extends StatelessWidget {
  const _DimensionToggle({required this.dimension, required this.onChanged});

  final EntryType dimension;
  final ValueChanged<EntryType> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return VeriSegmentedControl<EntryType>(
      values: const <EntryType>[EntryType.expense, EntryType.income],
      selected: dimension,
      semanticLabel: l10n.statTypeTitle,
      labelOf: (type) => type == EntryType.expense
          ? l10n.entryTypeExpense
          : l10n.entryTypeIncome,
      accentOf: (type) => type == EntryType.expense
          ? veriSemantic(context, veriExpense)
          : veriSemantic(context, veriIncome),
      onChanged: onChanged,
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({
    required this.trend,
    required this.color,
    required this.total,
    required this.dimension,
  });

  final ReportTrend trend;
  final Color color;
  final double total;
  final EntryType dimension;

  @override
  Widget build(BuildContext context) {
    final isZero = isZeroAmount(total);
    final title = trend.granularity == ReportTrendGranularity.monthly
        ? AppLocalizations.of(context).monthlyTrendTitle
        : AppLocalizations.of(context).panelDailyTrendLabel;
    final dimLabel = dimension.label(AppLocalizations.of(context));
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(
            title: title,
            trailing:
                '$dimLabel ${dimension == EntryType.expense ? formatExpenseAmount(total) : formatIncomeAmount(total)}',
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: InteractiveTrendChart(
              color: isZero
                  ? Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.42)
                  : color,
              values: trend.values,
              xLabels: _sampledLabels(trend.points),
              yLabels: reportAxisLabels(trend.maxValue),
              labelColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.50),
              tooltipOf: (index) {
                final point = trend.points[index];
                final amount = dimension == EntryType.expense
                    ? formatExpenseAmount(point.value)
                    : formatIncomeAmount(point.value);
                return ChartTooltip(
                  title: trend.granularity == ReportTrendGranularity.daily
                      ? AppLocalizations.of(context).dateMonthDay(point.date)
                      : AppLocalizations.of(context).yearMonth(point.date),
                  lines: <ChartTooltipLine>[
                    ChartTooltipLine(text: '$dimLabel $amount'),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 点位过多时抽样标签，避免坐标轴文字重叠。
  List<String> _sampledLabels(List<ReportTrendPoint> points) {
    if (points.length <= 12) {
      return points.map((point) => point.label).toList(growable: false);
    }
    final step = (points.length / 8).ceil();
    return <String>[
      for (var i = 0; i < points.length; i += 1)
        (i % step == 0 || i == points.length - 1) ? points[i].label : '',
    ];
  }
}

/// 排行分组维度选择器。
///
/// 五项超过统一分段控件的适用上限，因此使用贴近触发器的静态单选菜单。
class _GroupingSelector extends StatelessWidget {
  const _GroupingSelector({required this.grouping, required this.onChanged});

  final _ReportGrouping grouping;
  final ValueChanged<_ReportGrouping> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String labelOf(_ReportGrouping value) => switch (value) {
      _ReportGrouping.topCategory => l10n.rankGroupCategory,
      _ReportGrouping.subCategory => l10n.rankGroupSubCategory,
      _ReportGrouping.tag => l10n.rankGroupTagProjectScene,
      _ReportGrouping.account => l10n.rankGroupAccount,
      _ReportGrouping.merchant => l10n.rankGroupMerchant,
    };
    return VeriAnchoredChoice<_ReportGrouping>(
      values: _ReportGrouping.values,
      selected: grouping,
      idOf: (value) => value.name,
      labelOf: labelOf,
      iconOf: (value) => switch (value) {
        _ReportGrouping.topCategory => Icons.category_outlined,
        _ReportGrouping.subCategory => Icons.account_tree_outlined,
        _ReportGrouping.tag => Icons.label_outline,
        _ReportGrouping.account => Icons.account_balance_wallet_outlined,
        _ReportGrouping.merchant => Icons.storefront_outlined,
      },
      onSelected: onChanged,
      semanticLabel: l10n.reportGroupingLabel,
      builder: (context, openMenu, menuOpen) => FilterPill(
        key: const Key('report_grouping_selector'),
        icon: Icons.leaderboard_outlined,
        label: labelOf(grouping),
        onTap: openMenu,
      ),
    );
  }
}

class _CategoryRankCard extends StatelessWidget {
  const _CategoryRankCard({
    required this.stats,
    required this.color,
    required this.dimension,
    this.onTapCategory,
  });

  final List<ReportCategoryStat> stats;
  final Color color;
  final EntryType dimension;

  /// 可点行下钻（仅顶级分类模式传入）；为空则行不可点。
  final ValueChanged<ReportCategoryStat>? onTapCategory;

  @override
  Widget build(BuildContext context) {
    final dimLabel = dimension.label(AppLocalizations.of(context));
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(
            title: AppLocalizations.of(context).categoryRank,
            trailing: dimLabel,
          ),
          const SizedBox(height: 8),
          if (stats.isEmpty)
            EmptyState(
              icon: Icons.donut_small_outlined,
              title: AppLocalizations.of(context).noDimData(dimLabel),
              description: AppLocalizations.of(context).noDimDesc(dimLabel),
            )
          else
            ...stats.map(
              (stat) => _CategoryRankTile(
                stat: stat,
                color: color,
                onTap: onTapCategory == null
                    ? null
                    : () => onTapCategory!(stat),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryRankTile extends StatelessWidget {
  const _CategoryRankTile({
    required this.stat,
    required this.color,
    this.onTap,
  });

  final ReportCategoryStat stat;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _RankTile(
      leading: CategoryIconBox(
        iconCode: stat.category.iconCode,
        color: color,
        size: 30,
      ),
      label: stat.category.label,
      amount: stat.amount,
      percent: stat.percent,
      count: stat.count,
      color: color,
      onTap: onTap,
    );
  }
}

class _TagRankCard extends StatelessWidget {
  const _TagRankCard({
    required this.stats,
    required this.color,
    required this.dimension,
  });

  final List<ReportTagStat> stats;
  final Color color;
  final EntryType dimension;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dimLabel = dimension.label(l10n);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(title: l10n.tagRank, trailing: dimLabel),
          const SizedBox(height: 8),
          if (stats.isEmpty)
            EmptyState(
              icon: Icons.label_outline,
              title: l10n.noTagData,
              description: l10n.noTagDesc,
            )
          else ...<Widget>[
            ...stats.map(
              (stat) => _RankTile(
                leading: VeriIconBox(
                  icon: Icons.label_outline,
                  color: color,
                  size: 30,
                ),
                label: stat.tag.label,
                amount: stat.amount,
                percent: stat.percent,
                count: stat.count,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.tagRankOverlapNote,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.46),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 账户排行卡；信用子账户已经在纯函数层合并为信用主体，这里只负责展示。
class _AccountRankCard extends StatelessWidget {
  const _AccountRankCard({
    required this.stats,
    required this.color,
    required this.dimension,
  });

  final List<ReportAccountStat> stats;
  final Color color;
  final EntryType dimension;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dimLabel = dimension.label(l10n);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(title: l10n.accountRank, trailing: dimLabel),
          const SizedBox(height: 8),
          if (stats.isEmpty)
            EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: l10n.noAccountRankData,
              description: l10n.noAccountRankDesc,
            )
          else
            ...stats.map(
              (stat) => _RankTile(
                leading: AccountIconBox(iconCode: stat.iconCode, size: 30),
                label: stat.label,
                amount: stat.amount,
                percent: stat.percent,
                count: stat.count,
                color: color,
              ),
            ),
        ],
      ),
    );
  }
}

/// 商户排行卡；只展示有结构化来源证据的商户，并说明占比分母仍包含未识别交易。
class _MerchantRankCard extends StatelessWidget {
  const _MerchantRankCard({
    required this.stats,
    required this.color,
    required this.dimension,
  });

  final List<ReportMerchantStat> stats;
  final Color color;
  final EntryType dimension;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dimLabel = dimension.label(l10n);
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionTitle(title: l10n.merchantRank, trailing: dimLabel),
          const SizedBox(height: 8),
          if (stats.isEmpty)
            EmptyState(
              icon: Icons.storefront_outlined,
              title: l10n.noMerchantData,
              description: l10n.noMerchantDesc,
            )
          else ...<Widget>[
            ...stats.map(
              (stat) => _RankTile(
                leading: VeriIconBox(
                  icon: Icons.storefront_outlined,
                  color: color,
                  size: 30,
                ),
                label: stat.label,
                amount: stat.amount,
                percent: stat.percent,
                count: stat.count,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.merchantRankCoverageNote,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.46),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 排行行：图标 + 名称 + 金额 + 进度条 + 占比/笔数。可选点按下钻。
class _RankTile extends StatelessWidget {
  const _RankTile({
    required this.leading,
    required this.label,
    required this.amount,
    required this.percent,
    required this.count,
    required this.color,
    this.onTap,
  });

  final Widget leading;
  final String label;
  final double amount;
  final double percent;
  final int count;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      formatAmount(amount),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (onTap != null) ...<Widget>[
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.4),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: percent.clamp(0, 1).toDouble(),
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(999),
                  color: color,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                ),
                const SizedBox(height: 4),
                Text(
                  '${(percent * 100).toStringAsFixed(1)}% · ${AppLocalizations.of(context).entriesCount(count)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.46),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return content;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(veriRadiusSm),
      child: content,
    );
  }
}
