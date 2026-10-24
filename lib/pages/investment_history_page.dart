/// 历史估值页面只展示实际保存的观察点，不用当前参考价补齐缺失日期。
library;

import 'package:flutter/material.dart';
import '../app/app_theme.dart';
import '../app/chart_painters.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/investments/quote_format.dart';
import '../app/investments/investment_decimal.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';

/// [accountId] 是当前账本真实币种账户，账户删除后不显示其他账户数据。
class InvestmentHistoryPage extends StatefulWidget {
  const InvestmentHistoryPage({super.key, required this.accountId});
  final String accountId;

  /// 保存按钮需要短暂的忙碌状态，页面本身不保存账务副本。
  @override
  State<InvestmentHistoryPage> createState() => _InvestmentHistoryPageState();
}

class _InvestmentHistoryPageState extends State<InvestmentHistoryPage> {
  bool _saving = false;

  /// 只记录当前时点；等待 SQLite 成功后再显示结果，期间防止重复点击。
  Future<void> _capture() async {
    setState(() => _saving = true);
    final ok = await VeriFinScope.of(
      context,
    ).captureInvestmentValuation(widget.accountId);
    if (!mounted) return;
    setState(() => _saving = false);
    final l = AppLocalizations.of(context);
    await VeriFeedbackHost.of(context).showMessage(
      message: ok ? l.investHistorySaved : l.investSaveError,
      tone: ok ? VeriFeedbackTone.success : VeriFeedbackTone.error,
    );
  }

  /// 使用保存时价格与汇率计算观察点；任一点失效时保留列表并提示缺失，不画零值连线。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final p = c.investmentFor(widget.accountId);
    final snapshots = [...?p?.valuationSnapshots]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final values = snapshots.map((s) {
      final value = c
          .investmentSnapshotValuation(widget.accountId, s)
          ?.amounts
          ?.net;
      return value == null || s.rateToBase == null
          ? null
          : normalizeCurrencyAmount(value * s.rateToBase!, s.baseCurrencyCode);
    }).toList();
    final complete =
        values.isNotEmpty &&
        values.every((v) => v != null) &&
        snapshots.every(
          (s) => s.baseCurrencyCode == snapshots.first.baseCurrencyCode,
        );

    /// [date] 是实际观察时点；同日用本地化时分、跨日用月日，完整时间仍留在点按详情中。
    String axisLabel(DateTime date) {
      final local = date.toLocal(),
          first = snapshots.first.capturedAt.toLocal();
      return DateUtils.isSameDay(local, first) &&
              DateUtils.isSameDay(snapshots.last.capturedAt.toLocal(), first)
          ? MaterialLocalizations.of(context).formatTimeOfDay(
              TimeOfDay.fromDateTime(local),
              alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
                context,
              ),
            )
          : l.dateMonthDay(local);
    }

    String money(double value) => formatUserMoney(value, p!.currencyCode);
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
            children: [
              VeriHeader(title: l.investHistory, showBack: true),
              const SizedBox(height: 12),
              Text(l.investHistoryHint),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('capture_investment_valuation'),
                onPressed: p == null || _saving ? null : _capture,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: Text(l.investHistoryCapture),
              ),
              if (snapshots.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l.investHistoryEmpty),
                ),
              // 单点没有趋势，不能交给折线面积图生成一条虚构的下降填充。
              if (complete && values.length == 1)
                VeriCard(child: Text(l.investHistorySingleObservation)),
              if (complete && values.length >= 2)
                VeriCard(
                  child: SizedBox(
                    height: 170,
                    child: Padding(
                      // 给两端居中的轴标签留白，避免文字越过卡片边界。
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: InteractiveTrendChart(
                        color: veriRoyal,
                        values: values.cast<double>(),
                        xLabels: [
                          axisLabel(snapshots.first.capturedAt),
                          axisLabel(snapshots.last.capturedAt),
                        ],
                        tooltipOf: (i) => ChartTooltip(
                          title: formatQuoteTime(
                            context,
                            snapshots[i].capturedAt,
                          ),
                          lines: [
                            ChartTooltipLine(
                              text: formatUserMoney(
                                values[i]!,
                                snapshots.first.baseCurrencyCode,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (values.any((v) => v == null) ||
                  snapshots.any(
                    (s) =>
                        s.baseCurrencyCode != snapshots.first.baseCurrencyCode,
                  ))
                VeriCard(child: Text(l.investHistoryGap)),
              for (final s in snapshots.reversed)
                Builder(
                  builder: (context) {
                    final value = c.investmentSnapshotValuation(
                          widget.accountId,
                          s,
                        ),
                        parts = value?.amounts;
                    return VeriCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            formatQuoteTime(context, s.capturedAt),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          if (parts == null)
                            Text(l.investHistoryInvalid)
                          else ...[
                            Text('${l.investNetValue}: ${money(parts.net)}'),
                            Text('${l.investCash}: ${money(value!.cash)}'),
                            Text(
                              '${l.metricTotalAssets}: ${money(parts.assets)} · ${l.aiStatTotalLiabilities}: ${money(parts.liabilities)}',
                            ),
                            Text('${l.optionMargin}: ${money(value.frozen)}'),
                          ],
                          Text(
                            '${l.investHistoryBase}: ${values[snapshots.indexOf(s)] == null ? '—' : formatUserMoney(values[snapshots.indexOf(s)]!, s.baseCurrencyCode)}',
                          ),
                          if (s.rateToBase != null)
                            Text(
                              '${l.investHistoryRate}: ${formatRateValue(s.rateToBase!)}${s.rateDate == null ? '' : ' · ${MaterialLocalizations.of(context).formatMediumDate(s.rateDate!)}'}',
                            ),
                          for (final fact in s.prices.entries)
                            Text(
                              '${p!.securities.where((v) => v.id == fact.key).firstOrNull?.symbol ?? fact.key}: '
                              '${formatUserSecurityPrice(InvestmentDecimal.parse(fact.value.price).toString(), p.currencyCode)} · '
                              '${fact.value.manual ? l.exchangeRateSourceManual : fact.value.source} · ${formatQuoteTime(context, fact.value.quotedAt)}',
                            ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
