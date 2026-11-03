import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/security_search.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 可由测试明确完成的身份检索，不发网络请求，用于构造慢响应、失败和旧请求返回。
class _SearchClient extends SecuritySearchClient {
  final requests =
      <
        ({
          String query,
          StockMarket market,
          Completer<List<StockSecurity>> result,
        })
      >[];

  /// 记录公开搜索词与市场；[currencyCode] 保留真实 API 签名，不读取账户或金额。
  @override
  Future<List<StockSecurity>> search(
    String query, {
    required StockMarket market,
    required String currencyCode,
  }) {
    final result = Completer<List<StockSecurity>>();
    requests.add((query: query, market: market, result: result));
    return result.future;
  }
}

/// 构造隔离控制器与空证券账户；[local] 可预置已有证券和当前账户后备价。
Future<VeriFinController> _ready(
  _SearchClient search, {
  bool local = false,
}) async {
  final store = LocalKeyValueStore();
  store.write('verifin.locale.v1', 'zh');
  final c = await VeriFinController.create(
    store,
    repository: InMemoryLedgerRepository(),
    securitySearchClient: search,
  );
  c.addAccount(investmentAccountFixture());
  await c.waitForPendingWrites();
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
  return c;
}

/// 使用真实表单，默认 393×852；[tabs] 同时覆盖隐藏页签中的请求失效。
Future<void> _pump(
  WidgetTester tester,
  VeriFinController c, {
  bool tabs = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: c,
      child: zhMaterialApp(
        home: tabs
            ? TransactionEntryPage(
                bookId: c.activeBook.id,
                initialAccountId: 'stock-usd',
              )
            : const StockEditorPage(accountId: 'stock-usd'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 找到领域表单自己的滚动视图，避免候选列表滚动影响页面字段定位。
Finder _formScroll() => find
    .descendant(
      of: find.byType(StockEditorPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 滚动并填写 [field]；[up] 表示回到表单上半部分，输入时不点击联网按钮。
Future<void> _enter(
  WidgetTester tester,
  String field,
  String value, {
  bool up = false,
}) async {
  final input = find.byKey(ValueKey('stock-$field'));
  await tester.scrollUntilVisible(
    input,
    up ? -180 : 180,
    scrollable: _formScroll(),
  );
  await tester.ensureVisible(input);
  await tester.pumpAndSettle();
  await tester.enterText(input, value);
  await tester.pumpAndSettle();
}

/// 读取 [field] 当前草稿文本，不通过模型推测输入区结果。
String _text(WidgetTester tester, String field) => tester
    .widget<TextField>(find.byKey(ValueKey('stock-$field')))
    .controller!
    .text;

/// 主动发起一次检索；按钮与披露实际留在证券资料组内，不通过私有状态触发。
Future<void> _search(WidgetTester tester) async {
  final button = find.byKey(const Key('stock-search-online'));
  await tester.scrollUntilVisible(button, 120, scrollable: _formScroll());
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// 分段控件只给当前前景副本挂 Key；点击真实标签后再用 Key 核对切换结果。
Future<void> _switchMode(WidgetTester tester, String mode, String label) async {
  final option = find
      .descendant(
        of: find.byKey(const Key('transaction-entry-mode')),
        matching: find.text(label),
      )
      .hitTestable()
      .first;
  await tester.tap(option);
  await tester.pumpAndSettle();
  expect(find.byKey(ValueKey('transaction-mode-$mode')), findsOneWidget);
}

/// 使用当前账户已有证券的真实下拉项，随后显示并验证其自动带入的后备价。
Future<void> _pickLocalAvgo(WidgetTester tester) async {
  await _enter(tester, 'symbol', 'AV', up: true);
  await tester.tap(
    find.byKey(const ValueKey('investment-security-us:stock:AVGO')),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('stock-reference')),
    180,
    scrollable: _formScroll(),
  );
  expect(_text(tester, 'reference'), '330');
}

/// 选择器行必须在视口内可命中，再通过真实菜单更换市场。
Future<void> _chooseHongKong(WidgetTester tester) async {
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text('美股'),
    -150,
    scrollable: _formScroll(),
  );
  await tester.ensureVisible(find.text('美股'));
  await tester.pumpAndSettle();
  expect(find.text('美股').hitTestable(), findsOneWidget);
  await tester.tap(find.text('美股').hitTestable());
  await tester.pumpAndSettle();
  await tester.tap(find.text('港股').last);
  await tester.pumpAndSettle();
}

/// 本地和远端证券选择均只改变草稿身份，且请求必须由用户点击启动。
void main() {
  useTestDatabases();

  testWidgets('本地输入即匹配，选中填名称及当前账户后备价且零请求零落库', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search, local: true);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _enter(tester, 'price', '42');
    await _enter(tester, 'quantity', '2', up: true);
    await _enter(tester, 'symbol', 'aV', up: true);
    final option = find.byKey(
      const ValueKey('investment-security-us:stock:AVGO'),
    );
    expect(option, findsOneWidget);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(_text(tester, 'symbol'), 'AVGO');
    expect(_text(tester, 'name'), '博通');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stock-reference')),
      180,
      scrollable: _formScroll(),
    );
    expect(_text(tester, 'reference'), '330');
    expect(_text(tester, 'price'), '42');
    expect(_text(tester, 'quantity'), '2');
    expect(search.requests, isEmpty);
    expect(c.investmentFor('stock-usd')!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入不联网，主动查询拼音缩写后下拉选中且真实量价和手填参考价保留', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _enter(tester, 'price', '42');
    await _enter(tester, 'quantity', '2', up: true);
    await _enter(tester, 'reference', '123');
    await _enter(tester, 'symbol', 'bt', up: true);
    expect(search.requests, isEmpty);
    await _search(tester);
    expect(search.requests.single.query, 'bt');
    search.requests.single.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    final option = find.byKey(
      const ValueKey('investment-security-us:stock:AVGO'),
    );
    expect(option, findsOneWidget);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(_text(tester, 'symbol'), 'AVGO');
    expect(_text(tester, 'name'), '博通');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stock-reference')),
      180,
      scrollable: _formScroll(),
    );
    expect(_text(tester, 'quantity'), '2');
    expect(_text(tester, 'price'), '42');
    expect(_text(tester, 'reference'), '123');
    expect(c.investmentFor('stock-usd')!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('改输入或市场均废弃旧响应，不自动重搜或抢回焦点', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO');
    await _search(tester);
    await _enter(tester, 'symbol', 'GOOG', up: true);
    search.requests.first.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    expect(_text(tester, 'symbol'), 'GOOG');
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    expect(search.requests, hasLength(1));
    await _search(tester);
    await _chooseHongKong(tester);
    search.requests.last.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    expect(_text(tester, 'symbol'), 'GOOG');
    expect(search.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询失败和空结果保留草稿，可继续手填', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _enter(tester, 'name', '手填名称');
    await _enter(tester, 'symbol', 'MANUAL', up: true);
    await _search(tester);
    search.requests.first.result.completeError(StateError('固定失败'));
    await tester.pumpAndSettle();
    expect(find.text('证券资料查询失败，请稍后重试或手动填写。'), findsOneWidget);
    expect(_text(tester, 'symbol'), 'MANUAL');
    expect(_text(tester, 'name'), '手填名称');
    await _search(tester);
    search.requests.last.result.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配证券，可继续手动填写。'), findsOneWidget);
    await _enter(tester, 'symbol', 'NEW-MANUAL', up: true);
    expect(_text(tester, 'name'), '手填名称');
    expect(_text(tester, 'symbol'), 'NEW-MANUAL');
    expect(search.requests, hasLength(2));
    expect(c.investmentFor('stock-usd')!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('请求中切到普通页签后旧响应不展示候选，切回可重新主动查询', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    addTearDown(c.dispose);
    await _pump(tester, c, tabs: true);
    await _enter(tester, 'symbol', 'AVGO');
    await _search(tester);
    await _switchMode(tester, 'general', '普通记账');
    search.requests.single.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    await _switchMode(tester, 'investment', '投资交易');
    expect(_text(tester, 'symbol'), 'AVGO');
    await _search(tester);
    expect(search.requests, hasLength(2));
    search.requests.last.result.complete([]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动后备价绑定原证券，直接改代码或市场都会清除', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search, local: true);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _pickLocalAvgo(tester);
    await _enter(tester, 'symbol', 'AAPL', up: true);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stock-reference')),
      180,
      scrollable: _formScroll(),
    );
    expect(_text(tester, 'reference'), isEmpty);
    await _pickLocalAvgo(tester);
    await _chooseHongKong(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stock-reference')),
      180,
      scrollable: _formScroll(),
    );
    expect(_text(tester, 'reference'), isEmpty);
    expect(search.requests, isEmpty);
    expect(c.investmentFor('stock-usd')!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用户主动改填的参考价在更换代码与市场时保留', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search, local: true);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _pickLocalAvgo(tester);
    await _enter(tester, 'reference', '123');
    await _enter(tester, 'symbol', 'AAPL', up: true);
    await _chooseHongKong(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stock-reference')),
      180,
      scrollable: _formScroll(),
    );
    expect(_text(tester, 'reference'), '123');
    expect(search.requests, isEmpty);
    expect(c.investmentFor('stock-usd')!.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('晚到搜索结果缓存候选，不抢走用户已切到的数量输入焦点', (tester) async {
    final search = _SearchClient();
    final c = await _ready(search);
    addTearDown(c.dispose);
    await _pump(tester, c);
    await _enter(tester, 'symbol', 'AVGO');
    await _search(tester);
    await _enter(tester, 'quantity', '2');
    final quantity = tester.widget<TextField>(
      find.byKey(const ValueKey('stock-quantity')),
    );
    final focusedBeforeResponse = FocusManager.instance.primaryFocus;
    final focusedContext = focusedBeforeResponse?.context;
    final focusedWidget = focusedContext?.widget;
    final editable = focusedWidget is EditableText
        ? focusedWidget
        : focusedContext?.findAncestorWidgetOfExactType<EditableText>();
    expect(editable?.controller, same(quantity.controller));
    search.requests.single.result.complete([avgoFixture]);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(focusedBeforeResponse));
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    // 已验证结果不会抢焦点；主动结束数量输入后再返回代码框，避免键盘保留光标自动滚回数量。
    FocusManager.instance.primaryFocus?.unfocus();
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('stock-symbol')),
      -180,
      scrollable: _formScroll(),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('stock-symbol')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('stock-symbol')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('stock-symbol')).hitTestable());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('investment-security-us:stock:AVGO')),
      findsOneWidget,
    );
    expect(search.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
