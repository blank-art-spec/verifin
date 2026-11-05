import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_opening_draft.dart';
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
}) async {
  final c = await VeriFinController.create(
    LocalKeyValueStore()..write('verifin.locale.v1', 'zh'),
    repository: InMemoryLedgerRepository(),
    securitySearchClient: search,
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

Future<TextEditingController> _field(
  WidgetTester tester,
  String field, {
  bool up = false,
}) async {
  final input = find.byKey(ValueKey('option-$field'));
  await tester.scrollUntilVisible(
    input,
    up ? -220 : 220,
    scrollable: _scroll(),
  );
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
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

Future<void> _search(WidgetTester tester) async {
  final button = find.byKey(const Key('option-underlying-search-online'));
  await tester.scrollUntilVisible(button, 180, scrollable: _scroll());
  await tester.ensureVisible(button);
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
}) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final page = OptionEditorPage(accountId: 'stock-usd', securityId: securityId);
  await tester.pumpWidget(
    VeriFinScope(
      controller: c,
      child: zhMaterialApp(
        home: visible == null
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

void main() {
  useTestDatabases();

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

  testWidgets('独立期权交易显式查询股票身份，选中不复制价格或推断合约', (tester) async {
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
    expect((await _field(tester, 'strike')).text, isEmpty);
    expect((await _field(tester, 'multiplier')).text, isEmpty);
    await _enter(tester, 'strike', '99', up: true);
    await _enter(tester, 'multiplier', '10');
    await _enter(tester, 'quantity', '2');
    await _enter(tester, 'price', '2');
    expect((await _field(tester, 'reference')).text, isEmpty);
    await _enter(tester, 'reference', '3');
    expect((await _field(tester, 'underlyingPrice')).text, isEmpty);
    expect(actual.investmentFor('stock-usd')!.toJson(), before);
    await _save(tester, preview: true);
    final saved = actual.investmentFor('stock-usd')!;
    final option = saved.securities.singleWhere(
      (security) => security.option != null,
    );
    expect(option.symbol, 'avgo261218p00300000');
    expect(option.option!.underlyingId, avgoFixture.id);
    expect(option.option!.strike, '99');
    expect(option.option!.right, OptionRight.call);
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
    await _enter(tester, 'strike', '50');
    await _enter(tester, 'multiplier', '10');
    await _enter(tester, 'quantity', '2');
    await _enter(tester, 'cost', '175');
    await _enter(tester, 'reference', '3');
    expect(c.investmentFor('stock-usd'), isNull);
    await _save(tester);
    expect(result, isNotNull);
    expect(result!.underlying!.toJson(), avgoFixture.toJson());
    expect(result!.security.option!.right, OptionRight.call);
    expect(result!.security.option!.expiry, '2026-10-31');
    expect(result!.security.option!.strike, '50');
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
