import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';

/// 核对可导入模板中的三地证券父子账户、股票及腾讯认购/认沽固定组合。
///
/// [controller] 必须已通过正式导入或 SQLite 冷启动载入模板；本方法临时切换到
/// 日常账本与投资账本，检查它们的账户、汇率和持仓互不串用，结束时恢复调用前的
/// 活动账本。所有价格和金额均为虚构验收输入，不表示历史成交或真实行情。
///
/// 该检查由内存导入、导出后恢复和 SQLite 重读用例共用，保证三条读取路径面对
/// 相同业务预期：总账户只聚合，各市场证券只在对应结算币种子账户中记仓位与资金。
void expectSampleInvestmentPortfolio(VeriFinController controller) {
  final originalBookId = controller.activeBook.id;
  try {
    // 日常账本仍使用原样例汇率；投资账本自己的测试汇率不能覆盖它。
    controller.switchLedgerBook(defaultLedgerBookId);
    expect(controller.exchangeRates, hasLength(1));
    expect(controller.exchangeRates.single.currencyCode, 'USD');
    expect(controller.exchangeRates.single.rateToBase, 7.2);
    expect(
      controller.accountParents.map((parent) => parent.id),
      isNot(contains('parent_investment')),
    );
    expect(controller.investmentFor('acc_investment_usd'), isNull);

    controller.switchLedgerBook('book_investment');
    expect(controller.activeBook.id, 'book_investment');
    expect(controller.activeBook.baseCurrencyCode, 'CNY');
    final parent = controller.accountParents.single;
    expect(parent.id, 'parent_investment');
    expect(parent.name, '投资账户');
    expect(parent.currencyCode, 'CNY');
    expect(controller.creditAccounts, isEmpty);
    expect(
      controller.accountParentsForType(AccountType.investment).single.id,
      parent.id,
    );

    final children = controller.accountsForParent(parent.id);
    expect(
      children.map((account) => account.id),
      unorderedEquals([
        'acc_investment_cny',
        'acc_investment_usd',
        'acc_investment_hkd',
      ]),
    );
    expect(
      controller.accounts.map((account) => account.id),
      unorderedEquals(children.map((account) => account.id)),
    );
    expect(
      children.map((account) => account.currencyCode),
      unorderedEquals(['CNY', 'USD', 'HKD']),
    );
    for (final child in children) {
      expect(child.type, AccountType.investment);
      expect(child.bookId, 'book_investment');
      expect(child.creditAccountId, parent.id);
      expect(controller.parentForAccount(child)?.id, parent.id);
    }

    // 三个币种各持有一份证券聚合；父账户只汇总，不另外保存现金或持仓。
    expect(controller.investmentFor(parent.id), isNull);
    for (final child in children) {
      final childPortfolio = controller.investmentFor(child.id)!;
      expect(childPortfolio.currencyCode, child.currencyCode);
      expect(childPortfolio.bookId, child.bookId);
      expect(childPortfolio.openingHoldings, isEmpty);
      expect(childPortfolio.includedEntryIds, isEmpty);
      expect(childPortfolio.marketPriceIds, isEmpty);
      expect(childPortfolio.allowFinancing, isFalse);
      expect(
        childPortfolio.securities.every(
          (security) => security.currencyCode == child.currencyCode,
        ),
        isTrue,
      );
    }
    final usd = children.singleWhere(
      (account) => account.currencyCode == 'USD',
    );
    final portfolio = controller.investmentFor(usd.id)!;
    expect(portfolio.accountId, usd.id);
    expect(portfolio.bookId, 'book_investment');
    expect(portfolio.currencyCode, 'USD');
    expect(portfolio.openingCash, '10000');
    expect(portfolio.openingHoldings, isEmpty);
    expect(portfolio.marketPriceIds, isEmpty);
    expect(portfolio.allowFinancing, isFalse);
    expect(
      portfolio.securities.map((security) => security.id),
      unorderedEquals(['us:stock:AVGO', 'us:stock:GOOG']),
    );
    expect(portfolio.manualPrices, {
      'us:stock:AVGO': '330',
      'us:stock:GOOG': '110',
    });
    expect(
      {for (final event in portfolio.events) event.id: event.sequence},
      {
        'test_avgo_buy': 1,
        'test_avgo_sell': 2,
        'test_goog_buy': 3,
        'test_goog_sell': 4,
      },
    );
    // 股票成交只保存为投资事件，不能重复进入普通收支或额外生成一笔入金。
    expect(controller.entries, isEmpty);

    final projection = controller.investmentProjection(usd.id)!;
    expect(projection.positions, hasLength(2));
    expect(projection.realizedComplete, isTrue);
    expect(projection.realized.toDouble(), 157.2);
    final valuation = valueStocks(portfolio, projection);
    expect(valuation.marketValue?.toDouble(), 2640);
    expect(valuation.unrealized?.toDouble(), 238.8);

    // 各标的分别校验剩余成本和盈亏，避免合计正确却把两只股票的成本串用。
    const expected = {
      'us:stock:AVGO': (
        cost: 1800.6,
        value: 1980.0,
        realized: 118.6,
        unrealized: 179.4,
      ),
      'us:stock:GOOG': (
        cost: 600.6,
        value: 660.0,
        realized: 38.6,
        unrealized: 59.4,
      ),
    };
    for (final item in expected.entries) {
      final position = projection.positions.singleWhere(
        (position) => position.securityId == item.key,
      );
      expect(position.short, isFalse);
      expect(position.quantity.toString(), '6');
      expect(position.cost?.toDouble(), item.value.cost);
      final isolated = portfolio.copyWith(
        securities: portfolio.securities
            .where((security) => security.id == item.key)
            .toList(),
        events: portfolio.events
            .where((event) => event.securityId == item.key)
            .toList(),
        // 独立重放单只股票时，参考价也只保留该标的，避免产生悬空证券引用。
        manualPrices: {item.key: portfolio.manualPrices[item.key]!},
      );
      final isolatedProjection = projectStocks(isolated);
      final isolatedValue = valueStocks(isolated, isolatedProjection);
      expect(isolatedProjection.realized.toDouble(), item.value.realized);
      expect(isolatedValue.marketValue?.toDouble(), item.value.value);
      expect(isolatedValue.unrealized?.toDouble(), item.value.unrealized);
    }

    expect(controller.accountBalance(usd), 7756);
    expect(controller.accountAssetValue(usd), 10396);
    _expectCoscoSample(controller);
    _expectTencentSample(controller);
    expect(controller.exchangeRates, hasLength(2));
    expect(
      {
        for (final rate in controller.exchangeRates)
          rate.currencyCode: rate.rateToBase,
      },
      {'USD': 7.0, 'HKD': 0.9},
    );
    final parentBalances = controller.parentAccountBalances(parent);
    expect(parentBalances.isComplete, isTrue);
    expect(parentBalances.completeTotal, 189910);
    // 父账户当前 API 只提供净值；资产页的正式汇总负责分别折算多头和空头。
    final ledgerBalances = controller.accountBalancesInBase();
    expect(ledgerBalances.isComplete, isTrue);
    expect(ledgerBalances.completeAssets, 190270);
    expect(ledgerBalances.completeLiabilities, 360);
    expect(ledgerBalances.completeTotal, 189910);
  } finally {
    // 即使某条断言失败，也恢复调用方账本，避免检查助手改变后续断言的读取范围。
    controller.switchLedgerBook(originalBookId);
  }
}

/// 核对中远海能 A 股的稳定身份、两笔成交、剩余成本及原币资金。
///
/// [controller] 必须已选中投资账本；只读取 CNY 子账户，确保 600026 不被误记为
/// 港股 01138，也不与其他币种共享期初现金。所有量价是明确的固定验收输入。
void _expectCoscoSample(VeriFinController controller) {
  final account = controller.accounts.singleWhere(
    (account) => account.id == 'acc_investment_cny',
  );
  final portfolio = controller.investmentFor(account.id)!;
  expect(portfolio.openingCash, '20000');
  final security = portfolio.securities.single;
  expect(security.id, 'cn:stock:600026');
  expect(security.name, '中远海能');
  expect(security.market, StockMarket.cn);
  expect(security.option, isNull);
  expect(portfolio.manualPrices, {'cn:stock:600026': '12'});
  expect(portfolio.events.map((event) => event.id), [
    'test_cosco_buy',
    'test_cosco_sell',
  ]);
  final projection = controller.investmentProjection(account.id)!;
  final position = projection.positions.single;
  expect(position.short, isFalse);
  expect(position.quantity.toString(), '600');
  expect(position.cost?.toDouble(), 6003);
  expect(projection.realizedComplete, isTrue);
  expect(projection.realized.toDouble(), 793);
  final valuation = valueStocks(portfolio, projection);
  expect(valuation.marketValue?.toDouble(), 7200);
  expect(valuation.unrealized?.toDouble(), 1197);
  expect(controller.accountBalance(account), 14790);
  expect(controller.accountAssetValue(account), 21990);
}

/// 核对腾讯港元股票及明确标为本地虚构的认购多头、认沽空头。
///
/// [controller] 必须已选中投资账本；合约的乘数、交割股数和行权现金分别校验，
/// 不能把张数当股数估值，也不能把冻结资金重复扣出现金或净值。这里只验证固定
/// 示例，不调用真实行情，不把 TEST 代码作为港交所真实挂牌合约。
void _expectTencentSample(VeriFinController controller) {
  final account = controller.accounts.singleWhere(
    (account) => account.id == 'acc_investment_hkd',
  );
  final portfolio = controller.investmentFor(account.id)!;
  expect(portfolio.openingCash, '100000');
  expect(portfolio.securities, hasLength(3));
  final stock = portfolio.securities.singleWhere(
    (security) => security.option == null,
  );
  expect(stock.id, 'hk:stock:00700');
  expect(stock.name, '腾讯控股');
  for (final security in portfolio.securities) {
    expect(security.market, StockMarket.hk);
    final option = security.option;
    if (option == null) continue;
    expect(security.symbol, startsWith('TEST-TCH-'));
    expect(option.underlyingId, stock.id);
    expect(option.expiry, '2026-12-30');
    expect(option.premiumMultiplier, '100');
    expect(option.deliverableShares, '100');
    expect(option.settlement, OptionSettlement.physical);
    expect(option.confirmed, isTrue);
    expect(option.specification, contains('本地虚构'));
    expect(option.specification, contains('美式'));
    expect(option.strike, option.right == OptionRight.call ? '440' : '380');
    expect(
      option.exerciseCash,
      option.right == OptionRight.call ? '44000' : '38000',
    );
  }
  const callId = 'hk:option:TEST-TCH-CALL-20261230-440';
  const putId = 'hk:option:TEST-TCH-PUT-20261230-380';
  expect(portfolio.manualPrices, {stock.id: '420', callId: '15', putId: '4'});
  expect(portfolio.events.map((event) => event.id), [
    'test_tencent_buy',
    'test_tencent_sell',
    'test_tencent_call_open',
    'test_tencent_call_close',
    'test_tencent_put_open',
    'test_tencent_put_close',
  ]);
  final projection = controller.investmentProjection(account.id)!;
  expect(projection.positions, hasLength(3));
  const expected = {
    'hk:stock:00700': (quantity: '100', cost: 40010.0, short: false),
    callId: (quantity: '1', cost: 1005.0, short: false),
    putId: (quantity: '1', cost: 795.0, short: true),
  };
  for (final item in expected.entries) {
    final position = projection.positions.singleWhere(
      (position) => position.securityId == item.key,
    );
    expect(position.quantity.toString(), item.value.quantity);
    expect(position.cost?.toDouble(), item.value.cost);
    expect(position.short, item.value.short);
  }
  expect(projection.realizedComplete, isTrue);
  expect(projection.realized.toDouble(), 2840);
  expect(projection.frozenMargin.toDouble(), 10000);
  final cash = controller.accountBalance(account);
  final valuation = valueInvestmentAccount(portfolio, cash);
  expect(cash, 62620);
  expect(cash - valuation.frozen, 52620);
  expect(valuation.longValue, 43500);
  expect(valuation.shortObligation, 400);
  expect(valuation.unrealized, 2880);
  expect(valuation.amounts?.assets, 106120);
  expect(valuation.amounts?.liabilities, 400);
  expect(controller.accountAssetValue(account), 105720);
  final assets = controller.accountAssetAmounts(account);
  expect(assets.assets, 106120);
  expect(assets.liabilities, 400);
}
