import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/auto_capture/capture_parser.dart';
import 'package:verifin/app/models.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  test('关闭自动入账仍可合并安全重复来源，不新增交易或改金额', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    controller.addLedgerBook('重复检测账本', baseCurrencyCode: 'CNY');
    await controller.waitForPendingWrites();
    final account = Account(
      id: 'duplicate-gate-account',
      bookId: controller.activeBook.id,
      name: '重复检测账户',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 1000,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
    );
    expect(await controller.addAccountDraft(account), isTrue);
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final occurredAt = DateTime(2026, 10, 26, 12);
    controller.addEntry(
      LedgerEntry(
        id: 'existing-gate-expense',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 59.49,
        categoryId: category.id,
        accountId: account.id,
        note: '重复检测商户',
        occurredAt: occurredAt,
      ),
    );
    await controller.waitForPendingWrites();
    expect(
      await controller.saveAutoCaptureRule(
        AutoCaptureRule(
          id: 'duplicate-gate-rule',
          bookId: controller.activeBook.id,
          name: '重复检测规则',
          priority: 100,
          textContains: '重复检测商户',
          setKind: CaptureTransactionKind.expense,
          setAccountId: account.id,
          setCategoryId: category.id,
          setMerchant: '重复检测商户',
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
    final before = controller.entries.single;
    final balanceBefore = controller.accountBalance(account);
    expect(before.sourceRecords, isEmpty);

    expect(
      await controller.ingestCaptureInputs([
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'test.capture.bank',
          sourceEventId: 'duplicate-auto-post-disabled',
          rawText: '消费59.49元，商户重复检测商户',
          receivedAt: occurredAt.add(const Duration(minutes: 1)),
        ),
      ]),
      1,
    );

    final event = controller.captureEvents.single;
    expect(controller.autoCaptureSettings.autoPostHighConfidence, isFalse);
    expect(event.confidence, CaptureConfidence.high);
    expect(event.status, CaptureStatus.merged);
    expect(event.linkedEntryId, before.id);
    expect(controller.entries, hasLength(1));
    final after = controller.entries.single;
    expect(after.id, before.id);
    expect(after.amount, before.amount);
    expect(after.accountAmount, before.accountAmount);
    expect(after.baseAmount, before.baseAmount);
    expect(after.accountId, before.accountId);
    expect(after.categoryId, before.categoryId);
    expect(after.note, before.note);
    expect(after.occurredAt, before.occurredAt);
    expect(controller.accountBalance(account), balanceBefore);
    expect(after.sourceRecords, hasLength(1));
    expect(
      after.sourceRecords.single.sourceTransactionId,
      'duplicate-auto-post-disabled',
    );
  });

  test('本地高置信外币消费缺账本汇率时保持待确认，不自动创建交易', () async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    controller.addLedgerBook('缺率检测账本', baseCurrencyCode: 'CNY');
    await controller.waitForPendingWrites();
    final account = Account(
      id: 'missing-rate-usd-account',
      bookId: controller.activeBook.id,
      name: '美元检测账户',
      type: AccountType.debitCard,
      groupId: null,
      initialBalance: 100,
      iconCode: 'asset:payment_001',
      note: '',
      includeInAssets: true,
      hidden: false,
      currencyCode: 'USD',
      cardLast4: '4170',
    );
    expect(await controller.addAccountDraft(account), isTrue);
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    expect(
      await controller.saveAutoCaptureRule(
        AutoCaptureRule(
          id: 'missing-rate-gate-rule',
          bookId: controller.activeBook.id,
          name: '外币检测规则',
          priority: 100,
          textContains: '外币检测商户',
          setKind: CaptureTransactionKind.expense,
          setAccountId: account.id,
          setCategoryId: category.id,
          setMerchant: '外币检测商户',
        ),
      ),
      isTrue,
    );
    expect(
      await controller.saveAutoCaptureSettingsDraft(
        controller.autoCaptureSettings.copyWith(autoPostHighConfidence: true),
      ),
      isTrue,
    );
    expect(controller.exchangeRates, isEmpty);
    expect(controller.entries, isEmpty);
    final balanceBefore = controller.accountBalance(account);

    expect(
      await controller.ingestCaptureInputs([
        RawCaptureInput(
          sourceKind: CaptureSourceKind.notification,
          sourceId: 'test.capture.bank',
          sourceEventId: 'high-confidence-without-base-rate',
          rawText: '尾号4170消费USD 12.34，商户外币检测商户',
          receivedAt: DateTime(2026, 10, 26, 12),
        ),
      ]),
      1,
    );

    final event = controller.captureEvents.single;
    expect(event.confidence, CaptureConfidence.high);
    expect(event.confidenceScore, greaterThanOrEqualTo(0.85));
    expect(event.kind, CaptureTransactionKind.expense);
    expect(event.parsedAmount, 12.34);
    expect(event.currencyCode, 'USD');
    expect(event.accountCandidateId, account.id);
    expect(event.categoryCandidateId, category.id);
    expect(event.status, CaptureStatus.pendingReview);
    expect(event.linkedEntryId, isNull);
    expect(controller.entries, isEmpty);
    expect(controller.accountBalance(account), balanceBefore);
    expect(controller.exchangeRates, isEmpty);
  });
}
