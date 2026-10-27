import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/investments/investment_widgets.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/quote_format.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 在真实主题和本地化环境内挂载 [child]，由 [width]、[scale] 覆盖窄屏及大字号。
/// [locale] 决定标签和日期格式，[brightness] 检查浅深主题；结束时恢复测试尺寸。
Future<void> _pumpDetails(
  WidgetTester tester,
  Widget child, {
  required double width,
  required double scale,
  required Locale locale,
  required Brightness brightness,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildVeriFinTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 852),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: VeriCard(child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 核对 [details] 内全部文字完整绘制、无省略或固定行数限制，并处于信息区内。
/// [tester] 读取实际渲染尺寸；不以 Text.data 存在代替用户能够完整看见文字。
void _expectCompleteDetails(WidgetTester tester, Finder details) {
  final bounds = tester.getRect(details);
  final texts = find.descendant(of: details, matching: find.byType(Text));
  expect(texts, findsAtLeastNWidgets(3));
  for (final element in texts.evaluate()) {
    final finder = find.byElementPredicate(
      (value) => identical(value, element),
    );
    final widget = element.widget as Text;
    expect(widget.maxLines, isNull);
    expect(widget.overflow, isNot(TextOverflow.ellipsis));
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    expect(paragraph.didExceedMaxLines, isFalse);
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(bounds.left - 0.5));
    expect(rect.right, lessThanOrEqualTo(bounds.right + 0.5));
    expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + 0.5));
  }
  expect(tester.takeException(), isNull);
}

/// 创建只使用内存报价的真实持仓控制器，验证展示层仍遵循行情采用选择。
/// [fetchQuote] 为 false 时保留缺报价状态；[useMarket] 控制该证券是否显式采用行情。
/// 返回固定股票身份与可释放控制器，不连接真实来源、不修改设备或正式账目。
Future<({VeriFinController controller, String accountId})> _quotedController({
  bool fetchQuote = true,
  bool useMarket = true,
}) async {
  final adapter = FixtureQuoteAdapter(
    (_) async => [stockQuote(DateTime.now().toUtc())],
  );
  final controller = await VeriFinController.create(
    LocalKeyValueStore()..write('verifin.locale.v1', 'zh'),
    repository: InMemoryLedgerRepository(),
    marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
  );
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: DateTime(2026, 10, 1),
      securities: const [avgoFixture],
      openingHoldings: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '2',
          cost: '600',
        ),
      ],
      manualPrices: {avgoFixture.id: '300'},
    ),
    isTrue,
  );
  final sync = controller.investmentQuoteSync;
  expect(await sync.configure(enabled: true, automatic: false), isTrue);
  if (fetchQuote) {
    final portfolio = controller.investmentFor(account.id)!;
    sync.setVisible(portfolio);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
  }
  expect(
    await controller.setInvestmentMarketPrice(
      account.id,
      avgoFixture.id,
      useMarket,
    ),
    isTrue,
  );
  return (controller: controller, accountId: account.id);
}

/// 挂载 [controller] 中 [accountId] 的正式证券页，不通过独立演示界面验证布局。
/// 固定 393dp 中文环境，页面只读观察；测试结束时移除页面并恢复屏幕尺寸。
Future<void> _pumpInvestment(
  WidgetTester tester,
  VeriFinController controller,
  String accountId,
) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: buildVeriFinTheme(Brightness.light),
        home: InvestmentPage(accountId: accountId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 注册行情信息分区的阅读顺序、完整换行及时间格式；所有报价均来自本地夹具。
void main() {
  useTestDatabases();
  for (final scenario in [
    (locale: const Locale('zh'), width: 393.0, scale: 1.0, dark: false),
    (locale: const Locale('zh'), width: 360.0, scale: 1.5, dark: true),
    (locale: const Locale('en'), width: 393.0, scale: 1.0, dark: true),
    (locale: const Locale('en'), width: 360.0, scale: 1.5, dark: false),
  ]) {
    testWidgets(
      '行情来源信息完整换行 ${scenario.locale} ${scenario.width} ${scenario.scale}',
      (tester) async {
        const source =
            'Tencent Finance · Extended public reference quotation source';
        const time = '2026/10/27 16:14 CST';
        await _pumpDetails(
          tester,
          const InvestmentQuoteDetails(source: source, quoteTime: time),
          width: scenario.width,
          scale: scenario.scale,
          locale: scenario.locale,
          brightness: scenario.dark ? Brightness.dark : Brightness.light,
        );
        final details = find.byType(InvestmentQuoteDetails);
        final context = tester.element(details);
        final l = AppLocalizations.of(context);
        expect(find.text(source), findsOneWidget);
        expect(find.text(time), findsOneWidget);
        expect(find.text(l.marketQuoteTime), findsOneWidget);
        _expectCompleteDetails(tester, details);
      },
    );
  }

  for (final locale in [const Locale('zh'), const Locale('en')]) {
    testWidgets('紧凑报价日期保留年份时区，默认长日期不变 $locale', (tester) async {
      final time = DateTime(2026, 10, 27, 16, 14, 37);
      late String compact, compactSeconds, full, expectedFullDate, weekday;
      await _pumpDetails(
        tester,
        Builder(
          builder: (context) {
            compact = formatQuoteTime(context, time, compact: true);
            compactSeconds = formatQuoteTime(
              context,
              time,
              compact: true,
              includeSeconds: true,
            );
            full = formatQuoteTime(context, time);
            expectedFullDate = MaterialLocalizations.of(
              context,
            ).formatFullDate(time);
            weekday = DateFormat.EEEE(locale.toString()).format(time);
            return InvestmentQuoteDetails(
              source: 'Tencent Finance',
              quoteTime: compact,
            );
          },
        ),
        width: 393,
        scale: 1,
        locale: locale,
        brightness: Brightness.light,
      );
      expect(compact, contains('2026'));
      expect(compact, contains(time.timeZoneName));
      expect(compact, isNot(contains(weekday)));
      expect(compactSeconds, contains(':37'));
      expect(compact.length, lessThan(full.length));
      expect(full, contains(expectedFullDate));
      expect(full, contains(weekday));
      expect(full, contains(time.timeZoneName));
    });
  }

  testWidgets('正式持仓卡将来源放在盈亏后和操作前，改为手填后不展示缓存来源', (tester) async {
    final ready = await _quotedController();
    final controller = ready.controller;
    addTearDown(controller.dispose);
    await _pumpInvestment(tester, controller, ready.accountId);
    final details = find.byType(InvestmentQuoteDetails);
    await tester.scrollUntilVisible(
      details,
      180,
      scrollable: firstVerticalScrollable(),
      maxScrolls: 50,
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(details));
    final card = find
        .ancestor(of: details, matching: find.byType(VeriCard))
        .first;
    final pnl = find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DetailInfoRow && widget.label == l.investUnrealized,
      ),
    );
    final manualAction = find.descendant(
      of: card,
      matching: find.widgetWithText(TextButton, l.marketSetManual),
    );
    expect(details, findsOneWidget);
    expect(
      tester.getRect(details).top,
      greaterThanOrEqualTo(tester.getRect(pnl).bottom),
    );
    expect(
      tester.getRect(details).bottom,
      lessThanOrEqualTo(tester.getRect(manualAction).top),
    );
    _expectCompleteDetails(tester, details);
    expect(controller.accountAssetValue(controller.accounts.single), 10660);
    expect(
      controller.investmentFor(ready.accountId)!.manualPrices[avgoFixture.id],
      '300',
    );

    expect(
      await controller.setInvestmentMarketPrice(
        ready.accountId,
        avgoFixture.id,
        false,
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentQuoteDetails), findsNothing);
    expect(find.text('本地测试夹具'), findsNothing);
    expect(controller.accountAssetValue(controller.accounts.single), 10600);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采用行情但缺少有效报价时继续手填，不显示误导来源信息', (tester) async {
    final ready = await _quotedController(fetchQuote: false);
    final controller = ready.controller;
    addTearDown(controller.dispose);
    await _pumpInvestment(tester, controller, ready.accountId);
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
    await tester.scrollUntilVisible(
      find.text(l.marketNoQuote),
      180,
      scrollable: firstVerticalScrollable(),
      maxScrolls: 50,
    );
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentQuoteDetails), findsNothing);
    expect(find.text('本地测试夹具'), findsNothing);
    expect(controller.accountAssetValue(controller.accounts.single), 10600);
    expect(tester.takeException(), isNull);
  });
}
