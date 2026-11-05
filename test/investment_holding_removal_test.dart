import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/investments/fund_workflow_math.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';

const _other = StockSecurity(
  symbol: 'TEST-OTHER',
  name: '其他验收证券',
  market: StockMarket.us,
  currencyCode: 'USD',
);
const _fund = StockSecurity(
  symbol: 'TEST-FUND',
  name: '待删除验收基金',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);
const _otherFund = StockSecurity(
  symbol: 'TEST-OTHER-FUND',
  name: '其他验收基金',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 用真实 SQLite 验证删除范围、现金重放、并发确认及失败回滚，不触及设备账目。
void main() {
  setUpAll(sqfliteFfiInit);
  late AppDatabase db;
  late SqliteLedgerRepository repo;
  late VeriFinController controller;
  late LocalKeyValueStore store;
  final account = investmentAccountFixture();

  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = SqliteLedgerRepository(db);
    store = LocalKeyValueStore();
    controller = await VeriFinController.create(store, repository: repo);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  /// 建立已落库期初；[opening] 可覆盖多空方向，[cash] 控制历史资金边界。
  Future<void> enable({
    List<StockHolding>? opening,
    String cash = '5000',
  }) async {
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: cash,
        openedAt: DateTime(2026, 10, 1),
        securities: [avgoFixture, _other],
        openingHoldings:
            opening ??
            [
              StockHolding(
                securityId: avgoFixture.id,
                short: false,
                quantity: '3',
                cost: '1023',
              ),
            ],
        manualPrices: {avgoFixture.id: '325.48', _other.id: '50'},
      ),
      isTrue,
    );
  }

  /// 保存 [event] 对应证券的真实投资事实，不用普通收支模拟投资现金腿。
  Future<void> save(
    StockEvent event, {
    StockSecurity security = avgoFixture,
  }) async {
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: security,
        event: event,
      ),
      isTrue,
    );
  }

  /// 创建当前目标的只读预览；[openingOnly] 和 [short] 选择期初删除范围。
  InvestmentHoldingRemovalPreview preview({
    String? securityId,
    bool openingOnly = false,
    bool short = false,
  }) => controller.previewInvestmentHoldingRemoval(
    accountId: account.id,
    securityId: securityId ?? avgoFixture.id,
    openingOnly: openingOnly,
    short: short,
  )!;

  /// 在 [at] 记录独立收入，验证证券删除不会删掉普通流水及其现金贡献。
  Future<void> income(DateTime at) async {
    controller.addEntry(
      LedgerEntry(
        id: 'ordinary-income',
        bookId: account.bookId,
        type: EntryType.income,
        amount: 25,
        currencyCode: 'USD',
        categoryId: controller.categories
            .firstWhere((c) => c.type == EntryType.income)
            .id,
        accountId: account.id,
        note: '独立现金验收',
        occurredAt: at,
      ),
    );
    await controller.waitForPendingWrites();
  }

  test('期初持仓预览无副作用，删除现金不变且 SQLite 与完整备份可重读', () async {
    await enable();
    expect(await controller.captureInvestmentValuation(account.id), isTrue);
    final original = controller.investmentFor(account.id)!;
    final draft = preview();
    expect(draft.canRemove, isTrue);
    expect(draft.openingCount, 1);
    expect(draft.eventCount, 0);
    expect(draft.subscriptionCount, 0);
    expect(draft.cashBefore, 5000);
    expect(draft.cashAfter, 5000);
    expect(identical(controller.investmentFor(account.id), original), isTrue);
    expect(
      (await repo.loadInvestmentPortfolios()).single.toJson(),
      original.toJson(),
    );
    expect(await controller.removeInvestmentHolding(draft), isTrue);
    final removed = controller.investmentFor(account.id)!;
    expect(removed.openingHoldings, isEmpty);
    expect(projectStocks(removed).positions, isEmpty);
    expect(removed.securities, original.securities);
    expect(removed.manualPrices, original.manualPrices);
    expect(removed.valuationSnapshots, original.valuationSnapshots);
    expect(
      controller.investmentSnapshotValuation(
        account.id,
        removed.valuationSnapshots.single,
      ),
      isNull,
    );
    expect(controller.entries, isEmpty);
    expect(controller.accountBalance(account), 5000);
    expect(await controller.removeInvestmentHolding(draft), isFalse);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    expect(controller.investmentFor(account.id)!.toJson(), removed.toJson());
    final backup = controller.exportDataJson();
    controller.importDataJson(backup);
    await controller.waitForPendingWrites();
    expect(
      (await repo.loadInvestmentPortfolios()).single.toJson(),
      removed.toJson(),
    );
  });

  test('完整清除同证券多空及买卖，其他证券和普通现金流水保留', () async {
    await enable(
      opening: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '3',
          cost: '900',
        ),
        StockHolding(
          securityId: avgoFixture.id,
          short: true,
          quantity: '2',
          cost: '600',
        ),
      ],
    );
    await save(stockEventFixture('buy', StockEventKind.buy, '2', '100'));
    await save(
      stockEventFixture('sell', StockEventKind.sell, '1', '120', sequence: 2),
    );
    final otherBuy = StockEvent(
      id: 'other-buy',
      securityId: _other.id,
      kind: StockEventKind.buy,
      occurredAt: DateTime(2026, 10, 2, 10),
      sequence: 3,
      quantity: '1',
      price: '50',
    );
    await save(otherBuy, security: _other);
    await income(DateTime(2026, 10, 3));
    final draft = preview();
    expect(draft.openingCount, 2);
    expect(draft.eventCount, 2);
    expect(draft.cashBefore, 4895);
    expect(draft.cashAfter, 4975);
    expect(await controller.removeInvestmentHolding(draft), isTrue);
    final p = controller.investmentFor(account.id)!;
    expect(p.events, [otherBuy]);
    expect(projectStocks(p).positions.single.securityId, _other.id);
    expect(controller.entries.single.id, 'ordinary-income');
    expect(controller.accountBalance(account), 4975);
  });

  test('仅删除指定方向期初，保留后续买入及另一方向期初', () async {
    await enable(
      opening: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '3',
          cost: '900',
        ),
        StockHolding(
          securityId: avgoFixture.id,
          short: true,
          quantity: '1',
          cost: '300',
        ),
      ],
    );
    await save(stockEventFixture('buy', StockEventKind.buy, '2', '100'));
    final draft = preview(openingOnly: true);
    expect(draft.eventCount, 0);
    expect(draft.cashAfter, 4800);
    expect(await controller.removeInvestmentHolding(draft), isTrue);
    final p = controller.investmentFor(account.id)!;
    expect(p.openingHoldings.single.short, isTrue);
    expect(p.events.single.id, 'buy');
    expect(
      projectStocks(
        p,
      ).positions.firstWhere((p) => !p.short).quantity.toString(),
      '2',
    );
  });

  test('仅删期初会导致后续卖出数量不足时拒绝，完整清除仍可用', () async {
    await enable();
    await save(stockEventFixture('sell', StockEventKind.sell, '2', '350'));
    final original = controller.investmentFor(account.id)!;
    final draft = preview(openingOnly: true);
    expect(draft.issue, InvestmentHoldingRemovalIssue.invalidHistory);
    expect(draft.cashAfter, isNull);
    expect(await controller.removeInvestmentHolding(draft), isFalse);
    expect(identical(controller.investmentFor(account.id), original), isTrue);
    expect(preview().cashAfter, 5000);
  });

  test('清除资金来源会使剩余买入历史现金不足时拒绝', () async {
    await enable(cash: '0');
    await save(stockEventFixture('sell', StockEventKind.sell, '1', '350'));
    await save(
      StockEvent(
        id: 'other-buy',
        securityId: _other.id,
        kind: StockEventKind.buy,
        occurredAt: DateTime(2026, 10, 3),
        sequence: 2,
        quantity: '1',
        price: '100',
      ),
      security: _other,
    );
    final draft = preview();
    expect(draft.issue, InvestmentHoldingRemovalIssue.invalidHistory);
    expect(await controller.removeInvestmentHolding(draft), isFalse);
    expect(controller.accountBalance(account), 250);
  });

  test('确认期间普通资金流水变化，即使聚合未变也拒绝过期预览', () async {
    await enable();
    final draft = preview();
    await income(DateTime(2026, 10, 3));
    expect(
      identical(controller.investmentFor(account.id), draft.original),
      isTrue,
    );
    expect(await controller.removeInvestmentHolding(draft), isFalse);
    expect(preview().cashAfter, 5025);
  });

  test('确认期间新增现金核对锚点，拒绝过期预览并保留核对现金', () async {
    await enable();
    final draft = preview();
    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: DateTime(2026, 10, 3),
        balance: 4500,
      ),
      isTrue,
    );
    expect(await controller.removeInvestmentHolding(draft), isFalse);
    final refreshed = preview();
    expect(refreshed.cashBefore, 4500);
    expect(refreshed.cashAfter, 4500);
    expect(await controller.removeInvestmentHolding(refreshed), isTrue);
    expect(controller.latestBalanceAnchor(account.id)!.balance, 4500);
  });

  test('SQLite 原子保存失败保持内存磁盘，原预览可重试', () async {
    await enable();
    final draft = preview();
    await db.db.execute(
      "CREATE TRIGGER reject_removal BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT, '模拟清除保存失败'); END",
    );
    expect(await controller.removeInvestmentHolding(draft), isFalse);
    expect(
      identical(controller.investmentFor(account.id), draft.original),
      isTrue,
    );
    expect(
      (await repo.loadInvestmentPortfolios()).single.toJson(),
      draft.original.toJson(),
    );
    await db.db.execute('DROP TRIGGER reject_removal');
    expect(await controller.removeInvestmentHolding(draft), isTrue);
    expect(
      (await repo.loadInvestmentPortfolios()).single.openingHoldings,
      isEmpty,
    );
  });

  test('股票清除精确移除锚点内目标事件，保留同刻其他证券和普通流水', () async {
    await enable();
    final at = DateTime(2026, 10, 2, 10);
    await save(stockEventFixture('same', StockEventKind.buy, '1', '100'));
    await save(
      StockEvent(
        id: 'same-extra',
        securityId: _other.id,
        kind: StockEventKind.buy,
        occurredAt: at,
        sequence: 2,
        quantity: '1',
        price: '50',
      ),
      security: _other,
    );
    await income(at);
    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: at,
        balance: 4600,
      ),
      isTrue,
    );
    final anchor = controller.latestBalanceAnchor(account.id)!;
    expect(await controller.removeInvestmentHolding(preview()), isTrue);
    final p = controller.investmentFor(account.id)!;
    expect(
      p.anchorIncludedIds[anchor.id],
      unorderedEquals(['stock:same-extra', 'entry:ordinary-income']),
    );
    expect(controller.accountBalance(account), 4600);
    expect(
      (await repo.loadInvestmentPortfolios()).single.anchorIncludedIds,
      p.anchorIncludedIds,
    );
  });

  test('跨账户转移阻止单边完整清除及期初删除，两端保持不变', () async {
    await enable();
    final target = investmentAccountFixture(id: 'target');
    controller.addAccount(target);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: target.id,
        openingCash: '0',
        openedAt: DateTime(2026, 10, 1),
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
        occurredAt: DateTime(2026, 10, 2),
        batchId: 'transfer',
      ),
      isTrue,
    );
    final sourceBefore = controller.investmentFor(account.id)!;
    final targetBefore = controller.investmentFor(target.id)!;
    for (final openingOnly in [false, true]) {
      final draft = preview(openingOnly: openingOnly);
      expect(draft.issue, InvestmentHoldingRemovalIssue.transfer);
      expect(await controller.removeInvestmentHolding(draft), isFalse);
    }
    final incoming = controller.previewInvestmentHoldingRemoval(
      accountId: target.id,
      securityId: avgoFixture.id,
    )!;
    expect(incoming.issue, InvestmentHoldingRemovalIssue.transfer);
    expect(
      identical(controller.investmentFor(account.id), sourceBefore),
      isTrue,
    );
    expect(
      identical(controller.investmentFor(target.id), targetBefore),
      isTrue,
    );
  });

  test('未交割期权完整清除期初开仓及保证金，现金重算且标的股票保留', () async {
    final option = optionFixture(right: OptionRight.put);
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '5000',
        openedAt: DateTime(2026, 10, 1),
        securities: [avgoFixture, option],
        openingHoldings: [
          StockHolding(
            securityId: avgoFixture.id,
            short: false,
            quantity: '3',
            cost: '1023',
          ),
          StockHolding(
            securityId: option.id,
            short: true,
            quantity: '1',
            cost: '100',
          ),
        ],
        manualPrices: {avgoFixture.id: '325.48', option.id: '1'},
      ),
      isTrue,
    );
    for (final event in [
      optionEventFixture(
        option,
        StockEventKind.optionSellOpen,
        id: 'open',
        fee: '1',
      ),
      optionEventFixture(
        option,
        StockEventKind.optionMargin,
        id: 'margin',
        sequence: 2,
        quantity: '0',
        price: '0',
        margin: '1000',
      ),
    ]) {
      expect(
        await controller.saveOptionEvent(
          accountId: account.id,
          security: option,
          underlying: avgoFixture,
          event: event,
          referencePrice: '1',
          underlyingReferencePrice: '325.48',
        ),
        isTrue,
      );
    }
    final original = controller.investmentFor(account.id)!;
    expect(projectStocks(original).frozenMargin.toString(), '1000');
    final draft = preview(securityId: option.id);
    expect(draft.canRemove, isTrue);
    expect(draft.openingCount, 1);
    expect(draft.eventCount, 2);
    expect(draft.cashBefore, 5199);
    expect(draft.cashAfter, 5000);
    expect(await controller.removeInvestmentHolding(draft), isTrue);
    final removed = controller.investmentFor(account.id)!;
    final projection = projectStocks(removed);
    expect(removed.events, isEmpty);
    expect(removed.openingHoldings.single.securityId, avgoFixture.id);
    expect(projection.positions.single.securityId, avgoFixture.id);
    expect(projection.positions.single.quantity.toString(), '3');
    expect(projection.frozenMargin.toString(), '0');
    expect(controller.accountBalance(account), 5000);
    expect(removed.securities, original.securities);
    expect(
      (await repo.loadInvestmentPortfolios()).single.toJson(),
      removed.toJson(),
    );
  });

  test('仅删期初后没有剩余持仓时撤销该证券行情选择，保留其他证券选择', () async {
    await enable();
    // 模拟冷启动读取已经保存的逐证券选择；来源开关仍关闭，不产生行情网络请求。
    await repo.saveInvestmentPortfolios([
      controller
          .investmentFor(account.id)!
          .copyWith(marketPriceIds: {avgoFixture.id, _other.id}),
    ]);
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    expect(
      controller.investmentFor(account.id)!.marketPriceIds,
      contains(avgoFixture.id),
    );
    expect(
      await controller.removeInvestmentHolding(preview(openingOnly: true)),
      isTrue,
    );
    final removed = controller.investmentFor(account.id)!;
    expect(projectStocks(removed).positions, isEmpty);
    expect(removed.marketPriceIds, {_other.id});
    expect(removed.manualPrices[avgoFixture.id], '325.48');
    expect((await repo.loadInvestmentPortfolios()).single.marketPriceIds, {
      _other.id,
    });
  });

  test('已实物交割期权和对应标的均阻止单证券清除', () async {
    await enable();
    final option = optionFixture(multiplier: '1', shares: '1', exercise: '50');
    for (final event in [
      optionEventFixture(option, StockEventKind.optionBuyOpen, id: 'open'),
      optionEventFixture(
        option,
        StockEventKind.optionPhysicalSettle,
        id: 'settle',
        sequence: 2,
        price: '0',
        settled: true,
      ),
    ]) {
      expect(
        await controller.saveOptionEvent(
          accountId: account.id,
          security: option,
          underlying: avgoFixture,
          event: event,
          referencePrice: '2',
          underlyingReferencePrice: '325.48',
        ),
        isTrue,
      );
    }
    for (final securityId in [avgoFixture.id, option.id]) {
      final draft = preview(securityId: securityId);
      expect(draft.issue, InvestmentHoldingRemovalIssue.physicalSettlement);
      expect(await controller.removeInvestmentHolding(draft), isFalse);
    }
    expect(
      preview(openingOnly: true).issue,
      InvestmentHoldingRemovalIssue.physicalSettlement,
    );
  });

  test('基金清除付款退款和未来确认份额，锚点仅清理被删除事实的稳定 ID', () async {
    await enable();
    final at = DateTime(2026, 10, 2, 10);
    await save(stockEventFixture('buy', StockEventKind.buy, '1', '100'));
    await income(at);
    for (final item in [
      (id: 'target', security: _fund, amount: '100'),
      (id: 'refund', security: _fund, amount: '50'),
      (id: 'target-extra', security: _otherFund, amount: '40'),
    ]) {
      expect(
        await controller.saveFundSubscription(
          accountId: account.id,
          security: item.security,
          subscription: FundSubscription(
            id: item.id,
            securityId: item.security.id,
            requestedAt: at,
            paidAt: at,
            cashAmount: item.amount,
          ),
        ),
        isTrue,
      );
    }
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: 'target',
        confirmation: FundSubscriptionConfirmation(
          confirmedAt: DateTime(2026, 10, 3),
          navDate: DateTime.utc(2026, 10, 2),
          earningStartDate: DateTime.utc(2027, 1, 1),
          nav: '10',
          quantity: '10',
        ),
      ),
      isTrue,
    );
    expect(
      await controller.cancelFundSubscription(
        accountId: account.id,
        subscriptionId: 'refund',
        cancelledAt: at,
        refundedAt: at,
        refundAmount: '45',
      ),
      isTrue,
    );
    final beforeAnchor = preview(securityId: _fund.id);
    expect(beforeAnchor.cashBefore, 4780);
    expect(beforeAnchor.cashAfter, 4885);
    expect(beforeAnchor.subscriptionCount, 2);
    expect(beforeAnchor.eventCount, 1);
    expect(
      await controller.saveBalanceAnchor(
        account: account,
        effectiveAt: at,
        balance: 4800,
      ),
      isTrue,
    );
    final anchor = controller.latestBalanceAnchor(account.id)!;
    final draft = preview(securityId: _fund.id);
    expect(draft.cashAfter, 4800);
    expect(await controller.removeInvestmentHolding(draft), isTrue);
    final p = controller.investmentFor(account.id)!;
    expect(p.fundSubscriptions.single.id, 'target-extra');
    expect(p.events.single.id, 'buy');
    expect(
      p.anchorIncludedIds[anchor.id],
      unorderedEquals([
        'stock:buy',
        'entry:ordinary-income',
        'fund:target-extra:payment',
      ]),
    );
    expect(
      fundSubscriptionPendingValue(p, at: DateTime.now()).toString(),
      '40',
    );
    expect(
      fundSubscriptionCashLegs(p, at: DateTime.utc(9999, 12, 31)).single.id,
      'fund:target-extra:payment',
    );
    expect(
      projectStocks(
        p,
        at: DateTime.utc(9999, 12, 31),
      ).positions.any((h) => h.securityId == _fund.id),
      isFalse,
    );
    expect(controller.entries.single.id, 'ordinary-income');
    expect(controller.latestBalanceAnchor(account.id)!.balance, 4800);
  });

  test('不存在账户、证券或剩余事实时没有可删除预览', () async {
    await enable();
    expect(
      controller.previewInvestmentHoldingRemoval(
        accountId: 'missing',
        securityId: avgoFixture.id,
      ),
      isNull,
    );
    expect(
      controller.previewInvestmentHoldingRemoval(
        accountId: account.id,
        securityId: 'missing',
      ),
      isNull,
    );
    expect(
      controller.previewInvestmentHoldingRemoval(
        accountId: account.id,
        securityId: _other.id,
      ),
      isNull,
    );
    expect(await controller.removeInvestmentHolding(preview()), isTrue);
    expect(
      controller.previewInvestmentHoldingRemoval(
        accountId: account.id,
        securityId: avgoFixture.id,
      ),
      isNull,
    );
  });
}
