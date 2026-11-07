import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_opening_draft.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/security_search.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/investments/us_option_symbol.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/option_editor_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/option_editor_harness.dart';
import 'support/test_harness.dart';

/// 只记录公开标的检索参数；测试明确完成请求，不访问真实网络。
class _SearchClient extends SecuritySearchClient {
  final requests =
      <
        ({
          String query,
          StockMarket market,
          String currency,
          Completer<List<StockSecurity>> result,
        })
      >[];

  @override
  Future<List<StockSecurity>> search(
    String query, {
    required StockMarket market,
    required String currencyCode,
  }) {
    final result = Completer<List<StockSecurity>>();
    requests.add((
      query: query,
      market: market,
      currency: currencyCode,
      result: result,
    ));
    return result.future;
  }
}

Future<VeriFinController> _ready(
  _SearchClient search, {
  bool opening = false,
  bool local = false,
  MarketQuoteClient quotes = const MarketQuoteClient(),
}) async {
  final c = await VeriFinController.create(
    LocalKeyValueStore()..write('verifin.locale.v1', 'zh'),
    repository: InMemoryLedgerRepository(),
    securitySearchClient: search,
    marketQuoteClient: quotes,
  );
  addTearDown(c.dispose);
  c.addAccount(investmentAccountFixture());
  await c.waitForPendingWrites();
  if (!opening) {
    expect(
      await c.enableInvestment(
        accountId: 'stock-usd',
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: local ? [avgoFixture] : [],
        manualPrices: local ? {avgoFixture.id: '330'} : {},
      ),
      isTrue,
    );
  }
  return c;
}

Finder _scroll() => find
    .descendant(
      of: find.byType(OptionEditorPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 先展开实际字段分组再读取控制器；[up] 保留旧调用语义，定位统一从页首开始。
Future<TextEditingController> _field(
  WidgetTester tester,
  String field, {
  bool up = false,
}) async {
  final input = await revealOptionEditorField(tester, field);
  return tester.widget<TextField>(input).controller!;
}

Future<void> _enter(
  WidgetTester tester,
  String field,
  String value, {
  bool up = false,
}) async {
  await _field(tester, field, up: up);
  await tester.enterText(find.byKey(ValueKey('option-$field')), value);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

/// 标的搜索位于合约详情内，必须先通过展开入口才能主动联网。
Future<void> _search(WidgetTester tester) async {
  await expandOptionEditorSection(tester, 'details');
  final button = find.byKey(const Key('option-underlying-search-online'));
  await revealOptionEditorTarget(tester, button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, StockSecurity security) async {
  await _field(tester, 'underlying', up: true);
  await tester.tap(find.byKey(const ValueKey('option-underlying')));
  await tester.pumpAndSettle();
  final candidate = find.byKey(ValueKey('investment-security-${security.id}'));
  expect(candidate, findsOneWidget);
  await tester.tap(candidate);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  VeriFinController c, {
  String? securityId,
  ValueNotifier<bool>? visible,
  InvestmentPortfolio? openingPortfolio,
  Locale? locale,
  double scale = 1,
  Size size = const Size(393, 852),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final page = OptionEditorPage(
    accountId: 'stock-usd',
    securityId: securityId,
    openingPortfolio: openingPortfolio,
  );
  await tester.pumpWidget(
    VeriFinScope(
      controller: c,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: locale,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: visible == null
                  ? page
                  : ValueListenableBuilder<bool>(
                      valueListenable: visible,
                      builder: (context, shown, child) => Visibility(
                        visible: shown,
                        maintainState: true,
                        child: child!,
                      ),
                      child: page,
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, {bool preview = false}) async {
  if (preview) {
    final button = find.widgetWithText(OutlinedButton, '预览结算后现金与持仓');
    await tester.scrollUntilVisible(button, 240, scrollable: _scroll());
    await tester.tap(button);
    await tester.pumpAndSettle();
  }
  final save = find.widgetWithText(FilledButton, '保存');
  await tester.scrollUntilVisible(save, 240, scrollable: _scroll());
  await tester.pumpAndSettle();
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  expect(save.hitTestable(), findsOneWidget);
  expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

/// 合约查询与采用分别由用户触发，未完成的响应仍由用例控制。
Future<void> _contractAction(WidgetTester tester, String action) async {
  final button = find.byKey(ValueKey('option-contract-$action'));
  await revealOptionEditorTarget(tester, button);
  expect(button.hitTestable(), findsOneWidget);
  await tester.tap(button);
  await tester.pump();
}

/// 只构造本地期权报价，买卖中间价与最新成交价刻意不同以验证采用口径。
/// [delayed] 为 true 时只有至少延迟二十分钟的成交，用于验证免费模式提示与采用口径。
MarketQuote _contractQuote(MarketQuoteRequest request, {bool delayed = false}) {
  final time = DateTime.now().subtract(Duration(minutes: delayed ? 20 : 2));
  return MarketQuote(
    securityId: request.securityId,
    source: '本地测试夹具',
    currency: 'USD',
    unit: QuotePriceUnit.premiumUnit,
    fetchedAt: DateTime.now(),
    last: '2.9',
    lastAt: time,
    bid: delayed ? null : '3',
    bidAt: delayed ? null : time,
    ask: delayed ? null : '3.4',
    askAt: delayed ? null : time,
    delayMinutes: delayed ? 15 : null,
  );
}

/// 完成一次本地名称和报价响应；采用仍通过独立的页面按钮。
Future<void> _completeContractSearch(
  WidgetTester tester,
  _SearchClient search, {
  bool adopt = true,
}) async {
  await _contractAction(tester, 'search');
  search.requests.last.result.complete([avgoFixture]);
  await tester.pumpAndSettle();
  if (adopt) {
    await _contractAction(tester, 'use-price');
    await tester.pumpAndSettle();
  }
}

void main() {
  useTestDatabases();

  for (final opening in [false, true]) {
    testWidgets('${opening ? '期初' : '交易'}行情查询不猜乘数，手填小数乘数及成交成本保持', (
      tester,
    ) async {
      final search = _SearchClient();
      final adapter = FixtureQuoteAdapter(
        (requests) async => requests.map(_contractQuote).toList(),
        support: (request) => request.option,
      );
      final c = await _ready(
        search,
        opening: opening,
        quotes: MarketQuoteClient(adapters: [adapter]),
      );
      await c.investmentQuoteSync.configure(enabled: true, automatic: false);
      final before = c.investmentFor('stock-usd')?.toJson();
      await _pump(
        tester,
        c,
        openingPortfolio: opening
            ? InvestmentPortfolio(
                accountId: 'stock-usd',
                bookId: c.activeBook.id,
                currencyCode: 'USD',
                openedAt: DateTime(2026, 10, 1),
                openingCash: '10000',
              )
            : null,
      );
      await _enter(tester, 'symbol', 'SOFX261218P00009000');
      await _enter(tester, opening ? 'cost' : 'price', '2.15');
      expect((await _field(tester, 'multiplier')).text, isEmpty);
      await _completeContractSearch(tester, search, adopt: false);
      expect((await _field(tester, 'multiplier')).text, isEmpty);
      await _enter(tester, 'multiplier', '12.5');
      await _completeContractSearch(tester, search, adopt: false);
      expect((await _field(tester, 'multiplier')).text, '12.5');
      expect((await _field(tester, opening ? 'cost' : 'price')).text, '2.15');
      expect((await _field(tester, 'reference')).text, isEmpty);
      expect(
        find.byKey(const ValueKey('option-contract-use-multiplier')),
        findsNothing,
      );
      expect(c.investmentFor('stock-usd')?.toJson(), before);
      expect(c.investmentQuoteSync.state.value.automatic, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('英文窄屏大字号显示手填乘数说明，查询不改乘数与成交价', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests.map(_contractQuote).toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(
      tester,
      c,
      locale: const Locale('en'),
      scale: 1.6,
      size: const Size(360, 852),
    );
    await _enter(tester, 'symbol', 'SOFX261218P00009000');
    await _enter(tester, 'multiplier', '2.15');
    await _enter(tester, 'price', '2.15');
    await _completeContractSearch(tester, search, adopt: false);
    expect((await _field(tester, 'multiplier')).text, '2.15');
    expect(find.textContaining('Enter it manually'), findsOneWidget);
    expect((await _field(tester, 'price')).text, '2.15');
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询期间手填乘数不受迟到报价影响，换代码和行权价仍保留', (tester) async {
    final search = _SearchClient();
    final release = Completer<void>();
    final adapter = FixtureQuoteAdapter((requests) async {
      await release.future;
      return requests.map(_contractQuote).toList();
    }, support: (request) => request.option);
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'SOFX261218P00009000');
    await _contractAction(tester, 'search');
    await _enter(tester, 'multiplier', '10');
    search.requests.single.result.complete([]);
    release.complete();
    await tester.pumpAndSettle();
    expect((await _field(tester, 'multiplier')).text, '10');
    await _enter(tester, 'strike', '11');
    expect((await _field(tester, 'multiplier')).text, '10');
    await _enter(tester, 'symbol', 'SOFX261218P00011000');
    expect((await _field(tester, 'multiplier')).text, '10');
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有合约乘数锁定，行情查询不会修改历史定价身份', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests.map(_contractQuote).toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    final option = StockSecurity(
      symbol: 'AVGO261218C00050000',
      name: '本地合约锁定夹具',
      market: StockMarket.us,
      currencyCode: 'USD',
      option: optionFixture(multiplier: '10').option,
    );
    expect(
      await c.saveOptionEvent(
        accountId: 'stock-usd',
        security: option,
        underlying: avgoFixture,
        event: optionEventFixture(option, StockEventKind.optionBuyOpen),
        referencePrice: '3',
        underlyingReferencePrice: '50',
      ),
      isTrue,
    );
    final before = c.investmentFor('stock-usd')!.toJson();
    await _pump(tester, c, securityId: option.id);
    await _completeContractSearch(tester, search, adopt: false);
    expect((await _field(tester, 'multiplier')).text, '10');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('option-multiplier')))
          .readOnly,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('option-contract-use-multiplier')),
      findsNothing,
    );
    expect(c.investmentFor('stock-usd')!.toJson(), before);
    expect(tester.takeException(), isNull);
  });
  for (final opening in [false, true]) {
    testWidgets('${opening ? '期初' : '交易'}期权显式查询完整代码，报价须另行采用且不改持仓事实', (
      tester,
    ) async {
      final search = _SearchClient();
      final release = Completer<void>();
      final adapter = FixtureQuoteAdapter((requests) async {
        await release.future;
        return requests.map(_contractQuote).toList();
      }, support: (request) => request.option);
      final c = await _ready(
        search,
        opening: opening,
        quotes: MarketQuoteClient(adapters: [adapter]),
      );
      expect(
        await c.investmentQuoteSync.configure(enabled: true, automatic: false),
        isTrue,
      );
      final before = c.investmentFor('stock-usd')?.toJson();
      await _pump(
        tester,
        c,
        openingPortfolio: opening
            ? InvestmentPortfolio(
                accountId: 'stock-usd',
                bookId: c.activeBook.id,
                currencyCode: 'USD',
                openedAt: DateTime(2026, 10, 1),
                openingCash: '10000',
              )
            : null,
      );
      await _enter(tester, 'symbol', 'AVGO261218P00300000');
      await _enter(tester, 'multiplier', '10');
      await _enter(tester, 'quantity', '2');
      await _enter(tester, opening ? 'cost' : 'price', opening ? '175' : '2');
      await _enter(tester, 'reference', '1.25');
      expect(
        find.byKey(const ValueKey('option-underlyingPrice')),
        findsNothing,
      );
      expect(search.requests, isEmpty);
      expect(adapter.requests, 0);

      await _contractAction(tester, 'search');
      expect(search.requests, hasLength(1));
      expect(search.requests.single.query, 'AVGO');
      search.requests.single.result.complete([avgoFixture]);
      release.complete();
      await tester.pumpAndSettle();

      expect(adapter.requests, 1);
      final request = adapter.lastRequests.single;
      expect(request.symbol, 'AVGO261218P00300000');
      expect(request.optionUnderlyingSymbol, 'AVGO');
      expect(request.optionExpiry, '2026-12-18');
      expect(request.optionRight, OptionRight.put);
      expect(request.optionStrike, '300');
      expect(find.textContaining('本地测试夹具'), findsWidgets);
      final name = (await _field(tester, 'name')).text;
      expect(name, contains('博通'));
      expect(name, contains('300'));
      expect(name, contains('认沽'));
      expect((await _field(tester, 'underlying')).text, 'AVGO');
      expect((await _field(tester, 'underlyingName')).text, '博通');
      expect((await _field(tester, 'strike')).text, '300');
      expect((await _field(tester, 'multiplier')).text, '10');
      await expandOptionEditorSection(tester, 'settlement');
      expect(find.text('非标准 / 待补全'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '已核对结算方式、交割规格及原币金额'),
            )
            .value,
        isFalse,
      );
      expect((await _field(tester, 'quantity')).text, '2');
      expect(
        (await _field(tester, opening ? 'cost' : 'price')).text,
        opening ? '175' : '2',
      );
      expect((await _field(tester, 'reference')).text, '1.25');
      expect(
        find.byKey(const ValueKey('option-underlyingPrice')),
        findsNothing,
      );

      await _contractAction(tester, 'use-price');
      await tester.pumpAndSettle();
      expect((await _field(tester, 'reference')).text, '3.2');
      expect(c.investmentFor('stock-usd')?.toJson(), before);
      expect(c.investmentQuoteSync.state.value.automatic, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('合约查询保留用户名称及查询期间的新名称', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests.map(_contractQuote).toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _enter(tester, 'name', '我的期权名称');
    await _contractAction(tester, 'search');
    await _enter(tester, 'name', '查询时修改的名称');
    search.requests.single.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    expect((await _field(tester, 'name', up: true)).text, '查询时修改的名称');
    expect((await _field(tester, 'underlyingName')).text, '博通');
    expect((await _field(tester, 'reference')).text, isEmpty);
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同合约只重查未再次采用，改代码仍清除先前采用的报价', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests.map(_contractQuote).toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _completeContractSearch(tester, search);
    expect((await _field(tester, 'reference')).text, '3.2');

    await _completeContractSearch(tester, search, adopt: false);
    expect(adapter.requests, 2);
    expect((await _field(tester, 'reference')).text, '3.2');
    await _enter(tester, 'symbol', 'MSFT261218C00400000', up: true);
    expect((await _field(tester, 'reference')).text, isEmpty);
    expect(
      find.byKey(const ValueKey('option-contract-use-price')),
      findsNothing,
    );
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修改行权价清除采用的旧报价，手填新参考价后改代码保留手填', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests.map(_contractQuote).toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _completeContractSearch(tester, search);
    expect((await _field(tester, 'reference')).text, '3.2');
    await _enter(tester, 'strike', '310', up: true);
    expect((await _field(tester, 'reference')).text, isEmpty);
    expect(
      find.byKey(const ValueKey('option-contract-use-price')),
      findsNothing,
    );

    await _enter(tester, 'strike', '300', up: true);
    await _completeContractSearch(tester, search);
    expect((await _field(tester, 'reference')).text, '3.2');
    await _enter(tester, 'reference', '7');
    await _enter(tester, 'symbol', 'MSFT261218C00400000', up: true);
    expect((await _field(tester, 'reference')).text, '7');
    expect(
      find.byKey(const ValueKey('option-contract-use-price')),
      findsNothing,
    );
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手填行权价与代码冲突时查询保留输入并禁用采用报价', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests.map(_contractQuote).toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _enter(tester, 'strike', '99');
    await _enter(tester, 'reference', '5');
    await _completeContractSearch(tester, search, adopt: false);
    final adopt = find.byKey(const ValueKey('option-contract-use-price'));
    await tester.ensureVisible(adopt);
    expect(tester.widget<OutlinedButton>(adopt).onPressed, isNull);
    expect((await _field(tester, 'strike')).text, '99');
    expect((await _field(tester, 'reference')).text, '5');
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文窄屏大字号显示延迟成交说明并采用成交价，无布局溢出', (tester) async {
    final search = _SearchClient();
    final adapter = FixtureQuoteAdapter(
      (requests) async => requests
          .map((request) => _contractQuote(request, delayed: true))
          .toList(),
      support: (request) => request.option,
    );
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(
      tester,
      c,
      locale: const Locale('en'),
      scale: 1.6,
      size: const Size(360, 852),
    );
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _completeContractSearch(tester, search, adopt: false);
    expect(find.textContaining('本地测试夹具'), findsWidgets);
    expect(find.textContaining('At least 15 minutes delayed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _contractAction(tester, 'use-price');
    await tester.pumpAndSettle();
    expect((await _field(tester, 'reference')).text, '2.9');
    expect((await _field(tester, 'name', up: true)).text, contains('Put'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('改合约代码后旧名称和旧报价晚响应不能覆盖当前草稿', (tester) async {
    final search = _SearchClient();
    final release = Completer<void>();
    final adapter = FixtureQuoteAdapter((requests) async {
      await release.future;
      return requests.map(_contractQuote).toList();
    }, support: (request) => request.option);
    final c = await _ready(
      search,
      quotes: MarketQuoteClient(adapters: [adapter]),
    );
    await c.investmentQuoteSync.configure(enabled: true, automatic: false);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _contractAction(tester, 'search');
    await _enter(tester, 'symbol', 'MSFT261218C00400000', up: true);
    await _enter(tester, 'name', '微软新草稿');
    await _enter(tester, 'underlying', 'MSFT');
    await _enter(tester, 'underlyingName', '微软');
    await _enter(tester, 'strike', '400');
    await _enter(tester, 'reference', '7');
    search.requests.single.result.complete([avgoFixture]);
    release.complete();
    await tester.pumpAndSettle();
    expect(
      (await _field(tester, 'symbol', up: true)).text,
      'MSFT261218C00400000',
    );
    expect((await _field(tester, 'name')).text, '微软新草稿');
    expect((await _field(tester, 'underlying')).text, 'MSFT');
    expect((await _field(tester, 'underlyingName')).text, '微软');
    expect((await _field(tester, 'strike')).text, '400');
    expect((await _field(tester, 'reference')).text, '7');
    expect(
      find.byKey(const ValueKey('option-contract-use-price')),
      findsNothing,
    );
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final enabled in [false, true]) {
    testWidgets('期权行情${enabled ? '权限拒绝' : '联网未开启'}仍保留手填名称与价格', (tester) async {
      final search = _SearchClient();
      final adapter = FixtureQuoteAdapter(
        (_) async => throw StateError('模拟来源拒绝行情权限'),
        support: (request) => request.option,
      );
      final c = await _ready(
        search,
        quotes: MarketQuoteClient(adapters: [adapter]),
      );
      if (enabled) {
        await c.investmentQuoteSync.configure(enabled: true, automatic: false);
      }
      await _pump(tester, c);
      await _enter(tester, 'symbol', 'AVGO261218P00300000');
      await _enter(tester, 'name', '手填期权名称');
      await _enter(tester, 'multiplier', '10');
      await _enter(tester, 'quantity', '2');
      await _enter(tester, 'price', '2.4');
      await _enter(tester, 'reference', '2.5');
      await _contractAction(tester, 'search');
      search.requests.single.result.complete([avgoFixture]);
      await tester.pumpAndSettle();
      expect(adapter.requests, enabled ? 1 : 0);
      expect((await _field(tester, 'name')).text, '手填期权名称');
      expect((await _field(tester, 'multiplier')).text, '10');
      expect((await _field(tester, 'quantity')).text, '2');
      expect((await _field(tester, 'price')).text, '2.4');
      expect((await _field(tester, 'reference')).text, '2.5');
      expect(
        find.byKey(const ValueKey('option-contract-use-price')),
        findsNothing,
      );
      expect(c.investmentFor('stock-usd')!.securities, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  test('标的查询与期权报价共用严格 OCC 语法，不接受调整根或无效日期', () {
    final parsed = parseUsOptionSymbol('AVGO261218P00300000')!;
    expect(parsed.underlyingSymbol, 'AVGO');
    expect(parsed.expiry, '2026-12-18');
    expect(parsed.right, OptionRight.put);
    expect(parsed.strikeThousandths, BigInt.from(300000));
    for (final invalid in [
      'avgo261218P00300000',
      'AVGO260230C00300000',
      'AVGO261218C00000000',
      'AVGO1261218C00300000',
      'BRK.B261218C00300000',
      'TEST261218C00300000',
    ]) {
      expect(parseUsOptionSymbol(invalid), isNull, reason: invalid);
    }
  });

  testWidgets('标的搜索保留完整代码解析的身份，选中不复制股票价格或合约乘数', (tester) async {
    final search = _SearchClient();
    final actual = await _ready(search, local: true);
    final before = actual.investmentFor('stock-usd')!.toJson();
    await _pump(tester, actual);
    await _enter(tester, 'symbol', 'avgo261218p00300000');
    await _enter(tester, 'name', '手填期权');
    expect(search.requests, isEmpty);
    await _search(tester);
    expect(search.requests, hasLength(1));
    expect(search.requests.single.query, 'AVGO');
    expect(search.requests.single.market, StockMarket.us);
    expect(search.requests.single.currency, 'USD');
    search.requests.single.result.complete([
      avgoFixture,
      const StockSecurity(
        symbol: 'AVGO',
        name: '非股票',
        market: StockMarket.us,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      const StockSecurity(
        symbol: 'AVGO',
        name: '错误币种',
        market: StockMarket.us,
        currencyCode: 'HKD',
      ),
      optionFixture(),
    ]);
    await tester.pumpAndSettle();
    await _select(tester, avgoFixture);
    expect((await _field(tester, 'underlyingName')).text, '博通');
    expect((await _field(tester, 'strike')).text, '300');
    expect((await _field(tester, 'multiplier')).text, isEmpty);
    await _enter(tester, 'multiplier', '10');
    await _enter(tester, 'quantity', '2');
    await _enter(tester, 'price', '2');
    expect((await _field(tester, 'reference')).text, isEmpty);
    await _enter(tester, 'reference', '3');
    expect(find.byKey(const ValueKey('option-underlyingPrice')), findsNothing);
    expect(actual.investmentFor('stock-usd')!.toJson(), before);
    await _save(tester, preview: true);
    final saved = actual.investmentFor('stock-usd')!;
    final option = saved.securities.singleWhere(
      (security) => security.option != null,
    );
    expect(option.symbol.toUpperCase(), 'AVGO261218P00300000');
    expect(option.option!.underlyingId, avgoFixture.id);
    expect(option.option!.strike, '300');
    expect(option.option!.right, OptionRight.put);
    expect(saved.manualPrices[avgoFixture.id], '330');
    expect(saved.events, hasLength(1));
    expect(projectStocks(saved).positions.single.securityId, option.id);
    expect(actual.accountBalance(investmentAccountFixture()), 9960);
    expect(tester.takeException(), isNull);
  });

  testWidgets('期初期权查询返回草稿，合约和新标的随期初一起原子保存', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search, opening: true);
    final base = InvestmentPortfolio(
      accountId: 'stock-usd',
      bookId: c.activeBook.id,
      currencyCode: 'USD',
      openedAt: DateTime(2026, 10, 1),
      openingCash: '10000',
    );
    InvestmentOpeningHolding? result;
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context)
                      .push<InvestmentOpeningHolding>(
                        MaterialPageRoute(
                          builder: (_) => OptionEditorPage(
                            accountId: 'stock-usd',
                            openingPortfolio: base,
                          ),
                        ),
                      );
                },
                child: const Text('打开期初期权'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开期初期权'));
    await tester.pumpAndSettle();
    await _enter(tester, 'symbol', 'AVGO261218P00300000');
    await _enter(tester, 'name', '期初合约');
    expect(search.requests, isEmpty);
    await _search(tester);
    expect(search.requests.single.query, 'AVGO');
    search.requests.single.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    await _select(tester, avgoFixture);
    await _enter(tester, 'multiplier', '10');
    await _enter(tester, 'quantity', '2');
    await _enter(tester, 'cost', '175');
    await _enter(tester, 'reference', '3');
    expect(c.investmentFor('stock-usd'), isNull);
    await _save(tester);
    expect(result, isNotNull);
    expect(result!.underlying!.toJson(), avgoFixture.toJson());
    expect(result!.security.option!.right, OptionRight.put);
    expect(result!.security.option!.expiry, '2026-12-18');
    expect(result!.security.option!.strike, '300');
    expect(result!.security.option!.premiumMultiplier, '10');
    expect(result!.holding.cost, '175');
    expect(result!.underlyingPrice, isNull);
    expect(c.investmentFor('stock-usd'), isNull);
    final composed = composeInvestmentOpening(base: base, holdings: [result!]);
    expect(
      await c.enableInvestment(
        accountId: base.accountId,
        openingCash: composed.openingCash,
        openedAt: composed.openedAt,
        securities: composed.securities,
        openingHoldings: composed.openingHoldings,
        manualPrices: composed.manualPrices,
      ),
      isTrue,
    );
    final saved = c.investmentFor('stock-usd')!;
    expect(
      saved.securities.map((security) => security.id),
      contains(avgoFixture.id),
    );
    expect(saved.openingHoldings, hasLength(1));
    expect(saved.events, isEmpty);
    expect(saved.openingCash, '10000');
    expect(
      valueStocks(saved, projectStocks(saved)).marketValue!.toString(),
      '60',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('已有期权合约的标的锁定，不显示联网查询入口', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    final option = optionFixture();
    expect(
      await c.saveOptionEvent(
        accountId: 'stock-usd',
        security: option,
        underlying: avgoFixture,
        event: optionEventFixture(option, StockEventKind.optionBuyOpen),
        referencePrice: '3',
        underlyingReferencePrice: '50',
      ),
      isTrue,
    );
    await _pump(tester, c, securityId: option.id);
    await _field(tester, 'underlying');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('option-underlying')))
          .readOnly,
      isTrue,
    );
    expect(
      find.byKey(const Key('option-underlying-search-online')),
      findsNothing,
    );
    expect(search.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修改标的、隐藏或切账本再回来均丢弃旧查询，不覆盖当前草稿', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await _pump(tester, c, visible: visible);
    await _enter(tester, 'underlying', 'AVGO');
    await _search(tester);
    await _enter(tester, 'underlying', 'MSFT', up: true);
    search.requests.first.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('investment-security-${avgoFixture.id}')),
      findsNothing,
    );
    await _search(tester);
    visible.value = false;
    await tester.pumpAndSettle();
    visible.value = true;
    await tester.pumpAndSettle();
    const msft = StockSecurity(
      symbol: 'MSFT',
      name: '微软',
      market: StockMarket.us,
      currencyCode: 'USD',
    );
    search.requests.last.result.complete([msft]);
    await tester.pumpAndSettle();
    expect((await _field(tester, 'underlying', up: true)).text, 'MSFT');
    await tester.tap(find.byKey(const ValueKey('option-underlying')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('investment-security-${msft.id}')),
      findsNothing,
    );
    await _search(tester);
    final bookId = c.activeBook.id;
    c.addLedgerBook('另一个账本');
    await tester.pumpAndSettle();
    c.switchLedgerBook(bookId);
    await tester.pumpAndSettle();
    search.requests.last.result.complete([msft]);
    await tester.pumpAndSettle();
    await _field(tester, 'underlying', up: true);
    await tester.tap(find.byKey(const ValueKey('option-underlying')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('investment-security-${msft.id}')),
      findsNothing,
    );
    expect((await _field(tester, 'underlyingName')).text, isEmpty);
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅返回基金或期权视为无匹配，查询失败仍保留手填标的', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    await _pump(tester, c);
    await _enter(tester, 'underlying', 'AVGO');
    await _search(tester);
    search.requests.single.result.complete([
      optionFixture(),
      const StockSecurity(
        symbol: 'AVGO',
        name: '基金',
        market: StockMarket.us,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配证券，可继续手动填写。'), findsOneWidget);
    await _search(tester);
    search.requests.last.result.completeError(const FormatException('测试失败'));
    await tester.pumpAndSettle();
    expect(find.text('证券资料查询失败，请稍后重试或手动填写。'), findsOneWidget);
    expect((await _field(tester, 'underlying', up: true)).text, 'AVGO');
    expect(c.investmentFor('stock-usd')!.securities, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
