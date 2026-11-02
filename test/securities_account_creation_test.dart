import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/in_memory_ledger_repository.dart';
import 'support/investment_fixture.dart';

/// 只在最终开户事务注入失败，不影响控制器启动时的正常初始化。
class _FailingSecuritiesRepository extends InMemoryLedgerRepository {
  bool failCreation = false;

  /// 模拟磁盘事务在提交前失败，要求调用方保持原账户、主账户和持仓整体不变。
  @override
  Future<void> saveSecuritiesAccountAggregate({
    required List<CreditAccount> creditAccounts,
    required List<Account> accounts,
    required List<InvestmentPortfolio> investmentPortfolios,
  }) async {
    if (failCreation) throw StateError('测试注入：证券开户事务写入失败');
    await super.saveSecuritiesAccountAggregate(
      creditAccounts: creditAccounts,
      accounts: accounts,
      investmentPortfolios: investmentPortfolios,
    );
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  for (final sqlite in [false, true]) {
    test('${sqlite ? 'SQLite' : '内存'}证券开户原子保存并在冷启动后只计算一次期初现金', () async {
      final AppDatabase? db = sqlite
          ? await AppDatabase.open(
              factory: databaseFactoryFfi,
              path: inMemoryDatabasePath,
            )
          : null;
      final LedgerRepository repo = db == null
          ? InMemoryLedgerRepository()
          : SqliteLedgerRepository(db);
      final store = LocalKeyValueStore();
      var c = await VeriFinController.create(store, repository: repo);
      try {
        final account = investmentAccountFixture(id: 'new-securities-usd');
        final ordinaryBefore = c.entries
            .map((entry) => entry.toJson())
            .toList();
        expect(
          await c.createSecuritiesAccount(
            account: account,
            openingCash: '1234.567',
            openedAt: DateTime(2026, 11, 1, 9),
          ),
          isTrue,
        );
        var saved = c.accounts.singleWhere((a) => a.id == account.id);
        final parent = c.parentForAccount(saved)!;
        expect(saved.initialBalance, 0);
        expect(c.accountBalance(saved), 1234.57);
        expect(c.investmentFor(saved.id)!.openingCash, '1234.57');
        expect(c.investmentFor(saved.id)!.events, isEmpty);
        expect(c.investmentProjection(saved.id)!.positions, isEmpty);
        expect(
          c.entries.map((entry) => entry.toJson()).toList(),
          ordinaryBefore,
        );
        expect(parent.creditLimit, isNull);
        expect(parent.statementDay, isNull);

        c.dispose();
        c = await VeriFinController.create(store, repository: repo);
        saved = c.accounts.singleWhere((a) => a.id == account.id);
        expect(c.parentForAccount(saved)!.id, parent.id);
        expect(c.accountBalance(saved), 1234.57);
        expect(c.investmentFor(saved.id)!.openingCash, '1234.57');
        expect(
          c.entries.map((entry) => entry.toJson()).toList(),
          ordinaryBefore,
        );
        expect(
          (await repo.loadAccounts()).where((a) => a.id == account.id),
          hasLength(1),
        );
        expect(
          (await repo.loadInvestmentPortfolios()).where(
            (portfolio) => portfolio.accountId == account.id,
          ),
          hasLength(1),
        );
      } finally {
        c.dispose();
        await db?.close();
      }
    });
  }

  test('首次开户写入失败没有半套数据，使用原稳定 ID 重试可成功', () async {
    final repo = _FailingSecuritiesRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    final account = investmentAccountFixture(id: 'retry-securities');
    final accountsBefore = c.accounts.map((value) => value.toJson()).toList();
    final parentsBefore = c.accountParents
        .map((value) => value.toJson())
        .toList();
    repo.failCreation = true;
    expect(
      await c.createSecuritiesAccount(account: account, openingCash: '2000'),
      isFalse,
    );
    expect(c.accounts.map((value) => value.toJson()).toList(), accountsBefore);
    expect(
      c.accountParents.map((value) => value.toJson()).toList(),
      parentsBefore,
    );
    expect(c.investmentFor(account.id), isNull);
    expect(
      (await repo.loadAccounts()).map((value) => value.toJson()).toList(),
      accountsBefore,
    );
    expect(await repo.loadInvestmentPortfolios(), isEmpty);

    repo.failCreation = false;
    expect(
      await c.createSecuritiesAccount(account: account, openingCash: '2000'),
      isTrue,
    );
    expect(c.accounts.where((value) => value.id == account.id), hasLength(1));
    expect(
      c.accountBalance(c.accounts.singleWhere((a) => a.id == account.id)),
      2000,
    );
    expect(c.entries, isEmpty);
  });

  test('已有主账户下开户失败保护原数据，重试和重复币种均不会重复创建', () async {
    final repo = _FailingSecuritiesRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    final usd = investmentAccountFixture(id: 'parent-usd');
    expect(
      await c.createSecuritiesAccount(account: usd, openingCash: '1000'),
      isTrue,
    );
    final savedUsd = c.accounts.singleWhere((value) => value.id == usd.id);
    final parent = c.parentForAccount(savedUsd)!;
    final usdPortfolio = c.investmentFor(usd.id)!.toJson();
    final hkd = investmentAccountFixture(
      id: 'same-parent-hkd',
      currency: 'HKD',
    ).copyWith(creditAccountId: parent.id);
    repo.failCreation = true;
    expect(
      await c.createSecuritiesAccount(account: hkd, openingCash: '500'),
      isFalse,
    );
    expect(c.accountParents.single.toJson(), parent.toJson());
    expect(c.accountsForParent(parent.id).map((value) => value.id), [usd.id]);
    expect(c.investmentFor(usd.id)!.toJson(), usdPortfolio);
    expect((await repo.loadCreditAccounts()).single.toJson(), parent.toJson());

    repo.failCreation = false;
    expect(
      await c.createSecuritiesAccount(account: hkd, openingCash: '500'),
      isTrue,
    );
    expect(c.accountParents, hasLength(1));
    expect(c.accountsForParent(parent.id), hasLength(2));
    expect(c.investmentFor(usd.id)!.toJson(), usdPortfolio);
    final duplicateCurrency = hkd.copyWith(id: 'another-hkd');
    expect(
      await c.createSecuritiesAccount(
        account: duplicateCurrency,
        openingCash: '999',
      ),
      isFalse,
    );
    expect(
      await c.createSecuritiesAccount(account: hkd, openingCash: '999'),
      isFalse,
    );
    expect(c.accountsForParent(parent.id), hasLength(2));
    expect(
      c.accountBalance(c.accounts.singleWhere((a) => a.id == hkd.id)),
      500,
    );
    expect((await repo.loadInvestmentPortfolios()), hasLength(2));
    expect(c.entries, isEmpty);
  });

  test('并发重复点击同一稳定账户 ID 只成功一次，没有重复现金或主账户', () async {
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: InMemoryLedgerRepository(),
    );
    addTearDown(c.dispose);
    final account = investmentAccountFixture(id: 'concurrent-account');
    final results = await Future.wait([
      c.createSecuritiesAccount(account: account, openingCash: '200'),
      c.createSecuritiesAccount(account: account, openingCash: '200'),
    ]);
    expect(results.where((saved) => saved), hasLength(1));
    expect(c.accounts.where((value) => value.id == account.id), hasLength(1));
    expect(c.accountParents, hasLength(1));
    expect(
      c.accountBalance(c.accounts.singleWhere((a) => a.id == account.id)),
      200,
    );
    expect(c.entries, isEmpty);
  });

  test('非法现金、错误类型和失效账本上下文均不创建账户', () async {
    final repo = InMemoryLedgerRepository();
    final c = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repo,
    );
    addTearDown(c.dispose);
    final account = investmentAccountFixture(id: 'invalid-account');
    for (final cash in ['-1', '-0.001', '不是金额']) {
      expect(
        await c.createSecuritiesAccount(account: account, openingCash: cash),
        isFalse,
      );
    }
    expect(
      await c.createSecuritiesAccount(
        account: account.copyWith(type: AccountType.cash),
        openingCash: '10',
      ),
      isFalse,
    );
    expect(await c.createLedgerBook('其他账本'), isTrue);
    expect(
      await c.createSecuritiesAccount(account: account, openingCash: '10'),
      isFalse,
    );
    expect(await repo.loadAccounts(), isEmpty);
    expect(await repo.loadCreditAccounts(), isEmpty);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    expect(await repo.loadEntries(), isEmpty);
  });
}
