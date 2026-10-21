import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/main.dart';
import 'package:verifin/pages/auto_capture_page.dart';
import 'package:verifin/pages/entry_detail_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('自动采集页展示权限开关、状态面板和空队列', (tester) async {
    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AutoCapturePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('自动记账与智能识别'), findsOneWidget);
    expect(find.text('支付通知监听'), findsOneWidget);
    expect(find.text('消费短信补充'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('暂时没有待处理事件'),
      180,
      scrollable: firstVerticalScrollable(),
    );
    expect(find.text('暂时没有待处理事件'), findsOneWidget);
  });

  testWidgets('复核记账会解析已保存但尚无金额的掌上生活通知', (tester) async {
    final store = LocalKeyValueStore();
    store.write('verifin.locale.v1', 'zh');
    final repository = InMemoryLedgerRepository();
    final initial = await VeriFinController.create(
      store,
      repository: repository,
    );
    final bookId = initial.activeBook.id;
    initial.addLedgerBook('旅行账本');
    final targetBookId = initial.activeBook.id;
    initial.switchLedgerBook(bookId);
    await initial.waitForPendingWrites();
    initial.dispose();
    await repository.saveCaptureEvents(<CaptureEvent>[
      captureEventFromInput(
        id: 'cmb-unprocessed',
        bookId: bookId,
        input: RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'cmb-life',
          sourceLabel: '掌上生活',
          sourceEventId: 'cmb-unprocessed',
          rawText: '交易提醒\n您在财付通-遂小狮有一笔2.30人民币的消费已成功，点击查看详情',
          receivedAt: DateTime(2026, 10, 2, 18, 5),
        ),
      ),
    ]);
    final controller = await VeriFinController.create(
      store,
      repository: repository,
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AutoCapturePage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('复核记账'),
      180,
      scrollable: firstVerticalScrollable(),
    );
    await tester.drag(firstVerticalScrollable(), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复核记账'));
    await tester.pumpAndSettle();

    expect(controller.captureEvents.single.parsedAmount, 2.30);
    expect(find.byType(EntryDetailPage), findsOneWidget);
    expect(
      tester
          .widget<EntryDetailPage>(find.byType(EntryDetailPage))
          .captureEventId,
      'cmb-unprocessed',
    );
    await tester.tap(find.byKey(const Key('capture_review_book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旅行账本'));
    await tester.pumpAndSettle();
    expect(controller.activeBook.id, targetBookId);
    // 仅切换选择不搬移事件，也不创建交易；无目标账户时仍可记为无账户收支。
    expect((await repository.loadCaptureEvents()).single.bookId, bookId);
    expect(await repository.loadEntries(), isEmpty);
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    expect(controller.entries.single.bookId, targetBookId);
    expect(controller.entries.single.amount, 2.30);
    expect(controller.entries.single.accountId, isEmpty);
    expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
    expect(controller.captureEvents.single.bookId, targetBookId);
    expect(find.byType(EntryDetailPage), findsNothing);
  });

  testWidgets('复核取消账本选择不改状态，缺统计汇率仍可保存实际原币', (tester) async {
    final store = LocalKeyValueStore();
    store.write('verifin.locale.v1', 'zh');
    final repository = InMemoryLedgerRepository();
    var controller = await VeriFinController.create(
      store,
      repository: repository,
    );
    final sourceBookId = controller.activeBook.id;
    controller.addLedgerBook('美元账本', baseCurrencyCode: 'USD');
    final targetBookId = controller.activeBook.id;
    controller.switchLedgerBook(sourceBookId);
    await controller.waitForPendingWrites();
    final event =
        captureEventFromInput(
          id: 'review-missing-rate',
          bookId: sourceBookId,
          input: RawCaptureInput(
            sourceKind: CaptureSourceKind.notification,
            sourceId: 'test-bank',
            sourceEventId: 'review-missing-rate',
            rawText: '消费2.30人民币',
            receivedAt: DateTime(2026, 10, 2),
          ),
        ).copyWith(
          status: CaptureStatus.pendingReview,
          parsedAmount: 2.30,
          kind: CaptureTransactionKind.expense,
        );
    await repository.saveCaptureEvents([event]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repository);
    final draft = controller.captureEntryDraft(event.id)!;
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          home: EntryDetailPage(
            initialAmount: draft.amount,
            initialDraft: draft,
            captureEventId: event.id,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('capture_review_book')));
    await tester.pumpAndSettle();
    // 模拟系统返回关闭底部选择器，不离开复核页。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.activeBook.id, sourceBookId);
    await tester.tap(find.byKey(const Key('capture_review_book')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('美元账本'));
    await tester.pumpAndSettle();
    expect(controller.activeBook.id, targetBookId);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save_entry_button')))
          .onPressed,
      isNotNull,
    );
    expect(await repository.loadEntries(), isEmpty);
    expect((await repository.loadCaptureEvents()).single.bookId, sourceBookId);
    await tester.ensureVisible(find.byKey(const Key('save_entry_button')));
    await tester.tap(find.byKey(const Key('save_entry_button')));
    await tester.pumpAndSettle();
    final saved = (await repository.loadEntries()).single;
    expect(saved.bookId, targetBookId);
    expect(saved.currencyCode, 'CNY');
    expect(saved.baseAmount, 0);
    expect(saved.referenceBaseAmount, isNull);
    expect((await repository.loadCaptureEvents()).single.bookId, targetBookId);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('退款复核选择指定原消费后创建关联退款', (tester) async {
    final controller = await makeController();
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        controller.autoCaptureSettings.copyWith(autoPostHighConfidence: false),
      ),
      isTrue,
    );
    const account = Account(
      id: 'refund-review-card',
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
    controller.addEntry(
      LedgerEntry(
        id: 'refund-review-first',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 180,
        categoryId: category.id,
        accountId: account.id,
        note: '第一笔候选消费',
        occurredAt: receivedAt.subtract(const Duration(days: 8)),
      ),
    );
    controller.addEntry(
      LedgerEntry(
        id: 'refund-review-target',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 260,
        categoryId: category.id,
        accountId: account.id,
        note: '需要关联的消费',
        occurredAt: receivedAt.subtract(const Duration(days: 2)),
      ),
    );
    await controller.waitForPendingWrites();
    expect(
      await controller.ingestCaptureInputs(<RawCaptureInput>[
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'bank-of-china',
          sourceEventId: 'refund-review-widget',
          rawText: '您的信用卡6312于2026年10月20日，在微信退货RMB100.00元。',
          receivedAt: receivedAt,
        ),
      ]),
      1,
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AutoCapturePage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('复核记账'),
      180,
      scrollable: firstVerticalScrollable(),
    );
    await tester.tap(find.text('复核记账'));
    await tester.pumpAndSettle();

    expect(find.text('选择原消费'), findsOneWidget);
    expect(find.text('第一笔候选消费'), findsOneWidget);
    expect(find.text('需要关联的消费'), findsOneWidget);
    await tester.tap(find.text('需要关联的消费'));
    await tester.pumpAndSettle();
    expect(find.textContaining('确认创建退款'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    final refund = controller.entries.singleWhere(
      (entry) => entry.type == EntryType.refund,
    );
    expect(refund.refundOf, 'refund-review-target');
    expect(refund.amount, 100);
    expect(controller.captureEvents.single.status, CaptureStatus.confirmed);
  });

  testWidgets('冷启动会补解析已落库但尚未处理的通知', (tester) async {
    final store = LocalKeyValueStore();
    store.write('verifin.locale.v1', 'zh');
    final repository = InMemoryLedgerRepository();
    final initial = await VeriFinController.create(
      store,
      repository: repository,
    );
    final bookId = initial.activeBook.id;
    initial.dispose();
    await repository.saveCaptureEvents(<CaptureEvent>[
      captureEventFromInput(
        id: 'capture-before-crash',
        bookId: bookId,
        input: RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'cmb-life',
          sourceLabel: '掌上生活',
          sourceEventId: 'capture-before-crash',
          rawText: '您在财付通-遂小狮有一笔2.30人民币的消费已成功',
          receivedAt: DateTime(2026, 10, 2, 18, 5),
        ),
      ),
    ]);
    final controller = await VeriFinController.create(
      store,
      repository: repository,
    );

    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();

    final recovered = controller.captureEvents.single;
    expect(recovered.parsedAmount, 2.30);
    expect(recovered.kind, CaptureTransactionKind.expense);
    expect(recovered.processedAt, isNotNull);
  });
}
