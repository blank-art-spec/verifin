import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/credit_repayment_page.dart';
import 'package:verifin/pages/transaction_detail_page.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  Account repaymentAccount(
    String id, {
    bool credit = false,
    String currencyCode = 'CNY',
    double balance = 0,
  }) => Account(
    id: id,
    bookId: 'default',
    name: id,
    type: credit ? AccountType.creditCard : AccountType.debitCard,
    groupId: null,
    initialBalance: balance,
    iconCode: credit ? 'credit' : 'wallet',
    note: '',
    includeInAssets: true,
    hidden: false,
    currencyCode: currencyCode,
  );

  Future<void> createStatement(
    VeriFinController controller,
    Account card,
  ) async {
    final now = DateTime.now();
    expect(
      await controller.createBillingStatement(
        account: card,
        statementDate: DateTime(now.year, now.month - 1, 25),
        periodStart: DateTime(now.year, now.month - 2, 26),
        periodEnd: DateTime(now.year, now.month - 1, 25, 23, 59, 59),
        statementAmount: 100,
        minimumPayment: 0,
        dueDate: now,
        paidAmount: 0,
      ),
      isTrue,
    );
  }

  Future<void> openRepayment(
    WidgetTester tester,
    VeriFinController controller,
    Account card,
  ) async {
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => CreditRepaymentPage(account: card),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('可更换扣款账户，保存后只扣选中账户并同步结清账单', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final card = repaymentAccount('card', credit: true, balance: -150);
    final bank = repaymentAccount('default-bank', balance: 1000);
    final other = repaymentAccount('other-bank', balance: 2000);
    controller
      ..addAccount(card)
      ..addAccount(bank)
      ..addAccount(other)
      ..setDefaultAccountId(bank.id);
    await controller.waitForPendingWrites();
    await createStatement(controller, card);
    await openRepayment(tester, controller, card);
    expect(find.textContaining(bank.name), findsOneWidget);
    await tester.tap(find.byKey(const Key('repay_from_account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(other.name));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.accountBalance(bank), 1000);
    expect(controller.accountBalance(other), 1900);
    expect(controller.accountBalance(card), -50);
    expect(controller.creditOverview(card).billedOutstanding, 0);
    expect(controller.entries.single.accountId, other.id);
    expect(controller.entries.single.accountAmount, 100);
    expect(controller.entries.single.toAccountAmount, 100);
    expect(controller.entries.single.baseAmount, 0);
    expect(
      controller.billingStatements.single.status,
      BillingStatementStatus.paid,
    );
    expect(controller.statementRepaymentAllocations.single.amount, 100);
  });

  for (final width in [393.0, 360.0]) {
    testWidgets('跨币种缺汇率时手填实际扣款，按美元到账额结清账单（$width）', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await makeController();
      addTearDown(controller.dispose);
      final card = repaymentAccount(
        'usd-card',
        credit: true,
        currencyCode: 'USD',
        balance: -150,
      );
      final bank = repaymentAccount('cny-bank', balance: 1000);
      controller
        ..addAccount(card)
        ..addAccount(bank)
        ..setDefaultAccountId(bank.id);
      await controller.waitForPendingWrites();
      await createStatement(controller, card);
      await openRepayment(tester, controller, card);
      expect(find.text('尚未设置汇率'), findsOneWidget);
      expect(
        tester
            .widget<SaveHeaderAction>(find.byType(SaveHeaderAction))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('repay_from_amount')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('number_key_C')));
      for (final digit in ['7', '2', '5']) {
        await tester.tap(find.byKey(Key('number_key_$digit')));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('number_pad_ok')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      expect(controller.accountBalance(bank), 275);
      expect(controller.accountBalance(card), -50);
      final repayment = controller.entries.single;
      expect(repayment.currencyCode, 'CNY');
      expect(repayment.amount, 725);
      expect(repayment.accountAmount, 725);
      expect(repayment.toAccountAmount, 100);
      expect(repayment.conversionSource, ConversionSource.manual);
      expect(repayment.baseAmount, 0);
      expect(controller.statementRepaymentAllocations.single.amount, 100);
      expect(controller.creditOverview(card).billedOutstanding, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final withoutAccount in [false, true]) {
    testWidgets('跨币种按汇率预填，无账户还款=$withoutAccount', (tester) async {
      final controller = await makeController();
      addTearDown(controller.dispose);
      final card = repaymentAccount(
        'usd-card',
        credit: true,
        currencyCode: 'USD',
        balance: -100,
      );
      final bank = repaymentAccount('cny-bank', balance: 1000);
      controller
        ..addAccount(card)
        ..addAccount(bank)
        ..setDefaultAccountId(bank.id);
      await controller.waitForPendingWrites();
      await controller.saveExchangeRateDraft(
        currencyCode: 'USD',
        effectiveDate: DateTime(2020),
        rateToBase: 7.2,
      );
      await createStatement(controller, card);
      await openRepayment(tester, controller, card);
      expect(find.textContaining('720'), findsWidgets);
      if (withoutAccount) {
        await tester.tap(find.byKey(const Key('repay_from_account')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('无账户转账还款'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('repay_from_amount')), findsNothing);
      }
      await tester.tap(find.byTooltip('保存'));
      await tester.pumpAndSettle();
      expect(controller.accountBalance(bank), withoutAccount ? 1000 : 280);
      expect(controller.accountBalance(card), 0);
      expect(
        controller.entries.single.currencyCode,
        withoutAccount ? 'USD' : 'CNY',
      );
      expect(controller.entries.single.amount, withoutAccount ? 100 : 720);
      expect(
        controller.entries.single.accountAmount,
        withoutAccount ? isNull : 720,
      );
      expect(controller.entries.single.toAccountAmount, 100);
      expect(
        controller.entries.single.conversionSource,
        withoutAccount ? ConversionSource.identity : ConversionSource.rateTable,
      );
    });
  }

  testWidgets('只改扣款账户也会提示保存，选择器取消不改变草稿', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final card = repaymentAccount('card', credit: true, balance: -100);
    final bank = repaymentAccount('bank', balance: 1000);
    controller
      ..addAccount(card)
      ..addAccount(bank)
      ..setDefaultAccountId(bank.id);
    await controller.waitForPendingWrites();
    await openRepayment(tester, controller, card);
    await tester.tap(find.byKey(const Key('repay_from_account')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.textContaining(bank.name), findsOneWidget);
    await tester.tap(find.byKey(const Key('repay_from_account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无账户转账还款'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('保存修改？'), findsOneWidget);
    expect(controller.entries, isEmpty);
    await tester.tap(find.text('不保存'));
    await tester.pumpAndSettle();
    expect(find.byType(CreditRepaymentPage), findsNothing);
  });

  testWidgets('还款预填已出账待还，默认扣款账户可切换为无账户转账还款', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final card = Account(
      id: 'credit-card-1',
      bookId: controller.activeBook.id,
      name: '测试信用卡',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: -10438.30,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final bank = Account(
      id: 'bank-1',
      bookId: controller.activeBook.id,
      name: '测试储蓄卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 1000,
      iconCode: 'wallet',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    controller
      ..addAccount(card)
      ..addAccount(bank)
      ..setDefaultAccountId(bank.id);

    await controller.waitForPendingWrites();
    final now = DateTime.now();
    await controller.createBillingStatement(
      account: card,
      statementDate: DateTime(now.year, now.month - 1, 25),
      periodStart: DateTime(now.year, now.month - 2, 26),
      periodEnd: DateTime(now.year, now.month - 1, 25, 23, 59, 59),
      statementAmount: 5219.15,
      minimumPayment: 0,
      dueDate: now,
      paidAmount: 0,
    );
    expect(controller.accountBalance(card), -10438.30);

    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => CreditRepaymentPage(account: card),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 只预填已出账的 5219.15，恢复默认储蓄卡选择，并可改为无账户还款。
    expect(find.text('还款'), findsWidgets);
    expect(find.textContaining('5219.15'), findsWidgets);
    expect(find.textContaining('10438.3'), findsNothing);
    expect(find.text('扣款账户'), findsOneWidget);
    expect(find.textContaining('测试储蓄卡'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repay_from_account')));
    await tester.pumpAndSettle();
    expect(find.text('测试信用卡'), findsOneWidget); // 只有页头，不在候选中。
    await tester.tap(find.text('无账户转账还款'));
    await tester.pumpAndSettle();
    expect(find.text('无账户转账还款'), findsOneWidget);

    // 点击右上角保存。
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    // 本期正式账单结清；另一部分真实欠款保留，储蓄卡没有被扣款。
    expect(controller.accountBalance(card), closeTo(-5219.15, 0.001));
    expect(controller.accountBalance(bank), 1000);
    expect(controller.creditOverview(card).billedOutstanding, 0);
    expect(
      controller.billingStatements.single.status,
      BillingStatementStatus.paid,
    );
    expect(controller.billingStatements.single.paidAmount, 5219.15);
    final repayment = controller.entries.firstWhere(
      (entry) =>
          entry.type == EntryType.transfer && entry.toAccountId == card.id,
    );
    expect(repayment.amount, 5219.15);
    expect(repayment.accountId, '');
    expect(repayment.accountAmount, isNull);
    expect(repayment.toAccountAmount, 5219.15);
    expect(repayment.baseAmount, 0);
    expect(repayment.auditHistory, hasLength(1));
    expect(
      controller.allocationsForStatement(
        controller.billingStatements.single.id,
      ),
      hasLength(1),
    );
    // 用真实转账分类（非空），列表不会回退成「已删除分类」。
    final transferCategoryIds = controller
        .categoriesForType(EntryType.transfer)
        .map((c) => c.id)
        .toList();
    expect(repayment.categoryId, isNotEmpty);
    expect(transferCategoryIds, contains(repayment.categoryId));
  });

  testWidgets('无正式账单的结转待还也可直接还款，无需选择账户', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final card = Account(
      id: 'credit-card-2',
      bookId: controller.activeBook.id,
      name: '花呗',
      type: AccountType.creditAccount,
      groupId: null,
      initialBalance: 0,
      iconCode: 'wallet',
      note: '',
      includeInAssets: true,
      hidden: false,
      statementDay: 1,
    );
    controller.addAccount(card);
    final now = DateTime.now();
    controller.addEntry(
      LedgerEntry(
        id: 'last-cycle-expense',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 300,
        categoryId: controller.categoriesForType(EntryType.expense).first.id,
        accountId: card.id,
        note: '',
        occurredAt: DateTime(now.year, now.month - 1, 15),
      ),
    );
    await controller.waitForPendingWrites();
    expect(controller.creditOverview(card).billedOutstanding, 300);

    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => CreditRepaymentPage(account: card),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 没有其他可用账户时默认无账户，仍可打开选择器。
    expect(find.byKey(const Key('repay_from_account')), findsOneWidget);
    expect(find.text('无账户转账还款'), findsOneWidget);
    expect(find.byKey(const Key('repay_from_amount')), findsNothing);

    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    // 欠款被抵消，且没有从任何账户扣款（转账 accountId 为空）。
    expect(controller.accountBalance(card), 0);
    expect(controller.creditOverview(card).billedOutstanding, 0);
    expect(controller.billingStatements, isEmpty);
    final repayment = controller.entries.firstWhere(
      (entry) =>
          entry.type == EntryType.transfer && entry.toAccountId == card.id,
    );
    expect(repayment.accountId, '');
    expect(repayment.amount, 300);

    // 仅记录信用端还款仍可查看交易，不回退到首个账户，也不清空转入端。
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: TransactionDetailPage(entryId: repayment.id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无账户转账还款'), findsOneWidget);
    expect(find.textContaining('花呗'), findsWidgets);

    // 冷启动后自动结转待还保持为 0，不能把还款重复计入下一期。
    final reloaded = await makeController(store);
    addTearDown(reloaded.dispose);
    final reloadedCard = reloaded.accounts.firstWhere(
      (item) => item.id == card.id,
    );
    expect(reloaded.accountBalance(reloadedCard), 0);
    expect(reloaded.creditOverview(reloadedCard).billedOutstanding, 0);
  });

  testWidgets('没有已出账待还时不以历史总欠款预填还款', (WidgetTester tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final card = Account(
      id: 'credit-only-history',
      bookId: controller.activeBook.id,
      name: '仅有历史欠款',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: -10438.30,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    controller.addAccount(card);
    await controller.waitForPendingWrites();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: CreditRepaymentPage(account: card)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('10438.3'), findsNothing);
    expect(find.byKey(const Key('repay_from_account')), findsOneWidget);
    // 金额为 0 时保存不可用，浏览页面不会凭空结清未知归属的历史欠款。
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.entries, isEmpty);
    expect(controller.accountBalance(card), -10438.30);
  });

  testWidgets('还款页未改动时返回不弹未保存确认，也不写交易', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final card = Account(
      id: 'credit-card-3',
      bookId: controller.activeBook.id,
      name: '测试信用卡',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: -500,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final bank = Account(
      id: 'bank-3',
      bookId: controller.activeBook.id,
      name: '测试储蓄卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 1000,
      iconCode: 'wallet',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    controller
      ..addAccount(card)
      ..addAccount(bank)
      ..setDefaultAccountId(bank.id);

    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => CreditRepaymentPage(account: card),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 只是打开看了看欠款就返回：预填内容不算「未保存修改」，不得弹确认框。
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(CreditRepaymentPage), findsNothing);
    expect(controller.entries, isEmpty);
    expect(controller.accountBalance(card), -500);
  });

  testWidgets('重选同一天不算改动，返回不弹未保存确认', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    final card = Account(
      id: 'credit-card-4',
      bookId: controller.activeBook.id,
      name: '测试信用卡',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: -500,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final bank = Account(
      id: 'bank-4',
      bookId: controller.activeBook.id,
      name: '测试储蓄卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 1000,
      iconCode: 'wallet',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    controller
      ..addAccount(card)
      ..addAccount(bank)
      ..setDefaultAccountId(bank.id);

    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => CreditRepaymentPage(account: card),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 打开日期选择器，原样确认同一天：草稿指纹按分钟比较，不该被判成改动。
    await tester.tap(find.byIcon(Icons.event_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.byType(CreditRepaymentPage), findsNothing);
    expect(controller.entries, isEmpty);
  });
}
