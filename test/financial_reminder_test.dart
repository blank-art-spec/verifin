import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/ledger_math.dart';
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
    DateTime? now,
    Iterable<BillingStatement> statements = const <BillingStatement>[],
    double? Function(double, String, DateTime)? convert,
  }) {
    final reference = now ?? DateTime(2026, 9, 27);
    final statementList = statements.toList(growable: false);
    final converter =
        convert ?? (double amount, String _, DateTime _) => amount;
    var billedOutstanding = 0.0;
    var missingOverviewConversion = false;
    for (final statement in statementList) {
      final converted = converter(
        statement.outstandingAmount,
        statement.currencyCode,
        statement.statementDate,
      );
      if (converted == null) {
        missingOverviewConversion = true;
      } else {
        billedOutstanding += converted;
      }
    }
    return buildCreditReminderSnapshot(
      creditAccount: creditAccount,
      overview: CreditCycleOverview(
        cycle: DateWindow(
          start: DateTime(2026, 9, 26),
          end: DateTime(2026, 10, 25),
        ),
        nextStatementDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 11, 13),
        netSpending: netSpending,
        earlyRepayment: 0,
        currentCycleDebt: netSpending,
        billedOutstanding: billedOutstanding,
        totalDebt: netSpending,
        missingConversion: missingOverviewConversion,
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
      status: paid >= amount
          ? BillingStatementStatus.paid
          : BillingStatementStatus.open,
      currencyCode: currencyCode,
    );
  }

  group('CreditReminderSnapshot', () {
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
    });
  });
}
