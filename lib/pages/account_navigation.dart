/// 账户详情的统一导航入口，集中区分主账户、证券账户和普通账户。
library;

import 'package:flutter/material.dart';

import '../app/veri_fin_scope.dart';
import 'account_detail_page.dart';
import 'credit_account_detail_page.dart';
import 'investment_page.dart';

/// 打开账户对应的真实详情页面，不根据账本名称或当前持仓数量猜测类型。
///
/// [context] 必须位于应用 Scope 内；[accountId] 是实际币种账户 ID；
/// [parentId] 是只负责聚合的主账户 ID。两种 ID 只能提供一种。
/// 账户被删除或已经不属于当前账本时直接返回，不回退到列表首账户。
Future<void> openAccountDetails({
  required BuildContext context,
  String? accountId,
  String? parentId,
}) async {
  assert((accountId == null) != (parentId == null));
  final controller = VeriFinScope.of(context);
  if (parentId != null) {
    if (!controller.accountParents.any((parent) => parent.id == parentId)) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CreditAccountDetailPage(parentId: parentId),
      ),
    );
    return;
  }
  final account = controller.accounts
      .where((candidate) => candidate.id == accountId)
      .firstOrNull;
  if (account == null) return;
  final securitiesEnabled = controller.investmentFor(account.id) != null;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => securitiesEnabled
          ? InvestmentPage(accountId: account.id)
          : AccountDetailPage(account: account),
    ),
  );
}
