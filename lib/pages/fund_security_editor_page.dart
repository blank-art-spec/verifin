/// 基金身份草稿：手工录入和主动查询共用，返回资料时不创建持仓或申购。
library;

import 'package:flutter/material.dart';

import '../app/common_widgets.dart';
import '../app/investments/fund_workflow_math.dart';
import '../app/investments/investment_security_autocomplete.dart';
import '../app/investments/investment_security_suggestions.dart';
import '../app/investments/investment_widgets.dart';
import '../app/models.dart';
import '../app/veri_fin_scope.dart';
import '../l10n/app_localizations.dart';
import 'entry_editor_session.dart';

/// 输入当前账户同币种基金，查询结果必须主动选择后才进入可编辑草稿。
class FundSecurityEditorPage extends StatefulWidget {
  /// [accountId] 固定实际币种账户；[initial] 仅用于重开尚未保存的基金资料草稿。
  /// 本页只返回 StockSecurity，最终持久化由父页面的申购/已有持仓命令完成。
  const FundSecurityEditorPage({
    super.key,
    required this.accountId,
    this.initial,
  });

  final String accountId;
  final StockSecurity? initial;

  /// 每次打开创建独立输入、查询序号与返回保护，不共享其他账户的临时资料。
  @override
  State<FundSecurityEditorPage> createState() => _FundSecurityEditorPageState();
}

class _FundSecurityEditorPageState extends State<FundSecurityEditorPage> {
  final _symbol = TextEditingController();
  final _name = TextEditingController();
  final _exitController = EditorExitController();
  late String _bookId, _currency, _initialSnapshot;
  StockMarket _market = StockMarket.hk;
  List<StockSecurity> _online = const [];
  String? _onlineQuery, _message, _error;
  StockSecurity? _result;
  bool _initialized = false, _searching = false;
  int _generation = 0, _openRequest = 0;

  /// 精确比较用户输入；查询中的临时状态不属于需要保存的资料。
  String get _snapshot => editorDraftSnapshot(
    fields: {'symbol': _symbol, 'name': _name},
    values: [_market.name],
  );

  /// 查询必须绑定完整草稿，期间修改名称也会使旧响应失效，避免覆盖新输入。
  String get _queryContext => '$_bookId|$_currency|$_snapshot';

  /// 从当前账本复制账户币种与可选初始草稿；后续重建不覆盖用户正在编辑的资料。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final c = VeriFinScope.of(context);
    _bookId = c.activeBook.id;
    _currency =
        c.accounts
            .where((a) => a.id == widget.accountId && a.bookId == _bookId)
            .firstOrNull
            ?.currencyCode ??
        '';
    _market =
        widget.initial?.market ??
        (_currency == 'CNY' ? StockMarket.cn : StockMarket.hk);
    _symbol.text = widget.initial?.symbol ?? '';
    _name.text = widget.initial?.name ?? '';
    _initialSnapshot = _snapshot;
    _initialized = true;
    _symbol.addListener(_changed);
    _name.addListener(_changed);
  }

  /// 输入或市场变化立即撤销旧查询，只更新内存；输入本身从不发出网络请求。
  void _changed() {
    _generation++;
    setState(() {
      _searching = false;
      _online = const [];
      _onlineQuery = null;
      _message = null;
      _error = null;
    });
  }

  /// 校验账户仍属于原账本且币种未变，防止异步查询或返回期间切换到另一账户上下文。
  bool _accountAvailable() {
    final c = VeriFinScope.of(context);
    return c.activeBook.id == _bookId &&
        c.accounts.any(
          (a) =>
              a.id == widget.accountId &&
              a.bookId == _bookId &&
              a.currencyCode == _currency &&
              a.type.supportsSecurities,
        );
  }

  /// 检查 [generation] 与 [snapshot] 是否仍属于当前草稿；过期响应不能改变新查询。
  /// 账户临时失效时也结束本次等待，避免切回原账本后按钮一直停在处理中。
  bool _acceptQueryResponse(int generation, String snapshot) {
    if (!mounted || generation != _generation) return false;
    if (snapshot != _queryContext || !_accountAvailable()) {
      setState(() => _searching = false);
      return false;
    }
    return true;
  }

  /// 主动检索一次代码；完成时核对序号、草稿、账本及路由，不抢占用户的新页面。
  /// Controller 记录隐私友好的失败日志，本页展示错误并保留手工输入。
  Future<void> _search() async {
    if (_searching || !_accountAvailable()) return;
    final query = _symbol.text.trim();
    if (query.isEmpty) return;
    final c = VeriFinScope.of(context);
    final generation = ++_generation;
    final snapshot = _queryContext;
    setState(() {
      _searching = true;
      _online = const [];
      _onlineQuery = null;
      _message = null;
    });
    try {
      final values = await c.searchInvestmentFunds(
        query,
        market: _market,
        currencyCode: _currency,
      );
      if (!_acceptQueryResponse(generation, snapshot)) return;
      setState(() {
        _searching = false;
        _online = values;
        _onlineQuery = query;
        _message = values.isEmpty
            ? AppLocalizations.of(context).fundSearchNoResults
            : AppLocalizations.of(context).fundSearchChooseResult;
        if (values.isNotEmpty && (ModalRoute.of(context)?.isCurrent ?? false)) {
          _openRequest++;
        }
      });
    } catch (_) {
      // Controller 已记录错误类型；这里不显示可能含请求地址的原始异常。
      if (!_acceptQueryResponse(generation, snapshot)) return;
      setState(() {
        _searching = false;
        _message = AppLocalizations.of(context).fundSearchFailed;
      });
    }
  }

  /// [suggestion] 必须经用户点选；只填写身份，不携带其他账户参考价、成本或份额。
  void _select(InvestmentSecuritySuggestion suggestion) {
    final security = suggestion.security;
    _symbol.text = security.symbol;
    _name.text = security.name;
    setState(() => _market = security.market);
  }

  /// 校验代码与名称后仅生成返回值；同市场、忽略大小写的已有代码复用原身份。
  /// 不按代码前缀猜市场/币种，不把名称或查询成功当作自动净值支持承诺。
  Future<bool> _save() async {
    if (!_accountAvailable()) return false;
    final symbol = _symbol.text.trim().toUpperCase();
    final name = _name.text.trim();
    final security = StockSecurity(
      symbol: symbol,
      name: name,
      market: _market,
      currencyCode: _currency,
      type: InvestmentSecurityType.fund,
    );
    if (!RegExp(r'^[A-Z0-9][A-Z0-9._-]{0,63}$').hasMatch(symbol) ||
        name.isEmpty ||
        name.length > 160 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        !supportsFundAmountWorkflow(security)) {
      setState(() => _error = AppLocalizations.of(context).fundIdentityInvalid);
      return false;
    }
    final existing = VeriFinScope.of(context)
        .investmentFor(widget.accountId)
        ?.securities
        .where(
          (s) =>
              s.isFund &&
              s.market == _market &&
              s.currencyCode == _currency &&
              s.symbol.toUpperCase() == symbol,
        )
        .firstOrNull;
    _generation++;
    _result = existing ?? security;
    return true;
  }

  /// 明确使用资料后退出子页面；父表单取消时这份资料仍不会进入数据库。
  Future<void> _saveAndExit() async {
    if (await _save() && mounted) _exitController.exit();
  }

  /// 释放页面拥有的输入控制器，并使尚未返回的查询失效。
  @override
  void dispose() {
    _generation++;
    _symbol.removeListener(_changed);
    _name.removeListener(_changed);
    _symbol.dispose();
    _name.dispose();
    super.dispose();
  }

  /// 使用统一页面骨架、离页保护和证券候选组件；实色表面支持窄屏滚动。
  @override
  Widget build(BuildContext context) {
    final c = VeriFinScope.of(context), l = AppLocalizations.of(context);
    final available = _accountAvailable();
    final canSave =
        available &&
        _symbol.text.trim().isNotEmpty &&
        _name.text.trim().isNotEmpty;
    final suggestions = collectInvestmentSecuritySuggestions(
      portfolios: c.accounts
          .map((a) => c.investmentFor(a.id))
          .whereType<InvestmentPortfolio>(),
      bookId: _bookId,
      accountId: widget.accountId,
      currencyCode: _currency,
      market: _market,
      type: InvestmentSecurityType.fund,
      remoteSecurities: _online,
      remoteQuery: _onlineQuery,
    );
    return EntryEditorSurface(
      isDirty: _snapshot != _initialSnapshot,
      canSave: canSave,
      onSave: _save,
      exitController: _exitController,
      popResult: () => _result,
      body: SafeArea(
        child: VeriPage(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              VeriHeader(
                title: l.fundAddManually,
                showBack: true,
                actions: [
                  SaveHeaderAction(onPressed: canSave ? _saveAndExit : null),
                ],
              ),
              if (!available) InvestmentHint(l.investSaveError),
              InvestmentHint(l.fundIdentityDraftHint),
              const SizedBox(height: 12),
              InvestmentSection(
                title: l.investSecurityDetails,
                children: [
                  VeriAnchoredChoice<StockMarket>(
                    values: const [StockMarket.hk, StockMarket.cn],
                    selected: _market,
                    semanticLabel: l.investMarket,
                    idOf: (value) => 'fund-market-${value.name}',
                    labelOf: (value) => value.label(l, fund: true),
                    onSelected: (value) {
                      _market = value;
                      _changed();
                    },
                    builder: (context, open, active) => SettingsRow(
                      icon: Icons.public_outlined,
                      title: l.investMarket,
                      trailing: _market.label(l, fund: true),
                      onTap: available ? open : null,
                    ),
                  ),
                  DetailInfoRow(
                    label: l.commonCurrency,
                    value: _currency,
                    inline: true,
                  ),
                  InvestmentSecurityAutocomplete(
                    controller: _symbol,
                    fieldKey: const Key('fund-identity-symbol'),
                    label: l.fundCode,
                    suggestions: suggestions,
                    openRequest: _openRequest,
                    readOnly: !available,
                    onSelected: _select,
                  ),
                  OutlinedButton.icon(
                    key: const Key('fund-search-online'),
                    style: investmentOutlineButtonStyle(context),
                    onPressed:
                        !available || _searching || _symbol.text.trim().isEmpty
                        ? null
                        : _search,
                    icon: const Icon(Icons.search),
                    label: Text(
                      _searching ? l.commonProcessing : l.fundSearchOnline,
                    ),
                  ),
                  InvestmentHint(l.fundSearchConsent),
                  if (_message != null) InvestmentHint(_message!),
                  InvestmentInputField(
                    label: l.fundName,
                    child: TextField(
                      key: const Key('fund-identity-name'),
                      controller: _name,
                      readOnly: !available,
                      decoration: investmentInputDecoration(context),
                    ),
                  ),
                  InvestmentHint(l.fundManualNavHint),
                  if (_error != null) InvestmentHint(_error!),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
