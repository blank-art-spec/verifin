import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/investments/investment_position_sort.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

// 固定本地测试数据：依次为亏损、成本未知、盈利和持平，不代表真实证券行情。
const _securities = [
  StockSecurity(
    symbol: 'LOSS',
    name: '亏损示例',
    market: StockMarket.us,
    currencyCode: 'USD',
  ),
  StockSecurity(
    symbol: 'UNKNOWN',
    name: '未知成本示例',
    market: StockMarket.us,
    currencyCode: 'USD',
  ),
  StockSecurity(
    symbol: 'GAIN',
    name: '盈利示例',
    market: StockMarket.us,
    currencyCode: 'USD',
  ),
  StockSecurity(
    symbol: 'FLAT',
    name: '持平示例',
    market: StockMarket.us,
    currencyCode: 'USD',
  ),
];

/// 经生产 Controller 建立隔离持仓，不直接修改页面状态或伪造排序结果。
/// [accountIds] 可建立两个相同持仓的账户，验证切换账户不会继承旧排序。
/// 四项市值为 300、50、100、200，盈亏为 -100、未知、30、0。
Future<VeriFinController> _makeSortController({
  List<String> accountIds = const ['sort-account'],
}) async {
  final controller = await makeController();
  addTearDown(controller.dispose);
  for (final accountId in accountIds) {
    final account = investmentAccountFixture(id: accountId);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: _securities,
        openingHoldings: [
          for (final item in _securities.indexed)
            StockHolding(
              securityId: item.$2.id,
              short: false,
              quantity: '1',
              cost: ['400', null, '70', '200'][item.$1],
            ),
        ],
        manualPrices: {
          for (final item in _securities.indexed)
            item.$2.id: ['300', '50', '100', '200'][item.$1],
        },
      ),
      isTrue,
    );
  }
  return controller;
}

/// 挂载真实持仓页；[width]、[scale] 与 [locale] 覆盖窄屏、大字号和英文。
/// 字号通过 MaterialApp 的 builder 注入，弹出菜单与页面使用同一系统缩放。
/// [accountId] 可在同一组件树中改变，检查账户隔离而非靠重启整个应用重置。
Future<void> _pumpSortPage(
  WidgetTester tester,
  VeriFinController controller, {
  String accountId = 'sort-account',
  double width = 393,
  double scale = 1,
  Locale locale = const Locale('zh'),
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
        theme: buildVeriFinTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: InvestmentPage(accountId: accountId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 滚动至排序入口后点击真实控件，保证选项由用户可见交互触发。
/// [tester] 为当前测试驱动；返回前等待公共菜单动效结束。
Future<void> _openSort(WidgetTester tester) async {
  final selector = find.byKey(const Key('investment-position-sort'));
  await tester.scrollUntilVisible(
    selector,
    180,
    scrollable: find
        .descendant(
          of: find.byType(InvestmentPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(selector);
  await tester.pumpAndSettle();
}

/// 从菜单选择 [order] 并核对入口文案立即反映选择，使用当前语言的完整标签。
/// 选中项在入口与菜单中各显示一次，所以点击最后一个匹配文字，即弹出层选项。
Future<void> _selectSort(
  WidgetTester tester,
  InvestmentPositionSortOrder order,
) async {
  final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
  await _openSort(tester);
  await tester.tap(find.text(order.label(l)).last);
  await tester.pumpAndSettle();
  expect(
    find.descendant(
      of: find.byKey(const Key('investment-position-sort')),
      matching: find.text(order.label(l)),
    ),
    findsOneWidget,
  );
  expect(tester.takeException(), isNull);
}

/// 核对真实 ListView 声明的持仓卡片顺序，不读取页面的私有排序状态。
/// [expected] 是证券在夹具中的索引；列表保持懒构建，因此从正式 childrenDelegate
/// 读取每张卡片的稳定 key，不要求离屏卡片提前挂载，也不改变列表滚动位置。
void _expectPositionOrder(WidgetTester tester, List<int> expected) {
  final list = tester.widget<ListView>(
    find
        .descendant(
          of: find.byType(InvestmentPage),
          matching: find.byType(ListView),
        )
        .first,
  );
  final children = (list.childrenDelegate as SliverChildListDelegate).children;
  final keys = children
      .map((child) => child.key)
      .whereType<ValueKey<String>>()
      .where(
        (key) =>
            key.value.startsWith('investment-position-') &&
            (key.value.endsWith('-false') || key.value.endsWith('-true')),
      )
      .toList();
  expect(keys, [
    for (final index in expected)
      ValueKey('investment-position-${_securities[index].id}-false'),
  ]);
}

/// 覆盖四种用户排序、取消、报价变化与账户隔离；不会联网或编译 Android 应用。
void main() {
  useTestDatabases();

  testWidgets('持仓菜单支持四种排序，盈亏保留正负号且未知成本置尾', (tester) async {
    final controller = await _makeSortController();
    final before = jsonEncode(
      controller.investmentFor('sort-account')!.toJson(),
    );
    await _pumpSortPage(tester, controller);
    await _openSort(tester);
    for (final label in ['默认顺序', '市值降序', '市值升序', '盈亏金额降序', '盈亏金额升序']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPositionOrder(tester, [0, 1, 2, 3]);

    for (final scenario in [
      (InvestmentPositionSortOrder.marketValueDesc, [0, 3, 2, 1]),
      (InvestmentPositionSortOrder.marketValueAsc, [1, 2, 3, 0]),
      (InvestmentPositionSortOrder.unrealizedDesc, [2, 3, 0, 1]),
      (InvestmentPositionSortOrder.unrealizedAsc, [0, 3, 2, 1]),
      (InvestmentPositionSortOrder.original, [0, 1, 2, 3]),
    ]) {
      await _selectSort(tester, scenario.$1);
      _expectPositionOrder(tester, scenario.$2);
    }
    expect(
      jsonEncode(controller.investmentFor('sort-account')!.toJson()),
      before,
      reason: '改变展示顺序不能改写期初持仓、成本、价格或成交记录',
    );
  });

  testWidgets('取消菜单保留选择，参考价变动按当前规则重新排序', (tester) async {
    final controller = await _makeSortController();
    await _pumpSortPage(tester, controller);
    await _selectSort(tester, InvestmentPositionSortOrder.marketValueAsc);
    await _openSort(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPositionOrder(tester, [1, 2, 3, 0]);

    expect(
      await controller.setStockReferencePrice(
        'sort-account',
        _securities[2].id,
        '500',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    _expectPositionOrder(tester, [1, 3, 0, 2]);
    expect(
      find.descendant(
        of: find.byKey(const Key('investment-position-sort')),
        matching: find.text('市值升序'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('持仓分区滚出视口后返回仍保留所选顺序', (tester) async {
    final controller = await _makeSortController();
    await _pumpSortPage(tester, controller);
    await _selectSort(tester, InvestmentPositionSortOrder.unrealizedDesc);
    // 压低视口模拟分屏，确保返回页头时整个持仓分区离开列表的缓存范围。
    await tester.binding.setSurfaceSize(const Size(393, 320));
    final scroll = find
        .descendant(
          of: find.byType(InvestmentPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(scroll, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(393, 852));
    await tester.pumpAndSettle();
    await _openSort(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPositionOrder(tester, [2, 3, 0, 1]);
    expect(
      find.descendant(
        of: find.byKey(const Key('investment-position-sort')),
        matching: find.text('盈亏金额降序'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('同一页面切换账户后恢复默认顺序，不沿用上一账户选择', (tester) async {
    final controller = await _makeSortController(
      accountIds: ['sort-account', 'another-sort-account'],
    );
    await _pumpSortPage(tester, controller);
    await _selectSort(tester, InvestmentPositionSortOrder.unrealizedDesc);
    _expectPositionOrder(tester, [2, 3, 0, 1]);
    await _pumpSortPage(tester, controller, accountId: 'another-sort-account');
    await _openSort(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPositionOrder(tester, [0, 1, 2, 3]);
    expect(
      find.descendant(
        of: find.byKey(const Key('investment-position-sort')),
        matching: find.text('默认顺序'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('无持仓时保留空态，不显示无效排序入口', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final account = investmentAccountFixture(id: 'sort-account');
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
    await _pumpSortPage(tester, controller);
    await tester.scrollUntilVisible(
      find.text('暂无证券持仓'),
      180,
      scrollable: find
          .descendant(
            of: find.byType(InvestmentPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('暂无证券持仓'), findsOneWidget);
    expect(find.byKey(const Key('investment-position-sort')), findsNothing);
    _expectPositionOrder(tester, []);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出持仓页再进入恢复默认顺序', (tester) async {
    final controller = await _makeSortController();
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(
          theme: buildVeriFinTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-investment-sort-page'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const InvestmentPage(accountId: 'sort-account'),
                    ),
                  ),
                  child: const Text('查看持仓'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-investment-sort-page')));
    await tester.pumpAndSettle();
    await _selectSort(tester, InvestmentPositionSortOrder.unrealizedDesc);
    _expectPositionOrder(tester, [2, 3, 0, 1]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(InvestmentPage), findsNothing);
    await tester.tap(find.byKey(const Key('open-investment-sort-page')));
    await tester.pumpAndSettle();
    await _openSort(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    _expectPositionOrder(tester, [0, 1, 2, 3]);
    expect(
      find.descendant(
        of: find.byKey(const Key('investment-position-sort')),
        matching: find.text('默认顺序'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (width: 393.0, scale: 1.0, locale: const Locale('zh')),
    (width: 360.0, scale: 1.5, locale: const Locale('en')),
  ]) {
    testWidgets('排序入口及菜单可用且无溢出 ${scenario.locale} ${scenario.width}', (
      tester,
    ) async {
      final controller = await _makeSortController();
      await _pumpSortPage(
        tester,
        controller,
        width: scenario.width,
        scale: scenario.scale,
        locale: scenario.locale,
      );
      for (final order in InvestmentPositionSortOrder.values) {
        await _selectSort(tester, order);
        final selector = tester.getRect(
          find.byKey(const Key('investment-position-sort')),
        );
        expect(selector.left, greaterThanOrEqualTo(0));
        expect(selector.right, lessThanOrEqualTo(scenario.width));
      }
    });
  }
}
