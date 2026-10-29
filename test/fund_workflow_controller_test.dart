import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/investments/fund_amount_math.dart';
import 'package:verifin/app/investments/fund_reference_history.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

// 本文件全部净值均为离线固定夹具，包括 109.8290；不代表运行当日的真实报价。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 通过公开 Controller 命令验证基金生命周期的资金不变量，不联网、不生成普通收入。
void main() {
  useTestDatabases();
  late _FailingFundRepository repository;
  late VeriFinController controller;
  late LocalKeyValueStore store;
  late Account account;
  late _FundClock clock;

  setUp(() async {
    clock = _FundClock(DateTime.now().toUtc());
    repository = _FailingFundRepository();
    store = LocalKeyValueStore();
    controller = await VeriFinController.create(store, repository: repository);
    account = investmentAccountFixture(id: 'fund-workflow-usd');
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '5000',
        openedAt: clock.at(-30),
      ),
      isTrue,
    );
  });
  tearDown(() => controller.dispose());

  /// 读取当前账户的不可变聚合；所有实际写入均须经被测 Controller 公共命令完成。
  InvestmentPortfolio current() => controller.investmentFor(account.id)!;

  /// 保存单笔 [subscription]；[security] 可替换为非法身份，验证整个操作原子拒绝。
  Future<bool> save(
    FundSubscription subscription, {
    StockSecurity security = _fund,
  }) => controller.saveFundSubscription(
    accountId: account.id,
    security: security,
    subscription: subscription,
  );

  /// 按显式 [at] 计算账户现金和资产，避免用当前时钟代替待生效份额的历史截点。
  /// [anchors] 为该用例已落库的现金核对依据；默认空表示没有人为核对余额。
  InvestmentAccountValuation valuationAt(
    DateTime at, {
    List<BalanceAnchor> anchors = const [],
  }) {
    final portfolio = current();
    final cash = accountCashAt(
      account: account,
      portfolio: portfolio,
      entries: controller.entries,
      anchors: anchors,
      at: at,
    );
    return valueInvestmentAccount(investmentAt(portfolio, at), cash, at: at);
  }

  /// 将 [prices] 的相对香港日期和固定净值送入纯历史入口，验证真实写入事实的每日结果。
  /// [anchors] 保留现金核对的实际生效边界，不能用最新余额替代所有历史日期的现金。
  List<FundReferenceDay> history(
    Map<int, String> prices, {
    List<BalanceAnchor> anchors = const [],
  }) => buildFundReferenceHistory(
    portfolio: current(),
    security: _fund,
    history: FundNavHistory([
      for (final point in prices.entries)
        FundNavPoint(date: clock.date(point.key), price: point.value),
    ]),
    account: account,
    entries: controller.entries,
    anchors: anchors,
  );

  /// 在 [operation] 前后比对聚合、现金与仓储；失败不能留下只存在于内存的半笔事实。
  Future<void> expectAtomicRejection(Future<bool> Function() operation) async {
    final before = jsonEncode(current().toJson());
    final persisted = jsonEncode(
      (await repository.loadInvestmentPortfolios()).single.toJson(),
    );
    final cash = controller.accountBalance(account);
    expect(await operation(), isFalse);
    expect(jsonEncode(current().toJson()), before);
    expect(
      jsonEncode((await repository.loadInvestmentPortfolios()).single.toJson()),
      persisted,
    );
    expect(controller.accountBalance(account), cash);
    expect(controller.entries, isEmpty);
    expect(await repository.loadEntries(), isEmpty);
  }

  test('1401.31 美元申请不扣现金，实际付款才转成等额在途资产', () async {
    final requested = clock.order(cash: '1401.31');
    expect(await save(requested), isTrue);
    expect(controller.accountBalance(account), 5000);
    expect(valuationAt(clock.at(-1)).pendingSubscriptionValue, 0);
    expect(projectStocks(current()).positions, isEmpty);

    final paid = requested.copyWith(paidAt: clock.at(-8));
    expect(await save(paid), isTrue);
    expect(controller.accountBalance(account), closeTo(3598.69, 0.000001));
    final before = valuationAt(clock.at(-9));
    final after = valuationAt(clock.at(-7));
    expect(before.cash, 5000);
    expect(before.pendingSubscriptionValue, 0);
    expect(after.pendingSubscriptionValue, 1401.31);
    expect(after.longValue, 0);
    expect(after.amounts!.net, 5000);
    expect(after.unrealized, 0);
    expect(projectStocks(current()).income.toString(), '0');
    expect(current().events, isEmpty);
    expect(current().valuationSnapshots, isEmpty);
    expect(controller.entries, isEmpty);
    expect(await repository.loadEntries(), isEmpty);
    expect(
      (await repository.loadInvestmentPortfolios())
          .single
          .fundSubscriptions
          .single
          .paidAt,
      paid.paidAt,
    );
  });

  test('未来起算前无份额和收益，实际起算时仅转换资产形态且不重复扣款', () async {
    final order = clock.order(cash: '1401.31', paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    final historicalAt = clock.at(-7, hour: 23);
    final pendingRevision = investmentRevision(
      current(),
      const [],
      const [],
      historicalAt,
    );
    final beforeConfirmation = history({-7: '109.8290', -6: '110'});
    final reference = calculateFundPurchaseByAmount(
      cashAmount: '1401.31',
      nav: '109.8290',
      currencyCode: 'USD',
    );
    final confirmation = clock.confirmation(
      nav: '109.8290',
      quantity: reference.quantity.toString(),
      earningDay: 2,
    );
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        confirmation: confirmation,
      ),
      isTrue,
    );
    expect(
      investmentRevision(current(), const [], const [], historicalAt),
      pendingRevision,
      reason: '日后补录确认且费用未变，不能使付款后起算前的同一历史依据失效',
    );
    final afterConfirmation = history({-7: '109.8290', -6: '110'});
    expect(
      afterConfirmation.map((day) => day.cash),
      beforeConfirmation.map((day) => day.cash),
    );
    expect(
      afterConfirmation.map((day) => day.pendingSubscriptionValue.toString()),
      beforeConfirmation.map((day) => day.pendingSubscriptionValue.toString()),
    );
    expect(afterConfirmation.map((day) => day.accountNetValue), [5000, 5000]);
    expect(controller.investmentProjection(account.id)!.positions, isEmpty);
    final effective = fundSubscriptionEffectiveAt(
      current().fundSubscriptions.single,
    )!;
    expect(effective, hongKongFundDayStart(clock.date(2)));
    final before = valuationAt(
      effective.subtract(const Duration(microseconds: 1)),
    );
    final after = valuationAt(effective);
    expect(before.longValue, 0);
    expect(before.unrealized, 0);
    expect(before.pendingSubscriptionValue, 1401.31);
    expect(after.pendingSubscriptionValue, 0);
    expect(after.longValue, 1401.31);
    expect(after.unrealized, 0);
    expect(after.cash, before.cash);
    expect(after.cash, closeTo(3598.69, 0.000001));
    expect(after.amounts!.net, before.amounts!.net);
    final position = projectStocks(current(), at: effective).positions.single;
    expect(position.quantity.toString(), '12.75901629');
    expect(position.cost.toString(), '1401.31');
    final days = history({-7: '109.8290', -6: '110', 2: '109.8290'});
    expect(days.map((day) => day.quantity.toString()), [
      '0',
      '0',
      '12.75901629',
    ]);
    expect(days.map((day) => day.dailyProfit?.toString()), [null, '0', '0']);
    expect(days.map((day) => day.cumulativeProfit?.toString()), [
      '0',
      '0',
      '0',
    ]);
    expect(days.every((day) => day.accountNetValue == 5000), isTrue);
    expect(controller.entries, isEmpty);
  });

  test('现金锚点与扣款退款同刻时各计一次，锚点后补录的同刻事实仍正常生效', () async {
    final first = clock.order(id: 'known-payment', paidAt: clock.at(-8));
    expect(await save(first), isTrue);
    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: clock.at(-8),
        balance: 4000,
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4000);
    final second = clock.order(
      id: 'late-payment',
      cash: '500',
      paidAt: clock.at(-8),
    );
    expect(await save(second), isTrue);
    expect(controller.accountBalance(account), 3500);
    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: clock.at(-8),
        balance: 3500,
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 3500);
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: first.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-4),
        refundAmount: '900',
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4400);
    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: clock.at(-4),
        balance: 4400,
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4400);
    for (var retry = 0; retry < 2; retry++) {
      expect(
        await controller.cancelFundSubscription(
          accountId: account.id,
          subscriptionId: second.id,
          cancelledAt: clock.at(-6),
          refundedAt: clock.at(-4),
          refundAmount: '500',
        ),
        isTrue,
      );
      expect(controller.accountBalance(account), 4900);
    }
    final anchors = await repository.loadBalanceAnchors();
    expect(valuationAt(clock.at(-7), anchors: anchors).cash, 3500);
    expect(
      valuationAt(clock.at(-7), anchors: anchors).pendingSubscriptionValue,
      1500,
    );
    expect(valuationAt(clock.at(-3), anchors: anchors).cash, 4900);
    expect(
      valuationAt(clock.at(-3), anchors: anchors).pendingSubscriptionValue,
      0,
    );
    final days = history({
      -9: '100',
      -8: '100',
      -7: '101',
      -4: '102',
      -3: '103',
    }, anchors: anchors);
    expect(days.map((day) => day.accountNetValue), [
      5000,
      5000,
      5000,
      4900,
      4900,
    ]);
    expect(days.map((day) => day.dailyProfit?.toString()), [
      null,
      '0',
      '0',
      '-100',
      '0',
    ]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repository);
    expect(controller.accountBalance(account), 4900);
    expect(current().fundSubscriptions, hasLength(2));
    expect(controller.entries, isEmpty);
    expect(await repository.loadEntries(), isEmpty);
  });

  for (final sameDay in [true, false]) {
    test('重核成交净值规则不跨${sameDay ? '同日' : '后续'}持仓基准改变已包含份额', () async {
      final order = clock.order(paidAt: clock.at(-8));
      expect(await save(order), isTrue);
      expect(
        await controller.confirmFundSubscription(
          accountId: account.id,
          subscriptionId: order.id,
          confirmation: clock.confirmation(earningDay: sameDay ? -7 : -4),
        ),
        isTrue,
      );
      expect(
        await controller.saveFundHoldingBaseline(
          accountId: account.id,
          security: _fund,
          event: clock.baseline(day: sameDay ? -7 : -6),
          referencePrice: '100',
        ),
        isTrue,
      );
      final quantity = projectStocks(
        current(),
      ).positions.single.quantity.toString();
      await expectAtomicRejection(
        () => controller.confirmFundSubscription(
          accountId: account.id,
          subscriptionId: order.id,
          confirmation: clock.confirmation(
            earningDay: -7,
            accrualRule: FundAccrualRule.dealNavDate,
          ),
        ),
      );
      expect(
        projectStocks(current()).positions.single.quantity.toString(),
        quantity,
      );
      expect(controller.accountBalance(account), 4000);
    });
  }

  test('成交净值日内新增有歧义的持仓基准被原子拒绝，不重复增加申购份额', () async {
    final order = clock.order(paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        confirmation: clock.confirmation(
          earningDay: -7,
          accrualRule: FundAccrualRule.dealNavDate,
        ),
      ),
      isTrue,
    );
    await expectAtomicRejection(
      () => controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: clock.baseline(day: -7),
        referencePrice: '100',
      ),
    );
    expect(projectStocks(current()).positions.single.quantity.toString(), '10');
    expect(current().events, hasLength(1));
  });

  test('重复确认沿用一条事件，确认后的实际总扣款和现金始终不变', () async {
    final order = clock.order(cash: '1401.31', paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    final confirmation = clock.confirmation(nav: '100', quantity: '14.0131');
    for (var retry = 0; retry < 3; retry++) {
      expect(
        await controller.confirmFundSubscription(
          accountId: account.id,
          subscriptionId: order.id,
          confirmation: confirmation,
        ),
        isTrue,
      );
      expect(current().events, hasLength(1));
      expect(current().events.single.fundSubscriptionId, order.id);
      expect(current().events.single.kind, StockEventKind.fundAcquire);
      expect(
        projectStocks(current()).positions.single.quantity.toString(),
        '14.0131',
      );
      expect(controller.accountBalance(account), closeTo(3598.69, 0.000001));
    }
    expect(current().fundSubscriptions.single.cashAmount, '1401.31');
    expect(
      projectStocks(current()).cashMovements.values.single.toString(),
      '0',
    );
    expect(await repository.loadEntries(), isEmpty);
  });

  test('每笔申请独立起算，新的在途申购不会暂停已持有份额的净值收益', () async {
    final old = clock.order(
      id: 'old',
      cash: '1000',
      requestedAt: clock.at(-14),
      paidAt: clock.at(-13),
    );
    expect(await save(old), isTrue);
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: old.id,
        confirmation: clock.confirmation(
          confirmedDay: -11,
          navDay: -12,
          earningDay: -12,
        ),
      ),
      isTrue,
    );
    final next = clock.order(
      id: 'next',
      cash: '500',
      requestedAt: clock.at(-5),
      paidAt: clock.at(-4),
    );
    expect(await save(next), isTrue);
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: next.id,
        confirmation: clock.confirmation(
          confirmedDay: -3,
          navDay: -4,
          earningDay: 2,
          quantity: '5',
        ),
      ),
      isTrue,
    );
    expect(projectStocks(current()).positions.single.quantity.toString(), '10');
    final days = history({-5: '100', -4: '101', -3: '102'});
    expect(days.map((day) => day.quantity.toString()), ['10', '10', '10']);
    expect(days.map((day) => day.pendingSubscriptionValue.toString()), [
      '0',
      '500',
      '500',
    ]);
    expect(days.map((day) => day.dailyProfit?.toString()), [null, '10', '10']);
    expect(days.map((day) => day.cumulativeProfit?.toString()), [
      '0',
      '10',
      '20',
    ]);
    expect(days.map((day) => day.accountNetValue), [5000, 5010, 5020]);
    expect(
      projectStocks(
        current(),
        at: clock.at(3),
      ).positions.single.quantity.toString(),
      '15',
    );
    expect(controller.accountBalance(account), 3500);
    expect(controller.entries, isEmpty);
  });

  test('确认补正含费拆分时只调整净申购额，不改写总扣款或重复计算费用', () async {
    final order = clock.order(cash: '1401.31', paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        confirmation: clock.confirmation(quantity: '14', earningDay: 2),
        fee: '1.31',
      ),
      isTrue,
    );
    expect(current().fundSubscriptions.single.cashAmount, '1401.31');
    expect(current().fundSubscriptions.single.fee, '1.31');
    expect(controller.accountBalance(account), closeTo(3598.69, 0.000001));
    expect(valuationAt(clock.at(-1)).pendingSubscriptionValue, 1400);
    expect(valuationAt(clock.at(-1)).amounts!.net, closeTo(4998.69, 0.000001));
    final after = valuationAt(clock.at(3));
    expect(after.pendingSubscriptionValue, 0);
    expect(after.longValue, 1400);
    expect(after.unrealized, closeTo(-1.31, 0.000001));
    expect(after.amounts!.net, closeTo(4998.69, 0.000001));
    expect(
      projectStocks(
        current(),
        at: clock.at(3),
      ).positions.single.cost.toString(),
      '1401.31',
    );
    final days = history({-7: '100', 2: '100', 3: '100'});
    expect(days.map((day) => day.cumulativeProfit?.toString()), [
      '-1.31',
      '-1.31',
      '-1.31',
    ]);
    expect(days.map((day) => day.dailyProfit?.toString()), [null, '0', '0']);
    expect(controller.entries, isEmpty);
  });

  test('未付款申请取消和删除均不改变现金或产生资产', () async {
    final order = clock.order();
    expect(await save(order), isTrue);
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-7),
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 5000);
    expect(valuationAt(clock.at(-1)).amounts!.net, 5000);
    expect(projectStocks(current()).positions, isEmpty);
    expect(
      await controller.deleteFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
      ),
      isTrue,
    );
    expect(current().fundSubscriptions, isEmpty);
    expect(controller.entries, isEmpty);
  });

  test('已付款取消后保留待退款资产，实际部分退款只形成已确认差额', () async {
    final order = clock.order(paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-6),
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4000);
    expect(valuationAt(clock.at(-5)).pendingSubscriptionValue, 1000);
    expect(valuationAt(clock.at(-5)).amounts!.net, 5000);
    await expectAtomicRejection(
      () => controller.deleteFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
      ),
    );
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-4),
        refundAmount: '900',
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4900);
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-4),
        refundAmount: '900.00',
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4900);
    expect(current().fundSubscriptions.single.refundAmount, '900');
    expect(valuationAt(clock.at(-3)).pendingSubscriptionValue, 0);
    expect(valuationAt(clock.at(-3)).amounts!.net, 4900);
    final days = history({-7: '100', -5: '101', -4: '102', -3: '103'});
    expect(days.map((day) => day.dailyProfit?.toString()), [
      null,
      '0',
      '-100',
      '0',
    ]);
    expect(days.map((day) => day.cumulativeProfit?.toString()), [
      '0',
      '0',
      '-100',
      '-100',
    ]);
    expect(projectStocks(current()).income.toString(), '0');
    expect(controller.entries, isEmpty);
    expect(await repository.loadEntries(), isEmpty);
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-3),
        refundAmount: '1000',
      ),
    );
  });

  test('明确实际退款为零时结清在途资产，不虚构本金返还或收入', () async {
    final order = clock.order(paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-4),
        refundAmount: '0',
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 4000);
    expect(valuationAt(clock.at(-5)).amounts!.net, 5000);
    expect(valuationAt(clock.at(-3)).pendingSubscriptionValue, 0);
    expect(valuationAt(clock.at(-3)).amounts!.net, 4000);
    final days = history({-5: '100', -4: '100', -3: '100'});
    expect(days.map((day) => day.dailyProfit?.toString()), [
      null,
      '-1000',
      '0',
    ]);
    expect(days.last.cumulativeProfit?.toString(), '-1000');
    expect(current().events, isEmpty);
    expect(controller.entries, isEmpty);
  });

  test('已有持仓录入实际份额、成本和净值即可自动计算浮盈，更新净值不改变份额或成本', () async {
    // 12.77是用户从券商取得的实际份额夹具，不是用成本或当前净值反推的数量。
    final reference = calculateFundOpeningByQuantity(
      cost: '1401.31',
      quantity: '12.77',
      nav: '109.8290',
      currencyCode: 'USD',
    );
    final baseline = clock.baseline(
      day: -7,
      quantity: reference.quantity.toString(),
      nav: reference.navText,
      cost: reference.cost.toString(),
    );
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: baseline,
        referencePrice: reference.navText,
      ),
      isTrue,
    );
    final original = current().events.single.toJson();
    expect(current().events.single.quantityInferred, isFalse);
    expect(current().events.single.reportedUnrealized, isNull);
    expect(original.containsKey('reportedUnrealized'), isFalse);
    expect(original.containsKey('quantityInferred'), isFalse);
    expect(current().fundSubscriptions, isEmpty);
    expect(current().openingHoldings, isEmpty);
    expect(controller.accountBalance(account), 5000);
    final first = valueInvestmentAccount(
      current(),
      controller.accountBalance(account),
    );
    expect(first.longValue, 1402.52);
    expect(first.unrealized, closeTo(1.21, 0.000001));
    expect(first.amounts!.net, 6402.52);
    expect(
      await controller.setStockReferencePrice(account.id, _fund.id, '110'),
      isTrue,
    );
    final refreshed = valueInvestmentAccount(
      current(),
      controller.accountBalance(account),
    );
    expect(refreshed.longValue, 1404.7);
    expect(refreshed.unrealized, closeTo(3.39, 0.000001));
    expect(refreshed.amounts!.net, 6404.7);
    expect(current().events.single.toJson(), original);
    final position = projectStocks(current()).positions.single;
    expect(position.quantity.toString(), '12.77');
    expect(position.cost.toString(), '1401.31');
    expect(controller.accountBalance(account), 5000);
    final days = history({-8: '109', -7: '109.8290', -6: '110'});
    expect(days.map((day) => day.date), [clock.date(-7), clock.date(-6)]);
    expect(days.first.dailyProfit, isNull);
    expect(days.first.cumulativeProfit?.toString(), '1.21');
    expect(days.last.dailyProfit?.toString(), '2.18');
    expect(days.last.cumulativeProfit?.toString(), '3.39');
    expect(controller.entries, isEmpty);
    expect(current().valuationSnapshots, isEmpty);
    expect(await repository.loadEntries(), isEmpty);
    final restored =
        (await repository.loadInvestmentPortfolios()).single.events.single;
    expect(restored.reportedUnrealized, isNull);
    expect(restored.quantityInferred, isFalse);
    expect(restored.quantity, '12.77');
  });

  for (final fundInSource in [true, false]) {
    test('未来基金起算在${fundInSource ? '转出' : '转入'}账户时不阻止已有股票转移', () async {
      expect(
        await controller.saveStockEvent(
          accountId: account.id,
          security: avgoFixture,
          referencePrice: '50',
          event: StockEvent(
            id: 'stock-before-fund',
            securityId: avgoFixture.id,
            kind: StockEventKind.buy,
            occurredAt: clock.at(-12),
            sequence: 0,
            quantity: '10',
            price: '50',
          ),
        ),
        isTrue,
      );
      final target = investmentAccountFixture(id: 'fund-transfer-target');
      controller.addAccount(target);
      await controller.waitForPendingWrites();
      expect(
        await controller.enableInvestment(
          accountId: target.id,
          openingCash: '5000',
          openedAt: clock.at(-30),
        ),
        isTrue,
      );
      final fundOwner = fundInSource ? account : target;
      final order = clock.order(paidAt: clock.at(-8));
      expect(
        await controller.saveFundSubscription(
          accountId: fundOwner.id,
          security: _fund,
          subscription: order,
        ),
        isTrue,
      );
      expect(
        await controller.confirmFundSubscription(
          accountId: fundOwner.id,
          subscriptionId: order.id,
          confirmation: clock.confirmation(earningDay: 2),
        ),
        isTrue,
      );
      expect(
        await controller.transferStock(
          fromAccountId: account.id,
          toAccountId: target.id,
          securityId: avgoFixture.id,
          quantity: '1',
          short: false,
          occurredAt: clock.at(-1),
          batchId: 'stock-with-scheduled-fund',
        ),
        isTrue,
      );
      final fromHolding = controller
          .investmentProjection(account.id)!
          .positions
          .singleWhere((p) => p.securityId == avgoFixture.id);
      final toHolding = controller
          .investmentProjection(target.id)!
          .positions
          .singleWhere((p) => p.securityId == avgoFixture.id);
      expect(fromHolding.quantity.toString(), '9');
      expect(fromHolding.cost.toString(), '450');
      expect(toHolding.quantity.toString(), '1');
      expect(toHolding.cost.toString(), '50');
      expect(
        controller.accountBalance(account) + controller.accountBalance(target),
        8500,
      );
      expect(
        controller
            .investmentProjection(fundOwner.id)!
            .positions
            .where((p) => p.securityId == _fund.id),
        isEmpty,
        reason: '允许转移旧股票不能让未来基金份额提前成为可用持仓',
      );
      final before = jsonEncode([
        for (final id in [account.id, target.id])
          controller.investmentFor(id)!.toJson(),
      ]);
      expect(
        await controller.transferStock(
          fromAccountId: account.id,
          toAccountId: target.id,
          securityId: avgoFixture.id,
          quantity: '10',
          short: false,
          occurredAt: clock.at(-1),
          batchId: 'over-transfer',
        ),
        isFalse,
      );
      expect(
        jsonEncode([
          for (final id in [account.id, target.id])
            controller.investmentFor(id)!.toJson(),
        ]),
        before,
      );
    });
  }

  test('编辑或补录基金基准不会把当前参考价倒退成历史净值', () async {
    final baseline = clock.baseline(day: -7, quantity: '10', cost: '1000');
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: baseline,
        referencePrice: '100',
      ),
      isTrue,
    );
    expect(
      await controller.setStockReferencePrice(account.id, _fund.id, '120'),
      isTrue,
    );
    final edited = StockEvent.fromJson({
      ...baseline.toJson(),
      'note': '仅补充旧核对备注',
    });
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: edited,
        referencePrice: '100',
      ),
      isTrue,
    );
    expect(current().manualPrices[_fund.id], '120');
    expect(valueInvestmentAccount(current(), 5000).longValue, 1200);
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: clock.baseline(
          id: 'earlier',
          day: -8,
          quantity: '8',
          cost: '800',
          nav: '90',
        ),
        referencePrice: '90',
      ),
      isTrue,
    );
    expect(current().manualPrices[_fund.id], '120');
    expect(valueInvestmentAccount(current(), 5000).longValue, 1200);
    expect(controller.accountBalance(account), 5000);
  });

  test('旧版报告浮盈反推的基准仍可恢复，证据字段不被当作固定收益或收入', () async {
    final reference = calculateFundOpeningByUnrealized(
      cost: '1401.31',
      reportedUnrealized: '+1.20',
      nav: '109.8290',
      currencyCode: 'USD',
    );
    final baseline = clock.baseline(
      day: -7,
      quantity: reference.quantity.toString(),
      nav: reference.navText,
      cost: reference.cost.toString(),
      reportedUnrealized: reference.reportedUnrealized.toString(),
      inferred: true,
    );
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: baseline,
        referencePrice: reference.navText,
      ),
      isTrue,
    );
    expect(controller.accountBalance(account), 5000);
    expect(current().openingHoldings, isEmpty);
    expect(current().fundSubscriptions, isEmpty);
    expect(current().events.single.quantityInferred, isTrue);
    expect(current().events.single.reportedUnrealized, '1.2');
    expect(current().events.single.occurredAt, clock.at(-7));
    final valuation = valuationAt(clock.at(-1));
    expect(valuation.longValue, 1402.51);
    expect(valuation.unrealized, closeTo(1.2, 0.000001));
    expect(valuation.amounts!.net, 6402.51);
    final days = history({-8: '109', -7: '109.8290', -6: '110'});
    expect(days.map((day) => day.date), [clock.date(-7), clock.date(-6)]);
    expect(days.first.dailyProfit, isNull);
    expect(days.first.cumulativeProfit?.toString(), '1.2');
    expect(days.last.dailyProfit?.toString(), '2.18');
    expect(days.last.cumulativeProfit?.toString(), '3.38');
    expect(controller.entries, isEmpty);
    expect(current().valuationSnapshots, isEmpty);
    expect(await repository.loadEntries(), isEmpty);
    final legacyEvidence = current().events.single.toJson();
    final backup = controller.exportDataJson();
    controller.importDataJson(backup);
    await controller.waitForPendingWrites();
    expect(current().events.single.toJson(), legacyEvidence);
    expect(current().events.single.reportedUnrealized, '1.2');
    expect(current().events.single.quantityInferred, isTrue);
    expect(valuationAt(clock.at(-1)).unrealized, closeTo(1.2, 0.000001));
    expect(controller.entries, isEmpty);
  });

  test('后续基准替换持仓与成本，跨基准收益未知而后续区间恢复', () async {
    for (final baseline in [
      clock.baseline(id: 'first', day: -10),
      clock.baseline(
        id: 'later',
        day: -5,
        quantity: '8',
        nav: '110',
        cost: '800',
      ),
    ]) {
      expect(
        await controller.saveFundHoldingBaseline(
          accountId: account.id,
          security: _fund,
          event: baseline,
          referencePrice: baseline.price,
        ),
        isTrue,
      );
    }
    expect(projectStocks(current()).positions.single.quantity.toString(), '8');
    expect(projectStocks(current()).positions.single.cost.toString(), '800');
    expect(controller.accountBalance(account), 5000);
    expect(
      projectStocks(
        investmentAt(current(), clock.at(-9)),
        at: clock.at(-9),
      ).positions.single.quantity.toString(),
      '10',
    );
    final days = history({
      -11: '99',
      -10: '100',
      -9: '101',
      -5: '110',
      -4: '111',
    });
    expect(days.map((day) => day.quantity.toString()), ['10', '10', '8', '8']);
    expect(days.map((day) => day.dailyProfit?.toString()), [
      null,
      '10',
      null,
      '8',
    ]);
    expect(days.map((day) => day.cumulativeProfit?.toString()), [
      '0',
      '10',
      '80',
      '88',
    ]);
    final edited = clock.baseline(
      id: 'later',
      day: -5,
      quantity: '7',
      nav: '110',
      cost: '700',
    );
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: edited,
        referencePrice: edited.price,
      ),
      isTrue,
    );
    expect(current().events, hasLength(2));
    expect(
      current().events.map((event) => event.sequence).toSet(),
      hasLength(2),
    );
    expect(projectStocks(current()).positions.single.quantity.toString(), '7');
    expect(controller.accountBalance(account), 5000);
  });

  test('基准不能通过编辑或删除制造后续超量卖出，失败保留原持仓与现金', () async {
    final baseline = clock.baseline(day: -10);
    expect(
      await controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: baseline,
        referencePrice: baseline.price,
      ),
      isTrue,
    );
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: _fund,
        event: StockEvent(
          id: 'sell-after-baseline',
          securityId: _fund.id,
          kind: StockEventKind.sell,
          occurredAt: clock.at(-8),
          sequence: 2,
          quantity: '8',
          price: '101',
        ),
      ),
      isTrue,
    );
    await expectAtomicRejection(
      () => controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: clock.baseline(day: -10, quantity: '7', cost: '700'),
        referencePrice: '100',
      ),
    );
    await expectAtomicRejection(
      () => controller.deleteStockEvent(account.id, baseline.id),
    );
    expect(projectStocks(current()).positions.single.quantity.toString(), '2');
    expect(controller.accountBalance(account), 5808);
  });

  test('申购确认事件不能被普通股票保存或单独删除改写', () async {
    final order = clock.order(paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        confirmation: clock.confirmation(),
      ),
      isTrue,
    );
    final acquire = current().events.single;
    await expectAtomicRejection(
      () => controller.saveStockEvent(
        accountId: account.id,
        security: _fund,
        event: acquire,
      ),
    );
    await expectAtomicRejection(
      () => controller.saveStockEvent(
        accountId: account.id,
        security: _fund,
        event: StockEvent(
          id: acquire.id,
          securityId: _fund.id,
          kind: StockEventKind.buy,
          occurredAt: clock.at(-6),
          sequence: acquire.sequence,
          quantity: '1',
          price: '100',
        ),
      ),
    );
    await expectAtomicRejection(
      () => controller.deleteStockEvent(account.id, acquire.id),
    );
    await expectAtomicRejection(
      () => controller.deleteFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
      ),
    );
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-1),
      ),
    );
  });

  test('未来实际申请、扣款、确认或退款不能冒充已发生事实', () async {
    await expectAtomicRejection(
      () => save(clock.order(requestedAt: clock.at(2))),
    );
    await expectAtomicRejection(() => save(clock.order(paidAt: clock.at(2))));
    final order = clock.order(paidAt: clock.at(-8));
    expect(await save(order), isTrue);
    await expectAtomicRejection(
      () => controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        confirmation: clock.confirmation(confirmedDay: 2, earningDay: 2),
      ),
    );
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(2),
      ),
    );
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: order.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(2),
        refundAmount: '1000',
      ),
    );
    await expectAtomicRejection(
      () => controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: clock.baseline(day: 2),
        referencePrice: '100',
      ),
    );
  });

  test('币种、证券来源身份及日期顺序非法时整笔拒绝，不留下证券或资金残片', () async {
    const invalidSecurities = [
      StockSecurity(
        symbol: 'HK-WRONG-CURRENCY',
        name: '错误币种基金',
        market: StockMarket.hk,
        currencyCode: 'HKD',
        type: InvestmentSecurityType.fund,
      ),
      StockSecurity(
        symbol: 'US-NOT-HK-FUND',
        name: '非香港基金',
        market: StockMarket.us,
        currencyCode: 'USD',
        type: InvestmentSecurityType.fund,
      ),
      StockSecurity(
        symbol: 'HK-NOT-FUND',
        name: '股票身份',
        market: StockMarket.hk,
        currencyCode: 'USD',
      ),
    ];
    for (final security in invalidSecurities) {
      await expectAtomicRejection(
        () => save(clock.order(securityId: security.id), security: security),
      );
    }
    await expectAtomicRejection(
      () => save(clock.order(securityId: 'unknown-fund')),
    );
    final invalidOrders = [
      clock.order(cash: '1000.001'),
      clock.order(fee: '-1'),
      clock.order(fee: '1000'),
      clock.order(requestedAt: clock.at(-31)),
      clock.order(paidAt: clock.at(-11)),
      clock.order(expectedDate: clock.date(-11)),
    ];
    for (final order in invalidOrders) {
      await expectAtomicRejection(() => save(order));
    }
    final paid = clock.order(paidAt: clock.at(-8));
    expect(await save(paid), isTrue);
    for (final confirmation in [
      clock.confirmation(confirmedDay: -9),
      clock.confirmation(navDay: -11),
      clock.confirmation(navDay: -2),
      clock.confirmation(earningDay: -9),
      clock.confirmation(quantity: '0'),
    ]) {
      await expectAtomicRejection(
        () => controller.confirmFundSubscription(
          accountId: account.id,
          subscriptionId: paid.id,
          confirmation: confirmation,
        ),
      );
    }
    await expectAtomicRejection(() => save(paid.copyWith(cashAmount: '999')));
    await expectAtomicRejection(() => save(paid.copyWith(paidAt: null)));
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: paid.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-7),
        refundAmount: '1000',
      ),
    );
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: paid.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-5),
        refundAmount: '1000.01',
      ),
    );
    expect(current().securities, hasLength(1));
    expect(current().fundSubscriptions, hasLength(1));
    expect(current().events, isEmpty);
  });

  test('未付款的大额申请允许留存，实际扣款超过可用现金时保持原申请不变', () async {
    final order = clock.order(cash: '6000');
    expect(await save(order), isTrue);
    expect(controller.accountBalance(account), 5000);
    await expectAtomicRejection(
      () => save(order.copyWith(paidAt: clock.at(-8))),
    );
    expect(current().fundSubscriptions.single.paidAt, isNull);
    expect(valuationAt(clock.at(-1)).pendingSubscriptionValue, 0);
  });

  test('仓储写入失败时申请、确认、退款和基准均不发布虚假内存成功', () async {
    final paid = clock.order(paidAt: clock.at(-8));
    repository.failNextInvestmentSave = true;
    await expectAtomicRejection(() => save(paid));
    expect(await save(paid), isTrue);
    repository.failNextInvestmentSave = true;
    await expectAtomicRejection(
      () => controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: paid.id,
        confirmation: clock.confirmation(),
      ),
    );
    expect(current().fundSubscriptions.single.confirmation, isNull);
    repository.failNextInvestmentSave = true;
    await expectAtomicRejection(
      () => controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: paid.id,
        cancelledAt: clock.at(-6),
        refundedAt: clock.at(-5),
        refundAmount: '1000',
      ),
    );
    expect(current().fundSubscriptions.single.cancelledAt, isNull);
    repository.failNextInvestmentSave = true;
    await expectAtomicRejection(
      () => controller.saveFundHoldingBaseline(
        accountId: account.id,
        security: _fund,
        event: clock.baseline(day: -4),
        referencePrice: '100',
      ),
    );
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: paid.id,
        confirmation: clock.confirmation(),
      ),
      isTrue,
    );
    expect(current().events, hasLength(1));
    expect(projectStocks(current()).positions.single.quantity.toString(), '10');
    expect(controller.accountBalance(account), 4000);
    expect(await repository.loadEntries(), isEmpty);
  });
}

/// 固定单个用例开始时的香港日期；当前时刻只用于选相对日期，不依赖 CI 的固定年份。
class _FundClock {
  /// 将真实 [now] 转换为香港公历日期，所有交易夹具均在更早的明确日历日发生。
  _FundClock(DateTime now) : today = hongKongFundDate(now);

  final DateTime today;

  /// 返回相对 [today] 的 [offset] 日 UTC 纯日期；显式保留日历字段，避免本机时区干扰。
  DateTime date(int offset) {
    final value = addCalendarDays(today, offset);
    return DateTime.utc(value.year, value.month, value.day);
  }

  /// 返回相对日期香港 [hour] 时的真实 UTC 时刻；小时表示日内真实时间，不作日历日加减。
  DateTime at(int offset, {int hour = 12}) =>
      hongKongFundDayStart(date(offset)).add(Duration(hours: hour));

  /// 构造未确认申请；[cash] 是含 [fee] 的总扣款，只有显式 [paidAt] 才表达实际付款。
  /// [requestedAt]、[expectedDate]、[securityId] 可用于验证时间与证券身份的拒绝边界。
  FundSubscription order({
    String id = 'order',
    String cash = '1000',
    String fee = '0',
    String? securityId,
    DateTime? requestedAt,
    DateTime? paidAt,
    DateTime? expectedDate,
  }) {
    final requested = requestedAt ?? at(-10);
    final expected = addCalendarDays(hongKongFundDate(requested), 4);
    return FundSubscription(
      id: id,
      securityId: securityId ?? _fund.id,
      requestedAt: requested,
      cashAmount: cash,
      fee: fee,
      paidAt: paidAt,
      expectedConfirmationDate:
          expectedDate ??
          DateTime.utc(expected.year, expected.month, expected.day),
      note: '离线基金申请夹具',
    );
  }

  /// 构造券商确认事实；[confirmedDay] 是回执时刻，[navDay] 与 [earningDay] 为独立纯日期。
  /// [nav]、[quantity] 故意允许独立指定，测试不借量价乘积覆盖券商实际扣款。
  /// [accrualRule] 缺省保持既有夹具口径，新成交净值规则由相应用例明确指定。
  FundSubscriptionConfirmation confirmation({
    int confirmedDay = -5,
    int navDay = -7,
    int earningDay = -6,
    String nav = '100',
    String quantity = '10',
    FundAccrualRule accrualRule = FundAccrualRule.explicitStartDate,
  }) => FundSubscriptionConfirmation(
    confirmedAt: at(confirmedDay),
    navDate: date(navDay),
    earningStartDate: date(earningDay),
    nav: nav,
    quantity: quantity,
    accrualRule: accrualRule,
  );

  /// 构造当前持仓基准；[day] 控制生效日，[quantity] 是用户提供的实际份额，[cost] 是实际成本。
  /// [reportedUnrealized]/[inferred] 只供旧备份兼容用例显式填写，当前录入无需报告浮盈或反推份额。
  /// sequence交由生产命令分配，不能由测试伪造重放顺序。
  StockEvent baseline({
    String id = 'baseline',
    required int day,
    String quantity = '10',
    String nav = '100',
    String cost = '1000',
    String? reportedUnrealized,
    bool inferred = false,
  }) => StockEvent(
    id: id,
    securityId: _fund.id,
    kind: StockEventKind.fundHoldingBaseline,
    occurredAt: at(day),
    sequence: 0,
    quantity: quantity,
    price: nav,
    carriedCost: cost,
    reportedUnrealized: reportedUnrealized,
    fundNavDate: date(day),
    quantityInferred: inferred,
    note: '离线已有基金持仓夹具',
  );
}

/// 保留内存仓储的生产契约，只在下一次聚合保存前抛错，模拟原子落库失败。
class _FailingFundRepository extends InMemoryLedgerRepository {
  bool failNextInvestmentSave = false;

  /// [portfolios] 是候选全量聚合；失败发生在父类更新前，确保磁盘替身保持原状态。
  @override
  Future<void> saveInvestmentPortfolios(
    List<InvestmentPortfolio> portfolios,
  ) async {
    if (failNextInvestmentSave) {
      failNextInvestmentSave = false;
      throw StateError('模拟基金聚合保存失败');
    }
    await super.saveInvestmentPortfolios(portfolios);
  }
}
