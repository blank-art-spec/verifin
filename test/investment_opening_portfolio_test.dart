import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/investments/investment_opening_draft.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/investment_setup_page.dart';
import 'package:verifin/pages/option_editor_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/option_editor_harness.dart';
import 'support/test_harness.dart';

const _goog = StockSecurity(
  symbol: 'GOOG',
  name: '谷歌',
  market: StockMarket.us,
  currencyCode: 'USD',
);

const _captureKey = Key('opening-capture');
bool get _captureEnabled =>
    Platform.environment['VERIFIN_OPENING_SCREENSHOTS'] == '1';

/// 只有明确请求本机截图时加载真实中文字体；普通测试与 CI 不访问系统字体。
Future<void> _loadCaptureFont(WidgetTester tester) async {
  if (!_captureEnabled) return;
  await tester.runAsync(() async {
    final path =
        Platform.environment['VERIFIN_OPENING_FONT'] ??
        r'C:\Windows\Fonts\msyh.ttc';
    final bytes = await File(path).readAsBytes();
    final loader = FontLoader('OpeningPreview')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
}

/// 截取真实页面的顶部和列表底部，不扩展页面尺寸或创建独立展示 UI。
Future<void> _captureOpening(WidgetTester tester, String name) async {
  if (!_captureEnabled) return;
  FocusManager.instance.primaryFocus?.unfocus();
  final scroll = tester.state<ScrollableState>(_scroll(InvestmentSetupPage));
  for (final atBottom in [false, true]) {
    scroll.position.jumpTo(atBottom ? scroll.position.maxScrollExtent : 0);
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final directory = Directory('build/validation/opening-holdings-20261105');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/$name-${atBottom ? 'list' : 'top'}.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
  }
}

InvestmentPortfolio _base() => InvestmentPortfolio(
  accountId: 'stock-usd',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime(2026, 10, 1),
  openingCash: '5000',
);

/// 数字为固定本地验收值；总成本是原始事实，不从当前价格推算。
InvestmentOpeningHolding _holding(
  StockSecurity security, {
  String quantity = '2',
  String? cost = '100',
  String reference = '3',
  bool short = false,
  String? margin,
}) => InvestmentOpeningHolding(
  security: security,
  holding: StockHolding(
    securityId: security.id,
    short: short,
    quantity: quantity,
    cost: cost,
  ),
  referencePrice: reference,
  underlying: security.option == null ? null : avgoFixture,
  frozenMargin: margin,
);

Finder _scroll(Type page) => find
    .descendant(of: find.byType(page), matching: find.byType(Scrollable))
    .first;

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      key.startsWith('opening-edit') || key.startsWith('opening-remove')
          ? -220
          : 220,
      scrollable: _scroll(InvestmentSetupPage),
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 在对应品种的真实表单内填写 [key]；期权的选填和详情分组先显式展开。
Future<void> _enter(
  WidgetTester tester,
  Type page,
  String key,
  String value,
) async {
  final field = find.byKey(Key(key));
  if (page == OptionEditorPage) {
    await revealOptionEditorField(tester, key.substring('option-'.length));
  } else {
    await tester.scrollUntilVisible(field, 220, scrollable: _scroll(page));
  }
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _saveChild(WidgetTester tester, Type page) async {
  final save = find.widgetWithText(FilledButton, '保存');
  await tester.scrollUntilVisible(save, 220, scrollable: _scroll(page));
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _openSetup(
  WidgetTester tester,
  VeriFinController controller, {
  double scale = 1,
}) async {
  await _loadCaptureFont(tester);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: _captureEnabled
            ? buildVeriFinTheme(Brightness.light).copyWith(
                textTheme: buildVeriFinTheme(
                  Brightness.light,
                ).textTheme.apply(fontFamily: 'OpeningPreview'),
                primaryTextTheme: buildVeriFinTheme(
                  Brightness.light,
                ).primaryTextTheme.apply(fontFamily: 'OpeningPreview'),
              )
            : null,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: const RepaintBoundary(
                      key: _captureKey,
                      child: InvestmentSetupPage(accountId: 'stock-usd'),
                    ),
                  ),
                ),
              ),
              child: const Text('启用测试账户'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('启用测试账户'));
  await tester.pumpAndSettle();
}

/// 从用户可见的添加按钮填写股票，返回列表时应仍然只存在内存草稿。
Future<void> _addStock(
  WidgetTester tester, {
  String symbol = 'AVGO',
  String name = '博通',
  String quantity = '10',
  String cost = '30',
  String reference = '50',
  bool short = false,
}) async {
  await _tapKey(tester, 'opening-add-stock');
  for (final field in {
    'symbol': symbol,
    'name': name,
    'quantity': quantity,
    'cost': cost,
    'reference': reference,
  }.entries) {
    await _enter(tester, StockEditorPage, 'stock-${field.key}', field.value);
  }
  if (short) {
    final toggle = find.widgetWithText(SwitchListTile, '空头');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }
  await _saveChild(tester, StockEditorPage);
}

/// 只在本测试模拟一次投资聚合写入失败，随后可重试同一份完整草稿。
class _FailOnceRepository extends InMemoryLedgerRepository {
  bool failNextInvestmentSave = false;

  @override
  Future<void> saveInvestmentPortfolios(
    List<InvestmentPortfolio> portfolios,
  ) async {
    if (failNextInvestmentSave) {
      failNextInvestmentSave = false;
      throw StateError('模拟期初聚合写入失败');
    }
    await super.saveInvestmentPortfolios(portfolios);
  }
}

void main() {
  useTestDatabases();

  test('相同证券同方向不能重复期初，相反方向仍独立持有', () {
    final long = _holding(avgoFixture, reference: '50');
    expect(
      () => composeInvestmentOpening(base: _base(), holdings: [long, long]),
      throwsA(
        isA<InvestmentOpeningConflict>().having(
          (e) => e.issue,
          'issue',
          InvestmentOpeningIssue.duplicateHolding,
        ),
      ),
    );
    final result = composeInvestmentOpening(
      base: _base(),
      holdings: [
        long,
        _holding(avgoFixture, reference: '50', short: true),
      ],
    );
    expect(result.securities, hasLength(1));
    expect(result.openingHoldings, hasLength(2));
    expect(result.events, isEmpty);
  });

  test('同一期权多空共享一个冻结额，未知成本保留而乘数用于估值', () {
    final option = optionFixture(multiplier: '10');
    final result = composeInvestmentOpening(
      base: _base(),
      holdings: [
        _holding(avgoFixture, quantity: '10', cost: '400', reference: '50'),
        _holding(option, quantity: '3', cost: null, margin: '250'),
        _holding(option, quantity: '1', cost: '20', short: true, margin: '250'),
      ],
    );
    final projection = projectStocks(result);
    expect(result.securities, hasLength(2));
    expect(result.events, hasLength(1));
    expect(result.events.single.kind, StockEventKind.optionMargin);
    expect(projection.frozenMargin.toString(), '250');
    expect(projection.cashMovements.values.single.toString(), '0');
    expect(
      projection.positions
          .singleWhere((p) => p.securityId == option.id && !p.short)
          .cost,
      isNull,
    );
    expect(valueStocks(result, projection).marketValue.toString(), '560');
  });

  test('同合约两方向的冻结额或参考价冲突不能静默覆盖', () {
    final option = optionFixture();
    for (final sample in [
      (
        other: _holding(option, short: true, margin: '300'),
        issue: InvestmentOpeningIssue.conflictingMargin,
      ),
      (
        other: _holding(option, short: true, reference: '4', margin: '250'),
        issue: InvestmentOpeningIssue.conflictingReference,
      ),
      (
        other: _holding(
          optionFixture(multiplier: '10'),
          short: true,
          margin: '250',
        ),
        issue: InvestmentOpeningIssue.conflictingSecurity,
      ),
    ]) {
      expect(
        () => composeInvestmentOpening(
          base: _base(),
          holdings: [
            _holding(option, margin: '250'),
            sample.other,
          ],
        ),
        throwsA(
          isA<InvestmentOpeningConflict>().having(
            (e) => e.issue,
            'issue',
            sample.issue,
          ),
        ),
      );
    }
  });

  test('混合期初和保证金在 SQLite 一次保存，失败无半套数据且可冷读', () async {
    sqfliteFfiInit();
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final repo = SqliteLedgerRepository(db);
    final store = LocalKeyValueStore();
    final c = await VeriFinController.create(store, repository: repo);
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    final option = optionFixture(multiplier: '10');
    final initial = composeInvestmentOpening(
      base: _base(),
      holdings: [
        _holding(avgoFixture, quantity: '10', cost: '300', reference: '50'),
        _holding(_goog, quantity: '3', cost: '240', reference: '100'),
        _holding(option, quantity: '2', cost: '40', margin: '200'),
      ],
    );
    Future<bool> save() => c.enableInvestment(
      accountId: account.id,
      openingCash: initial.openingCash,
      openedAt: initial.openedAt,
      securities: initial.securities,
      openingHoldings: initial.openingHoldings,
      manualPrices: initial.manualPrices,
      openingOptionMargins: {option.id: '200'},
    );
    await db.db.execute(
      "CREATE TRIGGER reject_opening BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT, '模拟期初失败'); END",
    );
    expect(await save(), isFalse);
    expect(c.investmentFor(account.id), isNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    expect(c.accountBalance(account), account.initialBalance);
    await db.db.execute('DROP TRIGGER reject_opening');
    expect(await save(), isTrue);
    expect(c.accountBalance(account), 5000);
    expect(c.entries, isEmpty);
    final reloaded = await VeriFinController.create(store, repository: repo);
    addTearDown(reloaded.dispose);
    final p = reloaded.investmentFor(account.id)!;
    expect(p.openingHoldings, hasLength(3));
    expect(p.events, hasLength(1));
    expect(p.events.single.kind, StockEventKind.optionMargin);
    expect(reloaded.accountBalance(account), 5000);
    expect(
      reloaded.investmentProjection(account.id)!.frozenMargin.toString(),
      '200',
    );
    final restored = InvestmentPortfolio.fromJson(p.toJson());
    expect(restored.toJson(), p.toJson());
    expect(
      valueStocks(restored, projectStocks(restored)).marketValue.toString(),
      '860',
    );
  });

  testWidgets('从列表录入两只股票及期权，最终保存才启用且不重复扣现金', (tester) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await _openSetup(tester, c);
    await _enter(tester, InvestmentSetupPage, 'opening-cash', '5000');
    await _addStock(tester);
    expect(c.investmentFor(account.id), isNull);
    await _addStock(
      tester,
      symbol: 'GOOG',
      name: '谷歌',
      quantity: '3',
      cost: '80',
      reference: '100',
    );
    expect(c.investmentFor(account.id), isNull);
    await _tapKey(tester, 'opening-add-option');
    for (final field in {
      'symbol': 'TEST-AVGO-CALL',
      'name': '博通认购示例',
      'underlying': 'AVGO',
      'underlyingName': '博通',
      'strike': '50',
      'multiplier': '10',
      'quantity': '2',
      'cost': '40',
      'margin': '200',
      'reference': '3',
    }.entries) {
      await _enter(
        tester,
        OptionEditorPage,
        'option-${field.key}',
        field.value,
      );
    }
    await _saveChild(tester, OptionEditorPage);
    expect(c.investmentFor(account.id), isNull);
    expect(find.byType(InvestmentSetupPage), findsOneWidget);
    await _captureOpening(tester, 'mixed-393');
    await _tapKey(tester, 'opening-save');
    final saved = c.investmentFor(account.id)!;
    expect(saved.openingHoldings, hasLength(3));
    expect(saved.securities, hasLength(3));
    expect(saved.events.single.kind, StockEventKind.optionMargin);
    expect(c.accountBalance(account), 5000);
    expect(c.accountAssetValue(account), 5860);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏列表编辑和移除仅改草稿，返回不保存丢弃全部期初', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await _openSetup(tester, c, scale: 1.8);
    await _addStock(tester);
    await _addStock(tester, symbol: 'GOOG', name: '谷歌');
    await _captureOpening(tester, 'large-360');
    await _tapKey(tester, 'opening-edit-0');
    await _enter(tester, StockEditorPage, 'stock-quantity', '12');
    await _saveChild(tester, StockEditorPage);
    await _tapKey(tester, 'opening-remove-1');
    expect(find.byKey(const Key('opening-edit-1')), findsNothing);
    expect(c.investmentFor(account.id), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存修改？'), findsOneWidget);
    await tester.tap(find.text('不保存'));
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentSetupPage), findsNothing);
    expect(c.investmentFor(account.id), isNull);
    expect(c.accountBalance(account), account.initialBalance);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一股票多空参考价冲突保留两条草稿，修正后才能统一保存', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    await _openSetup(tester, c);
    await _enter(tester, InvestmentSetupPage, 'opening-cash', '5000');
    await _addStock(tester);
    await _addStock(tester, quantity: '2', reference: '55', short: true);
    expect(find.byType(InvestmentSetupPage), findsOneWidget);
    expect(find.byKey(const Key('opening-edit-0')), findsOneWidget);
    expect(find.byKey(const Key('opening-edit-1')), findsOneWidget);
    final error = find.textContaining('一致的参考价');
    await tester.scrollUntilVisible(
      error,
      220,
      scrollable: _scroll(InvestmentSetupPage),
    );
    expect(error, findsOneWidget);
    await _tapKey(tester, 'opening-save');
    expect(c.investmentFor(account.id), isNull);
    expect(find.byType(InvestmentSetupPage), findsOneWidget);
    expect(error, findsOneWidget);

    await _tapKey(tester, 'opening-edit-1');
    await _enter(tester, StockEditorPage, 'stock-reference', '50');
    await _saveChild(tester, StockEditorPage);
    expect(find.byType(InvestmentSetupPage), findsOneWidget);
    expect(find.textContaining('一致的参考价'), findsNothing);
    await _tapKey(tester, 'opening-save');
    final result = c.investmentFor(account.id)!;
    expect(result.openingHoldings, hasLength(2));
    expect(result.openingHoldings.where((h) => h.short).single.quantity, '2');
    expect(result.openingHoldings.where((h) => !h.short).single.quantity, '10');
    expect(result.manualPrices[avgoFixture.id], '50');
    expect(result.events, isEmpty);
    expect(c.accountBalance(account), 5000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整列表写入失败保留两条草稿，同页重试只创建一份期初', (tester) async {
    final repo = _FailOnceRepository();
    final store = LocalKeyValueStore();
    store.write('verifin.locale.v1', 'zh');
    final c = await VeriFinController.create(store, repository: repo);
    addTearDown(c.dispose);
    final account = investmentAccountFixture();
    c.addAccount(account);
    await c.waitForPendingWrites();
    // 初始化不应消费本用例的写入失败，仅针对用户最终保存。
    repo.failNextInvestmentSave = true;
    await _openSetup(tester, c);
    await _addStock(tester);
    await _addStock(tester, symbol: 'GOOG', name: '谷歌');
    await _tapKey(tester, 'opening-save');
    expect(c.investmentFor(account.id), isNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    expect(find.byType(InvestmentSetupPage), findsOneWidget);
    expect(find.byKey(const Key('opening-edit-0')), findsOneWidget);
    expect(find.byKey(const Key('opening-edit-1')), findsOneWidget);
    await _tapKey(tester, 'opening-save');
    expect(c.investmentFor(account.id)!.openingHoldings, hasLength(2));
    expect(await repo.loadInvestmentPortfolios(), hasLength(1));
    expect(c.investmentFor(account.id)!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
