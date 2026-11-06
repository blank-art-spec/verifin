import 'dart:convert';

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

/// 创建用户手填的基金身份；[market] 与 [currency] 由用例明确提供，不请求真实基金资料。
/// 虚构代码避免把测试值误当成线上产品，其他参数用于验证错误品种或同代码跨市场的隔离。
StockSecurity _manualFund({
  required StockMarket market,
  required String currency,
  String symbol = 'MANUAL-FUND',
  InvestmentSecurityType type = InvestmentSecurityType.fund,
}) => StockSecurity(
  symbol: symbol,
  name: '手工货币基金测试',
  market: market,
  currencyCode: currency,
  type: type,
);

/// 构造实际已扣款的申请；[security] 决定真实基金身份，所有日期均为固定历史夹具。
/// 金额与份额不从收益率反推，实际付款后仍须另一条确认命令才能取得份额。
FundSubscription _paidOrder(StockSecurity security) => FundSubscription(
  id: 'manual-paid-order',
  securityId: security.id,
  requestedAt: DateTime.utc(2025, 1, 5, 2),
  paidAt: DateTime.utc(2025, 1, 5, 3),
  cashAmount: '200',
);

/// 构造券商实际确认；[rule] 可切换成不适用的 CMS 专属规则，验证不会按名称扩大适用范围。
/// 净值为离线固定每份 1 元，既非万份收益也非七日年化，实际份额直接取确认回执的 200 份。
FundSubscriptionConfirmation _confirmation({
  FundAccrualRule rule = FundAccrualRule.explicitStartDate,
}) => FundSubscriptionConfirmation(
  confirmedAt: DateTime.utc(2025, 1, 7, 2),
  navDate: DateTime.utc(2025, 1, 5),
  earningStartDate: DateTime.utc(
    2025,
    1,
    rule == FundAccrualRule.dealNavDate ? 5 : 6,
  ),
  nav: '1',
  quantity: '200',
  accrualRule: rule,
);

/// 验证新增基金身份的金额流程、UTC+8 生效边界、SQLite 冷读及完整备份恢复。
/// 本文件仅使用本机临时数据库及固定金额，不访问网络或运行 Android 构建。
void main() {
  setUpAll(sqfliteFfiInit);
  final databases = <AppDatabase>[];
  tearDown(() async {
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
  });

  /// 打开当前用例的真实 SQLite 内存库；数据库在用例结束后关闭，避免跨用例复用数据。
  Future<LedgerRepository> openRepository() async {
    final database = await AppDatabase.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    databases.add(database);
    return SqliteLedgerRepository(database);
  }

  test('金额流程只开放香港及内地真实基金，不扩大 CMS 专属成交日规则', () {
    for (final market in [StockMarket.hk, StockMarket.cn]) {
      final fund = _manualFund(market: market, currency: 'USD');
      expect(supportsFundAmountWorkflow(fund), isTrue);
      expect(supportsCmsDealNavAccrual(fund), isFalse);
      expect(
        supportsFundAmountWorkflow(
          _manualFund(
            market: market,
            currency: 'USD',
            type: InvestmentSecurityType.stock,
          ),
        ),
        isFalse,
      );
    }
    expect(
      supportsFundAmountWorkflow(
        _manualFund(market: StockMarket.us, currency: 'USD'),
      ),
      isFalse,
    );
    expect(
      supportsCmsDealNavAccrual(
        _manualFund(
          market: StockMarket.cn,
          currency: 'USD',
          symbol: 'HK0001039582',
        ),
      ),
      isFalse,
    );
  });

  for (final (market, currency) in [
    (StockMarket.cn, 'CNY'),
    (StockMarket.hk, 'USD'),
  ]) {
    test('${market.name} 手工基金基准与申购经 SQLite 冷读和备份恢复保留', () async {
      final repository = await openRepository();
      final store = LocalKeyValueStore();
      var controller = await VeriFinController.create(
        store,
        repository: repository,
      );
      var controllerAlive = true;
      try {
        final account = investmentAccountFixture(
          id: 'manual-fund-${market.name}',
          currency: currency,
          bookId: controller.activeBook.id,
        );
        final security = _manualFund(market: market, currency: currency);
        controller.addAccount(account);
        await controller.waitForPendingWrites();
        expect(
          await controller.enableInvestment(
            accountId: account.id,
            openingCash: '5000',
            openedAt: DateTime.utc(2025, 1, 1),
          ),
          isTrue,
        );
        expect(controller.investmentFor(account.id)!.securities, isEmpty);
        expect(
          await controller.saveFundHoldingBaseline(
            accountId: account.id,
            security: security,
            event: StockEvent(
              id: 'manual-baseline',
              securityId: security.id,
              kind: StockEventKind.fundHoldingBaseline,
              occurredAt: DateTime.utc(2025, 1, 4, 2),
              sequence: 1,
              quantity: '1000',
              price: '1',
              carriedCost: '1000',
              fundNavDate: DateTime.utc(2025, 1, 4),
            ),
            referencePrice: '1',
          ),
          isTrue,
        );
        // 已有持仓仅核对数量和成本，不虚构另一笔现金扣款或自动分红。
        expect(controller.accountBalance(account), 5000);
        expect(
          await controller.saveFundSubscription(
            accountId: account.id,
            security: security,
            subscription: _paidOrder(security),
          ),
          isTrue,
        );
        expect(controller.accountBalance(account), 4800);
        expect(
          await controller.confirmFundSubscription(
            accountId: account.id,
            subscriptionId: 'manual-paid-order',
            confirmation: _confirmation(),
          ),
          isTrue,
        );
        final saved = controller.investmentFor(account.id)!;
        final start = DateTime.utc(2025, 1, 5, 16);
        final before = DateTime.utc(2025, 1, 5, 15, 59, 59);
        expect(
          saved.events
              .singleWhere((event) => event.kind == StockEventKind.fundAcquire)
              .occurredAt,
          start,
        );
        expect(
          projectStocks(saved, at: before).positions.single.quantity.toString(),
          '1000',
        );
        expect(
          projectStocks(saved, at: start).positions.single.quantity.toString(),
          '1200',
        );
        expect(
          fundSubscriptionPendingValue(saved, at: before).toString(),
          '200',
        );
        expect(fundSubscriptionPendingValue(saved, at: start).toString(), '0');
        expect(projectStocks(saved).income.toString(), '0');
        expect(saved.manualPrices, {security.id: '1'});
        expect(controller.accountBalance(account), 4800);
        expect(controller.entries, isEmpty);
        final originalJson = saved.toJson();
        expect(
          (await repository.loadInvestmentPortfolios()).single.toJson(),
          originalJson,
        );
        controller.dispose();
        controllerAlive = false;
        controller = await VeriFinController.create(
          store,
          repository: repository,
        );
        controllerAlive = true;
        expect(controller.investmentFor(account.id)!.toJson(), originalJson);
        final backup = controller.exportDataJson();
        expect((jsonDecode(backup) as Map)['version'], 17);
        controller.importDataJson(backup, dryRun: true);
        await controller.waitForPendingWrites();
        expect(controller.investmentFor(account.id)!.toJson(), originalJson);
        controller.resetAllData();
        await controller.waitForPendingWrites();
        controller.importDataJson(backup);
        await controller.waitForPendingWrites();
        expect(controller.investmentFor(account.id)!.toJson(), originalJson);
        expect(
          (await repository.loadInvestmentPortfolios()).single.toJson(),
          originalJson,
        );
        expect(controller.accountBalance(account), 4800);
        expect(controller.entries, isEmpty);
      } finally {
        // 重建控制器失败时不得再次 dispose 旧实例，以免覆盖真正的持久化错误。
        if (controllerAlive) controller.dispose();
      }
    });
  }

  test('手工基金拒绝跨币种、股票及美国市场，非 CMS 确认不借用成交日规则', () async {
    final repository = await openRepository();
    final controller = await VeriFinController.create(
      LocalKeyValueStore(),
      repository: repository,
    );
    addTearDown(controller.dispose);
    final account = investmentAccountFixture(id: 'manual-fund-rejections');
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '5000',
        openedAt: DateTime.utc(2025, 1, 1),
      ),
      isTrue,
    );
    final originalJson = controller.investmentFor(account.id)!.toJson();
    for (final invalid in [
      _manualFund(market: StockMarket.hk, currency: 'HKD'),
      _manualFund(market: StockMarket.cn, currency: 'CNY'),
      _manualFund(market: StockMarket.us, currency: 'USD'),
      _manualFund(
        market: StockMarket.hk,
        currency: 'USD',
        type: InvestmentSecurityType.stock,
      ),
    ]) {
      expect(
        await controller.saveFundSubscription(
          accountId: account.id,
          security: invalid,
          subscription: _paidOrder(invalid),
        ),
        isFalse,
      );
      expect(controller.investmentFor(account.id)!.toJson(), originalJson);
      expect(
        (await repository.loadInvestmentPortfolios()).single.toJson(),
        originalJson,
      );
    }
    final manual = _manualFund(market: StockMarket.hk, currency: 'USD');
    expect(
      await controller.saveFundSubscription(
        accountId: account.id,
        security: manual,
        subscription: _paidOrder(manual),
      ),
      isTrue,
    );
    final beforeConfirmation = controller.investmentFor(account.id)!.toJson();
    expect(
      await controller.confirmFundSubscription(
        accountId: account.id,
        subscriptionId: 'manual-paid-order',
        confirmation: _confirmation(rule: FundAccrualRule.dealNavDate),
      ),
      isFalse,
    );
    expect(controller.investmentFor(account.id)!.toJson(), beforeConfirmation);
    expect(
      (await repository.loadInvestmentPortfolios()).single.toJson(),
      beforeConfirmation,
    );
    expect(controller.accountBalance(account), 4800);
    expect(controller.entries, isEmpty);
  });
}
