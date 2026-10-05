import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/amount_format.dart' as money;
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/home_metrics.dart';
import 'package:verifin/app/ledger_math.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/home_page.dart';

HomeMetricContext _metrics(double amount) => HomeMetricContext(
  entries: [
    LedgerEntry(
      id: 'expense',
      bookId: 'book',
      type: EntryType.expense,
      amount: amount,
      accountId: '',
      categoryId: 'expense',
      note: '',
      occurredAt: DateTime(2026, 10, 5),
    ),
  ],
  accounts: const [],
  balanceOf: (_) => 0,
  now: DateTime(2026, 10, 5),
);

Widget _panelApp({
  required HomeMetricContext metrics,
  required double scale,
  required Locale locale,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: buildVeriFinTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: HomeTrendPanel(
          window: DateWindow(
            start: DateTime(2026, 10, 1),
            end: DateTime(2026, 10, 7),
          ),
          config: HomeTrendConfig.defaults,
          metricContext: metrics,
          chartValues: const [100, 100, 100, 200, 50, 0, 0],
          currencyCode: 'CNY',
          onTap: () {},
        ),
      ),
    ),
  ),
);

/// 检查实际排版和绘制边界；Text.data 完整并不能证明屏幕没有省略或裁切。
void _expectFullTextInside(WidgetTester tester, Finder scope, Rect bounds) {
  for (final element
      in find.descendant(of: scope, matching: find.byType(Text)).evaluate()) {
    final text = element.widget as Text;
    final paragraph = element.renderObject as RenderParagraph;
    expect(paragraph.didExceedMaxLines, isFalse, reason: '被省略：${text.data}');
    final finder = find.byElementPredicate((candidate) => candidate == element);
    final rect = tester.getRect(finder);
    expect(
      rect.left,
      greaterThanOrEqualTo(bounds.left - 0.5),
      reason: text.data,
    );
    expect(
      rect.right,
      lessThanOrEqualTo(bounds.right + 0.5),
      reason: text.data,
    );
    expect(rect.top, greaterThanOrEqualTo(bounds.top - 0.5), reason: text.data);
    expect(
      rect.bottom,
      lessThanOrEqualTo(bounds.bottom + 0.5),
      reason: text.data,
    );
  }
}

void main() {
  setUp(() {
    final previousUnit = money.moneyUnitStyle;
    final previousHide = money.hideUnitInSingleCurrency;
    final previousFraction = money.currencyFractionStyle;
    final previousBase = money.activeBaseCurrencyCode;
    money.moneyUnitStyle = MoneyUnitStyle.code;
    money.hideUnitInSingleCurrency = false;
    money.currencyFractionStyle = CurrencyFractionStyle.standard;
    money.activeBaseCurrencyCode = 'CNY';
    addTearDown(() {
      money.moneyUnitStyle = previousUnit;
      money.hideUnitInSingleCurrency = previousHide;
      money.currencyFractionStyle = previousFraction;
      money.activeBaseCurrencyCode = previousBase;
    });
  });

  const sizes = [
    Size(280, 653),
    Size(320, 568),
    Size(360, 800),
    Size(393, 852),
    Size(412, 915),
    Size(600, 960),
    Size(852, 393),
  ];
  for (final size in sizes) {
    for (final scale in [1.0, 2.0]) {
      for (final locale in [const Locale('zh'), const Locale('en')]) {
        for (final amount in [1265.59, 1234567890.12]) {
          testWidgets(
            '$size 字体 $scale ${locale.languageCode} 金额 $amount 显示完整',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = size;
              addTearDown(tester.view.reset);
              final metrics = _metrics(amount);
              await tester.pumpWidget(
                _panelApp(
                  metrics: metrics,
                  scale: scale,
                  locale: locale,
                  brightness: locale.languageCode == 'en'
                      ? Brightness.dark
                      : Brightness.light,
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              final primary = find.byKey(const Key('home_primary_metrics'));
              final bounds = tester.getRect(primary);
              _expectFullTextInside(tester, primary, bounds);
              expect(
                tester
                    .widget<Text>(find.byKey(const Key('home_primary_amount')))
                    .data,
                formatHomeMetric(HomeMetric.monthExpense, amount),
              );
              expect(
                tester
                    .widget<Text>(find.byKey(const Key('home_summary_amount')))
                    .data,
                formatHomeMetric(HomeMetric.monthNet, -amount),
              );
              expect(
                tester
                    .getRect(find.byKey(const Key('home_summary_pill')))
                    .right,
                closeTo(bounds.right, 0.5),
              );
              for (var index = 1; index <= 3; index++) {
                final tile = find.byKey(Key('home_metric_$index'));
                expect(tile, findsOneWidget);
                _expectFullTextInside(tester, tile, tester.getRect(tile));
              }
            },
          );
        }
      }
    }
  }

  testWidgets('空间不足时金额获得整行宽度，旋转后自动恢复并排', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _panelApp(
        metrics: _metrics(1265.59),
        scale: 2,
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    final amount = find.byKey(const Key('home_primary_amount'));
    final pill = find.byKey(const Key('home_summary_pill'));
    expect(
      tester.getRect(pill).top,
      greaterThan(tester.getRect(amount).bottom),
    );
    final firstTile = tester.getRect(find.byKey(const Key('home_metric_1')));
    final thirdTile = tester.getRect(find.byKey(const Key('home_metric_3')));
    expect(thirdTile.top, greaterThan(firstTile.top));
    // 测试字体的字形宽于手机字体；给足空间后才要求恢复并排。
    tester.view.physicalSize = const Size(1600, 600);
    await tester.pumpAndSettle();
    expect(tester.getRect(pill).top, lessThan(tester.getRect(amount).bottom));
    final primary = find.byKey(const Key('home_primary_metrics'));
    _expectFullTextInside(tester, primary, tester.getRect(primary));
    expect(tester.takeException(), isNull);
  });
}
