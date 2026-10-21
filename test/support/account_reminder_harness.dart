import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'test_harness.dart';

/// 新账本不预置账户；提醒测试显式创建账户，相同 store 的冷启动继续读取原账户。
Future<VeriFinController> makeReminderController([
  LocalKeyValueStore? store,
]) async {
  final controller = await makeController(store);
  if (controller.accounts.isEmpty) {
    final saved = await controller.addAccountDraft(
      Account(
        id: 'reminder-test-account',
        bookId: controller.activeBook.id,
        name: '提醒测试账户',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 0,
        iconCode: 'cash',
        note: '',
        includeInAssets: true,
        hidden: false,
      ),
    );
    if (!saved) throw StateError('提醒测试账户创建失败');
  }
  return controller;
}
