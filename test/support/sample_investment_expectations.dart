import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';

/// 核对可导入测试模板中的证券父子账户及 GOOG、AVGO 固定组合。
///
/// [controller] 必须已通过正式导入或 SQLite 冷启动载入模板；本方法临时切换到
/// 日常账本与投资账本，检查它们的账户、汇率和持仓互不串用，结束时恢复调用前的
/// 活动账本。所有价格和金额均为虚构验收输入，不表示历史成交或真实行情。
///
/// 该检查由内存导入、导出后恢复和 SQLite 重读用例共用，保证三条读取路径面对
/// 相同业务预期：总账户只聚合，两个股票只在 USD 子账户中记仓位与资金变动。
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

    // 只有 USD 启用持仓；其余币种保留零现金、零资产，父账户不另外创建投资聚合。
    expect(controller.investmentFor(parent.id), isNull);
    for (final child in children.where(
      (account) => account.currencyCode != 'USD',
    )) {
      expect(controller.investmentFor(child.id), isNull);
      expect(controller.accountBalance(child), 0);
      expect(controller.accountAssetValue(child), 0);
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
    expect(parentBalances.completeTotal, 72772);
  } finally {
    // 即使某条断言失败，也恢复调用方账本，避免检查助手改变后续断言的读取范围。
    controller.switchLedgerBook(originalBookId);
  }
}
