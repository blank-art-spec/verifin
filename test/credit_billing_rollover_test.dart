import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/models.dart';

const _credit = CreditAccount(
  id: 'huabei',
  bookId: 'book',
  name: '花呗',
  institution: '蚂蚁',
  cardLast4: '',
  currencyCode: 'CNY',
  creditLimit: null,
  statementDay: 5,
  dueRuleType: CreditDueRuleType.daysAfterStatement,
  dueDay: null,
  daysAfterStatement: 10,
  cycleBudget: null,
);

const _account = Account(
  id: 'cny',
  bookId: 'book',
  name: '花呗 CNY',
  type: AccountType.creditAccount,
  groupId: null,
  initialBalance: 0,
  iconCode: 'credit',
  note: '',
  includeInAssets: true,
  hidden: false,
  statementDay: 5,
  creditAccountId: 'huabei',
);

LedgerEntry _expense(
  String id,
  double amount,
  DateTime date, {
  String? cycleId,
}) => LedgerEntry(
  id: id,
  bookId: 'book',
  type: EntryType.expense,
  amount: amount,
  accountId: _account.id,
  categoryId: 'expense',
  note: '',
  occurredAt: date,
  billingCycleId: cycleId,
);

LedgerEntry _repayment(String id, double amount, DateTime date) => LedgerEntry(
  id: id,
  bookId: 'book',
  type: EntryType.transfer,
  amount: amount,
  accountId: 'debit',
  toAccountId: _account.id,
  categoryId: 'transfer',
  note: '',
  occurredAt: date,
);

BillingStatement _statement(DateTime date, double amount, double paid) =>
    BillingStatement(
      id: 'formal-${billingCycleIdFor(date)}',
      bookId: 'book',
      accountId: _account.id,
      statementDate: date,
      periodStart: DateTime(date.year, date.month - 1, 6),
      periodEnd: date,
      statementAmount: amount,
      minimumPayment: 0,
      dueDate: creditDueDate(_credit, date),
      paidAmount: paid,
      status: BillingStatementStatus.open,
    );

CreditCycleOverview _overview(
  DateTime now,
  List<LedgerEntry> entries, {
  List<BillingStatement> statements = const [],
  List<StatementRepaymentAllocation> allocations = const [],
  List<Account> accounts = const [_account],
}) => buildCreditCycleOverview(
  creditAccount: _credit,
  accounts: accounts,
  entries: entries,
  statements: statements,
  allocations: allocations,
  baseCurrencyCode: 'CNY',
  now: now,
  balanceOf: (_) => -138.78,
  convertToCreditCurrency: (amount, currency, date) =>
      currency == 'USD' ? amount * 7.2 : amount,
);

void main() {
  final expense = _expense('expense', 138.78, DateTime(2026, 9, 10));

  test('账单日前未出账，当天及过期后无需正式快照即可结转', () {
    final before = _overview(DateTime(2026, 10, 4, 19), [expense]);
    expect(before.currentCycleDebt, 138.78);
    expect(before.billedOutstanding, 0);
    expect(before.nextStatementDate, DateTime(2026, 10, 5));
    for (final now in [DateTime(2026, 10, 5), DateTime(2026, 10, 6, 19)]) {
      final overview = _overview(now, [expense]);
      expect(overview.currentCycleDebt, 0);
      expect(overview.billedOutstanding, 138.78);
      expect(overview.cycle.start, DateTime(2026, 10, 6));
      expect(overview.nextStatementDate, DateTime(2026, 11, 5));
      expect(overview.dueDate, DateTime(2026, 10, 15));
      final detail = creditStatementOverview(
        account: _account,
        entries: [expense],
        statements: const [],
        now: now,
      );
      expect(detail.billedOutstanding, overview.billedOutstanding);
      expect(detail.unbilledAmount, 0);
      expect(detail.latestStatement, isNull);
    }
  });

  test('明确归入下一账期的账单日消费保持未出账，未来流水不提前结转', () {
    final next = _expense(
      'next',
      30,
      DateTime(2026, 10, 5, 12),
      cycleId: '2026-11-05',
    );
    final overview = _overview(DateTime(2026, 10, 5, 19), [
      expense,
      next,
      _expense('future', 1000, DateTime(2026, 11, 6)),
      expense.copyWith(id: 'other-book', bookId: 'other'),
    ]);
    expect(overview.billedOutstanding, 138.78);
    expect(overview.currentCycleDebt, 30);
  });

  test('同一期正式账单优先，后续缺失账单仍按期结转', () {
    final formal = _statement(DateTime(2026, 10, 5), 120, 20);
    final now = DateTime(2026, 10, 5, 19);
    final overview = _overview(now, [expense], statements: [formal]);
    expect(overview.billedOutstanding, 100);
    final detail = creditStatementOverview(
      account: _account,
      entries: [expense],
      statements: [formal],
      now: now,
    );
    expect(detail.billedOutstanding, 100);
    expect(detail.latestStatement?.id, formal.id);
    final later = _overview(
      DateTime(2026, 11, 5, 19),
      [expense, _expense('october', 50, DateTime(2026, 10, 10))],
      statements: [formal],
    );
    expect(later.billedOutstanding, 150);
    expect(later.currentCycleDebt, 0);
    expect(later.dueDate, DateTime(2026, 10, 15));
  });

  test('提前还款及出账后还款抵扣待还，不重复抵扣本期欠款', () {
    final overview = _overview(DateTime(2026, 10, 6, 19), [
      expense,
      _repayment('early', 38.78, DateTime(2026, 10, 1)),
      _repayment('after', 20, DateTime(2026, 10, 6)),
      _expense('current', 30, DateTime(2026, 10, 6)),
    ]);
    expect(overview.billedOutstanding, closeTo(80, 0.001));
    expect(overview.earlyRepayment, 0);
    expect(overview.currentCycleDebt, 30);
  });

  test('已分配给正式账单的还款不再次冲抵自动结转', () {
    final formal = _statement(DateTime(2026, 9, 5), 1000, 300);
    final repayment = _repayment('repayment', 300, DateTime(2026, 9, 15));
    final allocations = [
      StatementRepaymentAllocation(
        id: 'allocation',
        bookId: 'book',
        statementId: formal.id,
        repaymentEntryId: repayment.id,
        amount: 300,
        createdAt: repayment.occurredAt,
      ),
    ];
    final now = DateTime(2026, 10, 5, 19);
    final overview = _overview(
      now,
      [expense, repayment],
      statements: [formal],
      allocations: allocations,
    );
    expect(overview.billedOutstanding, closeTo(838.78, 0.001));
    final detail = creditStatementOverview(
      account: _account,
      entries: [expense, repayment],
      statements: [formal],
      repaymentAllocations: allocations,
      now: now,
    );
    expect(detail.billedOutstanding, overview.billedOutstanding);
  });

  test('已到账退款只冲抵原信用账户，不重复减入新账期', () {
    final refund = LedgerEntry(
      id: 'refund',
      bookId: 'book',
      type: EntryType.refund,
      amount: 10,
      accountId: _account.id,
      categoryId: 'expense',
      note: '',
      occurredAt: DateTime(2026, 10, 6),
      settledAt: DateTime(2026, 10, 6),
      refundOf: expense.id,
    );
    final entries = [
      expense,
      refund,
      refund.copyWith(id: 'pending', clearSettledAt: true),
      refund.copyWith(id: 'cross-account', accountId: 'debit'),
      refund.copyWith(id: 'future', settledAt: DateTime(2026, 10, 7)),
      _expense('current', 40, DateTime(2026, 10, 6)),
    ];
    final now = DateTime(2026, 10, 6, 19);
    final formal = _statement(DateTime(2026, 9, 5), 0, 0);
    final overview = _overview(now, entries, statements: [formal]);
    final detail = creditStatementOverview(
      account: _account,
      entries: entries,
      statements: [formal],
      now: now,
    );
    expect(overview.billedOutstanding, closeTo(128.78, 0.001));
    expect(detail.billedOutstanding, overview.billedOutstanding);
    expect(detail.unbilledAmount, 40);
  });

  test('多币种使用账户实际清算金额，主体内调拨不当作还款', () {
    final usd = _account.copyWith(id: 'usd', currencyCode: 'USD');
    final usdExpense = expense.copyWith(
      id: 'usd-expense',
      accountId: usd.id,
      currencyCode: 'EUR',
      amount: 9,
      accountAmount: 10,
      baseAmount: 72,
    );
    final internal = _repayment(
      'internal',
      50,
      DateTime(2026, 10, 1),
    ).copyWith(accountId: usd.id);
    final overview = _overview(
      DateTime(2026, 10, 5, 19),
      [expense, usdExpense, internal],
      accounts: [_account, usd],
    );
    expect(overview.billedOutstanding, closeTo(210.78, 0.001));
    expect(overview.missingConversion, isFalse);
    final detail = creditStatementOverview(
      account: usd,
      entries: [usdExpense],
      statements: const [],
      now: DateTime(2026, 10, 5, 19),
    );
    expect(detail.billedOutstanding, 10);
  });

  test('跨年推进且不从初始负余额猜造账单', () {
    final overview = _overview(DateTime(2026, 12, 5, 19), [
      _expense('december', 20, DateTime(2026, 11, 6)),
    ]);
    expect(overview.nextStatementDate, DateTime(2027, 1, 5));
    expect(overview.billedOutstanding, 20);
    expect(_overview(DateTime(2026, 10, 5), []).billedOutstanding, 0);
  });

  test('未来正式账单不覆盖当前结转，跨月漏录与重复读取保持一致', () {
    final entries = [expense, _expense('older', 50, DateTime(2026, 8, 10))];
    final future = _statement(DateTime(2026, 11, 5), 999, 0);
    final now = DateTime(2026, 10, 6, 19);
    for (var read = 0; read < 2; read++) {
      final overview = _overview(now, entries, statements: [future]);
      expect(overview.billedOutstanding, closeTo(188.78, 0.001));
      expect(overview.dueDate, DateTime(2026, 9, 15));
      final detail = creditStatementOverview(
        account: _account,
        entries: entries,
        statements: [future],
        now: now,
      );
      expect(detail.billedOutstanding, overview.billedOutstanding);
      expect(detail.latestStatement, isNull);
    }
    expect(future.paidAmount, 0);
    expect(entries, hasLength(2));
  });
}
