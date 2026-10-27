/// 股票账户详情和编辑页；所有账务写入均经 Controller 公共命令。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../app/common_widgets.dart';
import '../app/investments/investment_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/stock_projection.dart';
import '../app/investments/quote_format.dart';
import '../app/investments/market_quote.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';
import 'option_editor_page.dart';
import 'market_quotes_page.dart';
import 'investment_history_page.dart';
import '../app/investments/investment_valuation.dart';

/// 将资产占比按当前语言显示为一位小数的百分比，不修改原始精度。
///
/// [l] 提供应用语言与百分比格式；[share] 是估值层计算的 0–1 比率，
/// 空头义务可大于 1。分母为零或价格不完整时传入 null，显示“未知”，
/// 避免把无法计算的占比误写成 0%。
String _investmentShareText(AppLocalizations l, double? share) =>
    share == null ? l.investUnknown : l.investAllocationPercent(share);

/// 指定币种账户的持仓与记录；父账户通过既有子账户列表进入。
class InvestmentPage extends StatelessWidget {
  /// [accountId] 必须是真实账户 ID；账户被删除时显示空态，不回退其他账户。
  const InvestmentPage({super.key, required this.accountId});
  final String accountId;

  /// 根据 [event] 的业务类型显示量价、总额或拆股比例，避免把股息总额称为成交价。
  /// [currency] 是结算币种；金额复用现有格式，数量及拆股比例保留原始精度。
  String _eventDetails(StockEvent event, AppLocalizations l, String currency) {
    final fees =
        '${l.investFees} ${formatUserMoney(InvestmentDecimal.parse(event.fee).toDouble(), currency)}';
    return switch (event.kind) {
      StockEventKind.dividend || StockEventKind.fee =>
        '${l.investTotalAmount} ${formatUserMoney(InvestmentDecimal.parse(event.price).toDouble(), currency)} · $fees',
      StockEventKind.split =>
        '${l.investSplitNew} ${event.quantity} : ${l.investSplitOld} ${event.price}',
      StockEventKind.transferIn ||
      StockEventKind.transferOut => '${l.investQuantity} ${event.quantity}',
      StockEventKind.optionMargin =>
        '${l.optionMargin}: ${event.marginAfter == null ? l.investUnknown : formatUserMoney(InvestmentDecimal.parse(event.marginAfter!).toDouble(), currency)}',
      StockEventKind.optionPhysicalSettle || StockEventKind.optionExpire =>
        '${l.optionContracts} ${event.quantity} · ${event.kind.label(l)} · $fees',
      StockEventKind.optionCashSettle =>
        '${l.optionContracts} ${event.quantity} · ${l.optionActualSettlement} ${formatUserMoney(InvestmentDecimal.parse(event.price).toDouble(), currency)} · $fees',
      StockEventKind.optionBuyOpen ||
      StockEventKind.optionSellClose ||
      StockEventKind.optionSellOpen ||
      StockEventKind.optionBuyClose =>
        '${l.optionContracts} ${event.quantity} · ${l.optionPremium} ${formatUserSecurityPrice(event.price, currency)} · $fees',
      _ =>
        '${l.investQuantity} ${event.quantity} × ${formatUserSecurityPrice(event.price, currency)} · $fees',
    };
  }

  /// 推入完整编辑页面，取消只丢弃本地草稿。
  void _edit(
    BuildContext context, {
    StockEvent? event,
    String? securityId,
    bool setup = false,
    bool transfer = false,
    bool short = false,
  }) {
    final p = VeriFinScope.of(context).investmentFor(accountId);
    final isOption =
        p?.securities.any(
          (s) => s.id == (event?.securityId ?? securityId) && s.option != null,
        ) ??
        false;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => isOption
              ? OptionEditorPage(
                  accountId: accountId,
                  event: event,
                  securityId: securityId,
                )
              : StockEditorPage(
                  accountId: accountId,
                  event: event,
                  securityId: securityId,
                  setup: setup,
                  transfer: transfer,
                  initialShort: short,
                ),
        ),
      ),
    );
  }

  /// 以同一纯计算结果展示净值、资产构成、盈亏及占总资产比例。
  /// 净值为主信息，现金/多头用实色面板，次级明细与盈亏分组排列；
  /// 窄屏与大字号允许完整换行。占比仍使用该币种账户的正现金与多头市值。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final account = c.accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(l.accountNameRequired))),
      );
    }
    final originalPortfolio = c.investmentFor(accountId);
    final portfolio = originalPortfolio == null
        ? null
        : c.pricedInvestmentPortfolio(originalPortfolio);
    final projection = c.investmentProjection(accountId);
    final valuation = portfolio == null
        ? null
        : valueStocks(portfolio, projection!);
    final cash = c.accountBalance(account);
    final detail = portfolio == null
        ? null
        : valueInvestmentAccount(portfolio, cash);
    String money(double value) => formatUserMoney(value, account.currencyCode);
    final surfaceText = Theme.of(context).colorScheme.onSurface;
    final secondaryText = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(
                title: l.investTitle,
                subtitle: currencyUnitSubtitle(
                  l,
                  account.name,
                  account.currencyCode,
                ),
                showBack: true,
                actions: [
                  if (portfolio != null)
                    HeaderAction(
                      icon: Icons.history,
                      tooltip: l.investHistory,
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              InvestmentHistoryPage(accountId: accountId),
                        ),
                      ),
                    ),
                  HeaderAction(
                    icon: Icons.cloud_outlined,
                    tooltip: l.marketTitle,
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => MarketQuotesPage(accountId: accountId),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (portfolio == null) ...[
                VeriCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.investSetupHint),
                      const SizedBox(height: 12),
                      Text('${l.investCurrentCash}：${money(cash)}'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _edit(context, setup: true),
                        child: Text(l.investEnable),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                VeriCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.investNetValue,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: secondaryText),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        valuation!.marketValue == null
                            ? l.investNoQuotes
                            : money(cash + valuation.marketValue!.toDouble()),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                      ),
                      const SizedBox(height: 16),
                      InvestmentMetricPair(
                        first: SummaryMetric(
                          label: l.investCash,
                          value: money(cash),
                          color: surfaceText,
                          detail:
                              '${l.investCashShare} ${_investmentShareText(l, detail!.cashShare)}',
                          allowValueWrap: true,
                        ),
                        second: SummaryMetric(
                          label: l.investLongValue,
                          value: detail.longValue == null
                              ? l.investUnknown
                              : money(detail.longValue!),
                          color: surfaceText,
                          detail:
                              '${l.investHoldingsShare} ${_investmentShareText(l, detail.holdingsShare)}',
                          allowValueWrap: true,
                        ),
                      ),
                      const SizedBox(height: 14),
                      InvestmentMetricPair(
                        filled: false,
                        first: SummaryMetric(
                          label: l.investMarketValue,
                          value: valuation.marketValue == null
                              ? l.investUnknown
                              : money(valuation.marketValue!.toDouble()),
                          color: secondaryText,
                          allowValueWrap: true,
                        ),
                        second: SummaryMetric(
                          label: l.investShortObligation,
                          value: detail.shortObligation == null
                              ? l.investUnknown
                              : money(detail.shortObligation!),
                          color: secondaryText,
                          detail: (detail.shortObligation ?? 0) > 0
                              ? '${l.investShortShare} ${_investmentShareText(l, detail.shortObligationShare)}'
                              : null,
                          allowValueWrap: true,
                        ),
                      ),
                      const Divider(height: 24),
                      InvestmentMetricPair(
                        filled: false,
                        first: SummaryMetric(
                          label: l.investRealized,
                          value: projection!.realizedComplete
                              ? money(projection.realized.toDouble())
                              : l.investUnknown,
                          color: accountBalanceColor(
                            context,
                            account,
                            projection.realized.toDouble(),
                          ),
                          allowValueWrap: true,
                        ),
                        second: SummaryMetric(
                          label: l.investUnrealized,
                          value: valuation.unrealized == null
                              ? l.investUnknown
                              : money(valuation.unrealized!.toDouble()),
                          color: accountBalanceColor(
                            context,
                            account,
                            valuation.unrealized?.toDouble() ?? 0,
                          ),
                          allowValueWrap: true,
                        ),
                      ),
                      const Divider(height: 24),
                      DetailInfoRow(
                        inline: true,
                        label: l.investIncome,
                        value: money(projection.income.toDouble()),
                      ),
                      if (portfolio.securities.any(
                        (s) => s.option != null,
                      )) ...[
                        DetailInfoRow(
                          inline: true,
                          label: l.optionMargin,
                          value: money(projection.frozenMargin.toDouble()),
                        ),
                        DetailInfoRow(
                          inline: true,
                          label: l.optionAvailableCash,
                          value: money(
                            cash - projection.frozenMargin.toDouble(),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        (detail.amounts?.liabilities ?? 0) > 0
                            ? l.investAllocationLiabilityHint
                            : l.investAllocationHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _edit(context),
                      icon: const Icon(Icons.add),
                      label: Text(l.investNewTrade),
                    ),
                    OutlinedButton(
                      style: investmentOutlineButtonStyle(context),
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              OptionEditorPage(accountId: accountId),
                        ),
                      ),
                      child: Text(l.optionTitle),
                    ),
                    OutlinedButton(
                      style: investmentOutlineButtonStyle(context),
                      onPressed: () async {
                        final value = await showTextInputDialog(
                          context: context,
                          title: l.investCashCheck,
                          label: l.investCashHint,
                          initialValue: cash.toString(),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                        );
                        if (!context.mounted || value == null) return;
                        final number = double.tryParse(value);
                        if (number == null || !number.isFinite) return;
                        final saved = await c.saveBalanceAnchor(
                          account: account,
                          effectiveAt: DateTime.now(),
                          balance: number,
                        );
                        if (!context.mounted) return;
                        if (!saved) {
                          unawaited(
                            VeriFeedbackHost.of(context).showMessage(
                              message: l.investSaveError,
                              tone: VeriFeedbackTone.error,
                            ),
                          );
                        }
                      },
                      child: Text(l.investCashCheck),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                InvestmentHint(
                  portfolio.marketPriceIds.isEmpty
                      ? l.investManualHint
                      : l.marketEffectiveHint,
                ),
                if (portfolio.securities.any((s) => s.option != null))
                  InvestmentHint(l.optionMarginHint),
                const SizedBox(height: 16),
                SectionTitle(title: l.investPositions),
                const SizedBox(height: 8),
                if (projection.positions.isEmpty)
                  VeriCard(child: Text(l.investEmpty)),
                for (final position in projection.positions) ...[
                  _StockPositionCard(
                    accountId: accountId,
                    portfolio: portfolio,
                    position: position,
                    accountValuation: detail,
                    onTransfer: () => _edit(
                      context,
                      securityId: position.securityId,
                      transfer: true,
                      short: position.short,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 14),
                SectionTitle(title: l.investRecords),
                const SizedBox(height: 8),
                for (final event in [
                  ...portfolio.events,
                ]..sort((a, b) => compareStockEvents(b, a))) ...[
                  VeriCard(
                    onTap: event.batchId == null
                        ? () => _edit(context, event: event)
                        : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${event.kind.label(l)} · ${portfolio.securities.firstWhere((s) => s.id == event.securityId).symbol}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(_eventDetails(event, l, account.currencyCode)),
                        const SizedBox(height: 6),
                        Text(
                          MaterialLocalizations.of(
                            context,
                          ).formatFullDate(event.occurredAt),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        if (event.note.isNotEmpty) Text(event.note),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
              const SizedBox(height: 12),
              InvestmentHint(l.investNoOptions),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一项持仓使用统一图标、金额格式和纯计算，不维护另一份可写数量。
class _StockPositionCard extends StatelessWidget {
  /// [accountId] 指向当前币种账户；[portfolio] 与 [position] 共享当前有效参考价。
  /// [accountValuation] 为顶部概览使用的同一估值，保证所有持仓采用同一占比分母。
  /// [onTransfer] 进入两端原子转移表单，价格与成本补齐分别走 Controller。
  const _StockPositionCard({
    required this.accountId,
    required this.portfolio,
    required this.position,
    required this.accountValuation,
    required this.onTransfer,
  });
  final String accountId;
  final InvestmentPortfolio portfolio;
  final StockPosition position;
  final InvestmentAccountValuation accountValuation;
  final VoidCallback onTransfer;

  /// 展示方向、数量、总成本、参考价及占总资产比例；未知成本不显示成零。
  /// 多头以市值计算持仓占比，空头以回补义务单列，期权沿用显式权利金乘数。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final security = portfolio.securities.firstWhere(
      (s) => s.id == position.securityId,
    );
    final price = portfolio.manualPrices[position.securityId];
    final quote = portfolio.marketPriceIds.contains(security.id)
        ? c.investmentQuoteSync.quotesFor(portfolio)[security.id]
        : null;
    final quoteReference = quote?.reference(
      MarketQuoteRequest(security),
      c.investmentQuoteSync.clock(),
    );
    final value = price == null
        ? null
        : securityPositionValue(
            security,
            position.quantity,
            InvestmentDecimal.parse(price),
            CurrencyCatalog.require(portfolio.currencyCode).minorUnit,
          );
    final pnl = value == null || position.cost == null
        ? null
        : position.short
        ? position.cost! - value
        : value - position.cost!;
    return VeriCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 长合约名称换行时，方向仍与标题首行基线对齐。
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  '${security.name} · ${security.symbol}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                position.short ? l.investShortPosition : l.investLong,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            security.market.label(l),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 20),
          DetailInfoRow(
            inline: true,
            label: security.option == null
                ? l.investQuantity
                : l.optionContracts,
            value: position.quantity.toString(),
          ),
          if (security.option != null) ...[
            DetailInfoRow(
              inline: true,
              label: l.optionRightType,
              value: security.option!.right.label(l),
            ),
            DetailInfoRow(
              inline: true,
              label: l.optionExpiry,
              value: MaterialLocalizations.of(
                context,
              ).formatMediumDate(DateTime.parse(security.option!.expiry)),
            ),
            DetailInfoRow(
              inline: true,
              label: l.optionMultiplier,
              value: security.option!.premiumMultiplier,
            ),
            if (!security.option!.confirmed ||
                security.option!.settlement == OptionSettlement.unsupported ||
                optionExpired(security.option!, DateTime.now()) ||
                c
                    .investmentProjection(accountId)!
                    .optionReviews
                    .contains(security.id))
              InvestmentHint(l.optionPending),
          ],
          DetailInfoRow(
            inline: true,
            label: l.investCost,
            value: position.cost == null
                ? l.investUnknown
                : formatUserMoney(
                    position.cost!.toDouble(),
                    portfolio.currencyCode,
                  ),
          ),
          DetailInfoRow(
            inline: true,
            label: quoteReference == null
                ? l.investReference
                : l.marketEffectivePrice,
            value: price == null
                ? l.investUnknown
                : formatUserSecurityPrice(price, portfolio.currencyCode),
          ),
          if (quoteReference == null &&
              portfolio.marketPriceIds.contains(security.id))
            InvestmentHint(l.marketNoQuote),
          DetailInfoRow(
            inline: true,
            label: position.short ? l.investShortShare : l.investHoldingsShare,
            value: _investmentShareText(
              l,
              accountValuation.shareOfAssets(value?.toDouble()),
            ),
          ),
          DetailInfoRow(
            inline: true,
            label: l.investUnrealized,
            value: pnl == null
                ? l.investUnknown
                : formatSignedUserMoney(pnl.toDouble(), portfolio.currencyCode),
            valueColor: accountBalanceColor(
              context,
              c.accounts.firstWhere((a) => a.id == accountId),
              pnl?.toDouble() ?? 0,
            ),
          ),
          if (quoteReference != null) ...[
            const SizedBox(height: 12),
            // 来源是价格依据，集中放在指标之后；短日期仍保留年份、时刻与时区。
            InvestmentQuoteDetails(
              source: quote!.source,
              quoteTime: formatQuoteTime(
                context,
                quoteReference.time,
                compact: true,
              ),
            ),
          ],
          const Divider(height: 20),
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: () async {
                  final raw = await showTextInputDialog(
                    context: context,
                    title: l.investReprice,
                    initialValue: price ?? '',
                    label: l.investReference,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  );
                  if (!context.mounted || raw == null) return;
                  try {
                    final ok = await c.setStockReferencePrice(
                      accountId,
                      position.securityId,
                      raw,
                    );
                    if (!context.mounted) return;
                    if (!ok) {
                      unawaited(
                        VeriFeedbackHost.of(context).showMessage(
                          message: l.investSaveError,
                          tone: VeriFeedbackTone.error,
                        ),
                      );
                    }
                  } on FormatException {
                    if (!context.mounted) return;
                    unawaited(
                      VeriFeedbackHost.of(context).showMessage(
                        message: l.investSaveError,
                        tone: VeriFeedbackTone.error,
                      ),
                    );
                  }
                },
                child: Text(
                  quoteReference == null ? l.investReprice : l.marketSetManual,
                ),
              ),
              if (security.option == null)
                TextButton(onPressed: onTransfer, child: Text(l.investTransfer))
              else ...[
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => OptionEditorPage(
                        accountId: accountId,
                        securityId: security.id,
                        initialShort: position.short,
                      ),
                    ),
                  ),
                  child: Text(l.optionTitle),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => OptionEditorPage(
                        accountId: accountId,
                        securityId: security.id,
                        specificationOnly: true,
                      ),
                    ),
                  ),
                  child: Text(l.optionVerifySpec),
                ),
              ],
              if (position.cost == null)
                TextButton(
                  onPressed: () async {
                    final raw = await showTextInputDialog(
                      context: context,
                      title: l.investCostEdit,
                      label: l.investOpeningCost,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    );
                    if (!context.mounted || raw == null) return;
                    try {
                      final ok = await c.setStockOpeningCost(
                        accountId,
                        position.securityId,
                        position.short,
                        raw,
                      );
                      if (!context.mounted) return;
                      if (!ok) {
                        unawaited(
                          VeriFeedbackHost.of(context).showMessage(
                            message: l.investSaveError,
                            tone: VeriFeedbackTone.error,
                          ),
                        );
                      }
                    } on FormatException {
                      if (!context.mounted) return;
                      unawaited(
                        VeriFeedbackHost.of(context).showMessage(
                          message: l.investSaveError,
                          tone: VeriFeedbackTone.error,
                        ),
                      );
                    }
                  },
                  child: Text(l.investCostEdit),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 股票期初、成交和转移的完整页面；未点保存不会产生任何用户数据。
class StockEditorPage extends StatefulWidget {
  /// [setup] 表示显式启用；[event] 非空表示编辑；[transfer] 表示跨账户原子批次。
  const StockEditorPage({
    super.key,
    required this.accountId,
    this.event,
    this.securityId,
    this.setup = false,
    this.transfer = false,
    this.initialShort = false,
  });
  final String accountId;
  final StockEvent? event;
  final String? securityId;
  final bool setup, transfer;
  final bool initialShort;

  /// 为每份编辑草稿创建独立状态，字段不绑定 Controller 集合。
  @override
  State<StockEditorPage> createState() => _StockEditorPageState();
}

class _StockEditorPageState extends State<StockEditorPage> {
  final _fields = <String, TextEditingController>{};
  StockMarket _market = StockMarket.us;
  StockEventKind _kind = StockEventKind.buy;
  late DateTime _date;
  late String _id, _bookId;
  int _sequence = 0;
  bool _initialized = false,
      _saving = false,
      _financing = false,
      _short = false;
  String? _error, _target;

  /// 延迟初始化到可读取 Scope 时；保留已有事件 ID/序号，重试不会重复成交。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final c = VeriFinScope.of(context);
    _bookId = c.activeBook.id;
    final account = c.accounts
        .where((a) => a.id == widget.accountId)
        .firstOrNull;
    if (account == null) {
      return;
    }
    final p = c.investmentFor(account.id), e = widget.event;
    _bookId = account.bookId;
    _market = account.currencyCode == 'HKD'
        ? StockMarket.hk
        : account.currencyCode == 'CNY'
        ? StockMarket.cn
        : StockMarket.us;
    final security = p?.securities
        .where((s) => s.id == (e?.securityId ?? widget.securityId))
        .firstOrNull;
    _market = security?.market ?? _market;
    _kind = e?.kind ?? StockEventKind.buy;
    _short = widget.initialShort;
    _date = e?.occurredAt ?? DateTime.now();
    _id = e?.id ?? 'stock-${DateTime.now().microsecondsSinceEpoch}';
    _sequence =
        e?.sequence ??
        (p?.events.fold<int>(
              0,
              (v, e) => e.sequence >= v ? e.sequence + 1 : v,
            ) ??
            0);
    _financing = p?.allowFinancing ?? false;
    for (final pair in {
      'symbol': security?.symbol ?? '',
      'name': security?.name ?? '',
      'quantity': e?.quantity ?? '',
      'price': e?.price ?? '',
      'fee': e?.fee ?? '0',
      'reference': p?.manualPrices[security?.id] ?? '',
      'cash': c
          .accountBalance(account)
          .toStringAsFixed(
            CurrencyCatalog.require(account.currencyCode).minorUnit,
          ),
      'cost': '',
      'note': e?.note ?? '',
    }.entries) {
      _fields[pair.key] = TextEditingController(text: pair.value);
    }
  }

  /// 释放输入资源，取消编辑不触发任何保存。
  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  /// [key] 定位草稿及测试输入框，[label] 独立占位并允许完整换行；
  /// [numeric] 使用带符号的小数键盘，[readOnly] 保持既有只读规则。
  Widget _field(
    String key,
    String label, {
    bool numeric = false,
    bool readOnly = false,
  }) => InvestmentInputField(
    label: label,
    child: TextField(
      key: ValueKey('stock-$key'),
      controller: _fields[key],
      readOnly: readOnly,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: investmentInputDecoration(context),
    ),
  );

  /// 提交前核对仍在同一账本；校验失败保留所有输入，保存中禁止重复点击。
  Future<void> _save() async {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (_saving || c.activeBook.id != _bookId) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    var ok = false;
    try {
      final account = c.accounts.firstWhere((a) => a.id == widget.accountId);
      final symbol = _fields['symbol']!.text.trim().toUpperCase();
      final security = StockSecurity(
        symbol: symbol,
        name: _fields['name']!.text.trim(),
        market: _market,
        currencyCode: account.currencyCode,
      );
      final quantity = _fields['quantity']!.text.trim();
      final reference = _fields['reference']!.text.trim();
      if (widget.setup) {
        final hasHolding = quantity.isNotEmpty;
        if (hasHolding &&
            (symbol.isEmpty || security.name.isEmpty || reference.isEmpty)) {
          throw const FormatException('期初资料不完整');
        }
        ok = await c.enableInvestment(
          accountId: account.id,
          openingCash: _fields['cash']!.text,
          openedAt: _date,
          securities: hasHolding ? [security] : [],
          openingHoldings: hasHolding
              ? [
                  StockHolding(
                    securityId: security.id,
                    short: _short,
                    quantity: quantity,
                    cost: _fields['cost']!.text.trim().isEmpty
                        ? null
                        : _fields['cost']!.text.trim(),
                  ),
                ]
              : [],
          manualPrices: hasHolding ? {security.id: reference} : {},
          allowFinancing: _financing,
        );
      } else if (widget.transfer) {
        if (_target == null) throw const FormatException('请选择转入账户');
        ok = await c.transferStock(
          fromAccountId: account.id,
          toAccountId: _target!,
          securityId: security.id,
          quantity: quantity,
          short: _short,
          occurredAt: _date,
          batchId: _id,
        );
      } else {
        if (symbol.isEmpty || security.name.isEmpty || reference.isEmpty) {
          throw const FormatException('请补充证券及参考价格');
        }
        final event = StockEvent(
          id: _id,
          securityId: security.id,
          kind: _kind,
          occurredAt: _date,
          sequence: _sequence,
          quantity:
              {StockEventKind.dividend, StockEventKind.fee}.contains(_kind)
              ? '0'
              : quantity,
          price: _fields['price']!.text,
          fee: _kind == StockEventKind.split ? '0' : _fields['fee']!.text,
          note: _fields['note']!.text.trim(),
        );
        ok = await c.saveStockEvent(
          accountId: account.id,
          security: security,
          event: event,
          referencePrice: reference,
        );
      }
    } on FormatException {
      // 输入错误由内联本地化提示反馈，草稿继续保留；持久化失败由 Controller 记录。
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = l.investSaveError;
      });
    }
  }

  /// 展示可取消的完整表单；市场/动作复用既有锚点选择器，日期时间沿用公共入口。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (c.activeBook.id != _bookId ||
        !c.accounts.any((a) => a.id == widget.accountId)) {
      return Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: Column(
              children: [
                VeriHeader(title: l.investTitle, showBack: true),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l.investSaveError),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final targets = c.accounts
        .where(
          (a) =>
              a.id != widget.accountId &&
              c.investmentFor(a.id) != null &&
              a.currencyCode ==
                  c.accounts
                      .firstWhere((a) => a.id == widget.accountId)
                      .currencyCode,
        )
        .toList();
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                VeriHeader(
                  title: widget.setup
                      ? l.investEnableOpening
                      : widget.transfer
                      ? l.investTransfer
                      : l.investNewTrade,
                  showBack: true,
                ),
                const SizedBox(height: 12),
                if (widget.setup) ...[
                  Text(l.investSetupHint),
                  const SizedBox(height: 12),
                  _field('cash', l.investOpeningCash, numeric: true),
                ],
                InvestmentSection(
                  title: l.investSecurityDetails,
                  children: [
                    if (!widget.setup && !widget.transfer)
                      VeriAnchoredChoice<StockEventKind>(
                        values: const [
                          StockEventKind.buy,
                          StockEventKind.sell,
                          StockEventKind.shortSell,
                          StockEventKind.cover,
                          StockEventKind.dividend,
                          StockEventKind.fee,
                          StockEventKind.split,
                        ],
                        selected: _kind,
                        idOf: (v) => v.name,
                        labelOf: (v) => v.label(l),
                        onSelected: (v) => setState(() => _kind = v),
                        semanticLabel: l.investEventType,
                        builder: (context, open, active) => SettingsRow(
                          icon: Icons.swap_horiz,
                          title: l.investEventType,
                          trailing: _kind.label(l),
                          trailingMaxLines: null,
                          trailingIcon: Icons.unfold_more,
                          onTap: open,
                        ),
                      ),
                    VeriAnchoredChoice<StockMarket>(
                      values: StockMarket.values,
                      selected: _market,
                      idOf: (v) => v.name,
                      labelOf: (v) => v.label(l),
                      onSelected: (v) => setState(() => _market = v),
                      semanticLabel: l.investMarket,
                      builder: (context, open, active) => SettingsRow(
                        icon: Icons.public,
                        title: l.investMarket,
                        trailing: _market.label(l),
                        trailingMaxLines: null,
                        trailingIcon: Icons.unfold_more,
                        onTap: widget.transfer || widget.event != null
                            ? null
                            : open,
                      ),
                    ),
                    _field(
                      'symbol',
                      l.investSymbol,
                      readOnly: widget.transfer || widget.event != null,
                    ),
                    _field('name', l.investName, readOnly: widget.transfer),
                  ],
                ),
                const SizedBox(height: 12),
                InvestmentSection(
                  title: l.investTradeDetails,
                  children: [
                    if (widget.setup ||
                        widget.transfer ||
                        !{
                          StockEventKind.dividend,
                          StockEventKind.fee,
                        }.contains(_kind))
                      _field(
                        'quantity',
                        widget.setup
                            ? l.investOpeningQuantity
                            : _kind == StockEventKind.split
                            ? l.investSplitNew
                            : l.investQuantity,
                        numeric: true,
                      ),
                    if (widget.setup) ...[
                      _field('cost', l.investOpeningCost, numeric: true),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _short,
                        onChanged: (v) => setState(() => _short = v),
                        title: Text(l.investShortPosition),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _financing,
                        onChanged: (v) => setState(() => _financing = v),
                        title: Text(l.investFinance),
                      ),
                    ],
                    if (!widget.setup && !widget.transfer) ...[
                      _field('price', switch (_kind) {
                        StockEventKind.dividend ||
                        StockEventKind.fee => l.investTotalAmount,
                        StockEventKind.split => l.investSplitOld,
                        _ => l.investPrice,
                      }, numeric: true),
                      if (_kind != StockEventKind.split)
                        _field('fee', l.investFees, numeric: true),
                      if (_kind == StockEventKind.split)
                        Text(
                          l.investSplitHint,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                    if (!widget.transfer) ...[
                      const SizedBox(height: 12),
                      _field('reference', l.investReference, numeric: true),
                      Text(
                        l.investReferenceConsent,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (widget.transfer) ...[
                      Text(l.investTransferHint),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l.investTarget),
                        subtitle: Text(
                          targets
                                  .where((a) => a.id == _target)
                                  .firstOrNull
                                  ?.name ??
                              l.investTransferHint,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: targets.isEmpty
                            ? null
                            : () async {
                                final selected = await showOptionSheet<String>(
                                  context: context,
                                  title: l.investTarget,
                                  values: targets.map((a) => a.id).toList(),
                                  selected: _target ?? targets.first.id,
                                  labelOf: (id) => targets
                                      .firstWhere((a) => a.id == id)
                                      .name,
                                  showSelectedMarker: _target != null,
                                );
                                if (!mounted || selected == null) {
                                  return;
                                }
                                setState(() => _target = selected);
                              },
                      ),
                      SwitchListTile(
                        value: _short,
                        onChanged: (v) => setState(() => _short = v),
                        title: Text(l.investShortPosition),
                      ),
                    ],
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        widget.setup ? l.investOpeningDate : l.investDate,
                      ),
                      subtitle: Text(
                        '${MaterialLocalizations.of(context).formatFullDate(_date)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_date))}',
                      ),
                      onTap: () async {
                        final day = await showEntryDatePicker(
                          context: context,
                          initialDateTime: _date,
                        );
                        if (!context.mounted || day == null) return;
                        final time = await showEntryTimePicker(
                          context: context,
                          initialDateTime: day,
                        );
                        if (!mounted || time == null) return;
                        setState(() => _date = time);
                      },
                    ),
                    _field('note', l.investNote),
                  ],
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l.investSave),
                ),
                if (widget.event != null)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () async {
                            final confirm = await showConfirmDialog(
                              context,
                              title: l.investDelete,
                              message: l.investDeleteHint,
                              destructive: true,
                            );
                            if (!context.mounted || confirm != true) return;
                            final ok = await c.deleteStockEvent(
                              widget.accountId,
                              widget.event!.id,
                            );
                            if (!context.mounted) return;
                            if (ok) {
                              Navigator.of(context).pop();
                            } else {
                              setState(() => _error = l.investSaveError);
                            }
                          },
                    child: Text(l.investDelete),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
