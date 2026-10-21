import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/ai/ai_entry_parser.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  test('批量回放的条数上限只处理本次选中的事件', () async {
    final store = LocalKeyValueStore();
    final repository = InMemoryLedgerRepository();
    final initial = await VeriFinController.create(
      store,
      repository: repository,
    );
    final bookId = initial.activeBook.id;
    initial.dispose();
    final events = <CaptureEvent>[
      for (var index = 0; index < 2; index++)
        captureEventFromInput(
          id: 'replay-limit-$index',
          bookId: bookId,
          input: RawCaptureInput(
            sourceKind: CaptureSourceKind.notification,
            sourceId: 'com.example.bank',
            sourceEventId: 'replay-limit-$index',
            rawText: '消费${index + 1}.00元，商户未知',
            receivedAt: DateTime(2026, 9, 27, 12, index),
          ),
        ),
    ];
    await repository.saveCaptureEvents(events);
    final controller = await VeriFinController.create(
      store,
      repository: repository,
    );

    expect(await controller.replayRecentCaptureEvents(limit: 1), 1);
    final unchanged = controller.captureEvents.where(
      (event) => event.status == CaptureStatus.raw && event.processedAt == null,
    );
    expect(unchanged, hasLength(1));
  });

  test('单条重新解析只刷新指定候选，不顺带自动入账或重启已忽略事件', () async {
    final store = LocalKeyValueStore();
    final repository = InMemoryLedgerRepository();
    final initial = await VeriFinController.create(
      store,
      repository: repository,
    );
    final account = Account(
      id: 'retry-account',
      bookId: initial.activeBook.id,
      name: '重试账户',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    expect(await initial.addAccountDraft(account), isTrue);
    final category = initial.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    expect(
      await initial.saveAutoCaptureRule(
        AutoCaptureRule(
          id: 'retry-rule',
          bookId: initial.activeBook.id,
          name: '单条重试规则',
          priority: 100,
          textContains: '重试商户',
          setKind: CaptureTransactionKind.expense,
          setAccountId: account.id,
          setCategoryId: category.id,
        ),
      ),
      isTrue,
    );
    expect(
      await initial.saveAutoCaptureSettingsDraft(
        initial.autoCaptureSettings.copyWith(autoPostHighConfidence: true),
      ),
      isTrue,
    );
    final bookId = initial.activeBook.id;
    initial.dispose();
    final rawEvents = <CaptureEvent>[
      for (var index = 0; index < 3; index++)
        captureEventFromInput(
          id: 'retry-$index',
          bookId: bookId,
          input: RawCaptureInput(
            sourceKind: CaptureSourceKind.notification,
            sourceId: 'com.example.bank',
            sourceEventId: 'retry-$index',
            rawText: '消费${index + 1}.00元，商户重试商户',
            receivedAt: DateTime(2026, 10, 2, 12, index),
          ),
        ),
    ];
    await repository.saveCaptureEvents(<CaptureEvent>[
      rawEvents[0],
      rawEvents[1],
      rawEvents[2].copyWith(status: CaptureStatus.ignored),
    ]);
    final controller = await VeriFinController.create(
      store,
      repository: repository,
    );
    final originalEntryCount = controller.entries.length;

    expect(await controller.retryCaptureEvent(rawEvents[0].id), isTrue);
    expect(controller.entries, hasLength(originalEntryCount));
    expect(
      controller.captureEvents
          .firstWhere((event) => event.id == rawEvents[0].id)
          .parsedAmount,
      1.00,
    );
    final untouched = controller.captureEvents.firstWhere(
      (event) => event.id == rawEvents[1].id,
    );
    expect(untouched.parsedAmount, isNull);
    expect(untouched.status, CaptureStatus.raw);
    expect(await controller.retryCaptureEvent(rawEvents[2].id), isFalse);
    expect(
      controller.captureEvents
          .firstWhere((event) => event.id == rawEvents[2].id)
          .status,
      CaptureStatus.ignored,
    );
  });

  test('批量回放只更新未落账事件的候选，不触发自动入账或撤销忽略', () async {
    final controller = await makeController();
    final account = Account(
      id: 'replay-account',
      bookId: controller.activeBook.id,
      name: '回放账户',
      type: AccountType.cash,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    expect(await controller.addAccountDraft(account), isTrue);
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    expect(
      await controller.saveAutoCaptureRule(
        AutoCaptureRule(
          id: 'replay-rule',
          bookId: controller.activeBook.id,
          name: '回放规则',
          priority: 100,
          textContains: '回放商户',
          setKind: CaptureTransactionKind.expense,
          setAccountId: account.id,
          setCategoryId: category.id,
        ),
      ),
      isTrue,
    );
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        controller.autoCaptureSettings.copyWith(autoPostHighConfidence: false),
      ),
      isTrue,
    );
    final originalEntryCount = controller.entries.length;
    expect(
      await controller.ingestCaptureInputs(<RawCaptureInput>[
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'com.example.bank',
          sourceEventId: 'replay-1',
          rawText: '消费12.00元，商户回放商户',
          receivedAt: DateTime(2026, 9, 27, 12),
        ),
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'com.example.bank',
          sourceEventId: 'replay-2',
          rawText: '消费13.00元，商户回放商户',
          receivedAt: DateTime(2026, 9, 27, 13),
        ),
      ]),
      2,
    );
    final health = controller.autoCaptureStats(now: DateTime(2026, 9, 27, 23));
    expect(health.todayCaptured, 2);
    expect(health.lastCapturedAt, DateTime(2026, 9, 27, 13));
    final ignored = controller.captureEvents.firstWhere(
      (event) => event.sourceEventId == 'replay-2',
    );
    expect(await controller.ignoreCaptureEvent(ignored.id), isTrue);
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        controller.autoCaptureSettings.copyWith(autoPostHighConfidence: true),
      ),
      isTrue,
    );

    expect(await controller.replayRecentCaptureEvents(), 1);
    expect(controller.entries, hasLength(originalEntryCount));
    expect(
      controller.captureEvents
          .firstWhere((event) => event.id == ignored.id)
          .status,
      CaptureStatus.ignored,
    );
    expect(
      controller.captureEvents
          .firstWhere((event) => event.id != ignored.id)
          .status,
      CaptureStatus.pendingReview,
    );
  });

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

  test('掌上生活消费提醒提取实际消费金额，忽略后续促销价格', () async {
    final controller = await makeController();
    final context = CaptureParseContext(
      book: controller.activeBook,
      accounts: controller.accounts,
      creditAccounts: controller.creditAccounts,
      categories: controller.categories,
      tags: controller.tags,
      entries: controller.entries,
      rules: const <AutoCaptureRule>[],
    );
    final notifications = <(String, double)>[
      (
        '交易提醒\n您在财付通-遂小狮有一笔2.30人民币的消费已成功，'
            '点击查看详情【金秋19.9元起看电影，更多优惠】',
        2.30,
      ),
      ('交易提醒\n您在支付宝-上海拉扎斯信息科技有限公司有一笔13.00人民币的消费已成功，点击查看详情', 13.00),
    ];

    for (var index = 0; index < notifications.length; index++) {
      final (rawText, expectedAmount) = notifications[index];
      final parsed = parseCaptureEvent(
        captureEventFromInput(
          id: 'cmb-notice-$index',
          bookId: controller.activeBook.id,
          input: RawCaptureInput(
            sourceKind: CaptureSourceKind.notification,
            sourceId: 'cmb-life',
            sourceLabel: '掌上生活',
            sourceEventId: 'cmb-notice-$index',
            rawText: rawText,
            receivedAt: DateTime(2026, 10, 2, 18, 5),
          ),
        ),
        context,
      );
      expect(parsed.parsedAmount, expectedAmount);
      expect(parsed.kind, CaptureTransactionKind.expense);
    }
  });

  test('美元单位前置/后置与千位金额绑定同币种信用子账户', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final cny = Account(
      id: 'cmb-cny',
      bookId: controller.activeBook.id,
      name: '招商人民币',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      cardLast4: '4185',
    );
    final usd = cny.copyWith(id: 'cmb-usd', name: '招商美元', currencyCode: 'USD');
    final context = CaptureParseContext(
      book: controller.activeBook,
      accounts: <Account>[cny, usd],
      creditAccounts: const <CreditAccount>[],
      categories: controller.categories,
      tags: controller.tags,
      entries: controller.entries,
      rules: const <AutoCaptureRule>[],
    );
    final amounts = <(String, double)>[
      ('USD 12.34', 12.34),
      ('usd12.34', 12.34),
      (r'US$12.34', 12.34),
      (r'US $ 12.34', 12.34),
      ('美元12.34', 12.34),
      ('12.34美元', 12.34),
      ('美金12.34', 12.34),
      ('1234.56美元', 1234.56),
      ('1,234.56美元', 1234.56),
      ('USD 1,234.56', 1234.56),
      ('USD 12.34,', 12.34),
    ];
    for (var index = 0; index < amounts.length; index++) {
      final (amountText, expectedAmount) = amounts[index];
      final parsed = parseCaptureEvent(
        captureEventFromInput(
          id: 'usd-format-$index',
          bookId: controller.activeBook.id,
          input: RawCaptureInput(
            sourceKind: CaptureSourceKind.notification,
            sourceId: 'cmb-life',
            sourceLabel: '掌上生活',
            sourceEventId: 'usd-format-$index',
            rawText:
                '尾号4185信用卡消费$amountText，商户示例商户。'
                '【19.9人民币起看电影】',
            receivedAt: DateTime(2026, 10, 8, 12),
          ),
        ),
        context,
      );
      expect(parsed.parsedAmount, expectedAmount, reason: amountText);
      expect(parsed.currencyCode, 'USD', reason: amountText);
      expect(parsed.accountCandidateId, usd.id, reason: amountText);
      expect(parsed.kind, CaptureTransactionKind.expense);
    }

    final cnyParsed = parseCaptureEvent(
      captureEventFromInput(
        id: 'cny-with-usd-promotion',
        bookId: controller.activeBook.id,
        input: RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'cmb-life',
          sourceEventId: 'cny-with-usd-promotion',
          rawText:
              '尾号4185信用卡消费1234.56人民币，商户示例商户。'
              '【美元10.00起优惠】',
          receivedAt: DateTime(2026, 10, 8, 12),
        ),
      ),
      context,
    );
    expect(cnyParsed.parsedAmount, 1234.56);
    expect(cnyParsed.currencyCode, 'CNY');
    expect(cnyParsed.accountCandidateId, cny.id);
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

  test('AI 只补充本地缺失字段且结果最高进入待确认', () async {
    final controller = await makeController();
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    const account = Account(
      id: 'ai-account',
      bookId: 'default',
      name: '测试账户',
      type: AccountType.onlinePayment,
      groupId: null,
      initialBalance: 0,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    final receivedAt = DateTime(2026, 9, 27, 18, 30);
    final parseContext = CaptureParseContext(
      book: controller.activeBook,
      accounts: const <Account>[account],
      creditAccounts: const <CreditAccount>[],
      categories: controller.categories,
      tags: const <Tag>[],
      entries: const <LedgerEntry>[],
      rules: const <AutoCaptureRule>[],
    );
    final local = parseCaptureEvent(
      captureEventFromInput(
        id: 'capture-ai-supplement',
        bookId: controller.activeBook.id,
        input: RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'com.example.payment',
          sourceEventId: 'ai-supplement-1',
          rawText: '支付59.49元',
          receivedAt: receivedAt,
        ),
      ),
      parseContext,
      processedAt: receivedAt,
    );
    final supplemented = applyAiCaptureSupplement(
      local,
      AiEntryDraft(
        type: EntryType.expense,
        amount: 59.49,
        currencyCode: 'CNY',
        categoryId: category.id,
        accountId: account.id,
        toAccountId: null,
        note: '麦当劳',
        occurredAt: receivedAt,
      ),
      parseContext,
    );

    expect(supplemented.aiAssisted, isTrue);
    expect(supplemented.accountCandidateId, account.id);
    expect(supplemented.categoryCandidateId, category.id);
    expect(supplemented.merchant, '麦当劳');
    expect(supplemented.confidence, CaptureConfidence.medium);
    expect(supplemented.status, CaptureStatus.pendingReview);
  });

  test('AI 金额与本地金额冲突时整份补充结果作废', () async {
    final controller = await makeController();
    final receivedAt = DateTime(2026, 9, 27, 18, 30);
    final parseContext = CaptureParseContext(
      book: controller.activeBook,
      accounts: controller.accounts,
      creditAccounts: controller.creditAccounts,
      categories: controller.categories,
      tags: controller.tags,
      entries: controller.entries,
      rules: const <AutoCaptureRule>[],
    );
    final local = parseCaptureEvent(
      captureEventFromInput(
        id: 'capture-ai-conflict',
        bookId: controller.activeBook.id,
        input: RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'com.example.payment',
          sourceEventId: 'ai-conflict-1',
          rawText: '支付59.49元',
          receivedAt: receivedAt,
        ),
      ),
      parseContext,
      processedAt: receivedAt,
    );
    final supplemented = applyAiCaptureSupplement(
      local,
      AiEntryDraft(
        type: EntryType.expense,
        amount: 599.49,
        currencyCode: 'CNY',
        categoryId: '',
        accountId: '',
        toAccountId: null,
        note: '错误结果',
        occurredAt: receivedAt,
      ),
      parseContext,
    );

    expect(supplemented.aiAssisted, isFalse);
    expect(supplemented.parsedAmount, 59.49);
    expect(supplemented.merchant, local.merchant);
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

  test('退款复核可在多个候选中指定原支出并支持部分退款', () async {
    final controller = await makeController();
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        controller.autoCaptureSettings.copyWith(autoPostHighConfidence: false),
      ),
      isTrue,
    );
    const account = Account(
      id: 'refund-card-6312',
      bookId: 'default',
      name: '中国银行信用卡',
      type: AccountType.creditCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      cardLast4: '6312',
    );
    expect(await controller.addAccountDraft(account), isTrue);
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final receivedAt = DateTime(2026, 10, 20, 17, 52);
    for (final item in <(String, double, String, int)>[
      ('refund-candidate-a', 180, '较早消费', 12),
      ('refund-candidate-b', 260, '需要关联的消费', 3),
    ]) {
      controller.addEntry(
        LedgerEntry(
          id: item.$1,
          bookId: controller.activeBook.id,
          type: EntryType.expense,
          amount: item.$2,
          categoryId: category.id,
          accountId: account.id,
          note: item.$3,
          occurredAt: receivedAt.subtract(Duration(days: item.$4)),
        ),
      );
    }
    await controller.waitForPendingWrites();
    expect(
      await controller.ingestCaptureInputs(<RawCaptureInput>[
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'bank-of-china',
          sourceEventId: 'refund-review-selection',
          rawText: '您的信用卡6312于2026年10月20日，在微信退货RMB100.00元。',
          receivedAt: receivedAt,
        ),
      ]),
      1,
    );
    final event = controller.captureEvents.single;

    final candidates = controller.captureRefundCandidates(
      event.id,
      sourceBookId: controller.activeBook.id,
      targetBookId: controller.activeBook.id,
    );
    expect(candidates.map((entry) => entry.id), <String>[
      'refund-candidate-b',
      'refund-candidate-a',
    ]);

    final refund = await controller.confirmParsedCaptureEvent(
      event.id,
      refundExpenseId: 'refund-candidate-b',
    );

    expect(refund, isNotNull);
    expect(refund!.amount, 100);
    expect(refund.refundOf, 'refund-candidate-b');
    expect(
      controller.entries
          .singleWhere((entry) => entry.id == 'refund-candidate-b')
          .refundedBaseAmount,
      100,
    );
    expect(
      controller.entries
          .singleWhere((entry) => entry.id == 'refund-candidate-a')
          .refundedBaseAmount,
      0,
    );
  });

  test('跨账本退款只匹配目标账本的账户和原支出', () async {
    final controller = await makeController();
    final sourceBookId = controller.activeBook.id;
    const sourceAccount = Account(
      id: 'source-refund-card',
      bookId: 'default',
      name: '来源银行卡',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 0,
      iconCode: 'credit',
      note: '',
      includeInAssets: true,
      hidden: false,
      cardLast4: '4185',
    );
    expect(await controller.addAccountDraft(sourceAccount), isTrue);
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final receivedAt = DateTime(2026, 10, 2);
    final original = LedgerEntry(
      id: 'source-refund-expense',
      bookId: sourceBookId,
      type: EntryType.expense,
      amount: 59.49,
      categoryId: category.id,
      accountId: sourceAccount.id,
      note: '消费',
      occurredAt: DateTime(2026, 10, 1),
    );
    controller.addEntry(original);
    await controller.ingestCaptureInputs([
      RawCaptureInput(
        sourceKind: CaptureSourceKind.notification,
        sourceId: 'test-bank',
        sourceEventId: 'cross-book-refund',
        rawText: '尾号4185退款59.49元，商户麦当劳',
        receivedAt: receivedAt,
      ),
    ]);
    final event = controller.captureEvents.single;
    controller.addLedgerBook('退款目标');
    final targetBookId = controller.activeBook.id;
    // 没有目标账户/原支出时不回退到来源账本，原事件保持不变。
    expect(
      await controller.confirmParsedCaptureEvent(
        event.id,
        sourceBookId: sourceBookId,
        targetBookId: targetBookId,
      ),
      isNull,
    );
    final targetAccount = sourceAccount.copyWith(
      id: 'target-refund-card',
      bookId: targetBookId,
      name: '目标银行卡',
    );
    expect(await controller.addAccountDraft(targetAccount), isTrue);
    controller.addEntry(
      original.copyWith(
        id: 'target-refund-expense',
        bookId: targetBookId,
        accountId: targetAccount.id,
      ),
    );
    final preview = controller.captureEventForReview(
      event.id,
      sourceBookId: sourceBookId,
      targetBookId: targetBookId,
    );
    expect(preview!.accountCandidateId, targetAccount.id);
    expect(controller.entries, hasLength(1));
    final refund = await controller.confirmParsedCaptureEvent(
      event.id,
      sourceBookId: sourceBookId,
      targetBookId: targetBookId,
    );
    expect(refund!.bookId, targetBookId);
    expect(refund.accountId, targetAccount.id);
    expect(refund.refundOf, 'target-refund-expense');
    expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
    expect(
      controller.entries
          .singleWhere((item) => item.id == 'target-refund-expense')
          .refundedBaseAmount,
      59.49,
    );
    controller.switchLedgerBook(sourceBookId);
    expect(controller.captureEvents, isEmpty);
    expect(controller.entries.single.refundedBaseAmount, 0);
    controller.dispose();
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

  test('AI 补充识别开关可持久化且旧配置默认关闭', () {
    const enabled = AutoCaptureSettings(aiAssistEnabled: true);

    expect(
      AutoCaptureSettings.decode(enabled.encode()).aiAssistEnabled,
      isTrue,
    );
    expect(
      AutoCaptureSettings.decode(
        '{"notificationEnabled":true}',
      ).aiAssistEnabled,
      isFalse,
    );
  });

  test('日期与地点同时命中才建议项目标签，且不改写商户等固有字段', () async {
    final controller = await makeController();
    final projectId = controller.addTag('项目:2026国庆返乡')!;
    final rule = AutoCaptureRule(
      id: 'holiday-project',
      bookId: controller.activeBook.id,
      name: '国庆返乡',
      priority: 10,
      placeContains: '湛江',
      startDate: DateTime(2026, 10, 1),
      endDate: DateTime(2026, 10, 7),
      setTagIds: <String>[projectId],
    );

    /// 以 [text] 和发生日 [at] 生成原始通知，并返回规则解析后的候选结果。
    CaptureEvent parse(String text, DateTime at) {
      final event = captureEventFromInput(
        id: 'event-${at.day}',
        bookId: controller.activeBook.id,
        input: RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'com.example.bank',
          sourceEventId: 'notice-${at.day}',
          rawText: text,
          receivedAt: at,
        ),
      );
      return parseCaptureEvent(
        event,
        CaptureParseContext(
          book: controller.activeBook,
          accounts: controller.accounts,
          creditAccounts: controller.creditAccounts,
          categories: controller.categories,
          tags: controller.tags,
          entries: controller.entries,
          rules: <AutoCaptureRule>[rule],
        ),
        processedAt: at,
      );
    }

    expect(
      parse('湛江消费38.50元，商户麦当劳', DateTime(2026, 10, 2)).tagCandidateIds,
      <String>[projectId],
    );
    expect(
      parse('深圳消费38.50元，商户麦当劳', DateTime(2026, 10, 2)).tagCandidateIds,
      isEmpty,
    );
    expect(
      parse('湛江消费38.50元，商户麦当劳', DateTime(2026, 10, 8)).tagCandidateIds,
      isEmpty,
    );
    controller.dispose();
  });
}
