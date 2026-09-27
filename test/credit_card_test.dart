import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/models.dart';

void main() {
  test('nextDueDate 当月未过取当月，已过顺延下月', () {
    // 今天 7/10，还款日 25 → 当月 7/25。
    expect(nextDueDate(25, DateTime(2026, 7, 10)), DateTime(2026, 7, 25));
    // 今天 7/26，还款日 25 → 下月 8/25。
    expect(nextDueDate(25, DateTime(2026, 7, 26)), DateTime(2026, 8, 25));
    // 当天即还款日 → 取当天。
    expect(nextDueDate(10, DateTime(2026, 7, 10)), DateTime(2026, 7, 10));
    // 12 月顺延跨年。
    expect(nextDueDate(5, DateTime(2026, 12, 20)), DateTime(2027, 1, 5));
  });

  test('daysUntilDue 计算剩余天数', () {
    expect(daysUntilDue(25, DateTime(2026, 7, 10)), 15);
    expect(daysUntilDue(10, DateTime(2026, 7, 10)), 0);
    expect(daysUntilDue(25, DateTime(2026, 7, 26)), 30);
  });

  test('正式账单摘要分开已出账待还和未出账消费', () {
    const account = Account(
      id: 'card',
      bookId: 'book',
      name: '招行',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final statement = BillingStatement(
      id: 'statement',
      bookId: 'book',
      accountId: account.id,
      statementDate: DateTime(2026, 8, 25),
      periodStart: DateTime(2026, 7, 26),
      periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
      statementAmount: 3703.85,
      minimumPayment: 370.39,
      dueDate: DateTime(2026, 9, 13),
      paidAmount: 3703.85,
      status: BillingStatementStatus.paid,
    );
    final overview = creditStatementOverview(
      account: account,
      statements: <BillingStatement>[statement],
      entries: <LedgerEntry>[
        LedgerEntry(
          id: 'unbilled',
          bookId: 'book',
          type: EntryType.expense,
          amount: 4047.43,
          categoryId: 'dining',
          accountId: account.id,
          note: '未出账',
          occurredAt: DateTime(2026, 8, 26),
        ),
      ],
      now: DateTime(2026, 9, 1),
    );

    expect(overview.billedOutstanding, 0);
    expect(overview.unbilledAmount, 4047.43);
    expect(overview.latestStatement?.status, BillingStatementStatus.paid);
  });

  test('正式账单摘要按退款到账日计算未出账金额', () {
    const account = Account(
      id: 'card',
      bookId: 'book',
      name: '招行',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final statement = BillingStatement(
      id: 'statement',
      bookId: 'book',
      accountId: account.id,
      statementDate: DateTime(2026, 8, 25),
      periodStart: DateTime(2026, 7, 26),
      periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
      statementAmount: 100,
      minimumPayment: 10,
      dueDate: DateTime(2026, 9, 13),
      paidAmount: 0,
      status: BillingStatementStatus.open,
    );
    final overview = creditStatementOverview(
      account: account,
      statements: <BillingStatement>[statement],
      entries: <LedgerEntry>[
        LedgerEntry(
          id: 'expense',
          bookId: 'book',
          type: EntryType.expense,
          amount: 100,
          categoryId: 'dining',
          accountId: account.id,
          note: '未出账消费',
          occurredAt: DateTime(2026, 8, 26),
        ),
        LedgerEntry(
          id: 'refund',
          bookId: 'book',
          type: EntryType.refund,
          amount: 20,
          categoryId: 'dining',
          accountId: account.id,
          note: '退款原始发生日在账单日前',
          occurredAt: DateTime(2026, 8, 20),
          settledAt: DateTime(2026, 8, 28),
        ),
      ],
      now: DateTime(2026, 9, 1),
    );

    expect(overview.unbilledAmount, 80);
  });

  test('动态还款规则支持次月固定日与账单日后天数', () {
    const fixed = CreditAccount(
      id: 'fixed',
      bookId: 'book',
      name: '招商信用卡',
      institution: '招商银行',
      cardLast4: '4185',
      currencyCode: 'CNY',
      creditLimit: 70000,
      statementDay: 25,
      dueRuleType: CreditDueRuleType.fixedDay,
      dueDay: 13,
      daysAfterStatement: null,
      cycleBudget: null,
    );
    final relative = fixed.copyWith(
      id: 'relative',
      dueRuleType: CreditDueRuleType.daysAfterStatement,
      daysAfterStatement: 20,
    );

    expect(fixed.hasCompleteCycleRule, isTrue);
    expect(relative.hasCompleteCycleRule, isTrue);
    expect(fixed.copyWith(clearDueDay: true).hasCompleteCycleRule, isFalse);
    expect(creditDueDate(fixed, DateTime(2026, 9, 25)), DateTime(2026, 10, 13));
    expect(
      creditDueDate(relative, DateTime(2026, 9, 25)),
      DateTime(2026, 10, 15),
    );
  });

  test('账单日当天可显式归入下一账期且首页四项金额保持一致', () {
    const creditAccount = CreditAccount(
      id: 'cmb-4185',
      bookId: 'book',
      name: '招商信用卡 4185',
      institution: '招商银行',
      cardLast4: '4185',
      currencyCode: 'CNY',
      creditLimit: 70000,
      statementDay: 25,
      dueRuleType: CreditDueRuleType.fixedDay,
      dueDay: 13,
      daysAfterStatement: null,
      cycleBudget: null,
    );
    const account = Account(
      id: 'cmb-cny',
      bookId: 'book',
      name: '招商人民币',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      statementDay: 25,
      dueDay: 13,
      creditAccountId: 'cmb-4185',
    );
    final statement = BillingStatement(
      id: 'cmb-2026-09-25',
      bookId: 'book',
      accountId: account.id,
      statementDate: DateTime(2026, 9, 25),
      periodStart: DateTime(2026, 8, 25),
      periodEnd: DateTime(2026, 9, 25, 8),
      statementAmount: 5497.15,
      minimumPayment: 549.72,
      dueDate: DateTime(2026, 10, 13),
      paidAmount: 0,
      status: BillingStatementStatus.open,
    );
    final entries = <LedgerEntry>[
      LedgerEntry(
        id: 'statement-day-expense',
        bookId: 'book',
        type: EntryType.expense,
        amount: 530.11,
        baseAmount: 530.11,
        categoryId: 'shopping',
        accountId: account.id,
        note: '账单日当天、银行确认属于下一期',
        occurredAt: DateTime(2026, 9, 25, 18),
        billingCycleId: '2026-10-25',
      ),
      LedgerEntry(
        id: 'after-statement-expense',
        bookId: 'book',
        type: EntryType.expense,
        amount: 474.54,
        baseAmount: 474.54,
        categoryId: 'dining',
        accountId: account.id,
        note: '账单日后消费',
        occurredAt: DateTime(2026, 9, 27),
      ),
    ];

    final overview = buildCreditCycleOverview(
      creditAccount: creditAccount,
      accounts: const <Account>[account],
      entries: entries,
      statements: <BillingStatement>[statement],
      allocations: const <StatementRepaymentAllocation>[],
      baseCurrencyCode: 'CNY',
      now: DateTime(2026, 9, 27, 23, 59),
      balanceOf: (_) => -6501.80,
      convertToCreditCurrency: (amount, source, date) => amount,
    );
    final accountOverview = creditStatementOverview(
      account: account,
      entries: entries,
      statements: <BillingStatement>[statement],
      now: DateTime(2026, 9, 27, 23, 59),
    );

    expect(billingCycleIdFor(DateTime(2026, 10, 25)), '2026-10-25');
    expect(overview.netSpending, closeTo(1004.65, 0.001));
    expect(overview.currentCycleDebt, closeTo(1004.65, 0.001));
    expect(overview.billedOutstanding, closeTo(5497.15, 0.001));
    expect(overview.totalDebt, closeTo(6501.80, 0.001));
    expect(accountOverview.unbilledAmount, closeTo(1004.65, 0.001));
    expect(accountOverview.billedOutstanding, closeTo(5497.15, 0.001));
  });

  test('本账期欠款只扣未分配给上期账单的提前还款', () {
    const creditAccount = CreditAccount(
      id: 'cmb-4185',
      bookId: 'book',
      name: '招商信用卡 4185',
      institution: '招商银行',
      cardLast4: '4185',
      currencyCode: 'CNY',
      creditLimit: 70000,
      statementDay: 25,
      dueRuleType: CreditDueRuleType.fixedDay,
      dueDay: 13,
      daysAfterStatement: null,
      cycleBudget: 4000,
    );
    const account = Account(
      id: 'cmb-cny',
      bookId: 'book',
      name: 'CNY 账户',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      creditAccountId: 'cmb-4185',
    );
    final statement = BillingStatement(
      id: 'aug-statement',
      bookId: 'book',
      accountId: account.id,
      statementDate: DateTime(2026, 8, 25),
      periodStart: DateTime(2026, 7, 26),
      periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
      statementAmount: 1000,
      minimumPayment: 100,
      dueDate: DateTime(2026, 9, 13),
      paidAmount: 300,
      status: BillingStatementStatus.partiallyPaid,
    );
    final repayment = LedgerEntry(
      id: 'repayment',
      bookId: 'book',
      type: EntryType.transfer,
      amount: 500,
      accountAmount: 500,
      toAccountAmount: 500,
      categoryId: 'transfer',
      accountId: 'debit',
      toAccountId: account.id,
      note: '还款',
      occurredAt: DateTime(2026, 9, 13),
    );
    final overview = buildCreditCycleOverview(
      creditAccount: creditAccount,
      accounts: const <Account>[account],
      entries: <LedgerEntry>[
        LedgerEntry(
          id: 'expense',
          bookId: 'book',
          type: EntryType.expense,
          amount: 1000,
          baseAmount: 1000,
          categoryId: 'dining',
          accountId: account.id,
          note: '',
          occurredAt: DateTime(2026, 9, 1),
        ),
        repayment,
      ],
      statements: <BillingStatement>[statement],
      allocations: <StatementRepaymentAllocation>[
        StatementRepaymentAllocation(
          id: 'allocation',
          bookId: 'book',
          statementId: statement.id,
          repaymentEntryId: repayment.id,
          amount: 300,
          createdAt: DateTime(2026, 9, 13),
        ),
      ],
      baseCurrencyCode: 'CNY',
      now: DateTime(2026, 9, 14),
      balanceOf: (_) => -1400,
      convertToCreditCurrency: (amount, source, date) => amount,
    );

    expect(overview.netSpending, 1000);
    expect(overview.earlyRepayment, 200);
    expect(overview.currentCycleDebt, 800);
    expect(overview.billedOutstanding, 700);
    expect(overview.totalDebt, 1400);
    expect(overview.nextStatementDate, DateTime(2026, 9, 25));
    expect(overview.dueDate, DateTime(2026, 9, 13));
  });

  test('外币原始消费按实际清算负债进入主体账期汇总', () {
    const creditAccount = CreditAccount(
      id: 'travel-card',
      bookId: 'book',
      name: '旅行信用卡',
      institution: '',
      cardLast4: '7788',
      currencyCode: 'CNY',
      creditLimit: 30000,
      statementDay: 25,
      dueRuleType: CreditDueRuleType.fixedDay,
      dueDay: 13,
      daysAfterStatement: null,
      cycleBudget: null,
    );
    const cnyAccount = Account(
      id: 'card-cny',
      bookId: 'book',
      name: 'CNY 账户',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      currencyCode: 'CNY',
      creditAccountId: 'travel-card',
    );
    const usdAccount = Account(
      id: 'card-usd',
      bookId: 'book',
      name: 'USD 账户',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      currencyCode: 'USD',
      creditAccountId: 'travel-card',
    );
    final overview = buildCreditCycleOverview(
      creditAccount: creditAccount,
      accounts: const <Account>[cnyAccount, usdAccount],
      entries: <LedgerEntry>[
        LedgerEntry(
          id: 'settled-cny',
          bookId: 'book',
          type: EntryType.expense,
          amount: 21.02,
          currencyCode: 'USD',
          accountAmount: 142,
          baseAmount: 142,
          refundedBaseAmount: 42,
          categoryId: 'travel',
          accountId: cnyAccount.id,
          note: '21.02 USD，人民币实际入账 142',
          occurredAt: DateTime(2026, 9, 1),
        ),
        LedgerEntry(
          id: 'usd-liability',
          bookId: 'book',
          type: EntryType.expense,
          amount: 10,
          currencyCode: 'USD',
          accountAmount: 10,
          baseAmount: 72,
          categoryId: 'travel',
          accountId: usdAccount.id,
          note: '美元账户负债',
          occurredAt: DateTime(2026, 9, 2),
        ),
        LedgerEntry(
          id: 'internal-currency-transfer',
          bookId: 'book',
          type: EntryType.transfer,
          amount: 50,
          currencyCode: 'USD',
          accountAmount: 50,
          toAccountAmount: 360,
          baseAmount: 0,
          categoryId: 'transfer',
          accountId: usdAccount.id,
          toAccountId: cnyAccount.id,
          note: '同一主体内部币种调拨，不是提前还款',
          occurredAt: DateTime(2026, 9, 3),
        ),
      ],
      statements: const <BillingStatement>[],
      allocations: const <StatementRepaymentAllocation>[],
      baseCurrencyCode: 'CNY',
      now: DateTime(2026, 9, 10),
      balanceOf: (account) => account.id == cnyAccount.id ? -100 : -10,
      convertToCreditCurrency: (amount, source, date) =>
          source == 'USD' ? amount * 7.2 : amount,
    );

    // 账期消费按冻结本位币：142 - 42 + 72 = 172；总欠款按子账户实际余额换算。
    expect(overview.netSpending, 172);
    expect(overview.earlyRepayment, 0);
    expect(overview.currentCycleDebt, 172);
    expect(overview.totalDebt, 172);
    expect(overview.missingConversion, isFalse);
  });
}
