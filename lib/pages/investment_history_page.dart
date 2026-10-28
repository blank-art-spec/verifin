/// 历史页区分基金公开净值推演与用户主动保存的估值依据，不用当前价格补齐缺日。
library;

import 'package:flutter/material.dart';
import '../app/app_theme.dart';
import '../app/chart_painters.dart';
import '../app/common_widgets.dart';
import '../app/investments/investment_widgets.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/investments/quote_format.dart';
import '../app/investments/investment_decimal.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'fund_reference_history_section.dart';

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
    final account = c.accounts
        .where((value) => value.id == widget.accountId)
        .firstOrNull;
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(title: l.investHistory, showBack: true),
              const SizedBox(height: 12),
              if (p != null && account != null)
                for (final security in p.securities.where(
                  (value) => value.isFund,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: FundReferenceHistorySection(
                      key: ValueKey('fund_history_${security.id}'),
                      account: account,
                      security: security,
                      points: c.fundReferenceHistoryFor(
                        widget.accountId,
                        security.id,
                      ),
                    ),
                  ),
              InvestmentHint(l.investHistoryHint),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('capture_investment_valuation'),
                onPressed: p == null || _saving ? null : _capture,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: Text(l.investHistoryCapture),
              ),
              const SizedBox(height: 16),
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
                        // 日期坐标使用主题次级文字色，避免浅色卡片上的默认淡灰难以阅读。
                        labelColor: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
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
              const SizedBox(height: 16),
              for (final s in snapshots.reversed)
                Builder(
                  builder: (context) {
                    final value = c.investmentSnapshotValuation(
                          widget.accountId,
                          s,
                        ),
                        parts = value?.amounts;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: InvestmentSection(
                        title: formatQuoteTime(context, s.capturedAt),
                        children: [
                          if (parts == null)
                            InvestmentHint(l.investHistoryInvalid)
                          else ...[
                            DetailInfoRow(
                              inline: true,
                              label: l.investNetValue,
                              value: money(parts.net),
                            ),
                            DetailInfoRow(
                              inline: true,
                              label: l.investCash,
                              value: money(value!.cash),
                            ),
                            DetailInfoRow(
                              inline: true,
                              label: l.metricTotalAssets,
                              value: money(parts.assets),
                            ),
                            DetailInfoRow(
                              inline: true,
                              label: l.aiStatTotalLiabilities,
                              value: money(parts.liabilities),
                            ),
                            DetailInfoRow(
                              inline: true,
                              label: l.optionMargin,
                              value: money(value.frozen),
                            ),
                          ],
                          const Divider(height: 24),
                          DetailInfoRow(
                            inline: true,
                            label: l.investHistoryBase,
                            value: values[snapshots.indexOf(s)] == null
                                ? '—'
                                : formatUserMoney(
                                    values[snapshots.indexOf(s)]!,
                                    s.baseCurrencyCode,
                                  ),
                          ),
                          if (s.rateToBase != null)
                            DetailInfoRow(
                              inline: true,
                              label: l.investHistoryRate,
                              value:
                                  '${formatRateValue(s.rateToBase!)}${s.rateDate == null ? '' : ' · ${MaterialLocalizations.of(context).formatMediumDate(s.rateDate!)}'}',
                            ),
                          // 保存时的证券、来源、价格、时间仍完整可见，按依据分组避免长段落挤在一起。
                          const Divider(height: 24),
                          SectionTitle(title: l.investValuationBasis),
                          for (final fact in s.prices.entries)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    p!.securities
                                            .where((v) => v.id == fact.key)
                                            .firstOrNull
                                            ?.symbol ??
                                        fact.key,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  DetailInfoRow(
                                    inline: true,
                                    label: fact.value.manual
                                        ? l.exchangeRateSourceManual
                                        : fact.value.source,
                                    value: formatUserSecurityPrice(
                                      InvestmentDecimal.parse(
                                        fact.value.price,
                                      ).toString(),
                                      p.currencyCode,
                                    ),
                                  ),
                                  Text(
                                    formatQuoteTime(
                                      context,
                                      fact.value.quotedAt,
                                      dateOnly: fact.value.dateOnly,
                                    ),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
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
