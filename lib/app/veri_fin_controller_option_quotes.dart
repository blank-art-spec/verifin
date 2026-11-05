part of 'veri_fin_controller.dart';

/// 期权行情凭证的独立设备生命周期；不进入账目写入队列或普通偏好备份。
mixin _OptionQuoteCredentialOps on _ControllerState {
  OptionQuoteCredentialStore? get _optionQuoteCredentialStore;
  bool _optionQuoteCredentialsLoadFailed = false;
  bool _savingOptionQuoteCredentials = false;

  /// 设备读取或解密失败时显示明确提示；保留磁盘原文，用户可重新填写或主动清除。
  bool get optionQuoteCredentialsLoadFailed =>
      _optionQuoteCredentialsLoadFailed;

  AlpacaOptionQuoteAdapter? get _optionQuoteAdapter => _marketQuoteClient
      .adapters
      .whereType<AlpacaOptionQuoteAdapter>()
      .firstOrNull;

  /// 只读查询未保存合约；不将观察写入账目、参考价或行情缓存。
  /// 切换账本、销毁或来源重配后，旧结果只能作为 cancelled 返回。
  Future<DraftOptionQuoteResult> fetchDraftOptionQuote(
    MarketQuoteRequest request,
  ) async {
    if (_controllerDisposed) {
      return const DraftOptionQuoteResult(DraftOptionQuoteStatus.cancelled);
    }
    final bookId = _activeBookId;
    final sync = investmentQuoteSync;
    final result = await sync.fetchDraftOptionQuote(
      request,
      isCurrent: () => !_controllerDisposed && _activeBookId == bookId,
    );
    if (_controllerDisposed || _activeBookId != bookId) {
      return const DraftOptionQuoteResult(DraftOptionQuoteStatus.cancelled);
    }
    final adapter = _optionQuoteAdapter;
    if (result.status == DraftOptionQuoteStatus.unsupported &&
        adapter != null &&
        _marketQuoteClient.allowsAdapter(adapter) &&
        !adapter.configured &&
        request.option &&
        !request.fund &&
        request.market == StockMarket.us &&
        request.currency == 'USD') {
      try {
        final identity = MarketQuoteRequest.usOptionSymbol(request.symbol);
        if (request.symbol == identity.symbol &&
            request.optionUnderlyingSymbol == identity.optionUnderlyingSymbol &&
            request.optionExpiry == identity.optionExpiry &&
            request.optionRight == identity.optionRight &&
            request.optionStrike != null &&
            InvestmentDecimal.parse(
                  request.optionStrike!,
                ).compareTo(InvestmentDecimal.parse(identity.optionStrike!)) ==
                0) {
          return const DraftOptionQuoteResult(
            DraftOptionQuoteStatus.credentialsRequired,
          );
        }
      } on FormatException {
        // 不合格身份保留 unsupported，不把缺配置误报成唯一原因。
      }
    }
    return result;
  }

  /// create 返回前恢复来源配置；失败不阻止账本打开，不改联网偏好或清毁安全存储。
  Future<void> _restoreOptionQuoteCredentials() async {
    final store = _optionQuoteCredentialStore, adapter = _optionQuoteAdapter;
    if (store == null || adapter == null) return;
    try {
      final credentials = await store.read();
      if (_controllerDisposed) return;
      adapter.configure(
        keyId: credentials?.keyId ?? '',
        secretKey: credentials?.secretKey ?? '',
      );
      _optionQuoteCredentialsLoadFailed = false;
    } catch (_) {
      _optionQuoteCredentialsLoadFailed = true;
      _logger?.warning('期权行情凭证读取失败，已保留设备原保存数据', source: 'investment_quote');
    }
  }

  /// 成对验证后先清旧行情缓存，再持久保存凭证，最后启用新内存配置。
  /// 双空表示主动清除；失败保留旧内存凭证并返回 false，页面应保留输入草稿。
  /// 同时只接受一次保存；无设备安全存储时不能假装保存成功，字段不写 KV 或备份。
  Future<bool> saveOptionQuoteCredentials(
    String keyId,
    String secretKey,
  ) async {
    final store = _optionQuoteCredentialStore, adapter = _optionQuoteAdapter;
    if (_controllerDisposed ||
        _savingOptionQuoteCredentials ||
        store == null ||
        adapter == null) {
      return false;
    }
    final key = keyId.trim(), secret = secretKey.trim();
    final OptionQuoteCredentials? credentials;
    try {
      credentials = key.isEmpty && secret.isEmpty
          ? null
          : OptionQuoteCredentials(keyId: key, secretKey: secret);
    } on FormatException {
      // 预期的表单校验失败；不记录用户填写的凭证，调用方保留草稿并反馈。
      return false;
    }
    _savingOptionQuoteCredentials = true;
    try {
      final saved = await investmentQuoteSync.reconfigureSource(
        sourceId: adapter.capability.id,
        affectedPortfolios: _investmentPortfolios.where(
          (portfolio) => portfolio.securities.any(
            (security) =>
                security.option != null &&
                security.market == StockMarket.us &&
                security.currencyCode == 'USD',
          ),
        ),
        persistConfiguration: () =>
            credentials == null ? store.clear() : store.write(credentials),
        configure: () {
          adapter.configure(
            keyId: credentials?.keyId ?? '',
            secretKey: credentials?.secretKey ?? '',
          );
          _optionQuoteCredentialsLoadFailed = false;
        },
      );
      if (saved && !_controllerDisposed) notifyListeners();
      return saved;
    } finally {
      _savingOptionQuoteCredentials = false;
    }
  }
}
