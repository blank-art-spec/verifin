/// 期权草稿与结算预览：只经 Controller 写入，联网行情不能填充真实成交或合约规格。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import '../app/calendar_days.dart';
import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_opening_draft.dart';
import '../app/investments/investment_widgets.dart';
import '../app/currency_math.dart';
import '../app/investments/stock_projection.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'sheets.dart';
import 'entry_editor_session.dart';

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
    this.editorSession,
    this.openingPortfolio,
    this.openingHolding,
  }) : assert(openingHolding == null || openingPortfolio != null),
       assert(
         openingPortfolio == null || (event == null && !specificationOnly),
       );
  final String accountId;
  final String? securityId;
  final StockEvent? event;
  final bool specificationOnly;
  final bool initialShort;

  /// 非空时由双页签外壳管理保存和返回，本页仅提供同一套期权表单。
  final EntryEditorSession? editorSession;

  /// 非空时只编辑启用页持有的期初草稿，返回条目，不创建组合或成交。
  final InvestmentPortfolio? openingPortfolio;
  final InvestmentOpeningHolding? openingHolding;

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
  final _exitController = EditorExitController();
  String? _initialEditorSnapshot;
  bool _submitted = false;
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
  InvestmentOpeningHolding? _openingResult;
  String? _previewInputSnapshot;
  ({InvestmentPortfolio portfolio, StockProjection projection, double cash})?
  _preview;

  bool get _opening => widget.openingPortfolio != null;

  /// 期初页的组合尚未落库；普通交易继续只读 Controller 的当前组合。
  InvestmentPortfolio? get _portfolio =>
      widget.openingPortfolio ??
      VeriFinScope.of(context).investmentFor(widget.accountId);

  /// 只比较用户可编辑事实，预览计算本身不视作一笔待保存修改。
  String get _editorSnapshot => editorDraftSnapshot(
    fields: _fields,
    values: [
      _selected,
      _date.toIso8601String(),
      _expiry.toIso8601String(),
      _market.name,
      _right.name,
      _settlement.name,
      _kind.name,
      _short,
      _confirmed,
      _specConfirmed,
      _uncovered,
    ],
  );

  /// 初次装入合约后捕获基线；成功提交后不能再次新增相同事件。
  bool get _editorDirty =>
      !_submitted &&
      _initialEditorSnapshot != null &&
      _initialEditorSnapshot != _editorSnapshot;

  /// 从当前账户初始化一次；普通刷新不覆盖用户正在编辑的文本。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final c = VeriFinScope.of(context), p = _portfolio;
    _bookId = c.activeBook.id;
    final e = widget.event;
    _id = e?.id ?? 'option-${DateTime.now().microsecondsSinceEpoch}';
    _date =
        e?.occurredAt ?? widget.openingPortfolio?.openedAt ?? DateTime.now();
    _expiry = addCalendarDays(_date, 30);
    _sequence =
        e?.sequence ?? c.nextInvestmentEventSequenceFor(widget.accountId) ?? 0;
    _kind =
        e?.kind ??
        (widget.securityId == null
            ? StockEventKind.optionBuyOpen
            : widget.initialShort
            ? StockEventKind.optionBuyClose
            : StockEventKind.optionSellClose);
    _short = e?.short ?? widget.initialShort;
    if (_opening) {
      _market = p?.currencyCode == 'HKD'
          ? StockMarket.hk
          : p?.currencyCode == 'CNY'
          ? StockMarket.cn
          : StockMarket.us;
    }
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
      'cost',
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
    final opening = widget.openingHolding;
    if (opening != null && p != null) {
      final underlying = opening.underlying;
      _loadContract(
        opening.security,
        p.copyWith(
          securities: [
            ...p.securities.where((s) => s.id != underlying?.id),
            ?underlying,
          ],
        ),
      );
      _short = opening.holding.short;
      _fields['quantity']!.text = opening.holding.quantity;
      _fields['cost']!.text = opening.holding.cost ?? '';
      _fields['margin']!.text = opening.frozenMargin ?? '';
      _fields['reference']!.text = opening.referencePrice;
      _fields['underlyingPrice']!.text = opening.underlyingPrice ?? '';
    }
    _initialEditorSnapshot = _editorSnapshot;
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
    if (_opening && widget.openingHolding == null) {
      _fields['margin']!.text =
          projectStocks(p).frozenMargins[s.id]?.toString() ?? '';
    }
    _invalidate();
  }

  /// 清除预览令牌；修改任何输入后必须重新预览，避免按旧画面确认新数据。
  void _invalidate() {
    _draft = null;
    _preview = null;
    _previewInputSnapshot = null;
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

  /// [key] 定位草稿及测试输入框，[label] 独立占位，避免与前方说明重叠；
  /// [number] 使用小数键盘，[locked] 保护已有定价身份，修改后仍须重新预览。
  Widget _field(
    String key,
    String label, {
    bool number = false,
    bool locked = false,
  }) => InvestmentInputField(
    label: label,
    child: TextField(
      key: ValueKey('option-$key'),
      controller: _fields[key],
      readOnly: locked || _busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: false)
          : TextInputType.text,
      onChanged: (_) => setState(_invalidate),
      decoration: investmentInputDecoration(context),
    ),
  );

  /// 用文本事实建立候选；每张行权现金直接取输入，不用行权价乘股数猜调整合约。
  ({StockSecurity security, StockSecurity underlying}) _readSecurities(
    InvestmentPortfolio p,
  ) {
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
    return (security: security, underlying: underlying);
  }

  /// 实际交易沿用原来的事件语义；期初条目不经过此方法。
  _OptionDraft _readDraft(InvestmentPortfolio p) {
    String text(String key) => _fields[key]!.text.trim();
    final definitions = _readSecurities(p);
    final security = definitions.security, underlying = definitions.underlying;
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

  /// 用临时组合核对期初条目，编辑时先移除原方向，不覆盖其他期初或产生交易。
  /// 成本为原币总额；参考权利金通过现有乘数算法估值，冻结额只作披露。
  InvestmentOpeningHolding _readOpening(InvestmentPortfolio p) {
    String text(String key) => _fields[key]!.text.trim();
    final definitions = _readSecurities(p),
        digits = CurrencyCatalog.require(p.currencyCode).minorUnit;
    final quantity = InvestmentDecimal.parse(text('quantity'));
    final rawCost = text('cost').isEmpty
        ? null
        : InvestmentDecimal.parse(text('cost'));
    final reference = InvestmentDecimal.parse(text('reference'));
    final rawMargin = text('margin').isEmpty
        ? null
        : InvestmentDecimal.parse(text('margin'));
    final underlyingPrice = text('underlyingPrice').isEmpty
        ? null
        : InvestmentDecimal.parse(text('underlyingPrice'));
    if ((rawCost != null && rawCost.units < BigInt.zero) ||
        reference.units < BigInt.zero ||
        (underlyingPrice != null && underlyingPrice.units < BigInt.zero)) {
      throw const FormatException('期初成本或参考价不能为负');
    }
    // 总成本舍入后也必须处于金额显示边界内；尤其接近上限时不能向父列表返回溢出值。
    final totalCost = rawCost?.rounded(digits);
    totalCost?.toDouble();
    reference.toDouble();
    underlyingPrice?.toDouble();
    rawMargin?.toDouble();
    final holding = StockHolding(
      securityId: definitions.security.id,
      short: _short,
      quantity: quantity.toString(),
      cost: totalCost?.toString(),
    );
    final original = widget.openingHolding?.holding;
    final candidate = p.copyWith(
      securities: [
        ...p.securities.where(
          (s) =>
              s.id != definitions.underlying.id &&
              s.id != definitions.security.id,
        ),
        definitions.underlying,
        definitions.security,
      ],
      openingHoldings: [
        ...p.openingHoldings.where(
          (h) =>
              original == null ||
              h.securityId != original.securityId ||
              h.short != original.short,
        ),
        holding,
      ],
      events: [
        ...p.events,
        if (rawMargin != null)
          StockEvent(
            id: 'opening-margin-check-$_id',
            securityId: definitions.security.id,
            kind: StockEventKind.optionMargin,
            occurredAt: p.openedAt,
            sequence: p.events.fold<int>(
              0,
              (value, e) => e.sequence >= value ? e.sequence + 1 : value,
            ),
            quantity: '0',
            price: '0',
            marginAfter: rawMargin.toString(),
          ),
      ],
      manualPrices: {
        ...p.manualPrices,
        definitions.security.id: reference.toString(),
        if (underlyingPrice != null)
          definitions.underlying.id: underlyingPrice.toString(),
      },
    );
    final projection = projectStocks(candidate);
    final valuation = valueStocks(candidate, projection);
    if (valuation.marketValue == null) {
      throw const FormatException('期初持仓须填写有效参考价');
    }
    valuation.marketValue!.toDouble();
    return InvestmentOpeningHolding(
      security: definitions.security,
      holding: holding,
      referencePrice: reference.toString(),
      underlying: definitions.underlying,
      underlyingPrice: underlyingPrice?.toString(),
      frozenMargin: rawMargin?.toString(),
    );
  }

  /// 期初草稿也绑定真实币种账户及当前账本，切换或删除后不能带回旧资料。
  bool _hasValidAccount(InvestmentPortfolio p) {
    final c = VeriFinScope.of(context);
    return c.activeBook.id == _bookId &&
        p.accountId == widget.accountId &&
        p.bookId == _bookId &&
        c.accounts.any(
          (a) =>
              a.id == widget.accountId &&
              a.bookId == _bookId &&
              a.currencyCode == p.currencyCode &&
              a.type.supportsSecurities,
        );
  }

  /// 捕获实际影响预览的账户组合与现金，字符串只留当前编辑会话，不输出或持久化。
  /// [portfolio] 必须来自当前账户；普通资金流水或现金核对改变余额也会要求重新预览。
  String _previewSnapshot(InvestmentPortfolio portfolio) {
    final controller = VeriFinScope.of(context);
    final account = controller.accounts
        .where((value) => value.id == widget.accountId)
        .firstOrNull;
    return jsonEncode({
      'portfolio': portfolio.toJson(),
      'cash': account == null ? null : controller.accountBalance(account),
    });
  }

  /// 零副作用预览；按最新组合读取新事件序号，编辑已有事件仍保留其原序号。
  /// 完整重放后显示现金和持仓；其他草稿提交后旧预览必须重新核对，不能自动确认。
  void _makePreview() {
    final c = VeriFinScope.of(context), p = c.investmentFor(widget.accountId);
    final nextSequence =
        widget.event?.sequence ??
        c.nextInvestmentEventSequenceFor(widget.accountId);
    if (c.activeBook.id != _bookId || p == null || nextSequence == null) {
      setState(() {
        _invalidate();
        _error = AppLocalizations.of(context).optionValidationError;
      });
      return;
    }
    _sequence = nextSequence;
    final d = _readDraft(p);
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
      _previewInputSnapshot = preview == null ? null : _previewSnapshot(p);
      _error = preview == null
          ? AppLocalizations.of(context).optionValidationError
          : null;
    });
  }

  /// 提交已预览的冻结事实；保存失败不退页，不宣称已落账。
  Future<bool> _save(InvestmentPortfolio p) async {
    if (_busy || _submitted) return false;
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (_opening) {
      if (!_hasValidAccount(p)) {
        setState(() => _error = l.optionValidationError);
        return false;
      }
      try {
        final result = _readOpening(p);
        setState(() {
          _openingResult = result;
          _submitted = true;
          _initialEditorSnapshot = _editorSnapshot;
          _error = null;
        });
        return true;
      } on FormatException {
        setState(() => _error = l.optionValidationError);
        return false;
      }
    }
    final current = c.investmentFor(widget.accountId);
    if (c.activeBook.id != _bookId ||
        current == null ||
        !c.accounts.any(
          (account) =>
              account.id == widget.accountId && account.bookId == _bookId,
        )) {
      setState(() => _error = l.optionValidationError);
      return false;
    }
    if (!widget.specificationOnly &&
        _previewInputSnapshot != _previewSnapshot(current)) {
      setState(() {
        _invalidate();
        _error = l.optionValidationError;
      });
      return false;
    }
    final d = widget.specificationOnly ? _readDraft(current) : _draft;
    if (d == null || c.activeBook.id != _bookId) return false;
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
    if (!mounted) return false;
    if (ok) {
      setState(() {
        _busy = false;
        _submitted = true;
        _initialEditorSnapshot = _editorSnapshot;
      });
    } else {
      setState(() {
        _busy = false;
        _error = l.optionValidationError;
      });
    }
    return ok;
  }

  /// 原独立期权页保存后走受控返回，保留原预览及 Controller 二次校验流程。
  Future<void> _saveAndExit(InvestmentPortfolio portfolio) async {
    if (await _save(portfolio) && mounted) {
      _exitController.exit(result: () => _openingResult);
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
      _exitController.exit();
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
        p = _portfolio;
    if (c.activeBook.id != _bookId ||
        p == null ||
        (_opening && !_hasValidAccount(p))) {
      return EntryEditorSurface(
        session: widget.editorSession,
        isDirty: _editorDirty,
        canSave: false,
        onSave: () async => false,
        exitController: _exitController,
        isSaving: _busy,
        body: SafeArea(child: Center(child: Text(l.investSaveError))),
      );
    }
    if (!_busy &&
        !_submitted &&
        _previewInputSnapshot != null &&
        _previewInputSnapshot != _previewSnapshot(p)) {
      // Scope 更新可能来自另一份隐藏草稿或普通资金流水，旧预览不能继续作为确认。
      _invalidate();
      _error = l.optionValidationError;
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
    final locked = !_opening && _selected != null;
    return EntryEditorSurface(
      session: widget.editorSession,
      isDirty: _editorDirty,
      canSave:
          !_busy &&
          !_submitted &&
          (_opening || widget.specificationOnly || _draft != null),
      onSave: () => _save(p),
      exitController: _exitController,
      isSaving: _busy,
      popResult: () => _openingResult,
      body: SafeArea(
        child: VeriPage(
          child: Material(
            color: Colors.transparent,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                if (widget.editorSession == null)
                  VeriHeader(
                    title: _opening
                        ? l.investOpeningOptionTitle
                        : widget.specificationOnly
                        ? l.optionVerifySpec
                        : l.optionTitle,
                    showBack: true,
                  ),
                const SizedBox(height: 12),
                InvestmentHint(
                  _opening ? l.investOpeningOptionHint : l.optionManualHint,
                ),
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
                    if (!widget.specificationOnly && !_opening) ...[
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
                if (_opening) ...[
                  InvestmentSection(
                    title: l.investOpeningOptionTitle,
                    children: [
                      _field('quantity', l.optionContracts, number: true),
                      _field('cost', l.investOpeningCost, number: true),
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
                      _field('margin', l.optionMargin, number: true),
                      Text(l.optionMarginHint),
                      _field('reference', l.investReference, number: true),
                      _field(
                        'underlyingPrice',
                        l.optionUnderlyingReference,
                        number: true,
                      ),
                    ],
                  ),
                ] else if (!widget.specificationOnly) ...[
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
                    onPressed: _busy ? null : _makePreview,
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
                if (widget.editorSession == null)
                  FilledButton(
                    onPressed:
                        _busy ||
                            (!_opening &&
                                !widget.specificationOnly &&
                                _draft == null)
                        ? null
                        : () => _saveAndExit(p),
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
