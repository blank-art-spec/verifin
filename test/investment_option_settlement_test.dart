import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/investments/stock_projection.dart';
import 'package:verifin/app/investments/stock_cash_math.dart';
import 'support/investment_fixture.dart';

/// 从同一权威投影核对现金、净值和已实现收益，避免只测某个内部算式。
void expectOptionTotals(
  InvestmentPortfolio p, {
  required double cash,
  required double net,
  required String realized,
}) {
  final result = projectStocks(p),
      amount = investmentCashBalance(portfolio: p, entries: []);
  expect(amount, cash);
  expect(amount + valueStocks(p, result).marketValue!.toDouble(), net);
  expect(result.realized.toString(), realized);
}

void main() {
  test('B04 两张认购部分平仓，权利金乘数及费用只计算一次', () {
    final s = optionFixture();
    final buy = optionEventFixture(
      s,
      StockEventKind.optionBuyOpen,
      quantity: '2',
      fee: '2',
    );
    var p = optionPortfolioFixture(s, events: [buy]);
    expectOptionTotals(p, cash: 9598, net: 10198, realized: '0');
    final close = optionEventFixture(
      s,
      StockEventKind.optionSellClose,
      id: 'close',
      price: '3',
      fee: '1',
      sequence: 2,
    );
    p = p.copyWith(events: [buy, close]);
    expectOptionTotals(p, cash: 9897, net: 10197, realized: '98');
    expect(projectStocks(p).positions.single.cost.toString(), '201');
    expect(valueStocks(p, projectStocks(p)).unrealized.toString(), '99');
  });

  test('B05 空头认沽、冻结及确认释放，保证金不重复扣净值', () {
    final s = optionFixture(right: OptionRight.put);
    final open = optionEventFixture(s, StockEventKind.optionSellOpen, fee: '1');
    final margin = optionEventFixture(
      s,
      StockEventKind.optionMargin,
      id: 'margin',
      sequence: 2,
      price: '0',
      quantity: '0',
      margin: '1000',
    );
    var p = optionPortfolioFixture(s, events: [open, margin], price: '1');
    expectOptionTotals(p, cash: 10199, net: 10099, realized: '0');
    expect(projectStocks(p).frozenMargin.toString(), '1000');
    final close = optionEventFixture(
      s,
      StockEventKind.optionBuyClose,
      id: 'close',
      sequence: 3,
      price: '1',
      fee: '1',
      margin: '0',
    );
    p = p.copyWith(events: [open, margin, close]);
    expectOptionTotals(p, cash: 10098, net: 10098, realized: '98');
    expect(projectStocks(p).frozenMargin.toString(), '0');
    expect(projectStocks(p).positions, isEmpty);
    p = p.copyWith(
      events: [
        open,
        margin,
        optionEventFixture(
          s,
          StockEventKind.optionBuyClose,
          id: 'close',
          sequence: 3,
          price: '1',
          fee: '1',
        ),
      ],
    );
    expect(projectStocks(p).frozenMargin.toString(), '1000');
  });

  test('A09 到期仍保留，明确确认后损益结转，缺价不清仓', () {
    final s = optionFixture();
    final open = optionEventFixture(s, StockEventKind.optionBuyOpen);
    final p = optionPortfolioFixture(s, events: [open]);
    expect(optionExpired(s.option!, DateTime(2027)), isTrue);
    expect(projectStocks(p).positions.single.quantity.toString(), '1');
    expect(
      valueStocks(p.copyWith(manualPrices: {}), projectStocks(p)).marketValue,
      isNull,
    );
    final expired = optionEventFixture(
      s,
      StockEventKind.optionExpire,
      id: 'expiry',
      sequence: 2,
      date: DateTime(2026, 12, 18),
      price: '0',
      settled: true,
    );
    expectOptionTotals(
      p.copyWith(events: [open, expired]),
      cash: 9800,
      net: 9800,
      realized: '-200',
    );
    expect(
      () => projectStocks(
        p.copyWith(
          events: [
            open,
            optionEventFixture(
              s,
              StockEventKind.optionExpire,
              id: 'bad',
              sequence: 2,
              price: '0',
              settled: true,
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => projectStocks(
        p.copyWith(
          events: [
            open,
            optionEventFixture(
              s,
              StockEventKind.optionExpire,
              id: 'bad',
              sequence: 2,
              date: DateTime(2027),
              price: '0',
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('A09 多空现金结算使用实际总额，不重复乘张数或乘数', () {
    for (final short in [false, true]) {
      final s = optionFixture(settlement: OptionSettlement.cash);
      final p = optionPortfolioFixture(
        s,
        events: [
          optionEventFixture(
            s,
            short
                ? StockEventKind.optionSellOpen
                : StockEventKind.optionBuyOpen,
          ),
          optionEventFixture(
            s,
            StockEventKind.optionCashSettle,
            id: 'settle',
            sequence: 2,
            short: short,
            price: '500',
            fee: '1',
            settled: true,
          ),
        ],
      );
      expectOptionTotals(
        p,
        cash: short ? 9699 : 10299,
        net: short ? 9699 : 10299,
        realized: short ? '-301' : '299',
      );
    }
  });

  for (final right in OptionRight.values) {
    for (final short in [false, true]) {
      test('A11 ${right.name} ${short ? "空头" : "多头"} 实物交割与权利金成本归集', () {
        final s = optionFixture(right: right);
        final sellStock =
            right == OptionRight.put && !short ||
            right == OptionRight.call && short;
        final p = optionPortfolioFixture(
          s,
          opening: sellStock
              ? [
                  StockHolding(
                    securityId: avgoFixture.id,
                    short: false,
                    quantity: '100',
                    cost: '4000',
                  ),
                ]
              : [],
          events: [
            optionEventFixture(
              s,
              short
                  ? StockEventKind.optionSellOpen
                  : StockEventKind.optionBuyOpen,
            ),
            optionEventFixture(
              s,
              StockEventKind.optionPhysicalSettle,
              id: 'deliver',
              sequence: 2,
              short: short,
              price: '0',
              settled: true,
            ),
          ],
        );
        final result = projectStocks(p);
        if (sellStock) {
          expectOptionTotals(
            p,
            cash: short ? 15200 : 14800,
            net: short ? 15200 : 14800,
            realized: short ? '1200' : '800',
          );
          expect(result.positions, isEmpty);
        } else {
          expectOptionTotals(
            p,
            cash: short ? 5200 : 4800,
            net: short ? 10200 : 9800,
            realized: '0',
          );
          expect(result.positions.single.securityId, avgoFixture.id);
          expect(result.positions.single.quantity.toString(), '100');
          expect(
            result.positions.single.cost.toString(),
            short ? '4800' : '5200',
          );
        }
      });
    }
  }

  test('A11 裸认购指派显式确认，部分覆盖股票后仅剩余部分形成空头', () {
    final s = optionFixture();
    final open = optionEventFixture(s, StockEventKind.optionSellOpen);
    final base = optionPortfolioFixture(
      s,
      opening: [
        StockHolding(
          securityId: avgoFixture.id,
          short: false,
          quantity: '40',
          cost: '1600',
        ),
      ],
    );
    final blocked = optionEventFixture(
      s,
      StockEventKind.optionPhysicalSettle,
      id: 'delivery',
      sequence: 2,
      short: true,
      price: '0',
      settled: true,
    );
    expect(
      () => projectStocks(base.copyWith(events: [open, blocked])),
      throwsFormatException,
    );
    final confirmed = optionEventFixture(
      s,
      StockEventKind.optionPhysicalSettle,
      id: 'delivery',
      sequence: 2,
      short: true,
      price: '0',
      settled: true,
      uncovered: true,
    );
    final p = base.copyWith(events: [open, confirmed]);
    expectOptionTotals(p, cash: 15200, net: 12200, realized: '480');
    final short = projectStocks(p).positions.single;
    expect(short.short, isTrue);
    expect(short.quantity.toString(), '60');
    expect(short.cost.toString(), '3120');
  });

  test('A11 调整合约乘数100、交割10股、行权现金5000保持独立', () {
    final s = optionFixture(shares: '10');
    final p = optionPortfolioFixture(
      s,
      events: [
        optionEventFixture(s, StockEventKind.optionBuyOpen),
        optionEventFixture(
          s,
          StockEventKind.optionPhysicalSettle,
          id: 'deliver',
          sequence: 2,
          price: '0',
          settled: true,
        ),
      ],
    );
    final result = projectStocks(p);
    expect(investmentCashBalance(portfolio: p, entries: []), 4800);
    expect(result.positions.single.quantity.toString(), '10');
    expect(result.positions.single.cost.toString(), '5200');
  });

  test('整数张数、方向隔离、未知成本、非标准交割与后续超平校验', () {
    final s = optionFixture();
    expect(
      () => projectStocks(
        optionPortfolioFixture(
          s,
          events: [
            optionEventFixture(
              s,
              StockEventKind.optionBuyOpen,
              quantity: '0.5',
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => projectStocks(
        optionPortfolioFixture(
          s,
          events: [
            optionEventFixture(s, StockEventKind.optionBuyOpen),
            optionEventFixture(
              s,
              StockEventKind.optionBuyClose,
              id: 'wrong',
              sequence: 2,
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    final unsupported = optionFixture(settlement: OptionSettlement.unsupported);
    final pending = optionPortfolioFixture(
      unsupported,
      events: [optionEventFixture(unsupported, StockEventKind.optionBuyOpen)],
    );
    expect(projectStocks(pending).positions, hasLength(1));
    expect(
      () => projectStocks(
        pending.copyWith(
          events: [
            ...pending.events,
            optionEventFixture(
              unsupported,
              StockEventKind.optionPhysicalSettle,
              id: 'bad',
              sequence: 2,
              price: '0',
              settled: true,
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
    final unknown = optionPortfolioFixture(
      s,
      opening: [StockHolding(securityId: s.id, short: false, quantity: '1')],
    );
    expect(valueStocks(unknown, projectStocks(unknown)).unrealized, isNull);
    expect(
      () => projectStocks(
        unknown.copyWith(
          events: [
            optionEventFixture(
              s,
              StockEventKind.optionPhysicalSettle,
              price: '0',
              settled: true,
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('多空同合约不抵销，非100及小数乘数和零保证金可往返', () {
    final s = optionFixture(multiplier: '12.5');
    final p = optionPortfolioFixture(
      s,
      events: [
        optionEventFixture(s, StockEventKind.optionBuyOpen),
        optionEventFixture(
          s,
          StockEventKind.optionSellOpen,
          id: 'short',
          sequence: 2,
        ),
      ],
    );
    expectOptionTotals(p, cash: 10000, net: 10000, realized: '0');
    expect(projectStocks(p).positions, hasLength(2));
  });
}
