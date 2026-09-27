import '../credit_card.dart';
import '../ledger_math.dart';
import '../models.dart';

/// 账期预算所处的提醒档位。
///
/// 档位只随消费增加而升级：80% 进入 [warning]，恰好达到预算进入 [reached]，超过
/// 预算进入 [exceeded]。退款使消费回落时，界面会展示当前档位；系统通知去重在调度层
/// 另行记录，避免同一账期反复跨线造成骚扰。
enum CycleBudgetAlertLevel { none, warning, reached, exceeded }

/// 单个信用主体的提醒投影。
///
/// 这是从账目、正式账单和账户规则实时计算出的只读快照，不增加第二份账务状态。
/// UI 与系统通知共用它，确保“页面显示”和“通知内容”不会采用两套口径。
class CreditReminderSnapshot {
  const CreditReminderSnapshot({
    required this.creditAccount,
    required this.overview,
    required this.daysUntilStatement,
    required this.dueDate,
    required this.daysUntilDue,
    required this.latestBilledAmount,
    required this.latestOutstandingAmount,
    required this.hasFormalStatement,
    required this.formalStatementMissingConversion,
    required this.budgetAlertLevel,
    required this.budgetUsageRatio,
  });

  /// 信用主体配置，提供名称、币种、预算和账期规则。
  final CreditAccount creditAccount;

  /// 与首页完全一致的当前账期聚合快照。
  final CreditCycleOverview overview;

  /// 距离下一次出账的日历日数；今天为 0。
  final int daysUntilStatement;

  /// 有未结正式账单时为最早到期日，否则为最近正式账单或当前规则推导的到期日。
  final DateTime dueDate;

  /// [dueDate] 距今天的日历日数；负数表示已逾期。
  final int daysUntilDue;

  /// 最近一个出账日下，多币种正式账单折算到信用主体币种后的账单金额。
  final double latestBilledAmount;

  /// 最近一个出账日下仍未结清的金额，口径与 [latestBilledAmount] 相同。
  final double latestOutstandingAmount;

  /// 当前信用主体是否至少存在一张截至今天的正式账单。
  final bool hasFormalStatement;

  /// 最近一期正式账单是否因缺少汇率而无法合计。
  final bool formalStatementMissingConversion;

  /// 当前账期预算档位；未设置预算或缺失汇率时为 [CycleBudgetAlertLevel.none]。
  final CycleBudgetAlertLevel budgetAlertLevel;

  /// 本账期净消费 / 账期预算；无有效预算或缺失汇率时为 null。
  final double? budgetUsageRatio;

  /// 最近一期正式账单存在且未结金额已归零时为 true。
  bool get latestStatementSettled =>
      hasFormalStatement &&
      !formalStatementMissingConversion &&
      latestOutstandingAmount <= 0.005;

  /// 任一期正式账单仍有待还金额时为 true；总额沿用首页信用主体聚合口径。
  bool get hasOutstandingStatement =>
      !overview.missingConversion && overview.billedOutstanding > 0.005;
}

/// 计算单个信用主体的预算、出账和还款提醒投影。
///
/// [convertToCreditCurrency] 负责把正式账单币种换算为信用主体币种；返回 null 表示
/// 缺少汇率。账单以最近出账日分组，多币种子账户同日账单会被合并，旧账单不会冒充
/// “本期已出账”。到期提醒则优先选择所有未结账单中最早的到期日，避免漏掉逾期项。
CreditReminderSnapshot buildCreditReminderSnapshot({
  required CreditAccount creditAccount,
  required CreditCycleOverview overview,
  required Iterable<Account> childAccounts,
  required Iterable<BillingStatement> statements,
  required DateTime now,
  required double? Function(
    double amount,
    String sourceCurrencyCode,
    DateTime date,
  )
  convertToCreditCurrency,
}) {
  final today = dateOnly(now);
  final childIds = childAccounts.map((item) => item.id).toSet();
  final visibleStatements = statements
      .where(
        (statement) =>
            childIds.contains(statement.accountId) &&
            !dateOnly(statement.statementDate).isAfter(today),
      )
      .toList(growable: false);
  DateTime? latestStatementDate;
  BillingStatement? earliestOutstanding;
  for (final statement in visibleStatements) {
    if (latestStatementDate == null ||
        statement.statementDate.isAfter(latestStatementDate)) {
      latestStatementDate = statement.statementDate;
    }
    if (statement.outstandingAmount > 0.005 &&
        (earliestOutstanding == null ||
            statement.dueDate.isBefore(earliestOutstanding.dueDate))) {
      earliestOutstanding = statement;
    }
  }

  var latestBilledAmount = 0.0;
  var latestOutstandingAmount = 0.0;
  var missingConversion = false;
  if (latestStatementDate != null) {
    final latestDate = dateOnly(latestStatementDate);
    for (final statement in visibleStatements.where(
      (item) => dateOnly(item.statementDate).isAtSameMomentAs(latestDate),
    )) {
      final billed = convertToCreditCurrency(
        statement.statementAmount,
        statement.currencyCode,
        statement.statementDate,
      );
      final outstanding = convertToCreditCurrency(
        statement.outstandingAmount,
        statement.currencyCode,
        statement.statementDate,
      );
      if (billed == null || outstanding == null) {
        missingConversion = true;
        continue;
      }
      latestBilledAmount += billed;
      latestOutstandingAmount += outstanding;
    }
  }

  final budget = creditAccount.cycleBudget;
  final ratio = budget == null || budget <= 0 || overview.missingConversion
      ? null
      : overview.netSpending.clamp(0.0, double.infinity) / budget;
  final budgetLevel = switch (ratio) {
    null => CycleBudgetAlertLevel.none,
    > 1.0000001 => CycleBudgetAlertLevel.exceeded,
    >= 0.9999999 => CycleBudgetAlertLevel.reached,
    >= 0.8 => CycleBudgetAlertLevel.warning,
    _ => CycleBudgetAlertLevel.none,
  };
  final dueDate =
      earliestOutstanding?.dueDate ??
      (latestStatementDate == null
          ? overview.dueDate
          : visibleStatements
                .where(
                  (item) => dateOnly(
                    item.statementDate,
                  ).isAtSameMomentAs(dateOnly(latestStatementDate!)),
                )
                .map((item) => item.dueDate)
                .reduce((a, b) => a.isBefore(b) ? a : b));

  return CreditReminderSnapshot(
    creditAccount: creditAccount,
    overview: overview,
    daysUntilStatement: calendarDaysBetween(today, overview.nextStatementDate),
    dueDate: dueDate,
    daysUntilDue: calendarDaysBetween(today, dueDate),
    latestBilledAmount: latestBilledAmount,
    latestOutstandingAmount: latestOutstandingAmount,
    hasFormalStatement: latestStatementDate != null,
    formalStatementMissingConversion: missingConversion,
    budgetAlertLevel: budgetLevel,
    budgetUsageRatio: ratio,
  );
}
