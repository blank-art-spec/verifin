/// 期权草稿与结算预览：只经 Controller 写入，联网行情不能填充真实成交或合约规格。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../app/app_theme.dart';
import '../app/calendar_days.dart';
import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_opening_draft.dart';
import '../app/investments/investment_validation_issue.dart';
import '../app/investments/market_quote.dart';
import '../app/investments/quote_format.dart';
import '../app/investments/investment_security_autocomplete.dart';
import '../app/investments/investment_security_suggestions.dart';
import '../app/investments/investment_widgets.dart';
import '../app/investments/us_option_symbol.dart';
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
  /// 包含实际事件及用户确认参考价；[underlyingPrice] 仅实物交割可提供，
  /// 普通开平仓不提交此值，避免无关股票估值被期权草稿覆盖。
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
  final _fieldErrors = <String, String>{};
  final _fieldAnchors = <String, GlobalKey>{};
  bool _detailsExpanded = false, _settlementExpanded = false;
  bool _extrasExpanded = false, _useTradePrice = false;
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
  bool _searchingUnderlying = false, _lookupVisible = true;
  int _underlyingSearchGeneration = 0, _underlyingOpenRequest = 0;
  List<StockSecurity> _onlineUnderlyings = const [];
  String? _underlyingSearchMessage, _underlyingSearchQuery;
  (String, String)? _observedUnderlyingInputs;
  bool _searchingContract = false, _fillingContract = false;
  bool _expiryEdited = false, _rightEdited = false;
  int _contractSearchGeneration = 0, _quoteRevision = 0;
  final _generatedFields = <String, String>{};
  DateTime? _generatedExpiry;
  OptionRight? _generatedRight;
  String? _adoptedQuotePrice, _contractLookupMessage;
  MarketQuoteRequest? _contractRequest;
  MarketQuote? _contractQuote;
  DraftOptionQuoteStatus? _contractQuoteStatus;
  _OptionDraft? _draft;
  InvestmentOpeningHolding? _openingResult;
  String? _previewInputSnapshot;
  ({InvestmentPortfolio portfolio, StockProjection projection, double cash})?
  _preview;

  bool get _opening => widget.openingPortfolio != null;

  /// 只有真实开平仓才可由用户选择以成交价暂估；期初和结算不生成虚构成交价。
  bool get _trading =>
      !_opening &&
      !widget.specificationOnly &&
      {
        StockEventKind.optionBuyOpen,
        StockEventKind.optionSellClose,
        StockEventKind.optionSellOpen,
        StockEventKind.optionBuyClose,
      }.contains(_kind);

  /// 返回本次明确选择的估值依据；勾选暂估时随成交价更新，取消后恢复原参考价草稿。
  String get _referencePrice => _trading && _useTradePrice
      ? _fields['price']!.text.trim()
      : _fields['reference']!.text.trim();

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
      _useTradePrice,
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
    final visible =
        Visibility.of(context) && (ModalRoute.of(context)?.isCurrent ?? true);
    if (_loaded) {
      if ((_lookupVisible && !visible) ||
          VeriFinScope.of(context).activeBook.id != _bookId) {
        _clearUnderlyingSearch();
        _clearContractLookup();
      }
      _lookupVisible = visible;
      return;
    }
    _lookupVisible = visible;
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
    if (e == null) {
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
    _observedUnderlyingInputs = (
      _fields['underlying']!.text,
      _fields['symbol']!.text,
    );
    _fields['underlying']!.addListener(_underlyingInputChanged);
    _fields['symbol']!.addListener(_underlyingInputChanged);
  }

  /// 载入明确选择的合约；不从 AVGO 行情页猜乘数、到期日或交割股数。
  void _loadContract(StockSecurity s, InvestmentPortfolio p) {
    _fieldErrors.clear();
    _clearUnderlyingSearch();
    _clearContractLookup();
    _adoptedQuotePrice = null;
    _useTradePrice = false;
    _generatedFields.clear();
    _generatedExpiry = null;
    _generatedRight = null;
    _expiryEdited = true;
    _rightEdited = true;
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
    _underlyingSearchGeneration++;
    _contractSearchGeneration++;
    _fields['underlying']?.removeListener(_underlyingInputChanged);
    _fields['symbol']?.removeListener(_underlyingInputChanged);
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
    String? hint,
  }) => InvestmentInputField(
    key: _anchor(key),
    label: label,
    child: TextField(
      key: ValueKey('option-$key'),
      controller: _fields[key],
      readOnly: locked || _busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: false)
          : TextInputType.text,
      onChanged: (_) => setState(() {
        if (key == 'strike') _clearContractLookup(identityChanged: true);
        if (key == 'reference') _adoptedQuotePrice = null;
        _fieldErrors.remove(key);
        if (key == 'symbol') _parseContractLocally();
        _invalidate();
      }),
      decoration: investmentInputDecoration(context).copyWith(
        // 用可自然换行的文字组件，避免默认省略号截断英文、大字号的修正说明。
        error: _fieldErrors[key] == null ? null : Text(_fieldErrors[key]!),
        helper: hint == null
            ? null
            : Text(
                hint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    ),
  );

  /// 为输入或选择器保存稳定定位点；[field] 与错误字段名一致，用于展开后滚动定位。
  GlobalKey _anchor(String field) =>
      _fieldAnchors.putIfAbsent(field, () => GlobalKey());

  /// 只在本地解析完整美股代码，复用既有身份填充规则；绝不自动联网或推断乘数。
  void _parseContractLocally() {
    if (_market != StockMarket.us || _portfolio?.currencyCode != 'USD') return;
    try {
      final request = MarketQuoteRequest.usOptionSymbol(
        _fields['symbol']!.text,
      );
      _fillContractIdentity(request);
    } on FormatException {
      // 输入尚未完成或属于其他合约格式时保留手填入口，不把半串代码当作错误打断输入。
    }
  }

  /// 以整行分组标题提供展开入口；[id] 保留字段定位和测试使用的稳定键。
  /// [label] 是短标题，[description] 解释收起的内容或显示当前合约摘要；长文字自然换行。
  /// [expanded] 同时控制状态文字、箭头及读屏语义；[onTap] 只切换展示，不修改草稿。
  /// 必填组传入空 [onTap]，只显示静态标题，避免内容始终可见却仍显示“收起”。
  /// [separated] 在卡片内子分组上方增加细分隔线，作为整张卡片标题时关闭。
  Widget _detailsToggle(
    String id,
    String label,
    bool expanded,
    VoidCallback? onTap, {
    required String description,
    bool separated = true,
  }) {
    final theme = Theme.of(context), l = AppLocalizations.of(context);
    final toggleable = onTap != null;
    final action = _busy ? null : onTap;
    // 展开状态属于辅助操作，沿用次级文字色，避免与查询、保存等主操作争抢注意力。
    final actionColor = _busy
        ? theme.disabledColor
        : theme.colorScheme.onSurfaceVariant;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: separated ? 12 : 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            if (toggleable) ...[
              const SizedBox(width: 12),
              Text(
                expanded ? l.optionCollapse : l.optionExpand,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: actionColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: actionColor,
              ),
            ],
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (separated) const Divider(height: 1),
        Semantics(
          key: ValueKey('option-$id-toggle'),
          container: true,
          label: label,
          value: description,
          button: toggleable ? true : null,
          expanded: toggleable ? expanded : null,
          enabled: toggleable ? !_busy : null,
          onTap: action,
          excludeSemantics: true,
          child: toggleable
              ? InkWell(
                  onTap: action,
                  excludeFromSemantics: true,
                  borderRadius: BorderRadius.circular(veriRadiusSm),
                  child: content,
                )
              : content,
        ),
      ],
    );
  }

  /// 选择器和复选框也有明确错误位置，不能只在页尾汇总后让用户猜测。
  Widget _choiceError(String field) => _fieldErrors[field] == null
      ? const SizedBox.shrink()
      : Text(
          _fieldErrors[field]!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );

  /// 展示当前参考价及显式暂估选择；[p] 提供币种，不改变原报价草稿或开启联网。
  Widget _referenceControls(InvestmentPortfolio p) {
    final l = AppLocalizations.of(context);
    String? formattedReference;
    try {
      if (_referencePrice.isNotEmpty) {
        formattedReference = formatUserSecurityPrice(
          _referencePrice,
          p.currencyCode,
        );
      }
    } on FormatException {
      // 草稿中的半输入或非法文本由字段校验解释，不将它当作有效金额展示。
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_trading)
          CheckboxListTile(
            key: const Key('option-use-trade-price'),
            contentPadding: EdgeInsets.zero,
            value: _useTradePrice,
            title: Text(l.optionUseTradePrice),
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _useTradePrice = value ?? false;
                    _fieldErrors.remove('reference');
                    _invalidate();
                  }),
          ),
        if (formattedReference != null)
          Text(l.optionReferenceSummary(formattedReference)),
        if (!(_trading && _useTradePrice) && _referencePrice.isEmpty)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() => _extrasExpanded = true),
            child: Text(l.optionEnterReference),
          ),
      ],
    );
  }

  /// 实时列出“张数 × 成交价 × 乘数”的权利金总额，帮助用户在预览前发现单位误填。
  /// [p] 仅提供现金精度；输入尚不完整时不显示伪造的零金额，也不阻断合法小数乘数。
  Widget _premiumAmount(InvestmentPortfolio p) {
    final l = AppLocalizations.of(context);
    try {
      final quantity = InvestmentDecimal.parse(_fields['quantity']!.text);
      final price = InvestmentDecimal.parse(_fields['price']!.text);
      final multiplier = InvestmentDecimal.parse(_fields['multiplier']!.text);
      if (quantity.units <= BigInt.zero ||
          price.units <= BigInt.zero ||
          multiplier.units <= BigInt.zero) {
        return const SizedBox.shrink();
      }
      final total = securityPositionValue(
        _readSecurities(p).security,
        quantity,
        price,
        CurrencyCatalog.require(p.currencyCode).minorUnit,
      );
      return InvestmentHint(
        l.optionPremiumCalculation(
          quantity.toString(),
          price.toString(),
          multiplier.toString(),
          formatUserMoney(total.toDouble(), p.currencyCode),
        ),
      );
    } on FormatException {
      // 半输入或超界数值交给逐字段校验，不在每次键入时展示失败状态。
      return const SizedBox.shrink();
    }
  }

  /// 展开含错误的区块，并在布局完成后定位第一个错误；输入仍保留在原草稿中。
  void _showErrors(Map<String, String> errors) {
    setState(() {
      _invalidate();
      _fieldErrors
        ..clear()
        ..addAll(errors);
      if (errors.keys.any(
        {
          'name',
          'underlying',
          'underlyingName',
          'strike',
          'expiry',
          'right',
        }.contains,
      )) {
        _detailsExpanded = true;
      }
      if (errors.keys.any(
        {
          'settlement',
          'shares',
          'exercise',
          'source',
          'specConfirmed',
        }.contains,
      )) {
        _settlementExpanded = true;
      }
      if (errors.keys.any({'reference', 'margin', 'note'}.contains)) {
        _extrasExpanded = true;
      }
      _error = AppLocalizations.of(context).optionFixFields;
    });
    FocusScope.of(context).unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || errors.isEmpty) return;
      final target = _fieldAnchors[errors.keys.first]?.currentContext;
      if (target != null) {
        // 不创建滚动动画或后台任务，定位完成后保留用户当前的输入焦点选择。
        // 零时长定位同步完成，无需等待动画；Future 仅表示框架已完成定位。
        unawaited(Scrollable.ensureVisible(target, alignment: 0.15));
      }
    });
  }

  /// 先校验表单可修正的事实；[p] 提供期初边界与币种精度，领域重放仍是最终门禁。
  /// 同时收集各字段问题，避免用户每次只修一个错误后又遇到同一句失败提示。
  bool _validateFields(InvestmentPortfolio p) {
    final l = AppLocalizations.of(context);
    final errors = <String, String>{};
    for (final entry in {
      'symbol': l.optionCode,
      'name': l.investName,
      'underlying': l.optionUnderlying,
      'underlyingName': l.optionUnderlyingName,
    }.entries) {
      if (_fields[entry.key]!.text.trim().isEmpty) {
        errors[entry.key] = l.optionRequiredField(entry.value);
      }
    }

    /// 按 [field] 校验当前文本；[positive] 要求大于零，[integer] 要求整数张数，
    /// [optional] 允许留空，[cashPrecision] 限制为账户币种的现金小数位数。
    /// 小数乘数是合法规格，不能把“与成交价相同”或“不是 100”直接判为错误。
    void number(
      String field, {
      bool positive = false,
      bool integer = false,
      bool optional = false,
      bool cashPrecision = false,
    }) {
      final raw = field == 'reference'
          ? _referencePrice
          : _fields[field]!.text.trim();
      if (optional && raw.isEmpty) return;
      try {
        final value = InvestmentDecimal.parse(raw);
        value.toDouble();
        if (value.units < BigInt.zero ||
            (positive && value.units == BigInt.zero) ||
            (integer && value.units % InvestmentDecimal.scale != BigInt.zero)) {
          throw const FormatException('字段数值不符合约束');
        }
        // 费用、保证金和现金交割总额是真实现金，必须符合账户币种最小单位。
        // 价格、乘数及交割规格可保留更高精度，不能统一强制保留两位小数。
        final digits = CurrencyCatalog.require(p.currencyCode).minorUnit;
        if (cashPrecision && value.compareTo(value.rounded(digits)) != 0) {
          errors[field] = l.optionCashPrecisionError(digits);
        }
      } on FormatException {
        errors[field] = integer
            ? l.optionQuantityError
            : field == 'multiplier'
            ? l.optionMultiplierError
            : positive
            ? l.optionPositiveNumberError
            : l.optionNonNegativeNumberError;
      }
    }

    number('strike', positive: true);
    number('multiplier', positive: true);
    if (_market == StockMarket.us && p.currencyCode == 'USD') {
      try {
        final request = MarketQuoteRequest.usOptionSymbol(
          _fields['symbol']!.text,
        );
        // 本地补全保留用户手工修改，保存时再逐项指出冲突，避免折叠后静默混用两个合约。
        if (_fields['underlying']!.text.trim().toUpperCase() !=
            request.optionUnderlyingSymbol) {
          errors.putIfAbsent(
            'underlying',
            () => l.optionLookupIdentityConflict,
          );
        }
        if (_expiry.toIso8601String().substring(0, 10) !=
            request.optionExpiry) {
          errors['expiry'] = l.optionLookupIdentityConflict;
        }
        if (_right != request.optionRight) {
          errors['right'] = l.optionLookupIdentityConflict;
        }
        if (!errors.containsKey('strike') &&
            InvestmentDecimal.parse(
                  _fields['strike']!.text,
                ).compareTo(InvestmentDecimal.parse(request.optionStrike!)) !=
                0) {
          errors['strike'] = l.optionLookupIdentityConflict;
        }
      } on FormatException {
        // 非标准或 TEST 示例没有可解析的标准身份，仍按原手填资料核对，不强制套用美股格式。
      }
    }
    final settlement =
        !widget.specificationOnly &&
        !_opening &&
        {
          StockEventKind.optionPhysicalSettle,
          StockEventKind.optionCashSettle,
        }.contains(_kind);
    if (settlement &&
        (!_specConfirmed || _settlement == OptionSettlement.unsupported)) {
      errors['specConfirmed'] = l.optionSpecificationRequiredError;
    }
    final confirmedPhysical =
        _specConfirmed && _settlement == OptionSettlement.physical;
    // 未确认时允许暂缺规格；已经填入的内容仍须是合法非负数，否则领域保存也会拒绝。
    number('shares', positive: confirmedPhysical, optional: !confirmedPhysical);
    number(
      'exercise',
      positive: confirmedPhysical,
      optional: !confirmedPhysical,
    );
    if (_specConfirmed) {
      if (_fields['source']!.text.trim().isEmpty) {
        errors['source'] = l.optionSourceRequiredError;
      }
    }
    if (!widget.specificationOnly) {
      if (_opening || _kind != StockEventKind.optionMargin) {
        number('quantity', positive: true, integer: true);
      }
      if (_opening) {
        number('cost', optional: true);
      } else {
        if (_trading || _kind == StockEventKind.optionCashSettle) {
          number(
            'price',
            positive: _trading,
            cashPrecision: _kind == StockEventKind.optionCashSettle,
          );
        }
        if (_kind != StockEventKind.optionMargin) {
          number('fee', cashPrecision: true);
        }
        if (_date.isBefore(p.openedAt)) {
          errors['date'] = l.optionBeforeOpeningError(
            MaterialLocalizations.of(context).formatCompactDate(p.openedAt),
            MaterialLocalizations.of(
              context,
            ).formatTimeOfDay(TimeOfDay.fromDateTime(p.openedAt)),
          );
        }
        if (_trading &&
            optionExpired(_readSecurities(p).security.option!, _date)) {
          errors['date'] = l.optionExpiredContractError;
        }
        if (settlement || _kind == StockEventKind.optionExpire) {
          if (!_confirmed) {
            errors['confirmed'] = l.optionSettlementConfirmationError;
          }
        }
      }
      number(
        'margin',
        optional: _opening || _kind != StockEventKind.optionMargin,
        cashPrecision: true,
      );
      number('reference');
      if (errors.containsKey('reference') && _referencePrice.isEmpty) {
        errors['reference'] = _trading
            ? l.optionReferenceRequiredError
            : l.optionOpeningReferenceRequiredError;
      }
      if (_kind == StockEventKind.optionPhysicalSettle && !_opening) {
        number('underlyingPrice', optional: true);
      }
    }
    if (errors.isNotEmpty) {
      _showErrors(errors);
      return false;
    }
    setState(_fieldErrors.clear);
    return true;
  }

  /// 手填标的优先；完整 OCC 合约代码只能辅助提取标的，不能自动填写其他合约条款。
  String get _underlyingQuery {
    final typed = _fields['underlying']!.text.trim();
    if (_market != StockMarket.us) return typed;
    final symbol = typed.isEmpty ? _fields['symbol']!.text.trim() : typed;
    return parseUsOptionSymbol(symbol.toUpperCase())?.underlyingSymbol ?? typed;
  }

  /// 请求修订只保留当前草稿身份，不含数量、成本、价格或私有备注。
  String get _underlyingLookupContext => jsonEncode([
    _bookId,
    widget.accountId,
    _market.name,
    _selected,
    _fields['underlying']!.text,
    _fields['symbol']!.text,
  ]);

  /// 清理仅属于本页的候选；任何代码、市场或既有合约变动都使旧响应失效。
  void _clearUnderlyingSearch() {
    _underlyingSearchGeneration++;
    _searchingUnderlying = false;
    _onlineUnderlyings = const [];
    _underlyingSearchMessage = null;
    _underlyingSearchQuery = null;
  }

  /// 自动补全使用同一文本控制器，输入和候选点选都要撤销旧预览；不自动联网。
  void _underlyingInputChanged() {
    if (!mounted) return;
    final inputs = (_fields['underlying']!.text, _fields['symbol']!.text);
    // 光标、选区或焦点变化不能清空刚收到的身份候选；仅真实输入变化才撤销查询。
    if (inputs == _observedUnderlyingInputs) return;
    _observedUnderlyingInputs = inputs;
    setState(() {
      _clearUnderlyingSearch();
      if (!_fillingContract) {
        _clearContractLookup(identityChanged: true, clearGeneratedFields: true);
      }
      _invalidate();
    });
  }

  /// 查询结果只属于当前草稿；改变合约身份后不沿用上个合约采用的报价。
  void _clearContractLookup({
    bool identityChanged = false,
    bool clearGeneratedFields = false,
  }) {
    _contractSearchGeneration++;
    _searchingContract = false;
    _contractRequest = null;
    _contractQuote = null;
    _contractQuoteStatus = null;
    _contractLookupMessage = null;
    if (identityChanged &&
        _adoptedQuotePrice != null &&
        _fields['reference']?.text == _adoptedQuotePrice) {
      _fields['reference']!.clear();
    }
    if (clearGeneratedFields) {
      _fillingContract = true;
      try {
        for (final entry in _generatedFields.entries) {
          if (_fields[entry.key]!.text == entry.value) {
            _fields[entry.key]!.clear();
          }
        }
        _generatedFields.clear();
      } finally {
        _fillingContract = false;
      }
    }
    if (identityChanged) _adoptedQuotePrice = null;
  }

  /// 只填写空白或本页生成后未改的字段，用户手填名称和身份始终优先。
  void _fillContractField(String field, String value) {
    final controller = _fields[field]!;
    if (controller.text.trim().isEmpty ||
        controller.text == _generatedFields[field]) {
      controller.text = value;
      _generatedFields[field] = value;
      _fieldErrors.remove(field);
    }
  }

  /// 名称是可编辑的本地显示文本；公开代码解析不代表已核对交割规格。
  String _contractName(MarketQuoteRequest request, String underlyingName) {
    final l = AppLocalizations.of(context);
    return l.optionLookupName(
      underlyingName,
      MaterialLocalizations.of(
        context,
      ).formatCompactDate(DateTime.parse(request.optionExpiry!)),
      request.optionStrike!,
      request.optionRight!.label(l),
    );
  }

  /// 从完整代码补齐可解析身份，不猜乘数、交割方式、股数、现金或确认状态。
  void _fillContractIdentity(MarketQuoteRequest request) {
    if (!_opening && _selected != null) return;
    _fillingContract = true;
    try {
      _fields['symbol']!.text = request.symbol;
      _fillContractField('underlying', request.optionUnderlyingSymbol!);
      _fillContractField('strike', request.optionStrike!);
      if (!_expiryEdited || _expiry == _generatedExpiry) {
        _expiry = DateTime.parse(request.optionExpiry!);
        _generatedExpiry = _expiry;
      }
      if (!_rightEdited || _right == _generatedRight) {
        _right = request.optionRight!;
        _generatedRight = _right;
      }
      final matches =
          _fields['underlying']!.text.trim().toUpperCase() ==
          request.optionUnderlyingSymbol;
      if (matches) {
        _fillContractField('underlyingName', request.optionUnderlyingSymbol!);
      }
      final name = matches ? _fields['underlyingName']!.text.trim() : '';
      _fillContractField(
        'name',
        _contractName(
          request,
          name.isEmpty ? request.optionUnderlyingSymbol! : name,
        ),
      );
      _invalidate();
    } finally {
      _fillingContract = false;
    }
  }

  /// 采用报价前核对实际草稿身份，不能把另一个日期或行权价的价格填进来。
  bool _matchesContractRequest(MarketQuoteRequest request) {
    try {
      return _market == request.market &&
          _fields['symbol']!.text.trim().toUpperCase() == request.symbol &&
          _fields['underlying']!.text.trim().toUpperCase() ==
              request.optionUnderlyingSymbol &&
          _expiry.toIso8601String().substring(0, 10) == request.optionExpiry &&
          _right == request.optionRight &&
          InvestmentDecimal.parse(
                _fields['strike']!.text,
              ).compareTo(InvestmentDecimal.parse(request.optionStrike!)) ==
              0;
    } on FormatException {
      // 尚未补全或与代码不一致时显示核对提示，不采用其他身份的报价。
      return false;
    }
  }

  /// 显式单次查询名称和参考报价，只有公开身份会传给来源；乘数始终由用户核对填写。
  Future<void> _lookupContract() async {
    final c = VeriFinScope.of(context), p = _portfolio;
    if (_busy ||
        _submitted ||
        _searchingContract ||
        p == null ||
        !_hasValidAccount(p)) {
      return;
    }
    final l = AppLocalizations.of(context);
    MarketQuoteRequest request;
    try {
      if (_market != StockMarket.us || p.currencyCode != 'USD') {
        throw const FormatException('unsupported');
      }
      request = MarketQuoteRequest.usOptionSymbol(_fields['symbol']!.text);
    } on FormatException {
      setState(() {
        _clearContractLookup();
        _contractLookupMessage = l.optionLookupUnsupported;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _clearContractLookup();
      _fillContractIdentity(request);
      _contractRequest = request;
      _searchingContract = true;
    });
    final generation = _contractSearchGeneration;
    final snapshot = _underlyingLookupContext;
    bool current() =>
        mounted &&
        generation == _contractSearchGeneration &&
        snapshot == _underlyingLookupContext &&
        !_busy &&
        !_submitted &&
        _hasValidAccount(p) &&
        Visibility.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    Future<void> lookupName() async {
      try {
        final securities = await c.searchInvestmentSecurities(
          request.optionUnderlyingSymbol!,
          market: request.market,
          currencyCode: request.currency,
        );
        if (!current()) return;
        final stock = securities
            .where(
              (s) =>
                  s.isStock &&
                  s.symbol.toUpperCase() == request.optionUnderlyingSymbol &&
                  s.market == request.market &&
                  s.currencyCode == request.currency,
            )
            .firstOrNull;
        if (stock == null) {
          setState(() => _contractLookupMessage = l.optionLookupNameFallback);
          return;
        }
        setState(() {
          if (_fields['underlying']!.text.trim().toUpperCase() ==
              stock.symbol.toUpperCase()) {
            _fillContractField('underlyingName', stock.name);
          }
          _fillContractField('name', _contractName(request, stock.name));
          _invalidate();
        });
      } catch (_) {
        // Controller 已脱敏记录错误；可用代码生成名称，价格查询仍独立继续。
        if (current()) {
          setState(() => _contractLookupMessage = l.optionLookupNameFallback);
        }
      }
    }

    Future<void> lookupQuote() async {
      final result = await c.fetchDraftOptionQuote(request);
      if (!current()) return;
      setState(() {
        _contractQuoteStatus = result.status;
        _contractQuote = result.quote;
        _quoteRevision = c.investmentQuoteSync.draftQuoteRevision;
      });
    }

    await Future.wait([lookupName(), lookupQuote()]);
    if (current()) setState(() => _searchingContract = false);
  }

  /// 权利金乘数只接受用户核对后的输入，已有合约保持锁定。
  Widget _multiplierField({required bool locked}) => _field(
    'multiplier',
    AppLocalizations.of(context).optionMultiplier,
    number: true,
    locked: locked,
    hint: AppLocalizations.of(context).optionMultiplierHelp,
  );

  /// 最新报价仅在用户点选后写入参考价草稿，不触碰成交、成本、数量或账户。
  void _useContractQuote() {
    final request = _contractRequest, quote = _contractQuote;
    if (_busy || _submitted || request == null || quote == null) return;
    final sync = VeriFinScope.of(context).investmentQuoteSync;
    if (_quoteRevision != sync.draftQuoteRevision ||
        !sync.state.value.enabled ||
        !_matchesContractRequest(request)) {
      setState(() {
        _clearContractLookup();
        _contractLookupMessage = AppLocalizations.of(context).optionLookupRetry;
      });
      return;
    }
    final reference = quote.reference(request, sync.clock());
    if (reference == null) return;
    setState(() {
      _fields['reference']!.text = reference.price;
      _useTradePrice = false;
      _adoptedQuotePrice = reference.price;
      _invalidate();
    });
  }

  /// 独立启用既有参考行情偏好，不开启自动刷新；成功后重查当前草稿。
  Future<void> _enableContractQuotes() async {
    final sync = VeriFinScope.of(context).investmentQuoteSync;
    final ok = await sync.configure(
      enabled: true,
      automatic: sync.state.value.automatic,
    );
    if (!mounted) return;
    if (ok) {
      await _lookupContract();
    } else {
      setState(
        () => _contractLookupMessage = AppLocalizations.of(
          context,
        ).marketSaveFailed,
      );
    }
  }

  /// 来源时间未知时明确展示未知，抓取时刻单列；仅显示来源明确提供的延迟。
  /// 保留历史期初提醒，不将可用报价称为实时成交，也不改动用户成本。
  Widget _contractLookup(InvestmentPortfolio p) {
    final l = AppLocalizations.of(context),
        sync = VeriFinScope.of(context).investmentQuoteSync,
        request = _contractRequest,
        quote = _contractQuote;
    final reference = request == null || quote == null
        ? null
        : quote.reference(request, sync.clock());
    final statusMessage = switch (_contractQuoteStatus) {
      DraftOptionQuoteStatus.networkDisabled => l.optionLookupNetworkDisabled,
      DraftOptionQuoteStatus.unsupported => l.optionLookupUnavailable,
      DraftOptionQuoteStatus.noQuote => l.optionLookupNoQuote,
      DraftOptionQuoteStatus.failed => l.optionLookupFailed,
      DraftOptionQuoteStatus.cancelled => l.optionLookupRetry,
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          key: const Key('option-contract-search'),
          style: investmentOutlineButtonStyle(context),
          onPressed:
              _busy ||
                  _submitted ||
                  _searchingContract ||
                  _fields['symbol']!.text.trim().isEmpty
              ? null
              : _lookupContract,
          icon: const Icon(Icons.search),
          label: Text(_searchingContract ? l.commonProcessing : l.optionLookup),
        ),
        InvestmentHint(l.optionLookupCompactHint),
        if (_contractLookupMessage != null)
          InvestmentHint(_contractLookupMessage!),
        if (statusMessage != null) InvestmentHint(statusMessage),
        if (_contractQuoteStatus == DraftOptionQuoteStatus.networkDisabled)
          TextButton(
            onPressed: _busy || _searchingContract
                ? null
                : _enableContractQuotes,
            child: Text(l.optionLookupEnable),
          ),
        if (reference != null && request != null && quote != null) ...[
          const SizedBox(height: 8),
          Text(request.symbol),
          DetailInfoRow(
            inline: true,
            label: reference.midpoint
                ? l.optionLookupMidpoint
                : l.optionLookupLast,
            value: formatUserSecurityPrice(reference.price, p.currencyCode),
          ),
          Text(quote.source),
          DetailInfoRow(
            inline: true,
            label: l.marketQuoteTime,
            value: reference.time == null
                ? l.marketQuoteTimeUnknown
                : formatQuoteTime(
                    context,
                    reference.time!,
                    compact: true,
                    includeSeconds: true,
                  ),
          ),
          DetailInfoRow(
            inline: true,
            label: l.investFetchedAt,
            value: formatQuoteTime(
              context,
              quote.fetchedAt,
              compact: true,
              includeSeconds: true,
            ),
          ),
          if (quote.delayMinutes != null && quote.delayMinutes! > 0)
            InvestmentHint(l.optionLookupDelayHint(quote.delayMinutes!)),
          if (quote.isOlderThanOneDay(request, sync.clock()))
            InvestmentHint(l.marketQuoteOlderThanOneDay),
          if (_opening) InvestmentHint(l.optionLookupOpeningHint),
          if (!_matchesContractRequest(request))
            InvestmentHint(l.optionLookupIdentityConflict),
          OutlinedButton(
            key: const Key('option-contract-use-price'),
            style: investmentOutlineButtonStyle(context),
            onPressed: _busy || _submitted || !_matchesContractRequest(request)
                ? null
                : _useContractQuote,
            child: Text(l.optionLookupUsePrice),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  /// 复用股票身份候选，当前账户、本账本同币种以及本次远端结果都只用于填代码/名称。
  Widget _underlyingField(
    InvestmentPortfolio portfolio, {
    required bool locked,
  }) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final suggestions = collectInvestmentSecuritySuggestions(
      portfolios: [
        portfolio,
        ...c.accounts
            .where((account) => account.currencyCode == portfolio.currencyCode)
            .map((account) => c.investmentFor(account.id))
            .whereType<InvestmentPortfolio>(),
      ],
      bookId: _bookId,
      accountId: widget.accountId,
      currencyCode: portfolio.currencyCode,
      market: _market,
      type: InvestmentSecurityType.stock,
      remoteSecurities: _onlineUnderlyings,
      remoteQuery: _underlyingSearchQuery,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InvestmentSecurityAutocomplete(
          key: _anchor('underlying'),
          controller: _fields['underlying']!,
          fieldKey: const ValueKey('option-underlying'),
          label: l.optionUnderlying,
          suggestions: suggestions,
          readOnly: locked || _busy || _submitted,
          openRequest: _underlyingOpenRequest,
          onSelected: (suggestion) => setState(() {
            _fields['underlyingName']!.text = suggestion.security.name;
            // 即使候选来自当前账户，也不复制参考价、成本或任何期权条款。
            _clearUnderlyingSearch();
            _invalidate();
          }),
        ),
        _choiceError('underlying'),
        if (!locked) ...[
          OutlinedButton.icon(
            key: const Key('option-underlying-search-online'),
            style: investmentOutlineButtonStyle(context),
            onPressed:
                _busy ||
                    _submitted ||
                    _searchingUnderlying ||
                    _underlyingQuery.isEmpty
                ? null
                : _searchUnderlying,
            icon: const Icon(Icons.search),
            label: Text(
              _searchingUnderlying ? l.commonProcessing : l.investSearchOnline,
            ),
          ),
          const SizedBox(height: 6),
          InvestmentHint(l.investSearchOnlineConsent),
          if (_underlyingSearchMessage != null) ...[
            const SizedBox(height: 8),
            InvestmentHint(_underlyingSearchMessage!),
          ],
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// 点击才发送公开标的代码或名称；OCC 输入只提取标的，候选必须由用户明确选择。
  Future<void> _searchUnderlying() async {
    final c = VeriFinScope.of(context), portfolio = _portfolio;
    final query = _underlyingQuery;
    if (_busy ||
        _submitted ||
        _searchingUnderlying ||
        portfolio == null ||
        (!_opening && _selected != null) ||
        !_hasValidAccount(portfolio) ||
        query.isEmpty) {
      return;
    }
    // 明确点击查询时展示实际要查询的标的代码，保留合约代码及用户的所有条款输入。
    if (_fields['underlying']!.text.trim() != query) {
      _fields['underlying']!.text = query;
    }
    final generation = ++_underlyingSearchGeneration;
    final snapshot = _underlyingLookupContext;
    setState(() {
      _searchingUnderlying = true;
      _onlineUnderlyings = const [];
      _underlyingSearchMessage = null;
      _underlyingSearchQuery = null;
    });
    bool current() =>
        mounted &&
        generation == _underlyingSearchGeneration &&
        snapshot == _underlyingLookupContext &&
        !_busy &&
        !_submitted &&
        _hasValidAccount(portfolio) &&
        Visibility.of(context) &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    void discard() {
      if (mounted && generation == _underlyingSearchGeneration) {
        setState(_clearUnderlyingSearch);
      }
    }

    try {
      final securities = await c.searchInvestmentSecurities(
        query,
        market: _market,
        currencyCode: portfolio.currencyCode,
      );
      if (!current()) {
        discard();
        return;
      }
      final eligible = securities
          .where(
            (security) =>
                security.isStock &&
                security.market == _market &&
                security.currencyCode == portfolio.currencyCode,
          )
          .toList();
      setState(() {
        _searchingUnderlying = false;
        _onlineUnderlyings = eligible;
        _underlyingSearchQuery = query;
        if (eligible.isNotEmpty) _underlyingOpenRequest++;
        _underlyingSearchMessage = eligible.isEmpty
            ? AppLocalizations.of(context).investSearchNoResults
            : null;
      });
    } catch (_) {
      // Controller 已记录脱敏错误类型；仅反馈查询失败，保留手填草稿。
      if (!current()) {
        discard();
        return;
      }
      setState(() {
        _searchingUnderlying = false;
        _underlyingSearchMessage = AppLocalizations.of(
          context,
        ).investSearchOnlineFailed;
      });
    }
  }

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
      _referencePrice,
      _kind != StockEventKind.optionPhysicalSettle ||
              text('underlyingPrice').isEmpty
          ? null
          : text('underlyingPrice'),
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
        _error = AppLocalizations.of(context).optionAccountUnavailableError;
      });
      return;
    }
    if (!_validateFields(p)) return;
    _sequence = nextSequence;
    final d = _readDraft(p);
    final result = c.previewOptionEventResult(
      accountId: widget.accountId,
      security: d.security,
      underlying: d.underlying,
      event: d.event,
      referencePrice: d.price,
      underlyingReferencePrice: d.underlyingPrice,
    );
    final preview = result.preview;
    if (preview == null) {
      _showDomainIssue(
        result.issue ?? InvestmentValidationIssue.invalidInput,
        p,
      );
      return;
    }
    setState(() {
      _preview = preview;
      _draft = d;
      _previewInputSnapshot = _previewSnapshot(p);
      _error = null;
    });
  }

  /// 将稳定领域原因映射到用户能操作的字段或说明；不展示异常原文和内部事件标识。
  /// [p] 仅用于显示真实期初边界；现金/后续记录冲突不伪装成某个输入框缺失。
  void _showDomainIssue(
    InvestmentValidationIssue issue,
    InvestmentPortfolio p,
  ) {
    final l = AppLocalizations.of(context);
    final message = switch (issue) {
      InvestmentValidationIssue.accountUnavailable =>
        l.optionAccountUnavailableError,
      InvestmentValidationIssue.beforeOpening => l.optionBeforeOpeningError(
        MaterialLocalizations.of(context).formatCompactDate(p.openedAt),
        MaterialLocalizations.of(
          context,
        ).formatTimeOfDay(TimeOfDay.fromDateTime(p.openedAt)),
      ),
      InvestmentValidationIssue.insufficientCash =>
        l.optionCashInsufficientError,
      InvestmentValidationIssue.positionExceeded =>
        l.optionPositionExceededError,
      InvestmentValidationIssue.expiredContract => l.optionExpiredContractError,
      InvestmentValidationIssue.beforeExpiry => l.optionBeforeExpiryError,
      InvestmentValidationIssue.specificationRequired =>
        l.optionSpecificationRequiredError,
      InvestmentValidationIssue.settlementConfirmationRequired =>
        l.optionSettlementConfirmationError,
      InvestmentValidationIssue.unknownCost => l.optionUnknownCostError,
      InvestmentValidationIssue.underlyingSharesInsufficient =>
        l.optionUnderlyingSharesError,
      InvestmentValidationIssue.uncoveredAssignmentNotConfirmed =>
        l.optionUncoveredError,
      InvestmentValidationIssue.contractIdentityLocked =>
        l.optionIdentityLockedError,
      InvestmentValidationIssue.adjustedContract =>
        l.optionAdjustedContractError,
      InvestmentValidationIssue.feesExceedPremium => l.optionFeesExceedError,
      InvestmentValidationIssue.subsequentEventConflict =>
        l.optionSubsequentEventError,
      InvestmentValidationIssue.invalidInput => l.optionOtherValidationError,
    };
    final field = switch (issue) {
      InvestmentValidationIssue.beforeOpening ||
      InvestmentValidationIssue.expiredContract ||
      InvestmentValidationIssue.beforeExpiry => 'date',
      InvestmentValidationIssue.positionExceeded => 'quantity',
      InvestmentValidationIssue.specificationRequired => 'specConfirmed',
      InvestmentValidationIssue.settlementConfirmationRequired => 'confirmed',
      InvestmentValidationIssue.uncoveredAssignmentNotConfirmed => 'uncovered',
      InvestmentValidationIssue.feesExceedPremium => 'fee',
      _ => null,
    };
    if (field != null) {
      _showErrors({field: message});
    } else {
      setState(() {
        _invalidate();
        _error = message;
      });
    }
  }

  /// 提交已预览的冻结事实；保存失败不退页，不宣称已落账。
  Future<bool> _save(InvestmentPortfolio p) async {
    if (_busy || _submitted) return false;
    if (!_validateFields(p)) return false;
    _clearUnderlyingSearch();
    _clearContractLookup();
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (_opening) {
      if (!_hasValidAccount(p)) {
        setState(() => _error = l.optionAccountUnavailableError);
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
      } on InvestmentValidationException catch (error) {
        _showDomainIssue(error.issue, p);
        return false;
      } on FormatException {
        setState(() => _error = l.optionOtherValidationError);
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
      setState(() => _error = l.optionAccountUnavailableError);
      return false;
    }
    if (!widget.specificationOnly &&
        _previewInputSnapshot != _previewSnapshot(current)) {
      setState(() {
        _invalidate();
        _error = l.optionPreviewStaleError;
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
        _error = l.optionSaveFailedError;
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
      _error = l.optionPreviewStaleError;
    }
    final existing = p.securities.where((s) => s.option != null).toList();
    final settles = {
      StockEventKind.optionExpire,
      StockEventKind.optionCashSettle,
      StockEventKind.optionPhysicalSettle,
    }.contains(_kind);
    final requiresSpecification =
        !_opening &&
        {
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                    final selected =
                                        await showOptionSheet<String>(
                                          context: context,
                                          title: l.optionSelect,
                                          values: existing
                                              .map((s) => s.id)
                                              .toList(),
                                          selected:
                                              _selected ?? existing.first.id,
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
                        _field('symbol', l.optionCode, locked: locked),
                        if (!widget.specificationOnly) _contractLookup(p),
                        _detailsToggle(
                          'details',
                          l.optionContractDetails,
                          _detailsExpanded || widget.specificationOnly,
                          widget.specificationOnly
                              ? null
                              : () => setState(
                                  () => _detailsExpanded = !_detailsExpanded,
                                ),
                          description:
                              !_detailsExpanded &&
                                  _fields['name']!.text.trim().isNotEmpty
                              ? _fields['name']!.text.trim()
                              : l.optionContractDetailsHint,
                        ),
                        if (_detailsExpanded || widget.specificationOnly) ...[
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
                                _clearUnderlyingSearch();
                                _clearContractLookup(
                                  identityChanged: true,
                                  clearGeneratedFields: true,
                                );
                                _invalidate();
                              }),
                            ),
                          _field('name', l.investName),
                          _underlyingField(p, locked: locked),
                          _field('underlyingName', l.optionUnderlyingName),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_detailsExpanded || widget.specificationOnly)
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
                              key: _anchor('right'),
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
                                _rightEdited = true;
                                _generatedRight = null;
                                _clearContractLookup(identityChanged: true);
                                _invalidate();
                              }),
                            )
                          else
                            Text(_right.label(l)),
                          _choiceError('right'),
                          ListTile(
                            key: _anchor('expiry'),
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
                                      _expiryEdited = true;
                                      _generatedExpiry = null;
                                      _clearContractLookup(
                                        identityChanged: true,
                                      );
                                      _invalidate();
                                    });
                                  },
                          ),
                          _choiceError('expiry'),
                          if (widget.specificationOnly)
                            _multiplierField(locked: locked),
                          _field(
                            'strike',
                            l.optionStrike,
                            number: true,
                            locked: locked,
                          ),
                        ],
                      ),
                    if (_detailsExpanded || widget.specificationOnly)
                      const SizedBox(height: 12),
                    InvestmentSection(
                      title: l.optionSettlementDetails,
                      header: _detailsToggle(
                        'settlement',
                        l.optionSettlementDetails,
                        _settlementExpanded ||
                            requiresSpecification ||
                            widget.specificationOnly,
                        requiresSpecification || widget.specificationOnly
                            ? null
                            : () => setState(
                                () =>
                                    _settlementExpanded = !_settlementExpanded,
                              ),
                        description: l.optionSettlementDetailsHint,
                        separated: false,
                      ),
                      children: [
                        if (_settlementExpanded ||
                            requiresSpecification ||
                            widget.specificationOnly) ...[
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
                          if (_settlement == OptionSettlement.physical ||
                              _fieldErrors.containsKey('shares') ||
                              _fieldErrors.containsKey('exercise')) ...[
                            _field(
                              'shares',
                              l.optionDeliverableShares,
                              number: true,
                            ),
                            _field(
                              'exercise',
                              l.optionExerciseCash,
                              number: true,
                            ),
                            Text(l.optionAdjustmentHint),
                          ],
                          _choiceError('settlement'),
                          _field('source', l.optionSpecification),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            key: _anchor('specConfirmed'),
                            value: _specConfirmed,
                            title: Text(l.optionSpecConfirmed),
                            onChanged: _busy
                                ? null
                                : (v) => setState(() {
                                    _specConfirmed = v ?? false;
                                    _fieldErrors.remove('specConfirmed');
                                    _invalidate();
                                  }),
                          ),
                          _choiceError('specConfirmed'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_opening) ...[
                      InvestmentSection(
                        title: l.investOpeningOptionTitle,
                        children: [
                          _multiplierField(locked: locked),
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
                          _field('reference', l.investReference, number: true),
                          _detailsToggle(
                            'extras',
                            l.optionMoreFields,
                            _extrasExpanded,
                            () => setState(
                              () => _extrasExpanded = !_extrasExpanded,
                            ),
                            description: l.optionOpeningMoreFieldsHint,
                          ),
                          if (_extrasExpanded) ...[
                            _field('margin', l.optionMargin, number: true),
                            InvestmentHint(l.optionMarginHint),
                          ],
                        ],
                      ),
                    ] else if (!widget.specificationOnly) ...[
                      InvestmentSection(
                        title: l.investTradeDetails,
                        children: [
                          _multiplierField(locked: locked),
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
                              key: _anchor('confirmed'),
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
                          _choiceError('confirmed'),
                          if (_kind == StockEventKind.optionPhysicalSettle)
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              key: _anchor('uncovered'),
                              value: _uncovered,
                              title: Text(l.optionUncoveredConsent),
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() {
                                      _uncovered = v ?? false;
                                      _invalidate();
                                    }),
                            ),
                          _choiceError('uncovered'),
                          if (_trading) _premiumAmount(p),
                          _referenceControls(p),
                          if (_kind == StockEventKind.optionPhysicalSettle)
                            _field(
                              'underlyingPrice',
                              l.optionUnderlyingReference,
                              number: true,
                            ),
                          ListTile(
                            key: _anchor('date'),
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
                                      _fieldErrors.remove('date');
                                      _invalidate();
                                    });
                                  },
                          ),
                          _choiceError('date'),
                          _detailsToggle(
                            'extras',
                            l.optionMoreFields,
                            _extrasExpanded ||
                                _kind == StockEventKind.optionMargin,
                            _kind == StockEventKind.optionMargin
                                ? null
                                : () => setState(
                                    () => _extrasExpanded = !_extrasExpanded,
                                  ),
                            description: l.optionMoreFieldsHint,
                          ),
                          if (_extrasExpanded ||
                              _kind == StockEventKind.optionMargin) ...[
                            if (!(_trading && _useTradePrice))
                              _field(
                                'reference',
                                l.investReference,
                                number: true,
                              ),
                            _field('margin', l.optionMarginAfter, number: true),
                            InvestmentHint(l.optionMarginHint),
                            _field('note', l.investNote),
                          ],
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
                            for (final holding
                                in _preview!.projection.positions)
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
