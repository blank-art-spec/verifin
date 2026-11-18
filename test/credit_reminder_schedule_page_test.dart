import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/reminder/reminder_settings.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/reminder_settings_page.dart';

import 'support/test_harness.dart';

const _captureKey = Key('credit-reminder-page-capture');

/// 仅显式请求本地截图时输出图片，普通测试和 CI 不读系统字体、不产生截图文件。
bool get _captureEnabled =>
    Platform.environment['VERIFIN_REMINDER_SCREENSHOTS'] == '1';

/// [tester] 提供真实异步区间；截图使用系统中文字体和原 Material 图标，避免方块字。
Future<void> _loadCaptureFont(WidgetTester tester) async {
  if (!_captureEnabled) return;
  await tester.runAsync(() async {
    final bytes = await File(r'C:\Windows\Fonts\msyh.ttc').readAsBytes();
    await (FontLoader(
      'ReminderCapture',
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

/// 构造与正式设备隔离的五个信用主体；[settings] 是已保存设置。
/// [store] 可让测试模拟冷启动，不访问用户数据库。
/// 信用卡有已结清账单和预算，花呗有待还账单，白条只有未出账消费，美团没有欠款。
Future<VeriFinController> _makeFixture(
  ReminderSettings settings, {
  LocalKeyValueStore? store,
}) async {
  final controller = await makeController(store);
  final now = DateTime.now();
  // 让默认的账单日提醒排在示例待还账单的还款日之后，以便分别看到两类提醒。
  final statementDay = addCalendarDays(now, 9).day;
  const names = ['招商信用卡', '中国银行信用卡', '蚂蚁花呗', '京东白条', '美团月付'];
  for (var index = 0; index < names.length; index++) {
    final id = 'reminder-account-$index';
    expect(
      await controller.addAccountDraft(
        Account(
          id: id,
          bookId: defaultLedgerBookId,
          name: names[index],
          type: index < 2 ? AccountType.creditCard : AccountType.creditAccount,
          groupId: null,
          initialBalance: 0,
          iconCode: 'credit',
          note: '',
          includeInAssets: true,
          hidden: false,
          statementDay: statementDay,
          dueDay: 13,
        ),
      ),
      isTrue,
    );
    final parent = controller.creditAccounts.singleWhere(
      (item) => item.name == names[index],
    );
    if (index < 2) {
      expect(
        await controller.saveCreditAccountDraft(
          parent.copyWith(cycleBudget: 4000),
        ),
        isTrue,
      );
    }
    if (index < 4) {
      final amount = [3200.0, 2200.0, 600.0, 200.0][index];
      controller.addEntry(
        LedgerEntry(
          id: 'reminder-expense-$index',
          bookId: defaultLedgerBookId,
          type: EntryType.expense,
          amount: amount,
          baseAmount: amount,
          categoryId: 'dining',
          accountId: id,
          note: '',
          occurredAt: now,
        ),
      );
    }
    if (index < 3) {
      final statementDate = DateTime(now.year, now.month - 1, statementDay);
      expect(
        await controller.saveBillingStatement(
          BillingStatement(
            id: 'reminder-statement-$index',
            bookId: defaultLedgerBookId,
            accountId: id,
            statementDate: statementDate,
            periodStart: DateTime(now.year, now.month - 2, statementDay),
            periodEnd: statementDate,
            statementAmount: 500,
            minimumPayment: 50,
            dueDate: addCalendarDays(now, index == 2 ? 5 : 10),
            paidAmount: index == 2 ? 0 : 500,
            status: index == 2
                ? BillingStatementStatus.open
                : BillingStatementStatus.paid,
            currencyCode: 'CNY',
          ),
        ),
        isTrue,
      );
    }
  }
  await controller.waitForPendingWrites();
  expect(await controller.saveReminderSettingsDraft(settings), isTrue);
  return controller;
}

/// 在 [width] 宽、852dp 高的正式页面上验证 [locale]、[brightness] 和 [scale] 下的布局。
/// 截图只替换测试字体，不创建演示页面；页面仍消费真正的 Controller 和设置草稿。
Future<void> _pumpPage(
  WidgetTester tester,
  VeriFinController controller, {
  double width = 393,
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 852);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await _loadCaptureFont(tester);
  var theme = buildVeriFinTheme(brightness);
  if (_captureEnabled) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'ReminderCapture'),
    );
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) => Localizations.override(
              context: context,
              locale: locale,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: const ReminderSettingsPage(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 滚动到真实页面的账户状态分区；[english] 只改变定位标题，不影响被测页面内容。
Future<void> _showAccountStatus(
  WidgetTester tester, {
  bool english = false,
}) async {
  final heading = find.text(
    english ? 'Upcoming credit account status' : '近期信用账户状态',
  );
  await tester.scrollUntilVisible(
    heading,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(heading);
  await tester.pumpAndSettle();
}

/// 将当前正式页面保存为 [name]；仅在截图开关启用时执行，不修改任何源图。
Future<void> _capture(WidgetTester tester, String name) async {
  if (!_captureEnabled) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('build/validation/credit-reminder-next-time');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// 注册按账户排程、草稿不落库、关闭与空状态及中英文窄屏布局验证。
void main() {
  useTestDatabases();
  const enabled = ReminderSettings(
    statementDateEnabled: true,
    repaymentDueEnabled: true,
  );

  testWidgets('每个账户可改还款日期和时刻，保存后冷启动保留且可逐项恢复默认', (tester) async {
    final store = LocalKeyValueStore();
    final controller = await _makeFixture(enabled, store: store);
    addTearDown(controller.dispose);
    final account = controller.creditAccounts.singleWhere(
      (item) => item.name == '蚂蚁花呗',
    );
    final card = find.byKey(ValueKey('credit_reminder_${account.id}'));
    final timeRow = find.descendant(of: card, matching: find.text('还款提醒时间'));
    final dateRow = find.descendant(of: card, matching: find.text('还款提醒日期'));
    final dueDate = controller
        .creditReminderSnapshots()
        .singleWhere((item) => item.creditAccount.id == account.id)
        .dueDate;
    await _pumpPage(tester, controller);
    await tester.scrollUntilVisible(dateRow, 180);
    await Scrollable.ensureVisible(tester.element(dateRow), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(dateRow);
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(dateRow));
    await _capture(tester, 'repayment-date-options');
    await tester.tap(find.widgetWithText(ListTile, '提前 4 天'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.text('提前 4 天')), findsOne);
    expect(
      controller.reminderSettings.repaymentAdvanceDaysOverride(account.id),
      isNull,
    );
    await tester.scrollUntilVisible(timeRow, 180);
    await Scrollable.ensureVisible(tester.element(timeRow), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(timeRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(1), '35');
    await tester.pumpAndSettle();
    final material = MaterialLocalizations.of(tester.element(fields.first));
    await tester.tap(find.text(material.okButtonLabel));
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.text('21:35')), findsOne);
    expect(
      find.descendant(
        of: card,
        matching: find.text(
          l10n.reminderNextScheduled(
            addCalendarDays(dueDate, -4),
            '21:35',
            l10n.reminderRepaymentDue,
          ),
        ),
      ),
      findsOne,
    );
    expect(
      controller.reminderSettings.repaymentTimeOverride(account.id),
      isNull,
    );
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    if (_captureEnabled) {
      await Scrollable.ensureVisible(tester.element(card), alignment: 0.12);
      await tester.pumpAndSettle();
      await _capture(tester, 'repayment-date-time-accounts');
    }
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());

    final restored = await makeController(store);
    addTearDown(restored.dispose);
    expect(restored.reminderSettings.repaymentTimeOverride(account.id), (
      hour: 21,
      minute: 35,
    ));
    expect(
      restored.reminderSettings.repaymentAdvanceDaysOverride(account.id),
      4,
    );
    expect(restored.reminderSettings.defaultTime, (hour: 21, minute: 0));
    expect(
      restored.creditAccounts
          .where((item) => item.id != account.id)
          .every(
            (item) =>
                restored.reminderSettings.repaymentTimeOverride(item.id) ==
                null,
          ),
      isTrue,
    );

    await _pumpPage(tester, restored);
    await tester.scrollUntilVisible(dateRow, 180);
    await Scrollable.ensureVisible(tester.element(dateRow), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(dateRow);
    await tester.pumpAndSettle();
    // 账户卡片可能也在显示同一全局值，只点选项面板中的设置项。
    await tester.tap(find.widgetWithText(ListTile, '默认 · 还款日当天'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: card, matching: find.text('默认 · 还款日当天')),
      findsOne,
    );
    expect(find.descendant(of: card, matching: find.text('21:35')), findsOne);
    await tester.scrollUntilVisible(timeRow, 180);
    await Scrollable.ensureVisible(tester.element(timeRow), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(timeRow);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: card, matching: find.text('默认 · 21:00')),
      findsOne,
    );
    expect(restored.reminderSettings.repaymentTimeOverride(account.id), (
      hour: 21,
      minute: 35,
    ), reason: '恢复默认同样只改草稿');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(
      await restored.deleteAccountAndRelatedEntries('reminder-account-2'),
      isNotNull,
    );
    await restored.waitForPendingWrites();
    final persisted = ReminderSettings.decode(
      store.read('verifin.reminder.v1'),
    );
    expect(restored.reminderSettings.repaymentTimeOverride(account.id), isNull);
    expect(
      restored.reminderSettings.repaymentAdvanceDaysOverride(account.id),
      isNull,
    );
    expect(persisted.repaymentTimeOverride(account.id), isNull);
    expect(persisted.repaymentAdvanceDaysOverride(account.id), isNull);
  });

  testWidgets('全局还款日期可单独修改，账户预览立刻跟随', (tester) async {
    final controller = await _makeFixture(enabled);
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    final defaultRow = find.widgetWithText(SettingsRow, '默认还款提醒日期');
    final statementRow = find.widgetWithText(SettingsRow, '账单日提醒日期');
    expect(
      find.descendant(of: defaultRow, matching: find.text('还款日当天')),
      findsOne,
    );
    expect(
      find.descendant(of: statementRow, matching: find.text('3 天前')),
      findsOne,
    );
    await tester.scrollUntilVisible(defaultRow, 120);
    await tester.tap(defaultRow);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '提前 2 天'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: statementRow, matching: find.text('3 天前')),
      findsOne,
    );
    await _showAccountStatus(tester);
    expect(find.text('默认 · 提前 2 天'), findsWidgets);
    expect(controller.reminderSettings.defaultRepaymentAdvanceDays, 0);
  });

  testWidgets('信用卡和信用平台显示最早提醒时间，空欠款保留暂无安排', (tester) async {
    final controller = await _makeFixture(enabled);
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _showAccountStatus(tester);
    expect(find.textContaining('21:00 · 还款日提醒'), findsWidgets);
    expect(find.textContaining('21:00 · 账单日提醒'), findsWidgets);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final emptyAccount = controller.creditAccounts.singleWhere(
      (item) => item.name == '美团月付',
    );
    final emptyCard = find.byKey(
      ValueKey('credit_reminder_${emptyAccount.id}'),
    );
    final emptyDateRow = find.descendant(
      of: emptyCard,
      matching: find.text('还款提醒日期'),
    );
    await tester.tap(emptyDateRow);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '还款日当天'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: emptyCard, matching: find.text('还款日当天')),
      findsOne,
    );
    expect(find.text('下次提醒：暂无定时安排'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'next-reminder-enabled');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未开启日期提醒时每个账户都有明确状态', (tester) async {
    final controller = await _makeFixture(
      const ReminderSettings(cycleBudgetEnabled: true),
    );
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await _showAccountStatus(tester);
    expect(find.text('下次提醒：未开启账单日或还款日提醒'), findsWidgets);
    expect(find.textContaining('21:00 ·'), findsNothing);
    await _capture(tester, 'next-reminder-disabled');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('修改开关即时预览并提示保存后生效，未保存不改变配置', (tester) async {
    final controller = await _makeFixture(enabled);
    addTearDown(controller.dispose);
    await _pumpPage(tester, controller);
    await tester.tap(find.byType(Switch).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(3));
    await tester.pumpAndSettle();
    await _showAccountStatus(tester);
    expect(find.text('以下提醒时间为设置预览，保存后生效。'), findsOneWidget);
    expect(find.text('下次提醒：未开启账单日或还款日提醒'), findsWidgets);
    expect(controller.reminderSettings, enabled);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final locale in [const Locale('zh'), const Locale('en')]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '下次提醒完整换行：${locale.languageCode}、${brightness.name}、360dp、1.5倍字号',
        (tester) async {
          final controller = await _makeFixture(enabled);
          addTearDown(controller.dispose);
          await _pumpPage(
            tester,
            controller,
            width: 360,
            locale: locale,
            brightness: brightness,
            scale: 1.5,
          );
          await _showAccountStatus(
            tester,
            english: locale.languageCode == 'en',
          );
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          expect(
            find.textContaining(
              locale.languageCode == 'en' ? 'Next reminder:' : '下次提醒：',
            ),
            findsWidgets,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
