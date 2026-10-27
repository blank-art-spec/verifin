import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/production_market_quotes.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';
import 'support/research_quote_fixture.dart';

/// 创建固定 AVGO 持仓及后备价；只用于验证来源开关与冷启动缓存的安全边界。
InvestmentPortfolio _researchHolding() => portfolioFixture(
  opening: [
    StockHolding(
      securityId: avgoFixture.id,
      short: false,
      quantity: '2',
      cost: '600',
    ),
  ],
  price: '300',
);

/// 构造本地已知时间的股票观察；[time] 同时作为夹具源时间和抓取时间。
MarketQuote _researchQuote(DateTime time) => MarketQuote(
  securityId: avgoFixture.id,
  source: researchFixtureSourceId,
  currency: 'USD',
  unit: QuotePriceUnit.share,
  fetchedAt: time,
  last: '350',
  lastAt: time,
);

/// 注册研究构建矩阵、来源隔离及缓存降级检查；没有真实网络、设备或用户数据。
void main() {
  test('明确的 diagnostic 调试研究构建可用，普通测试入口保持空来源', () {
    expect(
      permitsQuoteResearch(
        debugBuild: true,
        flavor: 'diagnostic',
        explicitlyEnabled: true,
      ),
      isTrue,
    );
    expect(buildProductionMarketQuoteClient().adapters, isEmpty);
  });
  for (final build in [
    (label: '诊断 release', debug: false, flavor: 'diagnostic', enabled: true),
    (label: '诊断未显式开启', debug: true, flavor: 'diagnostic', enabled: false),
    (label: 'GitHub 调试', debug: true, flavor: 'github', enabled: true),
    (label: 'Play 调试', debug: true, flavor: 'play', enabled: true),
    (label: 'GitHub release', debug: false, flavor: 'github', enabled: true),
    (label: 'Play release', debug: false, flavor: 'play', enabled: true),
    (label: '未指定渠道', debug: true, flavor: null, enabled: true),
  ]) {
    test('${build.label} 不能被研究参数开启公开来源', () {
      expect(
        permitsQuoteResearch(
          debugBuild: build.debug,
          flavor: build.flavor,
          explicitlyEnabled: build.enabled,
        ),
        isFalse,
      );
    });
  }

  test('普通客户端不接受研究来源，也不把研究可用当作正式准入', () {
    final adapter = ResearchFixtureQuoteAdapter((_) async => []);
    final client = MarketQuoteClient(adapters: [adapter]);

    expect(adapter.capability.approved, isFalse);
    expect(adapter.capability.researchOnly, isTrue);
    expect(client.allowsAdapter(adapter), isFalse);
    expect(client.hasAvailableSources, isFalse);
    expect(client.hasResearchSources, isFalse);
    expect(client.hasApprovedSources, isFalse);
    expect(client.adapterFor(MarketQuoteRequest(avgoFixture)), isNull);
    expect(adapter.requests, 0);
  });

  test('显式研究模式仍拒绝普通待审核来源，只选择明确标记的研究来源', () {
    final pending = ResearchFixtureQuoteAdapter(
      (_) async => [],
      researchOnly: false,
    );
    final research = ResearchFixtureQuoteAdapter((_) async => []);
    final onlyPending = MarketQuoteClient(
      adapters: [pending],
      allowResearchSources: true,
    );
    expect(onlyPending.hasAvailableSources, isFalse);
    expect(onlyPending.allowsAdapter(pending), isFalse);
    expect(onlyPending.adapterFor(MarketQuoteRequest(avgoFixture)), isNull);

    final client = MarketQuoteClient(
      adapters: [pending, research],
      allowResearchSources: true,
    );
    expect(client.hasApprovedSources, isFalse);
    expect(client.hasAvailableSources, isTrue);
    expect(client.hasResearchSources, isTrue);
    expect(client.adapterFor(MarketQuoteRequest(avgoFixture)), same(research));
    expect(client.adapterFor(MarketQuoteRequest(optionFixture())), isNull);
    expect(pending.requests, 0);
    expect(research.requests, 0);
  });

  test('普通客户端即使装有研究适配器也不能开启或发出查询', () async {
    final time = DateTime.utc(2026, 10, 27, 2);
    final adapter = ResearchFixtureQuoteAdapter(
      (_) async => [_researchQuote(time)],
    );
    final portfolio = _researchHolding();
    final sync = InvestmentQuoteSync(
      store: LocalKeyValueStore(),
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => time,
    );
    addTearDown(sync.dispose);
    sync.reconcile([portfolio]);
    sync.setVisible(portfolio);

    expect(await sync.configure(enabled: true, automatic: false), isFalse);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(adapter.requests, 0);
  });

  test('研究缓存与开启偏好换回正式客户端后不能恢复联网或旧报价', () async {
    final time = DateTime.utc(2026, 10, 27, 2);
    final store = LocalKeyValueStore();
    final portfolio = _researchHolding();
    final adapter = ResearchFixtureQuoteAdapter(
      (_) async => [_researchQuote(time)],
    );
    final research = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(
        adapters: [adapter],
        allowResearchSources: true,
      ),
      clock: () => time,
    );
    research.reconcile([portfolio]);
    expect(await research.configure(enabled: true, automatic: false), isTrue);
    research.setVisible(portfolio);
    expect(await research.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(research.quotesFor(portfolio)[avgoFixture.id]?.last, '350');
    expect(
      store.read('investment_quote_cache_v1'),
      contains(researchFixtureSourceId),
    );
    expect(
      store.read('investment_quote_settings_v1'),
      contains('"enabled":true'),
    );
    research.dispose();

    // 保留相同缓存和适配器，仅撤销构建许可；设备中的旧开启标记不能恢复研究能力。
    final formal = InvestmentQuoteSync(
      store: store,
      client: MarketQuoteClient(adapters: [adapter]),
      clock: () => time,
    );
    addTearDown(formal.dispose);
    formal.reconcile([portfolio]);
    formal.setVisible(portfolio);
    expect(formal.state.value.enabled, isFalse);
    expect(formal.quotesFor(portfolio), isEmpty);
    expect(await formal.configure(enabled: true, automatic: true), isFalse);
    expect(await formal.refresh(portfolio, isCurrent: () => true), isFalse);
    expect(adapter.requests, 1);
    expect(portfolio.manualPrices[avgoFixture.id], '300');
  });
}
