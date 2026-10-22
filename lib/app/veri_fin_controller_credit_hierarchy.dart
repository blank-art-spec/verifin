part of 'veri_fin_controller.dart';

/// 信用父子账户、参考折算、联网汇率和统一还款；所有写入仍通过仓储原子提交。
mixin _CreditHierarchyOps on ChangeNotifier, _ControllerState, _ControllerOps {
  bool _rateSyncRunning = false;
  bool _rateSyncFailed = false;
  bool get rateSyncRunning => _rateSyncRunning;
  bool get rateSyncFailed => _rateSyncFailed;
  @override
  Future<void> refreshExchangeRatesIfEnabled() async {
    await syncExchangeRates(force: false);
  }

  bool get autoExchangeRates => _store.read(_autoExchangeRatesKey) == 'true';
  DateTime? get lastRateSync => DateTime.tryParse(
    _store.read('$_exchangeRateSyncPrefix$_activeBookId.v1') ?? '',
  );

  Future<void> setAutoExchangeRates(bool enabled) async {
    _store.write(_autoExchangeRatesKey, enabled.toString());
    notifyListeners();
    if (enabled) await syncExchangeRates();
  }

  /// 前台每天检查一次，失败保留所有缓存。捕获账本 id 防止等待网络时切账串写。
  Future<bool> syncExchangeRates({
    bool force = true,
    FrankfurterClient client = const FrankfurterClient(),
  }) async {
    if (_rateSyncRunning || (!force && !autoExchangeRates)) return false;
    final book = activeBook;
    final generation = _rateSyncGeneration;
    final now = DateTime.now();
    final attemptKey = '$_exchangeRateAttemptPrefix${book.id}.v1';
    if (!force && _store.read(attemptKey) == currencyDateKey(now)) return true;
    final currencies = <String>{
      for (final account in accounts)
        if (account.currencyCode != book.baseCurrencyCode) account.currencyCode,
      for (final entry in entries)
        if (entry.currencyCode != book.baseCurrencyCode) entry.currencyCode,
      for (final rate in exchangeRates) rate.currencyCode,
    };
    _rateSyncRunning = true;
    _rateSyncFailed = false;
    notifyListeners();
    try {
      _store.write(attemptKey, currencyDateKey(now));
      final observations = await client.fetch(
        base: book.baseCurrencyCode,
        currencies: currencies,
      );
      if (_controllerDisposed || generation != _rateSyncGeneration) {
        return false;
      }
      return await _enqueueCaptureMutation(() async {
        if (_controllerDisposed || generation != _rateSyncGeneration) {
          return false;
        }
        if (!_ledgerBooks.any(
          (b) => b.id == book.id && b.baseCurrencyCode == book.baseCurrencyCode,
        )) {
          return false;
        }
        final next = List<ExchangeRate>.of(_exchangeRates);
        for (final observation in observations) {
          final index = next.indexWhere(
            (r) =>
                r.bookId == book.id &&
                r.currencyCode == observation.currency &&
                r.baseCurrencyCode == book.baseCurrencyCode &&
                currencyDateKey(r.effectiveDate) ==
                    currencyDateKey(observation.date),
          );
          if (index >= 0 && next[index].source != ExchangeRateSource.online) {
            continue;
          }
          final rate = ExchangeRate(
            id: index >= 0 ? next[index].id : _generateId('online-rate'),
            bookId: book.id,
            baseCurrencyCode: book.baseCurrencyCode,
            currencyCode: observation.currency,
            effectiveDate: observation.date,
            rateToBase: observation.rate,
            source: ExchangeRateSource.online,
            createdAt: index >= 0 ? next[index].createdAt : now,
            updatedAt: now,
          );
          if (index >= 0) {
            next[index] = rate;
          } else {
            next.add(rate);
          }
        }
        if (!await _runTrackedWrite(
          () => _repository.saveExchangeRates(next),
        )) {
          _rateSyncFailed = true;
          return false;
        }
        _exchangeRates
          ..clear()
          ..addAll(next);
        _store.write(
          '$_exchangeRateSyncPrefix${book.id}.v1',
          now.toIso8601String(),
        );
        return true;
      });
    } catch (error) {
      _rateSyncFailed = true;
      _logger?.error(
        'Exchange rate sync failed; cached observations retained',
        source: 'Frankfurter',
        error: error,
      );
      return false;
    } finally {
      _rateSyncRunning = false;
      if (!_controllerDisposed) notifyListeners();
    }
  }

  ({List<LedgerEntry> entries, Set<String> missing}) get _currentStatistics {
    final now = DateTime.now();
    final date = currencyDateKey(now);
    if (_statisticsProjectionDate != date) {
      _statisticsProjection = null;
    }
    _statisticsProjectionDate = date;
    return _statisticsProjection ??= projectStatisticsCurrency(
      entries: entries,
      book: activeBook,
      rates: exchangeRates,
      now: now,
    );
  }

  @override
  List<LedgerEntry> get statisticsEntries => _currentStatistics.entries;
  Set<String> get missingStatisticsCurrencies => _currentStatistics.missing;
  Set<String> get legacyCreditAccountsNeedingReview =>
      normalizeCreditHierarchy(accounts, creditAccounts).unresolvedAccountIds;

  /// 父账户汇总采用账本本币；额度的原币设置仍保留在持久化主体中。
  CreditAccount creditSummaryAccount(CreditAccount parent) {
    final result = parent.cycleBudget == null
        ? null
        : convertAmount(
            amount: parent.cycleBudget!,
            sourceCurrencyCode: parent.currencyCode,
            targetCurrencyCode: activeBook.baseCurrencyCode,
            date: DateTime.now(),
          );
    return parent.copyWith(
      currencyCode: activeBook.baseCurrencyCode,
      cycleBudget: result is ConvertedCurrencyAmount ? result.amount : null,
      clearCycleBudget: result is! ConvertedCurrencyAmount,
    );
  }

  Future<bool> upgradeCreditHierarchy() async {
    final next = normalizeCreditHierarchy(_accounts, _creditAccounts);
    if (jsonEncode(next.accounts.map((a) => a.toJson()).toList()) ==
            jsonEncode(_accounts.map((a) => a.toJson()).toList()) &&
        jsonEncode(next.parents.map((p) => p.toJson()).toList()) ==
            jsonEncode(_creditAccounts.map((p) => p.toJson()).toList())) {
      return true;
    }
    if (!await _runTrackedWrite(
      () => _repository.saveCreditAccountAggregate(
        accounts: next.accounts,
        creditAccounts: next.parents,
      ),
    )) {
      return false;
    }
    _accounts
      ..clear()
      ..addAll(next.accounts);
    _creditAccounts
      ..clear()
      ..addAll(next.parents);
    notifyListeners();
    return true;
  }

  /// 兼容既有信用调用；[id] 是主体 id，[statistics] 决定是否读取统计折算投影。
  List<LedgerEntry> entriesForCreditParent(
    String id, {
    bool statistics = false,
  }) => entriesForParent(id, statistics: statistics);

  /// 合并 [id] 主账户下所有子账户流水，内部转账只出现一次。
  /// [statistics] 为 true 时使用统计投影；读取不会改写交易或账户余额。
  List<LedgerEntry> entriesForParent(String id, {bool statistics = false}) {
    final ids = accountsForCreditAccount(id).map((a) => a.id).toSet();
    final source = statistics ? statisticsEntries : entries;
    return source
        .where((e) => ids.contains(e.accountId) || ids.contains(e.toAccountId))
        .toList()
      ..sort(_compareEntriesLatestFirst);
  }

  /// 为 [parentId] 确保币种 [currencyCode] 的真实子账户存在。
  /// 银行、证券与信用主账户共用此入口；已有币种直接返回，新增初始余额为零。
  /// 主体 id 永远不能写入交易 accountId，也不会因此创建任何流水。
  Future<Account?> ensureCurrencyChild(String parentId, String currencyCode) =>
      _enqueueCaptureMutation(() async {
        final parent = accountParents
            .where((p) => p.id == parentId)
            .firstOrNull;
        if (parent == null || !CurrencyCatalog.isSupported(currencyCode)) {
          return null;
        }
        final existing = accountsForCreditAccount(
          parentId,
        ).where((a) => a.currencyCode == currencyCode).firstOrNull;
        if (existing != null) return existing;
        final template = accountsForCreditAccount(parentId).firstOrNull;
        if (template == null) return null;
        final child = template.copyWith(
          id: _generateId('credit-child'),
          name: '${parent.name}.$currencyCode',
          currencyCode: currencyCode,
          initialBalance: 0,
          hidden: false,
          cardNumber: '',
          clearCreditLimit: currencyCode != parent.currencyCode,
        );
        return await addAccountDraft(child)
            ? accounts.firstWhere((a) => a.id == child.id)
            : null;
      });

  /// 兼容既有信用调用；[parentId] 与 [currencyCode] 转交统一币种子账户入口。
  Future<Account?> ensureCreditCurrencyChild(
    String parentId,
    String currencyCode,
  ) => ensureCurrencyChild(parentId, currencyCode);

  /// 为旧独立账户 [account] 启用多币种主体；只新增主体与关联，不更改账户 id、金额或流水。
  /// 用户显式点击后才调用；主体与关联在同一事务保存，失败时不改变内存。
  Future<CreditAccount?> enableCurrencyChildren(Account account) =>
      _enqueueCaptureMutation(() async {
        final current = accounts.where((a) => a.id == account.id).firstOrNull;
        if (current == null || !current.type.supportsCurrencyChildren) {
          return null;
        }
        final existing = parentForAccount(current);
        if (existing != null) return existing;
        final parent = _creditAccountFromLegacyAccount(current);
        final next = [
          for (final item in _accounts)
            item.id == current.id
                ? item.copyWith(creditAccountId: parent.id)
                : item,
        ];
        if (!await _runTrackedWrite(
          () => _repository.saveCreditAccountAggregate(
            accounts: next,
            creditAccounts: [..._creditAccounts, parent],
          ),
        )) {
          return null;
        }
        _accounts
          ..clear()
          ..addAll(next);
        _creditAccounts.add(parent);
        notifyListeners();
        return parent;
      });

  /// 按 [parent] 的展示币种估值；[visibleOnly] 为 true 时不包含已隐藏的子账户。
  /// 普通主账户使用自身主币种，信用账户沿用账本本币；缺率时返回不完整结果。
  ConvertedAccountBalances parentAccountBalances(
    CreditAccount parent, {
    bool visibleOnly = false,
  }) {
    final children = accountsForCreditAccount(parent.id);
    return convertAccountBalancesToBase(
      accounts: children.where((a) => !visibleOnly || !a.hidden),
      balanceOf: accountBalance,
      bookId: _activeBookId,
      baseCurrencyCode: activeBook.baseCurrencyCode,
      targetCurrencyCode: children.any((a) => a.type.supportsCredit)
          ? activeBook.baseCurrencyCode
          : parent.currencyCode,
      date: DateTime.now(),
      rates: _exchangeRates,
    );
  }

  /// 明确确认参考金额，原子修改原消费并保留审计与退款证据。
  Future<EntrySaveResult> confirmReferenceAmount(
    String entryId,
    double amount,
  ) async {
    final entry = entries.where((e) => e.id == entryId).firstOrNull;
    if (entry == null || !amount.isFinite || amount <= 0) {
      return const EntrySaveValidationFailure(
        EntryValidationCode.invalidAmounts,
      );
    }
    return saveEntryAggregateDraftResult(
      entry: entry.copyWith(
        referenceBaseAmount: normalizeCurrencyAmount(
          amount,
          activeBook.baseCurrencyCode,
        ),
        baseAmount: normalizeCurrencyAmount(
          amount,
          activeBook.baseCurrencyCode,
        ),
      ),
      isNew: false,
      refunds: refundsForEntry(entryId),
      attachments: attachmentsForEntry(entryId),
    );
  }

  List<CreditRepaymentLine> creditRepaymentDefaults(
    String parentId,
    CreditRepaymentScope scope,
  ) => [
    for (final account in accountsForCreditAccount(parentId))
      CreditRepaymentLine(
        accountId: account.id,
        amount: scope == CreditRepaymentScope.current
            ? creditOverview(account).billedOutstanding
            : (-accountBalance(account)).clamp(0.0, double.infinity),
      ),
  ];

  /// 全额结清当前所有币种账单豁免；部分还款与超出账单的消费必须有明确参考额。
  /// 正式账单内按时间先后抵扣已还款；未出账部分按剩余原币债务反推未付流水。
  @override
  List<LedgerEntry> repaymentMissingReferences(
    String parentId,
    List<CreditRepaymentLine> lines,
  ) {
    final children = accountsForCreditAccount(parentId);
    final amounts = {for (final line in lines) line.accountId: line.amount};
    final partialCurrent = children.any(
      (a) =>
          (amounts[a.id] ?? 0) + currencyAmountTolerance(a.currencyCode) <
          creditOverview(a).billedOutstanding,
    );
    final missing = <String, LedgerEntry>{};
    for (final account in children) {
      final overview = creditOverview(account);
      final outside =
          (amounts[account.id] ?? 0) >
          overview.billedOutstanding +
              currencyAmountTolerance(account.currencyCode);
      if (!partialCurrent && !outside) continue;
      final statements = billingStatementsForAccount(account.id);
      final expenses =
          entries
              .where(
                (e) => e.accountId == account.id && e.type == EntryType.expense,
              )
              .toList()
            ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
      double net(LedgerEntry expense) {
        final refunds = entries
            .where(
              (r) =>
                  r.isSettledRefund &&
                  r.refundOf == expense.id &&
                  r.accountId == account.id,
            )
            .fold<double>(0, (sum, r) => sum + (r.accountAmount ?? r.amount));
        return ((expense.accountAmount ?? expense.amount) - refunds).clamp(
          0.0,
          double.infinity,
        );
      }

      void add(LedgerEntry e) {
        if (e.currencyCode != activeBook.baseCurrencyCode &&
            e.referenceBaseAmount == null) {
          missing[e.id] = e;
        }
      }

      if (partialCurrent) {
        for (final statement in statements) {
          if (_statementOutstandingWithRefunds(statement) <=
              currencyAmountTolerance(account.currencyCode)) {
            continue;
          }
          var paid = statement.paidAmount;
          for (final e in expenses.where(
            (e) => creditExpenseBelongsToStatement(e, statement),
          )) {
            final amount = net(e);
            if (paid + currencyAmountTolerance(account.currencyCode) >=
                amount) {
              paid -= amount;
            } else {
              paid = 0;
              add(e);
            }
          }
        }
        // 没有银行正式账单的历史结转仍属于当前待还，不能绕过部分还款校验。
        var scheduledUnpaid =
            (overview.billedOutstanding -
                    statements.fold<double>(
                      0,
                      (sum, s) => sum + _statementOutstandingWithRefunds(s),
                    ))
                .clamp(0.0, double.infinity);
        if (account.statementDay != null) {
          final today = dateOnly(DateTime.now());
          for (final e in expenses.reversed.where((e) {
            final cycle = e.billingCycleId == null
                ? billingStatementDateForExpense(
                    account.statementDay!,
                    e.occurredAt,
                  )
                : DateTime.tryParse(e.billingCycleId!);
            if (cycle == null || cycle.isAfter(today)) return false;
            return !statements.any(
              (s) =>
                  billingCycleIdFor(s.statementDate) ==
                      billingCycleIdFor(cycle) ||
                  creditExpenseBelongsToStatement(e, s),
            );
          })) {
            if (scheduledUnpaid <=
                currencyAmountTolerance(account.currencyCode)) {
              break;
            }
            final value = net(e);
            if (value > 0) {
              add(e);
              scheduledUnpaid -= value;
            }
          }
        }
      }
      if (outside) {
        final cutoff = statements
            .map((s) => s.periodEnd)
            .fold<DateTime?>(
              null,
              (last, d) => last == null || d.isAfter(last) ? d : last,
            );
        var unpaid = (-accountBalance(account) - overview.billedOutstanding)
            .clamp(0.0, double.infinity);
        for (final e in expenses.reversed.where(
          (e) =>
              !statements.any((s) => creditExpenseBelongsToStatement(e, s)) &&
              (cutoff == null ||
                  (e.billingCycleId == null
                          ? dateOnly(e.occurredAt)
                          : DateTime.tryParse(e.billingCycleId!) ??
                                dateOnly(e.occurredAt))
                      .isAfter(dateOnly(cutoff))),
        )) {
          if (unpaid <= currencyAmountTolerance(account.currencyCode)) break;
          final value = net(e);
          if (value > 0) {
            add(e);
            unpaid -= value;
          }
        }
      }
    }
    return missing.values.toList()..sort(_compareEntriesLatestFirst);
  }

  /// 编辑整批还款时，以撤销该批次后的原始欠款检查所需的折算记录。
  List<LedgerEntry> repaymentDraftMissingReferences(
    String parentId,
    List<CreditRepaymentLine> lines, {
    String? batchId,
  }) {
    if (batchId == null) return repaymentMissingReferences(parentId, lines);
    final old = _entries
        .where((e) => e.repaymentBatchId == batchId)
        .map((e) => e.id)
        .toSet();
    final entrySnapshot = List<LedgerEntry>.of(_entries);
    final statementSnapshot = List<BillingStatement>.of(_billingStatements);
    final reverted = <String, double>{};
    for (final a in _statementRepaymentAllocations.where(
      (a) => old.contains(a.repaymentEntryId),
    )) {
      reverted[a.statementId] = (reverted[a.statementId] ?? 0) + a.amount;
    }
    try {
      _entries.removeWhere((e) => old.contains(e.id));
      _billingStatements.replaceRange(
        0,
        _billingStatements.length,
        statementSnapshot.map(
          (s) => s.copyWith(
            paidAmount: (s.paidAmount - (reverted[s.id] ?? 0)).clamp(
              0.0,
              s.statementAmount,
            ),
          ),
        ),
      );
      _invalidateDerivedViews();
      return repaymentMissingReferences(parentId, lines);
    } finally {
      _entries
        ..clear()
        ..addAll(entrySnapshot);
      _billingStatements
        ..clear()
        ..addAll(statementSnapshot);
      _invalidateDerivedViews();
    }
  }

  /// 一次仓储事务保存全部币种还款；转出金额为各币种的实际扣款分摊，总和只扣一次。
  /// 替换旧批次先在快照中回退旧分配，失败时内存和数据库都保持原批次。
  Future<EntrySaveResult> recordCreditRepaymentBatch({
    required String batchId,
    required String parentId,
    required List<CreditRepaymentLine> lines,
    required DateTime occurredAt,
    OccurredAtPrecision occurredAtPrecision = OccurredAtPrecision.minute,
    String fromAccountId = '',
    String note = '',
    bool replace = false,
  }) => _enqueueCaptureMutation(() async {
    const invalid = EntrySaveValidationFailure(
      EntryValidationCode.invalidAmounts,
    );
    final old = _entries.where((e) => e.repaymentBatchId == batchId).toList();
    if (batchId.isEmpty || replace && old.isEmpty) return invalid;
    if (!replace && old.isNotEmpty) {
      final repeated =
          old.length == lines.where((l) => l.amount > 0).length &&
          old.every(
            (e) =>
                e.accountId == fromAccountId &&
                e.note == note.trim() &&
                e.occurredAt == occurredAt &&
                e.occurredAtPrecision == occurredAtPrecision &&
                lines.any(
                  (l) =>
                      l.accountId == e.toAccountId &&
                      l.amount == e.toAccountAmount &&
                      (l.sourceAmount == null || l.sourceAmount == e.amount),
                ),
          );
      return repeated
          ? const EntrySaveSuccess()
          : const EntrySaveValidationFailure(EntryValidationCode.staleDraft);
    }
    final children = accountsForCreditAccount(parentId);
    final byId = {for (final a in children) a.id: a};
    final source = accounts
        .where((a) => a.id == fromAccountId && !a.hidden)
        .firstOrNull;
    final category = categoriesForType(EntryType.transfer).firstOrNull;
    if (category == null ||
        fromAccountId.isNotEmpty &&
            (source == null || byId.containsKey(source.id)) ||
        lines.map((l) => l.accountId).toSet().length != lines.length ||
        lines.isEmpty) {
      return invalid;
    }
    final oldIds = old.map((e) => e.id).toSet();
    final reverted = <String, double>{};
    for (final a in _statementRepaymentAllocations.where(
      (a) => oldIds.contains(a.repaymentEntryId),
    )) {
      reverted[a.statementId] = (reverted[a.statementId] ?? 0) + a.amount;
    }
    var statements = _billingStatements.map((s) {
      final next = s.copyWith(
        paidAmount: (s.paidAmount - (reverted[s.id] ?? 0)).clamp(
          0.0,
          s.statementAmount,
        ),
      );
      return next.copyWith(status: normalizedStatementStatus(next));
    }).toList();
    var allocations = _statementRepaymentAllocations
        .where((a) => !oldIds.contains(a.repaymentEntryId))
        .toList();
    // 编辑校验采用撤销旧批次后的快照，恢复后再作任何异步写入。
    final originalStatements = List<BillingStatement>.of(_billingStatements);
    final originalEntries = List<LedgerEntry>.of(_entries);
    List<LedgerEntry> missing;
    try {
      _billingStatements
        ..clear()
        ..addAll(statements);
      _entries.removeWhere((e) => oldIds.contains(e.id));
      _invalidateDerivedViews();
      missing = repaymentMissingReferences(parentId, lines);
      for (final line in lines) {
        final account = byId[line.accountId];
        if (account == null ||
            !line.amount.isFinite ||
            line.amount < 0 ||
            line.amount >
                (-accountBalance(account)).clamp(0.0, double.infinity) +
                    currencyAmountTolerance(account.currencyCode)) {
          return invalid;
        }
      }
    } finally {
      _billingStatements
        ..clear()
        ..addAll(originalStatements);
      _entries
        ..clear()
        ..addAll(originalEntries);
      _invalidateDerivedViews();
    }
    if (missing.isNotEmpty) return invalid;
    final additions = <LedgerEntry>[];
    for (final line in lines.where((l) => l.amount > 0)) {
      final account = byId[line.accountId]!;
      final amount = normalizeCurrencyAmount(line.amount, account.currencyCode);
      final sourceCode = source?.currencyCode ?? account.currencyCode;
      final debit = sourceCode == account.currencyCode
          ? amount
          : line.sourceAmount;
      if (debit == null || !debit.isFinite || debit <= 0) return invalid;
      final entry = LedgerEntry(
        id: '$batchId:${account.id}',
        bookId: activeBook.id,
        type: EntryType.transfer,
        amount: normalizeCurrencyAmount(debit, sourceCode),
        currencyCode: sourceCode,
        accountAmount: source == null
            ? null
            : normalizeCurrencyAmount(debit, sourceCode),
        toAccountAmount: amount,
        baseAmount: 0,
        conversionSource: sourceCode == account.currencyCode
            ? ConversionSource.identity
            : line.conversionSource,
        categoryId: category.id,
        accountId: fromAccountId,
        toAccountId: account.id,
        note: note.trim(),
        occurredAt: occurredAt,
        occurredAtPrecision: occurredAtPrecision,
        repaymentBatchId: batchId,
      );
      final plan = _planRepaymentToStatements(
        entry: entry,
        account: account,
        repaymentAmount: amount,
        statements: statements,
        allocations: allocations,
      );
      if (plan == null) return invalid;
      statements = plan.statements;
      allocations = plan.allocations;
      additions.add(
        appendEntryAudit(
          before: old.where((e) => e.id == entry.id).firstOrNull,
          after: entry,
          actor: EntryAuditActor.user,
          reason: replace ? EntryAuditReason.edited : EntryAuditReason.created,
          at: DateTime.now(),
        ),
      );
    }
    if (additions.isEmpty ||
        validateLedgerEntries(
              books: [activeBook],
              accounts: accounts,
              entries: additions,
              requireMinorUnitNormalization: true,
            ) !=
            null) {
      return invalid;
    }
    final nextEntries = [
      ..._entries.where((e) => !oldIds.contains(e.id)),
      ...additions,
    ]..sort(_compareEntriesLatestFirst);
    if (!await _runTrackedWrite(
      () => _repository.saveCreditAggregate(
        entries: nextEntries,
        statements: statements,
        allocations: allocations,
      ),
    )) {
      return const EntrySavePersistenceFailure();
    }
    _entries
      ..clear()
      ..addAll(nextEntries);
    _billingStatements
      ..clear()
      ..addAll(statements);
    _statementRepaymentAllocations
      ..clear()
      ..addAll(allocations);
    notifyListeners();
    onEntryAdded?.call();
    return const EntrySaveSuccess();
  });
}
