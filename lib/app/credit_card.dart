// 信用类账户（信用卡 / 信用账户）的纯函数：账单日/还款日推进、额度与本期账单。

import 'ledger_math.dart';
import 'models.dart';

/// 给定还款日（每月 1–28）和当前时间，返回下一个还款日期。
/// 今天已过当月还款日则顺延到下月。
DateTime nextDueDate(int dueDay, DateTime now) {
  final today = dateOnly(now);
  final day = dueDay.clamp(1, 28);
  final thisMonth = DateTime(today.year, today.month, day);
  if (thisMonth.isBefore(today)) {
    return DateTime(today.year, today.month + 1, day);
  }
  return thisMonth;
}

/// 距离下一个还款日的天数（今天为 0）。
int daysUntilDue(int dueDay, DateTime now) {
  return calendarDaysBetween(now, nextDueDate(dueDay, now));
}

/// 已用额度（当前欠款）：账户负余额的绝对值，非负；余额为正（存入/超额还款）时为 0。
double usedCredit(double balance) {
  return balance < 0 ? -balance : 0;
}

/// 可用额度 = 额度 − 已用。未设额度返回 null。可能因超额还款而接近或等于额度上限。
double? availableCredit(double? creditLimit, double balance) {
  if (creditLimit == null) {
    return null;
  }
  return creditLimit - usedCredit(balance);
}

/// 给定账单日（每月 1–28）和当前时间，返回下一个（含今天）账单日期。
DateTime nextStatementDate(int statementDay, DateTime now) {
  final today = dateOnly(now);
  final day = statementDay.clamp(1, 28);
  final thisMonth = DateTime(today.year, today.month, day);
  if (thisMonth.isBefore(today)) {
    return DateTime(today.year, today.month + 1, day);
  }
  return thisMonth;
}

/// 当前账单周期：上一个账单日次日 至 下一个（含今天）账单日当天（含首尾）。
/// 该窗口内的消费将在下个账单日出账。
DateWindow currentBillingCycle(int statementDay, DateTime now) {
  final nextStmt = nextStatementDate(statementDay, now);
  final day = statementDay.clamp(1, 28);
  final prevStmt = DateTime(nextStmt.year, nextStmt.month - 1, day);
  return DateWindow(
    start: DateTime(prevStmt.year, prevStmt.month, prevStmt.day + 1),
    end: nextStmt,
  );
}

/// 本期账单金额：本账单周期内、该账户支出的净额合计（退款冲抵后）。
/// 还款是转账、不计入支出，故不影响本值；本值与「当前欠款」是两个互不矛盾的口径。
double billingCycleExpense(
  Iterable<LedgerEntry> entries,
  String accountId,
  DateWindow cycle,
) {
  final start = dateOnly(cycle.start);
  final end = dateOnly(cycle.end);
  return entries
      .where(
        (entry) =>
            entry.type == EntryType.expense &&
            entry.accountId == accountId &&
            !dateOnly(entry.occurredAt).isBefore(start) &&
            !dateOnly(entry.occurredAt).isAfter(end),
      )
      .fold<double>(0, (sum, entry) => sum + entry.netAmount);
}

/// 信用账户页面的三个核心口径：已出账待还、当前未出账和最近一期账单。
class CreditStatementOverview {
  const CreditStatementOverview({
    required this.billedOutstanding,
    required this.unbilledAmount,
    required this.latestStatement,
  });

  final double billedOutstanding;
  final double unbilledAmount;
  final BillingStatement? latestStatement;
}

/// 汇总正式账单口径。
///
/// “已出账待还”直接汇总账单剩余，不再从账户总余额猜；“当前未出账”只统计最近一期
/// 账期结束后的消费与退款，不把还款转账混入消费。没有正式账单时退回当前账单周期估算。
CreditStatementOverview creditStatementOverview({
  required Account account,
  required Iterable<LedgerEntry> entries,
  required Iterable<BillingStatement> statements,
  required DateTime now,
}) {
  final sorted =
      statements.where((item) => item.accountId == account.id).toList()
        ..sort((a, b) => b.statementDate.compareTo(a.statementDate));
  final latest = sorted.firstOrNull;
  final billed = sorted.fold<double>(
    0,
    (sum, statement) => sum + statement.outstandingAmount,
  );
  final cutoff = latest?.periodEnd;
  double unbilled;
  if (cutoff == null) {
    unbilled = account.statementDay == null
        ? 0
        : billingCycleExpense(
            entries,
            account.id,
            currentBillingCycle(account.statementDay!, now),
          );
  } else {
    unbilled = 0;
    for (final entry in entries) {
      // 退款只有在实际到账后才会改变信用账户口径，因此筛选未出账条目时
      // 必须使用与余额计算相同的到账日，而不能只看退款原始发生日。
      final effectDate = accountEffectDate(entry);
      if (entry.accountId != account.id ||
          !effectDate.isAfter(cutoff) ||
          effectDate.isAfter(now)) {
        continue;
      }
      if (entry.type == EntryType.expense) {
        unbilled += entry.accountAmount ?? entry.amount;
      } else if (entry.isSettledRefund) {
        unbilled -= entry.accountAmount ?? entry.amount;
      }
    }
    if (unbilled < 0) unbilled = 0;
  }
  return CreditStatementOverview(
    billedOutstanding: billed,
    unbilledAmount: unbilled,
    latestStatement: latest,
  );
}

/// 根据应还与已还金额归一账单状态。争议账单保持 disputed，不自动覆盖用户判断。
BillingStatementStatus normalizedStatementStatus(BillingStatement statement) {
  if (statement.status == BillingStatementStatus.disputed) {
    return statement.status;
  }
  if (statement.paidAmount >= statement.statementAmount) {
    return BillingStatementStatus.paid;
  }
  if (statement.paidAmount > 0) {
    return BillingStatementStatus.partiallyPaid;
  }
  return BillingStatementStatus.open;
}
