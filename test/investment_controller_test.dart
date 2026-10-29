import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'support/investment_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late AppDatabase db;
  late SqliteLedgerRepository repo;
  late VeriFinController c;
  late LocalKeyValueStore store;
  final account = investmentAccountFixture();

  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = SqliteLedgerRepository(db);
    store = LocalKeyValueStore();
    c = await VeriFinController.create(store, repository: repo);
    c.addAccount(account);
    await c.waitForPendingWrites();
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  /// 统一启用时间，确保所有固定测试成交均晚于期初。
  Future<void> enable({String cash = '10000', bool financing = false}) async {
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: cash,
        openedAt: DateTime(2026, 10, 1),
        allowFinancing: financing,
      ),
      isTrue,
    );
  }

  /// 经生产 Controller 保存股票事件，不直接向数据库拼造持仓结果。
  Future<bool> save(StockEvent event, {String price = '330'}) =>
      c.saveStockEvent(
        accountId: account.id,
        security: avgoFixture,
        event: event,
        referencePrice: price,
      );

  test('B03 SQLite 重启后现金、持仓、费用及净值正确且不生成日常收支', () async {
    await enable();
    expect(
      await save(
        stockEventFixture('buy', StockEventKind.buy, '10', '300', fee: '1'),
      ),
      isTrue,
    );
    expect(
      await save(
        stockEventFixture(
          'sell',
          StockEventKind.sell,
          '4',
          '330',
          fee: '1',
          sequence: 2,
          day: 3,
        ),
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 8318);
    expect(c.accountAssetValue(account), 10298);
    expect(c.entries, isEmpty);
    expect((await repo.loadEntries()), isEmpty);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 8318);
    expect(
      c.investmentProjection(account.id)!.positions.single.cost.toString(),
      '1800.6',
    );
    expect(c.investmentProjection(account.id)!.realized.toString(), '118.6');
  });

  test('保存失败不改现金或内存，下一次重试仅成功一次', () async {
    await enable();
    await db.db.execute(
      "CREATE TRIGGER reject_investment BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT, '模拟保存失败'); END",
    );
    final event = stockEventFixture(
      'stable-id',
      StockEventKind.buy,
      '10',
      '300',
      fee: '1',
    );
    expect(await save(event), isFalse);
    expect(c.accountBalance(account), 10000);
    expect(c.investmentFor(account.id)!.events, isEmpty);
    expect((await repo.loadInvestmentPortfolios()).single.events, isEmpty);
    await db.db.execute('DROP TRIGGER reject_investment');
    expect(await save(event), isTrue);
    expect(await save(event), isTrue);
    expect(c.investmentFor(account.id)!.events, hasLength(1));
    expect(c.accountBalance(account), 6999);
  });

  test('编辑历史成交导致超量卖出时原子拒绝，删除有效事件后重算', () async {
    await enable();
    expect(
      await save(stockEventFixture('buy', StockEventKind.buy, '10', '300')),
      isTrue,
    );
    expect(
      await save(
        stockEventFixture(
          'sell',
          StockEventKind.sell,
          '4',
          '330',
          sequence: 2,
          day: 3,
        ),
      ),
      isTrue,
    );
    expect(
      await save(stockEventFixture('buy', StockEventKind.buy, '3', '300')),
      isFalse,
    );
    expect(c.accountBalance(account), 8320);
    expect(await c.deleteStockEvent(account.id, 'buy'), isFalse);
    expect(await c.deleteStockEvent(account.id, 'sell'), isTrue);
    expect(c.accountBalance(account), 7000);
    expect(
      c.investmentProjection(account.id)!.positions.single.quantity.toString(),
      '10',
    );
  });

  test('旧总资产显式拆分、未知成本补齐及现金锚点不抹除持仓', () async {
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '5000',
        openedAt: DateTime(2026, 10, 1),
        securities: const [avgoFixture],
        openingHoldings: [
          StockHolding(
            securityId: avgoFixture.id,
            short: false,
            quantity: '100',
          ),
        ],
        manualPrices: {avgoFixture.id: '50'},
      ),
      isTrue,
    );
    expect(c.accountAssetValue(account), 10000);
    expect(
      await c.setStockOpeningCost(account.id, avgoFixture.id, false, '4000'),
      isTrue,
    );
    expect(c.accountBalance(account), 5000);
    expect(
      await c.saveBalanceAnchor(
        account: account,
        effectiveAt: DateTime(2026, 10, 2, 10),
        balance: 4990,
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 4990);
    expect(c.accountAssetValue(account), 9990);
    expect(
      c.investmentProjection(account.id)!.positions.single.quantity.toString(),
      '100',
    );
  });

  test('同刻现金核对记录已包含事件，之后补录同刻事件仍计一次', () async {
    await enable();
    expect(
      await save(stockEventFixture('buy', StockEventKind.buy, '10', '300')),
      isTrue,
    );
    expect(
      await c.saveBalanceAnchor(
        account: account,
        effectiveAt: DateTime(2026, 10, 2, 10),
        balance: 6990,
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 6990);
    expect(
      await save(
        stockEventFixture('more', StockEventKind.buy, '1', '300', sequence: 2),
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 6690);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 6690);
  });

  test('SQLite 普通流水毫秒精度与投资微秒边界重启前后保持一致', () async {
    final boundary = DateTime(2026, 10, 2, 10, 0, 0, 0, 800);
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: boundary,
      ),
      isTrue,
    );
    c.addEntry(
      LedgerEntry(
        id: 'same-ms-later',
        bookId: account.bookId,
        type: EntryType.income,
        amount: 100,
        currencyCode: 'USD',
        categoryId: c.categories
            .firstWhere((v) => v.type == EntryType.income)
            .id,
        accountId: account.id,
        note: '验收示例',
        occurredAt: DateTime(2026, 10, 2, 10, 0, 0, 0, 900),
      ),
    );
    await c.waitForPendingWrites();
    expect(c.accountBalance(account), 10100);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 10100);
    expect(
      await c.saveBalanceAnchor(
        account: account,
        effectiveAt: boundary.add(const Duration(microseconds: 150)),
        balance: 9990,
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 9990);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 9990);
    expect(
      await save(
        stockEventFixture('buy', StockEventKind.buy, '1', '300', day: 3),
      ),
      isTrue,
    );
    final time = DateTime(2026, 10, 3, 10, 0, 0, 0, 800);
    expect(
      await c.saveBalanceAnchor(
        account: account,
        effectiveAt: time,
        balance: 9700,
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 9700);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 9700);
  });

  test('资金不足拒绝；只有显式真实融资才允许负现金', () async {
    await enable(cash: '1000');
    expect(
      await save(
        stockEventFixture('buy', StockEventKind.buy, '30', '50'),
        price: '50',
      ),
      isFalse,
    );
    expect(c.accountBalance(account), 1000);
    final financed = investmentAccountFixture(id: 'financed');
    c.addAccount(financed);
    await c.waitForPendingWrites();
    expect(
      await c.enableInvestment(
        accountId: financed.id,
        openingCash: '1000',
        openedAt: DateTime(2026, 10, 1),
        allowFinancing: true,
      ),
      isTrue,
    );
    expect(
      await c.saveStockEvent(
        accountId: financed.id,
        security: avgoFixture,
        event: stockEventFixture('buy', StockEventKind.buy, '30', '50'),
        referencePrice: '50',
      ),
      isTrue,
    );
    expect(c.accountBalance(financed), -500);
    expect(c.accountAssetValue(financed), 1000);
  });

  test('后续入金不能替较早未确认融资的买入补足当时现金', () async {
    await enable(cash: '0');
    c.addEntry(
      LedgerEntry(
        id: 'later',
        bookId: account.bookId,
        type: EntryType.income,
        amount: 1000,
        currencyCode: 'USD',
        accountId: account.id,
        categoryId: c.categories
            .firstWhere((v) => v.type == EntryType.income)
            .id,
        note: '验收示例',
        occurredAt: DateTime(2026, 10, 3),
      ),
    );
    await c.waitForPendingWrites();
    expect(
      await save(stockEventFixture('earlier', StockEventKind.buy, '1', '100')),
      isFalse,
    );
    expect(c.accountBalance(account), 1000);
    expect(c.investmentFor(account.id)!.events, isEmpty);
  });

  test('同币种持仓转移两端成本原子继承，单边失败回滚，批次重试幂等', () async {
    await enable();
    final target = investmentAccountFixture(id: 'target');
    c.addAccount(target);
    await c.waitForPendingWrites();
    expect(
      await c.enableInvestment(
        accountId: target.id,
        openingCash: '0',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
    expect(
      await save(
        stockEventFixture('buy', StockEventKind.buy, '100', '50'),
        price: '50',
      ),
      isTrue,
    );
    Future<bool> transfer() => c.transferStock(
      fromAccountId: account.id,
      toAccountId: target.id,
      securityId: avgoFixture.id,
      quantity: '40',
      short: false,
      occurredAt: DateTime(2026, 10, 3),
      batchId: 'batch',
    );
    await db.db.execute(
      "CREATE TRIGGER reject_target BEFORE INSERT ON investment_portfolios WHEN NEW.id = 'target' BEGIN SELECT RAISE(ABORT, '模拟转入失败'); END",
    );
    expect(await transfer(), isFalse);
    expect(
      c.investmentProjection(account.id)!.positions.single.quantity.toString(),
      '100',
    );
    expect(
      (await repo.loadInvestmentPortfolios())
          .firstWhere((p) => p.accountId == target.id)
          .events,
      isEmpty,
    );
    await db.db.execute('DROP TRIGGER reject_target');
    expect(await transfer(), isTrue);
    expect(await transfer(), isTrue);
    expect(
      c.investmentProjection(account.id)!.positions.single.cost.toString(),
      '3000',
    );
    expect(
      c.investmentProjection(target.id)!.positions.single.cost.toString(),
      '2000',
    );
    expect(c.accountBalance(account), 5000);
    expect(c.accountBalance(target), 0);
    expect(c.accountAssetValue(account) + c.accountAssetValue(target), 10000);
  });

  test('v14 预览零写入、JSON 往返、未知事件拒绝及旧备份兼容', () async {
    await enable();
    expect(
      await save(
        stockEventFixture('buy', StockEventKind.buy, '10', '300', fee: '1'),
      ),
      isTrue,
    );
    final raw = c.exportDataJson(),
        snapshot = jsonDecode(c.exportDataJson()) as Map<String, dynamic>;
    expect(snapshot['version'], 15);
    c.importDataJson(raw, dryRun: true);
    expect(c.investmentFor(account.id)!.events, hasLength(1));
    c.importDataJson(raw);
    await c.waitForPendingWrites();
    expect(c.accountBalance(account), 6999);
    // v12 股票没有基金类型字段；新版必须保留原身份与原现金，不自动改为基金。
    final legacyV12 = jsonDecode(raw) as Map<String, dynamic>;
    legacyV12['version'] = 12;
    c.importDataJson(jsonEncode(legacyV12));
    await c.waitForPendingWrites();
    expect(c.investmentFor(account.id)!.securities.single.isStock, isTrue);
    expect(c.investmentFor(account.id)!.securities.single.id, avgoFixture.id);
    expect(c.accountBalance(account), 6999);
    final broken = jsonDecode(raw) as Map<String, dynamic>;
    final data = broken['data'] as Map<String, dynamic>;
    final portfolios = data['investmentPortfolios'] as List;
    final brokenEvent =
        ((portfolios.first as Map)['events'] as List).first as Map;
    brokenEvent['kind'] = 'unknown';
    expect(
      () => c.importDataJson(jsonEncode(broken), dryRun: true),
      throwsA(anything),
    );
    expect(c.accountBalance(account), 6999);
    final old = jsonDecode(raw) as Map<String, dynamic>;
    old['version'] = 9;
    (old['data'] as Map).remove('investmentPortfolios');
    c.importDataJson(jsonEncode(old));
    await c.waitForPendingWrites();
    expect(c.investmentFor(account.id), isNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
  });

  test('删除账户、初始化及改账户类型清理边界', () async {
    await enable();
    expect(
      await save(stockEventFixture('buy', StockEventKind.buy, '1', '300')),
      isTrue,
    );
    expect(
      await c.saveAccountDraft(account.copyWith(type: AccountType.cash)),
      isFalse,
    );
    expect(await c.deleteAccountAndRelatedEntries(account.id), isNotNull);
    expect(c.investmentFor(account.id), isNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    c.resetAllData();
    await c.waitForPendingWrites();
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
  });

  test('并发启用与删除账户不能写回孤儿投资聚合', () async {
    final results = await Future.wait<Object?>([
      c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      c.deleteAccountAndRelatedEntries(account.id),
    ]);
    expect(results.first, isTrue);
    expect(results.last, isNotNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accounts.where((a) => a.id == account.id), isEmpty);
  });

  test('并发启用与改账户类型按同一队列核对能力', () async {
    final results = await Future.wait<bool>([
      c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      c.saveAccountDraft(account.copyWith(type: AccountType.cash)),
    ]);
    expect(results, [true, false]);
    expect(
      c.accounts.singleWhere((a) => a.id == account.id).type,
      AccountType.investment,
    );
  });

  test('并发成交与现金核对不会用旧快照覆盖新持仓', () async {
    await enable();
    expect(
      await Future.wait<bool>([
        save(stockEventFixture('buy', StockEventKind.buy, '10', '300')),
        c.saveBalanceAnchor(
          account: account,
          effectiveAt: DateTime(2026, 10, 3),
          balance: 6990,
        ),
      ]),
      [true, true],
    );
    expect(c.investmentFor(account.id)!.events, hasLength(1));
    expect(c.accountBalance(account), 6990);
  });
}
