import 'models.dart';

/// 只归并名称明确且配置不冲突的旧信用账户；所有账户和交易 id 保持不变。
({
  List<Account> accounts,
  List<CreditAccount> parents,
  Set<String> unresolvedAccountIds,
})
normalizeCreditHierarchy(List<Account> accounts, List<CreditAccount> parents) {
  final nextAccounts = List<Account>.of(accounts);
  final nextParents = List<CreditAccount>.of(parents);
  final groups = <String, List<Account>>{};
  for (final account in accounts.where((a) => a.type.supportsCredit)) {
    final match = RegExp(
      r'^(.+?)[.．·。/_\s-]+(人民币|美元|欧元|港币|港元|日元|英镑|澳元|加元|新加坡元|CNY|USD|EUR|HKD|JPY|GBP|AUD|CAD|SGD)$',
      caseSensitive: false,
    ).firstMatch(account.name.trim());
    if (match == null) continue;
    final suffix = match.group(2)!.toUpperCase();
    const codes = {
      '人民币': 'CNY',
      '美元': 'USD',
      '欧元': 'EUR',
      '港币': 'HKD',
      '港元': 'HKD',
      '日元': 'JPY',
      '英镑': 'GBP',
      '澳元': 'AUD',
      '加元': 'CAD',
      '新加坡元': 'SGD',
    };
    if ((codes[suffix] ?? suffix) != account.currencyCode) continue;
    groups
        .putIfAbsent('${account.bookId}\u0000${match.group(1)}', () => [])
        .add(account);
  }
  for (final group in groups.entries) {
    final children = group.value;
    if (children.map((a) => a.currencyCode).toSet().length != children.length) {
      continue;
    }
    final last4s = children
        .map((a) => a.cardLast4)
        .where((s) => s.isNotEmpty)
        .toSet();
    final statementDays = children
        .map((a) => a.statementDay)
        .whereType<int>()
        .toSet();
    final dueDays = children.map((a) => a.dueDay).whereType<int>().toSet();
    if (last4s.length > 1 || statementDays.length > 1 || dueDays.length > 1) {
      continue;
    }
    final linked = parents
        .where((p) => children.any((a) => a.creditAccountId == p.id))
        .toList();
    if (linked.isEmpty) continue;
    if (linked
            .where((p) => p.creditLimit != null)
            .map((p) => '${p.currencyCode}:${p.creditLimit}')
            .toSet()
            .length >
        1) {
      continue;
    }
    final prefix = group.key.split('\u0000').last;
    if (linked.any(
      (p) => p.name != prefix && !children.any((a) => a.name == p.name),
    )) {
      continue;
    }
    if (linked.length == 1 && linked.first.name == prefix) continue;
    // 不能拆开一个用户已维护的多子账户主体来按名称猜测重组。
    final ids = children.map((a) => a.id).toSet();
    if (linked.any(
      (p) =>
          accounts.any((a) => a.creditAccountId == p.id && !ids.contains(a.id)),
    )) {
      continue;
    }
    if (linked
            .map((p) => '${p.dueRuleType.name}:${p.daysAfterStatement}')
            .toSet()
            .length >
        1) {
      continue;
    }
    final currency =
        children.where((a) => a.currencyCode == 'CNY').firstOrNull ??
        children.first;
    final chosen =
        linked.where((p) => p.id == currency.creditAccountId).firstOrNull ??
        linked.first;
    final parent = chosen.copyWith(name: group.key.split('\u0000').last);
    nextParents.removeWhere((p) => linked.any((old) => old.id == p.id));
    nextParents.add(parent);
    for (final child in children) {
      final index = nextAccounts.indexWhere((a) => a.id == child.id);
      nextAccounts[index] = child.copyWith(creditAccountId: parent.id);
    }
  }
  final unresolved = <String>{
    for (final group in groups.values)
      if (nextAccounts
              .where((a) => group.any((g) => g.id == a.id))
              .map((a) => a.creditAccountId)
              .whereType<String>()
              .toSet()
              .length >
          1)
        for (final a in group) a.id,
  };
  return (
    accounts: nextAccounts,
    parents: nextParents,
    unresolvedAccountIds: unresolved,
  );
}

/// 还款页选择的是范围，实际到账始终用各子账户原币保存。
enum CreditRepaymentScope { current, all }

class CreditRepaymentLine {
  const CreditRepaymentLine({
    required this.accountId,
    required this.amount,
    this.sourceAmount,
    this.conversionSource = ConversionSource.manual,
  });
  final String accountId;
  final double amount;
  final double? sourceAmount;
  final ConversionSource conversionSource;
}
