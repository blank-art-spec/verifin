import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../app/account_icon_assets.dart';
import '../app/models.dart';
import 'app_database.dart';

/// 账目类全量数据快照。用于「导入/恢复/重置/删账本」这类需要一次性原子替换
/// 多张表的场景——见 [LedgerRepository.replaceAllLedgerData]。
class LedgerDataSnapshot {
  const LedgerDataSnapshot({
    required this.books,
    required this.accounts,
    required this.accountGroups,
    required this.categories,
    required this.tags,
    required this.attachments,
    required this.entries,
    required this.recurringRules,
    required this.monthlyBudgets,
    required this.categoryBudgets,
    required this.dailyBudgets,
    this.exchangeRates = const <ExchangeRate>[],
    this.balanceAnchors = const <BalanceAnchor>[],
    this.billingStatements = const <BillingStatement>[],
    this.statementRepaymentAllocations = const <StatementRepaymentAllocation>[],
    this.creditAccounts = const <CreditAccount>[],
  });

  final List<LedgerBook> books;
  final List<Account> accounts;
  final List<AccountGroup> accountGroups;
  final List<Category> categories;
  final List<Tag> tags;
  final List<Attachment> attachments;
  final List<LedgerEntry> entries;
  final List<RecurringRule> recurringRules;
  final Map<String, double> monthlyBudgets;
  final Map<String, double> categoryBudgets;
  final Map<String, double> dailyBudgets;
  final List<ExchangeRate> exchangeRates;
  final List<BalanceAnchor> balanceAnchors;
  final List<BillingStatement> billingStatements;
  final List<StatementRepaymentAllocation> statementRepaymentAllocations;
  final List<CreditAccount> creditAccounts;
}

/// 账目类数据仓储接口。生产实现为 [SqliteLedgerRepository]；测试可注入内存实现，
/// 避免真实异步 I/O 与 widget 测试的 fake-async 冲突。
///
/// 语义为「整表覆盖」：每次 saveX 以传入列表整体替换该类数据。
abstract interface class LedgerRepository {
  Future<List<LedgerEntry>> loadEntries();
  Future<void> saveEntries(List<LedgerEntry> entries);

  /// 读取设备本地的原始采集事件。事件不进入账本备份，但必须跨进程重启保留。
  Future<List<CaptureEvent>> loadCaptureEvents();

  /// 以传入列表整体替换采集事件表。
  Future<void> saveCaptureEvents(List<CaptureEvent> events);

  /// 读取当前设备上的自动识别规则。
  Future<List<AutoCaptureRule>> loadAutoCaptureRules();

  /// 以传入列表整体替换自动识别规则表。
  Future<void> saveAutoCaptureRules(List<AutoCaptureRule> rules);

  /// 原子保存原始事件与规则。
  ///
  /// 删除账户、分类或标签时，两张表的候选/动作引用必须一起清理，避免只成功一半。
  Future<void> saveAutoCaptureMetadata({
    required List<CaptureEvent> captureEvents,
    required List<AutoCaptureRule> rules,
  });

  /// 原子保存正式交易与原始事件状态。
  ///
  /// 自动入账/合并证据时必须使用此入口，避免“交易已写入但事件仍待确认”造成重复入账。
  Future<void> saveCaptureProcessing({
    required List<LedgerEntry> entries,
    required List<CaptureEvent> captureEvents,
  });

  Future<List<LedgerBook>> loadBooks();
  Future<void> saveBooks(List<LedgerBook> books);

  Future<List<Account>> loadAccounts();
  Future<void> saveAccounts(List<Account> accounts);

  Future<List<CreditAccount>> loadCreditAccounts();
  Future<void> saveCreditAccounts(List<CreditAccount> creditAccounts);

  /// 原子保存信用主体及其币种子账户，防止只留下主体或悬空的关联 id。
  Future<void> saveCreditAccountAggregate({
    required List<CreditAccount> creditAccounts,
    required List<Account> accounts,
  });

  Future<List<AccountGroup>> loadAccountGroups();
  Future<void> saveAccountGroups(List<AccountGroup> groups);

  Future<List<Category>> loadCategories();
  Future<void> saveCategories(List<Category> categories);

  Future<List<Tag>> loadTags();
  Future<void> saveTags(List<Tag> tags);

  Future<List<Attachment>> loadAttachments();
  Future<void> saveAttachments(List<Attachment> attachments);

  /// Replaces entries, attachments and optional exchange rates in one transaction.
  Future<void> saveEntryAggregate({
    required List<LedgerEntry> entries,
    required List<Attachment> attachments,
    List<ExchangeRate>? exchangeRates,
  });

  Future<List<RecurringRule>> loadRecurringRules();
  Future<void> saveRecurringRules(List<RecurringRule> rules);

  /// Persists generated recurring entries and advanced rules atomically.
  Future<void> saveRecurringGeneration({
    required List<LedgerEntry> entries,
    required List<RecurringRule> recurringRules,
  });

  Future<List<ExchangeRate>> loadExchangeRates();
  Future<void> saveExchangeRates(List<ExchangeRate> rates);

  Future<List<BalanceAnchor>> loadBalanceAnchors();
  Future<void> saveBalanceAnchors(List<BalanceAnchor> anchors);

  Future<List<BillingStatement>> loadBillingStatements();
  Future<void> saveBillingStatements(List<BillingStatement> statements);

  Future<List<StatementRepaymentAllocation>>
  loadStatementRepaymentAllocations();
  Future<void> saveStatementRepaymentAllocations(
    List<StatementRepaymentAllocation> allocations,
  );

  /// 原子保存正式账单、还款分配及其关联交易，避免只落下一半关系。
  Future<void> saveCreditAggregate({
    required List<LedgerEntry> entries,
    required List<BillingStatement> statements,
    required List<StatementRepaymentAllocation> allocations,
  });

  Future<Map<String, double>> loadMonthlyBudgets();
  Future<void> saveMonthlyBudgets(Map<String, double> budgets);

  Future<Map<String, double>> loadCategoryBudgets();
  Future<void> saveCategoryBudgets(Map<String, double> budgets);

  Future<Map<String, double>> loadDailyBudgets();
  Future<void> saveDailyBudgets(Map<String, double> budgets);

  /// 在单个事务中保存三张预算表，供预算设置页一次性提交草稿。
  Future<void> saveBudgetSettings({
    required Map<String, double> monthlyBudgets,
    required Map<String, double> categoryBudgets,
    required Map<String, double> dailyBudgets,
  });

  /// 在单个数据库事务中整体替换全部账目类表。用于导入/恢复/重置/删账本：
  /// 保证跨表一致——中途失败会整体回滚，不会留下「entries 已换、accounts 还是旧的」
  /// 这类孤儿引用状态。
  Future<void> replaceAllLedgerData(LedgerDataSnapshot snapshot);

  Future<bool> hasAnyData();
}

/// 基于 SQLite 的仓储实现。列表顺序通过 sort_order 列保留（entries 除外，其顺序
/// 由 occurred_at 决定）。
///
/// 写入策略：交易/账本/账户/分组/分类/标签/周期规则/汇率走**行级差分**（[_incrementalReplace]）
/// ——只写与内存基线快照不同的行，避免单条改动就重写整表（entries 随交易量无限增长，
/// 是写放大主因）。附件（含大 blob）与预算（极小）仍整表覆盖。saveX 的对外语义不变：
/// 落库后该表内容 == 传入列表。导入/恢复/重置走 [replaceAllLedgerData] 多表原子整替。
class SqliteLedgerRepository implements LedgerRepository {
  SqliteLedgerRepository(this._database);

  final AppDatabase _database;
  Database get _db => _database.db;

  /// 串行化本仓储的全部写入。sqflite 会串行执行底层事务，但行级差分快照在
  /// 事务开始前就会读取；若两个 saveX 同时进入，后一个会基于旧快照计算差分，
  /// 可能把“刚新增后立即删除”误判为无需写入。这里把“读取快照 → 写事务 → 更新
  /// 快照”整个临界区排成队列，同时让失败只结束当前调用、不阻塞后续写入。
  Future<void> _writeTail = Future<void>.value();

  Future<void> _enqueueWrite(Future<void> Function() operation) {
    final completer = Completer<void>();
    _writeTail = _writeTail.then((_) async {
      try {
        await operation();
        completer.complete();
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  // ---- 交易 ----

  @override
  Future<List<LedgerEntry>> loadEntries() async {
    final rows = await _db.query(
      'entries',
      orderBy: 'occurred_at DESC, id DESC',
    );
    final entries = rows.map(_entryFromRow).toList();
    _seedSnapshot('entries', entries.map(_entryToRow));
    return entries;
  }

  @override
  Future<void> saveEntries(List<LedgerEntry> entries) {
    final snapshot = List<LedgerEntry>.of(entries);
    return _enqueueWrite(
      () => _incrementalReplace('entries', snapshot.map(_entryToRow)),
    );
  }

  // ---- 自动采集原始事件与规则 ----

  @override
  Future<List<CaptureEvent>> loadCaptureEvents() async {
    final rows = await _db.query(
      'capture_events',
      orderBy: 'received_at DESC, id DESC',
    );
    final events = rows.map(_captureEventFromRow).toList();
    _seedSnapshot('capture_events', events.map(_captureEventToRow));
    return events;
  }

  @override
  Future<void> saveCaptureEvents(List<CaptureEvent> events) {
    final snapshot = List<CaptureEvent>.of(events);
    return _enqueueWrite(
      () => _incrementalReplace(
        'capture_events',
        snapshot.map(_captureEventToRow),
      ),
    );
  }

  @override
  Future<List<AutoCaptureRule>> loadAutoCaptureRules() async {
    final rows = await _db.query(
      'auto_capture_rules',
      orderBy: 'priority DESC, id ASC',
    );
    final rules = rows.map(_autoCaptureRuleFromRow).toList();
    _seedSnapshot('auto_capture_rules', rules.map(_autoCaptureRuleToRow));
    return rules;
  }

  @override
  Future<void> saveAutoCaptureRules(List<AutoCaptureRule> rules) {
    final snapshot = List<AutoCaptureRule>.of(rules);
    return _enqueueWrite(
      () => _incrementalReplace(
        'auto_capture_rules',
        snapshot.map(_autoCaptureRuleToRow),
      ),
    );
  }

  @override
  Future<void> saveAutoCaptureMetadata({
    required List<CaptureEvent> captureEvents,
    required List<AutoCaptureRule> rules,
  }) {
    final eventSnapshot = List<CaptureEvent>.of(captureEvents);
    final ruleSnapshot = List<AutoCaptureRule>.of(rules);
    return _enqueueWrite(() async {
      final eventRows = eventSnapshot
          .map(_captureEventToRow)
          .toList(growable: false);
      final ruleRows = ruleSnapshot
          .map(_autoCaptureRuleToRow)
          .toList(growable: false);
      final eventDiff = _diffRows(
        _rowSnapshots['capture_events'],
        _byId(eventRows),
      );
      final ruleDiff = _diffRows(
        _rowSnapshots['auto_capture_rules'],
        _byId(ruleRows),
      );
      await _db.transaction((txn) async {
        await _applyRowDiffInTxn(txn, 'capture_events', eventDiff);
        await _applyRowDiffInTxn(txn, 'auto_capture_rules', ruleDiff);
      });
      _seedSnapshot('capture_events', eventRows);
      _seedSnapshot('auto_capture_rules', ruleRows);
    });
  }

  @override
  Future<void> saveCaptureProcessing({
    required List<LedgerEntry> entries,
    required List<CaptureEvent> captureEvents,
  }) {
    final entrySnapshot = List<LedgerEntry>.of(entries);
    final eventSnapshot = List<CaptureEvent>.of(captureEvents);
    return _enqueueWrite(() async {
      final entryRows = entrySnapshot.map(_entryToRow).toList(growable: false);
      final eventRows = eventSnapshot
          .map(_captureEventToRow)
          .toList(growable: false);
      final entryDiff = _diffRows(_rowSnapshots['entries'], _byId(entryRows));
      final eventDiff = _diffRows(
        _rowSnapshots['capture_events'],
        _byId(eventRows),
      );
      await _db.transaction((txn) async {
        await _applyRowDiffInTxn(txn, 'entries', entryDiff);
        await _applyRowDiffInTxn(txn, 'capture_events', eventDiff);
      });
      _seedSnapshot('entries', entryRows);
      _seedSnapshot('capture_events', eventRows);
    });
  }

  // ---- 账本 ----

  @override
  Future<List<LedgerBook>> loadBooks() async {
    final rows = await _db.query('ledger_books', orderBy: 'sort_order ASC');
    final books = rows.map(_bookFromRow).toList();
    _seedSnapshot('ledger_books', _indexed(books, _bookToRow));
    return books;
  }

  @override
  Future<void> saveBooks(List<LedgerBook> books) {
    final snapshot = List<LedgerBook>.of(books);
    return _enqueueWrite(
      () => _incrementalReplace('ledger_books', _indexed(snapshot, _bookToRow)),
    );
  }

  // ---- 账户 ----

  @override
  Future<List<Account>> loadAccounts() async {
    final rows = await _db.query('accounts', orderBy: 'sort_order ASC');
    final accounts = rows.map(_accountFromRow).toList();
    _seedSnapshot('accounts', _indexed(accounts, _accountToRow));
    return accounts;
  }

  @override
  Future<void> saveAccounts(List<Account> accounts) {
    final snapshot = List<Account>.of(accounts);
    return _enqueueWrite(
      () => _incrementalReplace('accounts', _indexed(snapshot, _accountToRow)),
    );
  }

  // ---- 信用主体 ----

  @override
  Future<List<CreditAccount>> loadCreditAccounts() async {
    final rows = await _db.query('credit_accounts', orderBy: 'sort_order ASC');
    final creditAccounts = rows.map(_creditAccountFromRow).toList();
    _seedSnapshot(
      'credit_accounts',
      _indexed(creditAccounts, _creditAccountToRow),
    );
    return creditAccounts;
  }

  @override
  Future<void> saveCreditAccounts(List<CreditAccount> creditAccounts) {
    final snapshot = List<CreditAccount>.of(creditAccounts);
    return _enqueueWrite(
      () => _incrementalReplace(
        'credit_accounts',
        _indexed(snapshot, _creditAccountToRow),
      ),
    );
  }

  @override
  Future<void> saveCreditAccountAggregate({
    required List<CreditAccount> creditAccounts,
    required List<Account> accounts,
  }) {
    final creditSnapshot = List<CreditAccount>.of(creditAccounts);
    final accountSnapshot = List<Account>.of(accounts);
    return _enqueueWrite(() async {
      await _db.transaction((txn) async {
        await _replaceInTxn(
          txn,
          'credit_accounts',
          _indexed(creditSnapshot, _creditAccountToRow),
        );
        await _replaceInTxn(
          txn,
          'accounts',
          _indexed(accountSnapshot, _accountToRow),
        );
      });
      _seedSnapshot(
        'credit_accounts',
        _indexed(creditSnapshot, _creditAccountToRow),
      );
      _seedSnapshot('accounts', _indexed(accountSnapshot, _accountToRow));
    });
  }

  // ---- 账户分组 ----

  @override
  Future<List<AccountGroup>> loadAccountGroups() async {
    final rows = await _db.query('account_groups', orderBy: 'sort_order ASC');
    final groups = rows.map(_groupFromRow).toList();
    _seedSnapshot('account_groups', groups.map(_groupToRow));
    return groups;
  }

  @override
  Future<void> saveAccountGroups(List<AccountGroup> groups) {
    final snapshot = List<AccountGroup>.of(groups);
    return _enqueueWrite(
      () => _incrementalReplace('account_groups', snapshot.map(_groupToRow)),
    );
  }

  // ---- 分类 ----

  @override
  Future<List<Category>> loadCategories() async {
    final rows = await _db.query('categories', orderBy: 'sort_order ASC');
    final categories = rows.map(_categoryFromRow).toList();
    _seedSnapshot('categories', _indexed(categories, _categoryToRow));
    return categories;
  }

  @override
  Future<void> saveCategories(List<Category> categories) {
    final snapshot = List<Category>.of(categories);
    return _enqueueWrite(
      () =>
          _incrementalReplace('categories', _indexed(snapshot, _categoryToRow)),
    );
  }

  // ---- 标签 ----

  @override
  Future<List<Tag>> loadTags() async {
    final rows = await _db.query('tags', orderBy: 'sort_order ASC');
    final tags = rows.map(_tagFromRow).toList();
    _seedSnapshot('tags', _indexed(tags, _tagToRow));
    return tags;
  }

  @override
  Future<void> saveTags(List<Tag> tags) {
    final snapshot = List<Tag>.of(tags);
    return _enqueueWrite(
      () => _incrementalReplace('tags', _indexed(snapshot, _tagToRow)),
    );
  }

  // ---- 图片附件 ----

  @override
  Future<List<Attachment>> loadAttachments() async {
    final rows = await _db.query('attachments', orderBy: 'sort_order ASC');
    return rows.map(_attachmentFromRow).toList();
  }

  @override
  Future<void> saveAttachments(List<Attachment> attachments) {
    final snapshot = List<Attachment>.of(attachments);
    return _enqueueWrite(
      () => _replaceAll('attachments', _indexed(snapshot, _attachmentToRow)),
    );
  }

  /// 交易与附件在同一事务内提交，保留跨表原子性：交易走行级差分（只写变化行），
  /// 附件含大 blob 仍整表覆盖。差分基线必须在事务提交成功后写入，否则回滚会留下
  /// 与 DB 不符的快照。
  @override
  Future<void> saveEntryAggregate({
    required List<LedgerEntry> entries,
    required List<Attachment> attachments,
    List<ExchangeRate>? exchangeRates,
  }) {
    final entrySnapshot = List<LedgerEntry>.of(entries);
    final attachmentSnapshot = List<Attachment>.of(attachments);
    final rateSnapshot = exchangeRates == null
        ? null
        : List<ExchangeRate>.of(exchangeRates);
    return _enqueueWrite(() async {
      // entries 行映射昂贵且随行数增长：同一份行映射同时供差分与事务后的基线快照复用。
      final entryRows = entrySnapshot.map(_entryToRow).toList(growable: false);
      final rateRows = rateSnapshot
          ?.map(_exchangeRateToRow)
          .toList(growable: false);
      final entryDiff = _diffRows(_rowSnapshots['entries'], _byId(entryRows));
      await _db.transaction((txn) async {
        await _applyRowDiffInTxn(txn, 'entries', entryDiff);
        await _replaceInTxn(
          txn,
          'attachments',
          _indexed(attachmentSnapshot, _attachmentToRow),
        );
        if (rateRows != null) {
          await _replaceInTxn(txn, 'exchange_rates', rateRows);
        }
      });
      _seedSnapshot('entries', entryRows);
      if (rateRows != null) {
        _seedSnapshot('exchange_rates', rateRows);
      }
    });
  }

  // ---- 周期记账规则 ----

  @override
  Future<List<RecurringRule>> loadRecurringRules() async {
    final rows = await _db.query('recurring_rules', orderBy: 'sort_order ASC');
    final rules = rows.map(_recurringFromRow).toList();
    _seedSnapshot('recurring_rules', _indexed(rules, _recurringToRow));
    return rules;
  }

  @override
  Future<void> saveRecurringRules(List<RecurringRule> rules) {
    final snapshot = List<RecurringRule>.of(rules);
    return _enqueueWrite(
      () => _incrementalReplace(
        'recurring_rules',
        _indexed(snapshot, _recurringToRow),
      ),
    );
  }

  @override
  Future<void> saveRecurringGeneration({
    required List<LedgerEntry> entries,
    required List<RecurringRule> recurringRules,
  }) {
    final entrySnapshot = List<LedgerEntry>.of(entries);
    final ruleSnapshot = List<RecurringRule>.of(recurringRules);
    return _enqueueWrite(() async {
      await _db.transaction((txn) async {
        await _replaceInTxn(txn, 'entries', entrySnapshot.map(_entryToRow));
        await _replaceInTxn(
          txn,
          'recurring_rules',
          _indexed(ruleSnapshot, _recurringToRow),
        );
      });
      _seedSnapshot('entries', entrySnapshot.map(_entryToRow));
      _seedSnapshot('recurring_rules', _indexed(ruleSnapshot, _recurringToRow));
    });
  }

  // ---- 本地汇率 ----

  @override
  Future<List<ExchangeRate>> loadExchangeRates() async {
    final rows = await _db.query(
      'exchange_rates',
      orderBy: 'currency_code ASC, effective_date DESC, id DESC',
    );
    final rates = rows.map(_exchangeRateFromRow).toList();
    _seedSnapshot('exchange_rates', rates.map(_exchangeRateToRow));
    return rates;
  }

  @override
  Future<void> saveExchangeRates(List<ExchangeRate> rates) {
    final snapshot = List<ExchangeRate>.of(rates);
    return _enqueueWrite(
      () => _incrementalReplace(
        'exchange_rates',
        snapshot.map(_exchangeRateToRow),
      ),
    );
  }

  // ---- 余额核准、正式账单与还款分配 ----

  @override
  Future<List<BalanceAnchor>> loadBalanceAnchors() async {
    final rows = await _db.query(
      'balance_anchors',
      orderBy: 'effective_at DESC, id DESC',
    );
    final anchors = rows.map(_balanceAnchorFromRow).toList();
    _seedSnapshot('balance_anchors', anchors.map(_balanceAnchorToRow));
    return anchors;
  }

  @override
  Future<void> saveBalanceAnchors(List<BalanceAnchor> anchors) {
    final snapshot = List<BalanceAnchor>.of(anchors);
    return _enqueueWrite(
      () => _incrementalReplace(
        'balance_anchors',
        snapshot.map(_balanceAnchorToRow),
      ),
    );
  }

  @override
  Future<List<BillingStatement>> loadBillingStatements() async {
    final rows = await _db.query(
      'billing_statements',
      orderBy: 'statement_date DESC, id DESC',
    );
    final statements = rows.map(_billingStatementFromRow).toList();
    _seedSnapshot('billing_statements', statements.map(_billingStatementToRow));
    return statements;
  }

  @override
  Future<void> saveBillingStatements(List<BillingStatement> statements) {
    final snapshot = List<BillingStatement>.of(statements);
    return _enqueueWrite(
      () => _incrementalReplace(
        'billing_statements',
        snapshot.map(_billingStatementToRow),
      ),
    );
  }

  @override
  Future<List<StatementRepaymentAllocation>>
  loadStatementRepaymentAllocations() async {
    final rows = await _db.query(
      'statement_repayment_allocations',
      orderBy: 'created_at ASC, id ASC',
    );
    final allocations = rows.map(_statementRepaymentAllocationFromRow).toList();
    _seedSnapshot(
      'statement_repayment_allocations',
      allocations.map(_statementRepaymentAllocationToRow),
    );
    return allocations;
  }

  @override
  Future<void> saveStatementRepaymentAllocations(
    List<StatementRepaymentAllocation> allocations,
  ) {
    final snapshot = List<StatementRepaymentAllocation>.of(allocations);
    return _enqueueWrite(
      () => _incrementalReplace(
        'statement_repayment_allocations',
        snapshot.map(_statementRepaymentAllocationToRow),
      ),
    );
  }

  @override
  Future<void> saveCreditAggregate({
    required List<LedgerEntry> entries,
    required List<BillingStatement> statements,
    required List<StatementRepaymentAllocation> allocations,
  }) {
    final entrySnapshot = List<LedgerEntry>.of(entries);
    final statementSnapshot = List<BillingStatement>.of(statements);
    final allocationSnapshot = List<StatementRepaymentAllocation>.of(
      allocations,
    );
    return _enqueueWrite(() async {
      final entryRows = entrySnapshot.map(_entryToRow).toList(growable: false);
      final statementRows = statementSnapshot
          .map(_billingStatementToRow)
          .toList(growable: false);
      final allocationRows = allocationSnapshot
          .map(_statementRepaymentAllocationToRow)
          .toList(growable: false);
      await _db.transaction((txn) async {
        await _replaceInTxn(txn, 'entries', entryRows);
        await _replaceInTxn(txn, 'billing_statements', statementRows);
        await _replaceInTxn(
          txn,
          'statement_repayment_allocations',
          allocationRows,
        );
      });
      _seedSnapshot('entries', entryRows);
      _seedSnapshot('billing_statements', statementRows);
      _seedSnapshot('statement_repayment_allocations', allocationRows);
    });
  }

  // ---- 预算（键值对：月度 / 分类）----

  @override
  Future<Map<String, double>> loadMonthlyBudgets() =>
      _loadBudgetMap('monthly_budgets');

  @override
  Future<void> saveMonthlyBudgets(Map<String, double> budgets) {
    final snapshot = Map<String, double>.of(budgets);
    return _enqueueWrite(() => _saveBudgetMap('monthly_budgets', snapshot));
  }

  @override
  Future<Map<String, double>> loadCategoryBudgets() =>
      _loadBudgetMap('category_budgets');

  @override
  Future<void> saveCategoryBudgets(Map<String, double> budgets) {
    final snapshot = Map<String, double>.of(budgets);
    return _enqueueWrite(() => _saveBudgetMap('category_budgets', snapshot));
  }

  @override
  Future<Map<String, double>> loadDailyBudgets() =>
      _loadBudgetMap('daily_budgets');

  @override
  Future<void> saveDailyBudgets(Map<String, double> budgets) {
    final snapshot = Map<String, double>.of(budgets);
    return _enqueueWrite(() => _saveBudgetMap('daily_budgets', snapshot));
  }

  @override
  Future<void> saveBudgetSettings({
    required Map<String, double> monthlyBudgets,
    required Map<String, double> categoryBudgets,
    required Map<String, double> dailyBudgets,
  }) {
    final monthlySnapshot = Map<String, double>.of(monthlyBudgets);
    final categorySnapshot = Map<String, double>.of(categoryBudgets);
    final dailySnapshot = Map<String, double>.of(dailyBudgets);
    return _enqueueWrite(() async {
      await _db.transaction((txn) async {
        await _replaceInTxn(
          txn,
          'monthly_budgets',
          _budgetRows(monthlySnapshot),
        );
        await _replaceInTxn(
          txn,
          'category_budgets',
          _budgetRows(categorySnapshot),
        );
        await _replaceInTxn(txn, 'daily_budgets', _budgetRows(dailySnapshot));
      });
    });
  }

  @override
  Future<void> replaceAllLedgerData(LedgerDataSnapshot snapshot) {
    return _enqueueWrite(() async {
      // 全部表在同一事务内清空重建：任一步失败即整体回滚，绝不留半新半旧状态。
      await _db.transaction((txn) async {
        await _replaceInTxn(
          txn,
          'ledger_books',
          _indexed(snapshot.books, _bookToRow),
        );
        await _replaceInTxn(
          txn,
          'accounts',
          _indexed(snapshot.accounts, _accountToRow),
        );
        await _replaceInTxn(
          txn,
          'account_groups',
          snapshot.accountGroups.map(_groupToRow),
        );
        await _replaceInTxn(
          txn,
          'credit_accounts',
          _indexed(snapshot.creditAccounts, _creditAccountToRow),
        );
        await _replaceInTxn(
          txn,
          'categories',
          _indexed(snapshot.categories, _categoryToRow),
        );
        await _replaceInTxn(txn, 'tags', _indexed(snapshot.tags, _tagToRow));
        await _replaceInTxn(
          txn,
          'attachments',
          _indexed(snapshot.attachments, _attachmentToRow),
        );
        await _replaceInTxn(txn, 'entries', snapshot.entries.map(_entryToRow));
        await _replaceInTxn(
          txn,
          'recurring_rules',
          _indexed(snapshot.recurringRules, _recurringToRow),
        );
        await _replaceInTxn(
          txn,
          'monthly_budgets',
          _budgetRows(snapshot.monthlyBudgets),
        );
        await _replaceInTxn(
          txn,
          'category_budgets',
          _budgetRows(snapshot.categoryBudgets),
        );
        await _replaceInTxn(
          txn,
          'daily_budgets',
          _budgetRows(snapshot.dailyBudgets),
        );
        await _replaceInTxn(
          txn,
          'exchange_rates',
          snapshot.exchangeRates.map(_exchangeRateToRow),
        );
        await _replaceInTxn(
          txn,
          'balance_anchors',
          snapshot.balanceAnchors.map(_balanceAnchorToRow),
        );
        await _replaceInTxn(
          txn,
          'billing_statements',
          snapshot.billingStatements.map(_billingStatementToRow),
        );
        await _replaceInTxn(
          txn,
          'statement_repayment_allocations',
          snapshot.statementRepaymentAllocations.map(
            _statementRepaymentAllocationToRow,
          ),
        );
      });
      // 整替后重建各增量表基线，使后续单条 saveX 的差分有正确起点（否则会拿导入前
      // 的旧快照去 diff、误删或漏写）。附件/预算不走增量、无需重置。
      _seedSnapshot('ledger_books', _indexed(snapshot.books, _bookToRow));
      _seedSnapshot('accounts', _indexed(snapshot.accounts, _accountToRow));
      _seedSnapshot('account_groups', snapshot.accountGroups.map(_groupToRow));
      _seedSnapshot(
        'credit_accounts',
        _indexed(snapshot.creditAccounts, _creditAccountToRow),
      );
      _seedSnapshot(
        'categories',
        _indexed(snapshot.categories, _categoryToRow),
      );
      _seedSnapshot('tags', _indexed(snapshot.tags, _tagToRow));
      _seedSnapshot('entries', snapshot.entries.map(_entryToRow));
      _seedSnapshot(
        'recurring_rules',
        _indexed(snapshot.recurringRules, _recurringToRow),
      );
      _seedSnapshot(
        'exchange_rates',
        snapshot.exchangeRates.map(_exchangeRateToRow),
      );
      _seedSnapshot(
        'balance_anchors',
        snapshot.balanceAnchors.map(_balanceAnchorToRow),
      );
      _seedSnapshot(
        'billing_statements',
        snapshot.billingStatements.map(_billingStatementToRow),
      );
      _seedSnapshot(
        'statement_repayment_allocations',
        snapshot.statementRepaymentAllocations.map(
          _statementRepaymentAllocationToRow,
        ),
      );
    });
  }

  /// 是否已存在任何账目数据（用于判断迁移是否有内容写入）。
  @override
  Future<bool> hasAnyData() async {
    for (final table in const <String>[
      'entries',
      'ledger_books',
      'accounts',
      'account_groups',
      'credit_accounts',
      'categories',
      'exchange_rates',
      'balance_anchors',
      'billing_statements',
      'statement_repayment_allocations',
    ]) {
      final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      final count = (rows.first['c'] as int?) ?? 0;
      if (count > 0) {
        return true;
      }
    }
    return false;
  }

  // ---- 增量写：按主键 id 的行级差分 ----

  /// 每张「增量表」在内存里保留上次落库的行快照（id → 规范化行）。saveX 时据此
  /// 算出真正变化的行（新增/改动/删除），只写这些行，避免每次单条改动就 DELETE
  /// 整表再全量 INSERT（entries 表随交易量无限增长，是写放大的主因）。
  ///
  /// 语义与整表覆盖完全一致——落库后 DB 内容 == 传入列表；只是实现为「差分应用」。
  /// 附件表（含大 JPEG blob，缓存整行会成倍占内存）与预算表（极小、少写）不走此路，
  /// 仍用整表覆盖。导入/恢复/重置走 [replaceAllLedgerData]（多表原子整替）。
  final Map<String, Map<Object, Map<String, Object?>>> _rowSnapshots =
      <String, Map<Object, Map<String, Object?>>>{};

  /// 记录某表当前 DB 内容为基线快照（键为行的 id 列）。loadX 载入后、
  /// replaceAllLedgerData 整替后调用，使后续差分有正确基线。
  void _seedSnapshot(String table, Iterable<Map<String, Object?>> rows) {
    _rowSnapshots[table] = _byId(rows);
  }

  /// 以行的 id 列为键建立索引；差分与基线快照共用同一份键规则。
  static Map<Object, Map<String, Object?>> _byId(
    Iterable<Map<String, Object?>> rows,
  ) => <Object, Map<String, Object?>>{
    for (final row in rows) row['id'] as Object: row,
  };

  /// 以 [rows] 差分更新 [table]：只写与基线快照不同的行。无基线（未 load 过）时
  /// 退化为一次整表覆盖并建立基线；无任何变化则不发生写入。
  Future<void> _incrementalReplace(
    String table,
    Iterable<Map<String, Object?>> rows,
  ) async {
    final diff = _diffRows(_rowSnapshots[table], _byId(rows));
    if (diff.isEmpty) {
      return;
    }
    await _db.transaction((txn) => _applyRowDiffInTxn(txn, table, diff));
    _rowSnapshots[table] = diff.baseline;
  }

  /// 相对基线 [prev] 计算 [next] 的行级差分。基线缺失时只能整表覆盖：仅靠 upsert
  /// 无法删掉库里存在、传入列表里没有的行。
  static _RowDiff _diffRows(
    Map<Object, Map<String, Object?>>? prev,
    Map<Object, Map<String, Object?>> next,
  ) {
    if (prev == null) {
      return _RowDiff(
        upsert: next.values.toList(growable: false),
        deleteIds: const <Object>[],
        baseline: next,
        fullReplace: true,
      );
    }
    final upsert = <Map<String, Object?>>[];
    next.forEach((id, row) {
      final old = prev[id];
      if (old == null || !_sameRow(old, row)) {
        upsert.add(row);
      }
    });
    return _RowDiff(
      upsert: upsert,
      deleteIds: <Object>[
        for (final id in prev.keys)
          if (!next.containsKey(id)) id,
      ],
      baseline: next,
      fullReplace: false,
    );
  }

  /// 在调用方给定的事务内应用差分。供 [_incrementalReplace]（单表自建事务）与
  /// [saveEntryAggregate]（多表共享事务）复用；原子性由该事务保证。
  static Future<void> _applyRowDiffInTxn(
    Transaction txn,
    String table,
    _RowDiff diff,
  ) async {
    if (diff.fullReplace) {
      await txn.delete(table);
    }
    final batch = txn.batch();
    for (final row in diff.upsert) {
      batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final id in diff.deleteIds) {
      batch.delete(table, where: 'id = ?', whereArgs: <Object>[id]);
    }
    await batch.commit(noResult: true);
  }

  /// 行相等：列数与每列值都相等（列值均为 String/int/double/null，`!=` 即可）。
  static bool _sameRow(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  // ---- 内部工具 ----

  Future<void> _replaceAll(
    String table,
    Iterable<Map<String, Object?>> rows,
  ) async {
    await _db.transaction((txn) async {
      await _replaceInTxn(txn, table, rows);
    });
  }

  /// 在给定事务执行器内清空并重建单表。供 [_replaceAll]（单表）与
  /// [replaceAllLedgerData]（多表共享一个事务）复用。
  Future<void> _replaceInTxn(
    Transaction txn,
    String table,
    Iterable<Map<String, Object?>> rows,
  ) async {
    final rowList = rows.toList();
    await txn.delete(table);
    final batch = txn.batch();
    for (final row in rowList) {
      batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Iterable<Map<String, Object?>> _budgetRows(
    Map<String, double> budgets,
  ) => budgets.entries.map(
    (entry) => <String, Object?>{'scope_key': entry.key, 'amount': entry.value},
  );

  Future<Map<String, double>> _loadBudgetMap(String table) async {
    final rows = await _db.query(table);
    return <String, double>{
      for (final row in rows)
        row['scope_key'] as String: (row['amount'] as num).toDouble(),
    };
  }

  Future<void> _saveBudgetMap(String table, Map<String, double> budgets) async {
    await _replaceAll(table, _budgetRows(budgets));
  }

  /// 为有序列表补充 sort_order 列（值为列表下标）。
  static Iterable<Map<String, Object?>> _indexed<T>(
    List<T> items,
    Map<String, Object?> Function(T item, int index) toRow,
  ) {
    return items.indexed.map((item) => toRow(item.$2, item.$1));
  }

  // ---- 行映射 ----

  static Map<String, Object?> _entryToRow(LedgerEntry e) => <String, Object?>{
    'id': e.id,
    'book_id': e.bookId,
    'type': e.type.storageValue,
    'amount': e.amount,
    'currency_code': e.currencyCode,
    'account_amount': e.accountAmount,
    'to_account_amount': e.toAccountAmount,
    'base_amount': e.baseAmount,
    'conversion_source': e.conversionSource.name,
    'category_id': e.categoryId,
    'account_id': e.accountId,
    'to_account_id': e.toAccountId,
    'note': e.note,
    'occurred_at': e.occurredAt.millisecondsSinceEpoch,
    'occurred_at_precision': e.occurredAtPrecision.name,
    'post_date': e.postDate?.millisecondsSinceEpoch,
    'billing_cycle_id': e.billingCycleId,
    // 标签 id 列表以 JSON 数组存单列（整表覆盖式读写，无需关联表）。
    'tag_ids': e.tagIds.isEmpty ? null : jsonEncode(e.tagIds),
    'fee': e.fee,
    'reimbursable': e.reimbursable ? 1 : 0,
    'refunded_amount': e.refundedBaseAmount,
    'refund_of': e.refundOf,
    'settled_at': e.settledAt?.millisecondsSinceEpoch,
    'reconciliation_status': e.reconciliationStatus.name,
    'source_records': e.sourceRecords.isEmpty
        ? null
        : jsonEncode(e.sourceRecords.map((record) => record.toJson()).toList()),
    'audit_history': e.auditHistory.isEmpty
        ? null
        : jsonEncode(e.auditHistory.map((record) => record.toJson()).toList()),
  };

  static Map<String, Object?> _captureEventToRow(CaptureEvent event) =>
      <String, Object?>{
        'id': event.id,
        'book_id': event.bookId,
        'source_kind': event.sourceKind.name,
        'source_id': event.sourceId,
        'source_label': event.sourceLabel,
        'source_event_id': event.sourceEventId,
        'raw_text': event.rawText,
        'received_at': event.receivedAt.millisecondsSinceEpoch,
        'fingerprint': event.fingerprint,
        'parsed_amount': event.parsedAmount,
        'currency_code': event.currencyCode,
        'merchant': event.merchant,
        'card_last4': event.cardLast4,
        'transaction_kind': event.kind.name,
        'account_candidate_id': event.accountCandidateId,
        'to_account_candidate_id': event.toAccountCandidateId,
        'category_candidate_id': event.categoryCandidateId,
        'tag_candidate_ids': event.tagCandidateIds.isEmpty
            ? null
            : jsonEncode(event.tagCandidateIds),
        'confidence': event.confidence.name,
        'confidence_score': event.confidenceScore,
        'status': event.status.name,
        'linked_entry_id': event.linkedEntryId,
        'duplicate_entry_id': event.duplicateEntryId,
        'applied_rule_ids': event.appliedRuleIds.isEmpty
            ? null
            : jsonEncode(event.appliedRuleIds),
        'ai_assisted': event.aiAssisted ? 1 : 0,
        'failure_reason': event.failureReason,
        'processed_at': event.processedAt?.millisecondsSinceEpoch,
      };

  static CaptureEvent _captureEventFromRow(
    Map<String, Object?> row,
  ) => CaptureEvent(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    sourceKind: CaptureSourceKind.fromStorage(row['source_kind'] as String?),
    sourceId: row['source_id'] as String? ?? '',
    sourceLabel: row['source_label'] as String? ?? '',
    sourceEventId: row['source_event_id'] as String? ?? '',
    rawText: row['raw_text'] as String? ?? '',
    receivedAt: DateTime.fromMillisecondsSinceEpoch(row['received_at'] as int),
    fingerprint: row['fingerprint'] as String? ?? '',
    parsedAmount: (row['parsed_amount'] as num?)?.toDouble(),
    currencyCode: row['currency_code'] as String? ?? defaultCurrencyCode,
    merchant: row['merchant'] as String? ?? '',
    cardLast4: row['card_last4'] as String? ?? '',
    kind: CaptureTransactionKind.fromStorage(
      row['transaction_kind'] as String?,
    ),
    accountCandidateId: row['account_candidate_id'] as String?,
    toAccountCandidateId: row['to_account_candidate_id'] as String?,
    categoryCandidateId: row['category_candidate_id'] as String?,
    tagCandidateIds: _decodeStringList(row['tag_candidate_ids']),
    confidence: CaptureConfidence.fromStorage(row['confidence'] as String?),
    confidenceScore: (row['confidence_score'] as num?)?.toDouble() ?? 0,
    status: CaptureStatus.fromStorage(row['status'] as String?),
    linkedEntryId: row['linked_entry_id'] as String?,
    duplicateEntryId: row['duplicate_entry_id'] as String?,
    appliedRuleIds: _decodeStringList(row['applied_rule_ids']),
    aiAssisted: (row['ai_assisted'] as int? ?? 0) == 1,
    failureReason: row['failure_reason'] as String? ?? '',
    processedAt: row['processed_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['processed_at'] as int),
  );

  static Map<String, Object?> _autoCaptureRuleToRow(
    AutoCaptureRule rule,
  ) => <String, Object?>{
    'id': rule.id,
    'book_id': rule.bookId,
    'name': rule.name,
    'priority': rule.priority,
    'enabled': rule.enabled ? 1 : 0,
    'source_kind': rule.sourceKind?.name,
    'source_id': rule.sourceId,
    'text_contains': rule.textContains,
    'card_last4': rule.cardLast4,
    'exact_amount': rule.exactAmount,
    'match_kind': rule.matchKind?.name,
    'set_kind': rule.setKind?.name,
    'set_account_id': rule.setAccountId,
    'set_to_account_id': rule.setToAccountId,
    'set_category_id': rule.setCategoryId,
    'set_tag_ids': rule.setTagIds.isEmpty ? null : jsonEncode(rule.setTagIds),
    'set_merchant': rule.setMerchant,
  };

  static AutoCaptureRule _autoCaptureRuleFromRow(Map<String, Object?> row) =>
      AutoCaptureRule(
        id: row['id'] as String,
        bookId: row['book_id'] as String,
        name: row['name'] as String? ?? '',
        priority: (row['priority'] as num?)?.toInt() ?? 0,
        enabled: ((row['enabled'] as int?) ?? 1) != 0,
        sourceKind: row['source_kind'] == null
            ? null
            : CaptureSourceKind.fromStorage(row['source_kind'] as String?),
        sourceId: row['source_id'] as String? ?? '',
        textContains: row['text_contains'] as String? ?? '',
        cardLast4: row['card_last4'] as String? ?? '',
        exactAmount: (row['exact_amount'] as num?)?.toDouble(),
        matchKind: row['match_kind'] == null
            ? null
            : CaptureTransactionKind.fromStorage(row['match_kind'] as String?),
        setKind: row['set_kind'] == null
            ? null
            : CaptureTransactionKind.fromStorage(row['set_kind'] as String?),
        setAccountId: row['set_account_id'] as String?,
        setToAccountId: row['set_to_account_id'] as String?,
        setCategoryId: row['set_category_id'] as String?,
        setTagIds: _decodeStringList(row['set_tag_ids']),
        setMerchant: row['set_merchant'] as String? ?? '',
      );

  static LedgerEntry _entryFromRow(Map<String, Object?> row) => LedgerEntry(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    type: EntryType.fromStorage(row['type'] as String),
    amount: (row['amount'] as num).toDouble(),
    currencyCode: row['currency_code'] as String? ?? defaultCurrencyCode,
    accountAmount: (row['account_amount'] as num?)?.toDouble(),
    toAccountAmount: (row['to_account_amount'] as num?)?.toDouble(),
    baseAmount: (row['base_amount'] as num?)?.toDouble() ?? 0,
    conversionSource: ConversionSource.fromStorage(
      row['conversion_source'] as String?,
    ),
    categoryId: row['category_id'] as String,
    accountId: row['account_id'] as String,
    toAccountId: row['to_account_id'] as String?,
    note: row['note'] as String? ?? '',
    occurredAt: DateTime.fromMillisecondsSinceEpoch(row['occurred_at'] as int),
    occurredAtPrecision: OccurredAtPrecision.fromStorage(
      row['occurred_at_precision'] as String?,
    ),
    postDate: row['post_date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['post_date'] as int),
    billingCycleId: row['billing_cycle_id'] as String?,
    tagIds: _decodeTagIds(row['tag_ids']),
    fee: (row['fee'] as num?)?.toDouble() ?? 0,
    reimbursable: ((row['reimbursable'] as int?) ?? 0) != 0,
    refundedBaseAmount: (row['refunded_amount'] as num?)?.toDouble() ?? 0,
    refundOf: row['refund_of'] as String?,
    settledAt: row['settled_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['settled_at'] as int),
    reconciliationStatus: ReconciliationStatus.fromStorage(
      row['reconciliation_status'] as String?,
    ),
    sourceRecords: _decodeSourceRecords(row['source_records']),
    auditHistory: _decodeAuditHistory(row['audit_history']),
  );

  /// 读取交易审计历史；早期数据库该列为空时保留空列表。
  static List<EntryAuditRecord> _decodeAuditHistory(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <EntryAuditRecord>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <EntryAuditRecord>[];
    return decoded
        .whereType<Map>()
        .map(
          (item) => EntryAuditRecord.fromJson(Map<String, Object?>.from(item)),
        )
        .toList(growable: false);
  }

  static List<EntrySourceRecord> _decodeSourceRecords(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <EntrySourceRecord>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <EntrySourceRecord>[];
    return decoded
        .whereType<Map>()
        .map(
          (item) => EntrySourceRecord.fromJson(Map<String, Object?>.from(item)),
        )
        .toList(growable: false);
  }

  static List<String> _decodeTagIds(Object? raw) {
    if (raw is String && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList(growable: false);
      }
    }
    return const <String>[];
  }

  /// 解码 capture 表中的 JSON 字符串数组；损坏值按空列表降级，不阻断账本启动。
  static List<String> _decodeStringList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List
          ? decoded.map((item) => item.toString()).toList(growable: false)
          : const <String>[];
    } on Object {
      return const <String>[];
    }
  }

  static Map<String, Object?> _tagToRow(Tag t, int index) => <String, Object?>{
    'id': t.id,
    'label': t.label,
    'sort_order': index,
  };

  static Tag _tagFromRow(Map<String, Object?> row) =>
      Tag(id: row['id'] as String, label: row['label'] as String);

  static Map<String, Object?> _attachmentToRow(Attachment a, int index) =>
      <String, Object?>{
        'id': a.id,
        'entry_id': a.entryId,
        'data_url': a.dataUrl,
        'sort_order': index,
      };

  static Attachment _attachmentFromRow(Map<String, Object?> row) => Attachment(
    id: row['id'] as String,
    entryId: row['entry_id'] as String,
    dataUrl: row['data_url'] as String,
  );

  static Map<String, Object?> _recurringToRow(RecurringRule r, int index) =>
      <String, Object?>{
        'id': r.id,
        'book_id': r.bookId,
        'type': r.type.storageValue,
        'amount': r.amount,
        'currency_code': r.currencyCode,
        'account_amount': r.accountAmount,
        'to_account_amount': r.toAccountAmount,
        'base_amount': r.baseAmount,
        'rate_policy': r.ratePolicy.name,
        'category_id': r.categoryId,
        'account_id': r.accountId,
        'to_account_id': r.toAccountId,
        'note': r.note,
        'frequency': r.frequency.storageValue,
        'start_date': r.startDate.millisecondsSinceEpoch,
        'next_run_date': r.nextRunDate.millisecondsSinceEpoch,
        'active': r.active ? 1 : 0,
        'sort_order': index,
      };

  static RecurringRule _recurringFromRow(
    Map<String, Object?> row,
  ) => RecurringRule(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    type: EntryType.fromStorage(row['type'] as String),
    amount: (row['amount'] as num).toDouble(),
    currencyCode: row['currency_code'] as String? ?? defaultCurrencyCode,
    accountAmount: (row['account_amount'] as num?)?.toDouble(),
    toAccountAmount: (row['to_account_amount'] as num?)?.toDouble(),
    baseAmount: (row['base_amount'] as num?)?.toDouble() ?? 0,
    ratePolicy: RecurringRatePolicy.fromStorage(row['rate_policy'] as String?),
    categoryId: row['category_id'] as String,
    accountId: row['account_id'] as String,
    toAccountId: row['to_account_id'] as String?,
    note: row['note'] as String? ?? '',
    frequency: RecurringFrequency.fromStorage(row['frequency'] as String?),
    startDate: DateTime.fromMillisecondsSinceEpoch(row['start_date'] as int),
    nextRunDate: DateTime.fromMillisecondsSinceEpoch(
      row['next_run_date'] as int,
    ),
    active: ((row['active'] as int?) ?? 1) != 0,
  );

  static Map<String, Object?> _exchangeRateToRow(ExchangeRate rate) =>
      <String, Object?>{
        'id': rate.id,
        'book_id': rate.bookId,
        'base_currency_code': rate.baseCurrencyCode,
        'currency_code': rate.currencyCode,
        'effective_date': currencyDateKey(rate.effectiveDate),
        'rate_to_base': rate.rateToBase,
        'source': rate.source.name,
        'created_at': rate.createdAt.millisecondsSinceEpoch,
        'updated_at': rate.updatedAt.millisecondsSinceEpoch,
      };

  static ExchangeRate _exchangeRateFromRow(Map<String, Object?> row) {
    final effectiveDate = parseCurrencyDateKey(row['effective_date']);
    if (effectiveDate == null) {
      throw FormatException(
        'Invalid exchange rate effective_date: ${row['effective_date']}',
      );
    }
    return ExchangeRate(
      id: row['id'] as String,
      bookId: row['book_id'] as String,
      baseCurrencyCode: row['base_currency_code'] as String,
      currencyCode: row['currency_code'] as String,
      effectiveDate: effectiveDate,
      rateToBase: (row['rate_to_base'] as num).toDouble(),
      source: ExchangeRateSource.fromStorage(row['source'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  static Map<String, Object?> _balanceAnchorToRow(BalanceAnchor anchor) =>
      <String, Object?>{
        'id': anchor.id,
        'book_id': anchor.bookId,
        'account_id': anchor.accountId,
        'effective_at': anchor.effectiveAt.millisecondsSinceEpoch,
        'balance': anchor.balance,
        'created_at': anchor.createdAt.millisecondsSinceEpoch,
        'note': anchor.note,
      };

  static BalanceAnchor _balanceAnchorFromRow(Map<String, Object?> row) =>
      BalanceAnchor(
        id: row['id'] as String,
        bookId: row['book_id'] as String,
        accountId: row['account_id'] as String,
        effectiveAt: DateTime.fromMillisecondsSinceEpoch(
          row['effective_at'] as int,
        ),
        balance: (row['balance'] as num).toDouble(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
        ),
        note: row['note'] as String? ?? '',
      );

  static Map<String, Object?> _billingStatementToRow(
    BillingStatement statement,
  ) => <String, Object?>{
    'id': statement.id,
    'book_id': statement.bookId,
    'account_id': statement.accountId,
    'statement_date': statement.statementDate.millisecondsSinceEpoch,
    'period_start': statement.periodStart.millisecondsSinceEpoch,
    'period_end': statement.periodEnd.millisecondsSinceEpoch,
    'statement_amount': statement.statementAmount,
    'minimum_payment': statement.minimumPayment,
    'due_date': statement.dueDate.millisecondsSinceEpoch,
    'paid_amount': statement.paidAmount,
    'status': statement.status.name,
    'currency_code': statement.currencyCode,
    'source_id': statement.sourceId,
    'source_statement_id': statement.sourceStatementId,
    'note': statement.note,
  };

  static BillingStatement _billingStatementFromRow(Map<String, Object?> row) =>
      BillingStatement(
        id: row['id'] as String,
        bookId: row['book_id'] as String,
        accountId: row['account_id'] as String,
        statementDate: DateTime.fromMillisecondsSinceEpoch(
          row['statement_date'] as int,
        ),
        periodStart: DateTime.fromMillisecondsSinceEpoch(
          row['period_start'] as int,
        ),
        periodEnd: DateTime.fromMillisecondsSinceEpoch(
          row['period_end'] as int,
        ),
        statementAmount: (row['statement_amount'] as num).toDouble(),
        minimumPayment: (row['minimum_payment'] as num).toDouble(),
        dueDate: DateTime.fromMillisecondsSinceEpoch(row['due_date'] as int),
        paidAmount: (row['paid_amount'] as num).toDouble(),
        status: BillingStatementStatus.fromStorage(row['status'] as String?),
        currencyCode: row['currency_code'] as String? ?? defaultCurrencyCode,
        sourceId: row['source_id'] as String? ?? '',
        sourceStatementId: row['source_statement_id'] as String? ?? '',
        note: row['note'] as String? ?? '',
      );

  static Map<String, Object?> _statementRepaymentAllocationToRow(
    StatementRepaymentAllocation allocation,
  ) => <String, Object?>{
    'id': allocation.id,
    'book_id': allocation.bookId,
    'statement_id': allocation.statementId,
    'repayment_entry_id': allocation.repaymentEntryId,
    'amount': allocation.amount,
    'created_at': allocation.createdAt.millisecondsSinceEpoch,
  };

  static StatementRepaymentAllocation _statementRepaymentAllocationFromRow(
    Map<String, Object?> row,
  ) => StatementRepaymentAllocation(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    statementId: row['statement_id'] as String,
    repaymentEntryId: row['repayment_entry_id'] as String,
    amount: (row['amount'] as num).toDouble(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
  );

  static Map<String, Object?> _creditAccountToRow(
    CreditAccount creditAccount,
    int index,
  ) => <String, Object?>{
    'id': creditAccount.id,
    'book_id': creditAccount.bookId,
    'name': creditAccount.name,
    'institution': creditAccount.institution,
    'card_last4': creditAccount.cardLast4,
    'currency_code': creditAccount.currencyCode,
    'credit_limit': creditAccount.creditLimit,
    'statement_day': creditAccount.statementDay,
    'due_rule_type': creditAccount.dueRuleType.name,
    'due_day': creditAccount.dueDay,
    'days_after_statement': creditAccount.daysAfterStatement,
    'cycle_budget': creditAccount.cycleBudget,
    'sort_order': index,
  };

  static CreditAccount _creditAccountFromRow(Map<String, Object?> row) =>
      CreditAccount(
        id: row['id'] as String,
        bookId: row['book_id'] as String,
        name: row['name'] as String,
        institution: row['institution'] as String? ?? '',
        cardLast4: row['card_last4'] as String? ?? '',
        currencyCode: row['currency_code'] as String? ?? defaultCurrencyCode,
        creditLimit: (row['credit_limit'] as num?)?.toDouble(),
        statementDay: (row['statement_day'] as num?)?.toInt(),
        dueRuleType: CreditDueRuleType.fromStorage(
          row['due_rule_type'] as String?,
        ),
        dueDay: (row['due_day'] as num?)?.toInt(),
        daysAfterStatement: (row['days_after_statement'] as num?)?.toInt(),
        cycleBudget: (row['cycle_budget'] as num?)?.toDouble(),
      );

  static Map<String, Object?> _bookToRow(LedgerBook b, int index) =>
      <String, Object?>{
        'id': b.id,
        'name': b.name,
        'created_at': b.createdAt.millisecondsSinceEpoch,
        'is_default': b.isDefault ? 1 : 0,
        'base_currency_code': b.baseCurrencyCode,
        'currency_setup_status': b.currencySetupStatus.name,
        'sort_order': index,
      };

  static LedgerBook _bookFromRow(Map<String, Object?> row) => LedgerBook(
    id: row['id'] as String,
    name: row['name'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    isDefault: (row['is_default'] as int) != 0,
    baseCurrencyCode:
        row['base_currency_code'] as String? ?? defaultCurrencyCode,
    currencySetupStatus: CurrencySetupStatus.fromStorage(
      row['currency_setup_status'] as String?,
    ),
  );

  static Map<String, Object?> _accountToRow(Account a, int index) =>
      <String, Object?>{
        'id': a.id,
        'book_id': a.bookId,
        'name': a.name,
        'type': a.type.name,
        'group_id': a.groupId,
        'initial_balance': a.initialBalance,
        'currency_code': a.currencyCode,
        'icon_code': a.iconCode,
        'note': a.note,
        'include_in_assets': a.includeInAssets ? 1 : 0,
        'hidden': a.hidden ? 1 : 0,
        'card_last4': a.cardLast4,
        'card_number': a.cardNumber,
        'card_last4_follows': a.cardLast4Follows ? 1 : 0,
        'credit_limit': a.creditLimit,
        'sort_order': index,
        'statement_day': a.statementDay,
        'due_day': a.dueDay,
        'credit_account_id': a.creditAccountId,
      };

  static Account _accountFromRow(Map<String, Object?> row) => Account(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    name: row['name'] as String,
    type: AccountType.fromStorage(row['type'] as String?),
    groupId: row['group_id'] as String?,
    initialBalance: (row['initial_balance'] as num).toDouble(),
    currencyCode: row['currency_code'] as String? ?? defaultCurrencyCode,
    iconCode: normalizeAccountIconCode(row['icon_code'] as String?),
    note: row['note'] as String? ?? '',
    includeInAssets: (row['include_in_assets'] as int) != 0,
    hidden: (row['hidden'] as int) != 0,
    cardLast4: row['card_last4'] as String? ?? '',
    cardNumber: row['card_number'] as String? ?? '',
    cardLast4Follows: (row['card_last4_follows'] as int? ?? 0) != 0,
    creditLimit: (row['credit_limit'] as num?)?.toDouble(),
    statementDay: (row['statement_day'] as num?)?.toInt(),
    dueDay: (row['due_day'] as num?)?.toInt(),
    creditAccountId: row['credit_account_id'] as String?,
  );

  static Map<String, Object?> _groupToRow(AccountGroup g) => <String, Object?>{
    'id': g.id,
    'book_id': g.bookId,
    'name': g.name,
    'sort_order': g.sortOrder,
  };

  static AccountGroup _groupFromRow(Map<String, Object?> row) => AccountGroup(
    id: row['id'] as String,
    bookId: row['book_id'] as String,
    name: row['name'] as String,
    sortOrder: row['sort_order'] as int,
  );

  static Map<String, Object?> _categoryToRow(Category c, int index) =>
      <String, Object?>{
        'id': c.id,
        'label': c.label,
        'type': c.type.storageValue,
        'icon_code': c.iconCode,
        'sort_order': index,
        'parent_id': c.parentId,
      };

  static Category _categoryFromRow(Map<String, Object?> row) {
    return Category(
      id: row['id'] as String,
      label: row['label'] as String,
      type: EntryType.fromStorage(row['type'] as String),
      iconCode: row['icon_code'] as String,
      parentId: Category.normalizeParentId(row['parent_id'] as String?),
    );
  }
}

/// 一张增量表的行级差分计划：相对基线快照需要写入/删除的行，以及应用后应记录的
/// 新基线。[fullReplace] 为 true 表示没有基线可用，必须先清空整表再写入 [upsert]，
/// 否则库里可能残留传入列表之外的行。
class _RowDiff {
  const _RowDiff({
    required this.upsert,
    required this.deleteIds,
    required this.baseline,
    required this.fullReplace,
  });

  final List<Map<String, Object?>> upsert;
  final List<Object> deleteIds;
  final Map<Object, Map<String, Object?>> baseline;
  final bool fullReplace;

  /// 无增删改且无需清空整表——调用方可据此跳过事务。
  bool get isEmpty => !fullReplace && upsert.isEmpty && deleteIds.isEmpty;
}
