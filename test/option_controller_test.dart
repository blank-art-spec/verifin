import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/investments/investment_validation_issue.dart';
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
  final account = investmentAccountFixture(), s = optionFixture();
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
    expect(
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  /// 通过生产保存入口录入本地验收合约；不直接插入派生持仓或现金结果。
  Future<bool> save(
    StockEvent event, {
    StockSecurity? security,
    String reference = '3',
  }) => c.saveOptionEvent(
    accountId: account.id,
    security: security ?? s,
    underlying: avgoFixture,
    event: event,
    referencePrice: reference,
    underlyingReferencePrice: '50',
  );

  /// 通过新的只读结果入口检查草稿；[security] 可替换规格，[target] 可指定未启用账户。
  /// 固定参考价与标的参考价，保证失败来自待验证的业务规则而非无关数字输入。
  OptionEventPreviewResult preview(
    StockEvent event, {
    StockSecurity? security,
    String? target,
  }) => c.previewOptionEventResult(
    accountId: target ?? account.id,
    security: security ?? s,
    underlying: avgoFixture,
    event: event,
    referencePrice: '3',
    underlyingReferencePrice: '50',
  );

  test('预览明确区分账户失效、期初时间、现金和持仓问题且零写入', () async {
    final before = c.investmentFor(account.id)!.toJson();
    final ordinary = optionEventFixture(s, StockEventKind.optionBuyOpen);
    expect(
      preview(ordinary, target: 'missing').issue,
      InvestmentValidationIssue.accountUnavailable,
    );
    expect(
      preview(
        optionEventFixture(
          s,
          StockEventKind.optionBuyOpen,
          date: DateTime(2026, 9, 22),
        ),
      ).issue,
      InvestmentValidationIssue.beforeOpening,
    );
    expect(
      preview(
        optionEventFixture(s, StockEventKind.optionBuyOpen, quantity: '100'),
      ).issue,
      InvestmentValidationIssue.insufficientCash,
    );
    expect(
      preview(optionEventFixture(s, StockEventKind.optionSellClose)).issue,
      InvestmentValidationIssue.positionExceeded,
    );
    final success = preview(ordinary);
    expect(success.issue, isNull);
    expect(success.preview!.cash, 9800);
    expect(c.investmentFor(account.id)!.toJson(), before);
    expect((await repo.loadInvestmentPortfolios()).single.toJson(), before);
  });

  test('预览分别说明过期、到期过早、未确认结算和规格未核对', () {
    expect(
      preview(
        optionEventFixture(
          s,
          StockEventKind.optionBuyOpen,
          date: DateTime(2026, 12, 19),
        ),
      ).issue,
      InvestmentValidationIssue.expiredContract,
    );
    expect(
      preview(
        optionEventFixture(s, StockEventKind.optionExpire, price: '0'),
      ).issue,
      InvestmentValidationIssue.settlementConfirmationRequired,
    );
    expect(
      preview(
        optionEventFixture(
          s,
          StockEventKind.optionExpire,
          price: '0',
          settled: true,
        ),
      ).issue,
      InvestmentValidationIssue.beforeExpiry,
    );
    final pending = optionFixture(confirmed: false);
    expect(
      preview(
        optionEventFixture(
          pending,
          StockEventKind.optionPhysicalSettle,
          price: '0',
          settled: true,
        ),
        security: pending,
      ).issue,
      InvestmentValidationIssue.specificationRequired,
    );
  });

  test('预览区分期初成本未知与交割股票不足', () async {
    final unknownAccount = investmentAccountFixture(id: 'unknown-cost');
    c.addAccount(unknownAccount);
    await c.waitForPendingWrites();
    expect(
      await c.enableInvestment(
        accountId: unknownAccount.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: [avgoFixture, s],
        openingHoldings: [
          StockHolding(securityId: s.id, short: false, quantity: '1'),
        ],
        manualPrices: {s.id: '3'},
      ),
      isTrue,
    );
    expect(
      preview(
        optionEventFixture(
          s,
          StockEventKind.optionPhysicalSettle,
          price: '0',
          settled: true,
        ),
        target: unknownAccount.id,
      ).issue,
      InvestmentValidationIssue.unknownCost,
    );
    final put = optionFixture(right: OptionRight.put);
    expect(
      await save(
        optionEventFixture(put, StockEventKind.optionBuyOpen),
        security: put,
      ),
      isTrue,
    );
    expect(
      preview(
        optionEventFixture(
          put,
          StockEventKind.optionPhysicalSettle,
          id: 'put-delivery',
          sequence: 2,
          price: '0',
          settled: true,
        ),
        security: put,
      ).issue,
      InvestmentValidationIssue.underlyingSharesInsufficient,
    );
  });

  test('编辑影响后续平仓时给出后续记录冲突，旧预览契约仍返回空', () async {
    expect(
      await save(
        optionEventFixture(s, StockEventKind.optionBuyOpen, quantity: '2'),
      ),
      isTrue,
    );
    expect(
      await save(
        optionEventFixture(
          s,
          StockEventKind.optionSellClose,
          id: 'close',
          quantity: '2',
          sequence: 2,
        ),
      ),
      isTrue,
    );
    final edited = optionEventFixture(s, StockEventKind.optionBuyOpen);
    final result = preview(edited);
    expect(result.preview, isNull);
    expect(result.issue, InvestmentValidationIssue.subsequentEventConflict);
    expect(
      c.previewOptionEvent(
        accountId: account.id,
        security: s,
        underlying: avgoFixture,
        event: edited,
        referencePrice: '3',
      ),
      isNull,
    );
    expect(c.investmentFor(account.id)!.events.first.quantity, '2');
  });

  test('实物交割预览零写入，保存失败全部不变，重试幂等且冷启动一致', () async {
    final open = optionEventFixture(s, StockEventKind.optionBuyOpen);
    expect(await save(open), isTrue);
    final delivery = optionEventFixture(
      s,
      StockEventKind.optionPhysicalSettle,
      id: 'delivery',
      sequence: 2,
      price: '0',
      settled: true,
    );
    final before = c.investmentFor(account.id)!.toJson();
    final preview = c.previewOptionEvent(
      accountId: account.id,
      security: s,
      underlying: avgoFixture,
      event: delivery,
      referencePrice: '3',
      underlyingReferencePrice: '50',
    );
    expect(preview!.cash, 4800);
    expect(preview.projection.positions.single.cost.toString(), '5200');
    expect(c.investmentFor(account.id)!.toJson(), before);
    expect((await repo.loadInvestmentPortfolios()).single.toJson(), before);
    final sql = db.db;
    await sql.execute(
      "CREATE TRIGGER option_write_failure BEFORE INSERT ON investment_portfolios BEGIN SELECT RAISE(ABORT,'验收注入失败'); END",
    );
    expect(await save(delivery), isFalse);
    expect(c.investmentFor(account.id)!.toJson(), before);
    expect((await repo.loadInvestmentPortfolios()).single.toJson(), before);
    await sql.execute('DROP TRIGGER option_write_failure');
    expect(await save(delivery), isTrue);
    expect(await save(delivery), isTrue);
    expect(c.investmentFor(account.id)!.events, hasLength(2));
    expect(c.accountBalance(account), 4800);
    expect(c.entries, isEmpty);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 4800);
    expect(
      c.investmentProjection(account.id)!.positions.single.cost.toString(),
      '5200',
    );
    expect(await repo.loadEntries(), isEmpty);
  });

  test('合约身份不可改写，规格待补可核对，已结算交割股数不能追溯更改', () async {
    final pending = optionFixture(confirmed: false);
    expect(
      await save(
        optionEventFixture(pending, StockEventKind.optionBuyOpen),
        security: pending,
      ),
      isTrue,
    );
    final delivery = optionEventFixture(
      s,
      StockEventKind.optionPhysicalSettle,
      id: 'delivery',
      sequence: 2,
      price: '0',
      settled: true,
    );
    expect(await save(delivery, security: pending), isFalse);
    expect(await c.saveOptionSpecification(account.id, s), isTrue);
    expect(c.accountBalance(account), 9800);
    final changed = optionFixture(multiplier: '10');
    expect(await c.saveOptionSpecification(account.id, changed), isFalse);
    expect(await save(delivery), isTrue);
    expect(
      await c.saveOptionSpecification(account.id, optionFixture(shares: '10')),
      isFalse,
    );
    expect(await c.deleteStockEvent(account.id, 'option-event'), isFalse);
    expect(await c.deleteStockEvent(account.id, 'delivery'), isTrue);
    expect(c.accountBalance(account), 9800);
    expect(
      c.investmentProjection(account.id)!.positions.single.securityId,
      s.id,
    );
  });

  test('v11 全量备份恢复、非法合约预览拒绝、v10 股票默认兼容', () async {
    expect(
      await save(
        optionEventFixture(s, StockEventKind.optionSellOpen, margin: '1000'),
      ),
      isTrue,
    );
    final original = c.investmentFor(account.id)!.toJson(),
        raw = c.exportDataJson();
    expect((jsonDecode(raw) as Map)['version'], 17);
    c.importDataJson(raw, dryRun: true);
    expect(c.investmentFor(account.id)!.toJson(), original);
    c.importDataJson(raw);
    await c.waitForPendingWrites();
    expect(c.investmentFor(account.id)!.toJson(), original);
    expect(c.investmentProjection(account.id)!.frozenMargin.toString(), '1000');
    final broken = jsonDecode(raw) as Map;
    final p =
        ((broken['data'] as Map)['investmentPortfolios'] as List).single as Map;
    (((p['securities'] as List).last as Map)['option']
            as Map)['premiumMultiplier'] =
        '0';
    expect(
      () => c.importDataJson(jsonEncode(broken), dryRun: true),
      throwsA(anything),
    );
    expect(c.investmentFor(account.id)!.toJson(), original);
    final legacy = jsonDecode(raw) as Map;
    legacy['version'] = 10;
    final stock = portfolioFixture().toJson();
    (legacy['data'] as Map)['investmentPortfolios'] = [stock];
    c.importDataJson(jsonEncode(legacy));
    await c.waitForPendingWrites();
    expect(c.investmentFor(account.id)!.securities.single.option, isNull);
    expect(c.investmentProjection(account.id)!.frozenMargin.toString(), '0');
  });

  test('期权交割与现金锚点同刻不重计，之后补录现金事件仍有效', () async {
    final open = optionEventFixture(s, StockEventKind.optionBuyOpen);
    final delivery = optionEventFixture(
      s,
      StockEventKind.optionPhysicalSettle,
      id: 'delivery',
      sequence: 2,
      price: '0',
      settled: true,
    );
    expect(await save(open), isTrue);
    expect(await save(delivery), isTrue);
    expect(
      await c.saveBalanceAnchor(
        account: account,
        effectiveAt: delivery.occurredAt,
        balance: 5000,
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 5000);
    expect(
      c.investmentProjection(account.id)!.positions.single.quantity.toString(),
      '100',
    );
    final stockFee = StockEvent(
      id: 'fee',
      securityId: avgoFixture.id,
      kind: StockEventKind.fee,
      occurredAt: delivery.occurredAt,
      sequence: 3,
      quantity: '0',
      price: '1',
    );
    expect(
      await c.saveStockEvent(
        accountId: account.id,
        security: avgoFixture,
        event: stockFee,
      ),
      isTrue,
    );
    expect(c.accountBalance(account), 4999);
    c.dispose();
    c = await VeriFinController.create(store, repository: repo);
    expect(c.accountBalance(account), 4999);
  });

  test('期权不能经股票入口记录或转移，删账户及初始化清理完整聚合', () async {
    expect(
      await c.saveStockEvent(
        accountId: account.id,
        security: s,
        event: optionEventFixture(s, StockEventKind.optionBuyOpen),
      ),
      isFalse,
    );
    expect(
      await save(optionEventFixture(s, StockEventKind.optionBuyOpen)),
      isTrue,
    );
    final forged = StockEvent(
      id: 'option-event',
      securityId: avgoFixture.id,
      kind: StockEventKind.buy,
      occurredAt: DateTime(2026, 10, 3, 10),
      sequence: 1,
      quantity: '1',
      price: '50',
    );
    expect(
      await c.saveStockEvent(
        accountId: account.id,
        security: avgoFixture,
        event: forged,
      ),
      isFalse,
    );
    expect(
      c.investmentFor(account.id)!.events.single.kind,
      StockEventKind.optionBuyOpen,
    );
    expect(await c.deleteAccountAndRelatedEntries(account.id), isNotNull);
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
    c.resetAllData();
    await c.waitForPendingWrites();
    expect(await repo.loadInvestmentPortfolios(), isEmpty);
  });
}
