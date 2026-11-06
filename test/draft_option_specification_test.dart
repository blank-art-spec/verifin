import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/alpaca_option_quote_adapter.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';

final _request = MarketQuoteRequest.usOptionSymbol('SOFX261218P00009000');

/// 规格是明确标记的本地夹具；[multiplier] 与 [request] 用于模拟异常及错配响应。
OptionContractSpecification _specification({
  String multiplier = '100',
  String source = '本地规格夹具',
  MarketQuoteRequest? request,
}) => OptionContractSpecification(
  request: request ?? _request,
  premiumMultiplier: multiplier,
  source: source,
);

/// 分别统计草稿规格与行情查询，验证二者并行、相互不依赖且不发送真实网络请求。
class _Adapter extends MarketQuoteAdapter {
  _Adapter(this.respond);

  final Future<OptionContractSpecification?> Function() respond;
  bool approved = true;
  int specifications = 0, quotes = 0;
  bool Function()? current;

  @override
  QuoteSourceCapability get capability => QuoteSourceCapability(
    '本地规格夹具',
    approved: approved,
    reviewNote: '仅用于离线回归',
  );

  /// 只支持本用例的公开美股期权身份，不把股票混入规格请求。
  @override
  bool supports(MarketQuoteRequest request) => request.option;

  /// 行情始终无价格，用于证明无成交也能成功查询权利金乘数。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
    quotes++;
    return const [];
  }

  /// 保存 [isCurrent] 供用例验证撤销状态，响应可以暂停到设置或会话变化之后。
  @override
  Future<OptionContractSpecification?> fetchOptionSpecification(
    MarketQuoteRequest request, {
    required bool Function() isCurrent,
  }) {
    specifications++;
    current = isCurrent;
    return respond();
  }
}

/// 记录设备偏好写入次数；查询规格不得暗中保存缓存、联网偏好或自动刷新状态。
class _Preferences extends LocalKeyValueStore {
  int writes = 0;

  /// 委托原内存存储并记录明确落盘语义的调用次数。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    writes++;
    await super.writeAndFlush(key, value);
  }
}

/// 为 [adapter] 构造默认关闭联网的同步器；[store] 可观察查询是否产生写入。
InvestmentQuoteSync _sync(_Adapter adapter, {LocalKeyValueStore? store}) =>
    InvestmentQuoteSync(
      store: store ?? LocalKeyValueStore(),
      client: MarketQuoteClient(adapters: [adapter]),
    );

void main() {
  test('规格查询遵守联网、来源与品种门禁', () async {
    final adapter = _Adapter(() async => _specification());
    final sync = _sync(adapter);
    addTearDown(sync.dispose);
    expect(
      (await sync.fetchDraftOptionSpecification(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.networkDisabled,
    );
    await sync.configure(enabled: true, automatic: false);
    expect(
      (await sync.fetchDraftOptionSpecification(
        MarketQuoteRequest(avgoFixture),
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.unsupported,
    );
    adapter.approved = false;
    expect(
      (await sync.fetchDraftOptionSpecification(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.unsupported,
    );
    expect(adapter.specifications, 0);
  });

  test('规格与行情可并行，无成交仍返回准确乘数且不写缓存', () async {
    final pending = Completer<OptionContractSpecification?>();
    final adapter = _Adapter(() => pending.future);
    final store = _Preferences();
    final sync = _sync(adapter, store: store);
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final writes = store.writes, state = sync.state.value;
    final future = sync.fetchDraftOptionSpecification(
      _request,
      isCurrent: () => true,
    );
    expect(
      (await sync.fetchDraftOptionQuote(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.noQuote,
    );
    pending.complete(_specification(multiplier: '12.5'));
    final result = await future;
    expect(result.status, DraftOptionQuoteStatus.available);
    expect(result.specification!.premiumMultiplier, '12.5');
    expect(adapter.specifications, 1);
    expect(adapter.quotes, 1);
    expect(store.writes, writes);
    expect(store.read('investment_quote_cache_v1'), isNull);
    expect(sync.state.value, same(state));
  });

  test('无规格、错配身份、错误来源或无效乘数都不返回可采用资料', () async {
    OptionContractSpecification? response;
    final sync = _sync(_Adapter(() async => response));
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    for (final invalid in [
      null,
      _specification(source: '其他来源'),
      _specification(
        request: MarketQuoteRequest.usOptionSymbol('SOFX261218C00009000'),
      ),
      _specification(multiplier: '0'),
      _specification(multiplier: '-1'),
      _specification(multiplier: '不合法'),
    ]) {
      response = invalid;
      final result = await sync.fetchDraftOptionSpecification(
        _request,
        isCurrent: () => true,
      );
      expect(result.status, DraftOptionQuoteStatus.noQuote);
      expect(result.specification, isNull);
    }
  });

  test('重复规格请求不发送，关闭联网后迟到结果取消', () async {
    final pending = Completer<OptionContractSpecification?>();
    final adapter = _Adapter(() => pending.future);
    final sync = _sync(adapter);
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final first = sync.fetchDraftOptionSpecification(
      _request,
      isCurrent: () => true,
    );
    expect(
      (await sync.fetchDraftOptionSpecification(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.cancelled,
    );
    expect(adapter.specifications, 1);
    await sync.configure(enabled: false, automatic: false);
    expect(adapter.current!(), isFalse);
    pending.complete(_specification());
    expect((await first).status, DraftOptionQuoteStatus.cancelled);
  });

  test('退后台、销毁、调用方撤销和来源重配使旧规格失效', () async {
    for (final change in ['background', 'dispose', 'caller', 'source']) {
      final pending = Completer<OptionContractSpecification?>();
      final adapter = _Adapter(() => pending.future);
      final sync = _sync(adapter);
      var current = true;
      await sync.configure(enabled: true, automatic: false);
      sync.setForegroundPortfolios(const []);
      final future = sync.fetchDraftOptionSpecification(
        _request,
        isCurrent: () => current,
      );
      switch (change) {
        case 'background':
          sync.setForegroundPortfolios(null);
        case 'dispose':
          sync.dispose();
        case 'caller':
          current = false;
        case 'source':
          await sync.reconfigureSource(
            sourceId: adapter.capability.id,
            affectedPortfolios: const [],
            configure: () {},
          );
      }
      expect(adapter.current!(), isFalse, reason: change);
      pending.complete(_specification());
      expect(
        (await future).status,
        DraftOptionQuoteStatus.cancelled,
        reason: change,
      );
      if (change != 'dispose') sync.dispose();
    }
  });

  testWidgets('十五秒超时使回调失效，后续规格可以重查', (tester) async {
    final pending = Completer<OptionContractSpecification?>();
    var timedOut = false;
    final adapter = _Adapter(
      () async => timedOut ? _specification() : await pending.future,
    );
    final sync = _sync(adapter);
    addTearDown(sync.dispose);
    await sync.configure(enabled: true, automatic: false);
    final first = sync.fetchDraftOptionSpecification(
      _request,
      isCurrent: () => true,
    );
    await tester.pump(const Duration(seconds: 16));
    expect((await first).status, DraftOptionQuoteStatus.failed);
    expect(adapter.current!(), isFalse);
    pending.completeError(StateError('迟到的本地夹具错误'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    timedOut = true;
    expect(
      (await sync.fetchDraftOptionSpecification(
        _request,
        isCurrent: () => true,
      )).status,
      DraftOptionQuoteStatus.available,
    );
  });

  test('Controller 查询未保存合约不改变账目，切账本取消旧规格', () async {
    Completer<OptionContractSpecification?>? pending;
    final adapter = _Adapter(
      () async => pending == null ? _specification() : await pending.future,
    );
    final store = _Preferences();
    final controller = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
    );
    addTearDown(controller.dispose);
    await controller.investmentQuoteSync.configure(
      enabled: true,
      automatic: false,
    );

    /// 排除导出动作自身的时间字段，仅比较实际账务内容。
    Map<String, Object?> accountData() =>
        (jsonDecode(controller.exportDataJson()) as Map<String, Object?>)
          ..remove('exportedAt');
    final before = accountData(), writes = store.writes;
    expect(
      (await controller.fetchDraftOptionSpecification(_request)).status,
      DraftOptionQuoteStatus.available,
    );
    expect(accountData(), before);
    expect(store.writes, writes);
    pending = Completer<OptionContractSpecification?>();
    final old = controller.fetchDraftOptionSpecification(_request);
    controller.addLedgerBook('另一本账本');
    pending.complete(_specification());
    expect((await old).status, DraftOptionQuoteStatus.cancelled);
    await controller.waitForPendingWrites();
  });

  test('Controller 对支持合约明确反馈缺凭证，其他品种仍不支持', () async {
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(
        adapters: [AlpacaOptionQuoteAdapter()],
        allowResearchSources: true,
      ),
    );
    addTearDown(controller.dispose);
    await controller.investmentQuoteSync.configure(
      enabled: true,
      automatic: false,
    );
    expect(
      (await controller.fetchDraftOptionSpecification(_request)).status,
      DraftOptionQuoteStatus.credentialsRequired,
    );
    expect(
      (await controller.fetchDraftOptionSpecification(
        MarketQuoteRequest(avgoFixture),
      )).status,
      DraftOptionQuoteStatus.unsupported,
    );
  });
}
