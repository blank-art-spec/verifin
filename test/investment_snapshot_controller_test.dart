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
  final account = investmentAccountFixture();
  setUp(() async {
    db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    repo = SqliteLedgerRepository(db);
    c = await VeriFinController.create(LocalKeyValueStore(), repository: repo);
    c.addAccount(account);
    await c.waitForPendingWrites();
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: [avgoFixture],
        openingHoldings: [
          StockHolding(
            securityId: avgoFixture.id,
            short: false,
            quantity: '2',
            cost: '600',
          ),
        ],
        manualPrices: {avgoFixture.id: '330'},
      ),
      isTrue,
    );
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  test('历史依据 SQLite 保存失败零发布，重试、冷启动和 v13 完整恢复一致', () async {
    final before = c.investmentFor(account.id)!.toJson();
    await db.db.execute(
      "CREATE TRIGGER snapshot_failure BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT,'历史依据注入失败'); END",
    );
    expect(await c.captureInvestmentValuation(account.id), isFalse);
    expect(c.investmentFor(account.id)!.toJson(), before);
    expect((await repo.loadInvestmentPortfolios()).single.toJson(), before);
    await db.db.execute('DROP TRIGGER snapshot_failure');
    expect(await c.captureInvestmentValuation(account.id), isTrue);
    final p = c.investmentFor(account.id)!, s = p.valuationSnapshots.single;
    expect(s.prices[avgoFixture.id]!.price, '330');
    expect(s.prices[avgoFixture.id]!.manual, isTrue);
    // 当前基础账本为 CNY，未配置 USD 汇率时仍保存原币依据，不伪造本位币净值。
    expect(s.rateToBase, isNull);
    expect(c.investmentSnapshotValuation(account.id, s)!.amounts!.net, 10660);
    expect(
      await c.setStockReferencePrice(account.id, avgoFixture.id, '500'),
      isTrue,
    );
    expect(c.accountAssetValue(account), 11000);
    expect(
      c
          .investmentSnapshotValuation(
            account.id,
            c.investmentFor(account.id)!.valuationSnapshots.single,
          )!
          .amounts!
          .net,
      10660,
    );
    c.dispose();
    c = await VeriFinController.create(LocalKeyValueStore(), repository: repo);
    expect(
      c.investmentFor(account.id)!.valuationSnapshots.single.toJson(),
      s.toJson(),
    );
    final raw = c.exportDataJson();
    expect((jsonDecode(raw) as Map)['version'], 13);
    final beforePreview = c.investmentFor(account.id)!.toJson();
    c.importDataJson(raw, dryRun: true);
    expect(c.investmentFor(account.id)!.toJson(), beforePreview);
    c.importDataJson(raw);
    await c.waitForPendingWrites();
    expect(
      (await repo.loadInvestmentPortfolios()).single.valuationSnapshots.single
          .toJson(),
      s.toJson(),
    );
    expect(c.accountAssetValue(account), 11000);
    // 旧版没有 type/dateOnly 默认字段；恢复后原修订摘要和历史估值仍应有效。
    final legacyV12 = jsonDecode(raw) as Map<String, dynamic>;
    legacyV12['version'] = 12;
    c.importDataJson(jsonEncode(legacyV12));
    await c.waitForPendingWrites();
    final legacySnapshot = c
        .investmentFor(account.id)!
        .valuationSnapshots
        .single;
    expect(legacySnapshot.prices[avgoFixture.id]!.dateOnly, isFalse);
    expect(
      c.investmentSnapshotValuation(account.id, legacySnapshot)!.amounts!.net,
      10660,
    );
    expect(legacySnapshot.toJson(), s.toJson());
  });
  test('v11 旧聚合默认无历史，非法快照预览拒绝且不写；删账户清理附属依据', () async {
    await c.captureInvestmentValuation(account.id);
    final raw = c.exportDataJson(),
        invalid = jsonDecode(raw) as Map<String, dynamic>;
    final data = Map<String, Object?>.from(invalid['data'] as Map);
    final portfolios = data['investmentPortfolios'] as List;
    final invalidPortfolio = Map<String, Object?>.from(portfolios.first as Map);
    final snapshots = invalidPortfolio['valuationSnapshots'] as List;
    final fact = Map<String, Object?>.from(snapshots.first as Map)
      ..['rateToBase'] = -1;
    snapshots[0] = fact;
    portfolios[0] = invalidPortfolio;
    invalid['data'] = data;
    expect(
      () => c.importDataJson(jsonEncode(invalid), dryRun: true),
      throwsFormatException,
    );
    expect(c.investmentFor(account.id)!.valuationSnapshots, hasLength(1));
    final legacy = jsonDecode(raw) as Map<String, dynamic>;
    legacy['version'] = 11;
    final legacyData = Map<String, Object?>.from(legacy['data'] as Map);
    final oldPortfolios = legacyData['investmentPortfolios'] as List;
    oldPortfolios[0] = Map<String, Object?>.from(oldPortfolios.first as Map)
      ..remove('valuationSnapshots');
    legacy['data'] = legacyData;
    c.importDataJson(jsonEncode(legacy));
    await c.waitForPendingWrites();
    expect(c.investmentFor(account.id)!.valuationSnapshots, isEmpty);
    await c.captureInvestmentValuation(account.id);
    await c.deleteAccount(account.id);
    await c.waitForPendingWrites();
    expect(c.investmentFor(account.id), isNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
  });
}
