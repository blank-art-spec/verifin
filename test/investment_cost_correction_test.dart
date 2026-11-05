import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';

/// 使用真实 SQLite 保存与重读验证期初成本更正，固定报价仅用于验算，不请求行情。
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

  /// 建立已经保存的期初持仓；[cost] 为旧格式总成本，null 表示未知。
  /// [quantity] 为原始期初数量；[short] 选择方向，[security] 用于确认基金/期权边界。
  Future<void> enable({
    String quantity = '3',
    String? cost = '341',
    bool short = false,
    StockSecurity security = avgoFixture,
  }) async {
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '5000',
        openedAt: DateTime(2026, 10, 1),
        securities: [if (security.option != null) avgoFixture, security],
        openingHoldings: [
          StockHolding(
            securityId: security.id,
            short: short,
            quantity: quantity,
            cost: cost,
          ),
        ],
        manualPrices: {
          if (security.option != null) avgoFixture.id: '325.48',
          security.id: '325.48',
        },
      ),
      isTrue,
    );
  }

  /// 保存原有股票事实；[event] 的数量/单价独立于待更正的期初成本。
  Future<void> save(StockEvent event) async {
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: avgoFixture,
        event: event,
      ),
      isTrue,
    );
  }

  test('旧总成本不会自动乘数量，确认每股 341 后持仓亏损 46.56 并可冷读', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    expect(before.openingHoldings.single.cost, '341');
    expect(
      valueStocks(before, projectStocks(before)).unrealized.toString(),
      '635.44',
    );
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isTrue,
    );
    final corrected = controller.investmentFor(account.id)!;
    expect(corrected.openingHoldings.single.cost, '1023');
    expect(corrected.openingHoldings.single.quantity, '3');
    expect(corrected.events, isEmpty);
    expect(controller.entries, isEmpty);
    expect(controller.accountBalance(account), 5000);
    expect(
      valueStocks(corrected, projectStocks(corrected)).unrealized.toString(),
      '-46.56',
    );
    expect(
      InvestmentPortfolio.fromJson(
        corrected.toJson(),
      ).openingHoldings.single.cost,
      '1023',
    );
    controller.dispose();
    controller = await VeriFinController.create(store, repository: repo);
    final reloaded = controller.investmentFor(account.id)!;
    expect(reloaded.openingHoldings.single.cost, '1023');
    expect(controller.accountBalance(account), 5000);
    expect(
      valueStocks(reloaded, projectStocks(reloaded)).unrealized.toString(),
      '-46.56',
    );
  });

  test('卖出部分后按期初三股更正，重算已实现盈亏及剩余两股成本', () async {
    await enable();
    await save(stockEventFixture('sell', StockEventKind.sell, '1', '350'));
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
      ),
      isTrue,
    );
    final p = controller.investmentFor(account.id)!;
    final projection = projectStocks(p);
    expect(p.openingHoldings.single.cost, '1023');
    expect(projection.positions.single.quantity.toString(), '2');
    expect(projection.positions.single.cost.toString(), '682');
    expect(projection.realized.toString(), '9');
    expect(valueStocks(p, projection).unrealized.toString(), '-31.04');
    expect(controller.accountBalance(account), 5350);
    expect(p.events.single.price, '350');
  });

  test('拆股后的六股不作为期初单位成本的乘数', () async {
    await enable();
    await save(stockEventFixture('split', StockEventKind.split, '2', '1'));
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
      ),
      isTrue,
    );
    final projection = controller.investmentProjection(account.id)!;
    expect(projection.positions.single.quantity.toString(), '6');
    expect(projection.positions.single.cost.toString(), '1023');
    expect(controller.accountBalance(account), 5000);
  });

  test('后续加仓仍沿用原成交成本，不被期初更正覆盖', () async {
    await enable();
    await save(stockEventFixture('buy', StockEventKind.buy, '2', '300'));
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
      ),
      isTrue,
    );
    final projection = controller.investmentProjection(account.id)!;
    expect(projection.positions.single.quantity.toString(), '5');
    expect(projection.positions.single.cost.toString(), '1623');
    expect(controller.accountBalance(account), 4400);
  });

  test('碎股与八位单位成本先相乘，再按美元分精度舍入', () async {
    await enable(quantity: '2.5');
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '12.34567891',
        perUnit: true,
      ),
      isTrue,
    );
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '30.86',
    );
    expect(controller.accountBalance(account), 5000);
  });

  test('负微值及非法单位成本不因舍入而成为可保存的零', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    for (final input in ['-0.00000001', '-1', '1e2', 'NaN', '']) {
      expect(
        await controller.setStockOpeningCost(
          account.id,
          avgoFixture.id,
          false,
          input,
          perUnit: true,
        ),
        isFalse,
      );
      expect(identical(controller.investmentFor(account.id), before), isTrue);
    }
    expect(
      (await repo.loadInvestmentPortfolios())
          .single
          .openingHoldings
          .single
          .cost,
      '341',
    );
  });

  test('未知成本可以明确补为零，空头更正不增加现金', () async {
    await enable(cost: null, short: true);
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        true,
        '0',
        perUnit: true,
      ),
      isTrue,
    );
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '0',
    );
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        true,
        '341',
        perUnit: true,
      ),
      isTrue,
    );
    final p = controller.investmentFor(account.id)!;
    expect(p.openingHoldings.single.cost, '1023');
    expect(valueStocks(p, projectStocks(p)).unrealized.toString(), '46.56');
    expect(controller.accountBalance(account), 5000);
  });

  test('原有总成本调用不再次乘数量', () async {
    await enable(cost: null);
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
      ),
      isTrue,
    );
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '341',
    );
  });

  test('编辑期间组合已变更时拒绝过期草稿，重新读取后允许更正', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    expect(
      await controller.setStockReferencePrice(
        account.id,
        avgoFixture.id,
        '400',
      ),
      isTrue,
    );
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isFalse,
    );
    final latest = controller.investmentFor(account.id)!;
    expect(latest.openingHoldings.single.cost, '341');
    expect(latest.manualPrices[avgoFixture.id], '400');
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
        expectedPortfolio: latest,
      ),
      isTrue,
    );
  });

  test('SQLite 保存失败保留内存和磁盘成本，同一草稿可以重试', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    await db.db.execute(
      "CREATE TRIGGER reject_cost BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT, '模拟成本保存失败'); END",
    );
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isFalse,
    );
    expect(identical(controller.investmentFor(account.id), before), isTrue);
    expect(
      (await repo.loadInvestmentPortfolios())
          .single
          .openingHoldings
          .single
          .cost,
      '341',
    );
    expect(controller.accountBalance(account), 5000);
    await db.db.execute('DROP TRIGGER reject_cost');
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isTrue,
    );
    expect(
      (await repo.loadInvestmentPortfolios())
          .single
          .openingHoldings
          .single
          .cost,
      '1023',
    );
  });

  test('期初成本更正若破坏已转移成本则拒绝，两端持仓保持不变', () async {
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
        batchId: 'cost-transfer',
      ),
      isTrue,
    );
    final sourceBefore = controller.investmentFor(account.id)!;
    final targetBefore = controller.investmentFor(target.id)!;
    expect(
      await controller.setStockOpeningCost(
        account.id,
        avgoFixture.id,
        false,
        '341',
        perUnit: true,
      ),
      isFalse,
    );
    expect(
      identical(controller.investmentFor(account.id), sourceBefore),
      isTrue,
    );
    expect(
      identical(controller.investmentFor(target.id), targetBefore),
      isTrue,
    );
    expect(
      controller
          .investmentProjection(account.id)!
          .positions
          .single
          .cost
          .toString(),
      '227.33',
    );
    expect(
      controller
          .investmentProjection(target.id)!
          .positions
          .single
          .cost
          .toString(),
      '113.67',
    );
  });

  for (final security in [
    const StockSecurity(
      symbol: 'TEST-FUND',
      name: '验收基金',
      market: StockMarket.us,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    ),
    optionFixture(),
  ]) {
    test('${security.isFund ? '基金' : '期权'}不能走股票每股成本更正入口', () async {
      await enable(security: security);
      final before = controller.investmentFor(account.id)!;
      expect(
        await controller.setStockOpeningCost(
          account.id,
          security.id,
          false,
          '341',
          perUnit: true,
        ),
        isFalse,
      );
      expect(identical(controller.investmentFor(account.id), before), isTrue);
    });
  }
}
