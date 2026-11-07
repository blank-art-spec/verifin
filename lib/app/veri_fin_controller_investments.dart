part of 'veri_fin_controller.dart';

/// 期权草稿的只读预览结果；成功保留原预览数据，失败仅提供稳定原因码。
class OptionEventPreviewResult {
  /// [preview] 为当前组合完整重放的结果；[issue] 非空时预览无效，不能用来保存。
  /// 私有构造保证界面只能消费 Controller 的校验结果，不能自行拼造成功状态。
  const OptionEventPreviewResult._({this.preview, this.issue});

  final ({
    InvestmentPortfolio portfolio,
    StockProjection projection,
    double cash,
  })?
  preview;
  final InvestmentValidationIssue? issue;
}

/// 删除持仓时不能单独拆开的关联事实，或删除后不再成立的历史账务。
enum InvestmentHoldingRemovalIssue {
  /// 跨账户转移必须同时处理两端，不能从单个账户删除一边。
  transfer,

  /// 实物交割同时改变期权及标的股票，需要独立的整体更正流程。
  physicalSettlement,

  /// 删除后会出现超量平仓、历史现金不足或其他无效引用。
  invalidHistory,
}

/// 只读的持仓删除预览；构造器仅供 Controller 使用，界面不能自行拼造删除候选。
class InvestmentHoldingRemovalPreview {
  /// [original] 和 [revision] 固定确认时的持仓及资金依据；[candidate] 是零落库副作用的候选。
  /// [openingOnly] 为 true 时只删除 [short] 方向期初行，否则清除该证券全部方向及关联记录。
  /// 三个计数分别说明期初行、投资事件及基金申购事实的删除范围，现金表示同一时点的前后值。
  const InvestmentHoldingRemovalPreview._({
    required this.original,
    required this.securityId,
    required this.openingOnly,
    required this.short,
    required this.openingCount,
    required this.eventCount,
    required this.subscriptionCount,
    required this.cashBefore,
    required this.cashAfter,
    required this.issue,
    required this._candidate,
    required this._revision,
  });

  final InvestmentPortfolio original;
  final String securityId;
  final bool openingOnly, short;
  final int openingCount, eventCount, subscriptionCount;
  final double cashBefore;
  final double? cashAfter;
  final InvestmentHoldingRemovalIssue? issue;
  final InvestmentPortfolio _candidate;
  final String _revision;

  /// 只有预览完整通过引用、数量及资金校验，才允许界面提供最终确认操作。
  bool get canRemove => issue == null && cashAfter != null;
}

/// 股票投资命令：草稿先完整验证，原子落库成功后才发布新内存状态。
mixin _InvestmentOps on _ControllerOps {
  /// 串行执行投资命令；非法十进制/账务边界返回失败并记录中文原因，不泄露持仓原文。
  Future<bool> _runInvestmentCommand(Future<bool> Function() operation) =>
      _enqueueCaptureMutation(() async {
        try {
          return await operation();
        } on FormatException catch (error) {
          _logger?.warning('投资草稿未通过校验：${error.message}', source: 'investment');
          return false;
        }
      });

  /// 返回当前账本真实币种账户的投资状态；父主体不持有自己的仓位。
  InvestmentPortfolio? investmentFor(String accountId) => _investmentPortfolios
      .where((v) => v.accountId == accountId && v.bookId == _activeBookId)
      .firstOrNull;

  /// 返回账户持仓/已实现结果；未启用时返回 null，不自动创建期初。
  StockProjection? investmentProjection(String accountId) {
    final value = investmentFor(accountId);
    return value == null ? null : projectStocks(value);
  }

  /// 自动派生指定基金的净值日参考收益、基金市值及有完整价格依据的账户历史资产。
  /// [accountId] 是当前账本真实币种账户，[securityId] 必须指向该账户已采用净值的基金。
  /// 数据仅来自已校验的公开净值缓存与各日真实账务；缺价保持未知，不写收入或估值快照。
  /// 网络关闭后可继续读取合格缓存；撤销研究来源或改回手填后不继续采用这份参考历史。
  List<FundReferenceDay> fundReferenceHistoryFor(
    String accountId,
    String securityId,
  ) {
    final p = investmentFor(accountId);
    if (p == null || !p.marketPriceIds.contains(securityId)) return const [];
    final account = accounts
        .where((a) => a.id == accountId && a.bookId == p.bookId)
        .firstOrNull;
    final security = p.securities
        .where((s) => s.id == securityId && s.isFund)
        .firstOrNull;
    final history = investmentQuoteSync.fundNavHistoryFor(p, securityId);
    if (account == null || security == null || history == null) return const [];
    return buildFundReferenceHistory(
      portfolio: p,
      security: security,
      history: history,
      account: account,
      entries: _entries,
      anchors: _balanceAnchors,
    );
  }

  /// 返回当前账户原币资产分解；普通账户仍以现金/信用余额的正负拆分。
  AccountAssetAmounts accountAssetAmounts(Account account) {
    final p = _portfolioForAccount(account), cash = accountBalance(account);
    return p == null
        ? AccountAssetAmounts.balance(cash)
        : valueInvestmentAccount(pricedInvestmentPortfolio(p), cash).amounts!;
  }

  /// 根据快照原价格重放该时点原币估值；账务/规格曾被修改时返回 null，提示重新核对。
  InvestmentAccountValuation? investmentSnapshotValuation(
    String accountId,
    InvestmentValuationSnapshot snapshot,
  ) {
    final p = investmentFor(accountId),
        account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (p == null ||
        account == null ||
        !p.valuationSnapshots.contains(snapshot) ||
        snapshot.revision !=
            investmentRevision(
              p,
              _entries,
              _balanceAnchors,
              snapshot.capturedAt,
            )) {
      return null;
    }
    final past = investmentAt(p, snapshot.capturedAt).copyWith(
      manualPrices: snapshot.prices.map((id, f) => MapEntry(id, f.price)),
    );
    return valueInvestmentAccount(
      past,
      accountCashAt(
        account: account,
        entries: _entries,
        anchors: _balanceAnchors,
        at: snapshot.capturedAt,
        portfolio: past,
      ),
      at: snapshot.capturedAt,
    );
  }

  /// 主动记录实际当前时点的历史价格和汇率依据；不允许调用方伪造过去的快照日期。
  /// 保存失败保留原聚合；同一时点重试只保留一条，旧历史不随今天的参考价更新。
  Future<bool> captureInvestmentValuation(String accountId) =>
      _runInvestmentCommand(() async {
        final p = investmentFor(accountId);
        if (p == null) return false;
        final at = DateTime.now().toUtc(),
            effective = pricedInvestmentPortfolio(p);
        final quotes = investmentQuoteSync.quotesFor(p),
            facts = <String, InvestmentPriceFact>{};
        for (final position in projectStocks(investmentAt(p, at)).positions) {
          final security = p.securities.firstWhere(
            (s) => s.id == position.securityId,
          );
          final q = p.marketPriceIds.contains(security.id)
              ? quotes[security.id]
              : null;
          final ref = q?.reference(MarketQuoteRequest(security), at);
          final price = effective.manualPrices[security.id];
          if (price == null) continue;
          facts[security.id] = InvestmentPriceFact(
            price: price,
            quotedAt: ref == null ? at : ref.time,
            manual: ref == null,
            source: ref == null ? '' : q!.source,
            dateOnly: ref != null && q!.dateOnly,
            sourceTimeUnknown: ref != null && q!.sourceTimeUnknown,
            fetchedAt: ref != null && q!.sourceTimeUnknown ? q.fetchedAt : null,
          );
        }
        final rate = exchangeRateFor(p.currencyCode, at);
        final s = InvestmentValuationSnapshot(
          capturedAt: at,
          revision: investmentRevision(p, _entries, _balanceAnchors, at),
          baseCurrencyCode: activeBook.baseCurrencyCode,
          prices: facts,
          rateToBase: p.currencyCode == activeBook.baseCurrencyCode
              ? 1
              : rate?.rateToBase,
          rateDate: rate?.effectiveDate,
        );
        final next = p.copyWith(
          valuationSnapshots: [
            ...p.valuationSnapshots.where(
              (s) => !s.capturedAt.isAtSameMomentAs(at),
            ),
            s,
          ],
        );
        return _saveInvestmentCandidates([
          for (final value in _investmentPortfolios)
            value.accountId == p.accountId ? next : value,
        ]);
      });

  /// 首次启用 [accountId]；[openingCash] 为核对后的真实现金，不是原总资产。
  /// [openingHoldings] 可包含未知成本；[manualPrices] 只用于参考估值，取消草稿无副作用。
  /// [openingOptionMargins] 为每合约期初冻结额，与现金和多项持仓同次原子保存。
  Future<bool> enableInvestment({
    required String accountId,
    required String openingCash,
    DateTime? openedAt,
    List<StockSecurity> securities = const [],
    List<StockHolding> openingHoldings = const [],
    Map<String, String> manualPrices = const {},
    Map<String, String> openingOptionMargins = const {},
    bool allowFinancing = false,
  }) => _runInvestmentCommand(() async {
    final account = _accounts
        .where(
          (a) =>
              a.id == accountId &&
              a.bookId == _activeBookId &&
              a.type.supportsSecurities,
        )
        .firstOrNull;
    if (account == null || investmentFor(accountId) != null) return false;
    final time = openedAt ?? DateTime.now();
    final value = InvestmentPortfolio(
      accountId: account.id,
      bookId: account.bookId,
      currencyCode: account.currencyCode,
      openedAt: time,
      openingCash: InvestmentDecimal.parse(openingCash)
          .rounded(CurrencyCatalog.require(account.currencyCode).minorUnit)
          .toString(),
      includedEntryIds: _entries
          .where(
            (e) =>
                e.bookId == account.bookId &&
                entryTouchesAccount(e, account.id) &&
                !accountEffectDate(e).isAfter(time),
          )
          .map((e) => e.id)
          .toList(),
      securities: securities,
      openingHoldings: openingHoldings,
      manualPrices: manualPrices,
      events: investmentOpeningMarginEvents(
        openedAt: time,
        securities: securities,
        holdings: openingHoldings,
        margins: openingOptionMargins,
      ),
      allowFinancing: allowFinancing,
    );
    return _saveInvestmentCandidates([..._investmentPortfolios, value]);
  });

  /// 保存或编辑股票/基金份额事件；[event.id] 稳定保证重试幂等，编辑后重放后续事件。
  /// [security] 保留真实品种，基金只接受已实现的份额买卖、分红费用及同币种转移。
  /// [referencePrice] 是用户确认的手填参考价，不修改任何历史成交价。
  Future<bool> saveStockEvent({
    required String accountId,
    required StockSecurity security,
    required StockEvent event,
    String? referencePrice,
  }) => _runInvestmentCommand(() async {
    final current = investmentFor(accountId);
    if (current == null ||
        security.option != null ||
        event.kind.isOptionEvent ||
        event.kind == StockEventKind.fundAcquire ||
        event.kind == StockEventKind.fundHoldingBaseline ||
        event.fundSubscriptionId != null ||
        event.securityId != security.id ||
        security.currencyCode != current.currencyCode) {
      return false;
    }
    final old = current.events.where((e) => e.id == event.id).firstOrNull;
    // 同一幂等 ID 只能编辑原证券，不能借股票入口替换已存在的期权事实。
    if (old?.batchId != null ||
        old?.kind == StockEventKind.fundAcquire ||
        old?.kind == StockEventKind.fundHoldingBaseline ||
        event.batchId != null ||
        (old != null && old.securityId != event.securityId)) {
      return false;
    }
    final next = current.copyWith(
      securities: [
        ...current.securities.where((s) => s.id != security.id),
        security,
      ],
      events: [...current.events.where((e) => e.id != event.id), event],
      // 成交页明确填写的参考价也属于持续手填覆盖。
      marketPriceIds: referencePrice == null
          ? current.marketPriceIds
          : current.marketPriceIds.where((id) => id != security.id).toSet(),
      manualPrices: {
        ...current.manualPrices,
        if (referencePrice != null)
          security.id: InvestmentDecimal.parse(referencePrice).toString(),
      },
    );
    return _saveInvestmentCandidates([
      for (final p in _investmentPortfolios)
        p.accountId == accountId ? next : p,
    ]);
  });

  /// 删除非跨账户投资事件；若导致后续超量卖出则拒绝，保留原始聚合。
  Future<bool> deleteStockEvent(String accountId, String eventId) =>
      _runInvestmentCommand(() async {
        final current = investmentFor(accountId);
        final event = current?.events.where((e) => e.id == eventId).firstOrNull;
        if (current == null ||
            event == null ||
            event.batchId != null ||
            event.kind == StockEventKind.fundAcquire) {
          return false;
        }
        final next = current.copyWith(
          events: current.events.where((e) => e.id != eventId).toList(),
        );
        return _saveInvestmentCandidates([
          for (final p in _investmentPortfolios)
            p.accountId == accountId ? next : p,
        ]);
      });

  /// 预览清除 [accountId] 内 [securityId] 的误录账务，绝不伪造成交或修改派生数量。
  /// 默认同时移除该证券多空期初、全部投资事件及基金申购/付款/退款事实；
  /// [openingOnly] 为 true 时只删除 [short] 方向的期初行，后续事实全部保留并重放。
  /// 保留证券定义、后备价格、历史快照、普通资金流水和现金锚点；旧快照按修订摘要失效。
  /// 返回 null 表示目标已失效或没有可删除事实，关联阻止原因通过预览的 issue 表达。
  InvestmentHoldingRemovalPreview? previewInvestmentHoldingRemoval({
    required String accountId,
    required String securityId,
    bool openingOnly = false,
    bool short = false,
  }) {
    final current = investmentFor(accountId);
    if (current == null || !current.securities.any((s) => s.id == securityId)) {
      return null;
    }
    final removedOpening = current.openingHoldings
        .where(
          (h) =>
              h.securityId == securityId && (!openingOnly || h.short == short),
        )
        .toList();
    final removedEvents = openingOnly
        ? <StockEvent>[]
        : current.events.where((e) => e.securityId == securityId).toList();
    final removedSubscriptions = openingOnly
        ? <FundSubscription>[]
        : current.fundSubscriptions
              .where((s) => s.securityId == securityId)
              .toList();
    if (removedOpening.isEmpty &&
        removedEvents.isEmpty &&
        removedSubscriptions.isEmpty) {
      return null;
    }
    final now = DateTime.now();
    final anchor = latestBalanceAnchor(accountId);
    final cashBefore = investmentCashBalance(
      portfolio: current,
      entries: _entries,
      anchor: anchor,
      at: now,
    );
    final revision = investmentRevision(
      current,
      _entries,
      _balanceAnchors,
      DateTime.utc(9999, 12, 31),
    );
    InvestmentHoldingRemovalIssue? issue;
    if (current.events.any(
      (e) => e.securityId == securityId && e.batchId != null,
    )) {
      issue = InvestmentHoldingRemovalIssue.transfer;
    } else if (current.events.any((e) {
      if (e.kind != StockEventKind.optionPhysicalSettle) return false;
      final contract = current.securities
          .where((s) => s.id == e.securityId)
          .firstOrNull;
      return e.securityId == securityId ||
          contract?.option?.underlyingId == securityId;
    })) {
      issue = InvestmentHoldingRemovalIssue.physicalSettlement;
    }
    // 使用完整稳定 ID 清理同刻已包含事实；不能按前缀模糊匹配而删掉相似 ID 的其他记录。
    final removedCashIds = <String>{
      for (final event in removedEvents) 'stock:${event.id}',
      for (final subscription in removedSubscriptions) ...[
        'fund:${subscription.id}:payment',
        'fund:${subscription.id}:refund',
      ],
    };
    var next = current.copyWith(
      openingHoldings: current.openingHoldings
          .where((h) => !removedOpening.contains(h))
          .toList(),
      events: current.events.where((e) => !removedEvents.contains(e)).toList(),
      fundSubscriptions: current.fundSubscriptions
          .where((s) => !removedSubscriptions.contains(s))
          .toList(),
      anchorIncludedIds: {
        for (final entry in current.anchorIncludedIds.entries)
          entry.key: entry.value
              .where((id) => !removedCashIds.contains(id))
              .toList(),
      },
    );
    double? cashAfter;
    if (issue == null) {
      try {
        // 连未来已确认基金起算一起重放；清除完成后不能又由残留确认恢复仓位。
        final future = projectStocks(next, at: DateTime.utc(9999, 12, 31));
        final remains = future.positions.any((p) => p.securityId == securityId);
        if (!openingOnly && remains) {
          throw const FormatException('删除后仍存在目标证券持仓');
        }
        if (!remains) {
          next = next.copyWith(
            marketPriceIds: next.marketPriceIds
                .where((id) => id != securityId)
                .toSet(),
          );
        }
        validateInvestmentPortfolios([
          for (final p in _investmentPortfolios)
            p.accountId == accountId ? next : p,
        ], _accounts);
        cashAfter = investmentCashBalance(
          portfolio: next,
          entries: _entries,
          anchor: anchor,
          at: now,
          rejectUnfundedHistory: !next.allowFinancing,
        );
      } on FormatException {
        // 预览失败属于可恢复的关联校验，界面显示本地化原因；不记录持仓或金额原文。
        issue = InvestmentHoldingRemovalIssue.invalidHistory;
      }
    }
    return InvestmentHoldingRemovalPreview._(
      original: current,
      securityId: securityId,
      openingOnly: openingOnly,
      short: short,
      openingCount: removedOpening.length,
      eventCount: removedEvents.length,
      subscriptionCount: removedSubscriptions.length,
      cashBefore: cashBefore,
      cashAfter: cashAfter,
      issue: issue,
      candidate: next,
      revision: revision,
    );
  }

  /// 确认并原子保存 [preview] 指定的删除范围；预览本身不构成静默删除授权。
  /// 串行队列内同时校验原聚合身份与全部资金事实摘要，拒绝确认期间新增的交易或锚点；
  /// 重新预览后再经统一保存校验，失败保留原 SQLite 和内存，不能只删半份关联事实。
  Future<bool> removeInvestmentHolding(
    InvestmentHoldingRemovalPreview preview,
  ) => _runInvestmentCommand(() async {
    final current = investmentFor(preview.original.accountId);
    if (current == null ||
        !preview.canRemove ||
        !identical(current, preview.original) ||
        investmentRevision(
              current,
              _entries,
              _balanceAnchors,
              DateTime.utc(9999, 12, 31),
            ) !=
            preview._revision) {
      _logger?.warning('持仓删除依据已变化或预览未通过，请重新核对', source: 'investment');
      return false;
    }
    final refreshed = previewInvestmentHoldingRemoval(
      accountId: current.accountId,
      securityId: preview.securityId,
      openingOnly: preview.openingOnly,
      short: preview.short,
    );
    if (refreshed == null ||
        !refreshed.canRemove ||
        refreshed.cashBefore != preview.cashBefore ||
        refreshed.cashAfter != preview.cashAfter) {
      _logger?.warning('持仓删除的资金或关联依据已变化，请重新核对', source: 'investment');
      return false;
    }
    return _saveInvestmentCandidates([
      for (final p in _investmentPortfolios)
        p.accountId == current.accountId ? refreshed._candidate : p,
    ]);
  });

  /// 设置持续手填参考价；[price] 允许明确的零，不把缺价或网络失败自动当零。
  Future<bool> setStockReferencePrice(
    String accountId,
    String securityId,
    String price,
  ) => _runInvestmentCommand(() async {
    final current = investmentFor(accountId);
    if (current == null) return false;
    final next = current.copyWith(
      marketPriceIds: current.marketPriceIds
          .where((id) => id != securityId)
          .toSet(),
      manualPrices: {
        ...current.manualPrices,
        securityId: InvestmentDecimal.parse(price).toString(),
      },
    );
    return _saveInvestmentCandidates([
      for (final p in _investmentPortfolios)
        p.accountId == accountId ? next : p,
    ]);
  });

  /// 按证券显式切换参考价来源；开启仅对已准入来源生效，关闭保留原手填价格。
  Future<bool> setInvestmentMarketPrice(
    String accountId,
    String securityId,
    bool useMarket,
  ) => _runInvestmentCommand(() async {
    final p = investmentFor(accountId);
    final s = p?.securities.where((s) => s.id == securityId).firstOrNull;
    if (p == null ||
        s == null ||
        (useMarket &&
            investmentQuoteSync.client.adapterFor(MarketQuoteRequest(s)) ==
                null)) {
      return false;
    }
    final ids = {...p.marketPriceIds};
    if (useMarket) {
      ids.add(securityId);
    } else {
      ids.remove(securityId);
    }
    final next = p.copyWith(marketPriceIds: ids);
    return _saveInvestmentCandidates([
      for (final v in _investmentPortfolios)
        v.accountId == accountId ? next : v,
    ]);
  });

  /// 补录或更正期初持仓成本，再从期初重放后续买卖、拆股及盈亏；不创造现金腿。
  /// [accountId] 为当前账本的真实币种账户，[securityId] 与 [short] 共同选择期初仓位。
  /// [cost] 默认仍是期初总成本，保持旧调用及已保存数据的语义；[perUnit] 为 true 时，
  /// 它表示股票每股成本，必须乘以期初数量，而不是卖出或拆股后的当前数量。
  /// 量价乘积仅在最后按币种现金精度舍入；负单位成本须在舍入之前拒绝。
  /// [expectedPortfolio] 为编辑页打开时取得的原始组合，非空时拒绝已被其他操作改变的
  /// 草稿，避免用旧数量或旧成本覆盖新记录。全量校验及落库成功后才更新内存；
  /// 如成本更正会破坏既有跨账户转移的成本配对，则保留原数据并返回 false。
  Future<bool> setStockOpeningCost(
    String accountId,
    String securityId,
    bool short,
    String cost, {
    bool perUnit = false,
    InvestmentPortfolio? expectedPortfolio,
  }) => _setStockOpeningHolding(
    accountId,
    securityId,
    short,
    cost: cost,
    perUnit: perUnit,
    expectedPortfolio: expectedPortfolio,
  );

  /// 更正股票/ETF 的期初数量及成本；不新增成交或现金调整，不改证券身份和方向。
  /// [quantity] 必须为正；[cost] 为 null 表示未知成本，否则默认是总成本，
  /// [perUnit] 为 true 时由每股成本与本次更正的数量计算总成本。全量重放后续事件，
  /// 超量卖出、转出、交割或跨账户成本配对失效均拒绝，落库成功前不修改内存。
  /// [expectedPortfolio] 保留原始聚合并发保护；基金/期权沿用各自的更正流程。
  Future<bool> setStockOpeningHolding(
    String accountId,
    String securityId,
    bool short, {
    required String quantity,
    required String? cost,
    bool perUnit = false,
    InvestmentPortfolio? expectedPortfolio,
  }) => _setStockOpeningHolding(
    accountId,
    securityId,
    short,
    quantity: quantity,
    cost: cost,
    perUnit: perUnit,
    expectedPortfolio: expectedPortfolio,
  );

  /// 新旧期初更正入口共用一份串行校验及原子保存；省略数量即保留旧成本 API 语义。
  Future<bool> _setStockOpeningHolding(
    String accountId,
    String securityId,
    bool short, {
    String? quantity,
    required String? cost,
    required bool perUnit,
    InvestmentPortfolio? expectedPortfolio,
  }) => _runInvestmentCommand(() async {
    final current = investmentFor(accountId);
    if (current == null ||
        (expectedPortfolio != null && !identical(current, expectedPortfolio))) {
      return false;
    }
    final holding = current.openingHoldings
        .where((h) => h.securityId == securityId && h.short == short)
        .firstOrNull;
    final security = current.securities
        .where((s) => s.id == securityId)
        .firstOrNull;
    if (holding == null ||
        security == null ||
        ((quantity != null || perUnit) && !security.isStock)) {
      return false;
    }
    final units = InvestmentDecimal.parse(quantity ?? holding.quantity);
    final input = cost == null ? null : InvestmentDecimal.parse(cost);
    if (units.units <= BigInt.zero ||
        (input != null && input.units < BigInt.zero)) {
      throw const FormatException('期初数量必须为正且成本不能为负');
    }
    final totalCost = perUnit && input != null
        ? units.moneyProduct(
            input,
            CurrencyCatalog.require(current.currencyCode).minorUnit,
          )
        : input;
    totalCost?.toDouble();
    final next = current.copyWith(
      openingHoldings: [
        for (final h in current.openingHoldings)
          if (h.securityId == securityId && h.short == short)
            StockHolding(
              securityId: securityId,
              short: short,
              quantity: quantity == null ? h.quantity : units.toString(),
              cost: totalCost?.toString(),
            )
          else
            h,
      ],
    );
    return _saveInvestmentCandidates([
      for (final p in _investmentPortfolios)
        p.accountId == accountId ? next : p,
    ]);
  });

  /// 将股票及分摊成本同时转到同账本同币种账户；不产生收入或虚假现金。
  /// [batchId] 是稳定幂等键；已有完整批次重试返回成功，不重复转移。
  Future<bool> transferStock({
    required String fromAccountId,
    required String toAccountId,
    required String securityId,
    required String quantity,
    required bool short,
    required DateTime occurredAt,
    required String batchId,
  }) => _runInvestmentCommand(() async {
    final from = investmentFor(fromAccountId), to = investmentFor(toAccountId);
    if (from == null ||
        to == null ||
        fromAccountId == toAccountId ||
        from.currencyCode != to.currencyCode) {
      return false;
    }
    if (from.events.any((e) => e.batchId == batchId) &&
        to.events.any((e) => e.batchId == batchId)) {
      return true;
    }
    final security = from.securities
        .where((s) => s.id == securityId)
        .firstOrNull;
    if (security == null || security.option != null) return false;
    // 历史转移会改变后续成本分配；仍只接受位于两端已生效记录之后的真实转移。
    // 已确认但尚未起算的基金事件是未来计划，不应阻止当前股票或旧基金份额转移；
    // 普通成交及已经起算的基金仍保持原有末尾校验，未来申购也不会提前增加可转份额。
    final now = DateTime.now();
    if ([...from.events, ...to.events].any(
      (e) =>
          e.occurredAt.isAfter(occurredAt) &&
          !(e.kind == StockEventKind.fundAcquire && e.occurredAt.isAfter(now)),
    )) {
      return false;
    }
    final holding = projectStocks(from, at: now).positions
        .where((p) => p.securityId == securityId && p.short == short)
        .firstOrNull;
    final q = InvestmentDecimal.parse(quantity);
    if (holding == null ||
        q.units <= BigInt.zero ||
        q.compareTo(holding.quantity) > 0) {
      return false;
    }
    final cost = holding.cost == null
        ? null
        : q.compareTo(holding.quantity) == 0
        ? holding.cost
        : holding.cost!.allocated(
            q,
            holding.quantity,
            CurrencyCatalog.require(from.currencyCode).minorUnit,
          );
    StockEvent leg(InvestmentPortfolio p, StockEventKind kind) => StockEvent(
      id: '$batchId:${kind.name}',
      securityId: securityId,
      kind: kind,
      occurredAt: occurredAt,
      sequence: _nextStockSequence(p),
      quantity: q.toString(),
      price: '0',
      carriedCost: cost?.toString(),
      short: short,
      batchId: batchId,
    );
    final nextFrom = from.copyWith(
      events: [...from.events, leg(from, StockEventKind.transferOut)],
    );
    final nextTo = to.copyWith(
      securities: [...to.securities.where((s) => s.id != securityId), security],
      events: [...to.events, leg(to, StockEventKind.transferIn)],
      manualPrices: {
        ...to.manualPrices,
        if (!to.manualPrices.containsKey(securityId) &&
            from.manualPrices.containsKey(securityId))
          securityId: from.manualPrices[securityId]!,
      },
    );
    return _saveInvestmentCandidates([
      for (final p in _investmentPortfolios)
        p.accountId == from.accountId
            ? nextFrom
            : p.accountId == to.accountId
            ? nextTo
            : p,
    ]);
  });

  /// 取得账户内下一个稳定序号，保证同秒成交不依赖容器遍历顺序。
  int _nextStockSequence(InvestmentPortfolio p) => p.events.fold<int>(
    0,
    (value, e) => e.sequence >= value ? e.sequence + 1 : value,
  );

  /// 读取当前账本 [accountId] 最新组合的下一事件序号，不分配或预占持久化状态。
  /// 新建表单在保存/预览时读取，避免不同隐藏草稿复用初始化时的旧序号；
  /// 已有事件编辑保留原序号。账户组合已失效时返回 null，保存命令仍会再次校验。
  int? nextInvestmentEventSequenceFor(String accountId) {
    final portfolio = investmentFor(accountId);
    return portfolio == null ? null : _nextStockSequence(portfolio);
  }

  /// 生成期权候选聚合；证券规格变更不能追溯篡改历史权利金或已结算交割腿。
  /// [underlying] 必须是同币种股票；[underlyingReferencePrice] 供实物交割后的股票估值。
  InvestmentPortfolio _optionCandidate({
    required String accountId,
    required StockSecurity security,
    required StockSecurity underlying,
    required StockEvent event,
    required String referencePrice,
    String? underlyingReferencePrice,
  }) {
    final p = investmentFor(accountId);
    if (p == null ||
        security.option == null ||
        !underlying.isStock ||
        security.option!.underlyingId != underlying.id ||
        event.securityId != security.id ||
        !event.kind.isOptionEvent ||
        event.batchId != null ||
        p.events.any(
          (e) => e.id == event.id && e.securityId != event.securityId,
        )) {
      throw const FormatException('期权、标的或事件引用不一致');
    }
    _validateOptionDefinitionChange(p, security);
    return p.copyWith(
      securities: [
        ...p.securities.where(
          (s) => s.id != security.id && s.id != underlying.id,
        ),
        underlying,
        security,
      ],
      events: [...p.events.where((e) => e.id != event.id), event],
      marketPriceIds: p.marketPriceIds
          .where(
            (id) =>
                id != security.id &&
                !(id == underlying.id && underlyingReferencePrice != null),
          )
          .toSet(),
      manualPrices: {
        ...p.manualPrices,
        security.id: InvestmentDecimal.parse(referencePrice).toString(),
        if (underlyingReferencePrice != null)
          underlying.id: InvestmentDecimal.parse(
            underlyingReferencePrice,
          ).toString(),
      },
    );
  }

  /// 预览与保存共用候选校验；返回现金/冻结额和全部持仓，预览不写 SQLite 或 Controller。
  /// 失败返回 null；页面保留草稿并提示核对，异常原文不向用户泄露账户内容。
  ({InvestmentPortfolio portfolio, StockProjection projection, double cash})?
  previewOptionEvent({
    required String accountId,
    required StockSecurity security,
    required StockSecurity underlying,
    required StockEvent event,
    required String referencePrice,
    String? underlyingReferencePrice,
  }) => previewOptionEventResult(
    accountId: accountId,
    security: security,
    underlying: underlying,
    event: event,
    referencePrice: referencePrice,
    underlyingReferencePrice: underlyingReferencePrice,
  ).preview;

  /// 返回可解释的零写入预览，供表单定位日期、现金、持仓或结算资料问题。
  /// [accountId] 为当前账本币种账户；[security] 与 [underlying] 为草稿合约和标的。
  /// [event] 为待新增或替换的事实；两个参考价只用于候选估值，不改真实成交。
  /// 仍完整重放全部关联数据；若失败发生在另一条事件，明确标为后续记录冲突。
  OptionEventPreviewResult previewOptionEventResult({
    required String accountId,
    required StockSecurity security,
    required StockSecurity underlying,
    required StockEvent event,
    required String referencePrice,
    String? underlyingReferencePrice,
  }) {
    if (investmentFor(accountId) == null) {
      return const OptionEventPreviewResult._(
        issue: InvestmentValidationIssue.accountUnavailable,
      );
    }
    try {
      final next = _optionCandidate(
        accountId: accountId,
        security: security,
        underlying: underlying,
        event: event,
        referencePrice: referencePrice,
        underlyingReferencePrice: underlyingReferencePrice,
      );
      validateInvestmentPortfolios([
        for (final p in _investmentPortfolios)
          p.accountId == accountId ? next : p,
      ], _accounts);
      final cash = investmentCashBalance(
        portfolio: next,
        entries: _entries,
        anchor: latestBalanceAnchor(accountId),
        rejectUnfundedHistory: !next.allowFinancing,
      );
      return OptionEventPreviewResult._(
        preview: (portfolio: next, projection: projectStocks(next), cash: cash),
      );
    } on InvestmentValidationException catch (error) {
      // 明确的字段/业务校验无需写日志；只返回原因码，不将底层文案或事件 ID 暴露给界面。
      return OptionEventPreviewResult._(
        issue: error.eventId != null && error.eventId != event.id
            ? InvestmentValidationIssue.subsequentEventConflict
            : error.issue,
      );
    } on FormatException {
      // 其余格式错误由界面逐字段校验兜底；保持旧入口失败返回 null 的契约。
      return const OptionEventPreviewResult._(
        issue: InvestmentValidationIssue.invalidInput,
      );
    }
  }

  /// 原子保存期权事实及全部隐含交割腿；[event.id] 保持重试幂等，成功后才发布状态。
  /// 冻结保证金按用户确认的绝对值记载，不充当券商保证金或购买力计算器。
  Future<bool> saveOptionEvent({
    required String accountId,
    required StockSecurity security,
    required StockSecurity underlying,
    required StockEvent event,
    required String referencePrice,
    String? underlyingReferencePrice,
  }) => _runInvestmentCommand(() async {
    final next = _optionCandidate(
      accountId: accountId,
      security: security,
      underlying: underlying,
      event: event,
      referencePrice: referencePrice,
      underlyingReferencePrice: underlyingReferencePrice,
    );
    return _saveInvestmentCandidates([
      for (final p in _investmentPortfolios)
        p.accountId == accountId ? next : p,
    ]);
  });

  /// 补齐待核对合约的交割资料；不伪造成交、不改变冻结额或现金。
  Future<bool> saveOptionSpecification(
    String accountId,
    StockSecurity security,
  ) => _runInvestmentCommand(() async {
    final p = investmentFor(accountId);
    if (p == null ||
        security.option == null ||
        !p.securities.any((s) => s.id == security.id)) {
      return false;
    }
    _validateOptionDefinitionChange(p, security);
    final next = p.copyWith(
      securities: [
        for (final s in p.securities) s.id == security.id ? security : s,
      ],
    );
    return _saveInvestmentCandidates([
      for (final v in _investmentPortfolios)
        v.accountId == accountId ? next : v,
    ]);
  });

  /// 已发生成交后锁定定价身份；交割股数/现金等仅在尚无结算时允许补全。
  /// [security] 不能借同一个代码替换到期日、权利或乘数，从而重算出不同历史现金。
  void _validateOptionDefinitionChange(
    InvestmentPortfolio p,
    StockSecurity security,
  ) {
    final old = p.securities.where((s) => s.id == security.id).firstOrNull;
    if (old == null) return;
    if (old.option == null ||
        old.market != security.market ||
        old.currencyCode != security.currencyCode) {
      throw const InvestmentValidationException(
        InvestmentValidationIssue.contractIdentityLocked,
        '已有证券身份不能修改',
      );
    }
    final a = old.option!.toJson(), b = security.option!.toJson();
    final settled = p.events.any(
      (e) =>
          e.securityId == security.id &&
          {
            StockEventKind.optionPhysicalSettle,
            StockEventKind.optionCashSettle,
          }.contains(e.kind),
    );
    for (final field in [
      'underlyingId',
      'expiry',
      'right',
      'strike',
      'premiumMultiplier',
      if (settled) ...['settlement', 'deliverableShares', 'exerciseCash'],
    ]) {
      if (a[field] != b[field]) {
        throw const InvestmentValidationException(
          InvestmentValidationIssue.contractIdentityLocked,
          '已有合约定价及已结算规格不能改写',
        );
      }
    }
  }

  /// 保存所有候选聚合；先检查引用、重放及融资，再在一个事务内替换。
  Future<bool> _saveInvestmentCandidates(List<InvestmentPortfolio> next) async {
    try {
      validateInvestmentPortfolios(next, _accounts);
      for (final p in next) {
        final account = _accounts.firstWhere((a) => a.id == p.accountId);
        final cash = investmentCashBalance(
          portfolio: p,
          entries: _entries,
          anchor: latestBalanceAnchor(account.id),
          rejectUnfundedHistory: !p.allowFinancing,
        );
        if (cash < 0 && !p.allowFinancing) {
          throw const FormatException('现金不足，请先核实真实融资');
        }
      }
    } on FormatException catch (error) {
      _logger?.warning('投资操作校验未通过：${error.message}', source: 'investment');
      return false;
    }
    if (!await _runTrackedWrite(
      () => _repository.saveInvestmentPortfolios(next),
    )) {
      return false;
    }
    _investmentPortfolios
      ..clear()
      ..addAll(next);
    notifyListeners();
    return true;
  }
}

/// 验证全量投资聚合及转移配对；导入预览和普通保存共用，取消预览不会写库。
void validateInvestmentPortfolios(
  List<InvestmentPortfolio> values,
  List<Account> accounts,
) {
  final ids = <String>{};
  final batches = <String, List<(InvestmentPortfolio, StockEvent)>>{};
  for (final p in values) {
    final account = accounts.where((a) => a.id == p.accountId).firstOrNull;
    if (!ids.add(p.accountId) ||
        account == null ||
        !account.type.supportsSecurities ||
        account.bookId != p.bookId ||
        account.currencyCode != p.currencyCode) {
      throw const FormatException('投资账户关联不合法');
    }
    InvestmentDecimal.parse(p.openingCash).toDouble();
    validateFundSubscriptions(p);
    // 保存/恢复同时验证未来已核准的基金起算事件；当前页面仍按真实当前时点隐藏未生效份额。
    final projection = projectStocks(p, at: DateTime.utc(9999, 12, 31));
    final times = <int>{};
    for (final snapshot in p.valuationSnapshots) {
      CurrencyCatalog.require(snapshot.baseCurrencyCode);
      if (!times.add(snapshot.capturedAt.microsecondsSinceEpoch) ||
          snapshot.capturedAt.isBefore(p.openedAt) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(snapshot.revision) ||
          (snapshot.rateToBase != null &&
              !isValidExchangeRate(snapshot.rateToBase!)) ||
          (snapshot.rateDate?.isAfter(snapshot.capturedAt) ?? false) ||
          (p.currencyCode == snapshot.baseCurrencyCode &&
              snapshot.rateToBase != 1)) {
        throw const FormatException('历史估值依据不合法');
      }
      for (final fact in snapshot.prices.entries) {
        final value = InvestmentDecimal.parse(fact.value.price);
        final security = p.securities
            .where((s) => s.id == fact.key)
            .firstOrNull;
        final quotedAt = fact.value.quotedAt;
        final fetchedAt = fact.value.fetchedAt;
        if (security == null ||
            value.units < BigInt.zero ||
            (fact.value.sourceTimeUnknown
                ? (fact.value.manual ||
                      fact.value.dateOnly ||
                      security.option == null ||
                      security.market != StockMarket.us ||
                      security.currencyCode != 'USD' ||
                      value.units <= BigInt.zero ||
                      quotedAt != null ||
                      fetchedAt == null ||
                      fetchedAt.isAfter(
                        snapshot.capturedAt.add(const Duration(minutes: 5)),
                      ))
                : (quotedAt == null || fetchedAt != null)) ||
            (!fact.value.dateOnly &&
                (quotedAt?.isAfter(
                      snapshot.capturedAt.add(const Duration(minutes: 5)),
                    ) ??
                    false)) ||
            (!fact.value.manual && fact.value.source.isEmpty)) {
          throw const FormatException('历史参考价依据不合法');
        }
        if (fact.value.dateOnly &&
            (value.units <= BigInt.zero ||
                fact.value.manual ||
                !security.isFund ||
                security.market != StockMarket.hk ||
                quotedAt == null ||
                !isHongKongQuoteDateAtOrBefore(
                  quotedAt,
                  snapshot.capturedAt,
                ))) {
          throw const FormatException('基金历史净值日期精度不合法');
        }
        value.toDouble();
      }
    }
    if (p.marketPriceIds.any((id) => !p.securities.any((s) => s.id == id))) {
      throw const FormatException('行情覆盖选择引用了不存在的证券');
    }
    final valuation = valueStocks(p, projection);
    if (valuation.marketValue == null) {
      throw const FormatException('投资持仓需要明确的手填参考价');
    }
    valuation.marketValue!.toDouble();
    // 多项持仓的合计也必须可展示，避免各项合法但冻结或盈亏合计溢出后落库。
    valuation.unrealized?.toDouble();
    projection.frozenMargin.toDouble();
    projection.realized.toDouble();
    projection.income.toDouble();
    for (final position in projection.positions) {
      position.cost?.toDouble();
    }
    for (final event in p.events.where((e) => e.batchId != null)) {
      batches.putIfAbsent(event.batchId!, () => []).add((p, event));
    }
  }
  for (final legs in batches.values) {
    if (legs.length != 2) throw const FormatException('持仓转移必须同时包含两端');
    final (a, x) = legs[0];
    final (b, y) = legs[1];
    if (a.accountId == b.accountId ||
        a.bookId != b.bookId ||
        a.currencyCode != b.currencyCode ||
        x.securityId != y.securityId ||
        x.quantity != y.quantity ||
        x.carriedCost != y.carriedCost ||
        x.short != y.short ||
        !x.occurredAt.isAtSameMomentAs(y.occurredAt) ||
        {x.kind, y.kind}.difference({
          StockEventKind.transferIn,
          StockEventKind.transferOut,
        }).isNotEmpty ||
        x.kind == y.kind) {
      throw const FormatException('持仓转移两端不一致');
    }
  }
}
