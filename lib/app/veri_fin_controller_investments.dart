part of 'veri_fin_controller.dart';

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
            quotedAt: ref?.time ?? at,
            manual: ref == null,
            source: ref == null ? '' : q!.source,
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
  Future<bool> enableInvestment({
    required String accountId,
    required String openingCash,
    DateTime? openedAt,
    List<StockSecurity> securities = const [],
    List<StockHolding> openingHoldings = const [],
    Map<String, String> manualPrices = const {},
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
      allowFinancing: allowFinancing,
    );
    return _saveInvestmentCandidates([..._investmentPortfolios, value]);
  });

  /// 保存或编辑股票事件；[event.id] 稳定保证重试幂等，编辑后重放全部后续事件。
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
        event.kind.index >= StockEventKind.optionBuyOpen.index ||
        event.securityId != security.id ||
        security.currencyCode != current.currencyCode) {
      return false;
    }
    final old = current.events.where((e) => e.id == event.id).firstOrNull;
    // 同一幂等 ID 只能编辑原证券，不能借股票入口替换已存在的期权事实。
    if (old?.batchId != null ||
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
        if (current == null || event == null || event.batchId != null) {
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

  /// 为未确认期初成本补值；不创造现金腿，不猜测历史成交。
  Future<bool> setStockOpeningCost(
    String accountId,
    String securityId,
    bool short,
    String cost,
  ) => _runInvestmentCommand(() async {
    final current = investmentFor(accountId);
    if (current == null) return false;
    if (!current.openingHoldings.any(
      (h) => h.securityId == securityId && h.short == short,
    )) {
      return false;
    }
    final next = current.copyWith(
      openingHoldings: [
        for (final h in current.openingHoldings)
          if (h.securityId == securityId && h.short == short)
            StockHolding(
              securityId: securityId,
              short: short,
              quantity: h.quantity,
              cost: InvestmentDecimal.parse(cost).toString(),
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
    // 历史转移会改变后续成本分配；先只接受位于两端现有记录之后的真实转移。
    if ([
      ...from.events,
      ...to.events,
    ].any((e) => e.occurredAt.isAfter(occurredAt))) {
      return false;
    }
    final holding = projectStocks(from).positions
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
        underlying.option != null ||
        security.option!.underlyingId != underlying.id ||
        event.securityId != security.id ||
        event.kind.index < StockEventKind.optionBuyOpen.index ||
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
  }) {
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
      return (portfolio: next, projection: projectStocks(next), cash: cash);
    } on FormatException {
      // 草稿预览失败是可接受的字段校验，页面显示本地化错误且不产生保存日志。
      return null;
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
      throw const FormatException('已有证券身份不能修改');
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
      if (a[field] != b[field]) throw const FormatException('已有合约定价及已结算规格不能改写');
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
    final projection = projectStocks(p);
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
        if (!p.securities.any((s) => s.id == fact.key) ||
            value.units < BigInt.zero ||
            fact.value.quotedAt.isAfter(
              snapshot.capturedAt.add(const Duration(minutes: 5)),
            ) ||
            (!fact.value.manual && fact.value.source.isEmpty)) {
          throw const FormatException('历史参考价依据不合法');
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
