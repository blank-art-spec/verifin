/// 信用账户账务正确性模型：余额核准锚点、正式账单与还款分配。
///
/// 这些模型刻意独立于普通交易：余额核准不是一笔收入/支出，正式账单也不是
/// 重复消费。这样历史流水不完整时可以修正“当前欠多少”，同时保留原始流水供核对。
library;

import 'currency.dart';
import 'ledger_book.dart';

/// 正式账单状态。除 [disputed] 外，Controller 会在还款分配变化时按应还/已还金额
/// 自动归一为 open、partiallyPaid 或 paid；overdue 由页面结合到期日展示。
enum BillingStatementStatus {
  open,
  partiallyPaid,
  paid,
  overdue,
  disputed;

  static BillingStatementStatus fromStorage(String? value) =>
      BillingStatementStatus.values.firstWhere(
        (status) => status.name == value,
        orElse: () => BillingStatementStatus.open,
      );
}

/// 某个时点经过用户或正式账单核准的账户余额。
///
/// 余额计算只使用最新锚点的 [balance]，再叠加 [effectiveAt] 之后发生的账户变动；
/// 因而锚点之前漏掉的还款不会继续污染当前余额。时间精确到毫秒，允许同一天内
/// 区分“核准前”和“核准后”的交易。
class BalanceAnchor {
  const BalanceAnchor({
    required this.id,
    required this.bookId,
    required this.accountId,
    required this.effectiveAt,
    required this.balance,
    required this.createdAt,
    this.note = '',
  });

  final String id;
  final String bookId;
  final String accountId;
  final DateTime effectiveAt;
  final double balance;
  final DateTime createdAt;
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'accountId': accountId,
    'effectiveAt': effectiveAt.toIso8601String(),
    'balance': balance,
    'createdAt': createdAt.toIso8601String(),
    if (note.isNotEmpty) 'note': note,
  };

  static BalanceAnchor fromJson(Map<String, Object?> json) {
    final now = DateTime.now();
    return BalanceAnchor(
      id: json['id'] as String,
      bookId: json['bookId'] as String? ?? defaultLedgerBookId,
      accountId: json['accountId'] as String? ?? '',
      effectiveAt:
          DateTime.tryParse(json['effectiveAt'] as String? ?? '') ?? now,
      balance: (json['balance'] as num? ?? 0).toDouble(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? now,
      note: json['note'] as String? ?? '',
    );
  }
}

/// 银行或信用平台出具的一期正式账单。
///
/// [paidAmount] 是当前已核准的还款缓存；新增还款分配后由 Controller 重算。
/// 从外部正式账单导入时也允许直接带入银行声明的已还金额，以表达导入前已经结清、
/// 但本地缺少历史还款明细的场景。
class BillingStatement {
  const BillingStatement({
    required this.id,
    required this.bookId,
    required this.accountId,
    required this.statementDate,
    required this.periodStart,
    required this.periodEnd,
    required this.statementAmount,
    required this.minimumPayment,
    required this.dueDate,
    required this.paidAmount,
    required this.status,
    this.currencyCode = defaultCurrencyCode,
    this.sourceId = '',
    this.sourceStatementId = '',
    this.note = '',
  });

  final String id;
  final String bookId;
  final String accountId;
  final DateTime statementDate;
  final DateTime periodStart;
  final DateTime periodEnd;
  final double statementAmount;
  final double minimumPayment;
  final DateTime dueDate;
  final double paidAmount;
  final BillingStatementStatus status;
  final String currencyCode;

  /// 来源机构稳定标识（如 `cmb`、`alipay`）；手工创建时为空。
  final String sourceId;

  /// 来源账单自身的稳定 id；用于同一期正式账单重复导入时幂等更新。
  final String sourceStatementId;
  final String note;

  double get outstandingAmount =>
      (statementAmount - paidAmount).clamp(0.0, statementAmount).toDouble();

  BillingStatement copyWith({
    double? paidAmount,
    BillingStatementStatus? status,
  }) => BillingStatement(
    id: id,
    bookId: bookId,
    accountId: accountId,
    statementDate: statementDate,
    periodStart: periodStart,
    periodEnd: periodEnd,
    statementAmount: statementAmount,
    minimumPayment: minimumPayment,
    dueDate: dueDate,
    paidAmount: paidAmount ?? this.paidAmount,
    status: status ?? this.status,
    currencyCode: currencyCode,
    sourceId: sourceId,
    sourceStatementId: sourceStatementId,
    note: note,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'accountId': accountId,
    'statementDate': statementDate.toIso8601String(),
    'periodStart': periodStart.toIso8601String(),
    'periodEnd': periodEnd.toIso8601String(),
    'statementAmount': statementAmount,
    'minimumPayment': minimumPayment,
    'dueDate': dueDate.toIso8601String(),
    'paidAmount': paidAmount,
    'status': status.name,
    'currencyCode': currencyCode,
    if (sourceId.isNotEmpty) 'sourceId': sourceId,
    if (sourceStatementId.isNotEmpty) 'sourceStatementId': sourceStatementId,
    if (note.isNotEmpty) 'note': note,
  };

  static BillingStatement fromJson(Map<String, Object?> json) {
    final now = DateTime.now();
    DateTime date(String key) =>
        DateTime.tryParse(json[key] as String? ?? '') ?? now;
    return BillingStatement(
      id: json['id'] as String,
      bookId: json['bookId'] as String? ?? defaultLedgerBookId,
      accountId: json['accountId'] as String? ?? '',
      statementDate: date('statementDate'),
      periodStart: date('periodStart'),
      periodEnd: date('periodEnd'),
      statementAmount: (json['statementAmount'] as num? ?? 0).toDouble(),
      minimumPayment: (json['minimumPayment'] as num? ?? 0).toDouble(),
      dueDate: date('dueDate'),
      paidAmount: (json['paidAmount'] as num? ?? 0).toDouble(),
      status: BillingStatementStatus.fromStorage(json['status'] as String?),
      currencyCode: (json['currencyCode'] as String? ?? defaultCurrencyCode)
          .toUpperCase(),
      sourceId: json['sourceId'] as String? ?? '',
      sourceStatementId: json['sourceStatementId'] as String? ?? '',
      note: json['note'] as String? ?? '',
    );
  }
}

/// 一笔还款中分配给某一期正式账单的金额。
///
/// 同一还款交易可有多条分配（跨多期）；同一期也可由多笔还款逐步结清。未分配余额
/// 表示提前还款或覆盖未出账部分，不强行伪造账单关系。
class StatementRepaymentAllocation {
  const StatementRepaymentAllocation({
    required this.id,
    required this.bookId,
    required this.statementId,
    required this.repaymentEntryId,
    required this.amount,
    required this.createdAt,
  });

  final String id;
  final String bookId;
  final String statementId;
  final String repaymentEntryId;
  final double amount;
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'statementId': statementId,
    'repaymentEntryId': repaymentEntryId,
    'amount': amount,
    'createdAt': createdAt.toIso8601String(),
  };

  static StatementRepaymentAllocation fromJson(Map<String, Object?> json) {
    return StatementRepaymentAllocation(
      id: json['id'] as String,
      bookId: json['bookId'] as String? ?? defaultLedgerBookId,
      statementId: json['statementId'] as String? ?? '',
      repaymentEntryId: json['repaymentEntryId'] as String? ?? '',
      amount: (json['amount'] as num? ?? 0).toDouble(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
