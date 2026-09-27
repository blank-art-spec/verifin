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
}
