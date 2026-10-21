import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/reminder/account_entry_reminder.dart';
import 'package:verifin/app/reminder/china_workday_calendar.dart';
import 'package:verifin/l10n/app_localizations_zh.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';
import 'support/account_reminder_harness.dart';

/// 账户提醒回归：显式种入账户，验证真实领域与持久化语义。
void main() {
  useTestDatabases();

  test('工作日提醒允许不选星期，冷启动保留模式，原生快照含同源年度日历', () async {
    final store = LocalKeyValueStore();
    var controller = await makeReminderController(store);
    final account = controller.accounts.first;
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final draft = AccountEntryReminder(
      id: '',
      accountId: account.id,
      bookId: account.bookId,
      currencyCode: account.currencyCode,
      enabled: true,
      amount: 12,
      categoryId: category.id,
      weekdays: const [],
      repeatMode: AccountReminderRepeatMode.chinaWorkdays,
    );
    expect(await controller.saveAccountEntryReminder(draft), isTrue);
    await controller.flushPendingWrites();
    controller.dispose();
    controller = await makeReminderController(store);
    final rule = controller.accountEntryReminder(account.id)!;
    expect(rule.repeatMode, AccountReminderRepeatMode.chinaWorkdays);
    expect(rule.missingCalendarPolicy, MissingWorkdayCalendarPolicy.pause);
    final projection = controller
        .accountEntryReminderNotifications(AppLocalizationsZh())
        .single;
    expect(projection['repeatMode'], 'chinaWorkdays');
    expect(
      projection['workdayCalendar'],
      mainlandChinaWorkdayCalendar.toJson(),
    );
    // 即使原生队列送来了动作，确认端仍校验当天规则；空星期列表不能挡住有效工作日。
    final now = DateTime.now();
    final expected = mainlandChinaWorkdayCalendar.isWorkday(now) == true;
    final beforeCount = controller.entries.length;
    expect(
      await controller.handleAccountEntryReminder(
        id: rule.id,
        date: currencyDateKey(now),
        confirm: true,
      ),
      expected ? AccountReminderResult.recorded : AccountReminderResult.expired,
    );
    expect(controller.entries.length, beforeCount + (expected ? 1 : 0));
    expect(
      jsonEncode(controller.exportDataJson()),
      isNot(contains('workdayCalendar')),
    );
    controller.dispose();
  });

  /// 为 [account] 构造每天可触发的固定支出草稿，避免测试依赖执行当天是周几。
  AccountEntryReminder draftFor(Account account, String categoryId) =>
      AccountEntryReminder(
        id: '',
        accountId: account.id,
        bookId: account.bookId,
        currencyCode: account.currencyCode,
        enabled: true,
        name: '饭堂午餐',
        amount: 12.5,
        categoryId: categoryId,
        weekdays: const [1, 2, 3, 4, 5, 6, 7],
        confirmLabel: '确定',
        cancelLabel: '取消',
      );

  test('切换账本不丢失提醒，确认固定写回原账户，并发点击和冷启动不重复', () async {
    final store = LocalKeyValueStore();
    var controller = await makeReminderController(store);
    final account = controller.accounts.first;
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final beforeCount = controller.entries.length;
    expect(
      await controller.saveAccountEntryReminder(draftFor(account, category.id)),
      isTrue,
    );
    final rule = controller.accountEntryReminder(account.id)!;
    final today = currencyDateKey(dateOnly(DateTime.now()));
    controller.addLedgerBook('日常开销');
    final browsingBook = controller.activeBook.id;
    expect(
      controller
          .accountEntryReminderNotifications(AppLocalizationsZh())
          .single['bookId'],
      account.bookId,
    );
    final results = await Future.wait([
      controller.handleAccountEntryReminder(
        id: rule.id,
        date: today,
        confirm: true,
      ),
      controller.handleAccountEntryReminder(
        id: rule.id,
        date: today,
        confirm: true,
      ),
    ]);
    expect(results, [
      AccountReminderResult.recorded,
      AccountReminderResult.alreadyHandled,
    ]);
    expect(controller.activeBook.id, browsingBook);
    expect(controller.entries, isEmpty);
    controller.switchLedgerBook(account.bookId);
    expect(controller.entries.length, beforeCount + 1);
    final entry = controller.entries.firstWhere(
      (item) => item.id.startsWith('entry_account_reminder_'),
    );
    expect(entry.accountId, account.id);
    expect(entry.bookId, account.bookId);
    expect(entry.amount, 12.5);
    expect(entry.accountAmount, 12.5);
    await controller.flushPendingWrites();
    controller.dispose();
    controller = await makeReminderController(store);
    expect(
      await controller.handleAccountEntryReminder(
        id: rule.id,
        date: today,
        confirm: true,
      ),
      AccountReminderResult.alreadyHandled,
    );
    expect(controller.entries.length, beforeCount + 1);
    controller.dispose();
  });

  test('取消零落账，重启与重新配置都不能再处理当天', () async {
    final store = LocalKeyValueStore();
    var controller = await makeReminderController(store);
    final account = controller.accounts.first;
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    final beforeCount = controller.entries.length;
    expect(
      await controller.saveAccountEntryReminder(draftFor(account, category.id)),
      isTrue,
    );
    final rule = controller.accountEntryReminder(account.id)!;
    final today = currencyDateKey(dateOnly(DateTime.now()));
    expect(
      await controller.handleAccountEntryReminder(
        id: rule.id,
        date: today,
        confirm: false,
      ),
      AccountReminderResult.cancelled,
    );
    expect(controller.entries.length, beforeCount);
    await controller.flushPendingWrites();
    controller.dispose();
    controller = await makeReminderController(store);
    expect(
      await controller.saveAccountEntryReminder(rule.copyWith(amount: 20)),
      isTrue,
    );
    final changed = controller.accountEntryReminder(account.id)!;
    expect(changed.handledDate, today);
    expect(
      await controller.handleAccountEntryReminder(
        id: changed.id,
        date: today,
        confirm: true,
      ),
      AccountReminderResult.alreadyHandled,
    );
    expect(controller.entries.length, beforeCount);
    controller.dispose();
  });

  test('过期日期和编辑前旧通知不落账，提醒配置不进入账本备份', () async {
    final controller = await makeReminderController();
    final account = controller.accounts.first;
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    expect(
      await controller.saveAccountEntryReminder(draftFor(account, category.id)),
      isTrue,
    );
    final rule = controller.accountEntryReminder(account.id)!;
    final beforeCount = controller.entries.length;
    final now = DateTime.now();
    final yesterday = currencyDateKey(addCalendarDays(dateOnly(now), -1));
    expect(
      await controller.handleAccountEntryReminder(
        id: rule.id,
        date: yesterday,
        confirm: true,
      ),
      AccountReminderResult.expired,
    );
    expect(
      await controller.saveAccountEntryReminder(rule.copyWith(amount: 15)),
      isTrue,
    );
    expect(
      await controller.handleAccountEntryReminder(
        id: rule.id,
        date: currencyDateKey(dateOnly(now)),
        confirm: true,
      ),
      AccountReminderResult.expired,
    );
    expect(controller.entries.length, beforeCount);
    final exported =
        jsonDecode(controller.exportDataJson()) as Map<String, Object?>;
    expect(jsonEncode(exported), isNot(contains('account_entry_reminders')));
    expect(jsonEncode(exported), isNot(contains(rule.id)));
    controller.dispose();
  });

  test('删除无流水账户清除提醒，初始化清除提醒且旧通知失效', () async {
    final controller = await makeReminderController();
    final original = controller.accounts.first;
    final account = original.copyWith(
      id: 'reminder-empty-account',
      name: '空账户',
    );
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    expect(
      await controller.saveAccountEntryReminder(draftFor(account, category.id)),
      isTrue,
    );
    expect(await controller.deleteAccount(account.id), isNotNull);
    expect(controller.accountEntryReminder(account.id), isNull);
    expect(
      await controller.saveAccountEntryReminder(
        draftFor(original, category.id),
      ),
      isTrue,
    );
    final rule = controller.accountEntryReminder(original.id)!;
    controller.resetAllData();
    expect(controller.accountEntryRemindersListenable.value, isEmpty);
    expect(
      await controller.handleAccountEntryReminder(
        id: rule.id,
        date: currencyDateKey(dateOnly(DateTime.now())),
        confirm: true,
      ),
      AccountReminderResult.expired,
    );
    await controller.flushPendingWrites();
    controller.dispose();
  });
}
