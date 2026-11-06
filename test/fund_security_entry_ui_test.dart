import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/investments/fund_security_search.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/pages/fund_entry_page.dart';
import 'package:verifin/pages/fund_security_editor_page.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 返回固定公开身份的可控客户端；不会真正联网，测试可按需完成、失败或延迟每次响应。
class _FundSearchClient extends FundSecuritySearchClient {
  final requests =
      <
        ({
          String query,
          StockMarket market,
          String currency,
          Completer<List<StockSecurity>> result,
        })
      >[];

  /// 记录用户主动传入的 [query]、[market] 与 [currencyCode]，随后等待用例提供结果。
  /// 不读取账户、成本、数量，也不把查询结果写入父表单或仓储。
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

/// 固定的查询回包，仅用于确认显式选择行为；名称、代码及净值均不是线上产品承诺。
const _queriedFund = StockSecurity(
  symbol: 'HK0009999991',
  name: '查询取得的美元货币基金 A 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 创建已启用的美元账户；[search] 为本用例专属的无网络查询客户端。
/// [existing] 可预置带用户自定义名称的基金及后备价，用于验证同代码复用不覆盖原资料。
/// 返回仓储供用例验证取消不会落库，账户使用固定历史启用日，不依赖测试执行当天的时区。
Future<
  ({
    VeriFinController controller,
    Account account,
    InMemoryLedgerRepository repository,
  })
>
_ready(_FundSearchClient search, {StockSecurity? existing}) async {
  final store = LocalKeyValueStore();
  store.write('verifin.locale.v1', 'zh');
  final repository = InMemoryLedgerRepository();
  final controller = await VeriFinController.create(
    store,
    repository: repository,
    fundSecuritySearchClient: search,
  );
  final account = investmentAccountFixture(id: 'manual-fund-ui');
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '5000',
      openedAt: DateTime.utc(2025, 1, 1),
      securities: existing == null ? const [] : [existing],
      manualPrices: existing == null ? const {} : {existing.id: '125'},
    ),
    isTrue,
  );
  addTearDown(controller.dispose);
  return (controller: controller, account: account, repository: repository);
}

/// 在真实导航栈打开基金已有持仓表单；[size]、[scale] 分别控制窄屏及系统大字号。
/// 返回/保存仍经过页面自带离页保护，测试不通过直接操作状态跳过用户确认。
Future<void> _pump(
  WidgetTester tester,
  VeriFinController controller,
  Account account, {
  Size size = const Size(393, 852),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => FundEntryPage(
                    accountId: account.id,
                    mode: FundEntryMode.holdingBaseline,
                  ),
                ),
              ),
              child: const Text('打开手工基金验收'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开手工基金验收'));
  await tester.pumpAndSettle();
}

/// 查找当前可见表单的滚动容器；候选浮层独立滚动，不应被当成父页面列表。
Finder _formScroll() => find
    .descendant(
      of: find.byType(FundSecurityEditorPage).evaluate().isNotEmpty
          ? find.byType(FundSecurityEditorPage)
          : find.byType(FundEntryPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 从当前表单页首滚动到 [target]，避免上一轮在页尾时向错误方向寻找上方字段。
Future<void> _reveal(WidgetTester tester, Finder target) async {
  final scroll = _formScroll();
  await tester.drag(scroll, const Offset(0, 5000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: scroll,
    maxScrolls: 50,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// 从父表单打开真实“手动新增基金”子页面，保留尚未保存的父表单。
Future<void> _openIdentity(WidgetTester tester) async {
  final add = find.byKey(const Key('fund-add-manually'));
  await _reveal(tester, add);
  await tester.tap(add);
  await tester.pumpAndSettle();
  expect(find.byType(FundSecurityEditorPage), findsOneWidget);
}

/// 通过文本框填写完整 [key] 对应的字段，[text] 为用户输入而非直接修改控制器状态。
Future<void> _enter(WidgetTester tester, String key, String text) async {
  final input = find.byKey(ValueKey(key));
  await _reveal(tester, input);
  await tester.enterText(input, text);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

/// 读取输入框当前展示的草稿，不能用查询结果或持久化模型代替真实输入状态。
String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

/// 点击子页统一保存按钮，只将证券身份返回父草稿；它本身不得提交申购或持仓。
Future<void> _saveIdentity(WidgetTester tester) async {
  final save = find.byType(SaveHeaderAction);
  await _reveal(tester, save);
  await tester.tap(save);
  await tester.pumpAndSettle();
  expect(find.byType(FundSecurityEditorPage), findsNothing);
  expect(find.byType(FundEntryPage), findsOneWidget);
}

/// 手动填写一个非预置香港美元基金；[name] 可以使用长文案验证真实页面换行。
Future<void> _manualIdentity(
  WidgetTester tester, {
  String name = '自选美元货币基金 B 类',
}) async {
  await _openIdentity(tester);
  await _enter(tester, 'fund-identity-symbol', 'manual-usd-b');
  await _enter(tester, 'fund-identity-name', name);
  await _saveIdentity(tester);
}

/// 使用正式金额键盘填写成本，不直接向只读金额框注入文字或私有控制器值。
Future<void> _cost(WidgetTester tester) async {
  final field = find.byKey(const Key('fund-cost'));
  await _reveal(tester, field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('number_key_C')));
  for (final character in '1000'.split('')) {
    await tester.tap(find.byKey(Key('number_key_$character')));
  }
  await tester.pump();
  await tester.tap(find.byKey(const Key('number_pad_ok')));
  await tester.pumpAndSettle();
}

/// 填写真实份额、总成本与每份净值，并明确核对后提交父表单。
/// 本地固定值仅供验证数量和成本保存；不会把万份收益或年化收益当成每份净值。
Future<void> _saveHolding(WidgetTester tester) async {
  await _enter(tester, 'fund-confirmedQuantity', '10');
  await _cost(tester);
  await _enter(tester, 'fund-nav', '100');
  final reviewed = find.byKey(const Key('fund-reviewed'));
  await _reveal(tester, reviewed);
  await tester.tap(reviewed);
  await tester.pumpAndSettle();
  final save = find.byKey(const Key('fund-save'));
  await _reveal(tester, save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

/// 只有点击查询按钮才触发客户端，输入变化本身不能自动调用外部来源。
Future<void> _search(WidgetTester tester) async {
  final button = find.byKey(const Key('fund-search-online'));
  await _reveal(tester, button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// 验收身份草稿、联网候选和最终持仓之间的明确提交边界，全部使用正式 Widget。
void main() {
  useTestDatabases();

  testWidgets('新增其他基金只返回父草稿，父页不保存时不留下证券或持仓', (tester) async {
    final search = _FundSearchClient();
    final ready = await _ready(search);
    final before = ready.controller.investmentFor(ready.account.id)!.toJson();
    await _pump(tester, ready.controller, ready.account);
    await _manualIdentity(tester);
    expect(find.text('自选美元货币基金 B 类'), findsOneWidget);
    expect(ready.controller.investmentFor(ready.account.id)!.toJson(), before);
    expect(
      (await ready.repository.loadInvestmentPortfolios()).single.toJson(),
      before,
    );
    await Navigator.of(tester.element(find.byType(FundEntryPage))).maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '不保存'));
    await tester.pumpAndSettle();
    expect(find.byType(FundEntryPage), findsNothing);
    expect(ready.controller.investmentFor(ready.account.id)!.toJson(), before);
    expect(
      (await ready.repository.loadInvestmentPortfolios()).single.toJson(),
      before,
    );
    expect(search.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final (size, scale) in [
    (const Size(393, 852), 1.0),
    (const Size(360, 740), 1.5),
  ]) {
    testWidgets('${size.width}dp 字号 $scale 手工基金可保存且保持基金真实身份', (tester) async {
      final search = _FundSearchClient();
      final ready = await _ready(search);
      await _pump(
        tester,
        ready.controller,
        ready.account,
        size: size,
        scale: scale,
      );
      await _manualIdentity(tester, name: '用户手动录入的其他美元货币市场基金 B 类');
      expect(
        ready.controller.investmentFor(ready.account.id)!.securities,
        isEmpty,
      );
      await _saveHolding(tester);
      expect(find.byType(FundEntryPage), findsNothing);
      final saved = ready.controller.investmentFor(ready.account.id)!;
      final security = saved.securities.single;
      expect(security.symbol, 'MANUAL-USD-B');
      expect(security.name, '用户手动录入的其他美元货币市场基金 B 类');
      expect(security.type, InvestmentSecurityType.fund);
      expect(security.market, StockMarket.hk);
      expect(security.currencyCode, 'USD');
      expect(security.id, 'hk:fund:MANUAL-USD-B');
      expect(saved.events.single.kind, StockEventKind.fundHoldingBaseline);
      expect(saved.events.single.quantity, '10');
      expect(saved.events.single.carriedCost, '1000');
      expect(saved.manualPrices[security.id], '100');
      expect(ready.controller.accountBalance(ready.account), 5000);
      expect(ready.controller.entries, isEmpty);
      expect(
        (await ready.repository.loadInvestmentPortfolios()).single.toJson(),
        saved.toJson(),
      );
      expect(search.requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('输入不联网，查询返回仅展示候选，主动点选后才带入名称', (tester) async {
    final search = _FundSearchClient();
    final ready = await _ready(search);
    await _pump(tester, ready.controller, ready.account);
    await _openIdentity(tester);
    await _enter(tester, 'fund-identity-name', '手工名称仍待核对');
    await _enter(tester, 'fund-identity-symbol', _queriedFund.symbol);
    expect(search.requests, isEmpty);
    await _search(tester);
    expect(search.requests.single.query, _queriedFund.symbol);
    expect(search.requests.single.market, StockMarket.hk);
    expect(search.requests.single.currency, 'USD');
    search.requests.single.result.complete([_queriedFund]);
    await tester.pumpAndSettle();
    expect(_text(tester, 'fund-identity-name'), '手工名称仍待核对');
    final candidate = find.byKey(
      ValueKey('investment-security-${_queriedFund.id}'),
    );
    expect(candidate, findsOneWidget);
    expect(
      ready.controller.investmentFor(ready.account.id)!.securities,
      isEmpty,
    );
    await tester.tap(candidate);
    await tester.pumpAndSettle();
    expect(_text(tester, 'fund-identity-name'), _queriedFund.name);
    expect(_text(tester, 'fund-identity-symbol'), _queriedFund.symbol);
    await _saveIdentity(tester);
    expect(find.text(_queriedFund.name), findsOneWidget);
    expect(
      ready.controller.investmentFor(ready.account.id)!.securities,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询过程中修改代码或名称均废弃旧响应，不覆盖正在填写的资料', (tester) async {
    final search = _FundSearchClient();
    final ready = await _ready(search);
    await _pump(tester, ready.controller, ready.account);
    await _openIdentity(tester);
    await _enter(tester, 'fund-identity-symbol', _queriedFund.symbol);
    await _search(tester);
    await _enter(tester, 'fund-identity-name', '等待期间填写的新名称');
    search.requests.first.result.complete([_queriedFund]);
    await tester.pumpAndSettle();
    expect(_text(tester, 'fund-identity-name'), '等待期间填写的新名称');
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    await _search(tester);
    await _enter(tester, 'fund-identity-symbol', 'MANUAL-CHANGED');
    search.requests.last.result.complete([_queriedFund]);
    await tester.pumpAndSettle();
    expect(_text(tester, 'fund-identity-symbol'), 'MANUAL-CHANGED');
    expect(_text(tester, 'fund-identity-name'), '等待期间填写的新名称');
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    expect(search.requests, hasLength(2));
    expect(
      ready.controller.investmentFor(ready.account.id)!.securities,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询失败和没有结果保留草稿，仍能手工完成基金资料', (tester) async {
    final search = _FundSearchClient();
    final ready = await _ready(search);
    await _pump(tester, ready.controller, ready.account);
    await _openIdentity(tester);
    await _enter(tester, 'fund-identity-name', '保留的手工基金名称');
    await _enter(tester, 'fund-identity-symbol', _queriedFund.symbol);
    final l = AppLocalizations.of(
      tester.element(find.byType(FundSecurityEditorPage)),
    );
    await _search(tester);
    search.requests.first.result.completeError(StateError('固定离线查询失败'));
    await tester.pumpAndSettle();
    expect(find.text(l.fundSearchFailed), findsOneWidget);
    expect(_text(tester, 'fund-identity-name'), '保留的手工基金名称');
    expect(_text(tester, 'fund-identity-symbol'), _queriedFund.symbol);
    await _search(tester);
    search.requests.last.result.complete([]);
    await tester.pumpAndSettle();
    expect(find.text(l.fundSearchNoResults), findsOneWidget);
    await _enter(tester, 'fund-identity-symbol', 'MANUAL-OFFLINE');
    await _saveIdentity(tester);
    expect(find.text('保留的手工基金名称'), findsOneWidget);
    expect(
      ready.controller.investmentFor(ready.account.id)!.securities,
      isEmpty,
    );
    expect(search.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('查询中切到账本外丢弃响应，切回原账本后无需改输入也能重新查询', (tester) async {
    final search = _FundSearchClient();
    final ready = await _ready(search);
    final originalBookId = ready.controller.activeBook.id;
    final originalPortfolio = ready.controller
        .investmentFor(ready.account.id)!
        .toJson();
    expect(await ready.controller.createLedgerBook('查询期间切换的账本'), isTrue);
    final otherBookId = ready.controller.activeBook.id;
    expect(otherBookId, isNot(originalBookId));
    ready.controller.switchLedgerBook(originalBookId);
    await _pump(tester, ready.controller, ready.account);
    await _openIdentity(tester);
    await _enter(tester, 'fund-identity-symbol', _queriedFund.symbol);
    await _search(tester);
    expect(search.requests, hasLength(1));
    ready.controller.switchLedgerBook(otherBookId);
    await tester.pumpAndSettle();
    search.requests.single.result.complete([_queriedFund]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    ready.controller.switchLedgerBook(originalBookId);
    await tester.pumpAndSettle();
    expect(_text(tester, 'fund-identity-symbol'), _queriedFund.symbol);
    final button = find.byKey(const Key('fund-search-online'));
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await _search(tester);
    expect(search.requests, hasLength(2));
    search.requests.last.result.complete([]);
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    expect(
      ready.controller.investmentFor(ready.account.id)!.toJson(),
      originalPortfolio,
    );
    expect(
      (await ready.repository.loadInvestmentPortfolios()).single.toJson(),
      originalPortfolio,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('同代码大小写不同仍复用已有基金，查询及保存不覆盖用户名称和后备价', (tester) async {
    const existing = StockSecurity(
      symbol: 'manual-existing',
      name: '用户自行保存的基金名称',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    const remote = StockSecurity(
      symbol: 'MANUAL-EXISTING',
      name: '查询来源中的另一种名称',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    final search = _FundSearchClient();
    final ready = await _ready(search, existing: existing);
    final originalPortfolio = ready.controller
        .investmentFor(ready.account.id)!
        .toJson();
    await _pump(tester, ready.controller, ready.account);
    await _openIdentity(tester);
    await _enter(tester, 'fund-identity-symbol', remote.symbol);
    // 已有本地候选可能覆盖下方查询按钮，按真实键盘 Esc 收起后再主动查询。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _search(tester);
    search.requests.single.result.complete([remote]);
    await tester.pumpAndSettle();
    final candidate = find.byKey(
      ValueKey('investment-security-${existing.id}'),
    );
    expect(candidate, findsOneWidget);
    expect(find.text(remote.name), findsNothing);
    await tester.tap(candidate);
    await tester.pumpAndSettle();
    expect(_text(tester, 'fund-identity-symbol'), existing.symbol);
    expect(_text(tester, 'fund-identity-name'), existing.name);
    // 即使用户在“新增资料”中改名，也须复用原身份；该入口不承担修改既有基金资料。
    await _enter(tester, 'fund-identity-name', '新增页不能改写的名称');
    await _saveIdentity(tester);
    expect(find.text(existing.name), findsOneWidget);
    expect(
      ready.controller.investmentFor(ready.account.id)!.toJson(),
      originalPortfolio,
    );
    await _saveHolding(tester);
    final saved = ready.controller.investmentFor(ready.account.id)!;
    expect(saved.securities.single.toJson(), existing.toJson());
    expect(saved.events.single.securityId, existing.id);
    expect(saved.manualPrices, {existing.id: '125'});
    expect(
      saved.securities.any((security) => security.id == remote.id),
      isFalse,
    );
    expect(
      (await ready.repository.loadInvestmentPortfolios()).single.toJson(),
      saved.toJson(),
    );
    expect(tester.takeException(), isNull);
  });
}
