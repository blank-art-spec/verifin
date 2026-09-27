import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  test('未知资金账户时保留待确认，不回退到第一账户', () async {
    final controller = await makeController();
    final receivedAt = DateTime(2026, 9, 27, 12, 30);
    final event = captureEventFromInput(
      id: 'capture-unknown-account',
      bookId: controller.activeBook.id,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.eg.android.AlipayGphone',
        sourceEventId: 'notice-1',
        rawText: '支付宝付款59.49元，商户麦当劳',
        receivedAt: receivedAt,
      ),
    );

    final parsed = parseCaptureEvent(
      event,
      CaptureParseContext(
        book: controller.activeBook,
        accounts: controller.accounts,
        creditAccounts: controller.creditAccounts,
        categories: controller.categories,
        tags: controller.tags,
        entries: controller.entries,
        rules: const <AutoCaptureRule>[],
      ),
      processedAt: receivedAt,
    );

    expect(parsed.parsedAmount, 59.49);
    expect(parsed.kind, CaptureTransactionKind.expense);
    expect(parsed.accountCandidateId, isNull);
    expect(parsed.confidence, isNot(CaptureConfidence.high));
  });

  test('本地规则可把完整通知高置信度入账，多来源事件合并为同一交易', () async {
    final controller = await makeController();
    expect(
      await controller.addAccountDraft(
        Account(
          id: 'account-cash',
          bookId: controller.activeBook.id,
          name: '测试现金',
          type: AccountType.cash,
          groupId: null,
          initialBalance: 0,
          iconCode: 'asset:payment_001',
          note: '',
          includeInAssets: true,
          hidden: false,
        ),
      ),
      isTrue,
    );
    final account = controller.accounts.first;
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final initialEntryCount = controller.entries.length;
    final rule = AutoCaptureRule(
      id: 'rule-mcdonalds',
      bookId: controller.activeBook.id,
      name: '麦当劳规则',
      priority: 100,
      textContains: '麦当劳',
      setKind: CaptureTransactionKind.expense,
      setAccountId: account.id,
      setCategoryId: category.id,
      setMerchant: '麦当劳',
    );
    expect(await controller.saveAutoCaptureRule(rule), isTrue);

    final receivedAt = DateTime(2026, 9, 27, 8, 15);
    final firstAdded = await controller.ingestCaptureInputs(<RawCaptureInput>[
      RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.bank',
        sourceEventId: 'bank-1001',
        rawText: '消费59.49元，商户麦当劳',
        receivedAt: receivedAt,
      ),
    ]);

    expect(firstAdded, 1);
    expect(controller.entries, hasLength(initialEntryCount + 1));
    final created = controller.entries.firstWhere(
      (entry) => entry.sourceRecords.any(
        (source) => source.sourceTransactionId == 'bank-1001',
      ),
    );
    expect(created.accountId, account.id);
    expect(created.categoryId, category.id);
    expect(created.type, EntryType.expense);
    expect(controller.captureEvents.single.status, CaptureStatus.autoPosted);

    final secondAdded = await controller.ingestCaptureInputs(<RawCaptureInput>[
      RawCaptureInput(
        sourceKind: CaptureSourceKind.sms,
        sourceId: '95555',
        sourceEventId: 'sms-1001',
        rawText: '消费59.49元，商户麦当劳',
        receivedAt: receivedAt.add(const Duration(minutes: 1)),
      ),
    ]);

    expect(secondAdded, 1);
    expect(controller.entries, hasLength(initialEntryCount + 1));
    final merged = controller.captureEvents.firstWhere(
      (event) => event.sourceEventId == 'sms-1001',
    );
    expect(merged.status, CaptureStatus.merged);
    expect(merged.linkedEntryId, created.id);
    expect(
      controller.entries
          .singleWhere((entry) => entry.id == created.id)
          .sourceRecords,
      hasLength(2),
    );
  });

  test('同一原生事件重复回调只保存一次', () async {
    final controller = await makeController();
    final input = RawCaptureInput(
      nativeQueueId: 'native-queue-same-event',
      sourceKind: CaptureSourceKind.notification,
      sourceId: 'com.example.bank',
      sourceEventId: 'same-event',
      rawText: '验证码1234，请勿泄露',
      receivedAt: DateTime(2026, 9, 27, 18),
    );

    expect(await controller.ingestCaptureInputs(<RawCaptureInput>[input]), 1);
    expect(await controller.ingestCaptureInputs(<RawCaptureInput>[input]), 0);
    expect(controller.captureEvents, hasLength(1));
    expect(controller.captureEvents.single.status, CaptureStatus.raw);
    expect(controller.captureEvents.single.processedAt, isNotNull);
    expect(controller.entries, isEmpty);
    expect(controller.captureInputIsStored(input), isTrue);
  });

  test('同一分钟同文但系统事件号不同时保留两条原始事件', () async {
    final controller = await makeController();
    final receivedAt = DateTime(2026, 9, 27, 18);
    final inputs = <RawCaptureInput>[
      RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.bank',
        sourceEventId: 'bank-event-first',
        rawText: '验证码1234，请勿泄露',
        receivedAt: receivedAt,
      ),
      RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.bank',
        sourceEventId: 'bank-event-second',
        rawText: '验证码1234，请勿泄露',
        receivedAt: receivedAt.add(const Duration(seconds: 10)),
      ),
    ];

    expect(await controller.ingestCaptureInputs(inputs), 2);
    expect(controller.captureEvents, hasLength(2));
    expect(
      controller.captureEvents.map((event) => event.fingerprint).toSet(),
      hasLength(2),
    );
  });

  test('信用卡还款解析结果不是收入', () async {
    final controller = await makeController();
    final receivedAt = DateTime(2026, 9, 27, 20);
    final raw = captureEventFromInput(
      id: 'capture-repayment',
      bookId: controller.activeBook.id,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.sms,
        sourceId: '95555',
        sourceEventId: 'repayment-1',
        rawText: '信用卡还款1000元已到账',
        receivedAt: receivedAt,
      ),
    );
    final parsed = parseCaptureEvent(
      raw,
      CaptureParseContext(
        book: controller.activeBook,
        accounts: controller.accounts,
        creditAccounts: controller.creditAccounts,
        categories: controller.categories,
        tags: controller.tags,
        entries: controller.entries,
        rules: const <AutoCaptureRule>[],
      ),
      processedAt: receivedAt,
    );

    expect(parsed.kind, CaptureTransactionKind.creditRepayment);
    expect(parsed.kind.entryType, EntryType.transfer);
  });

  test('金额解析优先交易金额而不是通知里的余额', () async {
    final controller = await makeController();
    final receivedAt = DateTime(2026, 9, 27, 20);
    const account = Account(
      id: 'card-4185',
      bookId: 'default',
      name: '招商储蓄卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
      cardLast4: '4185',
    );
    final event = captureEventFromInput(
      id: 'capture-balance-text',
      bookId: controller.activeBook.id,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.bank',
        sourceEventId: 'notice-balance',
        rawText: '尾号4185消费59.49元，账户余额1000.00元，商户麦当劳',
        receivedAt: receivedAt,
      ),
    );
    final parsed = parseCaptureEvent(
      event,
      CaptureParseContext(
        book: controller.activeBook,
        accounts: const <Account>[account],
        creditAccounts: const <CreditAccount>[],
        categories: controller.categories,
        tags: const <Tag>[],
        entries: const <LedgerEntry>[],
        rules: const <AutoCaptureRule>[],
      ),
      processedAt: receivedAt,
    );

    expect(parsed.parsedAmount, 59.49);
    expect(parsed.accountCandidateId, account.id);
  });

  test('退款只与既有退款去重，唯一同额原支出可提升到高置信度', () async {
    final controller = await makeController();
    final receivedAt = DateTime(2026, 9, 27, 20);
    const account = Account(
      id: 'card-4185',
      bookId: 'default',
      name: '招商储蓄卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
      cardLast4: '4185',
    );
    final expense = LedgerEntry(
      id: 'expense-original',
      bookId: controller.activeBook.id,
      type: EntryType.expense,
      amount: 59.49,
      categoryId: 'dining',
      accountId: account.id,
      note: '麦当劳',
      occurredAt: receivedAt.subtract(const Duration(days: 1)),
    );
    final event = captureEventFromInput(
      id: 'capture-refund',
      bookId: controller.activeBook.id,
      input: RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'com.example.bank',
        sourceEventId: 'notice-refund',
        rawText: '尾号4185退款59.49元，商户麦当劳',
        receivedAt: receivedAt,
      ),
    );
    final parsed = parseCaptureEvent(
      event,
      CaptureParseContext(
        book: controller.activeBook,
        accounts: const <Account>[account],
        creditAccounts: const <CreditAccount>[],
        categories: controller.categories,
        tags: const <Tag>[],
        entries: <LedgerEntry>[expense],
        rules: const <AutoCaptureRule>[],
      ),
      processedAt: receivedAt,
    );

    expect(parsed.kind, CaptureTransactionKind.refund);
    expect(parsed.categoryCandidateId, expense.categoryId);
    expect(parsed.confidence, CaptureConfidence.high);
    expect(findCaptureDuplicate(parsed, <LedgerEntry>[expense]), isNull);
  });

  test('用户确认唯一原支出的退款后创建关联退款并重算净额', () async {
    final controller = await makeController();
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        controller.autoCaptureSettings.copyWith(autoPostHighConfidence: false),
      ),
      isTrue,
    );
    const account = Account(
      id: 'refund-card-4185',
      bookId: 'default',
      name: '招商储蓄卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
      cardLast4: '4185',
    );
    expect(await controller.addAccountDraft(account), isTrue);
    final expenseCategory = controller.categories.firstWhere(
      (category) => category.type == EntryType.expense,
    );
    final receivedAt = DateTime(2026, 9, 27, 20);
    controller.addEntry(
      LedgerEntry(
        id: 'refund-original-expense',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 59.49,
        categoryId: expenseCategory.id,
        accountId: account.id,
        note: '麦当劳',
        occurredAt: receivedAt.subtract(const Duration(days: 1)),
      ),
    );

    expect(
      await controller.ingestCaptureInputs(<RawCaptureInput>[
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'com.example.bank',
          sourceEventId: 'notice-refund-confirm',
          rawText: '尾号4185退款59.49元，商户麦当劳',
          receivedAt: receivedAt,
        ),
      ]),
      1,
    );
    final event = controller.captureEvents.single;
    expect(event.status, CaptureStatus.pendingReview);
    expect(event.confidence, CaptureConfidence.high);

    final refund = await controller.confirmParsedCaptureEvent(event.id);

    expect(refund, isNotNull);
    expect(refund!.type, EntryType.refund);
    expect(refund.refundOf, 'refund-original-expense');
    expect(refund.settledAt, receivedAt);
    expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
    expect(
      controller.entries
          .singleWhere((entry) => entry.id == 'refund-original-expense')
          .refundedBaseAmount,
      59.49,
    );
  });

  test('删除账户会清理规则动作并停用失去全部动作的规则', () async {
    final controller = await makeController();
    const account = Account(
      id: 'account-to-delete',
      bookId: 'default',
      name: '待删除账户',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    expect(await controller.addAccountDraft(account), isTrue);
    expect(
      await controller.saveAutoCaptureRule(
        const AutoCaptureRule(
          id: 'rule-account-reference',
          bookId: 'default',
          name: '账户引用清理',
          priority: 1,
          textContains: '测试',
          setAccountId: 'account-to-delete',
        ),
      ),
      isTrue,
    );

    expect(await controller.deleteAccount(account.id), 0);
    final cleaned = controller.autoCaptureRules.single;
    expect(cleaned.setAccountId, isNull);
    expect(cleaned.enabled, isFalse);
  });

  test('重置全部数据会立即通知原生层关闭自动采集', () async {
    final controller = await makeController();
    final changes = <AutoCaptureSettings>[];
    controller.onAutoCaptureSettingsChanged = changes.add;
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        const AutoCaptureSettings(notificationEnabled: true, smsEnabled: true),
      ),
      isTrue,
    );

    controller.resetAllData();

    expect(changes, hasLength(2));
    expect(changes.first.notificationEnabled, isTrue);
    expect(changes.last.notificationEnabled, isFalse);
    expect(changes.last.smsEnabled, isFalse);
  });
}
