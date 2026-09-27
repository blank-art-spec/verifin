import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  Account card(String id, String name) => Account(
    id: id,
    bookId: 'default',
    name: name,
    type: AccountType.creditCard,
    groupId: null,
    initialBalance: 0,
    iconCode: 'credit',
    note: '',
    includeInAssets: true,
    hidden: false,
    creditLimit: 70000,
    statementDay: 25,
    dueDay: 13,
  );

  test('新信用账户自动创建主体，已有账户可合并为同一主体', () async {
    final controller = await makeController();
    expect(await controller.addAccountDraft(card('cny', '招商人民币')), isTrue);
    expect(await controller.addAccountDraft(card('usd', '招商美元')), isTrue);
    expect(controller.creditAccounts, hasLength(2));

    final parent = controller.creditAccountForAccount(
      controller.accounts.firstWhere((item) => item.id == 'cny'),
    )!;
    final usd = controller.accounts.firstWhere((item) => item.id == 'usd');
    expect(
      await controller.saveAccountDraft(
        usd.copyWith(creditAccountId: parent.id),
      ),
      isTrue,
    );

    expect(controller.creditAccounts, hasLength(1));
    expect(controller.accountsForCreditAccount(parent.id), hasLength(2));
  });

  test('动态还款规则和账期预算可持久化并在冷启动恢复', () async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    expect(await controller.addAccountDraft(card('card', '招商信用卡')), isTrue);
    final original = controller.creditAccounts.single;
    expect(
      await controller.saveCreditAccountDraft(
        original.copyWith(
          name: '招商信用卡 4185',
          dueRuleType: CreditDueRuleType.daysAfterStatement,
          daysAfterStatement: 20,
          cycleBudget: 4000,
        ),
      ),
      isTrue,
    );

    final restored = await makeController(store);
    expect(restored.creditAccounts.single.name, '招商信用卡 4185');
    expect(
      restored.creditAccounts.single.dueRuleType,
      CreditDueRuleType.daysAfterStatement,
    );
    expect(restored.creditAccounts.single.daysAfterStatement, 20);
    expect(restored.creditAccounts.single.cycleBudget, 4000);
  });

  test('旧账户快照再次保存不会重复创建信用主体', () async {
    final controller = await makeController();
    final staleSnapshot = card('card', '招商信用卡');
    controller.addAccount(staleSnapshot);
    await controller.waitForPendingWrites();

    expect(
      await controller.saveAccountDraft(
        staleSnapshot.copyWith(note: '更新备注'),
      ),
      isTrue,
    );

    expect(controller.creditAccounts, hasLength(1));
    expect(controller.accounts.single.creditAccountId, isNotNull);
    expect(controller.accounts.single.note, '更新备注');
  });

  test('共享额度只镜像到同币种子账户，日期规则同步全部子账户', () async {
    final controller = await makeController();
    expect(await controller.addAccountDraft(card('cny', '招商人民币')), isTrue);
    final parent = controller.creditAccounts.single;
    expect(
      await controller.addAccountDraft(
        card(
          'usd',
          '招商美元',
        ).copyWith(currencyCode: 'USD', creditAccountId: parent.id),
      ),
      isTrue,
    );

    final cny = controller.accounts.firstWhere((item) => item.id == 'cny');
    expect(
      await controller.saveAccountDraft(cny.copyWith(creditLimit: 88000)),
      isTrue,
    );

    expect(controller.creditAccounts.single.creditLimit, 88000);
    final children = controller.accountsForCreditAccount(parent.id);
    expect(
      children.firstWhere((item) => item.currencyCode == 'CNY').creditLimit,
      88000,
    );
    expect(
      children.firstWhere((item) => item.currencyCode == 'USD').creditLimit,
      isNull,
      reason: '外币子账户不能把 8.8 万人民币共享额度误显示成 8.8 万美元',
    );
    expect(children.map((item) => item.statementDay), everyElement(25));
  });
}
