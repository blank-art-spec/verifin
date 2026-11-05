import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../app/common_widgets.dart';
import '../app/currency_catalog.dart';
import '../app/currency_math.dart';
import '../app/investments/investment_decimal.dart';
import '../app/investments/investment_widgets.dart';
import '../app/investments/stock_projection.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'entry_editor_session.dart';
import 'sheets.dart';

/// 更正已录入的股票/ETF 期初数量与每股成本，预览换算后的总额。
class StockOpeningCostPage extends StatefulWidget {
  /// [portfolio] 必须是 Controller 的原始聚合，用于保存时拒绝过期草稿。
  /// [holding] 为其中同证券、同方向的期初持仓；不接收当前剩余数量或期权仓位。
  const StockOpeningCostPage({
    super.key,
    required this.portfolio,
    required this.holding,
  });

  final InvestmentPortfolio portfolio;
  final StockHolding holding;

  /// 为此次编辑建立独立草稿，取消或返回均不自动改写期初事实。
  @override
  State<StockOpeningCostPage> createState() => _StockOpeningCostPageState();
}

class _StockOpeningCostPageState extends State<StockOpeningCostPage> {
  final _exitController = EditorExitController();
  late final TextEditingController _quantity, _unitCost;
  late final String _initialText;
  bool _saving = false;
  bool _saved = false;
  bool _unitCostEdited = false;
  String? _error;

  /// 以原总成本除以期初股数预填均价；未知成本仍为空，不伪造零成本。
  @override
  void initState() {
    super.initState();
    final originalCost = widget.holding.cost == null
        ? null
        : InvestmentDecimal.parse(widget.holding.cost!);
    final average = stockAverageUnitCost(
      originalCost,
      InvestmentDecimal.parse(widget.holding.quantity),
      cashDigits: CurrencyCatalog.require(
        widget.portfolio.currencyCode,
      ).minorUnit,
    );
    // 非零总成本的均价可能小于八位精度；留空待核对，使明确输入 0 仍能表达归零。
    _initialText =
        average == null ||
            (average.units == BigInt.zero && originalCost!.units != BigInt.zero)
        ? ''
        : average.toString();
    _unitCost = TextEditingController(text: _initialText);
    _quantity = TextEditingController(text: widget.holding.quantity);
  }

  /// 释放输入框资源；持久化只发生在用户明确保存时。
  @override
  void dispose() {
    _unitCost.dispose();
    _quantity.dispose();
    super.dispose();
  }

  /// 比较原始文本以驱动离页提醒；成功后不再把已提交内容当作未保存草稿。
  bool get _dirty =>
      !_saved &&
      (_unitCost.text.trim() != _initialText ||
          _quantity.text.trim() != widget.holding.quantity ||
          (_unitCostEdited &&
              _initialText.isEmpty &&
              widget.holding.cost != null));

  /// 仅修改了数字格式时保留原总成本，避免八位均价反乘后改变原始现金精度总额。
  /// [unitCost] 是已解析的非负输入，不将用于展示的均价当作权威成本替换依据。
  bool _keepsOriginalTotal(
    InvestmentDecimal quantity,
    InvestmentDecimal unitCost,
  ) =>
      widget.holding.cost != null &&
      _initialText.isNotEmpty &&
      quantity.compareTo(InvestmentDecimal.parse(widget.holding.quantity)) ==
          0 &&
      unitCost.compareTo(InvestmentDecimal.parse(_initialText)) == 0;

  /// 数量以八位定点解析；零数量应使用删除期初入口，不把更正偷偷变成删除。
  InvestmentDecimal _readQuantity() {
    final quantity = InvestmentDecimal.parse(_quantity.text);
    if (quantity.units <= BigInt.zero) {
      throw const FormatException('期初数量必须为正');
    }
    return quantity;
  }

  /// 校验每股成本并计算期初总成本；[unitCost] 不能为负，合法零成本允许保存。
  /// 按草稿股数相乘后只舍入一次；留空表示未知，非法/超范围输入显示本地化错误。
  InvestmentDecimal _totalCost(
    InvestmentDecimal quantity,
    InvestmentDecimal unitCost,
  ) {
    if (unitCost.units < BigInt.zero) {
      throw const FormatException('期初单位成本不能为负');
    }
    final total = _keepsOriginalTotal(quantity, unitCost)
        ? InvestmentDecimal.parse(widget.holding.cost!)
        : quantity.moneyProduct(
            unitCost,
            CurrencyCatalog.require(widget.portfolio.currencyCode).minorUnit,
          );
    total.toDouble();
    return total;
  }

  /// 留空保持未知；原总成本无法换算成可输入均价时，空白是保留原金额的显示回退，
  /// 不能仅因更正数量或数字格式就抹去已知成本。明确编辑均价后清空才表示未知。
  InvestmentDecimal? _readTotalCost(InvestmentDecimal quantity) {
    if (_unitCost.text.trim().isEmpty) {
      return !_unitCostEdited &&
              _initialText.isEmpty &&
              widget.holding.cost != null
          ? InvestmentDecimal.parse(widget.holding.cost!)
          : null;
    }
    return _totalCost(quantity, InvestmentDecimal.parse(_unitCost.text));
  }

  /// 保存到同一账本、同一原始聚合；冲突或落库失败保留草稿供核对，不关闭页面。
  /// Controller 负责串行重放及原子写入，此处提供明确数量、总成本及并发校验依据。
  Future<bool> _save() async {
    if (_saving || _saved) return false;
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (!identical(
      c.investmentFor(widget.portfolio.accountId),
      widget.portfolio,
    )) {
      setState(() => _error = l.investCostChanged);
      return false;
    }
    late InvestmentDecimal quantity;
    InvestmentDecimal? totalCost;
    try {
      quantity = _readQuantity();
    } on FormatException {
      setState(() => _error = l.investOpeningQuantityInvalid);
      return false;
    }
    try {
      totalCost = _readTotalCost(quantity);
    } on FormatException {
      // 输入错误属于可恢复的字段校验；不记录敏感金额，保留原文让用户直接修正。
      setState(() => _error = l.investUnitCostInvalid);
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await c.setStockOpeningHolding(
      widget.portfolio.accountId,
      widget.holding.securityId,
      widget.holding.short,
      quantity: quantity.toString(),
      cost: totalCost?.toString(),
      expectedPortfolio: widget.portfolio,
    );
    if (!mounted) return ok;
    setState(() {
      _saving = false;
      _saved = ok;
      if (!ok) _error = l.investCostCorrectionFailed;
    });
    return ok;
  }

  /// 保存按钮与离页保护共用 [_save]；仅在持久化成功后退出当前编辑页。
  Future<void> _saveAndClose() async {
    if (await _save() && mounted) _exitController.exit();
  }

  /// 删除当前方向已保存的期初记录；成本输入仍是草稿，不会先保存再删除。
  /// 先确认页面仍对应原始聚合，避免旧页面误删后来替换的期初；再由共享入口
  /// 预览后续持仓/现金并原子提交，失败或取消时继续保留此页草稿。
  Future<void> _deleteOpening() async {
    if (_saving || _saved) return;
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    if (!identical(
      c.investmentFor(widget.portfolio.accountId),
      widget.portfolio,
    )) {
      setState(() => _error = l.investCostChanged);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await showInvestmentHoldingRemovalConfirmation(
      context: context,
      accountId: widget.portfolio.accountId,
      securityId: widget.holding.securityId,
      openingOnly: true,
      short: widget.holding.short,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = ok;
    });
    if (ok) _exitController.exit();
  }

  /// 复用证券输入组件、实色卡片和标准页面骨架，预览只读且随输入即时更新。
  /// [context] 提供当前语言、金额显示偏好及账本作用域，窄屏/大字号自然换行。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    // 订阅账本/账户变化；切换账本或删除账户后隐藏旧证券资料，草稿仅留本页内存。
    if (c.activeBook.id != widget.portfolio.bookId ||
        c.investmentFor(widget.portfolio.accountId) == null) {
      return EntryEditorSurface(
        isDirty: _dirty,
        canSave: false,
        isSaving: _saving,
        onSave: _save,
        exitController: _exitController,
        body: SafeArea(
          child: VeriPage(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                VeriHeader(title: l.investCorrectOpeningCost, showBack: true),
                const SizedBox(height: 12),
                InvestmentHint(l.investCostChanged),
              ],
            ),
          ),
        ),
      );
    }
    final security = widget.portfolio.securities.firstWhere(
      (s) => s.id == widget.holding.securityId,
    );
    InvestmentDecimal? total;
    try {
      total = _readTotalCost(_readQuantity());
    } on FormatException {
      // 空白或尚未输入完成时不制造零总额；提交时再显示字段校验错误。
    }
    return EntryEditorSurface(
      isDirty: _dirty,
      canSave: !_saving && !_saved && _dirty,
      isSaving: _saving,
      onSave: _save,
      exitController: _exitController,
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(title: l.investCorrectOpeningCost, showBack: true),
              const SizedBox(height: 12),
              InvestmentSection(
                title: '${security.name} · ${security.symbol}',
                children: [
                  Text(
                    widget.holding.short ? l.investShortPosition : l.investLong,
                  ),
                  InvestmentInputField(
                    label: l.investOpeningShares,
                    child: TextField(
                      key: const ValueKey('stock-opening-quantity'),
                      controller: _quantity,
                      readOnly: _saving || _saved,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: investmentInputDecoration(context),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                  const SizedBox(height: 12),
                  InvestmentInputField(
                    label: l.investOpeningUnitCost,
                    child: TextField(
                      key: const ValueKey('stock-opening-unit-cost'),
                      controller: _unitCost,
                      readOnly: _saving || _saved,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: investmentInputDecoration(context),
                      onChanged: (_) => setState(() {
                        _unitCostEdited = true;
                        _error = null;
                      }),
                    ),
                  ),
                  DetailInfoRow(
                    inline: true,
                    label: l.investOpeningTotalCost,
                    value: total == null
                        ? l.investUnknown
                        : formatUserMoney(
                            total.toDouble(),
                            widget.portfolio.currencyCode,
                          ),
                  ),
                  const SizedBox(height: 12),
                  InvestmentHint(l.investCorrectOpeningCostHint),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: veriSemantic(context, veriExpense)),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: !_saving && !_saved && _dirty ? _saveAndClose : null,
                child: Text(l.commonSave),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _saving || _saved ? null : _deleteOpening,
                style: TextButton.styleFrom(
                  foregroundColor: veriSemantic(context, veriExpense),
                ),
                icon: const Icon(Icons.delete_outline),
                label: Text(l.investDeleteOpeningHolding),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
