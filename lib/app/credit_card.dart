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

/// 把一期信用账单的出账日编码为可持久化的账期标识 `yyyy-MM-dd`。
///
/// 标识只表达银行确认的账期归属，不包含账户 id；调用方仍必须先按账户筛选交易。
/// 采用出账日而非流水发生日，是因为账单日当天究竟归入本期还是下一期取决于银行
/// 切账时点，不能从自然日可靠推断。
String billingCycleIdFor(DateTime statementDate) {
  final date = dateOnly(statementDate);
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-'
      '$month-$day';
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

/// 按信用主体的动态还款规则计算某一期账单的到期日。
///
/// 固定日规则统一解释为“账单日的次月 N 日”；相对日规则使用日历日加法，避免
/// 夏令时地区用 `Duration(days: n)` 产生 23/25 小时偏差。
DateTime creditDueDate(CreditAccount creditAccount, DateTime statementDate) {
  final statement = dateOnly(statementDate);
  switch (creditAccount.dueRuleType) {
    case CreditDueRuleType.fixedDay:
      final day = (creditAccount.dueDay ?? statement.day).clamp(1, 28);
      return DateTime(statement.year, statement.month + 1, day);
    case CreditDueRuleType.daysAfterStatement:
      final days = (creditAccount.daysAfterStatement ?? 1).clamp(1, 3650);
      return addCalendarDays(statement, days);
  }
}

/// 首页信用主体卡片使用的完整账期快照。
class CreditCycleOverview {
  const CreditCycleOverview({
    required this.cycle,
    required this.nextStatementDate,
    required this.dueDate,
    required this.netSpending,
    required this.earlyRepayment,
    required this.currentCycleDebt,
    required this.billedOutstanding,
    required this.totalDebt,
    required this.missingConversion,
  });

  final DateWindow cycle;
  final DateTime nextStatementDate;
  final DateTime dueDate;

  /// 本账期支出减去对应已到账退款；还款不会改变该消费口径。
  final double netSpending;

  /// 本账期转入信用子账户、且未分配给历史正式账单的还款金额。
  final double earlyRepayment;

  /// 本账期当前欠款 = 净消费 − 明确属于本账期的提前还款，最低为 0。
  final double currentCycleDebt;

  /// 所有子账户正式账单尚未结清的金额。
  final double billedOutstanding;

  /// 所有子账户当前负余额折算后的总欠款。
  final double totalDebt;

  /// 任一外币金额缺少换算率时为 true；UI 应提示缺汇率而不是伪造合计。
  final bool missingConversion;
}

/// 聚合一个信用主体下的多币种子账户账期数据。
///
/// [convertToCreditCurrency] 把任意币种金额换成信用主体币种；同币种也应返回原值。
/// 支出净额使用已经冻结的账本本位币 [LedgerEntry.netBaseAmount]，因此不会因后来修改
/// 汇率而改写历史消费。正式账单、余额和还款则按各自币种在对应日期换算。
CreditCycleOverview buildCreditCycleOverview({
  required CreditAccount creditAccount,
  required Iterable<Account> accounts,
  required Iterable<LedgerEntry> entries,
  required Iterable<BillingStatement> statements,
  required Iterable<StatementRepaymentAllocation> allocations,
  required String baseCurrencyCode,
  required DateTime now,
  required double Function(Account account) balanceOf,
  required double? Function(
    double amount,
    String sourceCurrencyCode,
    DateTime date,
  )
  convertToCreditCurrency,
}) {
  final statementDay = creditAccount.statementDay ?? 1;
  final childAccounts = accounts
      .where((account) => account.creditAccountId == creditAccount.id)
      .toList(growable: false);
  final childById = <String, Account>{
    for (final account in childAccounts) account.id: account,
  };
  final childIds = childById.keys.toSet();
  final latestStatement = _latestStatementForAccounts(
    statements: statements,
    accountIds: childIds,
    now: now,
  );
  final nextStatement = _nextUnbilledStatementDate(
    statementDay: statementDay,
    now: now,
    latestStatement: latestStatement,
  );
  final cycle = _currentBillingCycleFromStatement(
    statementDay: statementDay,
    nextStatement: nextStatement,
    latestStatement: latestStatement,
  );
  final currentCycleId = billingCycleIdFor(nextStatement);
  final allocationByRepayment = <String, double>{};
  for (final allocation in allocations) {
    allocationByRepayment.update(
      allocation.repaymentEntryId,
      (value) => value + allocation.amount,
      ifAbsent: () => allocation.amount,
    );
  }

  var missing = false;
  double convert(double amount, String code, DateTime date) {
    // 零金额不需要汇率；空闲的外币子账户不能让整个主体误报“缺少汇率”。
    if (amount == 0) return 0;
    final converted = convertToCreditCurrency(amount, code, date);
    if (converted == null) {
      missing = true;
      return 0;
    }
    return converted;
  }

  var netSpending = 0.0;
  var earlyRepayment = 0.0;
  final cycleStart = dateOnly(cycle.start);
  final cycleEnd = dateOnly(cycle.end);
  for (final entry in entries) {
    final occurred = dateOnly(entry.occurredAt);
    final inCycle = entry.billingCycleId == null
        ? !occurred.isBefore(cycleStart) &&
              !occurred.isAfter(cycleEnd) &&
              !occurred.isAfter(dateOnly(now))
        : entry.billingCycleId == currentCycleId &&
              !occurred.isAfter(dateOnly(now));
    if (entry.type == EntryType.expense &&
        childIds.contains(entry.accountId) &&
        inCycle) {
      netSpending += convert(
        entry.netBaseAmount,
        baseCurrencyCode,
        entry.occurredAt,
      );
      continue;
    }
    if (entry.type != EntryType.transfer ||
        !childIds.contains(entry.toAccountId) ||
        // 同一信用主体的币种子账户之间调拨只是在负债币种间移动，不是还款。
        childIds.contains(entry.accountId) ||
        !inCycle) {
      continue;
    }
    final child = childById[entry.toAccountId];
    if (child == null) continue;
    final repayment = entry.toAccountAmount ?? entry.amount;
    final allocated = allocationByRepayment[entry.id] ?? 0;
    final unallocated = (repayment - allocated)
        .clamp(0.0, repayment)
        .toDouble();
    earlyRepayment += convert(
      unallocated,
      child.currencyCode,
      entry.occurredAt,
    );
  }

  var billedOutstanding = 0.0;
  BillingStatement? dueStatement;
  for (final statement in statements) {
    if (!childIds.contains(statement.accountId) ||
        statement.outstandingAmount <= 0) {
      continue;
    }
    billedOutstanding += convert(
      statement.outstandingAmount,
      statement.currencyCode,
      statement.statementDate,
    );
    if (dueStatement == null ||
        statement.dueDate.isBefore(dueStatement.dueDate)) {
      dueStatement = statement;
    }
  }

  var totalDebt = 0.0;
  for (final account in childAccounts) {
    totalDebt += convert(
      usedCredit(balanceOf(account)),
      account.currencyCode,
      now,
    );
  }
  final currentDebt = (netSpending - earlyRepayment)
      .clamp(0.0, double.infinity)
      .toDouble();
  return CreditCycleOverview(
    cycle: cycle,
    nextStatementDate: nextStatement,
    dueDate:
        dueStatement?.dueDate ?? creditDueDate(creditAccount, nextStatement),
    netSpending: netSpending,
    earlyRepayment: earlyRepayment,
    currentCycleDebt: currentDebt,
    billedOutstanding: billedOutstanding,
    totalDebt: totalDebt,
    missingConversion: missing,
  );
}

/// 找出指定信用子账户中，截至 [now] 最近的一张正式账单。
///
/// 多币种子账户可能各有一张同日账单，因此先按出账日、再按账期结束时间排序；这里只
/// 用它确定当前未出账周期边界，应还金额仍在主聚合循环中逐张换算，不能只读这一张。
BillingStatement? _latestStatementForAccounts({
  required Iterable<BillingStatement> statements,
  required Set<String> accountIds,
  required DateTime now,
}) {
  final today = dateOnly(now);
  final candidates =
      statements
          .where(
            (statement) =>
                accountIds.contains(statement.accountId) &&
                !dateOnly(statement.statementDate).isAfter(today),
          )
          .toList()
        ..sort((a, b) {
          final byStatementDate = b.statementDate.compareTo(a.statementDate);
          return byStatementDate != 0
              ? byStatementDate
              : b.periodEnd.compareTo(a.periodEnd);
        });
  return candidates.firstOrNull;
}

/// 计算尚未出账的目标出账日。
///
/// [nextStatementDate] 在账单日当天会返回“今天”。如果今天的正式账单已经存在，说明
/// 银行已经完成本期切账，当前未出账交易应归入下个月；否则仍保留今天，兼容尚未收到
/// 银行账单的旧数据。
DateTime _nextUnbilledStatementDate({
  required int statementDay,
  required DateTime now,
  required BillingStatement? latestStatement,
}) {
  final candidate = nextStatementDate(statementDay, now);
  if (latestStatement == null ||
      !dateOnly(
        latestStatement.statementDate,
      ).isAtSameMomentAs(dateOnly(candidate))) {
    return candidate;
  }
  return DateTime(
    candidate.year,
    candidate.month + 1,
    statementDay.clamp(1, 28),
  );
}

/// 构造首页使用的当前未出账窗口，正式账单的真实截止日优先于日历日猜测。
///
/// 只有最近账单恰好是目标账期的上一期时才采用它，避免用户漏录数月账单后把多个月
/// 的流水误并入本期。没有可用快照时保持旧版“上个账单日次日”回退规则。
DateWindow _currentBillingCycleFromStatement({
  required int statementDay,
  required DateTime nextStatement,
  required BillingStatement? latestStatement,
}) {
  final day = statementDay.clamp(1, 28);
  final expectedPreviousStatement = DateTime(
    nextStatement.year,
    nextStatement.month - 1,
    day,
  );
  final inferredStart = addCalendarDays(expectedPreviousStatement, 1);
  var start = inferredStart;
  if (latestStatement != null &&
      dateOnly(
        latestStatement.statementDate,
      ).isAtSameMomentAs(dateOnly(expectedPreviousStatement))) {
    final confirmedStart = addCalendarDays(latestStatement.periodEnd, 1);
    if (!confirmedStart.isAfter(nextStatement)) {
      start = confirmedStart;
    }
  }
  return DateWindow(start: start, end: nextStatement);
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
  final cycleId = billingCycleIdFor(cycle.end);
  return entries
      .where(
        (entry) =>
            entry.type == EntryType.expense &&
            entry.accountId == accountId &&
            (entry.billingCycleId == null
                ? !dateOnly(entry.occurredAt).isBefore(start) &&
                      !dateOnly(entry.occurredAt).isAfter(end)
                : entry.billingCycleId == cycleId),
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
  final statementDay = account.statementDay;
  final nextStatement = statementDay == null
      ? null
      : _nextUnbilledStatementDate(
          statementDay: statementDay,
          now: now,
          latestStatement: latest,
        );
  final currentCycleId = nextStatement == null
      ? null
      : billingCycleIdFor(nextStatement);
  double unbilled;
  if (cutoff == null) {
    unbilled = statementDay == null
        ? 0
        : billingCycleExpense(
            entries,
            account.id,
            _currentBillingCycleFromStatement(
              statementDay: statementDay,
              nextStatement: nextStatement!,
              latestStatement: null,
            ),
          );
  } else {
    unbilled = 0;
    for (final entry in entries) {
      // 退款只有在实际到账后才会改变信用账户口径，因此筛选未出账条目时
      // 必须使用与余额计算相同的到账日，而不能只看退款原始发生日。
      final effectDate = accountEffectDate(entry);
      if (entry.accountId != account.id || effectDate.isAfter(now)) {
        continue;
      }
      final belongsToCurrentCycle = entry.billingCycleId == null
          ? effectDate.isAfter(cutoff)
          : entry.billingCycleId == currentCycleId;
      if (!belongsToCurrentCycle) continue;
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
