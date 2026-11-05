import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';

const _parent = CreditAccount(
  id: 'parent',
  bookId: 'book',
  name: '测试信用卡',
  institution: '',
  cardLast4: '',
  currencyCode: 'CNY',
  creditLimit: null,
  statementDay: 5,
  dueRuleType: CreditDueRuleType.daysAfterStatement,
  dueDay: null,
  daysAfterStatement: 10,
  cycleBudget: null,
);

/// 构造 [currency] 币种的信用子账户，所有用例共用每月 5 日出账规则。
Account _account([String currency = 'CNY']) => Account(
  id: currency,
  bookId: 'book',
  name: currency,
  type: AccountType.creditCard,
  groupId: null,
  initialBalance: 0,
  iconCode: 'credit',
  note: '',
  includeInAssets: true,
  hidden: false,
  statementDay: 5,
  creditAccountId: _parent.id,
  currencyCode: currency,
);

/// 构造一笔 [amount] 支出；[occurredAt] 是消费事实，[postDate] 是可选银行入账
/// 时刻，[cycleId] 表示银行已经明确的账期，[reference] 为明确本币参考金额。
LedgerEntry _expense(
  String id,
  double amount,
  DateTime occurredAt, {
  DateTime? postDate,
  String? cycleId,
  String currency = 'CNY',
  double? reference,
}) => LedgerEntry(
  id: id,
  bookId: 'book',
  type: EntryType.expense,
  amount: amount,
  currencyCode: currency,
  accountId: currency,
  categoryId: 'expense',
  note: '',
  occurredAt: occurredAt,
  postDate: postDate,
  postDatePrecision: OccurredAtPrecision.minute,
  billingCycleId: cycleId,
  referenceBaseAmount: reference,
);

/// 按 [now] 查询父账户汇总；[statements] 提供真实账单，[currency] 选择唯一子账户。
/// 固定汇率只供本测试检查归期与还款顺序，不代表银行实际结算汇率。
CreditCycleOverview _overview(
  DateTime now,
  List<LedgerEntry> entries, {
  List<BillingStatement> statements = const [],
  String currency = 'CNY',
}) => buildCreditCycleOverview(
  creditAccount: _parent,
  accounts: [_account(currency)],
  entries: entries,
  statements: statements,
  allocations: const [],
  baseCurrencyCode: 'CNY',
  now: now,
  balanceOf: (_) => -100,
  convertToCreditCurrency: (amount, currency, date) =>
      currency == 'CNY' ? amount : amount * 7,
);

/// 构造 [date] 出账、金额为 [amount] 的正式账单，周期结束于出账日前一天。
BillingStatement _statement(DateTime date, double amount) => BillingStatement(
  id: billingCycleIdFor(date),
  bookId: 'book',
  accountId: 'CNY',
  statementDate: date,
  periodStart: DateTime(date.year, date.month - 1, 5),
  periodEnd: addCalendarDays(date, -1),
  statementAmount: amount,
  minimumPayment: 0,
  dueDate: creditDueDate(_parent, date),
  paidAmount: 0,
  status: BillingStatementStatus.open,
);

/// 覆盖入账跨期、时分截止、正式账单及还款顺序，验证新口径与原消费事实相互独立。
void main() {
  test('消费在出账日前、入账在出账日时优先归入下一期，未填沿用消费日', () {
    final occurredAt = DateTime(2026, 11, 4, 23, 50);
    final posted = _expense(
      'posted',
      100,
      occurredAt,
      postDate: DateTime(2026, 11, 5, 0, 10),
    );
    final fallback = _expense('fallback', 20, occurredAt);
    final now = DateTime(2026, 11, 5, 10);
    final entries = [posted, fallback];
    final parent = _overview(now, entries);
    final child = creditStatementOverview(
      account: _account(),
      entries: entries,
      statements: const [],
      now: now,
    );
    expect(parent.billedOutstanding, 20);
    expect(parent.currentCycleDebt, 100);
    expect(parent.netSpending, 100);
    expect(parent.dueOutstandingAmount, 20);
    expect(child.billedOutstanding, 20);
    expect(child.unbilledAmount, 100);
    expect(
      billingCycleExpense(entries, 'CNY', currentBillingCycle(5, now)),
      100,
    );
    expect(accountEffectDate(posted), occurredAt);
    expect(posted.occurredAt, occurredAt);

    final cleared = posted.copyWith(clearPostDate: true);
    expect(_overview(now, [cleared]).billedOutstanding, 100);
    expect(_overview(now, [cleared]).currentCycleDebt, 0);
  });

  test('具体入账时间尚未到达时不提前增加本期金额，达到时分后生效', () {
    final posted = _expense(
      'posted-at-noon',
      100,
      DateTime(2026, 11, 4),
      postDate: DateTime(2026, 11, 5, 12, 30),
    );
    for (final sample in [
      (now: DateTime(2026, 11, 5, 12, 29), expected: 0.0),
      (now: DateTime(2026, 11, 5, 12, 30), expected: 100.0),
    ]) {
      final parent = _overview(sample.now, [posted]);
      final child = creditStatementOverview(
        account: _account(),
        entries: [posted],
        statements: const [],
        now: sample.now,
      );
      expect(parent.currentCycleDebt, sample.expected);
      expect(parent.billedOutstanding, 0);
      expect(child.unbilledAmount, sample.expected);
      expect(child.billedOutstanding, 0);
      expect(
        billingCycleExpense(
          [posted],
          'CNY',
          currentBillingCycle(5, sample.now),
          now: sample.now,
        ),
        sample.expected,
      );
    }
    expect(
      billingCycleExpense(
        [posted],
        'CNY',
        currentBillingCycle(5, DateTime(2026, 11, 5)),
      ),
      100,
      reason: '不指定实时截止点时，历史周期汇总仍包含整个账期',
    );
  });

  test('银行明确账期仍优先，但未来具体入账时刻不会提前成为流水待还', () {
    final posted = _expense(
      'confirmed-cycle',
      100,
      DateTime(2026, 11, 4),
      postDate: DateTime(2026, 11, 5, 12, 30),
      cycleId: '2026-11-05',
    );
    final statement = _statement(DateTime(2026, 11, 5), 100);
    expect(creditExpenseBelongsToStatement(posted, statement), isTrue);
    expect(
      _overview(DateTime(2026, 11, 5, 12, 29), [posted]).billedOutstanding,
      0,
    );
    final effective = _overview(DateTime(2026, 11, 5, 12, 30), [posted]);
    expect(effective.billedOutstanding, 100);
    expect(effective.currentCycleDebt, 0);
  });

  test('正式账单按入账日期匹配消费，跨期入账不会被上一期快照重复吸收', () {
    final posted = _expense(
      'cross-cycle',
      100,
      DateTime(2026, 11, 4),
      postDate: DateTime(2026, 11, 5),
    );
    final oldStatement = _statement(DateTime(2026, 11, 5), 20);
    final newStatement = _statement(DateTime(2026, 12, 5), 100);
    expect(creditExpenseBelongsToStatement(posted, oldStatement), isFalse);
    expect(creditExpenseBelongsToStatement(posted, newStatement), isTrue);
    final beforeNextBill = _overview(
      DateTime(2026, 11, 6),
      [posted],
      statements: [oldStatement],
    );
    expect(beforeNextBill.billedOutstanding, 20);
    expect(beforeNextBill.currentCycleDebt, 100);
    final afterNextBill = _overview(
      DateTime(2026, 12, 6),
      [posted],
      statements: [oldStatement, newStatement],
    );
    expect(afterNextBill.billedOutstanding, 120);
    expect(afterNextBill.currentCycleDebt, 0);
  });

  test('未配置账单日时正式截止日包含全部入账时刻，次日才进入未出账', () {
    final statement = _statement(DateTime(2026, 11, 5), 100);
    final entries = [
      _expense(
        'cutoff-last-second',
        100,
        DateTime(2026, 11, 3),
        postDate: DateTime(2026, 11, 4, 23, 59, 59),
      ),
      _expense(
        'following-midnight',
        20,
        DateTime(2026, 11, 4),
        postDate: DateTime(2026, 11, 5),
      ),
    ];
    expect(creditExpenseBelongsToStatement(entries.first, statement), isTrue);
    expect(creditExpenseBelongsToStatement(entries.last, statement), isFalse);
    final overview = creditStatementOverview(
      account: _account().copyWith(clearStatementDay: true),
      entries: entries,
      statements: [statement],
      now: DateTime(2026, 11, 5, 12),
    );
    expect(overview.billedOutstanding, 100);
    expect(overview.unbilledAmount, 20);
  });

  test('出账后退款按原支出的入账账期冲抵正式账单', () {
    final posted = _expense(
      'original',
      100,
      DateTime(2026, 10, 4),
      postDate: DateTime(2026, 10, 6),
    );
    final oldStatement = _statement(DateTime(2026, 10, 5), 50);
    final newStatement = _statement(DateTime(2026, 11, 5), 100);
    final refund = LedgerEntry(
      id: 'refund',
      bookId: 'book',
      type: EntryType.refund,
      amount: 30,
      accountId: 'CNY',
      categoryId: 'expense',
      note: '',
      occurredAt: DateTime(2026, 11, 6),
      settledAt: DateTime(2026, 11, 6),
      refundOf: posted.id,
    );
    final allocations = allocateStatementRefunds(
      entries: [posted, refund],
      statements: [oldStatement, newStatement],
      now: DateTime(2026, 11, 7),
    );
    expect(allocations.single.statementId, newStatement.id);
    expect(allocations.single.amount, 30);
    final child = creditStatementOverview(
      account: _account(),
      entries: [posted, refund],
      statements: [oldStatement, newStatement],
      now: DateTime(2026, 11, 7),
    );
    expect(child.billedOutstanding, 120);
    expect(child.unbilledAmount, 0);
  });

  test('同账期部分还款按实际入账先后抵扣，剩余参考额与消费顺序无关', () {
    final laterPosted = _expense(
      'consumed-first',
      10,
      DateTime(2026, 10, 7),
      postDate: DateTime(2026, 10, 10, 12),
      currency: 'USD',
      reference: 70,
    );
    final earlierPosted = _expense(
      'consumed-later',
      10,
      DateTime(2026, 10, 8),
      postDate: DateTime(2026, 10, 10, 11),
      currency: 'USD',
      reference: 80,
    );
    final repayment = LedgerEntry(
      id: 'repayment',
      bookId: 'book',
      type: EntryType.transfer,
      amount: 10,
      currencyCode: 'USD',
      accountId: '',
      toAccountId: 'USD',
      categoryId: 'transfer',
      note: '',
      occurredAt: DateTime(2026, 11, 6),
    );
    for (final expenses in [
      [laterPosted, earlierPosted],
      [earlierPosted, laterPosted],
    ]) {
      final overview = _overview(DateTime(2026, 11, 7), [
        ...expenses,
        repayment,
      ], currency: 'USD');
      expect(overview.billedOutstanding, 70);
      expect(overview.dueOutstandingAmount, 70);
    }
  });
}
