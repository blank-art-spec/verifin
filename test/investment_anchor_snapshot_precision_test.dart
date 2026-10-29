import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/investment_fixture.dart';

/// 返回 [controller] 中 [accountId] 的实际数量和成本，独立核对股票与期权未被现金校准改写。
/// 将方向包含在键中，避免后续增加空头夹具时把同一证券的多空位置混在一起。
Map<String, List<String?>> _positionFacts(
  VeriFinController controller,
  String accountId,
) => {
  for (final position in controller.investmentProjection(accountId)!.positions)
    '${position.securityId}:${position.short}': [
      position.quantity.toString(),
      position.cost?.toString(),
    ],
};

/// 验证 [account] 的快照既可被公共 Controller 读取，也可作为历史纯计算入口的有效依据。
/// [expectedPositions] 保存校准前的真实数量/成本；所有金额均为固定离线夹具，不代表真实行情。
/// [expectedEntryIds] 可指定已保存普通流水，验证入库前后的时间文本变化不会使历史依据失效。
void _expectSnapshotUsable(
  VeriFinController controller,
  Account account,
  Map<String, List<String?>> expectedPositions, {
  List<String> expectedEntryIds = const [],
}) {
  final portfolio = controller.investmentFor(account.id)!;
  final snapshot = portfolio.valuationSnapshots.single;
  expect(controller.accountBalance(account), 9000);
  expect(_positionFacts(controller, account.id), expectedPositions);
  expect(
    controller.entries.map((entry) => entry.id),
    unorderedEquals(expectedEntryIds),
  );
  expect(portfolio.events, isEmpty);
  // 现金 9000、股票 2×50、期权 1×3×100，总计仍应为 9400 美元。
  final valuation = controller.investmentSnapshotValuation(
    account.id,
    snapshot,
  );
  expect(
    valuation,
    isNotNull,
    reason: '未改任何经济事实，SQLite 的时间精度/时区转换不能使已保存投资依据失效',
  );
  expect(valuation?.amounts?.net, 9400);
  final anchor = controller.latestBalanceAnchor(account.id)!;
  expect(
    investmentSnapshotAt(portfolio, snapshot.capturedAt, controller.entries, [
      anchor,
    ]),
    isNotNull,
    reason: '同一历史截点必须能继续找到有效价格依据，不能在冷启动后退化为未知',
  );
}

/// 通过真实 SQLite 和公开命令核对现金锚点入库前后对历史修订摘要的影响。
/// 不启动 Android、不请求行情、不改变期权规格，也不把收益写成收入流水。
void main() {
  setUpAll(sqfliteFfiInit);

  test('导入同毫秒多条核对记录时，实际采用余额变化必须使旧历史依据失效', () {
    final account = investmentAccountFixture();
    final portfolio = portfolioFixture();
    final at = DateTime(2026, 10, 3);
    final first = BalanceAnchor(
      id: 'anchor-a',
      bookId: account.bookId,
      accountId: account.id,
      effectiveAt: DateTime(2026, 10, 2, 10, 0, 0, 123, 100),
      balance: 9000,
      createdAt: DateTime(2026, 10, 2, 11),
    );
    final second = BalanceAnchor(
      id: 'anchor-b',
      bookId: account.bookId,
      accountId: account.id,
      effectiveAt: DateTime(2026, 10, 2, 10, 0, 0, 123, 200),
      balance: 8000,
      createdAt: DateTime(2026, 10, 2, 11),
    );
    final moved = BalanceAnchor(
      id: first.id,
      bookId: first.bookId,
      accountId: first.accountId,
      effectiveAt: DateTime(2026, 10, 2, 10, 0, 0, 123, 300),
      balance: first.balance,
      createdAt: first.createdAt,
    );
    expect(
      accountCashAt(
        account: account,
        entries: const [],
        anchors: [first, second],
        at: at,
        portfolio: portfolio,
      ),
      8000,
    );
    expect(
      accountCashAt(
        account: account,
        entries: const [],
        anchors: [moved, second],
        at: at,
        portfolio: portfolio,
      ),
      9000,
    );
    expect(
      investmentRevision(portfolio, const [], [moved, second], at),
      isNot(investmentRevision(portfolio, const [], [first, second], at)),
      reason: '仅在副本中统一时间精度，也不能掩盖实际最新核对记录已经改变的事实',
    );
  });

  test('既有本地毫秒锚点的 JSON 形状及冻结投资修订摘要经 SQLite 往返保持', () async {
    // 这份旧形状没有 UTC 后缀、没有微秒，符合既有 SQLite 和模型的毫秒精度契约。
    final legacyJson = <String, Object?>{
      'id': 'legacy-local-anchor',
      'bookId': defaultLedgerBookId,
      'accountId': 'legacy-local-ms',
      'effectiveAt': '2026-10-02T10:00:00.123',
      'balance': 9000.0,
      'createdAt': '2026-10-02T11:00:00.456',
      'note': '旧毫秒本地锚点',
    };
    final anchor = BalanceAnchor.fromJson(legacyJson);
    final portfolio = InvestmentPortfolio(
      accountId: 'legacy-local-ms',
      bookId: defaultLedgerBookId,
      currencyCode: 'USD',
      openedAt: DateTime(2026, 10, 1),
      openingCash: '10000',
    );
    final at = DateTime(2026, 10, 3);
    // 先由修复前的原算法实跑冻结；不能在生产修复后重新生成常量来掩盖旧摘要变化。
    const legacyRevision =
        '0166fb510417bfdcfba14c8fae8d74088d25da13a6658fec7815cf6f630361c4';
    expect(anchor.toJson(), legacyJson);
    expect(
      investmentRevision(portfolio, const [], [anchor], at),
      legacyRevision,
    );
    final database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repository = SqliteLedgerRepository(database);
      await repository.saveBalanceAnchors([anchor]);
      final restored = (await repository.loadBalanceAnchors()).single;
      expect(restored.toJson(), legacyJson);
      expect(
        investmentRevision(portfolio, const [], [restored], at),
        legacyRevision,
      );
    } finally {
      await database.close();
    }
  });

  for (final useMicroseconds in [true, false]) {
    test(
      '${useMicroseconds ? 'UTC微秒' : 'UTC毫秒'}现金锚点捕获投资依据后冷启动仍可读，股票期权和现金不变',
      () async {
        final database = await AppDatabase.open(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        final repository = SqliteLedgerRepository(database);
        final store = LocalKeyValueStore();
        var controller = await VeriFinController.create(
          store,
          repository: repository,
        );
        var controllerAlive = true;
        try {
          final account = investmentAccountFixture(
            id: 'anchor-snapshot-${useMicroseconds ? 'micros' : 'millis'}',
            bookId: controller.activeBook.id,
          );
          final option = optionFixture(expiry: '2099-12-18');
          // 使用明确过去的公历日，既不依赖本机时区，也不会在午夜附近构造未来锚点。
          final now = DateTime.now().toUtc();
          final previous = addCalendarDays(now, -1);
          final opened = addCalendarDays(previous, -2);
          final effectiveAt = DateTime.utc(
            previous.year,
            previous.month,
            previous.day,
            1,
            15,
            0,
            123,
            useMicroseconds ? 800 : 0,
          );
          controller.addAccount(account);
          await controller.waitForPendingWrites();
          expect(
            await controller.enableInvestment(
              accountId: account.id,
              openingCash: '10000',
              openedAt: DateTime.utc(opened.year, opened.month, opened.day),
              securities: [avgoFixture, option],
              openingHoldings: [
                StockHolding(
                  securityId: avgoFixture.id,
                  short: false,
                  quantity: '2',
                  cost: '80',
                ),
                StockHolding(
                  securityId: option.id,
                  short: false,
                  quantity: '1',
                  cost: '200',
                ),
              ],
              manualPrices: {avgoFixture.id: '50', option.id: '3'},
            ),
            isTrue,
          );
          final positions = _positionFacts(controller, account.id);
          expect(positions, {
            '${avgoFixture.id}:false': ['2', '80'],
            '${option.id}:false': ['1', '200'],
          });
          expect(
            await controller.saveBalanceAnchor(
              account: account,
              effectiveAt: effectiveAt,
              balance: 9000,
              note: '隔离锚点与历史依据精度检查',
            ),
            isTrue,
          );
          expect(
            await controller.captureInvestmentValuation(account.id),
            isTrue,
          );
          _expectSnapshotUsable(controller, account, positions);
          final anchorBefore = controller.latestBalanceAnchor(account.id)!;
          final snapshotBefore = controller
              .investmentFor(account.id)!
              .valuationSnapshots
              .single;
          final storedAnchor = (await repository.loadBalanceAnchors()).single;
          // 实际现金和锚点毫秒始终相同；UTC/本地文本或微秒的改变不能影响账目事实。
          expect(
            storedAnchor.effectiveAt.millisecondsSinceEpoch,
            effectiveAt.millisecondsSinceEpoch,
          );
          expect(storedAnchor.balance, anchorBefore.balance);

          controller.dispose();
          controllerAlive = false;
          controller = await VeriFinController.create(
            store,
            repository: repository,
          );
          controllerAlive = true;
          _expectSnapshotUsable(controller, account, positions);
          expect(
            controller
                .investmentFor(account.id)!
                .valuationSnapshots
                .single
                .toJson(),
            snapshotBefore.toJson(),
          );
          final anchorAfter = controller.latestBalanceAnchor(account.id)!;
          // 保留原 BalanceAnchor 行为：SQLite 可改变原微秒/UTC文本，摘要应独立规范这些表示。
          // 不能为了摘要稳定改写普通账户的真实锚点对象，导致同毫秒流水被再次计算。
          expect(anchorAfter.id, anchorBefore.id);
          expect(anchorAfter.balance, anchorBefore.balance);
          expect(
            anchorAfter.effectiveAt.millisecondsSinceEpoch,
            anchorBefore.effectiveAt.millisecondsSinceEpoch,
          );
          expect(
            anchorAfter.createdAt.millisecondsSinceEpoch,
            anchorBefore.createdAt.millisecondsSinceEpoch,
          );
          final backup = controller.exportDataJson();
          controller.importDataJson(backup, dryRun: true);
          _expectSnapshotUsable(controller, account, positions);
          controller.resetAllData();
          await controller.waitForPendingWrites();
          controller.importDataJson(backup);
          await controller.waitForPendingWrites();
          _expectSnapshotUsable(controller, account, positions);
          controller.dispose();
          controllerAlive = false;
          controller = await VeriFinController.create(
            store,
            repository: repository,
          );
          controllerAlive = true;
          _expectSnapshotUsable(controller, account, positions);
        } finally {
          if (controllerAlive) controller.dispose();
          await database.close();
        }
      },
    );
  }

  test('UTC微秒普通交易及记账日期的文本冷读变化不使股票期权快照失效，完整恢复仍可读', () async {
    final database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repository = SqliteLedgerRepository(database);
    final store = LocalKeyValueStore();
    var controller = await VeriFinController.create(
      store,
      repository: repository,
    );
    var controllerAlive = true;
    try {
      final account = investmentAccountFixture(
        id: 'entry-snapshot-precision',
        bookId: controller.activeBook.id,
      );
      final option = optionFixture(expiry: '2099-12-18');
      final previous = addCalendarDays(DateTime.now().toUtc(), -1);
      final opened = addCalendarDays(previous, -2);
      final occurredAt = DateTime.utc(
        previous.year,
        previous.month,
        previous.day,
        1,
        0,
        0,
        123,
        800,
      );
      final postDate = DateTime.utc(
        previous.year,
        previous.month,
        previous.day,
        2,
        0,
        0,
        456,
        900,
      );
      final effectiveAt = DateTime.utc(
        previous.year,
        previous.month,
        previous.day,
        3,
        0,
        0,
        789,
        800,
      );
      controller.addAccount(account);
      await controller.waitForPendingWrites();
      expect(
        await controller.enableInvestment(
          accountId: account.id,
          openingCash: '10000',
          openedAt: DateTime.utc(opened.year, opened.month, opened.day),
          securities: [avgoFixture, option],
          openingHoldings: [
            StockHolding(
              securityId: avgoFixture.id,
              short: false,
              quantity: '2',
              cost: '80',
            ),
            StockHolding(
              securityId: option.id,
              short: false,
              quantity: '1',
              cost: '200',
            ),
          ],
          manualPrices: {avgoFixture.id: '50', option.id: '3'},
        ),
        isTrue,
      );
      final category = controller.categories.firstWhere(
        (value) => value.type == EntryType.expense,
      );
      controller.addEntry(
        LedgerEntry(
          id: 'utc-micro-expense',
          bookId: account.bookId,
          type: EntryType.expense,
          amount: 100,
          currencyCode: 'USD',
          accountAmount: 100,
          baseAmount: 700,
          conversionSource: ConversionSource.manual,
          categoryId: category.id,
          accountId: account.id,
          note: '只核对时刻序列化，不更改交易金额',
          occurredAt: occurredAt,
          postDate: postDate,
        ),
      );
      await controller.waitForPendingWrites();
      expect(
        await controller.saveBalanceAnchor(
          account: account,
          effectiveAt: effectiveAt,
          balance: 9000,
        ),
        isTrue,
      );
      final positions = _positionFacts(controller, account.id);
      expect(await controller.captureInvestmentValuation(account.id), isTrue);
      _expectSnapshotUsable(
        controller,
        account,
        positions,
        expectedEntryIds: const ['utc-micro-expense'],
      );
      final before = controller.entries.single;
      final snapshot = controller
          .investmentFor(account.id)!
          .valuationSnapshots
          .single
          .toJson();
      final backup = controller.exportDataJson();
      controller.dispose();
      controllerAlive = false;
      controller = await VeriFinController.create(
        store,
        repository: repository,
      );
      controllerAlive = true;
      _expectSnapshotUsable(
        controller,
        account,
        positions,
        expectedEntryIds: const ['utc-micro-expense'],
      );
      expect(
        controller.entries.single.occurredAt.millisecondsSinceEpoch,
        before.occurredAt.millisecondsSinceEpoch,
      );
      expect(
        controller.entries.single.postDate!.millisecondsSinceEpoch,
        before.postDate!.millisecondsSinceEpoch,
      );
      expect(controller.entries.single.amount, before.amount);
      expect(
        controller
            .investmentFor(account.id)!
            .valuationSnapshots
            .single
            .toJson(),
        snapshot,
      );
      controller.importDataJson(backup, dryRun: true);
      _expectSnapshotUsable(
        controller,
        account,
        positions,
        expectedEntryIds: const ['utc-micro-expense'],
      );
      controller.resetAllData();
      await controller.waitForPendingWrites();
      controller.importDataJson(backup);
      await controller.waitForPendingWrites();
      _expectSnapshotUsable(
        controller,
        account,
        positions,
        expectedEntryIds: const ['utc-micro-expense'],
      );
      controller.dispose();
      controllerAlive = false;
      controller = await VeriFinController.create(
        store,
        repository: repository,
      );
      controllerAlive = true;
      _expectSnapshotUsable(
        controller,
        account,
        positions,
        expectedEntryIds: const ['utc-micro-expense'],
      );
      expect(controller.entries.single.amount, 100);
      expect(
        controller
            .investmentFor(account.id)!
            .valuationSnapshots
            .single
            .toJson(),
        snapshot,
      );
    } finally {
      if (controllerAlive) controller.dispose();
      await database.close();
    }
  });

  test('普通账户同毫秒支出早于核对时刻，不能为快照规范时间而重算一次，冷启仍为900', () async {
    final database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final repository = SqliteLedgerRepository(database);
    final store = LocalKeyValueStore();
    var controller = await VeriFinController.create(
      store,
      repository: repository,
    );
    var controllerAlive = true;
    try {
      final account = Account(
        id: 'ordinary-anchor-boundary',
        bookId: controller.activeBook.id,
        name: '普通现金精度边界',
        type: AccountType.cash,
        groupId: null,
        initialBalance: 1000,
        iconCode: 'cash',
        note: '隔离校准测试',
        includeInAssets: true,
        hidden: false,
      );
      final previous = addCalendarDays(DateTime.now().toUtc(), -1);
      final occurredAt = DateTime.utc(
        previous.year,
        previous.month,
        previous.day,
        1,
        0,
        0,
        123,
        500,
      );
      final effectiveAt = DateTime.utc(
        previous.year,
        previous.month,
        previous.day,
        1,
        0,
        0,
        123,
        800,
      );
      controller.addAccount(account);
      await controller.waitForPendingWrites();
      final category = controller.categories.firstWhere(
        (value) => value.type == EntryType.expense,
      );
      controller.addEntry(
        LedgerEntry(
          id: 'ordinary-same-ms-expense',
          bookId: account.bookId,
          type: EntryType.expense,
          amount: 100,
          categoryId: category.id,
          accountId: account.id,
          note: '',
          occurredAt: occurredAt,
        ),
      );
      await controller.waitForPendingWrites();
      expect(controller.accountBalance(account), 900);
      expect(
        await controller.saveBalanceAnchor(
          account: account,
          effectiveAt: effectiveAt,
          balance: 900,
        ),
        isTrue,
      );
      expect(
        controller.accountBalance(account),
        900,
        reason: '核对前的支出已经包含在900中，不能因锚点截去微秒变成再次扣款',
      );
      expect(
        controller.latestBalanceAnchor(account.id)!.effectiveAt,
        effectiveAt,
      );
      controller.dispose();
      controllerAlive = false;
      controller = await VeriFinController.create(
        store,
        repository: repository,
      );
      controllerAlive = true;
      expect(controller.accountBalance(account), 900);
      expect(controller.entries.single.amount, 100);
      expect(controller.entries, hasLength(1));
      expect(controller.latestBalanceAnchor(account.id)!.balance, 900);
    } finally {
      if (controllerAlive) controller.dispose();
      await database.close();
    }
  });
}
