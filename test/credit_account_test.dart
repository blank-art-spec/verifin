import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
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
    expect(
      await controller.addAccountDraft(
        card('usd', '招商美元').copyWith(currencyCode: 'USD'),
      ),
      isTrue,
    );
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

  test('同一招行信用主体的人民币还款不结清美元子账户', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    expect(
      await controller.addAccountDraft(
        card('cny', '招行人民币').copyWith(initialBalance: -200),
      ),
      isTrue,
    );
    final parent = controller.creditAccounts.single;
    expect(
      await controller.addAccountDraft(
        card('usd', '招行美元').copyWith(
          currencyCode: 'USD',
          initialBalance: -100,
          creditAccountId: parent.id,
        ),
      ),
      isTrue,
    );
    final now = DateTime.now();
    for (final account in controller.accounts) {
      expect(
        await controller.createBillingStatement(
          account: account,
          statementDate: DateTime(now.year, now.month - 1, 25),
          periodStart: DateTime(now.year, now.month - 2, 26),
          periodEnd: DateTime(now.year, now.month - 1, 25, 23, 59, 59),
          statementAmount: account.currencyCode == 'CNY' ? 200 : 100,
          minimumPayment: 0,
          dueDate: now,
          paidAmount: 0,
        ),
        isTrue,
      );
    }
    expect(
      (await controller.recordCreditRepayment(
        repaymentEntryId: 'repay-cny',
        accountId: 'cny',
        amount: 200,
        occurredAt: now,
      )).isSuccess,
      isTrue,
    );
    final cny = controller.accounts.firstWhere(
      (account) => account.id == 'cny',
    );
    final usd = controller.accounts.firstWhere(
      (account) => account.id == 'usd',
    );
    expect(controller.creditOverview(cny).billedOutstanding, 0);
    expect(controller.creditOverview(usd).billedOutstanding, 100);
    expect(controller.accountBalance(cny), 0);
    expect(controller.accountBalance(usd), -100);
    final usdStatement = controller.billingStatements.firstWhere(
      (statement) => statement.accountId == usd.id,
    );
    expect(usdStatement.paidAmount, 0);
    expect(usdStatement.status, isNot(BillingStatementStatus.paid));
    expect(controller.allocationsForStatement(usdStatement.id), isEmpty);

    // 同主体的内部币种调拨不能假装是外部还款并结清账单。
    expect(
      await controller.recordCreditRepayment(
        repaymentEntryId: 'internal-fx',
        accountId: usd.id,
        amount: 100,
        fromAccountId: cny.id,
        fromAmount: 720,
        occurredAt: now,
      ),
      isA<EntrySaveValidationFailure>(),
    );
    expect(controller.entries, hasLength(1));
    expect(controller.creditOverview(usd).billedOutstanding, 100);

    expect(
      (await controller.recordCreditRepayment(
        repaymentEntryId: 'repay-usd',
        accountId: usd.id,
        amount: 100,
        occurredAt: now,
      )).isSuccess,
      isTrue,
    );
    expect(controller.creditOverview(usd).billedOutstanding, 0);
    expect(controller.accountBalance(usd), 0);
  });

  test('失效或隐藏的扣款账户及缺少实际金额的跨币种还款不能落账', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await controller.addAccountDraft(card('cny', '人民币'));
    await controller.addAccountDraft(
      card('usd', '美元').copyWith(currencyCode: 'USD'),
    );
    await controller.addAccountDraft(
      card('hidden', '隐藏账户').copyWith(hidden: true),
    );
    final originalBookId = controller.activeBook.id;
    controller.addLedgerBook('其他账本');
    controller.addAccount(
      card('foreign', '其他账本账户').copyWith(bookId: controller.activeBook.id),
    );
    controller.switchLedgerBook(originalBookId);
    await controller.waitForPendingWrites();
    final invalidDrafts = <({String sourceId, double? sourceAmount})>[
      (sourceId: 'missing', sourceAmount: null),
      (sourceId: 'hidden', sourceAmount: null),
      (sourceId: 'foreign', sourceAmount: null),
      (sourceId: 'cny', sourceAmount: null),
      (sourceId: 'usd', sourceAmount: null),
      (sourceId: 'usd', sourceAmount: double.nan),
      (sourceId: 'usd', sourceAmount: 0.001),
    ];
    for (var i = 0; i < invalidDrafts.length; i++) {
      final draft = invalidDrafts[i];
      expect(
        await controller.recordCreditRepayment(
          repaymentEntryId: 'invalid-$i',
          accountId: 'cny',
          amount: 100,
          fromAccountId: draft.sourceId,
          fromAmount: draft.sourceAmount,
          occurredAt: DateTime.now(),
        ),
        isA<EntrySaveValidationFailure>(),
      );
    }
    expect(controller.entries, isEmpty);
    expect(controller.statementRepaymentAllocations, isEmpty);
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
      await controller.saveAccountDraft(staleSnapshot.copyWith(note: '更新备注')),
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
