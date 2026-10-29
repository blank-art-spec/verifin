/// 基金公开净值历史的纯展示；金额已由领域层按真实账务计算，不在界面补造历史价格。
library;

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/chart_painters.dart';
import '../app/common_widgets.dart';
import '../app/currency_math.dart';
import '../app/investments/fund_reference_history.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_widgets.dart';
import '../app/investments/quote_format.dart';
import '../app/models.dart';
import '../l10n/app_localizations.dart';

/// 展示一个基金的参考收益、市值及有完整价格依据的账户历史，不直接访问 Controller 或仓储。
class FundReferenceHistorySection extends StatefulWidget {
  /// [account] 提供原币及金额颜色，[security] 提供已经核对的基金身份。
  /// [points] 由领域层按净值日期升序生成；缺失账户金额保留 null，不在展示层填零。
  const FundReferenceHistorySection({
    super.key,
    required this.account,
    required this.security,
    required this.points,
  });

  final Account account;
  final StockSecurity security;
  final List<FundReferenceDay> points;

  /// 仅保留“最近二十日/全部”这个短暂阅读状态，不保存账务或设备偏好。
  @override
  State<FundReferenceHistorySection> createState() =>
      _FundReferenceHistorySectionState();
}

class _FundReferenceHistorySectionState
    extends State<FundReferenceHistorySection> {
  static const _recentDays = 20, _maximumDays = 4096;
  bool _expanded = false;

  /// 切换真实账户或基金后恢复最近二十日，防止上一基金的展开状态混入另一身份。
  @override
  void didUpdateWidget(covariant FundReferenceHistorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.security.id != widget.security.id) {
      _expanded = false;
    }
  }

  /// [value] 已是账户原币金额，沿用全局金额与单位偏好，不在此执行汇率换算。
  String _money(num value) =>
      formatUserMoney(value, widget.account.currencyCode);

  /// [value] 是有完整依据的原币参考盈亏；缺失时使用 [l] 的未知文案，不显示零收益。
  String _profit(InvestmentDecimal? value, AppLocalizations l) => value == null
      ? l.investUnknown
      : formatSignedUserMoney(value.toDouble(), widget.account.currencyCode);

  /// [point] 的起点来自上一实际公布净值日；缺少起点时保持 null，不能猜成前一自然日。
  /// 起止日期均经应用语言格式化，跨周末的收益因此明确显示为一个完整观察区间。
  String? _profitInterval(BuildContext context, FundReferenceDay point) {
    final start = point.profitFromDate;
    if (start == null) return null;
    return AppLocalizations.of(context).fundReferenceProfitInterval(
      formatQuoteTime(context, start, dateOnly: true),
      formatQuoteTime(context, point.date, dateOnly: true),
    );
  }

  /// [value] 是可为空的完整账户金额；基金自身已知不代表股票历史价格也完整。
  String _accountMoney(double? value, AppLocalizations l) =>
      value == null ? l.investUnknown : _money(value);

  /// [ids] 使用既有“市场:品种:原代码”身份；只去掉身份前缀，向用户显示原始证券代码。
  /// 保留代码本身可能包含的冒号，未知结构则原样显示，不借用其他账户名称。
  String _missingSymbols(Set<String> ids) {
    final symbols = ids.map((id) {
      final first = id.indexOf(':');
      final second = first < 0 ? -1 : id.indexOf(':', first + 1);
      return second < 0 ? id : id.substring(second + 1);
    }).toList()..sort();
    return symbols.join(', ');
  }

  /// [points] 均有对应基金净值；账户净值图仅在每一点资产、负债、净值完整时绘制。
  /// [accountNet] 选择图表系列，气泡仍使用同一真实来源日，不把日载体渲染为午夜时刻。
  Widget _trend(
    BuildContext context,
    List<FundReferenceDay> points, {
    required bool accountNet,
  }) {
    final l = AppLocalizations.of(context);
    final label = accountNet
        ? l.fundReferenceAccountNetValue
        : l.fundReferenceMarketValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(title: label),
        const SizedBox(height: 8),
        SizedBox(
          height: 170,
          child: Padding(
            // 带年份的日期轴比月日更长，两端留白供窄屏和大字号完整绘制。
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: InteractiveTrendChart(
              key: ValueKey(
                '${accountNet ? 'fund_account_chart' : 'fund_value_chart'}_${widget.security.id}',
              ),
              color: veriRoyal,
              labelColor: Theme.of(context).colorScheme.onSurfaceVariant,
              values: [
                for (final point in points)
                  accountNet
                      ? point.accountNetValue!
                      : point.marketValue.toDouble(),
              ],
              xLabels: [
                formatQuoteTime(
                  context,
                  points.first.date,
                  dateOnly: true,
                  compact: true,
                ),
                formatQuoteTime(
                  context,
                  points.last.date,
                  dateOnly: true,
                  compact: true,
                ),
              ],
              semanticsLabel: label,
              tooltipOf: (index) {
                final point = points[index];
                final interval = _profitInterval(context, point);
                return ChartTooltip(
                  title: formatQuoteTime(context, point.date, dateOnly: true),
                  lines: [
                    ChartTooltipLine(
                      text: _money(
                        accountNet
                            ? point.accountNetValue!
                            : point.marketValue.toDouble(),
                      ),
                    ),
                    if (!accountNet && interval != null)
                      ChartTooltipLine(text: interval),
                    ChartTooltipLine(
                      text: accountNet
                          ? '${l.fundReferenceCash}: ${_money(point.cash)}'
                          : '${l.fundReferenceDailyProfit}: ${_profit(point.dailyProfit, l)}',
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 展示 [point] 的完整原币依据；空值保持未知，缺价证券明确列出，长金额自然换行。
  Widget _day(BuildContext context, FundReferenceDay point) {
    final l = AppLocalizations.of(context);
    final interval = _profitInterval(context, point);
    final adjustment = point.subscriptionAdjustment;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            formatQuoteTime(context, point.date, dateOnly: true),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceNav,
            value: formatUserSecurityPrice(
              point.nav.toString(),
              widget.account.currencyCode,
            ),
          ),
          DetailInfoRow(
            inline: true,
            label: l.investFundQuantity,
            value: point.quantity.toString(),
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceMarketValue,
            value: _money(point.marketValue.toDouble()),
          ),
          if (point.pendingSubscriptionValue.units > BigInt.zero)
            DetailInfoRow(
              inline: true,
              label: l.fundPendingValue,
              value: _money(point.pendingSubscriptionValue.toDouble()),
            ),
          if (interval != null)
            DetailInfoRow(
              inline: true,
              label: l.fundReferenceProfitIntervalLabel,
              value: interval,
            ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceDailyProfit,
            value: _profit(point.dailyProfit, l),
            valueColor: accountBalanceColor(
              context,
              widget.account,
              point.dailyProfit?.toDouble() ?? 0,
            ),
          ),
          if (adjustment != null && adjustment.units != BigInt.zero)
            DetailInfoRow(
              inline: true,
              label: l.fundReferenceSubscriptionAdjustment,
              value: _profit(adjustment, l),
              valueColor: accountBalanceColor(
                context,
                widget.account,
                adjustment.toDouble(),
              ),
            ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceCumulativeProfit,
            value: _profit(point.cumulativeProfit, l),
            valueColor: accountBalanceColor(
              context,
              widget.account,
              point.cumulativeProfit?.toDouble() ?? 0,
            ),
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceCash,
            value: _money(point.cash),
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceAccountAssets,
            value: _accountMoney(point.accountAssets, l),
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceAccountLiabilities,
            value: _accountMoney(point.accountLiabilities, l),
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundReferenceAccountNetValue,
            value: _accountMoney(point.accountNetValue, l),
          ),
          if (point.missingSecurityIds.isNotEmpty)
            InvestmentHint(
              l.fundReferenceMissingSecurities(
                _missingSymbols(point.missingSecurityIds),
              ),
            ),
        ],
      ),
    );
  }

  /// [days] 已按最近在前排序；三点以内自然展开，较长列表使用有限视口按需构建。
  /// 展开全部时仍按需创建可见行，不把最多 4096 日的所有详情一次塞入页面树。
  Widget _details(BuildContext context, List<FundReferenceDay> days) {
    if (days.length <= 3) {
      return Column(children: [for (final day in days) _day(context, day)]);
    }
    return SizedBox(
      height: 420,
      child: ListView.separated(
        key: ValueKey('fund_reference_details_${widget.security.id}'),
        primary: false,
        itemCount: days.length,
        itemBuilder: (context, index) => _day(context, days[index]),
        separatorBuilder: (context, index) => const Divider(height: 1),
      ),
    );
  }

  /// 只读取传入结果；单点不画趋势，账户任一点缺价时不跨未知日期连线或填零。
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final source = widget.points;
    final points = source.length > _maximumDays
        ? source.sublist(source.length - _maximumDays)
        : source;
    final latest = points.lastOrNull;
    final completeAccount =
        points.isNotEmpty &&
        points.every(
          (point) =>
              point.accountAssets?.isFinite == true &&
              point.accountLiabilities?.isFinite == true &&
              point.accountNetValue?.isFinite == true &&
              point.missingSecurityIds.isEmpty,
        );
    final recent = points.reversed
        .take(_expanded ? points.length : _recentDays)
        .toList();
    return InvestmentSection(
      title: '${widget.security.name} · ${l.fundReferenceHistoryTitle}',
      children: [
        Text(
          widget.security.symbol,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (latest == null)
          InvestmentHint(l.fundReferenceHistoryEmpty)
        else ...[
          InvestmentHint(l.fundReferenceHistoryHint),
          DetailInfoRow(
            inline: true,
            label: l.marketNavDate,
            value: formatQuoteTime(context, latest.date, dateOnly: true),
          ),
          const SizedBox(height: 8),
          InvestmentMetricPair(
            filled: false,
            first: SummaryMetric(
              label: l.fundReferenceDailyProfit,
              value: _profit(latest.dailyProfit, l),
              color: accountBalanceColor(
                context,
                widget.account,
                latest.dailyProfit?.toDouble() ?? 0,
              ),
              allowValueWrap: true,
            ),
            second: SummaryMetric(
              label: l.fundReferenceCumulativeProfit,
              value: _profit(latest.cumulativeProfit, l),
              color: accountBalanceColor(
                context,
                widget.account,
                latest.cumulativeProfit?.toDouble() ?? 0,
              ),
              allowValueWrap: true,
            ),
          ),
          if (_profitInterval(context, latest) case final String interval)
            DetailInfoRow(
              inline: true,
              label: l.fundReferenceProfitIntervalLabel,
              value: interval,
            ),
          if (points.length == 1)
            InvestmentHint(l.fundReferenceSinglePoint)
          else ...[
            const SizedBox(height: 16),
            _trend(context, points, accountNet: false),
            if (completeAccount) ...[
              const SizedBox(height: 16),
              _trend(context, points, accountNet: true),
            ],
          ],
          if (!completeAccount) InvestmentHint(l.fundReferenceMissingPrices),
          if (points.any(
            (point) =>
                point.dailyProfit == null || point.cumulativeProfit == null,
          ))
            InvestmentHint(l.fundReferenceUnknownProfitHint),
          if (source.length > _maximumDays)
            InvestmentHint(l.fundReferenceHistoryLimited(_maximumDays)),
          const Divider(height: 24),
          SectionTitle(title: l.fundReferenceDetails),
          if (points.length > _recentDays)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('fund_reference_expand_${widget.security.id}'),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded
                      ? l.fundReferenceShowRecent
                      : l.fundReferenceShowAll(points.length),
                ),
              ),
            ),
          _details(context, recent),
        ],
      ],
    );
  }
}
