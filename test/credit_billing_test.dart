import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  Account creditAccount(String bookId) => Account(
    id: 'credit_test',
    bookId: bookId,
    name: '测试信用卡',
    type: AccountType.creditCard,
    groupId: null,
    initialBalance: -20000,
    iconCode: 'credit',
    note: '',
    includeInAssets: true,
    hidden: false,
    creditLimit: 30000,
    statementDay: 25,
    dueDay: 13,
  );

  test('出账后退款独立冲抵待还，不改变实际还款且不重复计入未出账', () {
    final account = creditAccount('default');
    final statement = BillingStatement(
      id: 'statement-sep',
      bookId: 'default',
      accountId: account.id,
      statementDate: DateTime(2026, 9, 25),
      periodStart: DateTime(2026, 8, 26),
      periodEnd: DateTime(2026, 9, 25),
      statementAmount: 5497.15,
      minimumPayment: 550,
      dueDate: DateTime(2026, 10, 13),
      paidAmount: 0,
      status: BillingStatementStatus.open,
    );
    final original = LedgerEntry(
      id: 'rail-expense',
      bookId: 'default',
      type: EntryType.expense,
      amount: 278,
      categoryId: 'travel',
      accountId: account.id,
      note: '铁路',
      occurredAt: DateTime(2026, 9, 23),
    );
    final refund = LedgerEntry(
      id: 'rail-refund',
      bookId: 'default',
      type: EntryType.refund,
      amount: 278,
      categoryId: 'travel',
      accountId: account.id,
      note: '铁路退款',
      occurredAt: DateTime(2026, 9, 27),
      refundOf: original.id,
      settledAt: DateTime(2026, 9, 28),
    );
    final entries = <LedgerEntry>[original, refund];
    final allocations = allocateStatementRefunds(
      entries: entries,
      statements: <BillingStatement>[statement],
      now: DateTime(2026, 9, 30),
    );
    expect(allocations, hasLength(1));
    expect(allocations.single.amount, 278);
    final overview = creditStatementOverview(
      account: account,
      entries: entries,
      statements: <BillingStatement>[statement],
      now: DateTime(2026, 9, 30),
    );
    expect(overview.billedOutstanding, closeTo(5219.15, 0.001));
    expect(overview.latestStatement!.paidAmount, 0);
    expect(overview.latestStatement!.refundAmount, 278);
    expect(overview.unbilledAmount, 0);
    expect(
      allocateStatementRefunds(
        entries: <LedgerEntry>[original, refund.copyWith(clearSettledAt: true)],
        statements: <BillingStatement>[statement],
        now: DateTime(2026, 9, 30),
      ),
      isEmpty,
    );
    expect(
      allocateStatementRefunds(
        entries: <LedgerEntry>[
          original,
          refund.copyWith(accountId: 'different-account'),
        ],
        statements: <BillingStatement>[statement],
        now: DateTime(2026, 9, 30),
      ),
      isEmpty,
    );
    expect(
      allocateStatementRefunds(
        entries: <LedgerEntry>[
          original,
          refund.copyWith(settledAt: DateTime(2026, 9, 25, 18)),
        ],
        statements: <BillingStatement>[statement],
        now: DateTime(2026, 9, 30),
      ),
      isEmpty,
    );
  });

  test('旧账单把退款误计为还款后可在应用内修正基线', () async {
    final controller = await makeController();
    final account = creditAccount(controller.activeBook.id);
    controller.addAccount(account);
    controller.addEntry(
      LedgerEntry(
        id: 'legacy-rail-expense',
        bookId: account.bookId,
        type: EntryType.expense,
        amount: 278,
        categoryId: 'travel',
        accountId: account.id,
        note: '铁路',
        occurredAt: DateTime(2026, 9, 23),
      ),
    );
    controller.addEntry(
      LedgerEntry(
        id: 'legacy-rail-refund',
        bookId: account.bookId,
        type: EntryType.refund,
        amount: 278,
        categoryId: 'travel',
        accountId: account.id,
        note: '铁路退款',
        occurredAt: DateTime(2026, 9, 27),
        refundOf: 'legacy-rail-expense',
        settledAt: DateTime(2026, 9, 28),
      ),
    );
    await controller.waitForPendingWrites();
    expect(
      await controller.saveBillingStatement(
        BillingStatement(
          id: 'legacy-statement',
          bookId: account.bookId,
          accountId: account.id,
          statementDate: DateTime(2026, 9, 25),
          periodStart: DateTime(2026, 8, 26),
          periodEnd: DateTime(2026, 9, 25),
          statementAmount: 5497.15,
          minimumPayment: 550,
          dueDate: DateTime(2026, 10, 13),
          paidAmount: 278,
          status: BillingStatementStatus.partiallyPaid,
        ),
      ),
      isTrue,
    );
    expect(
      await controller.correctBillingStatementPaidAmount(
        statementId: 'legacy-statement',
        paidAmount: 0,
      ),
      isTrue,
    );
    final corrected = controller.billingStatements.single;
    expect(corrected.paidAmount, 0);
    expect(corrected.refundAmount, 278);
    expect(corrected.outstandingAmount, closeTo(5219.15, 0.001));
  });

  test('余额锚点截断不完整历史，只累计锚点后变动并可冷启动恢复', () async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final account = creditAccount(controller.activeBook.id);
    controller
      ..addAccount(account)
      ..addEntry(
        LedgerEntry(
          id: 'old_expense',
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: 8000,
          categoryId: 'dining',
          accountId: account.id,
          note: '锚点前的不完整历史',
          occurredAt: DateTime(2026, 8, 1),
        ),
      );
    await controller.waitForPendingWrites();

    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: DateTime(2026, 8, 14, 23, 59, 59),
        balance: 0,
        note: '已结清',
      ),
      isTrue,
    );
    controller.addEntry(
      LedgerEntry(
        id: 'new_expense',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 15.6,
        categoryId: 'dining',
        accountId: account.id,
        note: '锚点后消费',
        occurredAt: DateTime(2026, 8, 15),
      ),
    );
    expect(controller.accountBalance(account), -15.6);
    await controller.waitForPendingWrites();
    controller.dispose();

    final restored = await makeController(store);
    addTearDown(restored.dispose);
    expect(restored.latestBalanceAnchor(account.id)?.balance, 0);
    final restoredAccount = restored.accounts.firstWhere(
      (item) => item.id == account.id,
    );
    expect(restored.accountBalance(restoredAccount), -15.6);
  });

  test('余额锚点按退款到账日计入锚点后的账户变动', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = creditAccount(controller.activeBook.id);
    controller.addAccount(account);
    final expense = LedgerEntry(
      id: 'anchor_refund_expense',
      bookId: account.bookId,
      type: EntryType.expense,
      amount: 100,
      accountAmount: 100,
      baseAmount: 100,
      categoryId: 'dining',
      accountId: account.id,
      note: '锚点前消费',
      occurredAt: DateTime(2026, 8, 1),
    );
    controller.addEntry(expense);
    controller.addEntry(
      LedgerEntry(
        id: 'anchor_refund',
        bookId: account.bookId,
        type: EntryType.refund,
        amount: 20,
        accountAmount: 20,
        baseAmount: 20,
        categoryId: 'dining',
        accountId: account.id,
        note: '退款到账',
        occurredAt: DateTime(2026, 8, 10),
        refundOf: expense.id,
        settledAt: DateTime(2026, 8, 15),
      ),
    );
    await controller.waitForPendingWrites();

    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: DateTime(2026, 8, 14, 23, 59, 59),
        balance: 0,
      ),
      isTrue,
    );
    // 退款发生日早于锚点，但到账日在锚点后，必须把 20 计入余额。
    expect(controller.accountBalance(account), 20);
  });

  test('一笔还款按最早到期顺序跨期分配，支持部分还款', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = creditAccount(controller.activeBook.id);
    controller.addAccount(account);
    await controller.waitForPendingWrites();

    expect(
      await controller.createBillingStatement(
        account: account,
        statementDate: DateTime(2026, 7, 25),
        periodStart: DateTime(2026, 6, 26),
        periodEnd: DateTime(2026, 7, 25, 23, 59, 59),
        statementAmount: 2000,
        minimumPayment: 200,
        dueDate: DateTime(2026, 8, 13),
        paidAmount: 0,
      ),
      isTrue,
    );
    expect(
      await controller.createBillingStatement(
        account: account,
        statementDate: DateTime(2026, 8, 25),
        periodStart: DateTime(2026, 7, 26),
        periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
        statementAmount: 4000,
        minimumPayment: 400,
        dueDate: DateTime(2026, 9, 13),
        paidAmount: 0,
      ),
      isTrue,
    );
    final repayment = LedgerEntry(
      id: 'repayment_5000',
      bookId: controller.activeBook.id,
      type: EntryType.transfer,
      amount: 5000,
      categoryId: 'transfer_out',
      accountId: '',
      toAccountId: account.id,
      note: '信用卡还款',
      occurredAt: DateTime(2026, 9, 13),
    );
    controller.addEntry(repayment);

    expect(
      await controller.allocateRepaymentToStatements(
        repaymentEntryId: repayment.id,
        creditAccountId: account.id,
        repaymentAmount: 5000,
      ),
      5000,
    );
    final statements =
        controller.billingStatementsForAccount(account.id).toList()
          ..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    expect(statements[0].paidAmount, 2000);
    expect(statements[0].status, BillingStatementStatus.paid);
    expect(statements[1].paidAmount, 3000);
    expect(statements[1].outstandingAmount, 1000);
    expect(statements[1].status, BillingStatementStatus.partiallyPaid);
    expect(
      statements
          .expand((item) => controller.allocationsForStatement(item.id))
          .fold<double>(0, (sum, item) => sum + item.amount),
      5000,
    );
  });

  test('重复导入同一期账单不会覆盖已有已还金额与还款分配', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = creditAccount(controller.activeBook.id);
    controller.addAccount(account);
    await controller.waitForPendingWrites();

    final statement = BillingStatement(
      id: 'statement_imported',
      bookId: account.bookId,
      accountId: account.id,
      statementDate: DateTime(2026, 8, 25),
      periodStart: DateTime(2026, 7, 26),
      periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
      statementAmount: 5000,
      minimumPayment: 500,
      dueDate: DateTime(2026, 9, 13),
      paidAmount: 0,
      status: BillingStatementStatus.open,
      sourceId: 'cmb',
      sourceStatementId: 'cmb-20260825',
    );
    expect(await controller.saveBillingStatement(statement), isTrue);

    final repayment = LedgerEntry(
      id: 'repayment_imported',
      bookId: account.bookId,
      type: EntryType.transfer,
      amount: 3000,
      categoryId: 'transfer_out',
      accountId: '',
      toAccountId: account.id,
      note: '信用卡还款',
      occurredAt: DateTime(2026, 9, 13),
    );
    controller.addEntry(repayment);
    expect(
      await controller.allocateRepaymentToStatements(
        repaymentEntryId: repayment.id,
        creditAccountId: account.id,
        repaymentAmount: 3000,
      ),
      3000,
    );

    // 模拟银行再次导出同一期，但文件不携带此前本地已还缓存。
    final reimported = BillingStatement(
      id: 'different_import_id',
      bookId: statement.bookId,
      accountId: statement.accountId,
      statementDate: statement.statementDate,
      periodStart: statement.periodStart,
      periodEnd: statement.periodEnd,
      statementAmount: statement.statementAmount,
      minimumPayment: statement.minimumPayment,
      dueDate: statement.dueDate,
      paidAmount: 0,
      status: BillingStatementStatus.open,
      sourceId: statement.sourceId,
      sourceStatementId: statement.sourceStatementId,
    );
    expect(await controller.saveBillingStatement(reimported), isTrue);
    expect(
      controller.billingStatementsForAccount(account.id).single.paidAmount,
      3000,
    );
    expect(controller.allocationsForStatement(statement.id), hasLength(1));
  });

  test('还款分配不会超过真实转账金额', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = creditAccount(controller.activeBook.id);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.createBillingStatement(
        account: account,
        statementDate: DateTime(2026, 8, 25),
        periodStart: DateTime(2026, 7, 26),
        periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
        statementAmount: 5000,
        minimumPayment: 500,
        dueDate: DateTime(2026, 9, 13),
        paidAmount: 0,
      ),
      isTrue,
    );
    final repayment = LedgerEntry(
      id: 'repayment_cap',
      bookId: account.bookId,
      type: EntryType.transfer,
      amount: 1000,
      categoryId: 'transfer_out',
      accountId: '',
      toAccountId: account.id,
      note: '实际只还一千',
      occurredAt: DateTime(2026, 9, 13),
    );
    controller.addEntry(repayment);

    expect(
      await controller.allocateRepaymentToStatements(
        repaymentEntryId: repayment.id,
        creditAccountId: account.id,
        repaymentAmount: 9999,
      ),
      1000,
    );
    expect(
      controller.billingStatementsForAccount(account.id).single.paidAmount,
      1000,
    );
  });

  test('已存在还款证据时拒绝缩小账单金额的导入修正', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = creditAccount(controller.activeBook.id);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    final statement = BillingStatement(
      id: 'statement_shrink',
      bookId: account.bookId,
      accountId: account.id,
      statementDate: DateTime(2026, 8, 25),
      periodStart: DateTime(2026, 7, 26),
      periodEnd: DateTime(2026, 8, 25, 23, 59, 59),
      statementAmount: 5000,
      minimumPayment: 500,
      dueDate: DateTime(2026, 9, 13),
      paidAmount: 0,
      status: BillingStatementStatus.open,
      sourceId: 'cmb',
      sourceStatementId: 'cmb-shrink',
    );
    expect(await controller.saveBillingStatement(statement), isTrue);
    final repayment = LedgerEntry(
      id: 'repayment_shrink',
      bookId: account.bookId,
      type: EntryType.transfer,
      amount: 3000,
      categoryId: 'transfer_out',
      accountId: '',
      toAccountId: account.id,
      note: '部分还款',
      occurredAt: DateTime(2026, 9, 13),
    );
    controller.addEntry(repayment);
    expect(
      await controller.allocateRepaymentToStatements(
        repaymentEntryId: repayment.id,
        creditAccountId: account.id,
        repaymentAmount: 3000,
      ),
      3000,
    );

    final invalidCorrection = BillingStatement(
      id: statement.id,
      bookId: statement.bookId,
      accountId: statement.accountId,
      statementDate: statement.statementDate,
      periodStart: statement.periodStart,
      periodEnd: statement.periodEnd,
      statementAmount: 2000,
      minimumPayment: 200,
      dueDate: statement.dueDate,
      paidAmount: 0,
      status: BillingStatementStatus.open,
      sourceId: statement.sourceId,
      sourceStatementId: statement.sourceStatementId,
    );
    expect(await controller.saveBillingStatement(invalidCorrection), isFalse);
    expect(
      controller.billingStatementsForAccount(account.id).single.statementAmount,
      5000,
    );
    expect(
      controller.billingStatementsForAccount(account.id).single.paidAmount,
      3000,
    );
  });
}
