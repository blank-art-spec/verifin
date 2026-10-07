// 信用类账户（信用卡 / 信用账户）的纯函数：账单日/还款日推进、额度与本期账单。

import 'ledger_math.dart';
import 'currency_math.dart';
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
/// 显式归属优先于默认规则；未指定时，出账日当天的消费计入下一期。
String billingCycleIdFor(DateTime statementDate) {
  final date = dateOnly(statementDate);
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year.toString().padLeft(4, '0')}-'
      '$month-$day';
}

/// 消费日期对应的目标出账日；出账日当天消费归入下月出账的账期。
/// 使用日历日推进，避免夏令时使日期边界偏移。
DateTime billingStatementDateForExpense(int statementDay, DateTime occurredAt) {
  return nextStatementDate(
    statementDay,
    addCalendarDays(dateOnly(occurredAt), 1),
  );
}

/// 当前账单周期：上一个账单日 至 下一个账单日前一天（含首尾）。
/// 如每月 5 日出账，5 日至次月 4 日的消费将在次月 5 日出账。
DateWindow currentBillingCycle(int statementDay, DateTime now) {
  final nextStmt = billingStatementDateForExpense(statementDay, now);
  final day = statementDay.clamp(1, 28);
  final prevStmt = DateTime(nextStmt.year, nextStmt.month - 1, day);
  return DateWindow(start: prevStmt, end: addCalendarDays(nextStmt, -1));
}

/// 当前账期闭区间对应的出账日标识；区间结束日是出账日的前一天。
String billingCycleIdForWindow(DateWindow cycle) {
  return billingCycleIdFor(addCalendarDays(cycle.end, 1));
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

  /// 正式账单剩余，加上已到出账日但尚无正式账单的流水待还。
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
  final entryList = entries
      .where((item) => item.bookId == creditAccount.bookId)
      .toList();
  final statementList = statements
      .where(
        (item) =>
            item.bookId == creditAccount.bookId &&
            !dateOnly(item.statementDate).isAfter(dateOnly(now)),
      )
      .toList();
  final childAccounts = accounts
      .where(
        (account) =>
            account.bookId == creditAccount.bookId &&
            account.creditAccountId == creditAccount.id,
      )
      .toList(growable: false);
  final childById = <String, Account>{
    for (final account in childAccounts) account.id: account,
  };
  final childIds = childById.keys.toSet();
  final scheduled = <String, _ScheduledCreditDebt>{
    if (creditAccount.statementDay != null)
      for (final account in childAccounts)
        account.id: _scheduledCreditDebt(
          account: account,
          statementDay: statementDay,
          entries: entryList,
          statements: statementList,
          allocations: allocations,
          internalAccountIds: childIds,
          now: now,
        ),
  };
  final latestStatement = _latestStatementForAccounts(
    statements: statementList,
    accountIds: childIds,
    now: now,
  );
  final nextStatement = billingStatementDateForExpense(statementDay, now);
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
  for (final debt in scheduled.values) {
    for (final repayment in debt.repayments.entries) {
      allocationByRepayment.update(
        repayment.key,
        (value) => value + repayment.value,
        ifAbsent: () => repayment.value,
      );
    }
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
  for (final entry in entryList) {
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
  DateTime? scheduledDueDate;
  for (final account in childAccounts) {
    for (final bill
        in scheduled[account.id]?.amounts.entries ??
            <MapEntry<DateTime, double>>[]) {
      if (bill.value <= 0) continue;
      billedOutstanding += convert(bill.value, account.currencyCode, bill.key);
      final due = creditDueDate(creditAccount, bill.key);
      if (scheduledDueDate == null || due.isBefore(scheduledDueDate)) {
        scheduledDueDate = due;
      }
    }
  }
  for (final statement in statementList) {
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
  var dueDate = dueStatement?.dueDate ?? scheduledDueDate;
  if (scheduledDueDate != null &&
      (dueDate == null || scheduledDueDate.isBefore(dueDate))) {
    dueDate = scheduledDueDate;
  }
  return CreditCycleOverview(
    cycle: cycle,
    nextStatementDate: nextStatement,
    dueDate: dueDate ?? creditDueDate(creditAccount, nextStatement),
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

class _ScheduledCreditDebt {
  const _ScheduledCreditDebt(this.amounts, this.repayments, this.refundIds);

  final Map<DateTime, double> amounts;
  final Map<String, double> repayments;
  final Set<String> refundIds;
}

/// 对没有正式账单覆盖的消费按配置账单日结转。只投影流水，不落库，
/// 不从账户总余额反推，也不把本位币或退到其他账户的钱当作该账户还款。
_ScheduledCreditDebt _scheduledCreditDebt({
  required Account account,
  required int statementDay,
  required Iterable<LedgerEntry> entries,
  required Iterable<BillingStatement> statements,
  required Iterable<StatementRepaymentAllocation> allocations,
  required Set<String> internalAccountIds,
  required DateTime now,
}) {
  final today = dateOnly(now);
  final entryList = entries
      .where((item) => item.bookId == account.bookId)
      .toList();
  final formal = statements
      .where(
        (item) => item.bookId == account.bookId && item.accountId == account.id,
      )
      .toList();
  final amounts = <DateTime, double>{};
  final refundIds = <String>{};
  final cycleByExpense = <String, DateTime>{};
  for (final entry in entryList) {
    if (entry.type != EntryType.expense ||
        entry.accountId != account.id ||
        entry.occurredAt.isAfter(now)) {
      continue;
    }
    final cycle = entry.billingCycleId == null
        ? billingStatementDateForExpense(statementDay, entry.occurredAt)
        : DateTime.tryParse(entry.billingCycleId!);
    if (cycle == null || cycle.isAfter(today)) continue;
    final covered = formal.any((statement) {
      if (billingCycleIdFor(statement.statementDate) ==
          billingCycleIdFor(cycle)) {
        return true;
      }
      if (entry.billingCycleId != null) return false;
      return _expenseIsInStatementPeriod(entry, statement);
    });
    if (covered) continue;
    cycleByExpense[entry.id] = cycle;
    amounts.update(
      cycle,
      (value) => value + (entry.accountAmount ?? entry.amount),
      ifAbsent: () => entry.accountAmount ?? entry.amount,
    );
  }
  for (final refund in entryList) {
    final cycle = cycleByExpense[refund.refundOf];
    if (cycle == null ||
        refund.accountId != account.id ||
        !refund.isSettledRefund ||
        refund.settledAt!.isAfter(now)) {
      continue;
    }
    amounts[cycle] = (amounts[cycle]! - (refund.accountAmount ?? refund.amount))
        .clamp(0.0, double.infinity)
        .toDouble();
    refundIds.add(refund.id);
  }
  final allocated = <String, double>{};
  for (final allocation in allocations) {
    allocated.update(
      allocation.repaymentEntryId,
      (value) => value + allocation.amount,
      ifAbsent: () => allocation.amount,
    );
  }
  final repayments =
      entryList
          .where(
            (entry) =>
                entry.type == EntryType.transfer &&
                entry.toAccountId == account.id &&
                !internalAccountIds.contains(entry.accountId) &&
                !entry.occurredAt.isAfter(now),
          )
          .toList()
        ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  final cycles = amounts.keys.toList()..sort();
  final used = <String, double>{};
  for (final repayment in repayments) {
    final actual = repayment.toAccountAmount ?? repayment.amount;
    var remaining = (actual - (allocated[repayment.id] ?? 0))
        .clamp(0.0, actual)
        .toDouble();
    // 先还已结转的旧期；出账前的还款只抵其当期，不预支未来账期。
    final repaymentCycle = nextStatementDate(
      statementDay,
      repayment.occurredAt,
    );
    for (final cycle in cycles) {
      if (cycle.isAfter(repaymentCycle) || remaining <= 0) continue;
      final paid = remaining.clamp(0.0, amounts[cycle]!).toDouble();
      amounts[cycle] = amounts[cycle]! - paid;
      remaining -= paid;
      used.update(repayment.id, (value) => value + paid, ifAbsent: () => paid);
    }
  }
  for (final cycle in cycles) {
    amounts[cycle] = normalizeCurrencyAmount(
      amounts[cycle]!,
      account.currencyCode,
    );
  }
  return _ScheduledCreditDebt(amounts, used, refundIds);
}

/// 构造首页使用的当前未出账窗口，出账日当天开始下一期。
///
/// 只有最近账单恰好是目标账期的上一期时才采用它，避免用户漏录数月账单后把多个月
/// 的流水误并入本期。正式截止日可补充更早的起点，但不排除出账日当天；
/// 已有明确账期标识的交易仍按标识归属，不靠修改发生日期切账。
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
  final inferredStart = expectedPreviousStatement;
  var start = inferredStart;
  if (latestStatement != null &&
      dateOnly(
        latestStatement.statementDate,
      ).isAtSameMomentAs(dateOnly(expectedPreviousStatement))) {
    final confirmedStart = dateOnly(
      addCalendarDays(latestStatement.periodEnd, 1),
    );
    if (confirmedStart.isBefore(inferredStart)) {
      start = confirmedStart;
    }
  }
  return DateWindow(start: start, end: addCalendarDays(nextStatement, -1));
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
  final cycleId = billingCycleIdForWindow(cycle);
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

/// 无明确归期的出账日消费不能被旧快照的包含式截止日吸收到上一期。
bool _expenseIsInStatementPeriod(
  LedgerEntry expense,
  BillingStatement statement,
) {
  final date = dateOnly(expense.occurredAt);
  return date.isBefore(dateOnly(statement.statementDate)) &&
      !date.isBefore(dateOnly(statement.periodStart)) &&
      !date.isAfter(dateOnly(statement.periodEnd));
}

/// 从已到账退款推导出账后退款对正式账单的冲抵关系。
///
/// [entries] 是同账本交易， [statements] 是正式账单， [now] 控制未来到账退款不提前
/// 生效。仅原支出与退款都在同一信用账户、且唯一匹配一期账单时分配；账单日当天
/// 因缺银行切账时刻而保持未分配，避免错误冲抵。退款金额采用账户实际到账金额。
List<StatementRefundAllocation> allocateStatementRefunds({
  required Iterable<LedgerEntry> entries,
  required Iterable<BillingStatement> statements,
  required DateTime now,
}) {
  final entryList = entries.toList();
  final statementList = statements.toList();
  final byId = <String, LedgerEntry>{
    for (final entry in entryList) entry.id: entry,
  };
  final allocations = <StatementRefundAllocation>[];
  for (final refund in entryList) {
    if (!refund.isSettledRefund ||
        dateOnly(refund.settledAt!).isAfter(dateOnly(now))) {
      continue;
    }
    final original = byId[refund.refundOf];
    if (original == null ||
        original.type != EntryType.expense ||
        original.bookId != refund.bookId ||
        original.accountId.isEmpty ||
        original.accountId != refund.accountId) {
      continue;
    }
    final candidates = statementList.where((statement) {
      if (statement.bookId != original.bookId ||
          statement.accountId != original.accountId ||
          !dateOnly(
            refund.settledAt!,
          ).isAfter(dateOnly(statement.statementDate))) {
        return false;
      }
      if (original.billingCycleId != null) {
        return original.billingCycleId ==
            billingCycleIdFor(statement.statementDate);
      }
      return _expenseIsInStatementPeriod(original, statement);
    }).toList();
    if (candidates.length != 1) continue;
    final statement = candidates.single;
    final amount =
        refund.accountAmount ??
        (refund.currencyCode == statement.currencyCode ? refund.amount : null);
    if (amount == null || !amount.isFinite || amount <= 0) continue;
    allocations.add(
      StatementRefundAllocation(
        statementId: statement.id,
        refundEntryId: refund.id,
        amount: amount,
        settledAt: refund.settledAt!,
      ),
    );
  }
  return allocations;
}

/// 汇总正式账单与尚无正式快照的到期流水。
///
/// “已出账待还”汇总正式账单剩余和到期流水，不从账户总余额猜；“当前未出账”只统计最近一期
/// 账期结束后的消费与退款，不把还款转账混入消费。缺少正式账单的已到期消费
/// 按配置结转，但不伪造最近一期正式账单。
CreditStatementOverview creditStatementOverview({
  required Account account,
  required Iterable<LedgerEntry> entries,
  required Iterable<BillingStatement> statements,
  required DateTime now,
  Iterable<StatementRepaymentAllocation> repaymentAllocations = const [],
  Set<String>? internalAccountIds,
}) {
  final entryList = entries
      .where((item) => item.bookId == account.bookId)
      .toList();
  final statementList = statements
      .where(
        (item) =>
            item.bookId == account.bookId &&
            !dateOnly(item.statementDate).isAfter(dateOnly(now)),
      )
      .toList();
  final allocations = allocateStatementRefunds(
    entries: entryList,
    statements: statementList,
    now: now,
  );
  final refundsByStatement = <String, double>{};
  for (final allocation in allocations) {
    refundsByStatement.update(
      allocation.statementId,
      (amount) => amount + allocation.amount,
      ifAbsent: () => allocation.amount,
    );
  }
  final allocatedRefundIds = allocations
      .map((item) => item.refundEntryId)
      .toSet();
  final sorted =
      statementList.where((item) => item.accountId == account.id).map((item) {
        final adjusted = item.copyWith(
          refundAmount: refundsByStatement[item.id] ?? 0,
        );
        return adjusted.copyWith(status: normalizedStatementStatus(adjusted));
      }).toList()..sort((a, b) => b.statementDate.compareTo(a.statementDate));
  final latest = sorted.firstOrNull;
  var billed = sorted.fold<double>(
    0,
    (sum, statement) => sum + statement.outstandingAmount,
  );
  final cutoff = latest?.periodEnd;
  final statementDay = account.statementDay;
  if (statementDay != null) {
    final scheduled = _scheduledCreditDebt(
      account: account,
      statementDay: statementDay,
      entries: entryList,
      statements: statementList,
      allocations: repaymentAllocations,
      internalAccountIds: internalAccountIds ?? {account.id},
      now: now,
    );
    billed += scheduled.amounts.values.fold<double>(
      0,
      (sum, amount) => sum + amount,
    );
    allocatedRefundIds.addAll(scheduled.refundIds);
  }
  final nextStatement = statementDay == null
      ? null
      : billingStatementDateForExpense(statementDay, now);
  final currentCycleId = nextStatement == null
      ? null
      : billingCycleIdFor(nextStatement);
  final currentCycle = nextStatement == null
      ? null
      : _currentBillingCycleFromStatement(
          statementDay: statementDay!,
          nextStatement: nextStatement,
          latestStatement: latest,
        );
  double unbilled;
  if (cutoff == null) {
    unbilled = statementDay == null
        ? 0
        : billingCycleExpense(
            entryList,
            account.id,
            _currentBillingCycleFromStatement(
              statementDay: statementDay,
              nextStatement: nextStatement!,
              latestStatement: null,
            ),
          );
  } else {
    unbilled = 0;
    for (final entry in entryList) {
      if (allocatedRefundIds.contains(entry.id)) continue;
      // 退款只有在实际到账后才会改变信用账户口径，因此筛选未出账条目时
      // 必须使用与余额计算相同的到账日，而不能只看退款原始发生日。
      final effectDate = accountEffectDate(entry);
      if (entry.accountId != account.id || effectDate.isAfter(now)) {
        continue;
      }
      final belongsToCurrentCycle = entry.billingCycleId == null
          ? currentCycle == null
                ? effectDate.isAfter(cutoff)
                : !dateOnly(effectDate).isBefore(currentCycle.start) &&
                      !dateOnly(effectDate).isAfter(currentCycle.end)
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

/// 根据应还、实还与出账后退款归一账单状态。争议账单保持 disputed。
BillingStatementStatus normalizedStatementStatus(BillingStatement statement) {
  if (statement.status == BillingStatementStatus.disputed) {
    return statement.status;
  }
  if (statement.outstandingAmount <= 0) {
    return BillingStatementStatus.paid;
  }
  if (statement.paidAmount > 0 || statement.refundAmount > 0) {
    return BillingStatementStatus.partiallyPaid;
  }
  return BillingStatementStatus.open;
}
