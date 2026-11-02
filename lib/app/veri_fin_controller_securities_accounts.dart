part of 'veri_fin_controller.dart';

/// 证券账户创建：资料、可选主账户及期初组合必须共同成功，取消时不留半套数据。
mixin _SecuritiesAccountOps on _InvestmentOps {
  /// 新建真实币种证券账户 [account]，并用已核对的 [openingCash] 初始化现金。
  /// [openedAt] 是期初核对时刻；初始持仓为空，之后通过原有股票/期权/基金命令录入。
  /// 调用方应保持 account.id 稳定以防重复点击；目标必须仍为当前账本。
  Future<bool> createSecuritiesAccount({
    required Account account,
    required String openingCash,
    DateTime? openedAt,
  }) => _runInvestmentCommand(() async {
    if (account.bookId != _activeBookId ||
        !account.type.supportsSecurities ||
        account.name.trim().isEmpty ||
        _accounts.any((value) => value.id == account.id) ||
        !_isAccountCurrencyAllowed(account)) {
      return false;
    }
    var normalized = _normalizeAccountCurrencyAmounts(
      account.copyWith(name: account.name.trim(), initialBalance: 0),
    );
    if (!_hasValidCreditAccountLink(normalized)) return false;
    CreditAccount? createdParent;
    if (normalized.creditAccountId == null ||
        normalized.creditAccountId!.isEmpty) {
      createdParent = _creditAccountFromLegacyAccount(normalized);
      if (_creditAccounts.any((value) => value.id == createdParent!.id)) {
        return false;
      }
      normalized = normalized.copyWith(creditAccountId: createdParent.id);
    }
    final exactCash = InvestmentDecimal.parse(openingCash);
    if (exactCash.units < BigInt.zero) {
      throw const FormatException('新建证券账户的期初现金不能为负数');
    }
    final cash = exactCash.rounded(
      CurrencyCatalog.require(normalized.currencyCode).minorUnit,
    );
    final portfolio = InvestmentPortfolio(
      accountId: normalized.id,
      bookId: normalized.bookId,
      currencyCode: normalized.currencyCode,
      openedAt: openedAt ?? DateTime.now(),
      openingCash: cash.toString(),
      securities: const [],
      openingHoldings: const [],
      events: const [],
      manualPrices: const {},
    );
    final nextAccounts = [..._accounts, normalized];
    final nextParents = [..._creditAccounts, ?createdParent];
    final nextPortfolios = [..._investmentPortfolios, portfolio];
    validateInvestmentPortfolios(nextPortfolios, nextAccounts);
    if (!await _runTrackedWrite(
      () => _repository.saveSecuritiesAccountAggregate(
        creditAccounts: nextParents,
        accounts: nextAccounts,
        investmentPortfolios: nextPortfolios,
      ),
    )) {
      return false;
    }
    _accounts
      ..clear()
      ..addAll(nextAccounts);
    _creditAccounts
      ..clear()
      ..addAll(nextParents);
    _investmentPortfolios
      ..clear()
      ..addAll(nextPortfolios);
    notifyListeners();
    return true;
  });
}
