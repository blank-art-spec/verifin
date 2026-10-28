/// 基金金额申购、已有持仓与逐笔确认页面；草稿取消时不产生任何资金或持仓事实。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/investments/fund_amount_math.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_widgets.dart';
import '../app/investments/quote_format.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 两个入口分别表达新申购与已经持有的资产；已有持仓不会伪装成一次新的现金买入。
enum FundEntryMode { purchase, holdingBaseline }

enum _FundFormAction { application, confirmation, cancellation }

/// 证券页与基金卡共用的操作菜单，不在多个页面复制不同的基金录入流程。
class FundOperationsButton extends StatelessWidget {
  /// [accountId] 为当前真实币种账户；[securityId] 可限定为卡片中的已有基金。
  /// [enabled] 由账户可选基金决定；[compact] 使持仓卡复用普通文字按钮密度。
  const FundOperationsButton({
    super.key,
    required this.accountId,
    this.securityId,
    this.enabled = true,
    this.compact = false,
  });

  final String accountId;
  final String? securityId;
  final bool enabled, compact;

  /// [mode] 只决定新页面的草稿类型；导航本身不确认申购、不扣款、不增加份额。
  void _open(BuildContext context, FundEntryMode mode) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FundEntryPage(
            accountId: accountId,
            mode: mode,
            securityId: securityId,
          ),
        ),
      ),
    );
  }

  /// 使用共享锚点操作菜单，两个动作取消后均无副作用，完整标题随大字号换行。
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return VeriAnchoredMenuAnchor(
      semanticLabel: l.fundOperations,
      entries: [
        VeriMenuItem(
          id: 'fund-buy-by-amount',
          title: l.fundBuyByAmount,
          icon: Icons.add_shopping_cart_outlined,
          onPressed: () => _open(context, FundEntryMode.purchase),
        ),
        VeriMenuItem(
          id: 'fund-record-holding',
          title: l.fundRecordHolding,
          icon: Icons.inventory_2_outlined,
          onPressed: () => _open(context, FundEntryMode.holdingBaseline),
        ),
      ],
      builder: (context, open, active) => compact
          ? TextButton(
              onPressed: enabled ? open : null,
              child: Text(l.fundOperations),
            )
          : OutlinedButton.icon(
              style: investmentOutlineButtonStyle(context),
              onPressed: enabled ? open : null,
              icon: const Icon(Icons.account_balance_outlined),
              label: Text(l.fundOperations),
            ),
    );
  }
}

/// 按当前真实时刻显示逐笔申购状态，预计日期从不被解释为已经确认。
/// [subscription] 是当前账户事实；[at] 可供稳定展示测试，省略时读取当前时刻。
String fundSubscriptionStatusLabel(
  FundSubscription subscription,
  AppLocalizations l, {
  DateTime? at,
}) {
  final now = at ?? DateTime.now();
  final paid =
      subscription.paidAt != null && !subscription.paidAt!.isAfter(now);
  if (subscription.refundedAt != null &&
      !subscription.refundedAt!.isAfter(now)) {
    return l.fundStatusRefunded;
  }
  if (subscription.cancelledAt != null &&
      !subscription.cancelledAt!.isAfter(now)) {
    return paid ? l.fundStatusRefundPending : l.fundStatusCancelled;
  }
  final confirmation = subscription.confirmation;
  if (confirmation != null) {
    return !paid ||
            hongKongFundDayStart(confirmation.earningStartDate).isAfter(now)
        ? l.fundStatusScheduled
        : l.fundStatusEffective;
  }
  return paid ? l.fundStatusPending : l.fundStatusUnpaid;
}

/// 一笔申购的统一摘要；点击只打开核对页面，不直接确认、取消或改变现金。
class FundSubscriptionCard extends StatelessWidget {
  /// [account]、[security] 与 [subscription] 必须由同一币种聚合提供，避免借用其他账户。
  const FundSubscriptionCard({
    super.key,
    required this.account,
    required this.security,
    required this.subscription,
  });

  final Account account;
  final StockSecurity security;
  final FundSubscription subscription;

  /// 以共享卡片列出实际金额和关键日期；状态与逐笔起算日分离，不显示虚构份额。
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final confirmation = subscription.confirmation;
    return VeriCard(
      key: ValueKey('fund-subscription-${subscription.id}'),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => FundEntryPage(
            accountId: account.id,
            mode: FundEntryMode.purchase,
            subscriptionId: subscription.id,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(security.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(fundSubscriptionStatusLabel(subscription, l)),
          DetailInfoRow(
            inline: true,
            label: l.fundCashAmount,
            value: formatUserMoney(
              InvestmentDecimal.parse(subscription.cashAmount).toDouble(),
              account.currencyCode,
            ),
          ),
          DetailInfoRow(
            inline: true,
            label: l.fundRequestedAt,
            value: formatQuoteTime(context, subscription.requestedAt),
          ),
          if (subscription.paidAt != null)
            DetailInfoRow(
              inline: true,
              label: l.fundPaidAt,
              value: formatQuoteTime(context, subscription.paidAt!),
            ),
          if (subscription.expectedConfirmationDate != null &&
              confirmation == null)
            DetailInfoRow(
              inline: true,
              label: l.fundExpectedConfirmationDate,
              value: formatQuoteTime(
                context,
                subscription.expectedConfirmationDate!,
                dateOnly: true,
              ),
            ),
          if (confirmation != null) ...[
            DetailInfoRow(
              inline: true,
              label: l.fundConfirmedAt,
              value: formatQuoteTime(context, confirmation.confirmedAt),
            ),
            DetailInfoRow(
              inline: true,
              label: l.fundEarningStartDate,
              value: formatQuoteTime(
                context,
                confirmation.earningStartDate,
                dateOnly: true,
              ),
            ),
            DetailInfoRow(
              inline: true,
              label: l.investFundQuantity,
              value: confirmation.quantity,
            ),
          ],
        ],
      ),
    );
  }
}

/// 基金两个金额入口及已有申购核对页；所有写入只经 Controller 公共原子命令。
class FundEntryPage extends StatefulWidget {
  /// [mode] 决定新草稿类型；[securityId] 限定已有基金；[subscriptionId] 打开一笔已有申购。
  /// [baselineEvent] 只用于编辑持仓基准，不能把普通买卖事件改作零现金基准。
  const FundEntryPage({
    super.key,
    required this.accountId,
    required this.mode,
    this.securityId,
    this.subscriptionId,
    this.baselineEvent,
  });

  final String accountId;
  final FundEntryMode mode;
  final String? securityId, subscriptionId;
  final StockEvent? baselineEvent;

  /// 页面独立持有草稿和核对勾选状态，离开页面时不保存。
  @override
  State<FundEntryPage> createState() => _FundEntryPageState();
}

class _FundEntryPageState extends State<FundEntryPage> {
  final _fields = <String, TextEditingController>{};
  bool _initialized = false,
      _saving = false,
      _paid = false,
      _expected = false,
      _reviewed = false,
      _refundReceived = false;
  String? _securityId, _error;
  late String _bookId, _currency, _id;
  late DateTime _requestedAt,
      _paidAt,
      _confirmedAt,
      _cancelledAt,
      _refundedAt,
      _navDate,
      _earningStartDate,
      _expectedDate,
      _baselineDate;
  _FundFormAction _action = _FundFormAction.application;

  /// 仅在首次读取 Scope 时复制草稿；后续净值更新不能覆盖用户正在填写的金额。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final c = VeriFinScope.of(context);
    _bookId = c.activeBook.id;
    final account = c.accounts
        .where((value) => value.id == widget.accountId)
        .firstOrNull;
    _currency = account?.currencyCode ?? 'USD';
    final portfolio = c.investmentFor(widget.accountId);
    final subscription = portfolio?.fundSubscriptions
        .where((value) => value.id == widget.subscriptionId)
        .firstOrNull;
    final baseline = widget.baselineEvent;
    final acquisition = portfolio?.events
        .where(
          (event) =>
              event.kind == StockEventKind.fundAcquire &&
              event.fundSubscriptionId == widget.subscriptionId,
        )
        .firstOrNull;
    final now = DateTime.now();
    final today = hongKongFundDate(now);
    _id =
        subscription?.id ??
        baseline?.id ??
        'fund-${now.microsecondsSinceEpoch}';
    _securityId =
        subscription?.securityId ?? baseline?.securityId ?? widget.securityId;
    _requestedAt = subscription?.requestedAt ?? now;
    _paidAt = subscription?.paidAt ?? now;
    _confirmedAt = subscription?.confirmation?.confirmedAt ?? now;
    _navDate =
        subscription?.confirmation?.navDate ?? baseline?.fundNavDate ?? today;
    _earningStartDate = subscription?.confirmation?.earningStartDate ?? today;
    _expectedDate = subscription?.expectedConfirmationDate ?? today;
    // 核对的是此刻的总持仓；不能放回日初再叠加当天已有买入而造成重复份额。
    _baselineDate = baseline?.occurredAt ?? now;
    _cancelledAt = subscription?.cancelledAt ?? now;
    _refundedAt = subscription?.refundedAt ?? now;
    _paid = subscription?.paidAt != null;
    _expected = subscription?.expectedConfirmationDate != null;
    _refundReceived = subscription?.refundedAt != null;
    if (subscription?.confirmation != null) {
      _action = _FundFormAction.confirmation;
    } else if (subscription?.cancelledAt != null) {
      _action = _FundFormAction.cancellation;
    }
    for (final pair in {
      'cashAmount': subscription?.cashAmount ?? '',
      'fee': subscription?.fee ?? '0',
      'cost': baseline?.carriedCost ?? '',
      'unrealized': baseline?.reportedUnrealized ?? '0',
      'nav': subscription?.confirmation?.nav ?? baseline?.price ?? '',
      'confirmedQuantity':
          (acquisition?.quantityInferred == false
              ? subscription?.confirmation?.quantity
              : null) ??
          (baseline?.quantityInferred == false ? baseline?.quantity : null) ??
          '',
      'refundAmount': subscription?.refundAmount ?? '',
      'note': subscription?.note ?? baseline?.note ?? '',
    }.entries) {
      _fields[pair.key] = TextEditingController(text: pair.value);
    }
  }

  /// 释放页面拥有的输入控制器，不触发保存或背景确认。
  @override
  void dispose() {
    for (final value in _fields.values) {
      value.dispose();
    }
    super.dispose();
  }

  /// [portfolio] 限定当前账户原有香港同币种基金；美元账户额外列出唯一已核对的 CMS B 类。
  /// 这套录入流程使用香港日期，其他市场基金继续沿用原有手工交易入口。
  List<StockSecurity> _securities(
    InvestmentPortfolio portfolio,
    AppLocalizations l,
  ) {
    final result = portfolio.securities
        .where(
          (security) =>
              security.isFund &&
              security.market == StockMarket.hk &&
              security.currencyCode == _currency,
        )
        .toList();
    if (_currency == 'USD' &&
        !result.any((security) => security.id == 'hk:fund:HK0001039582')) {
      result.add(
        StockSecurity(
          symbol: 'HK0001039582',
          name: l.fundCmsUsdName,
          market: StockMarket.hk,
          currencyCode: 'USD',
          type: InvestmentSecurityType.fund,
        ),
      );
    }
    return result;
  }

  /// [key] 定位精确文本草稿；只有输入变更才撤销核对勾选，不修改权威记录。
  void _changed(String key, String value) => setState(() {
    _reviewed = false;
    _error = null;
  });

  /// [securities] 是随账户变化的可选香港基金，因此使用共享动态单选弹窗；取消不预选基金。
  Future<void> _chooseSecurity(List<StockSecurity> securities) async {
    final selected = await showOptionSheet<String?>(
      context: context,
      title: AppLocalizations.of(context).fundChoose,
      values: securities.map((value) => value.id).toList(),
      selected: _securityId,
      labelOf: (id) {
        final security = securities.firstWhere((value) => value.id == id);
        return '${security.name} · ${security.symbol}';
      },
    );
    if (!mounted || selected == null) return;
    setState(() {
      _securityId = selected;
      _reviewed = false;
      _error = null;
    });
  }

  /// 金额使用共享数字键盘；[key]/[label] 标识草稿及本地化字段，净值和份额保留文本精度。
  /// [money] 是原币现金、[signed] 允许报告负浮盈、[readOnly] 禁止改写已发生的金额。
  Widget _field(
    String key,
    String label, {
    bool money = false,
    bool signed = false,
    bool readOnly = false,
  }) {
    return InvestmentInputField(
      label: label,
      child: TextField(
        key: ValueKey('fund-$key'),
        controller: _fields[key],
        readOnly: readOnly || money,
        onChanged: (value) => _changed(key, value),
        onTap: !money || readOnly
            ? null
            : () async {
                final value = await showNumberPadSheet(
                  context,
                  title: label,
                  initialAmount: double.tryParse(_fields[key]!.text),
                  currencyCode: _currency,
                  allowNegative: signed,
                  allowZero: key != 'cashAmount',
                );
                if (!mounted || value == null) return;
                _fields[key]!.text = value.toStringAsFixed(
                  CurrencyCatalog.require(_currency).minorUnit,
                );
                _changed(key, _fields[key]!.text);
              },
        keyboardType: key == 'note'
            ? TextInputType.text
            : const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
        maxLines: key == 'note' ? 3 : 1,
        decoration: investmentInputDecoration(context),
      ),
    );
  }

  /// [value] 是实际时刻或 UTC 日期载体；[dateOnly] 只选香港日历日期，否则保留真实时分。
  /// [onSelected] 仅更新本页草稿，取消任何一个选择器都不改变字段。
  Widget _dateField(
    String label,
    DateTime value,
    ValueChanged<DateTime> onSelected, {
    bool dateOnly = false,
    bool enabled = true,
  }) {
    // 日期行在实色卡片内自带墨水承载层，防止背景装饰遮住点按反馈。
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(formatQuoteTime(context, value, dateOnly: dateOnly)),
        trailing: enabled ? const Icon(Icons.calendar_today_outlined) : null,
        onTap: !enabled
            ? null
            : () async {
                final initial = dateOnly
                    ? DateTime(value.year, value.month, value.day)
                    : value.toLocal();
                final day = await showEntryDatePicker(
                  context: context,
                  initialDateTime: initial,
                );
                if (!mounted || day == null) return;
                DateTime selected;
                if (dateOnly) {
                  selected = DateTime.utc(day.year, day.month, day.day);
                } else {
                  final time = await showEntryTimePicker(
                    context: context,
                    initialDateTime: day,
                  );
                  if (!mounted || time == null) return;
                  selected = time;
                }
                setState(() {
                  onSelected(selected);
                  _reviewed = false;
                  _error = null;
                });
              },
      ),
    );
  }

  /// 按当前输入生成只读金额预览；编辑中的空值/非法值是正常草稿，不弹全局错误。
  FundAmountResult? _preview() {
    try {
      final quantity = _fields['confirmedQuantity']!.text.trim();
      if (widget.mode == FundEntryMode.holdingBaseline) {
        return calculateFundOpeningByUnrealized(
          cost: _fields['cost']!.text,
          reportedUnrealized: _fields['unrealized']!.text,
          nav: _fields['nav']!.text,
          currencyCode: _currency,
          confirmedQuantity: quantity.isEmpty ? null : quantity,
        );
      }
      return calculateFundPurchaseByAmount(
        cashAmount: _fields['cashAmount']!.text,
        nav: _fields['nav']!.text,
        currencyCode: _currency,
        fee: _fields['fee']!.text,
        confirmedQuantity: quantity.isEmpty ? null : quantity,
      );
    } on FormatException {
      // 用户尚未填齐金额或净值时不生成份额；保存操作会给出可见的本地化校验提示。
      return null;
    }
  }

  /// 仅使用此账户当前构建允许的缓存填入参考净值，不请求网络，也不自动确认个人申购。
  Widget _cachedNav(
    InvestmentPortfolio portfolio,
    StockSecurity? security,
    AppLocalizations l,
  ) {
    final c = VeriFinScope.of(context);
    final quote = security == null
        ? null
        : c.investmentQuoteSync.quotesFor(
            portfolio,
            includeFundHistory: true,
          )[security.id];
    if (quote == null ||
        quote.last == null ||
        !quote.dateOnly ||
        quote.lastAt == null) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      onPressed: () => setState(() {
        _fields['nav']!.text = quote.last!;
        _navDate = quote.lastAt!;
        _reviewed = false;
      }),
      icon: const Icon(Icons.history),
      label: Text(l.fundReadCachedNav),
    );
  }

  /// 展示 [result] 的原币金额、参考/确认份额及差额；不通过显示舍入改写现金或成本。
  Widget _previewPanel(FundAmountResult? result, AppLocalizations l) {
    if (result == null) return InvestmentHint(l.fundNoPreview);

    /// [value] 按当前原币现金精度展示；预览永远不反向覆盖输入的扣款和成本。
    String money(InvestmentDecimal value) =>
        formatUserMoney(value.toDouble(), _currency);
    return InvestmentSection(
      title: l.investValuationBasis,
      children: [
        if (result is FundPurchaseAmountResult)
          DetailInfoRow(
            inline: true,
            label: l.fundNetAmount,
            value: money(result.netAmount),
          ),
        if (result is FundOpeningAmountResult)
          DetailInfoRow(
            inline: true,
            label: l.fundTargetMarketValue,
            value: money(result.marketValue),
          ),
        DetailInfoRow(
          inline: true,
          label: l.fundEstimatedQuantity,
          value: result.estimatedQuantity.toString(),
        ),
        DetailInfoRow(
          inline: true,
          label: l.fundUsedQuantity,
          value: result.quantity.toString(),
        ),
        DetailInfoRow(
          inline: true,
          label: l.fundQuantityValue,
          value: money(result.pricedAmount),
        ),
        DetailInfoRow(
          inline: true,
          label: l.fundAmountDifference,
          value: formatSignedUserMoney(
            result.roundingDifference.toDouble(),
            _currency,
          ),
        ),
        InvestmentHint(l.fundQuantityInferredHint),
        if (result.roundingDifference.units != BigInt.zero)
          InvestmentHint(l.fundMismatchHint),
      ],
    );
  }

  /// 提交前核对账本及基金身份，确认必须显式勾选；只有 Controller 保存成功才退出。
  Future<void> _save() async {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (_saving || c.activeBook.id != _bookId) return;
    final p = c.investmentFor(widget.accountId);
    if (p == null) return;
    final security = _securities(
      p,
      l,
    ).where((value) => value.id == _securityId).firstOrNull;
    if (security == null) {
      setState(() => _error = l.fundSaveValidation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    var ok = false;
    try {
      if (widget.mode == FundEntryMode.holdingBaseline) {
        final result = _preview();
        if (result is! FundOpeningAmountResult || !_reviewed) {
          throw const FormatException('已有持仓资料尚未核对');
        }
        final sequence =
            widget.baselineEvent?.sequence ??
            p.events.fold<int>(
              0,
              (value, event) =>
                  event.sequence >= value ? event.sequence + 1 : value,
            );
        ok = await c.saveFundHoldingBaseline(
          accountId: widget.accountId,
          security: security,
          event: StockEvent(
            id: _id,
            securityId: security.id,
            kind: StockEventKind.fundHoldingBaseline,
            occurredAt: _baselineDate,
            sequence: sequence,
            quantity: result.quantity.toString(),
            price: result.navText,
            carriedCost: result.cost.toString(),
            reportedUnrealized: result.reportedUnrealized.toString(),
            fundNavDate: _navDate,
            quantityInferred: !result.quantityConfirmed,
            note: _fields['note']!.text.trim(),
          ),
          referencePrice: result.navText,
        );
      } else if (_action == _FundFormAction.application) {
        // 未确认申请可缺少净值；这里的 1 仅用于复用金额/费用校验，不保存或显示为成交净值。
        final values = calculateFundPurchaseByAmount(
          cashAmount: _fields['cashAmount']!.text,
          fee: _fields['fee']!.text,
          nav: '1',
          currencyCode: _currency,
        );
        ok = await c.saveFundSubscription(
          accountId: widget.accountId,
          security: security,
          subscription: FundSubscription(
            id: _id,
            securityId: security.id,
            requestedAt: _requestedAt,
            cashAmount: values.cashAmount.toString(),
            fee: values.fee.toString(),
            paidAt: _paid ? _paidAt : null,
            expectedConfirmationDate: _expected ? _expectedDate : null,
            note: _fields['note']!.text.trim(),
          ),
        );
      } else if (_action == _FundFormAction.confirmation) {
        final result = _preview();
        if (result is! FundPurchaseAmountResult ||
            !_reviewed ||
            widget.subscriptionId == null) {
          throw const FormatException('申购确认资料尚未核对');
        }
        ok = await c.confirmFundSubscription(
          accountId: widget.accountId,
          subscriptionId: widget.subscriptionId!,
          fee: result.fee.toString(),
          quantityInferred: !result.quantityConfirmed,
          confirmation: FundSubscriptionConfirmation(
            confirmedAt: _confirmedAt,
            navDate: _navDate,
            earningStartDate: _earningStartDate,
            nav: result.navText,
            quantity: result.quantity.toString(),
          ),
        );
      } else {
        if (widget.subscriptionId == null) {
          throw const FormatException('没有可取消的申购申请');
        }
        ok = await c.cancelFundSubscription(
          accountId: widget.accountId,
          subscriptionId: widget.subscriptionId!,
          cancelledAt: _cancelledAt,
          refundedAt: _refundReceived ? _refundedAt : null,
          refundAmount: _refundReceived
              ? _fields['refundAmount']!.text.trim()
              : null,
        );
      }
    } on FormatException {
      // 草稿不完整或精度非法时保留全部字段，使用统一本地化文案；持久化错误由 Controller 记录。
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = l.fundSaveValidation;
      });
    }
  }

  /// 删除仅作用于未扣款申请或用户明确选择的持仓基准，失败保持当前页面和草稿。
  Future<void> _delete() async {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final baseline = widget.baselineEvent != null;
    final confirmed = await showConfirmDialog(
      context,
      title: baseline ? l.investDelete : l.fundDeleteRequest,
      message: baseline ? l.investDeleteHint : l.fundDeleteRequestHint,
      destructive: true,
    );
    if (!mounted || !confirmed || c.activeBook.id != _bookId) return;
    setState(() => _saving = true);
    final ok = baseline
        ? await c.deleteStockEvent(widget.accountId, widget.baselineEvent!.id)
        : await c.deleteFundSubscription(
            accountId: widget.accountId,
            subscriptionId: widget.subscriptionId!,
          );
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

  /// 构建标准证券表单；实际资金、确认日期与起算日期分组，所有保存均由用户主动点击。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final p = c.investmentFor(widget.accountId);
    final account = c.accounts
        .where((value) => value.id == widget.accountId)
        .firstOrNull;
    if (p == null || account == null || c.activeBook.id != _bookId) {
      return Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                VeriHeader(title: l.fundOperations, showBack: true),
                Text(l.investSaveError),
              ],
            ),
          ),
        ),
      );
    }
    final subscription = p.fundSubscriptions
        .where((value) => value.id == widget.subscriptionId)
        .firstOrNull;
    if (widget.subscriptionId != null && subscription == null) {
      return Scaffold(
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                VeriHeader(title: l.fundOperations, showBack: true),
                Text(l.investSaveError),
              ],
            ),
          ),
        ),
      );
    }
    final securities = _securities(p, l);
    final selected = securities
        .where((value) => value.id == _securityId)
        .firstOrNull;
    final baseline = widget.mode == FundEntryMode.holdingBaseline;
    final locked = subscription?.paidAt != null;
    final refundLocked = subscription?.refundedAt != null;
    final applicationEditable =
        subscription?.confirmation == null && subscription?.cancelledAt == null;
    final preview = _preview();
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(
                title: baseline
                    ? l.fundRecordHolding
                    : subscription == null
                    ? l.fundBuyByAmount
                    : l.fundPendingTitle,
                showBack: true,
              ),
              const SizedBox(height: 12),
              InvestmentHint(
                baseline ? l.fundOpeningHint : l.fundSubmissionHint,
              ),
              const SizedBox(height: 12),
              if (securities.isEmpty) InvestmentHint(l.fundNoEligible),
              InvestmentSection(
                title: l.investSecurityDetails,
                children: [
                  if (securities.isNotEmpty)
                    SettingsRow(
                      icon: Icons.account_balance_outlined,
                      title: l.fundChoose,
                      trailing: selected?.name ?? l.fundChoose,
                      trailingMaxLines: null,
                      onTap:
                          _saving ||
                              widget.subscriptionId != null ||
                              widget.baselineEvent != null
                          ? null
                          : () => _chooseSecurity(securities),
                    ),
                  if (selected != null)
                    Text(
                      '${selected.symbol} · ${selected.market.label(l, fund: true)}',
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (subscription != null) ...[
                Text(
                  fundSubscriptionStatusLabel(subscription, l),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (applicationEditable)
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _action = _FundFormAction.application;
                                _reviewed = false;
                              }),
                        child: Text(l.fundRecordPayment),
                      ),
                    if (subscription.paidAt != null &&
                        subscription.cancelledAt == null)
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _action = _FundFormAction.confirmation;
                                _reviewed = false;
                              }),
                        child: Text(
                          subscription.confirmation == null
                              ? l.fundConfirmSubscription
                              : l.fundEditConfirmation,
                        ),
                      ),
                    if (subscription.confirmation == null)
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _action = _FundFormAction.cancellation;
                                _reviewed = false;
                              }),
                        child: Text(l.fundCancelSubscription),
                      ),
                  ],
                ),
              ],
              InvestmentSection(
                title: baseline ? l.fundRecordHolding : l.fundBuyByAmount,
                children: [
                  if (baseline) ...[
                    _field('cost', l.fundHoldingCost, money: true),
                    _field(
                      'unrealized',
                      l.fundReportedUnrealized,
                      money: true,
                      signed: true,
                    ),
                    _dateField(
                      l.fundBaselineDate,
                      _baselineDate,
                      (value) => _baselineDate = value,
                    ),
                    InvestmentHint(l.fundCashNotDeducted),
                  ] else ...[
                    _field(
                      'cashAmount',
                      l.fundCashAmount,
                      money: true,
                      readOnly: locked || !applicationEditable,
                    ),
                    _field(
                      'fee',
                      l.fundRequestFee,
                      money: true,
                      readOnly:
                          _action == _FundFormAction.cancellation ||
                          (!applicationEditable &&
                              _action != _FundFormAction.confirmation),
                    ),
                    if (locked) InvestmentHint(l.fundPaidAmountLocked),
                    _dateField(
                      l.fundRequestedAt,
                      _requestedAt,
                      (value) => _requestedAt = value,
                      enabled:
                          applicationEditable &&
                          _action == _FundFormAction.application,
                    ),
                    CompactSwitchRow(
                      icon: Icons.payments_outlined,
                      title: Text(l.fundAlreadyPaid),
                      value: _paid,
                      onChanged: locked || !applicationEditable
                          ? null
                          : (value) => setState(() => _paid = value),
                    ),
                    if (_paid)
                      _dateField(
                        l.fundPaidAt,
                        _paidAt,
                        (value) => _paidAt = value,
                        enabled: applicationEditable && !locked,
                      ),
                    if (_action == _FundFormAction.application) ...[
                      CompactSwitchRow(
                        icon: Icons.event_outlined,
                        title: Text(l.fundHasExpectedConfirmationDate),
                        value: _expected,
                        onChanged: (value) => setState(() => _expected = value),
                      ),
                      if (_expected)
                        _dateField(
                          l.fundExpectedConfirmationDate,
                          _expectedDate,
                          (value) => _expectedDate = value,
                          dateOnly: true,
                        ),
                    ],
                  ],
                  if (_action != _FundFormAction.cancellation || baseline) ...[
                    _field(
                      'nav',
                      baseline
                          ? l.fundHoldingNav
                          : _action == _FundFormAction.confirmation
                          ? l.fundConfirmedNav
                          : l.fundEstimatedNav,
                    ),
                    _cachedNav(p, selected, l),
                    if (baseline ||
                        _action == _FundFormAction.confirmation) ...[
                      _dateField(
                        l.fundNavDate,
                        _navDate,
                        (value) => _navDate = value,
                        dateOnly: true,
                      ),
                      _field(
                        'confirmedQuantity',
                        l.fundConfirmedQuantityOptional,
                      ),
                    ],
                  ],
                  if (!baseline && _action == _FundFormAction.confirmation) ...[
                    InvestmentHint(l.fundConfirmationHint),
                    _dateField(
                      l.fundConfirmedAt,
                      _confirmedAt,
                      (value) => _confirmedAt = value,
                    ),
                    _dateField(
                      l.fundEarningStartDate,
                      _earningStartDate,
                      (value) => _earningStartDate = value,
                      dateOnly: true,
                    ),
                  ],
                  if (!baseline && _action == _FundFormAction.cancellation) ...[
                    InvestmentHint(l.fundCancelHint),
                    _dateField(
                      l.fundCancelledAt,
                      _cancelledAt,
                      (value) => _cancelledAt = value,
                    ),
                    if (subscription?.paidAt != null) ...[
                      CompactSwitchRow(
                        icon: Icons.account_balance_wallet_outlined,
                        title: Text(l.fundRefundReceived),
                        value: _refundReceived,
                        onChanged: refundLocked
                            ? null
                            : (value) =>
                                  setState(() => _refundReceived = value),
                      ),
                      if (_refundReceived) ...[
                        _field(
                          'refundAmount',
                          l.fundRefundAmount,
                          money: true,
                          readOnly: refundLocked,
                        ),
                        _dateField(
                          l.fundRefundedAt,
                          _refundedAt,
                          (value) => _refundedAt = value,
                          enabled: !refundLocked,
                        ),
                      ],
                    ],
                  ],
                  if (baseline || _action == _FundFormAction.application)
                    _field('note', l.investNote),
                  InvestmentHint(l.fundScheduleHint),
                ],
              ),
              const SizedBox(height: 12),
              if (baseline || _action != _FundFormAction.cancellation)
                _previewPanel(preview, l),
              if (baseline || _action == _FundFormAction.confirmation)
                // 页面背景由 VeriPage 绘制；本层只为勾选行提供可见的交互反馈。
                Material(
                  type: MaterialType.transparency,
                  child: CheckboxListTile(
                    key: const Key('fund-reviewed'),
                    contentPadding: EdgeInsets.zero,
                    value: _reviewed,
                    title: Text(l.fundConfirmationCheck),
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _reviewed = value ?? false),
                  ),
                ),
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
                key: const Key('fund-save'),
                onPressed: _saving || securities.isEmpty ? null : _save,
                child: Text(
                  _saving
                      ? l.commonProcessing
                      : baseline
                      ? l.investSave
                      : _action == _FundFormAction.application
                      ? l.fundSaveRequest
                      : _action == _FundFormAction.confirmation
                      ? l.fundConfirmSubscription
                      : l.fundSaveCancellation,
                ),
              ),
              if (widget.baselineEvent != null ||
                  (subscription != null &&
                      subscription.paidAt == null &&
                      subscription.confirmation == null))
                TextButton(
                  onPressed: _saving ? null : _delete,
                  child: Text(baseline ? l.investDelete : l.fundDeleteRequest),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
