import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/reminder/account_entry_reminder.dart';
import 'package:verifin/app/reminder/workday_calendar_sync.dart';
import 'package:verifin/data/app_database.dart';
import 'package:verifin/data/ledger_repository.dart';
import 'support/workday_calendar_fixture.dart';
import 'support/investment_fixture.dart';

/// 模型字段往返测试：防「四处手写映射」漂移。
///
/// 每个持久化模型都有 toJson/fromJson（备份）与 _xToRow/_xFromRow（SQLite）两对
/// 手写映射，新增字段漏改任何一处都不会报错、只会静默丢数据。本文件用「全字段
/// 非默认值」夹具做两条往返（JSON 与 SQLite），再比对 toJson 输出，任一映射漏
/// 字段即失败。
///
/// **给模型加字段时必须同步更新这里的夹具**，且夹具值要满足：
/// - 与该字段在 fromJson/fromRow 里的兜底默认值**不同**（否则「写了但读丢、
///   恰好落回默认值」检测不出来）；
/// - DateTime 只到毫秒精度（SQLite 存 millisecondsSinceEpoch，微秒会被截断，
///   不是映射 bug）。
void main() {
  setUpAll(sqfliteFfiInit);
  test('v13 基金聚合缺少待确认字段时保持原 JSON 与冻结的历史修订摘要', () async {
    final legacyJson = _legacyV13FundPortfolioJson();
    final source = InvestmentPortfolio.fromJson(legacyJson);
    expect(source.fundSubscriptions, isEmpty);
    expect(source.events.single.fundSubscriptionId, isNull);
    expect(source.events.single.reportedUnrealized, isNull);
    expect(source.events.single.fundNavDate, isNull);
    expect(source.events.single.quantityInferred, isFalse);
    expect(source.toJson(), legacyJson);
    expect(source.toJson().containsKey('fundSubscriptions'), isFalse);
    final at = DateTime.utc(2026, 10, 15, 12);
    expect(
      investmentRevision(source, const [], const [], at),
      _legacyV13Revision,
    );
    expect(
      investmentSnapshotAt(source, at, const [], const [])?.toJson(),
      source.valuationSnapshots.single.toJson(),
    );
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repo = SqliteLedgerRepository(db);
      await repo.saveInvestmentPortfolios([source]);
      final restored = (await repo.loadInvestmentPortfolios()).single;
      expect(restored.toJson(), legacyJson);
      expect(
        investmentRevision(restored, const [], const [], at),
        _legacyV13Revision,
      );
      expect(restored.fundSubscriptions, isEmpty);
    } finally {
      await db.close();
    }
  });

  test('v14 申购各阶段和已有持仓基准的 JSON 与 SQLite 映射完整保留精确文本', () async {
    const fund = StockSecurity(
      symbol: 'HK0001039582',
      name: '基金金额录入映射夹具',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    // 所有日期和数值只作为映射输入，不表示真实申购或来源净值。
    final confirmation = FundSubscriptionConfirmation(
      confirmedAt: DateTime.utc(2026, 10, 28, 3),
      navDate: DateTime.utc(2026, 10, 27),
      earningStartDate: DateTime.utc(2026, 10, 28),
      nav: '109.8290',
      quantity: '12.75901629',
    );
    final source = InvestmentPortfolio(
      accountId: 'fund-amount-roundtrip',
      bookId: defaultLedgerBookId,
      currencyCode: 'USD',
      openedAt: DateTime.utc(2026, 10, 1),
      openingCash: '10000',
      securities: [fund],
      manualPrices: {fund.id: '109.8290'},
      events: [
        StockEvent(
          id: 'fund-existing-baseline',
          securityId: fund.id,
          kind: StockEventKind.fundHoldingBaseline,
          occurredAt: DateTime.utc(2026, 10, 15, 2),
          sequence: 1,
          quantity: '12.76994236',
          price: '109.8290',
          carriedCost: '1401.31',
          reportedUnrealized: '1.20',
          fundNavDate: DateTime.utc(2026, 10, 15),
          quantityInferred: true,
          note: '映射示例：反推份额不表示已确认实际成交',
        ),
        StockEvent(
          id: 'fund-confirmed-acquire',
          securityId: fund.id,
          kind: StockEventKind.fundAcquire,
          occurredAt: hongKongFundDayStart(confirmation.earningStartDate),
          sequence: 2,
          quantity: confirmation.quantity,
          price: confirmation.nav,
          carriedCost: '1401.31',
          fundSubscriptionId: 'fund-confirmed-subscription',
          fundNavDate: confirmation.navDate,
          note: '映射示例：持仓确认不重复扣款',
        ),
      ],
      fundSubscriptions: [
        FundSubscription(
          id: 'fund-request-only',
          securityId: fund.id,
          requestedAt: DateTime.utc(2026, 10, 25, 2),
          cashAmount: '500.00',
          fee: '2.00',
          expectedConfirmationDate: DateTime.utc(2026, 10, 29),
          note: '仅申请，尚未实际付款',
        ),
        FundSubscription(
          id: 'fund-paid-pending',
          securityId: fund.id,
          requestedAt: DateTime.utc(2026, 10, 25, 3),
          cashAmount: '1000.00',
          fee: '1.00',
          paidAt: DateTime.utc(2026, 10, 25, 3, 5),
          expectedConfirmationDate: DateTime.utc(2026, 10, 29),
          note: '已扣款，尚未确认份额',
        ),
        FundSubscription(
          id: 'fund-confirmed-subscription',
          securityId: fund.id,
          requestedAt: DateTime.utc(2026, 10, 26, 2),
          cashAmount: '1401.31',
          paidAt: DateTime.utc(2026, 10, 26, 2, 5),
          expectedConfirmationDate: DateTime.utc(2026, 10, 28),
          confirmation: confirmation,
          note: '已收到券商确认回执',
        ),
        FundSubscription(
          id: 'fund-cancelled-refunded',
          securityId: fund.id,
          requestedAt: DateTime.utc(2026, 10, 20, 2),
          cashAmount: '300.00',
          fee: '0.01',
          paidAt: DateTime.utc(2026, 10, 20, 2, 5),
          cancelledAt: DateTime.utc(2026, 10, 21, 2),
          refundedAt: DateTime.utc(2026, 10, 22, 2),
          refundAmount: '299.99',
          note: '已撤销并按实际退款金额核对',
        ),
      ],
    );
    final originalJson = source.toJson();
    final decoded = InvestmentPortfolio.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(originalJson)) as Map),
    );
    expect(decoded.toJson(), originalJson);
    expect(decoded.fundSubscriptions, hasLength(4));
    expect(decoded.fundSubscriptions[0].paidAt, isNull);
    expect(decoded.fundSubscriptions[1].confirmation, isNull);
    expect(decoded.fundSubscriptions[2].confirmation!.nav, '109.8290');
    expect(decoded.fundSubscriptions[2].confirmation!.quantity, '12.75901629');
    expect(decoded.fundSubscriptions[3].refundAmount, '299.99');
    expect(decoded.events.first.reportedUnrealized, '1.20');
    expect(decoded.events.first.quantityInferred, isTrue);
    expect(
      decoded.events.last.fundSubscriptionId,
      'fund-confirmed-subscription',
    );
    final confirmationJson = confirmation.toJson();
    expect(confirmationJson['navDate'], '2026-10-27');
    expect(confirmationJson['earningStartDate'], '2026-10-28');
    expect(confirmationJson['confirmedAt'], '2026-10-28T03:00:00.000Z');
    expect(decoded.events.first.toJson()['fundNavDate'], '2026-10-15');
    expect(() => decoded.fundSubscriptions.clear(), throwsUnsupportedError);
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repo = SqliteLedgerRepository(db);
      await repo.saveInvestmentPortfolios([source]);
      final restored = (await repo.loadInvestmentPortfolios()).single;
      expect(restored.toJson(), originalJson);
      expect(restored.events.first.reportedUnrealized, '1.20');
      expect(restored.events.first.quantityInferred, isTrue);
      expect(
        restored.fundSubscriptions[2].confirmation!.earningStartDate,
        DateTime.utc(2026, 10, 28),
      );
      expect(
        restored.fundSubscriptions[3].refundedAt,
        DateTime.utc(2026, 10, 22, 2),
      );
    } finally {
      await db.close();
    }
  });

  test('v15 非默认成交净值收益规则及日末事件在 JSON 和 SQLite 四向映射保留', () async {
    const fund = StockSecurity(
      symbol: 'HK0001039582',
      name: '收益规则映射夹具',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    final date = DateTime.utc(2026, 10, 23);
    final confirmation = FundSubscriptionConfirmation(
      confirmedAt: DateTime.utc(2026, 10, 26, 2),
      navDate: date,
      earningStartDate: date,
      nav: '109.8290',
      quantity: '12.759',
      accrualRule: FundAccrualRule.dealNavDate,
    );
    final source = InvestmentPortfolio(
      accountId: 'rule-roundtrip',
      bookId: defaultLedgerBookId,
      currencyCode: 'USD',
      openedAt: DateTime.utc(2026, 10, 1),
      openingCash: '5000',
      securities: [fund],
      fundSubscriptions: [
        FundSubscription(
          id: 'rule-order',
          securityId: fund.id,
          requestedAt: DateTime.utc(2026, 10, 23, 1),
          paidAt: DateTime.utc(2026, 10, 23, 2),
          cashAmount: '1401.31',
          confirmation: confirmation,
        ),
      ],
      events: [
        StockEvent(
          id: 'rule-acquire',
          securityId: fund.id,
          kind: StockEventKind.fundAcquire,
          occurredAt: hongKongFundDayEnd(date),
          sequence: 1,
          quantity: confirmation.quantity,
          price: confirmation.nav,
          carriedCost: '1401.31',
          fundSubscriptionId: 'rule-order',
          fundNavDate: date,
        ),
      ],
    );
    final json = source.toJson();
    final decoded = InvestmentPortfolio.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map),
    );
    expect(decoded.toJson(), json);
    expect(
      decoded.fundSubscriptions.single.confirmation!.toJson()['accrualRule'],
      'dealNavDate',
    );
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repository = SqliteLedgerRepository(db);
      await repository.saveInvestmentPortfolios([decoded]);
      final loaded = (await repository.loadInvestmentPortfolios()).single;
      expect(loaded.toJson(), json);
      expect(loaded.events.single.occurredAt, hongKongFundDayEnd(date));
      expect(
        loaded.fundSubscriptions.single.confirmation!.accrualRule,
        FundAccrualRule.dealNavDate,
      );
    } finally {
      await db.close();
    }
  });

  test('基金类型、精确份额和日期型净值依据 JSON/SQLite 四向映射完整保留', () async {
    const fund = StockSecurity(
      symbol: 'HK0001039582',
      name: '招商美元货币市场基金 B类',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    // 本用例使用非默认值验证四条映射；日期精度不能在导出或冷读时退回时刻。
    final source = InvestmentPortfolio(
      accountId: 'fund-usd',
      bookId: defaultLedgerBookId,
      currencyCode: 'USD',
      openedAt: DateTime(2026, 10, 1),
      openingCash: '10000',
      securities: [fund],
      events: [
        StockEvent(
          id: 'fund-buy-roundtrip',
          securityId: fund.id,
          kind: StockEventKind.buy,
          occurredAt: DateTime(2026, 10, 15, 10),
          sequence: 1,
          quantity: '10.125',
          price: '100.00000001',
          fee: '0.01',
          note: '映射验收示例：虚构份额与成交，不是基金历史价格',
        ),
      ],
      manualPrices: {fund.id: '109.80612345'},
      marketPriceIds: {fund.id},
      valuationSnapshots: [
        InvestmentValuationSnapshot(
          capturedAt: DateTime.utc(2026, 10, 28, 2, 30),
          revision: 'b' * 64,
          baseCurrencyCode: 'CNY',
          rateToBase: 7,
          rateDate: DateTime(2026, 10, 1),
          prices: {
            fund.id: InvestmentPriceFact(
              price: '109.80612345',
              quotedAt: DateTime.utc(2026, 10, 27),
              source: '基金日期精度测试来源',
              manual: false,
              dateOnly: true,
            ),
          },
        ),
      ],
    );
    final decoded = InvestmentPortfolio.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(source.toJson())) as Map),
    );
    expect(fund.id, 'hk:fund:HK0001039582');
    expect(decoded.securities.single.type, InvestmentSecurityType.fund);
    expect(decoded.securities.single.isFund, isTrue);
    expect(decoded.valuationSnapshots.single.prices[fund.id]!.dateOnly, isTrue);
    expect(decoded.toJson(), source.toJson());
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repo = SqliteLedgerRepository(db);
      await repo.saveInvestmentPortfolios([source]);
      final restored = (await repo.loadInvestmentPortfolios()).single;
      expect(restored.securities.single.id, fund.id);
      expect(
        restored.valuationSnapshots.single.prices[fund.id]!.dateOnly,
        isTrue,
      );
      expect(restored.toJson(), source.toJson());
    } finally {
      await db.close();
    }
  });

  test('旧版股票与价格依据缺少新增字段时保持原序列化形状', () {
    // 修订摘要依赖证券 JSON；默认字段继续省略，避免旧股票快照无故失效。
    final legacySecurity = <String, Object?>{
      'symbol': 'AVGO',
      'name': '博通',
      'market': 'us',
      'currencyCode': 'USD',
    };
    final stock = StockSecurity.fromJson(legacySecurity);
    expect(stock.type, InvestmentSecurityType.stock);
    expect(stock.isStock, isTrue);
    expect(stock.id, 'us:stock:AVGO');
    expect(stock.toJson(), legacySecurity);
    final legacyPrice = <String, Object?>{
      'price': '330',
      'quotedAt': '2026-10-24T00:00:00.000Z',
      'source': '旧价格来源',
      'manual': false,
    };
    final fact = InvestmentPriceFact.fromJson(legacyPrice);
    expect(fact.dateOnly, isFalse);
    expect(fact.toJson(), legacyPrice);
  });

  test('期权规格、显式结算及保证金 JSON/SQLite 四向映射完整保留', () async {
    final s = optionFixture(
      shares: '10',
      multiplier: '12.5',
      exercise: '5000.01',
    );
    final source = optionPortfolioFixture(
      s,
      events: [
        optionEventFixture(
          s,
          StockEventKind.optionPhysicalSettle,
          short: true,
          price: '0',
          settled: true,
          uncovered: true,
          margin: '123.45',
        ),
      ],
    );
    final decoded = InvestmentPortfolio.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(source.toJson())) as Map),
    );
    expect(decoded.toJson(), source.toJson());
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repo = SqliteLedgerRepository(db);
      await repo.saveInvestmentPortfolios([source]);
      expect(
        (await repo.loadInvestmentPortfolios()).single.toJson(),
        source.toJson(),
      );
    } finally {
      await db.close();
    }
  });
  test('股票聚合 JSON 与 SQLite 四向映射保留精确量价、未知成本和现金边界', () async {
    final source =
        portfolioFixture(
          events: [
            stockEventFixture(
              'buy',
              StockEventKind.buy,
              '0.125',
              '80.00000001',
              fee: '0.01',
            ),
          ],
          opening: [
            StockHolding(
              securityId: avgoFixture.id,
              short: true,
              quantity: '0.5',
            ),
          ],
        ).copyWith(
          marketPriceIds: {avgoFixture.id},
          valuationSnapshots: [
            InvestmentValuationSnapshot(
              capturedAt: DateTime(2026, 10, 24),
              revision: 'a' * 64,
              baseCurrencyCode: 'CNY',
              rateToBase: 7,
              rateDate: DateTime(2026, 10, 1),
              prices: {
                avgoFixture.id: InvestmentPriceFact(
                  price: '330.00000001',
                  quotedAt: DateTime(2026, 10, 24),
                  source: '本地测试来源',
                  manual: false,
                ),
              },
            ),
          ],
          anchorIncludedIds: {
            'anchor': ['stock:buy', 'entry:included'],
          },
        );
    final fromJson = InvestmentPortfolio.fromJson(
      Map<String, Object?>.from(jsonDecode(jsonEncode(source.toJson())) as Map),
    );
    expect(fromJson.toJson(), source.toJson());
    final db = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    try {
      final repo = SqliteLedgerRepository(db);
      await repo.saveInvestmentPortfolios([source]);
      expect(
        (await repo.loadInvestmentPortfolios()).single.toJson(),
        source.toJson(),
      );
    } finally {
      await db.close();
    }
  });

  test('工作日日历授权、有效缓存与检查状态完整往返，运行中标记不持久化', () {
    final settings = WorkdayCalendarSettings(
      enabled: true,
      documents: {2026: workdayCalendarDocument()},
      checkedAt: DateTime(2026, 10, 21, 12, 30),
      pendingYears: const {2027},
      failedYears: const {2028},
      updating: true,
    );
    final restored = WorkdayCalendarSettings.decode(
      jsonEncode(settings.toJson()),
    );
    expect(restored.toJson(), settings.toJson());
    expect(restored.updating, isFalse);
    expect(restored.calendar.toJson(), settings.calendar.toJson());
    expect(
      () => WorkdayCalendarSettings.decode('{"version":99}'),
      throwsFormatException,
    );
  });

  test('账户提醒设备 KV 保留工作日模式、缺失策略与原有字段，旧版默认不变', () {
    const rule = AccountEntryReminder(
      id: 'reminder-revision',
      accountId: 'account',
      bookId: 'book',
      currencyCode: 'USD',
      enabled: true,
      name: '饭堂',
      type: EntryType.income,
      amount: 19.5,
      categoryId: 'category',
      hour: 18,
      minute: 45,
      weekdays: [6, 7],
      repeatMode: AccountReminderRepeatMode.chinaWorkdays,
      missingCalendarPolicy: MissingWorkdayCalendarPolicy.weekdays,
      confirmLabel: '记一笔',
      cancelLabel: '跳过',
      handledDate: '2026-10-10',
    );
    final encoded =
        jsonDecode(jsonEncode(rule.toJson())) as Map<String, Object?>;
    expect(AccountEntryReminder.fromJson(encoded).toJson(), rule.toJson());
    expect(rule.copyWith().toJson(), rule.toJson());
    final legacy = {...encoded}
      ..remove('repeatMode')
      ..remove('missingCalendarPolicy');
    final restored = AccountEntryReminder.fromJson(legacy);
    expect(restored.enabled, isTrue);
    expect(restored.repeatMode, AccountReminderRepeatMode.weekdays);
    expect(restored.missingCalendarPolicy, MissingWorkdayCalendarPolicy.pause);
    expect(restored.weekdays, [6, 7]);
    expect(
      AccountEntryReminder.fromJson({
        ...encoded,
        'repeatMode': 'unknown',
      }).enabled,
      isFalse,
    );
    expect(
      AccountEntryReminder.fromJson({
        ...encoded,
        'missingCalendarPolicy': 'unknown',
      }).missingCalendarPolicy,
      MissingWorkdayCalendarPolicy.pause,
    );
  });

  // ---- 全字段非默认值夹具 ----

  final entryFull = LedgerEntry(
    id: 'entry-full',
    bookId: 'book-x',
    type: EntryType.refund,
    amount: 123.45,
    currencyCode: 'USD',
    accountAmount: 888.12,
    toAccountAmount: 99.87,
    baseAmount: 777.65,
    referenceBaseAmount: 776.54,
    repaymentBatchId: 'repayment-group-test',
    conversionSource: ConversionSource.imported,
    categoryId: 'cat-x',
    accountId: 'acc-x',
    toAccountId: 'acc-y',
    note: '往返夹具',
    occurredAt: DateTime(2026, 7, 12, 10, 30, 15, 123),
    occurredAtPrecision: OccurredAtPrecision.date,
    postDate: DateTime(2026, 7, 13),
    billingCycleId: '2026-08-25',
    tagIds: const <String>['t1', 't2'],
    fee: 2.5,
    reimbursable: true,
    refundedBaseAmount: 11.5,
    refundOf: 'entry-orig',
    settledAt: DateTime(2026, 7, 13, 9, 0, 0, 456),
    reconciliationStatus: ReconciliationStatus.amountConflict,
    sourceRecords: <EntrySourceRecord>[
      EntrySourceRecord(
        id: 'source-1',
        sourceId: 'cmb',
        sourceTransactionId: 'tx-123',
        fingerprint: 'abc123-001',
        importedAt: DateTime(2026, 7, 14, 8, 0, 0, 123),
        transactionDate: DateTime(2026, 7, 12, 10, 30, 15, 123),
        transactionDatePrecision: OccurredAtPrecision.date,
        postedDate: DateTime(2026, 7, 13),
        amount: 123.46,
        currencyCode: 'USD',
        merchant: '测试商户',
        rawDescription: '正式账单记录',
        statementId: 'statement-1',
      ),
    ],
    auditHistory: <EntryAuditRecord>[
      EntryAuditRecord(
        at: DateTime(2026, 7, 14, 8, 1, 0, 123),
        actor: EntryAuditActor.formalStatement,
        reason: EntryAuditReason.reconciled,
        sourceId: 'cmb',
        changes: const <String, EntryAuditChange>{
          'amount': EntryAuditChange(before: '100.0', after: '123.45'),
        },
      ),
    ],
  );

  /// 可空字段全空、可省略字段全默认：保证 null / 缺省路径同样无损。
  final entryMinimal = LedgerEntry(
    id: 'entry-min',
    bookId: 'book-x',
    type: EntryType.expense,
    amount: 1,
    categoryId: 'cat-x',
    accountId: '',
    note: '',
    occurredAt: DateTime(2026, 1, 2, 3, 4, 5),
  );

  final book = LedgerBook(
    id: 'book-x',
    name: '旅行账本',
    createdAt: DateTime(2026, 5, 1, 12, 0, 0, 789),
    isDefault: true,
    baseCurrencyCode: 'GBP',
    currencySetupStatus: CurrencySetupStatus.legacyUnconfirmed,
  );

  const accountFull = Account(
    id: 'acc-x',
    bookId: 'book-x',
    name: '往返测试卡',
    type: AccountType.creditCard,
    groupId: 'grp-1',
    initialBalance: -50.25,
    iconCode: 'bank',
    note: '账户备注',
    includeInAssets: false,
    hidden: true,
    currencyCode: 'EUR',
    cardLast4: '6789',
    cardNumber: '6222 1234 5678 6789',
    cardLast4Follows: true,
    creditLimit: 8000.5,
    statementDay: 5,
    dueDay: 25,
    creditAccountId: 'credit-full',
  );

  const creditAccount = CreditAccount(
    id: 'credit-full',
    bookId: 'book-x',
    name: '测试信用主体 6789',
    institution: '测试银行',
    cardLast4: '6789',
    currencyCode: 'GBP',
    creditLimit: 70000.5,
    statementDay: 25,
    dueRuleType: CreditDueRuleType.daysAfterStatement,
    dueDay: 13,
    daysAfterStatement: 20,
    cycleBudget: 4000.25,
  );

  const accountGroup = AccountGroup(
    id: 'grp-1',
    bookId: 'book-x',
    name: '投资分组',
    sortOrder: 3,
  );

  const categoryChild = Category(
    id: 'cat-x',
    label: '往返分类',
    type: EntryType.income,
    iconCode: 'emoji:🍜',
    parentId: 'cat-parent',
  );

  const categoryRoot = Category(
    id: 'cat-parent',
    label: '顶级分类',
    type: EntryType.income,
    iconCode: 'salary',
  );

  const tag = Tag(
    id: 'tag-1',
    label: '出差',
    groupId: 'project',
    iconCode: 'travel',
    archived: true,
    aliases: <String>['旅行'],
  );
  final project = Project(
    id: 'project-1',
    bookId: 'book-x',
    tagId: 'tag-1',
    name: '出差',
    startDate: DateTime(2026, 10, 1),
    endDate: DateTime(2026, 10, 7),
    budget: 2500,
    status: ProjectStatus.completed,
    note: '拜访客户',
  );
  const tagTemplate = TagTemplate(
    id: 'template-1',
    bookId: 'book-x',
    name: '出差',
    tagIds: <String>['tag-1'],
  );
  const tagGroup = TagGroup(
    id: 'custom-trip',
    name: '旅伴',
    selectionMode: TagSelectionMode.single,
    sortOrder: 6,
  );

  const attachment = Attachment(
    id: 'att-1',
    entryId: 'entry-full',
    dataUrl: 'data:image/jpeg;base64,QUJD',
  );

  final rule = RecurringRule(
    id: 'rule-1',
    bookId: 'book-x',
    type: EntryType.income,
    amount: 999.99,
    currencyCode: 'HKD',
    accountAmount: 888.88,
    toAccountAmount: 777.77,
    baseAmount: 666.66,
    ratePolicy: RecurringRatePolicy.latestAvailable,
    categoryId: 'cat-x',
    accountId: 'acc-x',
    toAccountId: 'acc-y',
    note: '工资',
    frequency: RecurringFrequency.weekly,
    startDate: DateTime(2026, 6, 1, 8, 0, 0, 1),
    nextRunDate: DateTime(2026, 7, 1, 8, 0, 0, 2),
    active: false,
  );

  final exchangeRate = ExchangeRate(
    id: 'rate-1',
    bookId: 'book-x',
    baseCurrencyCode: 'GBP',
    currencyCode: 'USD',
    effectiveDate: DateTime(2026, 7, 1),
    rateToBase: 0.7345678912,
    source: ExchangeRateSource.imported,
    createdAt: DateTime(2026, 7, 1, 8, 0, 0, 123),
    updatedAt: DateTime(2026, 7, 2, 9, 0, 0, 456),
  );

  final balanceAnchor = BalanceAnchor(
    id: 'anchor-1',
    bookId: 'book-x',
    accountId: 'acc-x',
    effectiveAt: DateTime(2026, 7, 31, 23, 59, 59, 999),
    balance: -88.12,
    createdAt: DateTime(2026, 8, 1, 8, 0, 0, 123),
    note: '银行余额核准',
  );

  final billingStatement = BillingStatement(
    id: 'statement-1',
    bookId: 'book-x',
    accountId: 'acc-x',
    statementDate: DateTime(2026, 7, 25),
    periodStart: DateTime(2026, 6, 26),
    periodEnd: DateTime(2026, 7, 25, 23, 59, 59, 999),
    statementAmount: 3703.85,
    minimumPayment: 370.39,
    dueDate: DateTime(2026, 8, 13),
    paidAmount: 3000,
    status: BillingStatementStatus.partiallyPaid,
    currencyCode: 'EUR',
    sourceId: 'cmb',
    sourceStatementId: '2026-07-25-6789',
    note: '正式账单',
  );

  final allocation = StatementRepaymentAllocation(
    id: 'allocation-1',
    bookId: 'book-x',
    statementId: 'statement-1',
    repaymentEntryId: 'entry-full',
    amount: 3000,
    createdAt: DateTime(2026, 8, 13, 10, 0, 0, 123),
  );

  final captureEvent = CaptureEvent(
    id: 'capture-1',
    bookId: 'book-x',
    sourceKind: CaptureSourceKind.notification,
    sourceId: 'com.example.bank',
    sourceLabel: '示例银行',
    sourceEventId: 'notification-42',
    rawText: '尾号4185消费59.49元，商户麦当劳',
    receivedAt: DateTime(2026, 8, 13, 12, 30, 0, 123),
    fingerprint: 'capture-fingerprint-1',
    parsedAmount: 59.49,
    currencyCode: 'CNY',
    merchant: '麦当劳',
    cardLast4: '4185',
    kind: CaptureTransactionKind.expense,
    accountCandidateId: 'acc-x',
    toAccountCandidateId: 'acc-y',
    categoryCandidateId: 'cat-x',
    tagCandidateIds: const <String>['t1', 't2'],
    confidence: CaptureConfidence.high,
    confidenceScore: 0.96,
    status: CaptureStatus.autoPosted,
    linkedEntryId: 'entry-full',
    duplicateEntryId: 'entry-min',
    appliedRuleIds: const <String>['capture-rule-1'],
    aiAssisted: true,
    failureReason: '非默认测试值',
    processedAt: DateTime(2026, 8, 13, 12, 30, 1, 456),
  );

  const captureRule = AutoCaptureRule(
    id: 'capture-rule-1',
    bookId: 'book-x',
    name: '麦当劳早餐',
    priority: 88,
    enabled: false,
    sourceKind: CaptureSourceKind.notification,
    sourceId: 'com.example.bank',
    textContains: '麦当劳',
    cardLast4: '4185',
    exactAmount: 59.49,
    matchKind: CaptureTransactionKind.expense,
    setKind: CaptureTransactionKind.expense,
    setAccountId: 'acc-x',
    setToAccountId: 'acc-y',
    setCategoryId: 'cat-x',
    setTagIds: <String>['t1', 't2'],
    setMerchant: '麦当劳',
  );

  /// 经真实 jsonEncode/jsonDecode 走一圈再 fromJson：既验证映射互逆，也验证
  /// toJson 产物真的可被 JSON 编码（残留 DateTime 等原始对象会在这里炸）。
  Map<String, Object?> jsonRoundTrip(Map<String, Object?> json) {
    return jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  }

  group('JSON 往返（备份导出→导入）', () {
    test('LedgerEntry 全字段与全空字段', () {
      for (final entry in <LedgerEntry>[entryFull, entryMinimal]) {
        final restored = LedgerEntry.fromJson(jsonRoundTrip(entry.toJson()));
        expect(restored.toJson(), entry.toJson());
      }
    });

    test('LedgerBook', () {
      final restored = LedgerBook.fromJson(jsonRoundTrip(book.toJson()));
      expect(restored.toJson(), book.toJson());
    });

    test('Account', () {
      final restored = Account.fromJson(jsonRoundTrip(accountFull.toJson()));
      expect(restored.toJson(), accountFull.toJson());
    });

    test('AccountGroup', () {
      final restored = AccountGroup.fromJson(
        jsonRoundTrip(accountGroup.toJson()),
      );
      expect(restored.toJson(), accountGroup.toJson());
    });

    test('CreditAccount', () {
      final restored = CreditAccount.fromJson(
        jsonRoundTrip(creditAccount.toJson()),
      );
      expect(restored.toJson(), creditAccount.toJson());
    });

    test('AccountGroup 忽略旧备份的图标字段', () {
      final restored = AccountGroup.fromJson(<String, Object?>{
        ...accountGroup.toJson(),
        'iconCode': 'wallet',
      });
      expect(restored.toJson(), accountGroup.toJson());
      expect(restored.toJson(), isNot(contains('iconCode')));
    });

    test('Category 子分类与顶级分类', () {
      for (final category in <Category>[categoryChild, categoryRoot]) {
        final restored = Category.fromJson(jsonRoundTrip(category.toJson()));
        expect(restored.toJson(), category.toJson());
      }
    });

    test('Tag', () {
      final restored = Tag.fromJson(jsonRoundTrip(tag.toJson()));
      expect(restored.toJson(), tag.toJson());
      expect(
        Tag.fromJson(<String, Object?>{
          'id': 'legacy',
          'label': '场景:返乡途中',
        }).groupId,
        'scene',
      );
      expect(
        TagGroup.fromJson(jsonRoundTrip(tagGroup.toJson())).toJson(),
        tagGroup.toJson(),
      );
    });

    test('Project 与 TagTemplate', () {
      expect(
        Project.fromJson(jsonRoundTrip(project.toJson())).toJson(),
        project.toJson(),
      );
      expect(
        TagTemplate.fromJson(jsonRoundTrip(tagTemplate.toJson())).toJson(),
        tagTemplate.toJson(),
      );
    });

    test('Attachment', () {
      final restored = Attachment.fromJson(jsonRoundTrip(attachment.toJson()));
      expect(restored.toJson(), attachment.toJson());
    });

    test('RecurringRule', () {
      final restored = RecurringRule.fromJson(jsonRoundTrip(rule.toJson()));
      expect(restored.toJson(), rule.toJson());
    });

    test('ExchangeRate', () {
      final restored = ExchangeRate.fromJson(
        jsonRoundTrip(exchangeRate.toJson()),
      );
      expect(restored.toJson(), exchangeRate.toJson());
    });

    test('余额锚点、正式账单与还款分配', () {
      final restoredAnchor = BalanceAnchor.fromJson(
        jsonRoundTrip(balanceAnchor.toJson()),
      );
      final restoredStatement = BillingStatement.fromJson(
        jsonRoundTrip(billingStatement.toJson()),
      );
      final restoredAllocation = StatementRepaymentAllocation.fromJson(
        jsonRoundTrip(allocation.toJson()),
      );
      expect(restoredAnchor.toJson(), balanceAnchor.toJson());
      expect(restoredStatement.toJson(), billingStatement.toJson());
      expect(restoredAllocation.toJson(), allocation.toJson());
    });

    test('自动采集事件与规则', () {
      final restoredEvent = CaptureEvent.fromJson(
        jsonRoundTrip(captureEvent.toJson()),
      );
      final restoredRule = AutoCaptureRule.fromJson(
        jsonRoundTrip(captureRule.toJson()),
      );
      expect(restoredEvent.toJson(), captureEvent.toJson());
      expect(restoredRule.toJson(), captureRule.toJson());
    });

    test('UserProfile', () {
      const profile = UserProfile(
        nickname: '测试昵称',
        bio: '测试简介',
        avatarDataUrl: 'data:image/png;base64,QUJD',
        gender: ProfileGender.female,
        birthday: '1990-01-02',
        city: '上海',
        occupation: '工程师',
      );
      final restored = UserProfile.fromJson(jsonRoundTrip(profile.toJson()));
      expect(restored.toJson(), profile.toJson());
    });

    test('PagePanelSetting', () {
      const setting = PagePanelSetting(id: 'trend', enabled: false);
      final restored = PagePanelSetting.fromJson(
        jsonRoundTrip(setting.toJson()),
      );
      expect(restored.toJson(), setting.toJson());
    });
  });

  group('SQLite 往返（落库→载入）', () {
    final opened = <AppDatabase>[];
    tearDown(() async {
      for (final db in opened) {
        await db.close();
      }
      opened.clear();
    });

    Future<LedgerRepository> openRepo() async {
      final db = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      opened.add(db);
      return SqliteLedgerRepository(db);
    }

    test('全部账目类模型经数据库往返后 toJson 不变', () async {
      final repo = await openRepo();
      await repo.saveEntries(<LedgerEntry>[entryFull, entryMinimal]);
      await repo.saveBooks(<LedgerBook>[book]);
      await repo.saveAccounts(<Account>[accountFull]);
      await repo.saveAccountGroups(<AccountGroup>[accountGroup]);
      await repo.saveCreditAccounts(<CreditAccount>[creditAccount]);
      await repo.saveCategories(<Category>[categoryChild, categoryRoot]);
      await repo.saveTags(<Tag>[tag]);
      await repo.saveTagGroups(<TagGroup>[...defaultTagGroups, tagGroup]);
      await repo.saveProjects(<Project>[project]);
      await repo.saveTagTemplates(<TagTemplate>[tagTemplate]);
      await repo.saveAttachments(<Attachment>[attachment]);
      await repo.saveRecurringRules(<RecurringRule>[rule]);
      await repo.saveExchangeRates(<ExchangeRate>[exchangeRate]);
      await repo.saveBalanceAnchors(<BalanceAnchor>[balanceAnchor]);
      await repo.saveBillingStatements(<BillingStatement>[billingStatement]);
      await repo.saveStatementRepaymentAllocations(
        <StatementRepaymentAllocation>[allocation],
      );
      await repo.saveCaptureEvents(<CaptureEvent>[captureEvent]);
      await repo.saveAutoCaptureRules(<AutoCaptureRule>[captureRule]);

      final entries = await repo.loadEntries();
      expect(
        entries.singleWhere((e) => e.id == entryFull.id).toJson(),
        entryFull.toJson(),
      );
      expect(
        entries.singleWhere((e) => e.id == entryMinimal.id).toJson(),
        entryMinimal.toJson(),
      );
      expect((await repo.loadBooks()).single.toJson(), book.toJson());
      expect((await repo.loadAccounts()).single.toJson(), accountFull.toJson());
      expect(
        (await repo.loadAccountGroups()).single.toJson(),
        accountGroup.toJson(),
      );
      expect(
        (await repo.loadCreditAccounts()).single.toJson(),
        creditAccount.toJson(),
      );
      final categories = await repo.loadCategories();
      expect(
        categories.singleWhere((c) => c.id == categoryChild.id).toJson(),
        categoryChild.toJson(),
      );
      expect(
        categories.singleWhere((c) => c.id == categoryRoot.id).toJson(),
        categoryRoot.toJson(),
      );
      expect((await repo.loadTags()).single.toJson(), tag.toJson());
      expect((await repo.loadTagGroups()).last.toJson(), tagGroup.toJson());
      expect((await repo.loadProjects()).single.toJson(), project.toJson());
      expect(
        (await repo.loadTagTemplates()).single.toJson(),
        tagTemplate.toJson(),
      );
      expect(
        (await repo.loadAttachments()).single.toJson(),
        attachment.toJson(),
      );
      expect((await repo.loadRecurringRules()).single.toJson(), rule.toJson());
      expect(
        (await repo.loadExchangeRates()).single.toJson(),
        exchangeRate.toJson(),
      );
      expect(
        (await repo.loadBalanceAnchors()).single.toJson(),
        balanceAnchor.toJson(),
      );
      expect(
        (await repo.loadBillingStatements()).single.toJson(),
        billingStatement.toJson(),
      );
      expect(
        (await repo.loadStatementRepaymentAllocations()).single.toJson(),
        allocation.toJson(),
      );
      expect(
        (await repo.loadCaptureEvents()).single.toJson(),
        captureEvent.toJson(),
      );
      expect(
        (await repo.loadAutoCaptureRules()).single.toJson(),
        captureRule.toJson(),
      );
    });
  });
}

/// v13 旧修订算法对下方固定事实计算的 SHA-256，不能随新模型的序列化结果重新生成。
const _legacyV13Revision =
    'fb2f64fb31c2bf99a86b56b68a777d1e4d425598a1513a1eae1da8f2fe0972aa';

/// 返回冻结的 v13 基金聚合；无参数，不读取当前模板或调用新模型 toJson。
/// 缺少 v14 的申购列表与事件附属字段，保留原事件、纯日期价格依据和历史修订摘要。
/// 测试必须同时证明 JSON 形状与旧摘要未变，不能只在新版先生成摘要后再声称兼容。
Map<String, Object?> _legacyV13FundPortfolioJson() => {
  'accountId': 'legacy-fund-usd',
  'bookId': 'default',
  'currencyCode': 'USD',
  'openedAt': '2026-10-01T00:00:00.000Z',
  'openingCash': '1000',
  'includedEntryIds': <String>[],
  'securities': [
    {
      'symbol': 'HK0001039582',
      'name': '旧版基金',
      'market': 'hk',
      'currencyCode': 'USD',
      'type': 'fund',
    },
  ],
  'openingHoldings': [
    {
      'securityId': 'hk:fund:HK0001039582',
      'short': false,
      'quantity': '10',
      'cost': '100',
    },
  ],
  'events': [
    {
      'id': 'legacy-sell',
      'securityId': 'hk:fund:HK0001039582',
      'kind': 'sell',
      'occurredAt': '2026-10-02T02:00:00.000Z',
      'sequence': 1,
      'quantity': '1',
      'price': '11',
      'fee': '0',
      'note': '旧版固定夹具',
      'carriedCost': null,
      'short': false,
      'batchId': null,
      'marginAfter': null,
      'settlementConfirmed': false,
      'allowUncoveredAssignment': false,
    },
  ],
  'manualPrices': {'hk:fund:HK0001039582': '11'},
  'allowFinancing': false,
  'anchorIncludedIds': <String, Object?>{},
  'marketPriceIds': <String>[],
  'valuationSnapshots': [
    {
      'capturedAt': '2026-10-15T12:00:00.000Z',
      'revision': _legacyV13Revision,
      'baseCurrencyCode': 'CNY',
      'prices': {
        'hk:fund:HK0001039582': {
          'price': '11',
          'quotedAt': '2026-10-15T00:00:00.000Z',
          'source': '旧基金净值来源',
          'manual': false,
          'dateOnly': true,
        },
      },
      'rateToBase': 7.0,
      'rateDate': '2026-10-01T00:00:00.000Z',
    },
  ],
};
