/// 期权草稿与结算预览：只经 Controller 写入，联网行情不能填充真实成交或合约规格。
library;

import 'package:flutter/material.dart';
import '../app/calendar_days.dart';
import '../app/common_widgets.dart';
import '../app/investments/investment_widgets.dart';
import '../app/currency_math.dart';
import '../app/investments/stock_projection.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';

/// 可取消的完整期权草稿；从持仓或既有投资记录进入时复用相同界面。
class OptionEditorPage extends StatefulWidget {
  /// [accountId] 为真实币种账户；[event] 编辑原事件，[specificationOnly] 只核对静态规格。
  const OptionEditorPage({
    super.key,
    required this.accountId,
    this.securityId,
    this.event,
    this.specificationOnly = false,
    this.initialShort = false,
  });
  final String accountId;
  final String? securityId;
  final StockEvent? event;
  final bool specificationOnly;
  final bool initialShort;

  /// 每个页面持有独立草稿，离页时销毁，不通过全局状态中转未确认输入。
  @override
  State<OptionEditorPage> createState() => _OptionEditorPageState();
}

/// 预览后冻结的提交事实；任何字段变化都废弃它，保存时仍由 Controller 重新校验。
class _OptionDraft {
  /// 包含实际事件及用户确认参考价；[underlyingPrice] 可空，但实物交割后有股票须有价。
  const _OptionDraft(
    this.security,
    this.underlying,
    this.event,
    this.price,
    this.underlyingPrice,
  );
  final StockSecurity security, underlying;
  final StockEvent event;
  final String price;
  final String? underlyingPrice;
}

class _OptionEditorPageState extends State<OptionEditorPage> {
  final _fields = <String, TextEditingController>{};
  bool _loaded = false,
      _busy = false,
      _short = false,
      _confirmed = false,
      _specConfirmed = false,
      _uncovered = false;
  late String _bookId, _id;
  String? _selected, _error;
  late DateTime _date, _expiry;
  late int _sequence;
  StockMarket _market = StockMarket.us;
  OptionRight _right = OptionRight.call;
  OptionSettlement _settlement = OptionSettlement.unsupported;
  StockEventKind _kind = StockEventKind.optionBuyOpen;
  _OptionDraft? _draft;
  ({InvestmentPortfolio portfolio, StockProjection projection, double cash})?
  _preview;

  /// 从当前账户初始化一次；普通刷新不覆盖用户正在编辑的文本。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final c = VeriFinScope.of(context), p = c.investmentFor(widget.accountId);
    _bookId = c.activeBook.id;
    final e = widget.event;
    _id = e?.id ?? 'option-${DateTime.now().microsecondsSinceEpoch}';
    _date = e?.occurredAt ?? DateTime.now();
    _expiry = addCalendarDays(_date, 30);
    _sequence =
        e?.sequence ??
        (p?.events.fold<int>(
              0,
              (n, e) => e.sequence >= n ? e.sequence + 1 : n,
            ) ??
            0);
    _kind =
        e?.kind ??
        (widget.securityId == null
            ? StockEventKind.optionBuyOpen
            : widget.initialShort
            ? StockEventKind.optionBuyClose
            : StockEventKind.optionSellClose);
    _short = e?.short ?? widget.initialShort;
    _confirmed = e?.settlementConfirmed ?? false;
    _uncovered = e?.allowUncoveredAssignment ?? false;
    for (final key in [
      'symbol',
      'name',
      'underlying',
      'underlyingName',
      'underlyingPrice',
      'strike',
      'multiplier',
      'shares',
      'exercise',
      'source',
      'quantity',
      'price',
      'fee',
      'reference',
      'margin',
      'note',
    ]) {
      _fields[key] = TextEditingController();
    }
    _fields['fee']!.text = e?.fee ?? '0';
    _fields['quantity']!.text = e?.quantity ?? '';
    _fields['price']!.text = e?.price ?? '';
    _fields['margin']!.text = e?.marginAfter ?? '';
    _fields['note']!.text = e?.note ?? '';
    final selected = p?.securities
        .where((s) => s.id == (e?.securityId ?? widget.securityId))
        .firstOrNull;
    if (selected != null) _loadContract(selected, p!);
  }

  /// 载入明确选择的合约；不从 AVGO 行情页猜乘数、到期日或交割股数。
  void _loadContract(StockSecurity s, InvestmentPortfolio p) {
    final o = s.option!;
    final underlying = p.securities.firstWhere((v) => v.id == o.underlyingId);
    _selected = s.id;
    _market = s.market;
    _right = o.right;
    _settlement = o.settlement;
    _expiry = DateTime.parse(o.expiry);
    _specConfirmed = o.confirmed;
    for (final pair in {
      'symbol': s.symbol,
      'name': s.name,
      'underlying': underlying.symbol,
      'underlyingName': underlying.name,
      'underlyingPrice': p.manualPrices[underlying.id] ?? '',
      'strike': o.strike,
      'multiplier': o.premiumMultiplier,
      'shares': o.deliverableShares,
      'exercise': o.exerciseCash,
      'source': o.specification,
      'reference': p.manualPrices[s.id] ?? '',
    }.entries) {
      _fields[pair.key]!.text = pair.value;
    }
    _invalidate();
  }

  /// 清除预览令牌；修改任何输入后必须重新预览，避免按旧画面确认新数据。
  void _invalidate() {
    _draft = null;
    _preview = null;
    _error = null;
  }

  /// 释放所有输入资源，取消或系统返回均不持久化草稿。
  @override
  void dispose() {
    for (final f in _fields.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// 构造带稳定测试键的输入；[number] 使用小数键盘，[locked] 保护已有定价身份。
  Widget _field(
    String key,
    String label, {
    bool number = false,
    bool locked = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: ValueKey('option-$key'),
      controller: _fields[key],
      readOnly: locked || _busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: false)
          : TextInputType.text,
      onChanged: (_) => setState(_invalidate),
      decoration: investmentInputDecoration(context, label),
    ),
  );

  /// 用文本事实建立候选；每张行权现金直接取输入，不用行权价乘股数猜调整合约。
  _OptionDraft _readDraft(InvestmentPortfolio p) {
    String text(String key) => _fields[key]!.text.trim();
    final underlying = StockSecurity(
      symbol: text('underlying'),
      name: text('underlyingName'),
      market: _market,
      currencyCode: p.currencyCode,
    );
    final contract = OptionContract(
      underlyingId: underlying.id,
      expiry: _expiry.toIso8601String().substring(0, 10),
      right: _right,
      strike: text('strike'),
      premiumMultiplier: text('multiplier'),
      settlement: _settlement,
      deliverableShares: text('shares').isEmpty ? '0' : text('shares'),
      exerciseCash: text('exercise').isEmpty ? '0' : text('exercise'),
      specification: text('source'),
      confirmed: _specConfirmed,
    );
    final security = StockSecurity(
      symbol: text('symbol'),
      name: text('name'),
      market: _market,
      currencyCode: p.currencyCode,
      option: contract,
    );
    final zeroPrice = {
      StockEventKind.optionExpire,
      StockEventKind.optionPhysicalSettle,
      StockEventKind.optionMargin,
    }.contains(_kind);
    final event = StockEvent(
      id: _id,
      securityId: security.id,
      kind: _kind,
      occurredAt: _date,
      sequence: _sequence,
      quantity: _kind == StockEventKind.optionMargin ? '0' : text('quantity'),
      price: zeroPrice ? '0' : text('price'),
      fee: _kind == StockEventKind.optionMargin ? '0' : text('fee'),
      short: _short,
      marginAfter: text('margin').isEmpty ? null : text('margin'),
      settlementConfirmed: _confirmed,
      allowUncoveredAssignment: _uncovered,
      note: text('note'),
    );
    return _OptionDraft(
      security,
      underlying,
      event,
      text('reference'),
      text('underlyingPrice').isEmpty ? null : text('underlyingPrice'),
    );
  }

  /// 零副作用预览；完整重放后显示现金、冻结额和所有多空持仓，失败保留输入。
  void _makePreview(InvestmentPortfolio p) {
    final d = _readDraft(p), c = VeriFinScope.of(context);
    final preview = c.previewOptionEvent(
      accountId: widget.accountId,
      security: d.security,
      underlying: d.underlying,
      event: d.event,
      referencePrice: d.price,
      underlyingReferencePrice: d.underlyingPrice,
    );
    setState(() {
      _preview = preview;
      _draft = preview == null ? null : d;
      _error = preview == null
          ? AppLocalizations.of(context).optionValidationError
          : null;
    });
  }

  /// 提交已预览的冻结事实；保存失败不退页，不宣称已落账。
  Future<void> _save(InvestmentPortfolio p) async {
    if (_busy) return;
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final d = widget.specificationOnly ? _readDraft(p) : _draft;
    if (d == null) return;
    setState(() => _busy = true);
    final ok = widget.specificationOnly
        ? await c.saveOptionSpecification(widget.accountId, d.security)
        : await c.saveOptionEvent(
            accountId: widget.accountId,
            security: d.security,
            underlying: d.underlying,
            event: d.event,
            referencePrice: d.price,
            underlyingReferencePrice: d.underlyingPrice,
          );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = l.optionValidationError;
      });
    }
  }

  /// 删除也重放全部后续交割；破坏后续持仓/资金的删除会被拒绝，不残留半笔。
  Future<void> _delete() async {
    final l = AppLocalizations.of(context), c = VeriFinScope.of(context);
    final yes = await showConfirmDialog(
      context,
      title: l.investDelete,
      message: l.investDeleteHint,
      destructive: true,
    );
    if (!mounted || yes != true) return;
    setState(() => _busy = true);
    final ok = await c.deleteStockEvent(widget.accountId, widget.event!.id);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = l.optionValidationError;
      });
    }
  }

  /// 实色完整页面；动态合约选择、日期与静态动作均复用现有公共组件。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context),
        l = AppLocalizations.of(context),
        p = c.investmentFor(widget.accountId);
    if (c.activeBook.id != _bookId || p == null) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(l.investSaveError))),
      );
    }
    final existing = p.securities.where((s) => s.option != null).toList();
    final settles = {
      StockEventKind.optionExpire,
      StockEventKind.optionCashSettle,
      StockEventKind.optionPhysicalSettle,
    }.contains(_kind);
    final value = _preview == null
        ? null
        : valueStocks(_preview!.portfolio, _preview!.projection).marketValue;
    final locked = _selected != null;
    return Scaffold(
      body: SafeArea(
        child: VeriPage(
          child: Material(
            color: Colors.transparent,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                VeriHeader(
                  title: widget.specificationOnly
                      ? l.optionVerifySpec
                      : l.optionTitle,
                  showBack: true,
                ),
                const SizedBox(height: 12),
                InvestmentHint(l.optionManualHint),
                const SizedBox(height: 12),
                InvestmentSection(
                  title: l.investSecurityDetails,
                  children: [
                    if (existing.isNotEmpty &&
                        widget.event == null &&
                        !widget.specificationOnly)
                      OutlinedButton(
                        style: investmentOutlineButtonStyle(context),
                        onPressed: _busy
                            ? null
                            : () async {
                                final selected = await showOptionSheet<String>(
                                  context: context,
                                  title: l.optionSelect,
                                  values: existing.map((s) => s.id).toList(),
                                  selected: _selected ?? existing.first.id,
                                  labelOf: (id) => existing
                                      .firstWhere((s) => s.id == id)
                                      .symbol,
                                );
                                if (!mounted || selected == null) return;
                                setState(
                                  () => _loadContract(
                                    existing.firstWhere(
                                      (s) => s.id == selected,
                                    ),
                                    p,
                                  ),
                                );
                              },
                        child: Text(l.optionSelect),
                      ),
                    if (!widget.specificationOnly) ...[
                      VeriAnchoredChoice<StockEventKind>(
                        values: const [
                          StockEventKind.optionBuyOpen,
                          StockEventKind.optionSellClose,
                          StockEventKind.optionSellOpen,
                          StockEventKind.optionBuyClose,
                          StockEventKind.optionExpire,
                          StockEventKind.optionCashSettle,
                          StockEventKind.optionPhysicalSettle,
                          StockEventKind.optionMargin,
                        ],
                        selected: _kind,
                        idOf: (v) => v.name,
                        semanticLabel: l.investEventType,
                        builder: (context, open, active) => SettingsRow(
                          icon: Icons.swap_horiz,
                          title: l.investEventType,
                          trailing: _kind.label(l),
                          trailingMaxLines: null,
                          trailingIcon: Icons.unfold_more,
                          onTap: _busy ? null : open,
                        ),
                        labelOf: (v) => v.label(l),
                        onSelected: _busy
                            ? (_) {}
                            : (v) => setState(() {
                                _kind = v;
                                _invalidate();
                              }),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (!locked)
                      VeriAnchoredChoice<StockMarket>(
                        values: StockMarket.values,
                        selected: _market,
                        idOf: (v) => v.name,
                        semanticLabel: l.investMarket,
                        builder: (context, open, active) => SettingsRow(
                          icon: Icons.public,
                          title: l.investMarket,
                          trailing: _market.label(l),
                          trailingMaxLines: null,
                          trailingIcon: Icons.unfold_more,
                          onTap: _busy ? null : open,
                        ),
                        labelOf: (v) => v.label(l),
                        onSelected: (v) => setState(() {
                          _market = v;
                          _invalidate();
                        }),
                      ),
                    _field('symbol', l.optionCode, locked: locked),
                    _field('name', l.investName),
                    _field('underlying', l.optionUnderlying, locked: locked),
                    _field('underlyingName', l.optionUnderlyingName),
                  ],
                ),
                const SizedBox(height: 12),
                InvestmentSection(
                  title: l.investContractTerms,
                  children: [
                    Text(
                      currencyUnitSubtitle(
                            l,
                            l.investCurrency,
                            p.currencyCode,
                          ) ??
                          l.investCurrency,
                    ),
                    if (!locked)
                      VeriAnchoredChoice<OptionRight>(
                        values: OptionRight.values,
                        selected: _right,
                        idOf: (v) => v.name,
                        semanticLabel: l.optionCall,
                        builder: (context, open, active) => SettingsRow(
                          icon: Icons.description_outlined,
                          title: l.optionRightType,
                          trailing: _right.label(l),
                          trailingMaxLines: null,
                          trailingIcon: Icons.unfold_more,
                          onTap: _busy ? null : open,
                        ),
                        labelOf: (v) => v.label(l),
                        onSelected: (v) => setState(() {
                          _right = v;
                          _invalidate();
                        }),
                      )
                    else
                      Text(_right.label(l)),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.optionExpiry),
                      subtitle: Text(
                        MaterialLocalizations.of(
                          context,
                        ).formatFullDate(_expiry),
                      ),
                      onTap: locked || _busy
                          ? null
                          : () async {
                              final date = await showEntryDatePicker(
                                context: context,
                                initialDateTime: _expiry,
                              );
                              if (!mounted || date == null) return;
                              setState(() {
                                _expiry = date;
                                _invalidate();
                              });
                            },
                    ),
                    _field(
                      'strike',
                      l.optionStrike,
                      number: true,
                      locked: locked,
                    ),
                    _field(
                      'multiplier',
                      l.optionMultiplier,
                      number: true,
                      locked: locked,
                    ),
                    VeriAnchoredChoice<OptionSettlement>(
                      values: OptionSettlement.values,
                      selected: _settlement,
                      idOf: (v) => v.name,
                      semanticLabel: l.optionVerifySpec,
                      builder: (context, open, active) => SettingsRow(
                        icon: Icons.description_outlined,
                        title: l.optionVerifySpec,
                        trailing: _settlement.label(l),
                        trailingMaxLines: null,
                        trailingIcon: Icons.unfold_more,
                        onTap: _busy ? null : open,
                      ),
                      labelOf: (v) => v.label(l),
                      onSelected: (v) => setState(() {
                        _settlement = v;
                        _invalidate();
                      }),
                    ),
                    if (_settlement == OptionSettlement.physical) ...[
                      _field('shares', l.optionDeliverableShares, number: true),
                      _field('exercise', l.optionExerciseCash, number: true),
                      Text(l.optionAdjustmentHint),
                    ],
                    _field('source', l.optionSpecification),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _specConfirmed,
                      title: Text(l.optionSpecConfirmed),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _specConfirmed = v ?? false;
                              _invalidate();
                            }),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (!widget.specificationOnly) ...[
                  InvestmentSection(
                    title: l.investTradeDetails,
                    children: [
                      if (_kind != StockEventKind.optionMargin)
                        _field('quantity', l.optionContracts, number: true),
                      if (!{
                        StockEventKind.optionExpire,
                        StockEventKind.optionPhysicalSettle,
                        StockEventKind.optionMargin,
                      }.contains(_kind))
                        _field(
                          'price',
                          _kind == StockEventKind.optionCashSettle
                              ? l.optionActualSettlement
                              : l.optionPremium,
                          number: true,
                        ),
                      if (_kind != StockEventKind.optionMargin)
                        _field('fee', l.investFees, number: true),
                      if (settles) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _short,
                          title: Text(l.investShortPosition),
                          onChanged: _busy
                              ? null
                              : (v) => setState(() {
                                  _short = v;
                                  _invalidate();
                                }),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _confirmed,
                          title: Text(l.optionSettlementConfirmed),
                          onChanged: _busy
                              ? null
                              : (v) => setState(() {
                                  _confirmed = v ?? false;
                                  _invalidate();
                                }),
                        ),
                      ],
                      if (_kind == StockEventKind.optionPhysicalSettle)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _uncovered,
                          title: Text(l.optionUncoveredConsent),
                          onChanged: _busy
                              ? null
                              : (v) => setState(() {
                                  _uncovered = v ?? false;
                                  _invalidate();
                                }),
                        ),
                      _field('margin', l.optionMarginAfter, number: true),
                      Text(l.optionMarginHint),
                      _field('reference', l.investReference, number: true),
                      _field(
                        'underlyingPrice',
                        l.optionUnderlyingReference,
                        number: true,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l.investDate),
                        subtitle: Text(
                          '${MaterialLocalizations.of(context).formatFullDate(_date)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(_date))}',
                        ),
                        onTap: _busy
                            ? null
                            : () async {
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
                                setState(() {
                                  _date = time;
                                  _invalidate();
                                });
                              },
                      ),
                      _field('note', l.investNote),
                    ],
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    style: investmentOutlineButtonStyle(context),
                    onPressed: _busy ? null : () => _makePreview(p),
                    child: Text(l.optionPreview),
                  ),
                ] else
                  Text(l.optionSpecOnlyHint),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_preview != null)
                  VeriCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SectionTitle(title: l.optionPreview),
                        const SizedBox(height: 8),
                        DetailInfoRow(
                          inline: true,
                          label: l.investCash,
                          value: formatUserMoney(
                            _preview!.cash,
                            p.currencyCode,
                          ),
                        ),
                        DetailInfoRow(
                          inline: true,
                          label: l.optionMargin,
                          value: formatUserMoney(
                            _preview!.projection.frozenMargin.toDouble(),
                            p.currencyCode,
                          ),
                        ),
                        DetailInfoRow(
                          inline: true,
                          label: l.investNetValue,
                          value: value == null
                              ? l.investUnknown
                              : formatUserMoney(
                                  _preview!.cash + value.toDouble(),
                                  p.currencyCode,
                                ),
                        ),
                        const Divider(height: 20),
                        for (final holding in _preview!.projection.positions)
                          Text(
                            '${_preview!.portfolio.securities.firstWhere((s) => s.id == holding.securityId).symbol} · ${holding.short ? l.investShortPosition : l.investLong} · ${holding.quantity} · ${l.investCost}: ${holding.cost == null ? l.investUnknown : formatUserMoney(holding.cost!.toDouble(), p.currencyCode)}',
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      _busy || (!widget.specificationOnly && _draft == null)
                      ? null
                      : () => _save(p),
                  child: Text(_busy ? l.commonProcessing : l.investSave),
                ),
                if (widget.event != null && !widget.specificationOnly)
                  TextButton(
                    onPressed: _busy ? null : _delete,
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
