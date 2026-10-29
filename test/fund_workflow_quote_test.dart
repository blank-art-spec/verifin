import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/investment_quote_sync.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/market_quote_fixture.dart';
import 'support/test_harness.dart';

/// 仅供本地阶段与行情链路验证的固定身份；下面的净值是合成夹具，不是官方网站数据。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 复用既有请求计数适配器；[clock] 是抓取时刻，[lastDate] 决定合成历史覆盖的香港纯日期。
/// 只返回前一点100和末点101，不请求互联网；请求内容仍只有公开身份，不能携带申购或账户。
FixtureQuoteAdapter _adapter({
  required DateTime Function() clock,
  required DateTime Function() lastDate,
}) => FixtureQuoteAdapter(
  (requests) async {
    final end = lastDate();
    final history = FundNavHistory([
      FundNavPoint(
        date: DateTime.utc(end.year, end.month, end.day - 1),
        price: '100.0000',
      ),
      FundNavPoint(date: end, price: '101.0000'),
    ]);
    return [
      for (final request in requests)
        MarketQuote(
          securityId: request.securityId,
          source: '本地测试夹具',
          currency: 'USD',
          unit: QuotePriceUnit.fundUnit,
          fetchedAt: clock().toUtc(),
          last: history.points.last.price,
          lastAt: end,
          dateOnly: true,
          navHistory: history,
        ),
    ];
  },
  support: (request) =>
      request.securityId == _fund.id &&
      request.fund &&
      !request.option &&
      request.market == StockMarket.hk &&
      request.currency == 'USD',
);

/// 构造已付款但尚未确认的固定申请；2098年用于让注入时钟与真实机器时间明确分离。
FundSubscription _pending() => FundSubscription(
  id: 'fund-pending',
  securityId: _fund.id,
  requestedAt: DateTime.utc(2098, 10, 25, 3),
  paidAt: DateTime.utc(2098, 10, 26, 4),
  cashAmount: '101',
  fee: '1',
);

/// 组合零期初持仓的独立聚合；[adopted] 模拟用户明确选择公开净值，不伪造持仓以拿报价。
InvestmentPortfolio _portfolio(
  FundSubscription subscription, {
  bool adopted = false,
  List<StockEvent> events = const [],
}) => InvestmentPortfolio(
  accountId: 'pending-fund-quotes',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime.utc(2098, 10, 1),
  openingCash: '1000',
  securities: const [_fund],
  fundSubscriptions: [subscription],
  events: events,
  manualPrices: {_fund.id: '100'},
  marketPriceIds: {if (adopted) _fund.id},
);

/// 将已确认申请 [subscription] 转成唯一零现金份额事实，起算日期交给公共helper解释。
StockEvent _acquire(FundSubscription subscription) => StockEvent(
  id: 'fund-acquire',
  securityId: _fund.id,
  kind: StockEventKind.fundAcquire,
  occurredAt: fundSubscriptionEffectiveAt(subscription)!,
  sequence: 1,
  quantity: subscription.confirmation!.quantity,
  price: subscription.confirmation!.nav,
  carriedCost: subscription.cashAmount,
  fundSubscriptionId: subscription.id,
  fundNavDate: subscription.confirmation!.navDate,
);

/// 建立只用本地来源的同步器；[clock] 固定持仓和报价的共同截点，不启动自动计时器。
Future<InvestmentQuoteSync> _sync(
  InvestmentPortfolio portfolio,
  FixtureQuoteAdapter adapter, {
  required DateTime Function() clock,
}) async {
  final sync = InvestmentQuoteSync(
    store: LocalKeyValueStore(),
    client: MarketQuoteClient(adapters: [adapter]),
    clock: clock,
  );
  addTearDown(sync.dispose);
  sync.reconcile([portfolio]);
  sync.setVisible(portfolio);
  expect(await sync.configure(enabled: true, automatic: false), isTrue);
  return sync;
}

/// 覆盖首次净值获取、未生效确认、退款后的历史补齐与时钟注入；全程不访问真实接口。
void main() {
  useTestDatabases();

  test('仅待确认申购也能首次手动刷新，取得公开历史后用户可以采纳', () async {
    final now = DateTime.now().toUtc();
    final adapter = _adapter(
      clock: () => DateTime.now().toUtc(),
      lastDate: () => hongKongFundDate(now),
    );
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
      marketQuoteClient: MarketQuoteClient(adapters: [adapter]),
    );
    addTearDown(controller.dispose);
    final account = investmentAccountFixture(id: 'only-fund-subscription');
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openedAt: DateTime.utc(2020, 1, 1),
        openingCash: '1000',
        securities: const [_fund],
      ),
      isTrue,
    );
    expect(
      await controller.saveFundSubscription(
        accountId: account.id,
        security: _fund,
        subscription: FundSubscription(
          id: 'only-pending-order',
          securityId: _fund.id,
          requestedAt: now.subtract(const Duration(hours: 2)),
          paidAt: now.subtract(const Duration(hours: 1)),
          cashAmount: '101',
          fee: '1',
        ),
      ),
      isTrue,
    );
    final portfolio = controller.investmentFor(account.id)!;
    expect(portfolio.openingHoldings, isEmpty);
    expect(portfolio.events, isEmpty);
    expect(portfolio.marketPriceIds, isEmpty);
    final sync = controller.investmentQuoteSync;
    sync.setVisible(portfolio);
    expect(await sync.configure(enabled: true, automatic: false), isTrue);
    expect(sync.hasSupportedHoldings(portfolio), isTrue);
    expect(
      await sync.refresh(
        portfolio,
        isCurrent: () =>
            identical(controller.investmentFor(account.id), portfolio),
      ),
      isTrue,
    );
    expect(adapter.requests, 1);
    expect(adapter.lastRequests.map((request) => request.securityId), [
      _fund.id,
    ]);
    final history = sync.fundNavHistoryFor(portfolio, _fund.id)!;
    expect(history.points.last.date, hongKongFundDate(now));
    // 在途资金没有冒充份额；历史入口可以读净值，默认持仓报价仍为空。
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(sync.quotesFor(portfolio, includeFundHistory: true).keys, [
      _fund.id,
    ]);
    expect(
      await controller.setInvestmentMarketPrice(account.id, _fund.id, true),
      isTrue,
    );
    final adopted = controller.investmentFor(account.id)!;
    expect(adopted.marketPriceIds, contains(_fund.id));
    expect(adopted.openingHoldings, isEmpty);
    expect(adopted.events, isEmpty);
    expect(
      sync.fundNavHistoryFor(adopted, _fund.id)!.toJson(),
      history.toJson(),
    );
    expect(controller.accountBalance(account), 899);
  });

  test('已确认但未来起算仍可首次刷新，不提前把参考份额用于当前持仓报价', () async {
    final now = DateTime.utc(2098, 10, 28, 4);
    final order = _pending().copyWith(
      confirmation: FundSubscriptionConfirmation(
        confirmedAt: DateTime.utc(2098, 10, 27, 4),
        navDate: DateTime.utc(2098, 10, 26),
        earningStartDate: DateTime.utc(2098, 10, 29),
        nav: '100',
        quantity: '1',
      ),
    );
    final portfolio = _portfolio(order, events: [_acquire(order)]);
    validateFundSubscriptions(portfolio);
    final adapter = _adapter(
      clock: () => now,
      lastDate: () => DateTime.utc(2098, 10, 28),
    );
    final sync = await _sync(portfolio, adapter, clock: () => now);
    expect(portfolio.marketPriceIds, isEmpty);
    expect(sync.hasSupportedHoldings(portfolio), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(sync.fundNavHistoryFor(portfolio, _fund.id), isNotNull);
    expect(sync.quotesFor(portfolio), isEmpty);
    expect(fundSubscriptionPendingValue(portfolio, at: now).toString(), '100');
    expect(adapter.requests, 1);
  });

  test('起算后的请求选择和默认报价都采用注入时钟，不使用真实机器时间', () async {
    var now = DateTime.utc(2098, 10, 28, 4);
    final order = _pending().copyWith(
      confirmation: FundSubscriptionConfirmation(
        confirmedAt: DateTime.utc(2098, 10, 27, 4),
        navDate: DateTime.utc(2098, 10, 26),
        earningStartDate: DateTime.utc(2098, 10, 29),
        nav: '100',
        quantity: '1',
      ),
    );
    final portfolio = _portfolio(order, events: [_acquire(order)]);
    final adapter = _adapter(
      clock: () => now,
      lastDate: () => hongKongFundDate(now),
    );
    final sync = await _sync(portfolio, adapter, clock: () => now);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(sync.quotesFor(portfolio), isEmpty);
    now = DateTime.utc(2098, 10, 29, 4);
    // 未采用且确认已生效时，只能由真实持仓选入请求；遗漏at:clock会在这里退回零持仓。
    expect(sync.hasSupportedHoldings(portfolio), isTrue);
    expect(sync.quotesFor(portfolio).keys, [_fund.id]);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(adapter.requests, 2);
    expect(
      sync.quotesFor(portfolio)[_fund.id]!.lastAt,
      DateTime.utc(2098, 10, 29),
    );
    expect(fundSubscriptionPendingValue(portfolio, at: now).toString(), '0');
  });

  test('取消退款后只补齐最后资金日的历史，覆盖完成后停止空持仓自动需求', () async {
    var now = DateTime.utc(2098, 10, 30, 4);
    var lastDate = DateTime.utc(2098, 10, 28);
    final order = _pending().copyWith(
      cancelledAt: DateTime.utc(2098, 10, 28, 4),
      refundedAt: DateTime.utc(2098, 10, 29, 4),
      refundAmount: '100',
    );
    final portfolio = _portfolio(order, adopted: true);
    validateFundSubscriptions(portfolio);
    final adapter = _adapter(clock: () => now, lastDate: () => lastDate);
    final sync = await _sync(portfolio, adapter, clock: () => now);
    expect(sync.hasSupportedHoldings(portfolio), isTrue);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(
      sync.fundNavHistoryFor(portfolio, _fund.id)!.points.last.date,
      lastDate,
    );
    expect(sync.hasSupportedHoldings(portfolio), isTrue);
    lastDate = DateTime.utc(2098, 10, 29);
    expect(await sync.refresh(portfolio, isCurrent: () => true), isTrue);
    expect(
      sync.fundNavHistoryFor(portfolio, _fund.id)!.points.last.date,
      lastDate,
    );
    expect(sync.hasSupportedHoldings(portfolio), isFalse);
    expect(sync.quotesFor(portfolio), isEmpty);
    now = DateTime.utc(2098, 10, 30, 5);
    expect(
      await sync.refresh(portfolio, isCurrent: () => true, automatic: true),
      isFalse,
    );
    expect(adapter.requests, 2);
    expect(fundSubscriptionPendingValue(portfolio, at: now).toString(), '0');
  });

  test('成交净值规则在重复确认、刷新、历史读取及冷启动后保持收益幂等', () async {
    final today = hongKongFundDate(DateTime.now());

    /// [offset] 按香港日历日移动，保持领域要求的 UTC 纯日期，避免固定历史年份或绝对日时长。
    DateTime day(int offset) {
      final shifted = addCalendarDays(today, offset);
      return DateTime.utc(shifted.year, shifted.month, shifted.day);
    }

    final dealDate = day(-5);
    final sourceHistory = FundNavHistory([
      FundNavPoint(date: day(-6), price: '99'),
      FundNavPoint(date: dealDate, price: '100'),
      FundNavPoint(date: day(-4), price: '101'),
      FundNavPoint(date: day(-3), price: '102'),
    ]);
    // 来源仍复用公共请求计数夹具；四个固定公开净值点不含用户资金或私人申购事实。
    final adapter = FixtureQuoteAdapter(
      (requests) async => [
        for (final request in requests)
          MarketQuote(
            securityId: request.securityId,
            source: '本地测试夹具',
            currency: 'USD',
            unit: QuotePriceUnit.fundUnit,
            fetchedAt: DateTime.now().toUtc(),
            last: sourceHistory.points.last.price,
            lastAt: sourceHistory.points.last.date,
            dateOnly: true,
            navHistory: sourceHistory,
          ),
      ],
      support: (request) =>
          request.securityId == _fund.id &&
          request.fund &&
          !request.option &&
          request.market == StockMarket.hk &&
          request.currency == 'USD',
    );
    final repository = InMemoryLedgerRepository();
    final store = LocalKeyValueStore();
    final client = MarketQuoteClient(adapters: [adapter]);
    var controller = await VeriFinController.create(
      store,
      repository: repository,
      marketQuoteClient: client,
    );
    var controllerAlive = true;
    try {
      final account = investmentAccountFixture(
        id: 'deal-nav-idempotent-fund',
        bookId: controller.activeBook.id,
      );
      controller.addAccount(account);
      await controller.waitForPendingWrites();
      expect(
        await controller.enableInvestment(
          accountId: account.id,
          openedAt: hongKongFundDayStart(day(-10)),
          openingCash: '5000',
          securities: const [_fund],
        ),
        isTrue,
      );
      const orderId = 'deal-nav-idempotent-order';
      expect(
        await controller.saveFundSubscription(
          accountId: account.id,
          security: _fund,
          subscription: FundSubscription(
            id: orderId,
            securityId: _fund.id,
            requestedAt: hongKongFundDayStart(
              day(-6),
            ).add(const Duration(hours: 9)),
            paidAt: hongKongFundDayStart(
              dealDate,
            ).add(const Duration(hours: 9)),
            cashAmount: '1000',
          ),
        ),
        isTrue,
      );
      final confirmation = FundSubscriptionConfirmation(
        confirmedAt: hongKongFundDayStart(
          day(-2),
        ).add(const Duration(hours: 10)),
        navDate: dealDate,
        earningStartDate: dealDate,
        nav: '100',
        quantity: '10',
        accrualRule: FundAccrualRule.dealNavDate,
      );
      Map<String, Object?>? expectedFacts;

      /// 对当前控制器反复读取同一公开历史，验证参考结果不增量落账，也不会重加份额或累计收益。
      /// 冷启动后仍调用此检查，要求恢复的真实成本、现金、规则及净值日期均与首次采用后相同。
      void expectStableHistory() {
        final portfolio = controller.investmentFor(account.id)!;
        expect(portfolio.toJson(), expectedFacts);
        expect(portfolio.events, hasLength(1));
        expect(portfolio.events.single.kind, StockEventKind.fundAcquire);
        expect(portfolio.events.single.fundSubscriptionId, orderId);
        expect(portfolio.events.single.carriedCost, '1000');
        expect(
          portfolio.fundSubscriptions.single.confirmation!.accrualRule,
          FundAccrualRule.dealNavDate,
        );
        final position = controller
            .investmentProjection(account.id)!
            .positions
            .single;
        expect(position.quantity.toString(), '10');
        expect(position.cost?.toString(), '1000');
        expect(controller.accountBalance(account), 4000);
        final history = controller.investmentQuoteSync.fundNavHistoryFor(
          portfolio,
          _fund.id,
        )!;
        expect(
          history.points.map((point) => point.date),
          sourceHistory.points.map((point) => point.date),
        );
        expect(history.points.map((point) => point.date).toSet(), hasLength(4));
        expect(history.points, hasLength(4));
        for (var read = 0; read < 3; read++) {
          final days = controller.fundReferenceHistoryFor(account.id, _fund.id);
          expect(days.map((point) => point.dailyProfit?.toString()), [
            null,
            '0',
            '10',
            '10',
          ]);
          expect(days.map((point) => point.cumulativeProfit?.toString()), [
            '0',
            '0',
            '10',
            '20',
          ]);
          expect(days.last.marketValue.toString(), '1020');
          expect(days.last.accountNetValue, 5020);
        }
        expect(controller.investmentFor(account.id)!.toJson(), expectedFacts);
        expect(portfolio.valuationSnapshots, isEmpty);
        expect(controller.entries, isEmpty);
      }

      for (var repeat = 0; repeat < 3; repeat++) {
        expect(
          await controller.confirmFundSubscription(
            accountId: account.id,
            subscriptionId: orderId,
            confirmation: confirmation,
          ),
          isTrue,
        );
        final portfolio = controller.investmentFor(account.id)!;
        final sync = controller.investmentQuoteSync;
        sync.setVisible(portfolio);
        if (repeat == 0) {
          expect(await sync.configure(enabled: true, automatic: false), isTrue);
        }
        expect(
          await sync.refresh(
            portfolio,
            isCurrent: () =>
                identical(controller.investmentFor(account.id), portfolio),
          ),
          isTrue,
        );
        if (repeat == 0) {
          expect(
            await controller.setInvestmentMarketPrice(
              account.id,
              _fund.id,
              true,
            ),
            isTrue,
          );
          expectedFacts = controller.investmentFor(account.id)!.toJson();
        }
        expectStableHistory();
        await controller.waitForPendingWrites();
        expect(
          (await repository.loadInvestmentPortfolios()).single.toJson(),
          expectedFacts,
        );
        expect(await repository.loadEntries(), isEmpty);
      }
      expect(adapter.requests, 3);
      controller.dispose();
      controllerAlive = false;
      controller = await VeriFinController.create(
        store,
        repository: repository,
        marketQuoteClient: client,
      );
      controllerAlive = true;
      // 冷启动只读取原有缓存，不主动请求，也不要求用户重新采纳已保存的净值来源。
      expectStableHistory();
      expect(adapter.requests, 3);
      final restored = controller.investmentFor(account.id)!;
      final sync = controller.investmentQuoteSync;
      sync.setVisible(restored);
      expect(
        await sync.refresh(
          restored,
          isCurrent: () =>
              identical(controller.investmentFor(account.id), restored),
        ),
        isTrue,
      );
      expect(adapter.requests, 4);
      expectStableHistory();
      expect(await repository.loadEntries(), isEmpty);
    } finally {
      // 新控制器创建失败时不能再次释放旧实例，避免掩盖真正失败并留下存活的测试订阅。
      if (controllerAlive) controller.dispose();
    }
  });
}
