import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/attention_center.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/models.dart';

void main() {
  final now = DateTime(2026, 9, 27, 12);

  /// 构造测试账户；[credit] 为 true 时表示可接收还款的信用账户。
  Account account(String id, {bool credit = false, String currency = 'CNY'}) {
    return Account(
      id: id,
      bookId: 'book',
      name: id,
      type: credit ? AccountType.creditCard : AccountType.debitCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'wallet',
      note: '',
      includeInAssets: true,
      hidden: false,
      currencyCode: currency,
    );
  }

  /// 构造交易快照，测试可按需要覆盖类型、对账状态和退款关系。
  LedgerEntry entry(
    String id, {
    EntryType type = EntryType.expense,
    ReconciliationStatus status = ReconciliationStatus.unverified,
    String accountId = 'cash',
    String? toAccountId,
    String? refundOf,
    double amount = 100,
    DateTime? occurredAt,
  }) {
    return LedgerEntry(
      id: id,
      bookId: 'book',
      type: type,
      amount: amount,
      categoryId: 'dining',
      accountId: accountId,
      toAccountId: toAccountId,
      note: id,
      occurredAt: occurredAt ?? now,
      refundOf: refundOf,
      reconciliationStatus: status,
    );
  }

  /// 构造自动采集事件，用于验证单事件的分流优先级。
  CaptureEvent capture(
    String id, {
    CaptureStatus status = CaptureStatus.pendingReview,
    CaptureConfidence confidence = CaptureConfidence.low,
    CaptureTransactionKind kind = CaptureTransactionKind.expense,
  }) {
    return CaptureEvent(
      id: id,
      bookId: 'book',
      sourceKind: CaptureSourceKind.notification,
      sourceId: 'bank',
      sourceEventId: id,
      rawText: 'sample',
      receivedAt: now,
      fingerprint: id,
      parsedAmount: 42,
      status: status,
      confidence: confidence,
      kind: kind,
      processedAt: now,
    );
  }

  /// 构造账户估值结果；参数只保留本组测试关心的缺率信息。
  ConvertedAccountBalances valuation({
    Set<String> missingCodes = const <String>{},
    Set<String> affectedIds = const <String>{},
  }) {
    return ConvertedAccountBalances(
      amountsByAccountId: const <String, double>{},
      missingCurrencyCodes: missingCodes,
      affectedAccountIds: affectedIds,
      rateDatesByAccountId: const <String, DateTime>{},
      staleAccountIds: const <String>{},
    );
  }

  test('自动采集事件只进入一个最高优先级异常类型', () {
    final snapshot = buildAttentionCenterSnapshot(
      accounts: const <Account>[],
      entries: const <LedgerEntry>[],
      captureEvents: <CaptureEvent>[
        capture('failed', status: CaptureStatus.failed),
        capture('duplicate', status: CaptureStatus.duplicateSuspected),
        capture('refund', kind: CaptureTransactionKind.refund),
        capture('low'),
        capture(
          'review',
          confidence: CaptureConfidence.medium,
          status: CaptureStatus.pendingReview,
        ),
      ],
      billingStatements: const <BillingStatement>[],
      repaymentAllocations: const <StatementRepaymentAllocation>[],
      recurringMissingRates: const <String, Set<String>>{},
      accountValuation: valuation(),
      now: now,
    );

    expect(snapshot.total, 5);
    expect(snapshot.countOf(AttentionIssueType.captureFailure), 1);
    expect(snapshot.countOf(AttentionIssueType.duplicateTransaction), 1);
    expect(snapshot.countOf(AttentionIssueType.unmatchedRefund), 1);
    expect(snapshot.countOf(AttentionIssueType.lowConfidenceCapture), 1);
    expect(snapshot.countOf(AttentionIssueType.captureReview), 1);
  });

  test('对账差异和丢失原支出的退款会进入异常中心', () {
    final snapshot = buildAttentionCenterSnapshot(
      accounts: <Account>[account('cash')],
      entries: <LedgerEntry>[
        entry('conflict', status: ReconciliationStatus.amountConflict),
        entry('bank', status: ReconciliationStatus.bankOnly),
        entry('local', status: ReconciliationStatus.localOnly),
        entry(
          'orphan-refund',
          type: EntryType.refund,
          refundOf: 'missing-expense',
        ),
      ],
      captureEvents: const <CaptureEvent>[],
      billingStatements: const <BillingStatement>[],
      repaymentAllocations: const <StatementRepaymentAllocation>[],
      recurringMissingRates: const <String, Set<String>>{},
      accountValuation: valuation(),
      now: now,
    );

    expect(snapshot.countOf(AttentionIssueType.amountConflict), 1);
    expect(snapshot.countOf(AttentionIssueType.bankOnlyTransaction), 1);
    expect(snapshot.countOf(AttentionIssueType.localOnlyTransaction), 1);
    expect(snapshot.countOf(AttentionIssueType.unmatchedRefund), 1);
  });

  test('部分分配的还款只提醒剩余金额', () {
    final repayment = entry(
      'repayment',
      type: EntryType.transfer,
      accountId: 'cash',
      toAccountId: 'credit',
      amount: 1000,
    );
    final statement = BillingStatement(
      id: 'statement',
      bookId: 'book',
      accountId: 'credit',
      statementDate: DateTime(2026, 9, 26),
      periodStart: DateTime(2026, 8, 1),
      periodEnd: DateTime(2026, 8, 31),
      statementAmount: 1000,
      minimumPayment: 100,
      dueDate: DateTime(2026, 10, 10),
      paidAmount: 400,
      status: BillingStatementStatus.partiallyPaid,
    );
    final snapshot = buildAttentionCenterSnapshot(
      accounts: <Account>[account('cash'), account('credit', credit: true)],
      entries: <LedgerEntry>[repayment],
      captureEvents: const <CaptureEvent>[],
      billingStatements: <BillingStatement>[statement],
      repaymentAllocations: <StatementRepaymentAllocation>[
        StatementRepaymentAllocation(
          id: 'allocation',
          bookId: 'book',
          statementId: statement.id,
          repaymentEntryId: repayment.id,
          amount: 400,
          createdAt: now,
        ),
      ],
      recurringMissingRates: const <String, Set<String>>{},
      accountValuation: valuation(),
      now: now,
    );

    final issue = snapshot
        .issuesOf(AttentionIssueType.unallocatedRepayment)
        .single;
    expect(issue.amount, 600);
    expect(issue.accountId, 'credit');
  });

  test('新建一张正式账单不会把此前 310 笔历史还款变成异常', () {
    final statement = BillingStatement(
      id: 'statement-new',
      bookId: 'book',
      accountId: 'credit',
      statementDate: DateTime(2026, 9, 25),
      periodStart: DateTime(2026, 8, 26),
      periodEnd: DateTime(2026, 9, 25),
      statementAmount: 100,
      minimumPayment: 10,
      dueDate: DateTime(2026, 10, 15),
      paidAmount: 0,
      status: BillingStatementStatus.open,
    );
    final historical = <LedgerEntry>[
      for (var i = 0; i < 310; i++)
        entry(
          'historical-$i',
          type: EntryType.transfer,
          toAccountId: 'credit',
          occurredAt: DateTime(2026, 9, 13),
        ),
    ];
    final current = entry(
      'current',
      type: EntryType.transfer,
      toAccountId: 'credit',
      amount: 150,
      occurredAt: DateTime(2026, 9, 26),
    );
    final sameDay = entry(
      'statement-day',
      type: EntryType.transfer,
      toAccountId: 'credit',
      occurredAt: DateTime(2026, 9, 25, 8),
    );
    final snapshot = buildAttentionCenterSnapshot(
      accounts: <Account>[account('cash'), account('credit', credit: true)],
      entries: <LedgerEntry>[...historical, sameDay, current],
      captureEvents: const <CaptureEvent>[],
      billingStatements: <BillingStatement>[statement],
      repaymentAllocations: const <StatementRepaymentAllocation>[],
      recurringMissingRates: const <String, Set<String>>{},
      accountValuation: valuation(),
      now: now,
    );
    final issues = snapshot.issuesOf(AttentionIssueType.unallocatedRepayment);
    expect(issues, hasLength(1));
    expect(issues.single.referenceId, 'current');
    expect(issues.single.amount, 100);
  });

  test('已结清账单和未来账单不会触发还款未关联告警', () {
    final repayment = entry(
      'advance',
      type: EntryType.transfer,
      toAccountId: 'credit',
      occurredAt: DateTime(2026, 9, 26),
    );
    final closed = BillingStatement(
      id: 'closed',
      bookId: 'book',
      accountId: 'credit',
      statementDate: DateTime(2026, 9, 25),
      periodStart: DateTime(2026, 8, 26),
      periodEnd: DateTime(2026, 9, 25),
      statementAmount: 100,
      minimumPayment: 10,
      dueDate: DateTime(2026, 10, 15),
      paidAmount: 100,
      status: BillingStatementStatus.paid,
    );
    final future = BillingStatement(
      id: 'future',
      bookId: 'book',
      accountId: 'credit',
      statementDate: DateTime(2026, 10, 25),
      periodStart: DateTime(2026, 9, 26),
      periodEnd: DateTime(2026, 10, 25),
      statementAmount: 100,
      minimumPayment: 10,
      dueDate: DateTime(2026, 11, 15),
      paidAmount: 0,
      status: BillingStatementStatus.open,
    );
    final snapshot = buildAttentionCenterSnapshot(
      accounts: <Account>[account('cash'), account('credit', credit: true)],
      entries: <LedgerEntry>[repayment],
      captureEvents: const <CaptureEvent>[],
      billingStatements: <BillingStatement>[closed, future],
      repaymentAllocations: const <StatementRepaymentAllocation>[],
      recurringMissingRates: const <String, Set<String>>{},
      accountValuation: valuation(),
      now: now,
    );
    expect(snapshot.issuesOf(AttentionIssueType.unallocatedRepayment), isEmpty);
  });

  test('账户和周期规则缺失同一币种汇率时合并成一项', () {
    final snapshot = buildAttentionCenterSnapshot(
      accounts: <Account>[
        account('usd-a', currency: 'USD'),
        account('usd-b', currency: 'USD'),
      ],
      entries: const <LedgerEntry>[],
      captureEvents: const <CaptureEvent>[],
      billingStatements: const <BillingStatement>[],
      repaymentAllocations: const <StatementRepaymentAllocation>[],
      recurringMissingRates: const <String, Set<String>>{
        'rent': <String>{'USD'},
      },
      accountValuation: valuation(
        missingCodes: const <String>{'USD'},
        affectedIds: const <String>{'usd-a', 'usd-b'},
      ),
      now: now,
    );

    final issue = snapshot
        .issuesOf(AttentionIssueType.missingExchangeRate)
        .single;
    expect(issue.referenceId, 'USD');
    expect(issue.relatedCount, 3);
  });
}
