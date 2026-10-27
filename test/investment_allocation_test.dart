import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_valuation.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'package:verifin/app/models.dart';

import 'support/investment_fixture.dart';

/// 创建占比边界用的估值；[cash] 为真实现金，[longValue] 为多头市值，
/// [shortObligation] 为回补义务，[frozen] 只披露冻结额，不更改现金。
/// 成本字段固定为已知，便于单独检查缺价、非有限数及零分母，无持久化副作用。
InvestmentAccountValuation _valuation({
  double cash = 7756,
  double? longValue = 2640,
  double? shortObligation = 0,
  double frozen = 0,
}) => InvestmentAccountValuation(
  cash: cash,
  frozen: frozen,
  longValue: longValue,
  shortObligation: shortObligation,
  unrealized: 0,
  realized: 0,
  costComplete: true,
);

/// 注册证券资产占比的纯计算回归，无参数、无返回值；不联网、写库或连接设备。
void main() {
  test('真实测试模板：现金与双标的持仓按同一总资产计算', () {
    final root =
        jsonDecode(
              File('docs/dev/verifin-sample-backup.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final data = root['data'] as Map<String, dynamic>;
    final portfolio = InvestmentPortfolio.fromJson(
      Map<String, Object?>.from(
        (data['investmentPortfolios'] as List).singleWhere(
              (portfolio) =>
                  (portfolio as Map)['accountId'] == 'acc_investment_usd',
            )
            as Map,
      ),
    );
    final cash = investmentCashBalance(portfolio: portfolio, entries: []);
    final valuation = valueInvestmentAccount(portfolio, cash);

    expect(cash, 7756);
    expect(valuation.longValue, 2640);
    expect(valuation.amounts!.assets, 10396);
    expect(valuation.cashShare, closeTo(7756 / 10396, 1e-12));
    expect(valuation.holdingsShare, closeTo(2640 / 10396, 1e-12));
    expect(valuation.shortObligationShare, 0);
    expect(valuation.shareOfAssets(1980), closeTo(1980 / 10396, 1e-12));
    expect(valuation.shareOfAssets(660), closeTo(660 / 10396, 1e-12));
    expect(valuation.cashShare! + valuation.holdingsShare!, closeTo(1, 1e-12));
  });

  test('B07 股票与多空期权按总资产分配，空头义务不抵销分母', () {
    final call = optionFixture();
    final put = optionFixture(right: OptionRight.put);
    final portfolio = InvestmentPortfolio(
      accountId: 'stock-usd',
      bookId: defaultLedgerBookId,
      currencyCode: 'USD',
      openedAt: DateTime(2026, 10, 1),
      openingCash: '10000',
      securities: [avgoFixture, call, put],
      events: [
        stockEventFixture('stock', StockEventKind.buy, '10', '300', fee: '1'),
        optionEventFixture(
          call,
          StockEventKind.optionBuyOpen,
          id: 'call',
          fee: '1',
          sequence: 2,
        ),
        optionEventFixture(
          put,
          StockEventKind.optionSellOpen,
          id: 'put',
          fee: '1',
          sequence: 3,
          margin: '1000',
        ),
      ],
      manualPrices: {avgoFixture.id: '330', call.id: '3', put.id: '1'},
    );
    final cash = investmentCashBalance(portfolio: portfolio, entries: []);
    final valuation = valueInvestmentAccount(portfolio, cash);

    expect(cash, 6997);
    expect(valuation.longValue, 3600);
    expect(valuation.shortObligation, 100);
    expect(valuation.frozen, 1000);
    expect(valuation.amounts!.assets, 10597);
    expect(valuation.amounts!.net, 10497);
    expect(valuation.cashShare, closeTo(6997 / 10597, 1e-12));
    expect(valuation.holdingsShare, closeTo(3600 / 10597, 1e-12));
    expect(valuation.shortObligationShare, closeTo(100 / 10597, 1e-12));
    expect(valuation.shareOfAssets(3300), closeTo(3300 / 10597, 1e-12));
    expect(valuation.shareOfAssets(300), closeTo(300 / 10597, 1e-12));
    expect(valuation.cashShare! + valuation.holdingsShare!, closeTo(1, 1e-12));
  });

  test('期权持仓使用合约自己的权利金乘数，不固定乘一百', () {
    final option = optionFixture(
      multiplier: '10',
      shares: '10',
      exercise: '500',
    );
    final portfolio = optionPortfolioFixture(
      option,
      events: [
        optionEventFixture(option, StockEventKind.optionBuyOpen, quantity: '2'),
      ],
    );
    final cash = investmentCashBalance(portfolio: portfolio, entries: []);
    final valuation = valueInvestmentAccount(portfolio, cash);

    expect(cash, 9960);
    expect(valuation.longValue, 60);
    expect(valuation.amounts!.assets, 10020);
    expect(valuation.holdingsShare, closeTo(60 / 10020, 1e-12));
    expect(valuation.cashShare, closeTo(9960 / 10020, 1e-12));
  });

  test('冻结现金仍属于现金资产，不重复减少现金占比', () {
    final liquid = _valuation(cash: 1000, longValue: 1000);
    final frozen = _valuation(cash: 1000, longValue: 1000, frozen: 400);

    expect(frozen.cashShare, 0.5);
    expect(frozen.cashShare, liquid.cashShare);
    expect(frozen.holdingsShare, liquid.holdingsShare);
    expect(frozen.amounts!.assets, 2000);
  });

  test('负现金归融资负债，现金资产占比为零，持仓不会按净值放大', () {
    final valuation = _valuation(cash: -100, longValue: 330);

    expect(valuation.amounts!.assets, 330);
    expect(valuation.amounts!.liabilities, 100);
    expect(valuation.amounts!.net, 230);
    expect(valuation.cashShare, 0);
    expect(valuation.holdingsShare, 1);
    expect(valuation.shareOfAssets(330), 1);
  });

  test('空头义务可以超过总资产，比例保留风险且不截断', () {
    final valuation = _valuation(cash: 100, longValue: 0, shortObligation: 250);

    expect(valuation.cashShare, 1);
    expect(valuation.holdingsShare, 0);
    expect(valuation.shortObligationShare, 2.5);
    expect(valuation.shareOfAssets(250), 2.5);
    expect(valuation.amounts!.net, -150);
  });

  test('仅现金与仅持仓有明确的百分之百，零金额与负零保持零占比', () {
    final cashOnly = _valuation(cash: 500, longValue: 0);
    final holdingsOnly = _valuation(cash: 0, longValue: 500);

    expect(cashOnly.cashShare, 1);
    expect(cashOnly.holdingsShare, 0);
    expect(holdingsOnly.cashShare, 0);
    expect(holdingsOnly.holdingsShare, 1);
    expect(holdingsOnly.shareOfAssets(-0.0)!.isNegative, isFalse);
  });

  test('总资产为零或负数时不可计算，不把零分母显示成零占比', () {
    for (final valuation in [
      _valuation(cash: 0, longValue: 0),
      _valuation(cash: -100, longValue: 0),
      _valuation(cash: 0, longValue: -1),
    ]) {
      expect(valuation.cashShare, isNull);
      expect(valuation.holdingsShare, isNull);
      expect(valuation.shortObligationShare, isNull);
      expect(valuation.shareOfAssets(0), isNull);
    }
  });

  test('整体估值含 NaN 或正负无穷时不产生伪造占比', () {
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      for (final valuation in [
        _valuation(cash: invalid),
        _valuation(longValue: invalid),
        _valuation(shortObligation: invalid),
      ]) {
        expect(valuation.cashShare, isNull);
        expect(valuation.holdingsShare, isNull);
        expect(valuation.shortObligationShare, isNull);
        expect(valuation.shareOfAssets(1), isNull);
      }
    }
    // 单项数值有限也可能在合计时溢出；不能展示基于无穷总资产/总负债的分布。
    for (final valuation in [
      _valuation(cash: double.maxFinite, longValue: double.maxFinite),
      _valuation(
        cash: -double.maxFinite,
        longValue: 1,
        shortObligation: double.maxFinite,
      ),
    ]) {
      expect(valuation.cashShare, isNull);
      expect(valuation.holdingsShare, isNull);
      expect(valuation.shortObligationShare, isNull);
    }
  });

  test('负持仓市值或负空头义务使分布不可用，不借正现金掩盖非法输入', () {
    for (final valuation in [
      _valuation(longValue: -1),
      _valuation(shortObligation: -1),
    ]) {
      expect(valuation.cashShare, isNull);
      expect(valuation.holdingsShare, isNull);
      expect(valuation.shortObligationShare, isNull);
      expect(valuation.shareOfAssets(1), isNull);
    }
  });

  test('单项分子缺失、为负或非有限时不可计算，除法溢出也不返回无穷', () {
    final valuation = _valuation();
    for (final invalid in <double?>[
      null,
      -1,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(valuation.shareOfAssets(invalid), isNull);
    }
    expect(
      _valuation(
        cash: double.minPositive,
        longValue: 0,
      ).shareOfAssets(double.maxFinite),
      isNull,
    );
  });

  test('任一侧参考价缺失时分布整体不可用，不按已知部分计算占比', () {
    for (final valuation in [
      _valuation(longValue: null),
      _valuation(shortObligation: null),
    ]) {
      expect(valuation.cashShare, isNull);
      expect(valuation.holdingsShare, isNull);
      expect(valuation.shortObligationShare, isNull);
      expect(valuation.shareOfAssets(660), isNull);
    }
    final portfolio = portfolioFixture(
      opening: [
        StockHolding(securityId: avgoFixture.id, short: false, quantity: '1'),
      ],
    ).copyWith(manualPrices: {});
    expect(valueInvestmentAccount(portfolio, 100).cashShare, isNull);
  });

  test('成本未知只影响盈亏，不阻止按有效市值计算现金和持仓占比', () {
    final portfolio = portfolioFixture(
      opening: [
        StockHolding(securityId: avgoFixture.id, short: false, quantity: '1'),
      ],
    );
    final valuation = valueInvestmentAccount(portfolio, 670);

    expect(valuation.costComplete, isFalse);
    expect(valuation.unrealized, isNull);
    expect(valuation.amounts!.assets, 1000);
    expect(valuation.cashShare, 0.67);
    expect(valuation.holdingsShare, 0.33);
    expect(valuation.shareOfAssets(330), 0.33);
  });
}
