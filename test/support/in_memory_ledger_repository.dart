import 'package:verifin/app/models.dart';
import 'package:verifin/data/ledger_repository.dart';

/// 纯内存仓储实现，供 widget / 控制器逻辑测试注入。
///
/// saveX 同步更新内部状态（返回已完成的 Future），因此不会引入真实异步 I/O，
/// 避免与 testWidgets 的 fake-async 冲突；同一实例在多个控制器间共享即模拟重启后
/// 从同一存储重新载入。
class InMemoryLedgerRepository implements LedgerRepository {
  List<LedgerEntry> _entries = <LedgerEntry>[];
  List<CaptureEvent> _captureEvents = <CaptureEvent>[];
  List<AutoCaptureRule> _autoCaptureRules = <AutoCaptureRule>[];
  List<LedgerBook> _books = <LedgerBook>[];
  List<Account> _accounts = <Account>[];
  List<AccountGroup> _groups = <AccountGroup>[];
  List<CreditAccount> _creditAccounts = <CreditAccount>[];
  List<Category> _categories = <Category>[];
  List<Tag> _tags = <Tag>[];
  List<Attachment> _attachments = <Attachment>[];
  List<RecurringRule> _recurringRules = <RecurringRule>[];
  List<ExchangeRate> _exchangeRates = <ExchangeRate>[];
  List<BalanceAnchor> _balanceAnchors = <BalanceAnchor>[];
  List<BillingStatement> _billingStatements = <BillingStatement>[];
  List<StatementRepaymentAllocation> _statementRepaymentAllocations =
      <StatementRepaymentAllocation>[];
  Map<String, double> _monthlyBudgets = <String, double>{};
  Map<String, double> _categoryBudgets = <String, double>{};
  Map<String, double> _dailyBudgets = <String, double>{};

  @override
  Future<List<LedgerEntry>> loadEntries() async =>
      List<LedgerEntry>.of(_entries);

  @override
  Future<void> saveEntries(List<LedgerEntry> entries) async {
    _entries = List<LedgerEntry>.of(entries);
  }

  @override
  Future<List<CaptureEvent>> loadCaptureEvents() async =>
      List<CaptureEvent>.of(_captureEvents);

  @override
  Future<void> saveCaptureEvents(List<CaptureEvent> events) async {
    _captureEvents = List<CaptureEvent>.of(events);
  }

  @override
  Future<List<AutoCaptureRule>> loadAutoCaptureRules() async =>
      List<AutoCaptureRule>.of(_autoCaptureRules);

  @override
  Future<void> saveAutoCaptureRules(List<AutoCaptureRule> rules) async {
    _autoCaptureRules = List<AutoCaptureRule>.of(rules);
  }

  @override
  Future<void> saveAutoCaptureMetadata({
    required List<CaptureEvent> captureEvents,
    required List<AutoCaptureRule> rules,
  }) async {
    _captureEvents = List<CaptureEvent>.of(captureEvents);
    _autoCaptureRules = List<AutoCaptureRule>.of(rules);
  }

  @override
  Future<void> saveCaptureProcessing({
    required List<LedgerEntry> entries,
    required List<CaptureEvent> captureEvents,
  }) async {
    _entries = List<LedgerEntry>.of(entries);
    _captureEvents = List<CaptureEvent>.of(captureEvents);
  }

  @override
  Future<List<LedgerBook>> loadBooks() async => List<LedgerBook>.of(_books);

  @override
  Future<void> saveBooks(List<LedgerBook> books) async {
    _books = List<LedgerBook>.of(books);
  }

  @override
  Future<List<Account>> loadAccounts() async => List<Account>.of(_accounts);

  @override
  Future<void> saveAccounts(List<Account> accounts) async {
    _accounts = List<Account>.of(accounts);
  }

  @override
  Future<List<CreditAccount>> loadCreditAccounts() async =>
      List<CreditAccount>.of(_creditAccounts);

  @override
  Future<void> saveCreditAccounts(List<CreditAccount> creditAccounts) async {
    _creditAccounts = List<CreditAccount>.of(creditAccounts);
  }

  @override
  Future<void> saveCreditAccountAggregate({
    required List<CreditAccount> creditAccounts,
    required List<Account> accounts,
  }) async {
    _creditAccounts = List<CreditAccount>.of(creditAccounts);
    _accounts = List<Account>.of(accounts);
  }

  @override
  Future<List<AccountGroup>> loadAccountGroups() async =>
      List<AccountGroup>.of(_groups);

  @override
  Future<void> saveAccountGroups(List<AccountGroup> groups) async {
    _groups = List<AccountGroup>.of(groups);
  }

  @override
  Future<List<Category>> loadCategories() async =>
      List<Category>.of(_categories);

  @override
  Future<void> saveCategories(List<Category> categories) async {
    _categories = List<Category>.of(categories);
  }

  @override
  Future<List<Tag>> loadTags() async => List<Tag>.of(_tags);

  @override
  Future<void> saveTags(List<Tag> tags) async {
    _tags = List<Tag>.of(tags);
  }

  @override
  Future<List<Attachment>> loadAttachments() async =>
      List<Attachment>.of(_attachments);

  @override
  Future<void> saveAttachments(List<Attachment> attachments) async {
    _attachments = List<Attachment>.of(attachments);
  }

  @override
  Future<void> saveEntryAggregate({
    required List<LedgerEntry> entries,
    required List<Attachment> attachments,
    List<ExchangeRate>? exchangeRates,
  }) async {
    _entries = List<LedgerEntry>.of(entries);
    _attachments = List<Attachment>.of(attachments);
    if (exchangeRates != null) {
      _exchangeRates = List<ExchangeRate>.of(exchangeRates);
    }
  }

  @override
  Future<List<RecurringRule>> loadRecurringRules() async =>
      List<RecurringRule>.of(_recurringRules);

  @override
  Future<void> saveRecurringRules(List<RecurringRule> rules) async {
    _recurringRules = List<RecurringRule>.of(rules);
  }

  @override
  Future<void> saveRecurringGeneration({
    required List<LedgerEntry> entries,
    required List<RecurringRule> recurringRules,
  }) async {
    _entries = List<LedgerEntry>.of(entries);
    _recurringRules = List<RecurringRule>.of(recurringRules);
  }

  @override
  Future<List<ExchangeRate>> loadExchangeRates() async =>
      List<ExchangeRate>.of(_exchangeRates);

  @override
  Future<void> saveExchangeRates(List<ExchangeRate> rates) async {
    _exchangeRates = List<ExchangeRate>.of(rates);
  }

  @override
  Future<List<BalanceAnchor>> loadBalanceAnchors() async =>
      List<BalanceAnchor>.of(_balanceAnchors);

  @override
  Future<void> saveBalanceAnchors(List<BalanceAnchor> anchors) async {
    _balanceAnchors = List<BalanceAnchor>.of(anchors);
  }

  @override
  Future<List<BillingStatement>> loadBillingStatements() async =>
      List<BillingStatement>.of(_billingStatements);

  @override
  Future<void> saveBillingStatements(List<BillingStatement> statements) async {
    _billingStatements = List<BillingStatement>.of(statements);
  }

  @override
  Future<List<StatementRepaymentAllocation>>
  loadStatementRepaymentAllocations() async =>
      List<StatementRepaymentAllocation>.of(_statementRepaymentAllocations);

  @override
  Future<void> saveStatementRepaymentAllocations(
    List<StatementRepaymentAllocation> allocations,
  ) async {
    _statementRepaymentAllocations = List<StatementRepaymentAllocation>.of(
      allocations,
    );
  }

  @override
  Future<void> saveCreditAggregate({
    required List<LedgerEntry> entries,
    required List<BillingStatement> statements,
    required List<StatementRepaymentAllocation> allocations,
  }) async {
    _entries = List<LedgerEntry>.of(entries);
    _billingStatements = List<BillingStatement>.of(statements);
    _statementRepaymentAllocations = List<StatementRepaymentAllocation>.of(
      allocations,
    );
  }

  @override
  Future<Map<String, double>> loadMonthlyBudgets() async =>
      Map<String, double>.of(_monthlyBudgets);

  @override
  Future<void> saveMonthlyBudgets(Map<String, double> budgets) async {
    _monthlyBudgets = Map<String, double>.of(budgets);
  }

  @override
  Future<Map<String, double>> loadCategoryBudgets() async =>
      Map<String, double>.of(_categoryBudgets);

  @override
  Future<void> saveCategoryBudgets(Map<String, double> budgets) async {
    _categoryBudgets = Map<String, double>.of(budgets);
  }

  @override
  Future<Map<String, double>> loadDailyBudgets() async =>
      Map<String, double>.of(_dailyBudgets);

  @override
  Future<void> saveDailyBudgets(Map<String, double> budgets) async {
    _dailyBudgets = Map<String, double>.of(budgets);
  }

  @override
  Future<void> saveBudgetSettings({
    required Map<String, double> monthlyBudgets,
    required Map<String, double> categoryBudgets,
    required Map<String, double> dailyBudgets,
  }) async {
    _monthlyBudgets = Map<String, double>.of(monthlyBudgets);
    _categoryBudgets = Map<String, double>.of(categoryBudgets);
    _dailyBudgets = Map<String, double>.of(dailyBudgets);
  }

  @override
  Future<void> replaceAllLedgerData(LedgerDataSnapshot snapshot) async {
    _books = List<LedgerBook>.of(snapshot.books);
    _accounts = List<Account>.of(snapshot.accounts);
    _groups = List<AccountGroup>.of(snapshot.accountGroups);
    _creditAccounts = List<CreditAccount>.of(snapshot.creditAccounts);
    _categories = List<Category>.of(snapshot.categories);
    _tags = List<Tag>.of(snapshot.tags);
    _attachments = List<Attachment>.of(snapshot.attachments);
    _entries = List<LedgerEntry>.of(snapshot.entries);
    _recurringRules = List<RecurringRule>.of(snapshot.recurringRules);
    _exchangeRates = List<ExchangeRate>.of(snapshot.exchangeRates);
    _balanceAnchors = List<BalanceAnchor>.of(snapshot.balanceAnchors);
    _billingStatements = List<BillingStatement>.of(snapshot.billingStatements);
    _statementRepaymentAllocations = List<StatementRepaymentAllocation>.of(
      snapshot.statementRepaymentAllocations,
    );
    _monthlyBudgets = Map<String, double>.of(snapshot.monthlyBudgets);
    _categoryBudgets = Map<String, double>.of(snapshot.categoryBudgets);
    _dailyBudgets = Map<String, double>.of(snapshot.dailyBudgets);
  }

  @override
  Future<bool> hasAnyData() async =>
      _entries.isNotEmpty ||
      _books.isNotEmpty ||
      _accounts.isNotEmpty ||
      _groups.isNotEmpty ||
      _creditAccounts.isNotEmpty ||
      _categories.isNotEmpty ||
      _exchangeRates.isNotEmpty ||
      _balanceAnchors.isNotEmpty ||
      _billingStatements.isNotEmpty ||
      _statementRepaymentAllocations.isNotEmpty;
}
