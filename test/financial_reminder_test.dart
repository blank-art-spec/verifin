import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/reminder/financial_reminder.dart';

void main() {
  const creditAccount = CreditAccount(
    id: 'cmb',
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
    cycleBudget: 4000,
  );
  const cnyAccount = Account(
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
    currencyCode: 'CNY',
    creditAccountId: 'cmb',
  );
  const usdAccount = Account(
    id: 'cmb-usd',
    bookId: 'book',
    name: '招商美元',
    type: AccountType.creditCard,
    groupId: null,
    initialBalance: 0,
    iconCode: 'credit',
    note: '',
    includeInAssets: true,
    hidden: false,
    currencyCode: 'USD',
    creditAccountId: 'cmb',
  );

  /// 构造指定消费和账单的提醒投影，减少每条测试重复无关的账期字段。
  CreditReminderSnapshot snapshotFor({
    required double netSpending,
    double earlyRepayment = 0,
    Iterable<LedgerEntry> entries = const <LedgerEntry>[],
    DateTime? now,
    Iterable<BillingStatement> statements = const <BillingStatement>[],
    double? Function(double, String, DateTime)? convert,
  }) {
    final reference = now ?? DateTime(2026, 9, 27);
    final statementList = statements.toList(growable: false);
    final converter =
        convert ?? (double amount, String _, DateTime _) => amount;
    return buildCreditReminderSnapshot(
      creditAccount: creditAccount,
      overview: buildCreditCycleOverview(
        creditAccount: creditAccount,
        accounts: const <Account>[cnyAccount, usdAccount],
        entries: <LedgerEntry>[
          if (netSpending > 0)
            LedgerEntry(
              id: 'current-expense',
              bookId: 'book',
              type: EntryType.expense,
              amount: netSpending,
              baseAmount: netSpending,
              accountId: cnyAccount.id,
              categoryId: 'expense',
              note: '',
              occurredAt: reference,
            ),
          if (earlyRepayment > 0)
            LedgerEntry(
              id: 'current-repayment',
              bookId: 'book',
              type: EntryType.transfer,
              amount: earlyRepayment,
              accountId: 'debit',
              toAccountId: cnyAccount.id,
              categoryId: 'transfer',
              note: '',
              occurredAt: reference,
            ),
          ...entries,
        ],
        statements: statementList,
        allocations: const <StatementRepaymentAllocation>[],
        baseCurrencyCode: 'CNY',
        now: reference,
        balanceOf: (_) => 0,
        convertToCreditCurrency: converter,
      ),
      childAccounts: const <Account>[cnyAccount, usdAccount],
      statements: statementList,
      now: reference,
      convertToCreditCurrency: converter,
    );
  }

  /// 构造一张正式账单；[paid] 用于覆盖部分还款和已结清边界。
  BillingStatement statementFor({
    required String id,
    required String accountId,
    required DateTime statementDate,
    required DateTime dueDate,
    required double amount,
    double paid = 0,
    double refunded = 0,
    String currencyCode = 'CNY',
  }) {
    return BillingStatement(
      id: id,
      bookId: 'book',
      accountId: accountId,
      statementDate: statementDate,
      periodStart: DateTime(statementDate.year, statementDate.month - 1, 26),
      periodEnd: statementDate,
      statementAmount: amount,
      minimumPayment: amount * 0.1,
      dueDate: dueDate,
      paidAmount: paid,
      refundAmount: refunded,
      status: paid >= amount
          ? BillingStatementStatus.paid
          : BillingStatementStatus.open,
      currencyCode: currencyCode,
    );
  }

  LedgerEntry expenseFor({
    String id = 'previous-expense',
    double amount = 1000,
    String? accountId,
    String currencyCode = 'CNY',
    DateTime? date,
  }) => LedgerEntry(
    id: id,
    bookId: 'book',
    type: EntryType.expense,
    amount: amount,
    currencyCode: currencyCode,
    accountAmount: amount,
    baseAmount: currencyCode == 'USD' ? amount * 7 : amount,
    accountId: accountId ?? cnyAccount.id,
    categoryId: 'expense',
    note: '',
    occurredAt: date ?? DateTime(2026, 9, 24),
  );

  group('CreditReminderSnapshot', () {
    test('无正式账单时，消费在出账日结转后即可提醒，未出账不提醒', () {
      final entries = <LedgerEntry>[expenseFor()];
      final before = snapshotFor(
        netSpending: 0,
        entries: entries,
        now: DateTime(2026, 9, 24, 23, 59),
      );
      expect(before.hasFormalStatement, isFalse);
      expect(before.hasOutstandingStatement, isFalse);
      expect(before.dueOutstandingAmount, 0);

      for (final now in <DateTime>[
        DateTime(2026, 9, 25),
        DateTime(2026, 9, 27),
      ]) {
        final billed = snapshotFor(netSpending: 0, entries: entries, now: now);
        expect(billed.hasFormalStatement, isFalse);
        expect(billed.hasOutstandingStatement, isTrue);
        expect(billed.dueOutstandingAmount, 1000);
        expect(billed.dueDate, DateTime(2026, 10, 13));
      }
    });

    test('流水结转待还扣除实际还款和到账退款，清零后不提醒', () {
      for (final amounts in <(double, double, double)>[
        (400, 200, 400),
        (1000, 0, 0),
        (1200, 0, 0),
        (0, 1000, 0),
      ]) {
        final (paid, refunded, expected) = amounts;
        final snapshot = snapshotFor(
          netSpending: 0,
          entries: <LedgerEntry>[
            expenseFor(),
            if (paid > 0)
              LedgerEntry(
                id: 'repayment',
                bookId: 'book',
                type: EntryType.transfer,
                amount: paid,
                accountId: 'debit',
                toAccountId: cnyAccount.id,
                categoryId: 'transfer',
                note: '',
                occurredAt: DateTime(2026, 9, 27),
              ),
            if (refunded > 0)
              LedgerEntry(
                id: 'refund',
                bookId: 'book',
                type: EntryType.refund,
                amount: refunded,
                accountId: cnyAccount.id,
                categoryId: 'expense',
                note: '',
                refundOf: 'previous-expense',
                occurredAt: DateTime(2026, 9, 26),
                settledAt: DateTime(2026, 9, 26),
              ),
          ],
        );
        expect(snapshot.dueOutstandingAmount, expected);
        expect(snapshot.hasOutstandingStatement, expected > 0);
      }
    });

    test('正式账单覆盖同一期消费后以正式待还为准，不重复结转', () {
      final snapshot = snapshotFor(
        netSpending: 0,
        entries: <LedgerEntry>[expenseFor()],
        statements: <BillingStatement>[
          statementFor(
            id: 'formal',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 800,
            paid: 200,
          ),
        ],
      );
      expect(snapshot.dueOutstandingAmount, 600);
      expect(snapshot.overview.billedOutstanding, 600);
    });

    test('正式账单与流水结转同日到期合并，多币种按主体币种提醒', () {
      final snapshot = snapshotFor(
        netSpending: 100,
        entries: <LedgerEntry>[
          expenseFor(
            accountId: usdAccount.id,
            currencyCode: 'USD',
            amount: 100,
          ),
        ],
        statements: <BillingStatement>[
          statementFor(
            id: 'formal',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 1000,
            paid: 800,
          ),
        ],
        convert: (amount, code, _) => code == 'USD' ? amount * 7 : amount,
      );
      expect(snapshot.dueDate, DateTime(2026, 10, 13));
      expect(snapshot.dueOutstandingAmount, 900);
      expect(snapshot.hasOutstandingStatement, isTrue);
    });

    test('流水结转早于正式账单到期时，使用结转的到期日和金额', () {
      final snapshot = snapshotFor(
        netSpending: 0,
        entries: <LedgerEntry>[
          expenseFor(
            accountId: usdAccount.id,
            currencyCode: 'USD',
            amount: 100,
          ),
        ],
        statements: <BillingStatement>[
          statementFor(
            id: 'later-formal',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 11, 13),
            amount: 1000,
          ),
        ],
        convert: (amount, code, _) => code == 'USD' ? amount * 7 : amount,
      );
      expect(snapshot.dueDate, DateTime(2026, 10, 13));
      expect(snapshot.dueOutstandingAmount, 700);
    });

    test('结转待还缺汇率时不拿同日人民币部分金额发提醒', () {
      final snapshot = snapshotFor(
        netSpending: 0,
        entries: <LedgerEntry>[
          expenseFor(),
          expenseFor(
            id: 'usd-expense',
            accountId: usdAccount.id,
            currencyCode: 'USD',
            amount: 100,
          ),
        ],
        convert: (amount, code, _) => code == 'USD' ? null : amount,
      );
      expect(snapshot.dueDate, DateTime(2026, 10, 13));
      expect(snapshot.dueOutstandingAmount, isNull);
      expect(snapshot.hasOutstandingStatement, isFalse);
    });

    test('出账提醒仅在当前账期存在待还金额时启用', () {
      expect(snapshotFor(netSpending: 0).hasUpcomingStatementDebt, isFalse);
      expect(snapshotFor(netSpending: 100).hasUpcomingStatementDebt, isTrue);
      expect(
        snapshotFor(
          netSpending: 100,
          earlyRepayment: 100,
        ).hasUpcomingStatementDebt,
        isFalse,
      );
      expect(
        snapshotFor(
          netSpending: 100,
          earlyRepayment: 120,
        ).hasUpcomingStatementDebt,
        isFalse,
      );
      expect(
        snapshotFor(
          netSpending: 100,
          earlyRepayment: 40,
        ).hasUpcomingStatementDebt,
        isTrue,
      );
    });

    test('已结清或零额账单不能被未出账消费误触发还款提醒', () {
      for (final amounts in <(double, double, double)>[
        (0, 0, 0),
        (100, 100, 0),
        (100, 0, 100),
      ]) {
        final (amount, paid, refunded) = amounts;
        final snapshot = snapshotFor(
          netSpending: 500,
          statements: <BillingStatement>[
            statementFor(
              id: 'settled',
              accountId: cnyAccount.id,
              statementDate: DateTime(2026, 9, 25),
              dueDate: DateTime(2026, 10, 13),
              amount: amount,
              paid: paid,
              refunded: refunded,
            ),
          ],
        );
        expect(snapshot.hasFormalStatement, isTrue);
        expect(snapshot.hasOutstandingStatement, isFalse);
        expect(snapshot.dueOutstandingAmount, 0);
      }
      expect(snapshotFor(netSpending: 500).hasOutstandingStatement, isFalse);
    });

    test('账期预算按 80%、达到与超出分为三级', () {
      expect(
        snapshotFor(netSpending: 3199).budgetAlertLevel,
        CycleBudgetAlertLevel.none,
      );
      expect(
        snapshotFor(netSpending: 3200).budgetAlertLevel,
        CycleBudgetAlertLevel.warning,
      );
      expect(
        snapshotFor(netSpending: 4000).budgetAlertLevel,
        CycleBudgetAlertLevel.reached,
      );
      expect(
        snapshotFor(netSpending: 4300).budgetAlertLevel,
        CycleBudgetAlertLevel.exceeded,
      );
      expect(
        snapshotFor(netSpending: 4300).budgetUsageRatio,
        closeTo(1.075, 1e-9),
      );
    });

    test('最近同日多币种账单合并，旧账单不冒充本期', () {
      final snapshot = snapshotFor(
        netSpending: 100,
        statements: <BillingStatement>[
          statementFor(
            id: 'old',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 8, 25),
            dueDate: DateTime(2026, 9, 13),
            amount: 999,
          ),
          statementFor(
            id: 'cny',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 3000,
            paid: 2000,
          ),
          statementFor(
            id: 'usd',
            accountId: usdAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 15),
            amount: 100,
            paid: 50,
            currencyCode: 'USD',
          ),
        ],
        convert: (amount, code, _) => code == 'USD' ? amount * 7 : amount,
      );

      expect(snapshot.latestBilledAmount, 3700);
      expect(snapshot.latestOutstandingAmount, 1350);
      expect(snapshot.hasFormalStatement, isTrue);
      expect(snapshot.latestStatementSettled, isFalse);
    });

    test('还款提醒优先选择所有未结账单中最早到期的一张', () {
      final snapshot = snapshotFor(
        netSpending: 0,
        now: DateTime(2026, 9, 27),
        statements: <BillingStatement>[
          statementFor(
            id: 'overdue',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 8, 25),
            dueDate: DateTime(2026, 9, 25),
            amount: 1200,
          ),
          statementFor(
            id: 'latest',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 3703.85,
          ),
        ],
      );

      expect(snapshot.dueDate, DateTime(2026, 9, 25));
      expect(snapshot.daysUntilDue, -2);
      expect(snapshot.hasOutstandingStatement, isTrue);
      expect(snapshot.dueOutstandingAmount, 1200);
    });

    test('还款提醒金额只合并最早到期日的未结正式账单', () {
      final snapshot = snapshotFor(
        netSpending: 500,
        statements: <BillingStatement>[
          statementFor(
            id: 'cny',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 8, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 1000,
            paid: 800,
          ),
          statementFor(
            id: 'usd',
            accountId: usdAccount.id,
            statementDate: DateTime(2026, 8, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 100,
            paid: 50,
            currencyCode: 'USD',
          ),
          statementFor(
            id: 'later',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 11, 13),
            amount: 3000,
          ),
        ],
        convert: (amount, code, _) => code == 'USD' ? amount * 7 : amount,
      );
      expect(snapshot.dueDate, DateTime(2026, 10, 13));
      expect(snapshot.dueOutstandingAmount, 550);
      expect(snapshot.hasOutstandingStatement, isTrue);
    });

    test('最近账单已结清时仍保留较早未结账单的还款提醒', () {
      final snapshot = snapshotFor(
        netSpending: 0,
        statements: <BillingStatement>[
          statementFor(
            id: 'older',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 8, 25),
            dueDate: DateTime(2026, 9, 13),
            amount: 100,
          ),
          statementFor(
            id: 'latest-paid',
            accountId: cnyAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 13),
            amount: 1000,
            paid: 1000,
          ),
        ],
      );
      expect(snapshot.latestStatementSettled, isTrue);
      expect(snapshot.hasOutstandingStatement, isTrue);
      expect(snapshot.dueOutstandingAmount, 100);
    });

    test('缺失汇率时不伪造正式账单合计', () {
      final snapshot = snapshotFor(
        netSpending: 0,
        statements: <BillingStatement>[
          statementFor(
            id: 'usd',
            accountId: usdAccount.id,
            statementDate: DateTime(2026, 9, 25),
            dueDate: DateTime(2026, 10, 15),
            amount: 100,
            currencyCode: 'USD',
          ),
        ],
        convert: (amount, code, _) => code == 'USD' ? null : amount,
      );

      expect(snapshot.formalStatementMissingConversion, isTrue);
      expect(snapshot.latestStatementSettled, isFalse);
      expect(snapshot.dueOutstandingAmount, isNull);
      expect(snapshot.hasOutstandingStatement, isFalse);
      expect(snapshot.hasUpcomingStatementDebt, isFalse);
    });
  });
}
