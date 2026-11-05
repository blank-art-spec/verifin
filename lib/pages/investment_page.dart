/// 股票账户详情和编辑页；所有账务写入均经 Controller 公共命令。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/investments/investment_widgets.dart';
import '../app/investments/investment_security_autocomplete.dart';
import '../app/investments/investment_security_suggestions.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/feedback.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_opening_draft.dart';
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
import 'investment_setup_page.dart';
import 'fund_entry_page.dart';
import 'account_information_section.dart';
import 'transaction_entry_page.dart';
import 'entry_editor_session.dart';
import 'stock_opening_cost_page.dart';
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

  /// 从证券账户内新增时固定本次目标账本并预填实际币种账户。
  /// [account] 是当前已初始化投资组合的账户，不传聚合主账户或“无账户”。
  Future<void> _newTrade(BuildContext context, Account account) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransactionEntryPage(
          bookId: account.bookId,
          initialAccountId: account.id,
        ),
      ),
    );
  }

  /// 根据 [event] 的业务类型显示量价、总额或拆股比例，避免把股息总额称为成交价。
  /// [currency] 是结算币种；[fund] 表示份额而非股数，数量和价格均保留原始精度。
  String _eventDetails(
    StockEvent event,
    AppLocalizations l,
    String currency, {
    bool fund = false,
  }) {
    final fees =
        '${l.investFees} ${formatUserMoney(InvestmentDecimal.parse(event.fee).toDouble(), currency)}';
    return switch (event.kind) {
      StockEventKind.dividend || StockEventKind.fee =>
        '${l.investTotalAmount} ${formatUserMoney(InvestmentDecimal.parse(event.price).toDouble(), currency)} · $fees',
      StockEventKind.split =>
        '${l.investSplitNew} ${event.quantity} : ${l.investSplitOld} ${event.price}',
      StockEventKind.fundHoldingBaseline =>
        '${l.investFundQuantity} ${event.quantity} · ${l.fundTotalCost} ${event.carriedCost == null ? l.investUnknown : formatUserMoney(InvestmentDecimal.parse(event.carriedCost!).toDouble(), currency)}',
      StockEventKind.fundAcquire =>
        '${l.investFundQuantity} ${event.quantity} × ${formatUserSecurityPrice(event.price, currency)} · ${l.fundCashAmount} ${event.carriedCost == null ? l.investUnknown : formatUserMoney(InvestmentDecimal.parse(event.carriedCost!).toDouble(), currency)}',
      StockEventKind.transferIn || StockEventKind.transferOut =>
        '${fund ? l.investFundQuantity : l.investQuantity} ${event.quantity}',
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
        '${fund ? l.investFundQuantity : l.investQuantity} ${event.quantity} × ${formatUserSecurityPrice(event.price, currency)} · $fees',
    };
  }

  /// 推入对应业务的完整编辑页面，取消只丢弃本地草稿。
  /// 基金申购确认按原申请进入核对页，基准进入专用表单，避免误改为普通股票买入。
  void _edit(
    BuildContext context, {
    StockEvent? event,
    String? securityId,
    bool setup = false,
    bool transfer = false,
    bool short = false,
  }) {
    final p = VeriFinScope.of(context).investmentFor(accountId);
    if (event?.kind == StockEventKind.fundAcquire ||
        event?.kind == StockEventKind.fundHoldingBaseline) {
      if (event!.kind == StockEventKind.fundAcquire &&
          event.fundSubscriptionId == null) {
        return;
      }
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => FundEntryPage(
              accountId: accountId,
              mode: event.kind == StockEventKind.fundHoldingBaseline
                  ? FundEntryMode.holdingBaseline
                  : FundEntryMode.purchase,
              subscriptionId: event.fundSubscriptionId,
              baselineEvent: event.kind == StockEventKind.fundHoldingBaseline
                  ? event
                  : null,
            ),
          ),
        ),
      );
      return;
    }
    final isOption =
        p?.securities.any(
          (s) => s.id == (event?.securityId ?? securityId) && s.option != null,
        ) ??
        false;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => setup
              ? InvestmentSetupPage(accountId: accountId)
              : isOption
              ? OptionEditorPage(
                  accountId: accountId,
                  event: event,
                  securityId: securityId,
                )
              : StockEditorPage(
                  accountId: accountId,
                  event: event,
                  securityId: securityId,
                  transfer: transfer,
                  initialShort: short,
                ),
        ),
      ),
    );
  }

  /// 以同一纯计算结果展示净值、资产构成、盈亏及占总资产比例。
  /// 净值为主信息，现金/多头用实色面板，次级明细与盈亏分组排列；
  /// 窄屏与大字号允许完整换行。申购在途资产单独披露，净值采用统一估值结果。
  /// 已有基金清仓后仍提供按原身份新增交易的入口，再次买入不会误建成同代码股票。
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
    const actionStyle = ButtonStyle(
      alignment: AlignmentDirectional.centerStart,
      visualDensity: VisualDensity.standard,
      minimumSize: WidgetStatePropertyAll(Size(0, 48)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      iconSize: WidgetStatePropertyAll(20),
    );
    final outlineActionStyle = actionStyle.merge(
      investmentOutlineButtonStyle(context),
    );
    final unheldFunds =
        portfolio?.securities
            .where(
              (security) =>
                  security.isFund &&
                  !projection!.positions.any(
                    (position) => position.securityId == security.id,
                  ),
            )
            .toList() ??
        const <StockSecurity>[];
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(
                title: account.name,
                subtitle: currencyUnitSubtitle(
                  l,
                  c.parentForAccount(account)?.name ?? l.investTitle,
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
                  // 尚未录入证券也是正常状态，保留行情入口，由目标页展示明确空态。
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
                        detail!.amounts == null
                            ? l.investNoQuotes
                            : money(detail.amounts!.net),
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
                              '${l.investCashShare} ${_investmentShareText(l, detail.cashShare)}',
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
                          value: valuation!.marketValue == null
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
                      if (detail.pendingSubscriptionValue > 0) ...[
                        const SizedBox(height: 10),
                        DetailInfoRow(
                          inline: true,
                          label: l.fundPendingValue,
                          value: money(detail.pendingSubscriptionValue),
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
                _InvestmentActions(
                  key: const Key('investment-primary-actions'),
                  children: [
                    FilledButton.icon(
                      key: const Key('investment-stock-action'),
                      style: actionStyle,
                      onPressed: () => _newTrade(context, account),
                      icon: const Icon(Icons.add),
                      label: Text(l.investNewTrade),
                    ),
                    FundOperationsButton(
                      key: const Key('fund-operations'),
                      accountId: accountId,
                      style: actionStyle,
                    ),
                    OutlinedButton.icon(
                      key: const Key('investment-option-action'),
                      style: outlineActionStyle,
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) =>
                              OptionEditorPage(accountId: accountId),
                        ),
                      ),
                      icon: const Icon(Icons.layers_outlined),
                      label: Text(l.optionTitle),
                    ),
                    OutlinedButton.icon(
                      key: const Key('investment-cash-action'),
                      style: outlineActionStyle,
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
                      icon: const Icon(Icons.account_balance_wallet_outlined),
                      label: Text(l.investCashCheck),
                    ),
                  ],
                ),
                if (unheldFunds.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final fund in unheldFunds)
                        OutlinedButton(
                          key: ValueKey('fund-trade-${fund.id}'),
                          style: investmentOutlineButtonStyle(context),
                          onPressed: () => _edit(context, securityId: fund.id),
                          child: Text(
                            '${l.investFundNewTrade} · ${fund.symbol}',
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                InvestmentHint(
                  portfolio.marketPriceIds.isEmpty
                      ? l.investManualHint
                      : l.marketEffectiveHint,
                ),
                if (portfolio.securities.any((s) => s.option != null))
                  InvestmentHint(l.optionMarginHint),
                if (portfolio.fundSubscriptions.any(
                  (subscription) =>
                      subscription.confirmation == null ||
                      hongKongFundDayStart(
                        subscription.confirmation!.earningStartDate,
                      ).isAfter(DateTime.now()),
                )) ...[
                  const SizedBox(height: 16),
                  SectionTitle(title: l.fundPendingTitle),
                  const SizedBox(height: 8),
                  for (final subscription in [
                    ...portfolio.fundSubscriptions,
                  ]..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)))
                    if (subscription.confirmation == null ||
                        hongKongFundDayStart(
                          subscription.confirmation!.earningStartDate,
                        ).isAfter(DateTime.now())) ...[
                      FundSubscriptionCard(
                        account: account,
                        security: portfolio.securities.firstWhere(
                          (security) => security.id == subscription.securityId,
                        ),
                        subscription: subscription,
                      ),
                      const SizedBox(height: 8),
                    ],
                ],
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
                    onTrade: () =>
                        _edit(context, securityId: position.securityId),
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
                          '${event.kind.label(l, fund: portfolio.securities.firstWhere((s) => s.id == event.securityId).isFund)} · ${portfolio.securities.firstWhere((s) => s.id == event.securityId).symbol}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _eventDetails(
                            event,
                            l,
                            account.currencyCode,
                            fund: portfolio.securities
                                .firstWhere((s) => s.id == event.securityId)
                                .isFund,
                          ),
                        ),
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
              AccountFundingSection(account: account),
              const SizedBox(height: 12),
              InvestmentHint(l.investNoOptions),
              const SizedBox(height: 12),
              AccountInformationSection(account: account),
            ],
          ),
        ),
      ),
    );
  }
}

/// 证券页四个主操作保持按行排列的等宽双列，不受按钮文案或额外基金入口挤占。
class _InvestmentActions extends StatelessWidget {
  const _InvestmentActions({super.key, required this.children})
    : assert(children.length == 4);

  final List<Widget> children;

  /// 每排随最长按钮自然增高；仅在图标和四个当前字号汉字也放不下时退为单列。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fontSize = Theme.of(context).textTheme.labelLarge?.fontSize ?? 12;
      final minimumWidth =
          MediaQuery.textScalerOf(context).scale(fontSize) * 4 + 52;
      final columns = constraints.maxWidth >= minimumWidth * 2 + 10 ? 2 : 1;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index += columns) ...[
            if (index > 0) const SizedBox(height: 10),
            if (columns == 1)
              children[index]
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: children[index]),
                    const SizedBox(width: 10),
                    Expanded(child: children[index + 1]),
                  ],
                ),
              ),
          ],
        ],
      );
    },
  );
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
    required this.onTrade,
    required this.onTransfer,
  });
  final String accountId;
  final InvestmentPortfolio portfolio;
  final StockPosition position;
  final InvestmentAccountValuation accountValuation;
  final VoidCallback onTransfer, onTrade;

  /// 展示方向、数量、每股成本、总成本、参考价及占总资产比例；未知成本不显示成零。
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
    final referenceDay = security.isFund
        ? c.fundReferenceHistoryFor(accountId, security.id).lastOrNull
        : null;
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
    final ordinaryStock = !security.isFund && security.option == null;
    final averageCost = ordinaryStock
        ? stockAverageUnitCost(position.cost, position.quantity)
        : null;
    // 从原始聚合定位期初事实；行情估值副本不能作为编辑并发校验的基线。
    final originalPortfolio = c.investmentFor(accountId);
    final opening = originalPortfolio?.openingHoldings
        .where(
          (h) =>
              h.securityId == position.securityId && h.short == position.short,
        )
        .firstOrNull;
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
            security.market.label(l, fund: security.isFund),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: 20),
          DetailInfoRow(
            inline: true,
            label: security.option == null
                ? security.isFund
                      ? l.investFundQuantity
                      : l.investQuantity
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
          if (ordinaryStock)
            DetailInfoRow(
              inline: true,
              label: l.investAverageUnitCost,
              value: averageCost == null
                  ? l.investUnknown
                  : formatUserSecurityPrice(
                      averageCost.toString(),
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
          if (referenceDay != null) ...[
            DetailInfoRow(
              inline: true,
              label: l.fundReferenceDailyProfit,
              value: referenceDay.dailyProfit == null
                  ? l.investUnknown
                  : formatSignedUserMoney(
                      referenceDay.dailyProfit!.toDouble(),
                      portfolio.currencyCode,
                    ),
            ),
            DetailInfoRow(
              inline: true,
              label: l.fundReferenceCumulativeProfit,
              value: referenceDay.cumulativeProfit == null
                  ? l.investUnknown
                  : formatSignedUserMoney(
                      referenceDay.cumulativeProfit!.toDouble(),
                      portfolio.currencyCode,
                    ),
            ),
          ],
          if (quoteReference != null) ...[
            const SizedBox(height: 12),
            // 来源是价格依据，集中放在指标之后；短日期仍保留年份、时刻与时区。
            InvestmentQuoteDetails(
              source: quote!.source,
              dateOnly: quote.dateOnly,
              quoteTime: formatQuoteTime(
                context,
                quoteReference.time,
                compact: true,
                dateOnly: quote.dateOnly,
              ),
            ),
          ],
          const Divider(height: 20),
          Wrap(
            spacing: 4,
            children: [
              if (security.isFund && security.market == StockMarket.hk)
                FundOperationsButton(
                  accountId: accountId,
                  securityId: security.id,
                  compact: true,
                ),
              if (security.isFund)
                TextButton(
                  onPressed: onTrade,
                  child: Text(l.investFundNewTrade),
                ),
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
              if (ordinaryStock && opening != null && originalPortfolio != null)
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => StockOpeningCostPage(
                        portfolio: originalPortfolio,
                        holding: opening,
                      ),
                    ),
                  ),
                  child: Text(l.investCorrectOpeningCost),
                )
              else if (position.cost == null)
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
              TextButton.icon(
                onPressed: () => showInvestmentHoldingRemovalConfirmation(
                  context: context,
                  accountId: accountId,
                  securityId: security.id,
                ),
                style: TextButton.styleFrom(
                  foregroundColor: veriSemantic(context, veriExpense),
                ),
                icon: const Icon(Icons.delete_outline),
                label: Text(l.investClearHolding),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 股票或已有基金的期初、成交和转移页面；未点保存不会产生任何用户数据。
class StockEditorPage extends StatefulWidget {
  /// [openingPortfolio] 非空时只返回一项期初草稿；[event] 编辑成交，
  /// [transfer] 表示跨账户原子批次，三种模式不能相互混用。
  const StockEditorPage({
    super.key,
    required this.accountId,
    this.event,
    this.securityId,
    this.openingPortfolio,
    this.openingHolding,
    this.openingSecurityType = InvestmentSecurityType.stock,
    this.transfer = false,
    this.initialShort = false,
    this.editorSession,
  }) : assert(openingHolding == null || openingPortfolio != null),
       assert(openingPortfolio == null || (event == null && !transfer));
  final String accountId;
  final StockEvent? event;
  final String? securityId;
  final bool transfer;
  final bool initialShort;

  /// 父级启用页的内存快照与待编辑条目；返回前不创建账户组合或资金事件。
  final InvestmentPortfolio? openingPortfolio;
  final InvestmentOpeningHolding? openingHolding;
  final InvestmentSecurityType openingSecurityType;

  /// 非空时复用本表单内容，外层负责新增页签与全部草稿的退出。
  final EntryEditorSession? editorSession;

  /// 为每份编辑草稿创建独立状态，字段不绑定 Controller 集合。
  @override
  State<StockEditorPage> createState() => _StockEditorPageState();
}

class _StockEditorPageState extends State<StockEditorPage> {
  final _exitController = EditorExitController();
  String? _initialEditorSnapshot;
  bool _submitted = false;
  final _fields = <String, TextEditingController>{};
  StockMarket _market = StockMarket.us;
  InvestmentSecurityType _securityType = InvestmentSecurityType.stock;
  StockEventKind _kind = StockEventKind.buy;
  late DateTime _date;
  late String _id, _bookId;
  int _sequence = 0;
  bool _initialized = false, _saving = false, _short = false;
  InvestmentOpeningHolding? _openingResult;
  String? _initialOpeningUnitCost;
  String? _error, _target, _initialReference;
  List<StockSecurity> _onlineSecurities = const [];
  String? _onlineQuery,
      _searchMessage,
      _searchInputSnapshot,
      _autofilledReference;
  String? _autofilledReferenceIdentity;
  int _searchGeneration = 0, _suggestionOpenRequest = 0;
  bool _searching = false, _lookupVisible = true;

  bool get _opening => widget.openingPortfolio != null;

  /// 搜索只绑定代码输入、所选市场和品种；数量、真实成交价等编辑不改变搜索身份。
  String get _securityLookupContext =>
      '${_fields['symbol']?.text ?? ''}|${_market.name}|${_securityType.name}';

  /// 后备价归属使用真实证券身份；代码首尾空白或字母大小写变化不代表另一证券。
  String get _securityLookupIdentity =>
      '${_market.name}:${_securityType.name}:${_fields['symbol']?.text.trim().toUpperCase() ?? ''}';

  /// 身份改变时移除上一证券自动带入且未被用户改写的后备价。
  /// 必须先清除自动标记，再清文本；clear 会同步触发所有原有草稿监听，避免递归清除。
  /// 用户主动改填的价格与其余真实成交字段保持原样，等待用户自行核对新证券。
  void _discardAutofilledReferenceIfIdentityChanged() {
    if (_autofilledReferenceIdentity == null ||
        _autofilledReferenceIdentity == _securityLookupIdentity) {
      return;
    }
    final previous = _autofilledReference;
    _autofilledReference = null;
    _autofilledReferenceIdentity = null;
    if (previous != null && _fields['reference']!.text == previous) {
      _fields['reference']!.clear();
    }
  }

  /// 输入或市场改变后废弃旧远端结果及未完成请求；不取消用户已填的任何草稿字段。
  void _clearSecuritySearch() {
    _searchGeneration++;
    _onlineSecurities = const [];
    _onlineQuery = null;
    _searchMessage = null;
    _searching = false;
    _searchInputSnapshot = _securityLookupContext;
  }

  /// 以所有输入和业务选择比较草稿，不将加载默认值或保存错误误判为修改。
  String get _editorSnapshot => editorDraftSnapshot(
    fields: _fields,
    values: [
      _market.name,
      _securityType.name,
      _kind.name,
      _date.toIso8601String(),
      _short,
      _target,
    ],
  );

  /// 已成功提交的同一记录保持只读，防止切换页签后再次新增。
  bool get _editorDirty =>
      !_submitted &&
      _initialEditorSnapshot != null &&
      _initialEditorSnapshot != _editorSnapshot;

  /// 文本输入也刷新退出保护；切换页签只隐藏表单，不丢弃其控制器。
  void _editorChanged() {
    _discardAutofilledReferenceIfIdentityChanged();
    if (_searchInputSnapshot != _securityLookupContext) {
      _clearSecuritySearch();
    }
    if (mounted) setState(() {});
  }

  /// 延迟初始化到可读取 Scope 时；保留已有事件 ID/序号，重试不会重复成交。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = Visibility.of(context);
    if (_initialized) {
      if ((_lookupVisible && !visible) ||
          VeriFinScope.of(context).activeBook.id != _bookId) {
        _clearSecuritySearch();
      }
      _lookupVisible = visible;
      return;
    }
    _lookupVisible = visible;
    _initialized = true;
    final c = VeriFinScope.of(context);
    _bookId = c.activeBook.id;
    final account = c.accounts
        .where((a) => a.id == widget.accountId)
        .firstOrNull;
    if (account == null) {
      return;
    }
    final p = widget.openingPortfolio ?? c.investmentFor(account.id);
    final e = widget.event, opening = widget.openingHolding;
    _bookId = account.bookId;
    _market = account.currencyCode == 'HKD'
        ? StockMarket.hk
        : account.currencyCode == 'CNY'
        ? StockMarket.cn
        : StockMarket.us;
    final security =
        opening?.security ??
        p?.securities
            .where((s) => s.id == (e?.securityId ?? widget.securityId))
            .firstOrNull;
    _market = security?.market ?? _market;
    _securityType =
        security?.type ??
        (_opening ? widget.openingSecurityType : InvestmentSecurityType.stock);
    _kind = e?.kind ?? StockEventKind.buy;
    _short = _securityType == InvestmentSecurityType.fund
        ? false
        : opening?.holding.short ?? widget.initialShort;
    _date = e?.occurredAt ?? DateTime.now();
    _id = e?.id ?? 'stock-${DateTime.now().microsecondsSinceEpoch}';
    _sequence =
        e?.sequence ?? c.nextInvestmentEventSequenceFor(account.id) ?? 0;
    _initialReference =
        opening?.referencePrice ?? p?.manualPrices[security?.id];
    if (opening != null) {
      final originalCost = opening.holding.cost == null
          ? null
          : InvestmentDecimal.parse(opening.holding.cost!);
      final average = stockAverageUnitCost(
        originalCost,
        InvestmentDecimal.parse(opening.holding.quantity),
      );
      // 不可表示的均价留空；未改数量及成本时始终保留原始总额。
      _initialOpeningUnitCost =
          average == null ||
              (average.units == BigInt.zero &&
                  originalCost!.units != BigInt.zero)
          ? ''
          : average.toString();
    }
    for (final pair in {
      'symbol': security?.symbol ?? '',
      'name': security?.name ?? '',
      'quantity': opening?.holding.quantity ?? e?.quantity ?? '',
      'price': e?.price ?? '',
      'fee': e?.fee ?? '0',
      'reference': _initialReference ?? '',
      'cost': _initialOpeningUnitCost ?? '',
      'note': e?.note ?? '',
    }.entries) {
      _fields[pair.key] = TextEditingController(text: pair.value);
    }
    _initialEditorSnapshot = _editorSnapshot;
    _searchInputSnapshot = _securityLookupContext;
    for (final field in _fields.values) {
      field.addListener(_editorChanged);
    }
  }

  /// 释放输入资源，取消编辑不触发任何保存。
  @override
  void dispose() {
    _searchGeneration++;
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

  /// 构建代码字段及本地/用户主动查询的远端候选；其他账户只复用身份，不复制价格。
  /// [context] 提供本地化和 Scope；已有事件、持仓上下文或转仓继续锁定证券身份。
  Widget _symbolField(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final account = c.accounts
        .where((value) => value.id == widget.accountId)
        .firstOrNull;
    final readOnly =
        widget.transfer || widget.event != null || widget.securityId != null;
    final suggestions = account == null
        ? const <InvestmentSecuritySuggestion>[]
        : collectInvestmentSecuritySuggestions(
            portfolios: [
              if (widget.openingPortfolio != null) widget.openingPortfolio!,
              ...c.accounts
                  .where((value) => value.currencyCode == account.currencyCode)
                  .map((value) => c.investmentFor(value.id))
                  .whereType<InvestmentPortfolio>(),
            ],
            bookId: _bookId,
            accountId: widget.accountId,
            currencyCode: account.currencyCode,
            market: _market,
            type: _securityType,
            remoteSecurities: _onlineSecurities,
            remoteQuery: _onlineQuery,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InvestmentSecurityAutocomplete(
          controller: _fields['symbol']!,
          fieldKey: const ValueKey('stock-symbol'),
          label: l.investSymbol,
          suggestions: suggestions,
          openRequest: _suggestionOpenRequest,
          readOnly: readOnly || _saving,
          onSelected: (suggestion) {
            final security = suggestion.security;
            setState(() {
              _market = security.market;
              _securityType = security.type;
              _fields['name']!.text = security.name;
              if (suggestion.referencePrice != null) {
                _autofilledReference = suggestion.referencePrice;
                _autofilledReferenceIdentity = _securityLookupIdentity;
                _fields['reference']!.text = suggestion.referencePrice!;
              } else {
                // 改选其他证券时移除上一项自动带入的价格，保留用户自己改填的参考价。
                if (_autofilledReference != null &&
                    _fields['reference']!.text == _autofilledReference) {
                  _fields['reference']!.clear();
                }
                _autofilledReference = null;
                _autofilledReferenceIdentity = null;
              }
              _clearSecuritySearch();
            });
          },
        ),
        if (!readOnly && _securityType == InvestmentSecurityType.stock) ...[
          OutlinedButton.icon(
            key: const Key('stock-search-online'),
            style: investmentOutlineButtonStyle(context),
            onPressed:
                _saving || _searching || _fields['symbol']!.text.trim().isEmpty
                ? null
                : _searchSecurity,
            icon: const Icon(Icons.search),
            label: Text(_searching ? l.commonProcessing : l.investSearchOnline),
          ),
          const SizedBox(height: 6),
          InvestmentHint(l.investSearchOnlineConsent),
          if (_searchMessage != null) ...[
            const SizedBox(height: 8),
            InvestmentHint(_searchMessage!),
          ],
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// 仅在用户点击联网按钮时查询一次公开股票资料；每次按键不会触发请求。
  /// 请求序号和原输入上下文共同拒绝旧结果，切页签、离页或换账本不抢焦点。
  /// Controller 负责隐私友好日志，界面失败只反馈并保留全部原草稿。
  Future<void> _searchSecurity() async {
    if (_searching || _saving) return;
    final c = VeriFinScope.of(context);
    final account = c.accounts
        .where((value) => value.id == widget.accountId)
        .firstOrNull;
    final query = _fields['symbol']!.text.trim();
    if (account == null || query.isEmpty || c.activeBook.id != _bookId) return;
    final generation = ++_searchGeneration;
    final inputSnapshot = _securityLookupContext;
    setState(() {
      _searching = true;
      _onlineSecurities = const [];
      _onlineQuery = null;
      _searchMessage = null;
    });
    try {
      final securities = await c.searchInvestmentSecurities(
        query,
        market: _market,
        currencyCode: account.currencyCode,
      );
      if (!mounted ||
          generation != _searchGeneration ||
          inputSnapshot != _securityLookupContext ||
          c.activeBook.id != _bookId) {
        return;
      }
      if (_saving ||
          _submitted ||
          !Visibility.of(context) ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          !c.accounts.any((value) => value.id == widget.accountId)) {
        setState(_clearSecuritySearch);
        return;
      }
      setState(() {
        _searching = false;
        _onlineSecurities = securities;
        _onlineQuery = query;
        if (securities.isNotEmpty) _suggestionOpenRequest++;
        _searchMessage = securities.isEmpty
            ? AppLocalizations.of(context).investSearchNoResults
            : null;
      });
    } catch (_) {
      // Controller 已记录不含搜索词的中文错误类型；这里保留草稿并给出可见反馈。
      if (!mounted ||
          generation != _searchGeneration ||
          inputSnapshot != _securityLookupContext ||
          c.activeBook.id != _bookId) {
        return;
      }
      if (_saving ||
          _submitted ||
          !Visibility.of(context) ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          !c.accounts.any((value) => value.id == widget.accountId)) {
        setState(_clearSecuritySearch);
        return;
      }
      setState(() {
        _searching = false;
        _searchMessage = AppLocalizations.of(context).investSearchOnlineFailed;
      });
    }
  }

  /// 提交前核对仍在同一账本；校验失败保留所有输入，保存中禁止重复点击。
  /// 已有基金的后备价数值未变时不重设价格依据，使买卖或编辑交易后仍可采用净值并重算历史。
  /// 用户确实改变后备价时才传入新值，由 Controller 切回手填；股票沿用既有保存语义。
  Future<bool> _save() async {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (_saving || _submitted || c.activeBook.id != _bookId) return false;
    _clearSecuritySearch();
    final account = c.accounts
        .where((a) => a.id == widget.accountId)
        .firstOrNull;
    if (account == null ||
        account.bookId != _bookId ||
        (!_opening && c.investmentFor(account.id) == null) ||
        (_opening &&
            (!account.type.supportsSecurities ||
                widget.openingPortfolio!.accountId != account.id ||
                widget.openingPortfolio!.bookId != _bookId ||
                widget.openingPortfolio!.currencyCode !=
                    account.currencyCode))) {
      setState(() => _error = l.investSaveError);
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var ok = false;
    try {
      final symbol = _fields['symbol']!.text.trim().toUpperCase();
      final security = StockSecurity(
        symbol: symbol,
        name: _fields['name']!.text.trim(),
        market: _market,
        currencyCode: account.currencyCode,
        type: _securityType,
      );
      final quantity = _fields['quantity']!.text.trim();
      final reference = _fields['reference']!.text.trim();
      if (_opening) {
        if (symbol.isEmpty ||
            security.name.isEmpty ||
            reference.isEmpty ||
            widget.event != null ||
            widget.transfer ||
            security.option != null) {
          throw const FormatException('期初资料不完整');
        }
        final units = InvestmentDecimal.parse(quantity);
        final referencePrice = InvestmentDecimal.parse(reference);
        if (units.units <= BigInt.zero || referencePrice.units < BigInt.zero) {
          throw const FormatException('期初数量或参考价不合法');
        }
        referencePrice.toDouble();
        String? openingTotalCost;
        final unitCostText = _fields['cost']!.text.trim();
        final original = widget.openingHolding;
        final unchangedUnits =
            original != null &&
            units.compareTo(
                  InvestmentDecimal.parse(original.holding.quantity),
                ) ==
                0;
        final unchangedCost =
            unitCostText == (_initialOpeningUnitCost ?? '') ||
            (unitCostText.isNotEmpty &&
                (_initialOpeningUnitCost?.isNotEmpty ?? false) &&
                InvestmentDecimal.parse(unitCostText).compareTo(
                      InvestmentDecimal.parse(_initialOpeningUnitCost!),
                    ) ==
                    0);
        if (unchangedUnits && unchangedCost) {
          // 八位均价仅供预填；仅改参考价、名称或数字格式不能反乘覆盖总成本。
          openingTotalCost = original.holding.cost;
        } else if (unitCostText.isNotEmpty) {
          final unitCost = InvestmentDecimal.parse(unitCostText);
          if (unitCost.units < BigInt.zero) {
            throw const FormatException('期初单位成本不合法');
          }
          // 表单录入每股/每份成本，持久化仍为总成本；量价相乘后只在现金精度舍入。
          openingTotalCost = units
              .moneyProduct(
                unitCost,
                CurrencyCatalog.require(account.currencyCode).minorUnit,
              )
              .toString();
        }
        if (openingTotalCost != null) {
          InvestmentDecimal.parse(openingTotalCost).toDouble();
        }
        final holding = StockHolding(
          securityId: security.id,
          short: _short,
          quantity: units.toString(),
          cost: openingTotalCost,
        );
        final p = widget.openingPortfolio!;
        final candidate = p.copyWith(
          securities: [
            ...p.securities.where((s) => s.id != security.id),
            security,
          ],
          openingHoldings: [
            ...p.openingHoldings.where(
              (h) =>
                  original == null ||
                  h.securityId != original.holding.securityId ||
                  h.short != original.holding.short,
            ),
            holding,
          ],
          manualPrices: {
            ...p.manualPrices,
            security.id: referencePrice.toString(),
          },
        );
        final projection = projectStocks(candidate);
        valueStocks(candidate, projection).marketValue?.toDouble();
        _openingResult = InvestmentOpeningHolding(
          security: security,
          holding: holding,
          referencePrice: referencePrice.toString(),
        );
        ok = true;
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
        // 其他隐藏草稿可能已保存并占用序号；新事件每次提交按最新组合重新读取，
        // 已有事件编辑保持原顺序，失败重试也不能一直沿用冲突的旧序号。
        final nextSequence =
            widget.event?.sequence ??
            c.nextInvestmentEventSequenceFor(account.id);
        if (nextSequence == null) throw const FormatException('证券账户已失效');
        _sequence = nextSequence;
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
        final keepFundPriceSource =
            security.isFund &&
            _initialReference != null &&
            InvestmentDecimal.parse(
                  reference,
                ).compareTo(InvestmentDecimal.parse(_initialReference!)) ==
                0;
        ok = await c.saveStockEvent(
          accountId: account.id,
          security: security,
          event: event,
          referencePrice: keepFundPriceSource ? null : reference,
        );
      }
    } on FormatException {
      // 输入错误由内联本地化提示反馈，草稿继续保留；持久化失败由 Controller 记录。
    }
    if (!mounted) return false;
    if (ok) {
      setState(() {
        _saving = false;
        _submitted = true;
        _initialEditorSnapshot = _editorSnapshot;
      });
    } else {
      setState(() {
        _saving = false;
        _error = l.investSaveError;
      });
    }
    return ok;
  }

  /// 原独立页面保存成功后通过同一个退出控制器返回；嵌入模式由宿主调用 _save。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) {
      _exitController.exit(result: () => _openingResult);
    }
  }

  /// 展示可取消的完整表单；市场/动作复用既有锚点选择器，日期时间沿用公共入口。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (c.activeBook.id != _bookId ||
        !c.accounts.any(
          (a) =>
              a.id == widget.accountId &&
              (!_opening ||
                  (a.type.supportsSecurities &&
                      widget.openingPortfolio!.accountId == a.id &&
                      widget.openingPortfolio!.bookId == _bookId &&
                      widget.openingPortfolio!.currencyCode == a.currencyCode)),
        )) {
      return EntryEditorSurface(
        session: widget.editorSession,
        isDirty: _editorDirty,
        canSave: false,
        onSave: _save,
        exitController: _exitController,
        isSaving: _saving,
        body: SafeArea(
          child: VeriPage(
            child: Column(
              children: [
                if (widget.editorSession == null)
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
    return EntryEditorSurface(
      session: widget.editorSession,
      isDirty: _editorDirty,
      canSave: !_saving && !_submitted,
      onSave: _save,
      exitController: _exitController,
      popResult: () => _openingResult,
      isSaving: _saving,
      body: SafeArea(
        child: VeriPage(
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                if (widget.editorSession == null)
                  VeriHeader(
                    title: _opening
                        ? l.investOpeningHoldingTitle
                        : widget.transfer
                        ? l.investTransfer
                        : _securityType == InvestmentSecurityType.fund
                        ? l.investFundNewTrade
                        : l.investNewTrade,
                    showBack: true,
                  ),
                const SizedBox(height: 12),
                InvestmentSection(
                  title: l.investSecurityDetails,
                  children: [
                    if (!_opening && !widget.transfer)
                      VeriAnchoredChoice<StockEventKind>(
                        values: [
                          StockEventKind.buy,
                          StockEventKind.sell,
                          if (_securityType != InvestmentSecurityType.fund) ...[
                            StockEventKind.shortSell,
                            StockEventKind.cover,
                          ],
                          StockEventKind.dividend,
                          StockEventKind.fee,
                          if (_securityType != InvestmentSecurityType.fund)
                            StockEventKind.split,
                        ],
                        selected: _kind,
                        idOf: (v) => v.name,
                        labelOf: (v) => v.label(
                          l,
                          fund: _securityType == InvestmentSecurityType.fund,
                        ),
                        onSelected: (v) => setState(() => _kind = v),
                        semanticLabel: l.investEventType,
                        builder: (context, open, active) => SettingsRow(
                          icon: Icons.swap_horiz,
                          title: l.investEventType,
                          trailing: _kind.label(
                            l,
                            fund: _securityType == InvestmentSecurityType.fund,
                          ),
                          trailingMaxLines: null,
                          trailingIcon: Icons.unfold_more,
                          onTap: open,
                        ),
                      ),
                    VeriAnchoredChoice<StockMarket>(
                      values: StockMarket.values,
                      selected: _market,
                      idOf: (v) => v.name,
                      labelOf: (v) => v.label(
                        l,
                        fund: _securityType == InvestmentSecurityType.fund,
                      ),
                      onSelected: (v) => setState(() {
                        _market = v;
                        _discardAutofilledReferenceIfIdentityChanged();
                        _clearSecuritySearch();
                      }),
                      semanticLabel: l.investMarket,
                      builder: (context, open, active) => SettingsRow(
                        icon: Icons.public,
                        title: l.investMarket,
                        trailing: _market.label(
                          l,
                          fund: _securityType == InvestmentSecurityType.fund,
                        ),
                        trailingMaxLines: null,
                        trailingIcon: Icons.unfold_more,
                        onTap:
                            widget.transfer ||
                                widget.event != null ||
                                widget.securityId != null
                            ? null
                            : open,
                      ),
                    ),
                    _symbolField(context),
                    _field('name', l.investName, readOnly: widget.transfer),
                  ],
                ),
                const SizedBox(height: 12),
                InvestmentSection(
                  title: _opening
                      ? l.investOpeningHoldingTitle
                      : l.investTradeDetails,
                  children: [
                    if (_opening ||
                        widget.transfer ||
                        !{
                          StockEventKind.dividend,
                          StockEventKind.fee,
                        }.contains(_kind))
                      _field(
                        'quantity',
                        _opening
                            ? l.investOpeningHoldingQuantity
                            : _kind == StockEventKind.split
                            ? l.investSplitNew
                            : _securityType == InvestmentSecurityType.fund
                            ? l.investFundQuantity
                            : l.investQuantity,
                        numeric: true,
                      ),
                    if (_opening) ...[
                      _field('cost', l.investOpeningUnitCost, numeric: true),
                      Text(
                        l.investOpeningUnitCostHint,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_securityType != InvestmentSecurityType.fund)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _short,
                          onChanged: (v) => setState(() => _short = v),
                          title: Text(l.investShortPosition),
                        ),
                    ],
                    if (!_opening && !widget.transfer) ...[
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
                      if (_securityType != InvestmentSecurityType.fund)
                        SwitchListTile(
                          value: _short,
                          onChanged: (v) => setState(() => _short = v),
                          title: Text(l.investShortPosition),
                        ),
                    ],
                    if (!_opening)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l.investDate),
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
                    if (!_opening) _field('note', l.investNote),
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
                if (widget.editorSession == null)
                  FilledButton(
                    onPressed: _saving ? null : _saveAndExit,
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
                              _exitController.exit();
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
