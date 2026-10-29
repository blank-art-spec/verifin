import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/sample_investment_expectations.dart';
import 'support/investment_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  final opened = <AppDatabase>[];
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
  });

  // ffi 会跨调用复用 :memory: 数据库，测试间必须关闭以隔离。
  Future<LedgerRepository> openRepo() async {
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    opened.add(db);
    return SqliteLedgerRepository(db);
  }

  LedgerEntry entry(String id, {double amount = 10}) => LedgerEntry(
    id: id,
    bookId: defaultLedgerBookId,
    type: EntryType.expense,
    amount: amount,
    categoryId: 'dining',
    accountId: 'alipay',
    note: '',
    occurredAt: DateTime(2026, 5, int.parse(id)),
  );

  test('v14 已扣款待确认申购在 SQLite 冷读、预览和完整恢复后保留且不生成持仓或收入', () async {
    final repo = await openRepo();
    final store = LocalKeyValueStore();
    var controller = await VeriFinController.create(store, repository: repo);
    var controllerAlive = true;
    try {
      final account = investmentAccountFixture(
        id: 'backup-pending-fund',
        bookId: controller.activeBook.id,
      );
      const fund = StockSecurity(
        symbol: 'HK0001039582',
        name: '备份待确认基金示例',
        market: StockMarket.hk,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      );
      controller.addAccount(account);
      await controller.waitForPendingWrites();
      expect(
        await controller.enableInvestment(
          accountId: account.id,
          openingCash: '5000',
          openedAt: DateTime.utc(2026, 10, 1),
          securities: [fund],
          manualPrices: {fund.id: '109.8290'},
        ),
        isTrue,
      );
      final pending = FundSubscription(
        id: 'backup-paid-fund-subscription',
        securityId: fund.id,
        requestedAt: DateTime.utc(2026, 10, 25, 2),
        cashAmount: '1401.31',
        paidAt: DateTime.utc(2026, 10, 25, 2, 5),
        expectedConfirmationDate: DateTime.utc(2026, 10, 26),
        note: '固定备份夹具：预计日不表示券商已经确认份额',
      );
      // 仓储注入完整合法聚合，只用于独立验证持久化契约，不依赖申购页面或其命令签名。
      final source = controller
          .investmentFor(account.id)!
          .copyWith(fundSubscriptions: [pending]);
      await repo.saveInvestmentPortfolios([source]);
      controller.dispose();
      controllerAlive = false;
      controller = await VeriFinController.create(store, repository: repo);
      controllerAlive = true;
      var loaded = controller.investmentFor(account.id)!;
      expect(loaded.toJson(), source.toJson());
      expect(loaded.fundSubscriptions.single.toJson(), pending.toJson());
      expect(loaded.fundSubscriptions.single.confirmation, isNull);
      expect(loaded.events, isEmpty);
      expect(controller.investmentProjection(account.id)!.positions, isEmpty);
      expect(controller.entries, isEmpty);

      final raw = controller.exportDataJson();
      expect((jsonDecode(raw) as Map)['version'], 14);
      final beforePreview = loaded.toJson();
      controller.importDataJson(raw, dryRun: true);
      await controller.waitForPendingWrites();
      expect(controller.investmentFor(account.id)!.toJson(), beforePreview);
      expect(
        (await repo.loadInvestmentPortfolios()).single.toJson(),
        beforePreview,
      );

      controller.resetAllData();
      await controller.waitForPendingWrites();
      expect(await repo.loadInvestmentPortfolios(), isEmpty);
      controller.importDataJson(raw);
      await controller.waitForPendingWrites();
      loaded = controller.investmentFor(account.id)!;
      expect(loaded.toJson(), source.toJson());
      expect(loaded.fundSubscriptions.single.cashAmount, '1401.31');
      expect(
        loaded.fundSubscriptions.single.paidAt,
        DateTime.utc(2026, 10, 25, 2, 5),
      );
      expect(
        loaded.fundSubscriptions.single.expectedConfirmationDate,
        DateTime.utc(2026, 10, 26),
      );
      expect(loaded.fundSubscriptions.single.confirmation, isNull);
      expect(loaded.events, isEmpty);
      expect(controller.entries, isEmpty);

      controller.dispose();
      controllerAlive = false;
      controller = await VeriFinController.create(store, repository: repo);
      controllerAlive = true;
      expect(controller.investmentFor(account.id)!.toJson(), source.toJson());
      expect(controller.investmentProjection(account.id)!.positions, isEmpty);
      expect(controller.entries, isEmpty);
    } finally {
      // 创建新控制器失败时不再释放已经结束的旧实例，避免掩盖真正的初始化失败。
      if (controllerAlive) controller.dispose();
    }
  });

  for (final paymentMicros in [800, 900]) {
    final anchorMicros = paymentMicros == 800 ? 900 : 800;
    test(
      '基金付款/退款 $paymentMicros 微秒与锚点 $anchorMicros 微秒同毫秒，SQLite 冷启及恢复不重复计款',
      () async {
        final repo = await openRepo();
        final store = LocalKeyValueStore();
        var controller = await VeriFinController.create(
          store,
          repository: repo,
        );
        var controllerAlive = true;
        try {
          final account = investmentAccountFixture(
            id: 'fund-anchor-micros-$paymentMicros',
            bookId: controller.activeBook.id,
          );
          const fund = StockSecurity(
            symbol: 'HK0001039582',
            name: '毫秒现金核对隔离基金',
            market: StockMarket.hk,
            currencyCode: 'USD',
            type: InvestmentSecurityType.fund,
          );
          final relative = addCalendarDays(
            hongKongFundDate(DateTime.now()),
            -2,
          );
          final paidAt = DateTime.utc(
            relative.year,
            relative.month,
            relative.day,
            1,
            0,
            0,
            0,
            paymentMicros,
          );
          final paymentAnchorAt = DateTime.utc(
            relative.year,
            relative.month,
            relative.day,
            1,
            0,
            0,
            0,
            anchorMicros,
          );
          final refundedAt = DateTime.utc(
            relative.year,
            relative.month,
            relative.day,
            3,
            0,
            0,
            0,
            paymentMicros,
          );
          final refundAnchorAt = DateTime.utc(
            relative.year,
            relative.month,
            relative.day,
            3,
            0,
            0,
            0,
            anchorMicros,
          );
          final requestedAt = DateTime.utc(
            relative.year,
            relative.month,
            relative.day,
          );
          final cancelledAt = DateTime.utc(
            relative.year,
            relative.month,
            relative.day,
            2,
          );
          // 下一个毫秒的已知事实仍须在校准后正常重放，不能被“同毫秒全含”误吞。
          final nextPaymentAt = DateTime.fromMillisecondsSinceEpoch(
            paidAt.millisecondsSinceEpoch + 1,
            isUtc: true,
          );
          final nextRefundAt = DateTime.fromMillisecondsSinceEpoch(
            refundedAt.millisecondsSinceEpoch + 1,
            isUtc: true,
          );
          controller.addAccount(account);
          await controller.waitForPendingWrites();
          expect(
            await controller.enableInvestment(
              accountId: account.id,
              openingCash: '5000',
              openedAt: requestedAt.subtract(const Duration(hours: 1)),
            ),
            isTrue,
          );
          for (final order in [
            FundSubscription(
              id: 'same-ms',
              securityId: fund.id,
              requestedAt: requestedAt,
              paidAt: paidAt,
              cashAmount: '1000',
            ),
            FundSubscription(
              id: 'next-ms',
              securityId: fund.id,
              requestedAt: requestedAt,
              paidAt: nextPaymentAt,
              cashAmount: '200',
            ),
          ]) {
            expect(
              await controller.saveFundSubscription(
                accountId: account.id,
                security: fund,
                subscription: order,
              ),
              isTrue,
            );
          }
          expect(controller.accountBalance(account), 3800);
          expect(
            await controller.saveBalanceAnchor(
              account: account,
              effectiveAt: paymentAnchorAt,
              balance: 4000,
            ),
            isTrue,
          );
          expect(controller.accountBalance(account), 3800);
          final paymentAnchor = controller.latestBalanceAnchor(account.id)!;
          final includedPayments = controller
              .investmentFor(account.id)!
              .anchorIncludedIds[paymentAnchor.id]!;
          expect(includedPayments, contains('fund:same-ms:payment'));
          expect(includedPayments, isNot(contains('fund:next-ms:payment')));

          controller.dispose();
          controllerAlive = false;
          controller = await VeriFinController.create(store, repository: repo);
          controllerAlive = true;
          // 真实 SQLite 将锚点截为毫秒，但基金聚合 JSON 仍保留原付款微秒。
          expect(
            controller.latestBalanceAnchor(account.id)!.effectiveAt.microsecond,
            0,
          );
          expect(
            controller
                .investmentFor(account.id)!
                .fundSubscriptions
                .firstWhere((order) => order.id == 'same-ms')
                .paidAt,
            paidAt,
          );
          expect(controller.accountBalance(account), 3800);

          for (final refund in [
            ('same-ms', refundedAt, '900'),
            ('next-ms', nextRefundAt, '200'),
          ]) {
            expect(
              await controller.cancelFundSubscription(
                accountId: account.id,
                subscriptionId: refund.$1,
                cancelledAt: cancelledAt,
                refundedAt: refund.$2,
                refundAmount: refund.$3,
              ),
              isTrue,
            );
          }
          expect(controller.accountBalance(account), 4900);
          expect(
            await controller.saveBalanceAnchor(
              account: account,
              effectiveAt: refundAnchorAt,
              balance: 4700,
            ),
            isTrue,
          );
          expect(controller.accountBalance(account), 4900);
          final refundAnchor = controller.latestBalanceAnchor(account.id)!;
          final includedRefunds = controller
              .investmentFor(account.id)!
              .anchorIncludedIds[refundAnchor.id]!;
          expect(includedRefunds, contains('fund:same-ms:refund'));
          expect(includedRefunds, isNot(contains('fund:next-ms:refund')));

          controller.dispose();
          controllerAlive = false;
          controller = await VeriFinController.create(store, repository: repo);
          controllerAlive = true;
          expect(
            controller.latestBalanceAnchor(account.id)!.effectiveAt.microsecond,
            0,
          );
          expect(
            controller
                .investmentFor(account.id)!
                .fundSubscriptions
                .firstWhere((order) => order.id == 'same-ms')
                .refundedAt,
            refundedAt,
          );
          expect(controller.accountBalance(account), 4900);
          expect(controller.accountAssetValue(account), 4900);
          expect(controller.entries, isEmpty);

          final source = controller.investmentFor(account.id)!.toJson();
          final raw = controller.exportDataJson();
          expect((jsonDecode(raw) as Map)['version'], 14);
          controller.resetAllData();
          await controller.waitForPendingWrites();
          expect(await repo.loadInvestmentPortfolios(), isEmpty);
          controller.importDataJson(raw);
          await controller.waitForPendingWrites();
          expect(controller.investmentFor(account.id)!.toJson(), source);
          expect(controller.accountBalance(account), 4900);
          controller.dispose();
          controllerAlive = false;
          controller = await VeriFinController.create(store, repository: repo);
          controllerAlive = true;
          expect(controller.investmentFor(account.id)!.toJson(), source);
          expect(controller.accountBalance(account), 4900);
          expect(controller.accountAssetValue(account), 4900);
          expect(await repo.loadEntries(), isEmpty);
        } finally {
          // 冷启动若失败，不再次释放已经结束的实例，避免掩盖实际数据库恢复异常。
          if (controllerAlive) controller.dispose();
        }
      },
    );
  }

  test('SQLite 跨账本复核事务失败不移动事件，重试与重启保持目标账本', () async {
    final repo = await openRepo();
    final store = LocalKeyValueStore();
    var controller = await VeriFinController.create(store, repository: repo);
    final sourceBookId = controller.activeBook.id;
    controller.addLedgerBook('复核目标');
    final targetBookId = controller.activeBook.id;
    await controller.waitForPendingWrites();
    final event = captureEventFromInput(
      id: 'sqlite-cross-book',
      bookId: sourceBookId,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'test-bank',
        sourceEventId: 'sqlite-cross-book',
        rawText: '消费10.00元',
        receivedAt: DateTime(2026, 10, 2),
      ),
    ).copyWith(status: CaptureStatus.pendingReview);
    await repo.saveCaptureEvents([event]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    final draft = entry(
      '1',
    ).copyWith(bookId: targetBookId, accountId: '', clearAccountAmount: true);
    final db = opened.last.db;
    await db.execute(
      "CREATE TRIGGER reject_cross_book BEFORE INSERT ON capture_events BEGIN SELECT RAISE(ABORT, '模拟跨账本保存失败'); END",
    );
    expect(
      await controller.saveEntryAggregateDraftResult(
        entry: draft,
        isNew: true,
        captureEventId: event.id,
        captureEventBookId: sourceBookId,
      ),
      isA<EntrySavePersistenceFailure>(),
    );
    expect(await repo.loadEntries(), isEmpty);
    expect((await repo.loadCaptureEvents()).single.bookId, sourceBookId);
    await db.execute('DROP TRIGGER reject_cross_book');
    expect(
      (await controller.saveEntryAggregateDraftResult(
        entry: draft,
        isNew: true,
        captureEventId: event.id,
        captureEventBookId: sourceBookId,
      )).isSuccess,
      isTrue,
    );
    controller.dispose();
    controller = await VeriFinController.create(
      store,
      repository: SqliteLedgerRepository(opened.last),
    );
    expect(controller.entries.single.bookId, targetBookId);
    expect(controller.captureEvents.single.bookId, targetBookId);
    expect(controller.captureEvents.single.linkedEntryId, draft.id);
    expect(
      controller.entries.single.sourceRecords.single.fingerprint,
      event.fingerprint,
    );
    expect(await controller.replayRecentCaptureEvents(), 0);
    controller.dispose();
  });

  test('挂载仓储后新增的交易写入 SQLite 并可被新控制器读回', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    controller.addEntry(entry('1', amount: 25));
    await controller.waitForPendingWrites();

    expect((await repo.loadEntries()).single.amount, 25);

    // 共享同一数据库的新控制器应从库中恢复交易。
    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    expect(reloaded.entries.single.id, '1');
  });

  for (final withPaymentAccount in [false, true]) {
    test('还款带扣款账户=$withPaymentAccount：SQLite 失败全部回滚，重试及冷启动保持结清', () async {
      final repo = await openRepo();
      final store = LocalKeyValueStore();
      final controller = await VeriFinController.create(
        store,
        repository: repo,
      );
      addTearDown(controller.dispose);
      final card = Account(
        id: 'repayment-card',
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
      controller.addAccount(card);
      final bank = Account(
        id: 'repayment-bank',
        bookId: controller.activeBook.id,
        name: '扣款储蓄卡',
        type: AccountType.debitCard,
        groupId: null,
        initialBalance: 10000,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
      );
      controller.addAccount(bank);
      await controller.waitForPendingWrites();
      final now = DateTime.now();
      expect(
        await controller.createBillingStatement(
          account: card,
          statementDate: DateTime(now.year, now.month - 1, 25),
          periodStart: DateTime(now.year, now.month - 2, 26),
          periodEnd: DateTime(now.year, now.month - 1, 25, 23, 59, 59),
          statementAmount: 5219.15,
          minimumPayment: 0,
          dueDate: now,
          paidAmount: 0,
        ),
        isTrue,
      );
      final db = opened.last.db;
      // 分配表是事务中最后写入的表；让它失败可检查此前交易与账单也已回滚。
      await db.execute(
        "CREATE TRIGGER reject_repayment BEFORE INSERT ON statement_repayment_allocations BEGIN SELECT RAISE(ABORT, '模拟还款分配失败'); END",
      );
      final failed = await controller.recordCreditRepayment(
        repaymentEntryId: 'repayment-once',
        fromAccountId: withPaymentAccount ? bank.id : '',
        accountId: card.id,
        amount: 5219.15,
        occurredAt: now,
      );
      expect(failed, isA<EntrySavePersistenceFailure>());
      expect(controller.entries, isEmpty);
      expect(controller.billingStatements.single.paidAmount, 0);
      expect(controller.statementRepaymentAllocations, isEmpty);
      expect(controller.accountBalance(card), -10438.30);
      expect(controller.accountBalance(bank), 10000);
      expect(await repo.loadEntries(), isEmpty);
      expect((await repo.loadBillingStatements()).single.paidAmount, 0);
      expect(await repo.loadStatementRepaymentAllocations(), isEmpty);

      await db.execute('DROP TRIGGER reject_repayment');
      final saved = await controller.recordCreditRepayment(
        repaymentEntryId: 'repayment-once',
        fromAccountId: withPaymentAccount ? bank.id : '',
        accountId: card.id,
        amount: 5219.15,
        occurredAt: now,
        note: ' 实际还款 ',
      );
      expect(saved.isSuccess, isTrue);
      expect(controller.entries.single.note, '实际还款');
      expect(
        controller.entries.single.accountId,
        withPaymentAccount ? bank.id : '',
      );
      expect(
        controller.accountBalance(bank),
        withPaymentAccount ? 4780.85 : 10000,
      );
      expect(
        controller.billingStatements.single.status,
        BillingStatementStatus.paid,
      );
      expect(controller.creditOverview(card).billedOutstanding, 0);
      expect(controller.accountBalance(card), closeTo(-5219.15, 0.001));

      // 同一草稿再次提交必须拒绝，避免重复抵扣账单与信用账户余额。
      final duplicate = await controller.recordCreditRepayment(
        repaymentEntryId: 'repayment-once',
        accountId: card.id,
        amount: 5219.15,
        occurredAt: now,
      );
      expect(duplicate, isA<EntrySaveValidationFailure>());
      expect(controller.entries, hasLength(1));
      final reloaded = await VeriFinController.create(store, repository: repo);
      addTearDown(reloaded.dispose);
      final reloadedCard = reloaded.accounts.firstWhere(
        (item) => item.id == card.id,
      );
      expect(reloaded.creditOverview(reloadedCard).billedOutstanding, 0);
      expect(
        reloaded.billingStatements.single.status,
        BillingStatementStatus.paid,
      );
      expect(reloaded.statementRepaymentAllocations, hasLength(1));
      expect(reloaded.entries.single.auditHistory, hasLength(1));
      expect(reloaded.accountBalance(reloadedCard), closeTo(-5219.15, 0.001));
      expect(
        reloaded.accountBalance(bank),
        withPaymentAccount ? 4780.85 : 10000,
      );
    });
  }

  test('SQLite 复核状态写失败会回滚交易附件，重试后冷启动仍已确认', () async {
    final repo = await openRepo();
    final store = LocalKeyValueStore();
    var controller = await VeriFinController.create(store, repository: repo);
    final event = captureEventFromInput(
      id: 'sqlite-review',
      bookId: controller.activeBook.id,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'cmb-life',
        sourceEventId: 'sqlite-review',
        rawText: '消费10.00元',
        receivedAt: DateTime(2026, 10, 2),
      ),
    ).copyWith(status: CaptureStatus.pendingReview);
    final reviewedEntry = entry('1').copyWith(
      bookId: controller.activeBook.id,
      accountId: '',
      clearAccountAmount: true,
      categoryId: controller.categories
          .firstWhere((category) => category.type == EntryType.expense)
          .id,
    );
    await repo.saveCaptureEvents([event]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    final db = opened.last.db;
    await db.execute(
      "CREATE TRIGGER reject_review BEFORE INSERT ON capture_events BEGIN SELECT RAISE(ABORT, 'injected review failure'); END",
    );
    const attachment = Attachment(
      id: 'review-photo',
      entryId: '1',
      dataUrl: 'data:image/jpeg;base64,TkVX',
    );
    final failed = await controller.saveEntryAggregateDraftResult(
      entry: reviewedEntry,
      isNew: true,
      captureEventId: event.id,
      attachments: [attachment],
    );
    expect(failed, isA<EntrySavePersistenceFailure>());
    expect(controller.entries, isEmpty);
    expect(await repo.loadEntries(), isEmpty);
    expect(await repo.loadAttachments(), isEmpty);
    expect(
      (await repo.loadCaptureEvents()).single.status,
      CaptureStatus.pendingReview,
    );
    await db.execute('DROP TRIGGER reject_review');
    expect(
      (await controller.saveEntryAggregateDraftResult(
        entry: reviewedEntry,
        isNew: true,
        captureEventId: event.id,
        attachments: [attachment],
      )).isSuccess,
      isTrue,
    );
    controller.dispose();
    final reloaded = await VeriFinController.create(
      store,
      repository: SqliteLedgerRepository(opened.last),
    );
    expect(reloaded.entries.single.id, reviewedEntry.id);
    expect(reloaded.captureEvents.single.status, CaptureStatus.confirmed);
    expect(reloaded.captureEvents.single.linkedEntryId, reviewedEntry.id);
    expect(
      reloaded.entries.single.sourceRecords.single.fingerprint,
      event.fingerprint,
    );
    expect(reloaded.attachmentsForEntry(reviewedEntry.id), hasLength(1));
    expect(await reloaded.replayRecentCaptureEvents(), 0);
    reloaded.dispose();
  });

  test('退款关联条目（refund_of/settled_at）写入 SQLite 并被新控制器读回', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final bookId = controller.activeBook.id;
    controller
      ..addAccount(
        Account(
          id: 'cash',
          bookId: bookId,
          name: '现金',
          type: AccountType.cash,
          groupId: null,
          initialBalance: 1000,
          iconCode: 'cash',
          note: '',
          includeInAssets: true,
          hidden: false,
        ),
      )
      ..addEntry(
        entry('4', amount: 100).copyWith(bookId: bookId, accountId: 'cash'),
      );
    // 一笔已到账、一笔待到账。
    controller.addRefund(
      expenseId: '4',
      amount: 30,
      accountId: 'cash',
      initiatedAt: DateTime(2026, 5, 4),
      settledAt: DateTime(2026, 5, 6),
    );
    controller.addRefund(
      expenseId: '4',
      amount: 20,
      accountId: 'cash',
      initiatedAt: DateTime(2026, 5, 10),
    );
    await controller.waitForPendingWrites();

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final refunds = reloaded.refundsForEntry('4');
    expect(refunds.length, 2);
    // settled_at 忠实往返：一笔有到账日、一笔为待到账（null）。
    expect(refunds.where((r) => r.settledAt != null).single.amount, 30);
    expect(refunds.where((r) => r.isPendingRefund).single.amount, 20);
    // 只有已到账的 30 冲减净额、进余额；待到账的 20 不动。
    final expense = reloaded.entries.firstWhere((e) => e.id == '4');
    expect(expense.netAmount, 70);
    final cash = reloaded.accounts.firstWhere((a) => a.id == 'cash');
    expect(reloaded.accountBalance(cash), 930); // 1000 − 100 + 30
  });

  test('删除账户与相关交易会原子清理跨账户退款、附件并停用周期规则', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final bookId = controller.activeBook.id;
    final cash = Account(
      id: 'delete-cash',
      bookId: bookId,
      name: '现金',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 100,
      iconCode: 'cash',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final card = cash.copyWith(id: 'keep-card', name: '银行卡');
    controller
      ..addAccount(cash)
      ..addAccount(card)
      ..addEntry(
        LedgerEntry(
          id: 'delete-expense',
          bookId: bookId,
          type: EntryType.expense,
          amount: 20,
          categoryId: 'dining',
          accountId: cash.id,
          note: '',
          occurredAt: DateTime(2026, 8, 20),
        ),
      )
      ..addRecurringRule(
        RecurringRule(
          id: 'delete-account-rule',
          bookId: bookId,
          type: EntryType.expense,
          amount: 5,
          categoryId: 'dining',
          accountId: cash.id,
          note: '',
          frequency: RecurringFrequency.monthly,
          startDate: DateTime(2026, 8, 1),
          nextRunDate: DateTime(2026, 9, 1),
        ),
      );
    final refund = controller.addRefund(
      expenseId: 'delete-expense',
      amount: 4,
      accountId: card.id,
      initiatedAt: DateTime(2026, 8, 21),
      settledAt: DateTime(2026, 8, 22),
    );
    controller
      ..addAttachment('delete-expense', 'data:image/jpeg;base64,RVhQRU5TRQ==')
      ..addAttachment(refund!.id, 'data:image/jpeg;base64,UkVGVU5E');
    await controller.waitForPendingWrites();

    expect(await controller.deleteAccountAndRelatedEntries(cash.id), 1);

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    expect(reloaded.accounts.map((account) => account.id), <String>[card.id]);
    expect(reloaded.entries, isEmpty);
    expect(await repo.loadAttachments(), isEmpty);
    final rule = reloaded.recurringRules.single;
    expect(rule.active, isFalse);
    expect(rule.accountId, isEmpty);
  });

  test('交易聚合保存会重算退款缓存，并原子持久化交易、退款和附件', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final original = entry('5', amount: 100);
    controller.addEntry(original);
    await controller.waitForPendingWrites();

    final refund = LedgerEntry(
      id: 'refund-5',
      bookId: original.bookId,
      type: EntryType.refund,
      amount: 40,
      categoryId: original.categoryId,
      accountId: original.accountId,
      note: '',
      occurredAt: DateTime(2026, 5, 6),
      refundOf: original.id,
      settledAt: DateTime(2026, 5, 7),
    );
    const attachment = Attachment(
      id: 'attachment-5',
      entryId: '5',
      dataUrl: 'data:image/jpeg;base64,QUJD',
    );

    final saved = await controller.saveEntryAggregateDraft(
      // 模拟 Issue #31：交易编辑器仍持有 refundedAmount=0 的旧快照。
      entry: original.copyWith(note: '修改后的备注', refundedAmount: 0),
      isNew: false,
      refunds: <LedgerEntry>[refund],
      attachments: const <Attachment>[attachment],
    );
    expect(saved, isTrue);

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final persisted = reloaded.entries.firstWhere((item) => item.id == '5');
    expect(persisted.note, '修改后的备注');
    expect(persisted.refundedAmount, 40);
    expect(persisted.netAmount, 60);
    expect(reloaded.refundsForEntry('5').single.id, 'refund-5');
    expect(reloaded.attachmentsForEntry('5').single.id, 'attachment-5');
  });

  test('账本/账户/分组写入 SQLite 并被新控制器读回', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    // 全新数据库首启动已播种默认账本（默认账户为空，用户新增后才有）。
    expect(await repo.loadBooks(), isNotEmpty);

    controller.addLedgerBook('旅行账本');
    await controller.addAccountGroup('出行');
    await controller.waitForPendingWrites();

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    expect(reloaded.ledgerBooks.any((b) => b.name == '旅行账本'), isTrue);
    // addLedgerBook 会切换活动账本，分组落在新账本下。
    reloaded.switchLedgerBook(
      reloaded.ledgerBooks.firstWhere((b) => b.name == '旅行账本').id,
    );
    expect(reloaded.accountGroups.any((g) => g.name == '出行'), isTrue);
  });

  test('新增账户后新控制器能读回', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    controller.addAccount(
      const Account(
        id: 'my-cash',
        bookId: defaultLedgerBookId,
        name: '钱包',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 66,
        iconCode: 'wallet',
        note: '',
        includeInAssets: true,
        hidden: false,
        cardLast4: '',
      ),
    );
    // 信用卡：完整卡号 + 额度 + 关掉跟随（手填后四位）——验证经 SQLite 往返保留。
    controller.addAccount(
      const Account(
        id: 'my-credit',
        bookId: defaultLedgerBookId,
        name: '信用卡',
        type: AccountType.creditCard,
        groupId: null,
        initialBalance: -200,
        iconCode: 'credit',
        note: '',
        includeInAssets: true,
        hidden: false,
        cardLast4: '9999',
        cardNumber: '6222000000001234',
        cardLast4Follows: false,
        creditLimit: 5000,
      ),
    );
    await controller.waitForPendingWrites();

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final restored = reloaded.accounts.firstWhere((a) => a.id == 'my-cash');
    expect(restored.name, '钱包');
    expect(restored.initialBalance, 66);
    final credit = reloaded.accounts.firstWhere((a) => a.id == 'my-credit');
    expect(credit.cardNumber, '6222000000001234');
    expect(credit.cardLast4, '9999');
    expect(credit.cardLast4Follows, isFalse);
    expect(credit.creditLimit, 5000);
  });

  test('分类与预算写入 SQLite 并被新控制器读回', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    final month = DateTime(2026, 6);
    controller.addCategory(
      type: EntryType.expense,
      label: '宠物',
      iconCode: 'pets',
    );
    controller.setMonthlyBudget(month, 2000);
    final petCategory = controller
        .categoriesForType(EntryType.expense)
        .firstWhere((c) => c.label == '宠物');
    controller.setCategoryBudget(month, petCategory.id, 500);
    await controller.waitForPendingWrites();

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    expect(
      reloaded.categoriesForType(EntryType.expense).any((c) => c.label == '宠物'),
      isTrue,
    );
    expect(reloaded.monthlyBudget(month), 2000);
    expect(reloaded.categoryBudget(month, petCategory.id), 500);
  });

  test('导入备份写入 SQLite 并被新控制器读回', () async {
    final rawJson = File(
      'docs/dev/verifin-sample-backup.json',
    ).readAsStringSync();
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(controller.dispose);
    controller.importDataJson(rawJson);
    await controller.waitForPendingWrites();

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(reloaded.dispose);
    expect(reloaded.accounts.length, greaterThanOrEqualTo(8));
    expect(reloaded.entries.length, greaterThanOrEqualTo(20));
    expect(reloaded.categories.any((c) => c.id == 'coffee'), isTrue);
    // 导出应能从 SQLite 恢复出的内存状态重建等价备份。
    final reExported = jsonDecode(reloaded.exportDataJson()) as Map;
    expect((reExported['data'] as Map)['entries'], isNotEmpty);
    // 冷启动后共用三地组合检查，覆盖父子关联、各币种现金、腾讯期权与独立汇率。
    expect(reloaded.activeBook.id, defaultLedgerBookId);
    expectSampleInvestmentPortfolio(reloaded);
    expect(reloaded.activeBook.id, defaultLedgerBookId);
  });

  test('重置数据会清空 SQLite', () async {
    final repo = await openRepo();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    controller.addEntry(entry('4'));
    await controller.waitForPendingWrites();
    expect(await repo.loadEntries(), isNotEmpty);

    controller.resetAllData();
    await controller.waitForPendingWrites();
    expect(await repo.loadEntries(), isEmpty);

    final reloaded = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    expect(reloaded.entries, isEmpty);
  });
}
