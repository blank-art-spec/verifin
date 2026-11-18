import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/reminder/reminder_settings.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/reminder_settings_page.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  group('ReminderSettings', () {
    test('encode/decode round trips', () {
      const settings = ReminderSettings(
        enabled: true,
        cycleBudgetEnabled: true,
        statementDateEnabled: true,
        repaymentDueEnabled: true,
        statementAdvanceDays: 5,
        defaultRepaymentAdvanceDays: 1,
        hour: 8,
        minute: 30,
      );
      final decoded = ReminderSettings.decode(settings.encode());
      expect(decoded, settings);
      expect(decoded.hasAnyEnabled, isTrue);
    });

    test('旧版配置升级后新增提醒保持关闭', () {
      final decoded = ReminderSettings.decode(
        '{"enabled":true,"hour":20,"minute":15}',
      );

      expect(decoded.enabled, isTrue);
      expect(decoded.cycleBudgetEnabled, isFalse);
      expect(decoded.statementDateEnabled, isFalse);
      expect(decoded.repaymentDueEnabled, isFalse);
      expect(decoded.statementAdvanceDays, 3);
      expect(decoded.defaultRepaymentAdvanceDays, 0);
      expect(decoded.repaymentTimeOverride('credit-card'), isNull);
    });

    test('旧版共用默认切换为当天，非默认共用值保留，新版独立 3 天仍有效', () {
      final oldDefault = ReminderSettings.decode(
        '{"repaymentDueEnabled":true,"advanceDays":3}',
      );
      expect(oldDefault.repaymentDueEnabled, isTrue);
      expect(oldDefault.statementAdvanceDays, 3);
      expect(oldDefault.defaultRepaymentAdvanceDays, 0);

      final oldCustom = ReminderSettings.decode(
        '{"repaymentDueEnabled":true,"advanceDays":7}',
      );
      expect(oldCustom.statementAdvanceDays, 7);
      expect(oldCustom.defaultRepaymentAdvanceDays, 7);

      final current = oldDefault.copyWith(defaultRepaymentAdvanceDays: 3);
      expect(ReminderSettings.decode(current.encode()), current);
    });

    test('坏的账户时刻回退全局，不影响有效设置或其他账户', () {
      final decoded = ReminderSettings.decode(
        '{"repaymentDueEnabled":true,"hour":20,"minute":5,'
        '"repaymentMinutes":{"valid":0,"invalid":1440,"text":"60"}}',
      );
      expect(decoded.repaymentDueEnabled, isTrue);
      expect(decoded.defaultTime, (hour: 20, minute: 5));
      expect(decoded.repaymentTimeOverride('valid'), (hour: 0, minute: 0));
      expect(decoded.repaymentAdvanceDaysOverride('valid'), isNull);
      expect(decoded.repaymentTimeOverride('invalid'), isNull);
      expect(decoded.repaymentTimeOverride('text'), isNull);
      expect(ReminderSettings.decode(decoded.encode()), decoded);
    });

    test('保留当天和最长提前日数，损坏日期覆盖不影响时分', () {
      final decoded = ReminderSettings.decode(
        '{"advanceDays":3,"repaymentMinutes":{"invalid-day":540},'
        '"repaymentAdvanceDays":{"today":0,"valid":30,"invalid-day":31,'
        '"negative":-1,"text":"3"}}',
      );
      expect(decoded.repaymentAdvanceDaysOverride('today'), 0);
      expect(decoded.repaymentAdvanceDaysOverride('valid'), 30);
      expect(decoded.repaymentAdvanceDaysOverride('invalid-day'), isNull);
      expect(decoded.repaymentAdvanceDaysOverride('negative'), isNull);
      expect(decoded.repaymentAdvanceDaysOverride('text'), isNull);
      expect(decoded.repaymentTimeOverride('invalid-day'), (
        hour: 9,
        minute: 0,
      ));
      expect(ReminderSettings.decode(decoded.encode()), decoded);
    });

    test('decode of null/garbage falls back to disabled', () {
      expect(ReminderSettings.decode(null), ReminderSettings.disabled);
      expect(ReminderSettings.decode(''), ReminderSettings.disabled);
      expect(ReminderSettings.decode('not json'), ReminderSettings.disabled);
    });

    test('decode clamps out-of-range hour/minute', () {
      final decoded = ReminderSettings.decode(
        '{"enabled":true,"advanceDays":90,"hour":30,"minute":90}',
      );
      expect(decoded.statementAdvanceDays, 30);
      expect(decoded.defaultRepaymentAdvanceDays, 0);
      expect(decoded.hour, 23);
      expect(decoded.minute, 59);
    });

    test('timeLabel pads to HH:mm', () {
      const settings = ReminderSettings(hour: 9, minute: 5);
      expect(settings.timeLabel, '09:05');
    });

    test('nextFireTime rolls to tomorrow when time already passed', () {
      const settings = ReminderSettings(enabled: true, hour: 9, minute: 0);
      final afternoon = DateTime(2026, 5, 1, 15, 0);
      expect(settings.nextFireTime(afternoon), DateTime(2026, 5, 2, 9, 0));

      final morning = DateTime(2026, 5, 1, 7, 0);
      expect(settings.nextFireTime(morning), DateTime(2026, 5, 1, 9, 0));
    });
  });

  test('账期预算提醒按账期和档位跨重启去重', () async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    const account = Account(
      id: 'credit-card',
      bookId: 'default',
      name: '招商信用卡',
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
    expect(await controller.addAccountDraft(account), isTrue);
    final creditAccount = controller.creditAccounts.single;
    expect(
      await controller.saveCreditAccountDraft(
        creditAccount.copyWith(cycleBudget: 4000),
      ),
      isTrue,
    );
    controller.addEntry(
      LedgerEntry(
        id: 'expense-80',
        bookId: 'default',
        type: EntryType.expense,
        amount: 3200,
        baseAmount: 3200,
        categoryId: 'dining',
        accountId: account.id,
        note: '',
        occurredAt: DateTime(2026, 9, 27),
      ),
    );
    await controller.saveReminderSettingsDraft(
      const ReminderSettings(cycleBudgetEnabled: true),
    );
    final pending = controller.pendingBudgetReminderSnapshots(
      now: DateTime(2026, 9, 27),
    );
    expect(pending, hasLength(1));
    expect(
      await controller.markBudgetReminderDelivered(pending.single),
      isTrue,
    );
    expect(
      controller.pendingBudgetReminderSnapshots(now: DateTime(2026, 9, 27)),
      isEmpty,
    );
    await controller.waitForPendingWrites();
    controller.dispose();

    final restored = await makeController(store);
    expect(
      restored.pendingBudgetReminderSnapshots(now: DateTime(2026, 9, 27)),
      isEmpty,
      reason: '同一账期的 80% 档位在冷启动后不能重复通知',
    );
    restored.addEntry(
      LedgerEntry(
        id: 'expense-reached',
        bookId: 'default',
        type: EntryType.expense,
        amount: 800,
        baseAmount: 800,
        categoryId: 'dining',
        accountId: account.id,
        note: '',
        occurredAt: DateTime(2026, 9, 28),
      ),
    );
    expect(
      restored.pendingBudgetReminderSnapshots(now: DateTime(2026, 9, 28)),
      hasLength(1),
      reason: '达到预算属于更高档位，应再通知一次',
    );
    restored.dispose();
  });

  testWidgets('提醒设置页开关与时间持久化', (WidgetTester tester) async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);

    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const ReminderSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 初始未开启，不显示提醒时间行。
    expect(find.text('每日提醒'), findsOneWidget);
    expect(find.text('提醒时间'), findsNothing);

    // 打开开关后出现时间行，但保存前不写 Controller/KV。
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('提醒时间'), findsOneWidget);
    expect(controller.reminderSettings.enabled, isFalse);
    expect(
      ReminderSettings.decode(store.read('verifin.reminder.v1')).enabled,
      isFalse,
    );

    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.reminderSettings.enabled, isTrue);
    expect(
      ReminderSettings.decode(store.read('verifin.reminder.v1')).enabled,
      isTrue,
    );

    controller.dispose();
  });
}
