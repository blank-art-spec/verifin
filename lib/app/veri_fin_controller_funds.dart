part of 'veri_fin_controller.dart';

/// 香港基金申请、实际扣款、确认及已有持仓的原子命令；不向普通收支表复制投资事实。
mixin _FundOps on _InvestmentOps {
  /// 检查 [security] 是当前 [portfolio] 的同币种香港基金，拒绝跨账户、股票及期权复用身份。
  void _requireFundSecurity(
    InvestmentPortfolio portfolio,
    StockSecurity security,
  ) {
    if (!security.isFund ||
        security.option != null ||
        security.market != StockMarket.hk ||
        security.currencyCode != portfolio.currencyCode) {
      throw const FormatException('请选择同币种的香港基金');
    }
    final existing = portfolio.securities
        .where((s) => s.id == security.id)
        .firstOrNull;
    if (existing != null &&
        (!existing.isFund ||
            existing.currencyCode != security.currencyCode ||
            existing.option != null)) {
      throw const FormatException('已有证券身份不能通过基金入口改写');
    }
  }

  /// [instant] 是用户核准的已发生时刻；预计确认日和收益起算日不使用本检查。
  /// 不接受未来实际扣款、确认或退款，防止草稿或预计日期直接影响当前现金。
  void _requireActualFundInstant(DateTime instant) {
    if (instant.isAfter(DateTime.now())) {
      throw const FormatException('实际申请、扣款或确认时刻不能晚于现在');
    }
  }

  /// 把单个 [candidate] 放回全量聚合，经统一重放/融资校验后原子保存，保持其他账户不变。
  Future<bool> _saveFundCandidate(InvestmentPortfolio candidate) =>
      _saveInvestmentCandidates([
        for (final portfolio in _investmentPortfolios)
          portfolio.accountId == candidate.accountId ? candidate : portfolio,
      ]);

  /// 新建或编辑申购申请；[cashAmount]、[paidAt] 在 [subscription] 内分别表达金额和实际扣款。
  /// 未扣款时不减少现金；扣款后形成在途资产而非份额。付款总额不得借普通编辑改写或撤回，
  /// 确认与取消必须走各自命令。可补正已付待确认的费用分配，但实际总扣款保持不变。
  Future<bool> saveFundSubscription({
    required String accountId,
    required StockSecurity security,
    required FundSubscription subscription,
  }) => _runInvestmentCommand(() async {
    final portfolio = investmentFor(accountId);
    if (portfolio == null || subscription.securityId != security.id) {
      return false;
    }
    _requireFundSecurity(portfolio, security);
    _requireActualFundInstant(subscription.requestedAt);
    if (subscription.paidAt != null) {
      _requireActualFundInstant(subscription.paidAt!);
    }
    final old = portfolio.fundSubscriptions
        .where((s) => s.id == subscription.id)
        .firstOrNull;
    if (old != null && old.securityId != subscription.securityId) return false;
    if (subscription.confirmation != null ||
        subscription.cancelledAt != null ||
        subscription.refundedAt != null ||
        subscription.refundAmount != null ||
        old?.confirmation != null ||
        old?.cancelledAt != null) {
      return false;
    }
    if (old?.paidAt != null &&
        (subscription.paidAt == null ||
            !subscription.paidAt!.isAtSameMomentAs(old!.paidAt!) ||
            InvestmentDecimal.parse(
                  subscription.cashAmount,
                ).compareTo(InvestmentDecimal.parse(old.cashAmount)) !=
                0)) {
      throw const FormatException('已实际扣款的总额与日期不能通过普通申请编辑撤回');
    }
    final next = portfolio.copyWith(
      securities: [
        ...portfolio.securities.where((s) => s.id != security.id),
        security,
      ],
      fundSubscriptions: [
        ...portfolio.fundSubscriptions.where((s) => s.id != subscription.id),
        subscription,
      ],
    );
    return _saveFundCandidate(next);
  });

  /// 用券商实际确认的 [confirmation] 核准指定 [subscriptionId]，不把公开最新净值当确认回执。
  /// [fee] 可补正实际扣款中包含的申购费用；总扣款不变。份额和净值可核对重填，稳定确认事件
  /// 只保留一条，现金腿始终为零；若收益起算在未来，份额到实际生效时刻才参与当前估值。
  /// [quantityInferred] 标识仍采用金额反推的份额；保存、编辑和备份不能把估算冒充券商回执。
  Future<bool> confirmFundSubscription({
    required String accountId,
    required String subscriptionId,
    required FundSubscriptionConfirmation confirmation,
    String? fee,
    bool quantityInferred = false,
  }) => _runInvestmentCommand(() async {
    final portfolio = investmentFor(accountId);
    final old = portfolio?.fundSubscriptions
        .where((s) => s.id == subscriptionId)
        .firstOrNull;
    if (portfolio == null ||
        old == null ||
        old.paidAt == null ||
        old.cancelledAt != null) {
      return false;
    }
    _requireActualFundInstant(confirmation.confirmedAt);
    final security = portfolio.securities.firstWhere(
      (s) => s.id == old.securityId,
    );
    _requireFundSecurity(portfolio, security);
    final subscription = old.copyWith(confirmation: confirmation, fee: fee);
    final existing = portfolio.events
        .where(
          (event) =>
              event.kind == StockEventKind.fundAcquire &&
              event.fundSubscriptionId == subscriptionId,
        )
        .firstOrNull;
    final event = StockEvent(
      id: existing?.id ?? 'fund-confirm:$subscriptionId',
      securityId: security.id,
      kind: StockEventKind.fundAcquire,
      occurredAt: fundSubscriptionEffectiveAt(subscription)!,
      sequence: existing?.sequence ?? _nextStockSequence(portfolio),
      quantity: confirmation.quantity,
      price: confirmation.nav,
      carriedCost: subscription.cashAmount,
      fundSubscriptionId: subscriptionId,
      fundNavDate: confirmation.navDate,
      quantityInferred: quantityInferred,
    );
    if (portfolio.events.any(
      (value) => value.id == event.id && value != existing,
    )) {
      return false;
    }
    final next = portfolio.copyWith(
      fundSubscriptions: [
        for (final value in portfolio.fundSubscriptions)
          value.id == subscriptionId ? subscription : value,
      ],
      events: [
        ...portfolio.events.where((value) => value.id != event.id),
        event,
      ],
      // 确认净值是已核准的后备依据，不撤销此前的逐证券行情采用选择。
      manualPrices: {
        ...portfolio.manualPrices,
        if (!portfolio.manualPrices.containsKey(security.id))
          security.id: confirmation.nav,
      },
    );
    return _saveFundCandidate(next);
  });

  /// 撤销尚未确认的 [subscriptionId]；[cancelledAt] 是实际撤销时刻。
  /// 已扣款未退款时继续保留在途资产，只有实际 [refundedAt]/[refundAmount] 同时提供才加回现金；
  /// 后续补录退款沿用原申请，不能再次返还或把未到账金额当损失。确认后应记录卖出，不能取消。
  Future<bool> cancelFundSubscription({
    required String accountId,
    required String subscriptionId,
    required DateTime cancelledAt,
    DateTime? refundedAt,
    String? refundAmount,
  }) => _runInvestmentCommand(() async {
    final portfolio = investmentFor(accountId);
    final old = portfolio?.fundSubscriptions
        .where((s) => s.id == subscriptionId)
        .firstOrNull;
    if (portfolio == null || old == null || old.confirmation != null) {
      return false;
    }
    _requireActualFundInstant(cancelledAt);
    if (refundedAt != null) _requireActualFundInstant(refundedAt);
    if (old.refundedAt != null &&
        (refundedAt == null ||
            !old.refundedAt!.isAtSameMomentAs(refundedAt) ||
            refundAmount == null ||
            InvestmentDecimal.parse(
                  old.refundAmount!,
                ).compareTo(InvestmentDecimal.parse(refundAmount)) !=
                0)) {
      throw const FormatException('已到账的基金退款不能重复返还或通过取消撤回');
    }
    final next = portfolio.copyWith(
      fundSubscriptions: [
        for (final value in portfolio.fundSubscriptions)
          value.id == subscriptionId
              ? value.copyWith(
                  cancelledAt: cancelledAt,
                  // 已到账的同值重试保留原始事实文本与时刻，不因键盘补尾零变成第二次退款。
                  refundedAt: old.refundedAt ?? refundedAt,
                  refundAmount: old.refundAmount ?? refundAmount,
                )
              : value,
      ],
    );
    return _saveFundCandidate(next);
  });

  /// 只删除从未实际扣款、未确认的 [subscriptionId] 申请；有资金事实的申请须保留付款及退款依据。
  Future<bool> deleteFundSubscription({
    required String accountId,
    required String subscriptionId,
  }) => _runInvestmentCommand(() async {
    final portfolio = investmentFor(accountId);
    final subscription = portfolio?.fundSubscriptions
        .where((s) => s.id == subscriptionId)
        .firstOrNull;
    if (portfolio == null ||
        subscription == null ||
        subscription.paidAt != null ||
        subscription.confirmation != null ||
        subscription.refundedAt != null) {
      return false;
    }
    return _saveFundCandidate(
      portfolio.copyWith(
        fundSubscriptions: portfolio.fundSubscriptions
            .where((s) => s.id != subscriptionId)
            .toList(),
      ),
    );
  });

  /// 保存或编辑已有基金持仓的 [event] 基准，份额/成本在基准日替换而非叠加，不产生现金扣款。
  /// [referencePrice] 是用户核对的基准后备净值；录入浮盈只保留证据，不另外生成收入或费用。
  /// 同日开户时截点不早于账户启用时刻；更早的基准不能用来回填不存在的账户历史。
  Future<bool> saveFundHoldingBaseline({
    required String accountId,
    required StockSecurity security,
    required StockEvent event,
    required String referencePrice,
  }) => _runInvestmentCommand(() async {
    final portfolio = investmentFor(accountId);
    if (portfolio == null ||
        event.kind != StockEventKind.fundHoldingBaseline ||
        event.securityId != security.id ||
        event.fundSubscriptionId != null) {
      return false;
    }
    _requireFundSecurity(portfolio, security);
    _requireActualFundInstant(event.occurredAt);
    final old = portfolio.events.where((e) => e.id == event.id).firstOrNull;
    if (old != null &&
        (old.kind != StockEventKind.fundHoldingBaseline ||
            old.securityId != security.id)) {
      return false;
    }
    var effectiveAt = event.occurredAt;
    if (effectiveAt.isBefore(portfolio.openedAt) &&
        hongKongFundDate(effectiveAt) == hongKongFundDate(portfolio.openedAt)) {
      effectiveAt = portfolio.openedAt;
    }
    final normalized = StockEvent.fromJson({
      ...event.toJson(),
      'sequence': old?.sequence ?? _nextStockSequence(portfolio),
      'occurredAt': effectiveAt.toIso8601String(),
    });
    final next = portfolio.copyWith(
      securities: [
        ...portfolio.securities.where((s) => s.id != security.id),
        security,
      ],
      events: [...portfolio.events.where((e) => e.id != event.id), normalized],
      manualPrices: {
        ...portfolio.manualPrices,
        security.id: InvestmentDecimal.parse(referencePrice).toString(),
      },
    );
    return _saveFundCandidate(next);
  });
}
