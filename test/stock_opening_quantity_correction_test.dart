import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';

const _goog = StockSecurity(
  symbol: 'GOOG',
  name: '谷歌期初更正验收',
  market: StockMarket.us,
  currencyCode: 'USD',
);

/// 用独立 SQLite 文件验证数量和成本一起提交，包含关闭数据库后的真正冷读。
void main() {
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late String databasePath;
  late AppDatabase db;
  late SqliteLedgerRepository repo;
  late VeriFinController controller;
  late LocalKeyValueStore store;
  final account = investmentAccountFixture(id: 'opening-quantity-usd');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'verifin-opening-quantity-',
    );
    databasePath = '${directory.path}${Platform.pathSeparator}ledger.sqlite';
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: databasePath,
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
    await directory.delete(recursive: true);
  });

  /// [quantity]/[cost] 是已保存的原始期初事实；报价固定为 300，仅供重放验算。
  Future<void> enable({
    String quantity = '319.72',
    String? cost = '639.44',
    bool short = false,
    StockSecurity security = _goog,
  }) async {
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openedAt: DateTime(2026, 10, 1),
        openingCash: '438.77',
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
          if (security.option != null) avgoFixture.id: '300',
          security.id: '300',
        },
      ),
      isTrue,
    );
  }

  /// 关闭数据库连接后从同一文件重建 Controller，避免仅测试同一内存聚合。
  Future<void> restart() async {
    await controller.waitForPendingWrites();
    controller.dispose();
    await db.close();
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: databasePath,
    );
    repo = SqliteLedgerRepository(db);
    controller = await VeriFinController.create(store, repository: repo);
  }

  /// 按账户索引真实磁盘内容，便于比较跨账户失败是否产生半写。
  Future<Map<String, Object?>> diskSnapshot() async => {
    for (final portfolio in await repo.loadInvestmentPortfolios())
      portfolio.accountId: portfolio.toJson(),
  };

  /// 正常保存历史交易，事件在数量更正前后均应保持原始量价和顺序。
  Future<void> trade(
    String id,
    StockEventKind kind,
    String quantity,
    String price,
    int day,
  ) async {
    expect(
      await controller.saveStockEvent(
        accountId: account.id,
        security: _goog,
        event: StockEvent(
          id: id,
          securityId: _goog.id,
          kind: kind,
          occurredAt: DateTime(2026, 10, day, 10),
          sequence: day,
          quantity: quantity,
          price: price,
          fee: '0',
        ),
      ),
      isTrue,
    );
  }

  test('GOOG数量和每股成本填反后原子更正，现金438.77及重启备份均一致', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    expect(before.openingHoldings.single.quantity, '319.72');
    expect(before.openingHoldings.single.cost, '639.44');
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2',
        cost: '319.72',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isTrue,
    );
    final corrected = controller.investmentFor(account.id)!;
    expect(corrected.openingHoldings.single.quantity, '2');
    expect(corrected.openingHoldings.single.cost, '639.44');
    expect(corrected.openingCash, '438.77');
    expect(corrected.manualPrices, before.manualPrices);
    expect(corrected.events, isEmpty);
    expect(controller.entries, isEmpty);
    expect(controller.accountBalance(account), 438.77);
    expect(
      valueStocks(corrected, projectStocks(corrected)).unrealized.toString(),
      '-39.44',
    );
    final savedJson = corrected.toJson();
    expect((await diskSnapshot())[account.id], savedJson);

    await restart();
    expect(controller.investmentFor(account.id)!.toJson(), savedJson);
    expect(controller.accountBalance(account), 438.77);
    final backup = controller.exportDataJson();
    controller.importDataJson(backup, dryRun: true);
    await controller.waitForPendingWrites();
    expect((await diskSnapshot())[account.id], savedJson);
    controller.resetAllData();
    await controller.waitForPendingWrites();
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    controller.importDataJson(backup);
    await controller.waitForPendingWrites();
    await restart();
    expect(controller.investmentFor(account.id)!.toJson(), savedJson);
    expect(controller.accountBalance(account), 438.77);
    expect(controller.entries, isEmpty);
  });

  test('有效后续买卖按更正后的期初数量重放，成交和现金不改写', () async {
    await enable(quantity: '5', cost: '500');
    await trade('later-buy', StockEventKind.buy, '2', '120', 2);
    await trade('later-sell', StockEventKind.sell, '1', '150', 3);
    final before = controller.investmentFor(account.id)!;
    final eventsBefore = before.events.map((event) => event.toJson()).toList();
    final cashBefore = controller.accountBalance(account);
    expect(cashBefore, 348.77);
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2',
        cost: '100',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isTrue,
    );
    final after = controller.investmentFor(account.id)!;
    final projection = projectStocks(after);
    expect(after.openingHoldings.single.cost, '200');
    expect(projection.positions.single.quantity.toString(), '3');
    expect(projection.positions.single.cost.toString(), '330');
    expect(projection.realized.toString(), '40');
    expect(valueStocks(after, projection).unrealized.toString(), '570');
    expect(after.events.map((event) => event.toJson()).toList(), eventsBefore);
    expect(controller.accountBalance(account), cashBefore);
    expect((await diskSnapshot())[account.id], after.toJson());
  });

  test('无效数量或成本全部拒绝，不能只保存另一字段', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    final diskBefore = await diskSnapshot();
    for (final quantity in [
      '0',
      '-1',
      '',
      'NaN',
      '1e2',
      '1.123456789',
      '1000000000000',
    ]) {
      expect(
        await controller.setStockOpeningHolding(
          account.id,
          _goog.id,
          false,
          quantity: quantity,
          cost: '319.72',
          perUnit: true,
          expectedPortfolio: before,
        ),
        isFalse,
      );
      expect(identical(controller.investmentFor(account.id), before), isTrue);
      expect(await diskSnapshot(), diskBefore);
    }
    for (final cost in ['-0.00000001', '-1', '', 'NaN', '1e2']) {
      expect(
        await controller.setStockOpeningHolding(
          account.id,
          _goog.id,
          false,
          quantity: '2',
          cost: cost,
          perUnit: true,
          expectedPortfolio: before,
        ),
        isFalse,
      );
      expect(identical(controller.investmentFor(account.id), before), isTrue);
      expect(await diskSnapshot(), diskBefore);
    }
    expect(controller.accountBalance(account), 438.77);
  });

  test('编辑期间资料已变更时拒绝旧expectedPortfolio，不覆盖新参考价', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    expect(
      await controller.setStockReferencePrice(account.id, _goog.id, '310'),
      isTrue,
    );
    final latest = controller.investmentFor(account.id)!;
    final diskBefore = await diskSnapshot();
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2',
        cost: '319.72',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isFalse,
    );
    expect(identical(controller.investmentFor(account.id), latest), isTrue);
    expect(await diskSnapshot(), diskBefore);
    expect(latest.openingHoldings.single.quantity, '319.72');
    expect(latest.manualPrices[_goog.id], '310');
  });

  test('SQLite拒写时数量成本均不落盘，原草稿可在故障解除后重试', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    final diskBefore = await diskSnapshot();
    await db.db.execute(
      "CREATE TRIGGER reject_opening_quantity BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT, '模拟期初更正写入失败'); END",
    );
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2',
        cost: '319.72',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isFalse,
    );
    expect(identical(controller.investmentFor(account.id), before), isTrue);
    expect(await diskSnapshot(), diskBefore);
    expect(controller.accountBalance(account), 438.77);
    await db.db.execute('DROP TRIGGER reject_opening_quantity');
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2',
        cost: '319.72',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isTrue,
    );
    final saved = (await repo.loadInvestmentPortfolios()).single;
    expect(saved.openingHoldings.single.quantity, '2');
    expect(saved.openingHoldings.single.cost, '639.44');
  });

  test('减少期初数量导致历史超卖时拒绝，成交现金及原组合保持不变', () async {
    await enable(quantity: '5', cost: '500');
    await trade('past-sell', StockEventKind.sell, '3', '100', 2);
    final before = controller.investmentFor(account.id)!;
    final diskBefore = await diskSnapshot();
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2',
        cost: '100',
        perUnit: true,
        expectedPortfolio: before,
      ),
      isFalse,
    );
    expect(identical(controller.investmentFor(account.id), before), isTrue);
    expect(await diskSnapshot(), diskBefore);
    expect(controller.accountBalance(account), 738.77);
  });

  test('更正破坏历史转移成本配对时两账户都不能半写', () async {
    await enable(quantity: '5', cost: '500');
    final target = investmentAccountFixture(id: 'opening-quantity-target');
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
        securityId: _goog.id,
        quantity: '1',
        short: false,
        occurredAt: DateTime(2026, 10, 2),
        batchId: 'opening-quantity-transfer',
      ),
      isTrue,
    );
    final sourceBefore = controller.investmentFor(account.id)!;
    final targetBefore = controller.investmentFor(target.id)!;
    final diskBefore = await diskSnapshot();
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '4',
        cost: '200',
        perUnit: true,
        expectedPortfolio: sourceBefore,
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
    expect(await diskSnapshot(), diskBefore);
    expect(controller.accountBalance(account), 438.77);
    expect(controller.accountBalance(target), 0);
  });

  test('不存在的证券或方向不能误改另一期初仓位', () async {
    await enable();
    final before = controller.investmentFor(account.id)!;
    final diskBefore = await diskSnapshot();
    for (final identity in [
      (id: 'us:stock:GOOGL', short: false),
      (id: _goog.id, short: true),
    ]) {
      expect(
        await controller.setStockOpeningHolding(
          account.id,
          identity.id,
          identity.short,
          quantity: '2',
          cost: '319.72',
          perUnit: true,
          expectedPortfolio: before,
        ),
        isFalse,
      );
      expect(identical(controller.investmentFor(account.id), before), isTrue);
      expect(await diskSnapshot(), diskBefore);
    }
  });

  test('碎股数量与每股成本一起更正，只在最终总成本舍入', () async {
    await enable();
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        false,
        quantity: '2.5',
        cost: '12.34567891',
        perUnit: true,
      ),
      isTrue,
    );
    final saved = (await repo.loadInvestmentPortfolios()).single;
    expect(saved.openingHoldings.single.quantity, '2.5');
    expect(saved.openingHoldings.single.cost, '30.86');
    expect(controller.accountBalance(account), 438.77);
  });

  test('空头数量更正支持明确未知成本，不生成现金流', () async {
    await enable(quantity: '5', cost: '500', short: true);
    expect(
      await controller.setStockOpeningHolding(
        account.id,
        _goog.id,
        true,
        quantity: '2',
        cost: null,
      ),
      isTrue,
    );
    final saved = (await repo.loadInvestmentPortfolios()).single;
    expect(saved.openingHoldings.single.quantity, '2');
    expect(saved.openingHoldings.single.cost, isNull);
    expect(saved.openingHoldings.single.short, isTrue);
    expect(controller.accountBalance(account), 438.77);
    expect(saved.events, isEmpty);
  });

  test('旧setStockOpeningCost继续只改成本，总额与perUnit语义保持兼容', () async {
    await enable(quantity: '2', cost: '639.44');
    expect(
      await controller.setStockOpeningCost(account.id, _goog.id, false, '600'),
      isTrue,
    );
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.quantity,
      '2',
    );
    expect(
      controller.investmentFor(account.id)!.openingHoldings.single.cost,
      '600',
    );
    expect(
      await controller.setStockOpeningCost(
        account.id,
        _goog.id,
        false,
        '319.72',
        perUnit: true,
      ),
      isTrue,
    );
    final saved = (await repo.loadInvestmentPortfolios()).single;
    expect(saved.openingHoldings.single.quantity, '2');
    expect(saved.openingHoldings.single.cost, '639.44');
    expect(controller.accountBalance(account), 438.77);
  });

  for (final security in [
    const StockSecurity(
      symbol: 'TEST-FUND',
      name: '兼容基金夹具',
      market: StockMarket.us,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    ),
    optionFixture(),
  ]) {
    test('${security.isFund ? '基金' : '期权'}不能走股票数量更正，旧总成本补录仍可使用', () async {
      await enable(quantity: '3', cost: '600', security: security);
      final before = controller.investmentFor(account.id)!;
      final diskBefore = await diskSnapshot();
      expect(
        await controller.setStockOpeningHolding(
          account.id,
          security.id,
          false,
          quantity: '2',
          cost: '200',
        ),
        isFalse,
      );
      expect(identical(controller.investmentFor(account.id), before), isTrue);
      expect(await diskSnapshot(), diskBefore);
      expect(
        await controller.setStockOpeningCost(
          account.id,
          security.id,
          false,
          '1000',
        ),
        isTrue,
      );
      final saved = (await repo.loadInvestmentPortfolios()).single;
      expect(saved.openingHoldings.single.quantity, '3');
      expect(saved.openingHoldings.single.cost, '1000');
    });
  }
}
