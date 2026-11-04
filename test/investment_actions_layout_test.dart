import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/fund_entry_page.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/option_editor_page.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

const _emptyFund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

const _actionKeys = [
  'investment-stock-action',
  'fund-operations',
  'investment-option-action',
  'investment-cash-action',
];

/// 建立只含现金的真实证券组合；可加入已存资料但没有持仓的基金，检查额外入口位置。
Future<VeriFinController> _controller({bool emptyFund = false}) async {
  final controller = await makeController();
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '1000',
      openedAt: DateTime(2026, 10, 1),
      securities: emptyFund ? [_emptyFund] : [],
    ),
    isTrue,
  );
  addTearDown(controller.dispose);
  return controller;
}

/// 使用正式页面和主题，按实际屏宽、字号和语言核对操作区。
Future<void> _pumpActions(
  WidgetTester tester,
  VeriFinController controller, {
  double width = 393,
  double scale = 1,
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  controller.setLocalePreference(
    locale.languageCode == 'en' ? LocalePreference.en : LocalePreference.zh,
  );
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildVeriFinTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 852),
            textScaler: TextScaler.linear(scale),
          ),
          child: const InvestmentPage(accountId: 'stock-usd'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _reveal(tester, find.byKey(const Key('investment-primary-actions')));
}

/// 保留复用基金菜单的外层 key，同时定位真实的按钮触控区域。
Finder _action(String key) => find.descendant(
  of: find.byKey(Key(key)),
  matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  matchRoot: true,
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: find
        .descendant(
          of: find.byType(InvestmentPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

/// 断言完整文案实际绘制在按钮内，不只检查 Text.data 中保留了字符串。
void _expectReadable(WidgetTester tester, Finder button, String label) {
  expect(button, findsOneWidget);
  final bounds = tester.getRect(button);
  expect(bounds.height, greaterThanOrEqualTo(48));
  final labelFinder = find.descendant(of: button, matching: find.text(label));
  expect(labelFinder, findsOneWidget);
  final labelBounds = tester.getRect(labelFinder);
  expect(labelBounds.left, greaterThanOrEqualTo(bounds.left));
  expect(labelBounds.right, lessThanOrEqualTo(bounds.right));
  expect(labelBounds.top, greaterThanOrEqualTo(bounds.top));
  expect(labelBounds.bottom, lessThanOrEqualTo(bounds.bottom));
  expect(
    tester.widget<Text>(labelFinder).overflow,
    isNot(TextOverflow.ellipsis),
  );
  final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
  expect(paragraph.didExceedMaxLines, isFalse);
}

/// 四个主要操作按业务顺序固定为两行，行内等高、列宽一致，行列间距保留。
void _expectTwoRows(WidgetTester tester) {
  final rects = _actionKeys.map((key) => tester.getRect(_action(key))).toList();
  for (final rect in rects.skip(1)) {
    expect(rect.width, closeTo(rects.first.width, 1));
  }
  for (final row in [0, 2]) {
    expect(rects[row + 1].top, closeTo(rects[row].top, 1));
    expect(rects[row + 1].height, closeTo(rects[row].height, 1));
    expect(rects[row + 1].left, greaterThan(rects[row].right));
  }
  expect(rects[2].top, greaterThan(rects[0].bottom));
  expect(rects[2].left, closeTo(rects[0].left, 1));
  expect(rects[3].right, closeTo(rects[1].right, 1));
}

void main() {
  useTestDatabases();
  for (final scenario in [
    (width: 393.0, scale: 1.0, locale: const Locale('zh')),
    (width: 360.0, scale: 1.0, locale: const Locale('zh')),
    (width: 320.0, scale: 1.0, locale: const Locale('zh')),
    (width: 393.0, scale: 1.5, locale: const Locale('zh')),
    (width: 360.0, scale: 1.5, locale: const Locale('zh')),
    (width: 320.0, scale: 1.5, locale: const Locale('zh')),
    (width: 360.0, scale: 1.5, locale: const Locale('en')),
  ]) {
    testWidgets(
      '证券四操作两行等宽且文案完整 ${scenario.width} ${scenario.scale} ${scenario.locale}',
      (tester) async {
        final controller = await _controller();
        await _pumpActions(
          tester,
          controller,
          width: scenario.width,
          scale: scenario.scale,
          locale: scenario.locale,
          brightness: scenario.scale == 1.5
              ? Brightness.dark
              : Brightness.light,
        );
        _expectTwoRows(tester);
        final l = AppLocalizations.of(
          tester.element(find.byType(InvestmentPage)),
        );
        final labels = [
          l.investNewTrade,
          l.fundOperations,
          l.optionTitle,
          l.investCashCheck,
        ];
        for (var index = 0; index < _actionKeys.length; index++) {
          _expectReadable(tester, _action(_actionKeys[index]), labels[index]);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('无持仓基金的额外入口位于四个主要操作之后', (tester) async {
    final controller = await _controller(emptyFund: true);
    await _pumpActions(tester, controller, width: 320, scale: 1.5);
    _expectTwoRows(tester);
    final extra = find.byKey(ValueKey('fund-trade-${_emptyFund.id}'));
    expect(extra, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('investment-primary-actions')),
        matching: extra,
      ),
      findsNothing,
    );
    expect(
      tester.getRect(extra).top,
      greaterThanOrEqualTo(
        tester.getRect(_action('investment-cash-action')).bottom,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('四个主要操作仍打开对应入口，取消不改账', (tester) async {
    final controller = await _controller();
    await _pumpActions(tester, controller, width: 360);
    final before = jsonDecode(controller.exportDataJson()) as Map;
    before.remove('exportedAt');
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));

    await tester.tap(_action('investment-stock-action'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionEntryPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(TransactionEntryPage))).pop();
    await tester.pumpAndSettle();

    await _reveal(tester, _action('fund-operations'));
    await tester.tap(_action('fund-operations'));
    await tester.pumpAndSettle();
    expect(find.text(l.fundBuyByAmount), findsOneWidget);
    expect(find.text(l.fundRecordHolding), findsOneWidget);
    await tester.tap(find.text(l.fundBuyByAmount));
    await tester.pumpAndSettle();
    expect(find.byType(FundEntryPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(FundEntryPage))).pop();
    await tester.pumpAndSettle();

    await _reveal(tester, _action('investment-option-action'));
    await tester.tap(_action('investment-option-action'));
    await tester.pumpAndSettle();
    expect(find.byType(OptionEditorPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(OptionEditorPage))).pop();
    await tester.pumpAndSettle();

    await _reveal(tester, _action('investment-cash-action'));
    await tester.tap(_action('investment-cash-action'));
    await tester.pumpAndSettle();
    expect(find.text(l.investCashHint), findsOneWidget);
    await tester.tap(find.text(l.commonCancel));
    await tester.pumpAndSettle();
    final after = jsonDecode(controller.exportDataJson()) as Map;
    after.remove('exportedAt');
    expect(after, before);
    expect(tester.takeException(), isNull);
  });
}
