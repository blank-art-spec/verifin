import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/entry_sheets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 创建真实证券账户作为版式输入；长名称属于用户资料，不从本地化文案截短。
Future<({VeriFinController controller, Account account})> _layoutController(
  Locale locale,
) async {
  final controller = await makeController();
  controller.setLocalePreference(
    locale.languageCode == 'en' ? LocalePreference.en : LocalePreference.zh,
  );
  final account = investmentAccountFixture().copyWith(
    name: locale.languageCode == 'en'
        ? 'International securities account two'
        : '长期投资证券账户二',
  );
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
    ),
    isTrue,
  );
  return (controller: controller, account: account);
}

/// 用真实主题、本地化和系统安全区挂载实际新增页，保留真实窗口键盘 inset。
Future<void> _pumpLayout(
  WidgetTester tester,
  VeriFinController controller,
  String accountId, {
  required double width,
  required double scale,
  required Locale locale,
  required Brightness brightness,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 852);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildVeriFinTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: TransactionEntryPage(
          bookId: controller.activeBook.id,
          initialAccountId: accountId,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 检查完整文本实际绘制而非只保存在 Text.data 中；不允许行数裁切或可见字符越出宽度。
/// 整段选择框可能包含换行尾空白，故逐个可见字符检查，并在失败时报告具体字符和位置。
void _expectCompleteParagraph(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(paragraph.didExceedMaxLines, isFalse);
  final plainText = paragraph.text.toPlainText();
  expect(plainText, isNotEmpty);
  var offset = 0;
  for (final rune in plainText.runes) {
    final character = String.fromCharCode(rune);
    final end = offset + character.length;
    if (character.trim().isNotEmpty) {
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: offset, extentOffset: end),
      )) {
        final reason =
            '可见字符“$character”位于 $offset，全文“$plainText”，'
            '段落宽 ${paragraph.size.width}，字符框 $box';
        expect(box.left, greaterThanOrEqualTo(-1), reason: reason);
        expect(
          box.right,
          lessThanOrEqualTo(paragraph.size.width + 1),
          reason: reason,
        );
      }
    }
    offset = end;
  }
}

/// 保存位于 Scaffold 的可调整 body 中；系统键盘出现后仍须在可见窗口及安全区内。
Future<void> _expectSaveAboveKeyboard(WidgetTester tester) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  tester.view.padding = const FakeViewPadding(top: 24);
  await tester.pumpAndSettle();
  final save = find.byKey(const Key('transaction-save-current'));
  expect(save.hitTestable(), findsOneWidget);
  final rect = tester.getRect(save);
  expect(rect.height, greaterThanOrEqualTo(40));
  expect(rect.top, greaterThanOrEqualTo(24));
  expect(rect.bottom, lessThanOrEqualTo(852 - 300));
  expect(tester.takeException(), isNull);
}

/// 手动新增金额仍走既有计算器；以较长合法原币金额检查明细渲染，不直接注入表单状态。
Future<void> _enterLargeAmount(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('detail_amount_button')));
  await tester.pumpAndSettle();
  expect(find.byType(NumberPadSheet), findsOneWidget);
  await tester.tap(find.byKey(const Key('number_key_C')));
  for (final digit in '1234567.89'.split('')) {
    await tester.tap(find.byKey(Key('number_key_$digit')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('number_pad_ok')));
  await tester.pumpAndSettle();
  expect(find.byType(NumberPadSheet), findsNothing);
}

void main() {
  useTestDatabases();
  for (final settings in [
    (
      width: 393.0,
      brightness: Brightness.light,
      locale: const Locale('zh'),
      scale: 1.0,
    ),
    (
      width: 360.0,
      brightness: Brightness.dark,
      locale: const Locale('en'),
      scale: 1.5,
    ),
  ]) {
    testWidgets(
      '投资表单 ${settings.width} ${settings.brightness} ${settings.locale} '
      '${settings.scale} 完整显示账户并在键盘上方保存',
      (tester) async {
        final fixture = await _layoutController(settings.locale);
        addTearDown(fixture.controller.dispose);
        await _pumpLayout(
          tester,
          fixture.controller,
          fixture.account.id,
          width: settings.width,
          brightness: settings.brightness,
          locale: settings.locale,
          scale: settings.scale,
        );
        final context = tester.element(find.byType(TransactionEntryPage));
        final l = AppLocalizations.of(context);
        expect(Theme.of(context).brightness, settings.brightness);
        expect(Localizations.localeOf(context), settings.locale);
        expect(
          find.byKey(const ValueKey('transaction-mode-investment')),
          findsOneWidget,
        );
        final accountLabel = find.descendant(
          of: find.byKey(const Key('transaction-investment-account')),
          matching: find.text('${fixture.account.name} · USD'),
        );
        _expectCompleteParagraph(tester, accountLabel);
        expect(
          tester.getRect(find.text(l.entryNewRecord)).top,
          greaterThanOrEqualTo(24),
        );
        expect(find.byType(Scaffold), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('stock-symbol')),
          'AVGO',
        );
        await _expectSaveAboveKeyboard(tester);
        final scroll = find
            .descendant(
              of: find.byType(StockEditorPage),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('stock-reference')),
          200,
          scrollable: scroll,
        );
        expect(tester.takeException(), isNull);
        expect(
          fixture.controller.investmentFor(fixture.account.id)!.events,
          isEmpty,
        );
      },
    );
  }

  testWidgets('普通表单393英文浅色1.5字号完整显示大金额，键盘不盖住保存', (tester) async {
    const locale = Locale('en');
    final fixture = await _layoutController(locale);
    addTearDown(fixture.controller.dispose);
    await _pumpLayout(
      tester,
      fixture.controller,
      fixture.account.id,
      width: 393,
      brightness: Brightness.light,
      locale: locale,
      scale: 1.5,
    );
    final l = AppLocalizations.of(
      tester.element(find.byType(TransactionEntryPage)),
    );
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const Key('transaction-entry-mode')),
            matching: find.text(l.entryModeGeneral),
          )
          .hitTestable()
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('transaction-mode-general')),
      findsOneWidget,
    );
    await _enterLargeAmount(tester);
    final amountText = find.descendant(
      of: find.byKey(const Key('detail_amount_button')),
      matching: find.byType(Text),
    );
    final amount = tester.widget<Text>(amountText).data!;
    expect(amount.replaceAll(',', ''), contains('1234567.89'));
    _expectCompleteParagraph(tester, amountText);
    expect(tester.takeException(), isNull);
    await _expectSaveAboveKeyboard(tester);
    final note = find.byKey(const Key('entry_note_field'));
    await tester.scrollUntilVisible(
      note,
      200,
      scrollable: find
          .descendant(
            of: find.byType(EntryDetailPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(note, 'Unsaved investment ledger bookkeeping draft');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('transaction-save-current')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(fixture.controller.entries, isEmpty);
  });
}
