import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';

/// 核对可导入模板中的两个证券父账户、六个币种子账户及各自独立的固定持仓。
///
/// [controller] 必须已通过正式导入或 SQLite 冷启动载入模板；本方法临时切换到
/// 日常账本与投资账本，检查它们的账户、汇率和持仓互不串用，结束时恢复调用前的
/// 活动账本。所有价格和金额均为虚构验收输入，不表示历史成交或真实行情。
///
/// 该检查由内存导入、导出后恢复和 SQLite 重读用例共用，保证三条读取路径面对
/// 相同业务预期：总账户只聚合，各市场证券只在对应结算币种子账户中记仓位与资金；
/// 两个 USD 子账户即使持有同一 GOOG，数量、成交成本及手填参考价也不互相合并；
/// 第二 USD 子账户另持有按份额计价的招商美元货币基金，不能把它恢复为港股。
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
    expect(controller.investmentFor('acc_investment_2_usd'), isNull);

    controller.switchLedgerBook('book_investment');
    expect(controller.activeBook.id, 'book_investment');
    expect(controller.activeBook.baseCurrencyCode, 'CNY');
    final parent = controller.accountParents.singleWhere(
      (parent) => parent.id == 'parent_investment',
    );
    expect(parent.id, 'parent_investment');
    expect(parent.name, '投资账户');
    expect(parent.currencyCode, 'CNY');
    expect(controller.creditAccounts, isEmpty);
    expect(
      controller.accountParentsForType(AccountType.investment).map((p) => p.id),
      unorderedEquals([parent.id, 'credit-account-acc_investment_2_cny']),
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
      unorderedEquals([
        ...children.map((account) => account.id),
        'acc_investment_2_cny',
        'acc_investment_2_usd',
        'acc_investment_2_hkd',
      ]),
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
    _expectSecondBrokerSample(controller);
    // 父账户当前 API 只提供净值；资产页的正式汇总负责分别折算多头和空头。
    final ledgerBalances = controller.accountBalancesInBase();
    expect(ledgerBalances.isComplete, isTrue);
    expect(ledgerBalances.completeAssets, 281108);
    expect(ledgerBalances.completeLiabilities, 360);
    expect(ledgerBalances.completeTotal, 280748);
  } finally {
    // 即使某条断言失败，也恢复调用方账本，避免检查助手改变后续断言的读取范围。
    controller.switchLedgerBook(originalBookId);
  }
}

/// 核对第二个证券主账户的三币种层级、独立 GOOG、美元货币基金及国电电力 A 股。
///
/// [controller] 必须已选择投资账本。量价均为固定验收输入：第二个 USD 子账户
/// 持有五股 GOOG 和十份招商美元货币基金，不能借用第一个 USD 子账户的六股、
/// 成本或 110 手填价；基金使用固定 100 买价及后备净值，仅改变现金/持仓构成。
/// CNY 子账户持有 600795，HKD 保留已启用但无资金、无持仓的空账户。
/// 本方法只读取聚合及正式估值接口，不修改手填价、触发联网或另外生成入金。
void _expectSecondBrokerSample(VeriFinController controller) {
  const parentId = 'credit-account-acc_investment_2_cny';
  final parent = controller.accountParents.singleWhere(
    (parent) => parent.id == parentId,
  );
  expect(controller.accountParents, hasLength(2));
  expect(parent.name, '投资账户二');
  expect(parent.currencyCode, 'CNY');
  expect(controller.investmentFor(parentId), isNull);
  final children = controller.accountsForParent(parentId);
  expect(
    children.map((account) => account.id),
    unorderedEquals([
      'acc_investment_2_cny',
      'acc_investment_2_usd',
      'acc_investment_2_hkd',
    ]),
  );
  expect(
    children.map((account) => account.currencyCode),
    unorderedEquals(['CNY', 'USD', 'HKD']),
  );
  for (final account in children) {
    expect(account.name, '投资账户二.${account.currencyCode}');
    expect(account.bookId, 'book_investment');
    expect(account.type, AccountType.investment);
    expect(account.initialBalance, 0);
    expect(account.creditAccountId, parentId);
    expect(controller.parentForAccount(account)?.id, parentId);
    final portfolio = controller.investmentFor(account.id)!;
    expect(portfolio.bookId, account.bookId);
    expect(portfolio.currencyCode, account.currencyCode);
    expect(portfolio.openedAt, DateTime(2026, 10, 1));
    expect(portfolio.openingHoldings, isEmpty);
    expect(portfolio.includedEntryIds, isEmpty);
    expect(portfolio.anchorIncludedIds, isEmpty);
    expect(portfolio.marketPriceIds, isEmpty);
    expect(portfolio.valuationSnapshots, isEmpty);
    expect(portfolio.allowFinancing, isFalse);
  }

  const expected = {
    'USD': (
      securityId: 'us:stock:GOOG',
      name: '谷歌',
      market: StockMarket.us,
      openingCash: '10000',
      eventId: 'test_second_goog_buy',
      day: 13,
      quantity: '5',
      price: '300',
      fee: '1',
      referencePrice: '310',
      cost: 1501.0,
      cash: 7499.0,
      value: 2550.0,
      unrealized: 49.0,
      netValue: 10049.0,
    ),
    'CNY': (
      securityId: 'cn:stock:600795',
      name: '国电电力',
      market: StockMarket.cn,
      openingCash: '20000',
      eventId: 'test_second_gdep_buy',
      day: 14,
      quantity: '1000',
      price: '5',
      fee: '5',
      referencePrice: '5.5',
      cost: 5005.0,
      cash: 14995.0,
      value: 5500.0,
      unrealized: 495.0,
      netValue: 20495.0,
    ),
  };
  for (final item in expected.entries) {
    final account = children.singleWhere(
      (account) => account.currencyCode == item.key,
    );
    final portfolio = controller.investmentFor(account.id)!;
    expect(portfolio.openingCash, item.value.openingCash);
    final security = portfolio.securities.singleWhere(
      (value) => value.id == item.value.securityId,
    );
    expect(security.id, item.value.securityId);
    expect(security.name, item.value.name);
    expect(security.market, item.value.market);
    expect(security.currencyCode, item.key);
    expect(security.option, isNull);
    expect(security.isStock, isTrue);
    expect(
      portfolio.securities.map((value) => value.id),
      unorderedEquals([
        security.id,
        if (item.key == 'USD') 'hk:fund:HK0001039582',
      ]),
    );
    expect(portfolio.manualPrices, {
      security.id: item.value.referencePrice,
      if (item.key == 'USD') 'hk:fund:HK0001039582': '100',
    });
    expect(portfolio.events, hasLength(item.key == 'USD' ? 2 : 1));
    final event = portfolio.events.singleWhere(
      (value) => value.id == item.value.eventId,
    );
    expect(event.id, item.value.eventId);
    expect(event.securityId, security.id);
    expect(event.kind, StockEventKind.buy);
    expect(event.occurredAt, DateTime(2026, 10, item.value.day, 10));
    expect(event.sequence, 1);
    expect(event.quantity, item.value.quantity);
    expect(event.price, item.value.price);
    expect(event.fee, item.value.fee);
    expect(event.note, contains('固定测试价格'));
    final projection = controller.investmentProjection(account.id)!;
    final position = projection.positions.singleWhere(
      (value) => value.securityId == security.id,
    );
    expect(position.short, isFalse);
    expect(position.quantity.toString(), item.value.quantity);
    expect(position.cost?.toDouble(), item.value.cost);
    expect(projection.realizedComplete, isTrue);
    expect(projection.realized.toDouble(), 0);
    expect(controller.accountBalance(account), item.value.cash);
    final valuation = valueInvestmentAccount(portfolio, item.value.cash);
    expect(valuation.longValue, item.value.value);
    expect(valuation.shortObligation, 0);
    expect(valuation.frozen, 0);
    expect(valuation.unrealized, item.value.unrealized);
    expect(controller.accountAssetValue(account), item.value.netValue);
  }

  _expectCmsFundSample(controller);

  final hkd = children.singleWhere((account) => account.currencyCode == 'HKD');
  final hkdPortfolio = controller.investmentFor(hkd.id)!;
  expect(hkdPortfolio.openingCash, '0');
  expect(hkdPortfolio.securities, isEmpty);
  expect(hkdPortfolio.events, isEmpty);
  expect(hkdPortfolio.manualPrices, isEmpty);
  expect(controller.investmentProjection(hkd.id)!.positions, isEmpty);
  expect(controller.accountBalance(hkd), 0);
  expect(controller.accountAssetValue(hkd), 0);
  final balances = controller.parentAccountBalances(parent);
  expect(balances.isComplete, isTrue);
  expect(balances.completeTotal, 90838);
}

/// 核对第二 USD 子账户中的基金身份、份额及稳定示例买入，禁止混用股票身份。
///
/// [controller] 已选择投资账本；样例的十份基金按固定 100 USD 买入并保留相同
/// 手填后备净值，因此成本和市值均为 1,000 USD，现金只减少一次且未实现盈亏为零。
/// 这里核对的是可恢复的本地测试事实，不把当前公开净值反写成历史成交或启用联网。
void _expectCmsFundSample(VeriFinController controller) {
  final portfolio = controller.investmentFor('acc_investment_2_usd')!;
  final security = portfolio.securities.singleWhere(
    (value) => value.id == 'hk:fund:HK0001039582',
  );
  expect(security.symbol, 'HK0001039582');
  expect(security.name, '招商美元货币市场基金 B类');
  expect(security.type, InvestmentSecurityType.fund);
  expect(security.isFund, isTrue);
  expect(security.isStock, isFalse);
  expect(security.market, StockMarket.hk);
  expect(security.currencyCode, 'USD');
  expect(security.option, isNull);
  final event = portfolio.events.singleWhere(
    (value) => value.id == 'test_second_cms_fund_buy',
  );
  expect(event.securityId, security.id);
  expect(event.kind, StockEventKind.buy);
  expect(event.occurredAt, DateTime(2026, 10, 15, 10));
  expect(event.sequence, 2);
  expect(event.quantity, '10');
  expect(event.price, '100');
  expect(event.fee, '0');
  expect(event.note, contains('固定测试价格'));
  expect(event.note, contains('不是真实成交或历史净值'));
  final position = controller
      .investmentProjection(portfolio.accountId)!
      .positions
      .singleWhere((value) => value.securityId == security.id);
  expect(position.short, isFalse);
  expect(position.quantity.toString(), '10');
  expect(position.cost?.toDouble(), 1000);
  expect(portfolio.manualPrices[security.id], '100');
  expect(portfolio.marketPriceIds, isEmpty);
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
