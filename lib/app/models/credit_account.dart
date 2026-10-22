/// 多币种主账户模型：银行、证券与信用主体，沿用已有类名和存储结构。
///
/// `Account` 继续表达具体币种子账户及其流水；多个子账户通过
/// `Account.creditAccountId` 指向同一个 [CreditAccount]。这样人民币、美元等子账户
/// 不会各自重复一份信用额度和账单规则。
library;

import 'currency.dart';
import 'ledger_book.dart';

/// 到期还款日的推导方式。
enum CreditDueRuleType {
  /// 每期账单出具后的次月固定日期，例如 9 月 25 日账单在 10 月 13 日到期。
  fixedDay,

  /// 从账单日按日历日顺延固定天数，例如账单日后 20 天。
  daysAfterStatement;

  /// 从 SQLite / 备份字符串恢复枚举；未知值回退为兼容旧账户的固定日规则。
  static CreditDueRuleType fromStorage(String? value) =>
      CreditDueRuleType.values.firstWhere(
        (item) => item.name == value,
        orElse: () => CreditDueRuleType.fixedDay,
      );
}

/// 主账户：真实信用卡、银行账户或证券账户的多币种容器。
///
/// 类名和存储字段沿用历史名称，保持 SQLite v27 / JSON v9 结构不变。
/// 主体类型由子账户能力确定；普通主账户不设置任何额度、账单或还款字段。
class CreditAccount {
  const CreditAccount({
    required this.id,
    required this.bookId,
    required this.name,
    required this.institution,
    required this.cardLast4,
    required this.currencyCode,
    required this.creditLimit,
    required this.statementDay,
    required this.dueRuleType,
    required this.dueDay,
    required this.daysAfterStatement,
    required this.cycleBudget,
  });

  final String id;
  final String bookId;

  /// 面向用户的主体名称，例如“招商信用卡 4185”或“花呗”。
  final String name;

  /// 发卡行或信用服务机构；允许为空，避免强迫用户重复填写名称。
  final String institution;

  /// 主体共享的卡尾号。无实体卡的信用平台可为空。
  final String cardLast4;

  /// 主账户币种。普通主体用于余额估值；信用主体用于共享额度与账期预算。
  final String currencyCode;

  /// 共享额度；null 表示未设置。
  final double? creditLimit;

  /// 每月账单日，限制为 1–28；null 表示暂不启用账期计算。
  final int? statementDay;

  final CreditDueRuleType dueRuleType;

  /// [CreditDueRuleType.fixedDay] 使用的次月固定还款日，限制为 1–28。
  final int? dueDay;

  /// [CreditDueRuleType.daysAfterStatement] 使用的日历日间隔，必须大于 0。
  final int? daysAfterStatement;

  /// 当前账期预算；null 表示未设置。预算与自然月预算相互独立。
  final double? cycleBudget;

  /// 账单日和所选还款规则都已填写时为 true；首页只有在此时才展示推导日期，
  /// 避免把缺失值用某个“看似合理”的日期静默补齐后误导用户。
  bool get hasCompleteCycleRule =>
      statementDay != null &&
      switch (dueRuleType) {
        CreditDueRuleType.fixedDay => dueDay != null,
        CreditDueRuleType.daysAfterStatement => daysAfterStatement != null,
      };

  CreditAccount copyWith({
    String? id,
    String? bookId,
    String? name,
    String? institution,
    String? cardLast4,
    String? currencyCode,
    double? creditLimit,
    bool clearCreditLimit = false,
    int? statementDay,
    bool clearStatementDay = false,
    CreditDueRuleType? dueRuleType,
    int? dueDay,
    bool clearDueDay = false,
    int? daysAfterStatement,
    bool clearDaysAfterStatement = false,
    double? cycleBudget,
    bool clearCycleBudget = false,
  }) => CreditAccount(
    id: id ?? this.id,
    bookId: bookId ?? this.bookId,
    name: name ?? this.name,
    institution: institution ?? this.institution,
    cardLast4: cardLast4 ?? this.cardLast4,
    currencyCode: (currencyCode ?? this.currencyCode).toUpperCase(),
    creditLimit: clearCreditLimit ? null : creditLimit ?? this.creditLimit,
    statementDay: clearStatementDay ? null : statementDay ?? this.statementDay,
    dueRuleType: dueRuleType ?? this.dueRuleType,
    dueDay: clearDueDay ? null : dueDay ?? this.dueDay,
    daysAfterStatement: clearDaysAfterStatement
        ? null
        : daysAfterStatement ?? this.daysAfterStatement,
    cycleBudget: clearCycleBudget ? null : cycleBudget ?? this.cycleBudget,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'bookId': bookId,
    'name': name,
    if (institution.isNotEmpty) 'institution': institution,
    if (cardLast4.isNotEmpty) 'cardLast4': cardLast4,
    'currencyCode': currencyCode,
    if (creditLimit != null) 'creditLimit': creditLimit,
    if (statementDay != null) 'statementDay': statementDay,
    'dueRuleType': dueRuleType.name,
    if (dueDay != null) 'dueDay': dueDay,
    if (daysAfterStatement != null) 'daysAfterStatement': daysAfterStatement,
    if (cycleBudget != null) 'cycleBudget': cycleBudget,
  };

  /// 从备份恢复信用主体；缺失字段采用不改变账务金额的保守默认值。
  static CreditAccount fromJson(Map<String, Object?> json) => CreditAccount(
    id: json['id'] as String,
    bookId: json['bookId'] as String? ?? defaultLedgerBookId,
    name: json['name'] as String? ?? '未命名信用账户',
    institution: json['institution'] as String? ?? '',
    cardLast4: json['cardLast4'] as String? ?? '',
    currencyCode: (json['currencyCode'] as String? ?? defaultCurrencyCode)
        .toUpperCase(),
    creditLimit: (json['creditLimit'] as num?)?.toDouble(),
    statementDay: (json['statementDay'] as num?)?.toInt(),
    dueRuleType: CreditDueRuleType.fromStorage(json['dueRuleType'] as String?),
    dueDay: (json['dueDay'] as num?)?.toInt(),
    daysAfterStatement: (json['daysAfterStatement'] as num?)?.toInt(),
    cycleBudget: (json['cycleBudget'] as num?)?.toDouble(),
  );
}
