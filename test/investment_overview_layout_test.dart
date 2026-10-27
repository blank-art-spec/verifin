import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/investments/investment_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/test_harness.dart';

/// 将三地样例的 USD 双标的组合载入隔离控制器，供真实证券概览做布局验收。
/// [locale] 指定界面及金额格式语言；[openingCash] 非空时仅替换 USD 副本的期初现金，
/// 并显式允许融资，以覆盖合法的大额负现金。调用方负责释放返回的控制器。
Future<VeriFinController> _overviewController({
  Locale locale = const Locale('zh'),
  String? openingCash,
}) async {
  final root =
      jsonDecode(File('docs/dev/verifin-sample-backup.json').readAsStringSync())
          as Map<String, dynamic>;
  if (openingCash != null) {
    final data = root['data'] as Map<String, dynamic>;
    final portfolio =
        (data['investmentPortfolios'] as List).singleWhere(
              (portfolio) =>
                  (portfolio as Map)['accountId'] == 'acc_investment_usd',
            )
            as Map<String, dynamic>;
    portfolio['openingCash'] = openingCash;
    portfolio['allowFinancing'] = true;
  }
  final controller = await makeController();
  controller.importDataJson(jsonEncode(root));
  await controller.waitForPendingWrites();
  controller.switchLedgerBook('book_investment');
  controller.setLocalePreference(
    locale.languageCode == 'en' ? LocalePreference.en : LocalePreference.zh,
  );
  return controller;
}

/// 在指定逻辑宽度、字号、语言和主题下打开正式证券页。
/// [tester] 驱动组件树，[controller] 提供真实读取路径；[width] 与 [scale] 控制
/// 自适应布局，[locale] 与 [brightness] 检查中英文及浅深色。结束时恢复测试尺寸。
Future<void> _pumpOverview(
  WidgetTester tester,
  VeriFinController controller, {
  double width = 393,
  double scale = 1,
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
          child: const InvestmentPage(accountId: 'acc_investment_usd'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 按完整本地化 [label] 定位概览指标，避免误匹配持仓卡或投资记录中的文字。
Finder _overviewMetric(String label) => find.byWidgetPredicate(
  (widget) => widget is SummaryMetric && widget.label == label,
);

/// 核对 [metric] 内标签、完整金额和占比各自占据独立高度，没有互相覆盖。
/// [tester] 提供真实布局；同时检查段落未截断、可见字符绘制盒未越出可用宽度，
/// 以发现超长金额虽保留在 Text.data 中、实际绘制却被省略或裁切的问题。
void _expectCompleteMetric(WidgetTester tester, Finder metric) {
  final data = tester.widget<SummaryMetric>(metric);
  expect(data.allowValueWrap, isTrue);
  final label = find.descendant(of: metric, matching: find.text(data.label));
  final value = find.descendant(of: metric, matching: find.text(data.value));
  expect(label, findsOneWidget);
  expect(value, findsOneWidget);
  expect(
    tester.getRect(value).top,
    greaterThanOrEqualTo(tester.getRect(label).bottom),
  );
  final valueWidget = tester.widget<Text>(value);
  expect(valueWidget.maxLines, isNull);
  expect(valueWidget.overflow, isNot(TextOverflow.ellipsis));
  final paragraph = tester.renderObject<RenderParagraph>(value);
  expect(paragraph.didExceedMaxLines, isFalse);
  // 全选产生的是“选择背景矩形”，会把换行处没有可见字形的尾随空格也计入。
  // 居中排版时，这些空格的选择矩形可以超过段落宽度；逐个检查非空白码点，
  // 继续严格约束数字、正负号和币种符号，避免把选择背景误当成可见字符溢出。
  var textOffset = 0;
  var visibleCharacters = 0;
  for (final rune in data.value.runes) {
    final character = String.fromCharCode(rune);
    final nextOffset = textOffset + character.length;
    if (character.trim().isNotEmpty) {
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: textOffset, extentOffset: nextOffset),
      );
      final reason =
          '${data.label} / ${data.value} / 字符“$character”'
          '（U+${rune.toRadixString(16)}，偏移 $textOffset）'
          ' / 段落 ${paragraph.size}';
      expect(boxes, isNotEmpty, reason: reason);
      for (final box in boxes) {
        expect(box.left, greaterThanOrEqualTo(-1), reason: reason);
        expect(
          box.right,
          lessThanOrEqualTo(paragraph.size.width + 1),
          reason: reason,
        );
        expect(box.top, greaterThanOrEqualTo(-1), reason: reason);
        expect(
          box.bottom,
          lessThanOrEqualTo(paragraph.size.height + 1),
          reason: reason,
        );
      }
      visibleCharacters++;
    }
    textOffset = nextOffset;
  }
  expect(visibleCharacters, greaterThan(0), reason: '${data.label} 必须包含可见数值');
  if (data.detail != null) {
    final detail = find.descendant(
      of: metric,
      matching: find.text(data.detail!),
    );
    expect(detail, findsOneWidget);
    expect(
      tester.getRect(detail).top,
      greaterThanOrEqualTo(tester.getRect(value).bottom),
    );
    expect(tester.widget<Text>(detail).maxLines, isNull);
  }
  expect(tester.takeException(), isNull);
}

/// 读取包含 [metric] 的自适应指标组，检查配对关系与背景分组。
Finder _pairFor(Finder metric) => find
    .ancestor(of: metric, matching: find.byType(InvestmentMetricPair))
    .first;

/// 注册概览层级、自适应、完整金额及共享指标默认行为的回归。
/// 无参数、无返回值；只运行隔离组件测试，不连接模拟器或真实行情。
void main() {
  useTestDatabases();
  for (final scenario in [
    (
      locale: const Locale('zh'),
      width: 393.0,
      scale: 1.0,
      brightness: Brightness.light,
    ),
    (
      locale: const Locale('zh'),
      width: 360.0,
      scale: 1.5,
      brightness: Brightness.dark,
    ),
    (
      locale: const Locale('en'),
      width: 393.0,
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      locale: const Locale('en'),
      width: 360.0,
      scale: 1.5,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets(
      '证券概览分组与完整文字 ${scenario.locale} ${scenario.width} ${scenario.scale}',
      (tester) async {
        final controller = await _overviewController(locale: scenario.locale);
        addTearDown(controller.dispose);
        final before = jsonDecode(controller.exportDataJson()) as Map;
        before.remove('exportedAt');
        await _pumpOverview(
          tester,
          controller,
          width: scenario.width,
          scale: scenario.scale,
          locale: scenario.locale,
          brightness: scenario.brightness,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(InvestmentPage)),
        );
        final cash = _overviewMetric(l.investCash);
        final holdings = _overviewMetric(l.investLongValue);
        final market = _overviewMetric(l.investMarketValue);
        final short = _overviewMetric(l.investShortObligation);
        final realized = _overviewMetric(l.investRealized);
        final unrealized = _overviewMetric(l.investUnrealized);
        for (final metric in [
          cash,
          holdings,
          market,
          short,
          realized,
          unrealized,
        ]) {
          expect(metric, findsOneWidget);
          _expectCompleteMetric(tester, metric);
        }
        final cashRect = tester.getRect(cash);
        final holdingsRect = tester.getRect(holdings);
        if (scenario.scale > 1.4) {
          expect(holdingsRect.top, greaterThan(cashRect.bottom));
          expect(holdingsRect.left, closeTo(cashRect.left, 1));
          expect(holdingsRect.width, closeTo(cashRect.width, 1));
        } else {
          expect(holdingsRect.top, closeTo(cashRect.top, 1));
          expect(holdingsRect.left, greaterThan(cashRect.right));
          expect(holdingsRect.width, closeTo(cashRect.width, 1));
        }
        final cashPair = _pairFor(cash);
        final accountingPair = _pairFor(market);
        final profitPair = _pairFor(realized);
        expect(tester.widget<InvestmentMetricPair>(cashPair).filled, isTrue);
        expect(
          tester.widget<InvestmentMetricPair>(accountingPair).filled,
          isFalse,
        );
        expect(tester.widget<InvestmentMetricPair>(profitPair).filled, isFalse);
        expect(
          tester.getRect(accountingPair).top,
          greaterThanOrEqualTo(tester.getRect(cashPair).bottom),
        );
        expect(
          tester.getRect(profitPair).top,
          greaterThanOrEqualTo(tester.getRect(accountingPair).bottom),
        );
        expect(
          tester.widget<SummaryMetric>(cash).detail,
          '${l.investCashShare} 74.6%',
        );
        expect(
          tester.widget<SummaryMetric>(holdings).detail,
          '${l.investHoldingsShare} 25.4%',
        );
        final scroll = find
            .descendant(
              of: find.byType(InvestmentPage),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text(l.investIncome),
          200,
          scrollable: scroll,
        );
        expect(find.text(l.investIncome), findsOneWidget);
        expect(tester.takeException(), isNull);
        final after = jsonDecode(controller.exportDataJson()) as Map;
        after.remove('exportedAt');
        expect(after, before, reason: '浏览概览与自适应重排不能改账');
      },
    );
  }

  for (final opening in ['123456789012.34', '-123456789012.34']) {
    testWidgets('真实概览完整呈现大额现金与净值 $opening', (tester) async {
      final controller = await _overviewController(
        locale: const Locale('en'),
        openingCash: opening,
      );
      addTearDown(controller.dispose);
      await _pumpOverview(
        tester,
        controller,
        width: 360,
        scale: 1.5,
        locale: const Locale('en'),
      );
      final l = AppLocalizations.of(
        tester.element(find.byType(InvestmentPage)),
      );
      final cash = _overviewMetric(l.investCash);
      _expectCompleteMetric(tester, cash);
      final usd = controller.accounts.singleWhere(
        (account) => account.id == 'acc_investment_usd',
      );
      expect(controller.accountBalance(usd).abs(), greaterThan(100000000000));
      final netValue = formatUserMoney(
        controller.accountAssetValue(usd),
        'USD',
      );
      final hero = find.text(netValue);
      expect(hero, findsOneWidget);
      final heroText = tester.widget<Text>(hero);
      expect(heroText.style?.fontSize, 32);
      expect(heroText.maxLines, isNull);
      expect(heroText.overflow, isNot(TextOverflow.ellipsis));
      final paragraph = tester.renderObject<RenderParagraph>(hero);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('指标组按实际可用宽度切换，默认指标保留原单行省略行为', (tester) async {
    final theme = buildVeriFinTheme(Brightness.light);
    for (final width in [299.0, 300.0]) {
      await tester.pumpWidget(
        zhMaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: InvestmentMetricPair(
                  first: SummaryMetric(
                    label: '现金',
                    value: '123456789012.34 USD',
                    color: theme.colorScheme.onSurface,
                    allowValueWrap: true,
                  ),
                  second: SummaryMetric(
                    label: '多头持仓价值',
                    value: '-987654321098.76 USD',
                    color: theme.colorScheme.onSurface,
                    detail: '持仓占比 100.0%',
                    allowValueWrap: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = _overviewMetric('现金');
      final second = _overviewMetric('多头持仓价值');
      _expectCompleteMetric(tester, first);
      _expectCompleteMetric(tester, second);
      if (width < 300) {
        expect(
          tester.getRect(second).top,
          greaterThan(tester.getRect(first).bottom),
        );
      } else {
        expect(
          tester.getRect(second).top,
          closeTo(tester.getRect(first).top, 1),
        );
        expect(
          tester.getRect(second).left,
          greaterThan(tester.getRect(first).right),
        );
      }
    }
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 150,
            child: Row(
              children: [
                SummaryMetric(
                  label: '原有指标',
                  value: '123456789012.34 USD',
                  color: theme.colorScheme.onSurface,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final defaultMetric = _overviewMetric('原有指标');
    expect(tester.widget<SummaryMetric>(defaultMetric).allowValueWrap, isFalse);
    final defaultValue = find.descendant(
      of: defaultMetric,
      matching: find.text('123456789012.34 USD'),
    );
    expect(tester.widget<Text>(defaultValue).maxLines, 1);
    expect(tester.widget<Text>(defaultValue).overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
