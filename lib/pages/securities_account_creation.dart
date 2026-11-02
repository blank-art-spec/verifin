import 'package:flutter/material.dart';

import '../app/veri_fin_scope.dart';
import 'assets_pages.dart';

/// 从投资录入空态打开证券账户创建，固定 [bookId]，不在选择或取消时写账。
/// 表单复用普通新建账户页面，保存时改用账户与期初组合的原子创建命令。
Future<void> createSecuritiesAccount({
  required BuildContext context,
  required String bookId,
}) async {
  if (VeriFinScope.of(context).activeBook.id != bookId) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AddAccountPage(securities: true, bookId: bookId),
    ),
  );
}
