/// 只读证券重放：股票/基金份额及期权的数量、成本、现金腿与盈亏唯一计算入口。
library;

import '../currency_catalog.dart';
import '../models/investment.dart';
import '../models/option_contract.dart';
import 'investment_decimal.dart';
part 'option_projection.dart';

/// 单个证券方向的重放结果；成本未知时不制造零成本盈利。
class StockPosition {
  /// [securityId] 和 [short] 共同标识持仓方向，[cost] 为剩余总成本/净开仓所得。
  StockPosition(this.securityId, this.short, this.quantity, this.cost);
  final String securityId;
  final bool short;
  InvestmentDecimal quantity;
  InvestmentDecimal? cost;
}

/// 账户重放结果；现金腿按事件保存供现金锚点重算使用，持仓不受现金校准影响。
class StockProjection {
  /// 参数均为派生值，不应直接持久化为第二份可编辑账目。
  StockProjection({
    required this.positions,
    required this.cashMovements,
    required this.realized,
    required this.income,
    required this.realizedComplete,
    this.frozenMargins = const {},
    this.optionReviews = const {},
  });
  final List<StockPosition> positions;
  final Map<String, InvestmentDecimal> cashMovements;
  final InvestmentDecimal realized, income;
  final bool realizedComplete;
  final Map<String, InvestmentDecimal> frozenMargins;

  /// 标的发生拆股后，原期权交割资料需要重新处理，不自动按股票比例改合约。
  final Set<String> optionReviews;

  /// 合计已确认但尚未明确释放的现金冻结额；不从净值再次扣除。
  InvestmentDecimal get frozenMargin => frozenMargins.values.fold(
    InvestmentDecimal.zero,
    (sum, value) => sum + value,
  );
}

/// 按业务时间及稳定序号计算整个账户；非法事件、悬空证券或超量平仓直接抛错。
/// [portfolio] 为不可变用户事实；返回值不修改原始数据，便于保存前完整预览/验证。
/// [at] 指定基金申购确认/持仓基准的生效截点，默认当前时刻；未来起算的确认不能提前变成持仓。
/// 普通股票/期权沿用既有完整事件重放，历史调用仍应先截取 investmentAt 的全部证券事实。
StockProjection projectStocks(InvestmentPortfolio portfolio, {DateTime? at}) {
  final fundCutoff = at ?? DateTime.now();
  final digits = CurrencyCatalog.require(portfolio.currencyCode).minorUnit;
  final securities = {
    for (final security in portfolio.securities) security.id: security,
  };
  if (securities.length != portfolio.securities.length) {
    throw const FormatException('证券身份重复');
  }
  for (final security in securities.values) {
    if (security.symbol.isEmpty ||
        security.name.isEmpty ||
        security.currencyCode != portfolio.currencyCode ||
        (security.isFund && security.option != null)) {
      throw const FormatException('证券或结算币种不合法');
    }
    if (security.option != null) _validateOptionContract(security, securities);
  }
  final cash = <String, InvestmentDecimal>{};
  final positions = <String, StockPosition>{};
  var realized = InvestmentDecimal.zero, income = InvestmentDecimal.zero;
  var complete = true;
  final ids = <String>{};
  final sequences = <int>{};
  final margins = <String, InvestmentDecimal>{};
  final reviews = <String>{};

  // 相同证券的多空方向分别核算，不隐式抵销或穿越零仓位。
  StockPosition position(String id, bool short) => positions.putIfAbsent(
    '$id:$short',
    () => StockPosition(
      id,
      short,
      InvestmentDecimal.zero,
      InvestmentDecimal.zero,
    ),
  );

  for (final holding in portfolio.openingHoldings) {
    final quantity = InvestmentDecimal.parse(holding.quantity);
    final cost = holding.cost == null
        ? null
        : InvestmentDecimal.parse(holding.cost!);
    final key = '${holding.securityId}:${holding.short}';
    if (!securities.containsKey(holding.securityId) ||
        positions.containsKey(key) ||
        quantity.units <= BigInt.zero ||
        (securities[holding.securityId]!.isFund && holding.short) ||
        (cost != null && cost.units < BigInt.zero)) {
      throw const FormatException('期初持仓不合法');
    }
    if (securities[holding.securityId]!.option != null) {
      _requireOptionQuantity(quantity);
    }
    positions[key] = StockPosition(
      holding.securityId,
      holding.short,
      quantity,
      cost?.rounded(digits),
    );
  }
  final events = [...portfolio.events]..sort(compareStockEvents);
  for (final event in events) {
    if (!ids.add(event.id) ||
        !sequences.add(event.sequence) ||
        event.sequence < 0 ||
        event.id.isEmpty ||
        !securities.containsKey(event.securityId) ||
        event.occurredAt.isBefore(portfolio.openedAt)) {
      throw const FormatException('成交身份、顺序或期初边界不合法');
    }
    final q = InvestmentDecimal.parse(event.quantity),
        p = InvestmentDecimal.parse(event.price),
        fee = InvestmentDecimal.parse(event.fee);
    if (fee.units < BigInt.zero ||
        p.units < BigInt.zero ||
        q.units < BigInt.zero ||
        fee.compareTo(fee.rounded(digits)) != 0) {
      throw const FormatException('数量、报价或费用不合法');
    }
    final kind = event.kind;
    final security = securities[event.securityId]!;
    // 本阶段基金只复用明确的份额买卖、现金分红/费用及成本转移，不支持融券或拆股。
    if (security.isFund &&
        (event.short ||
            !const {
              StockEventKind.buy,
              StockEventKind.sell,
              StockEventKind.dividend,
              StockEventKind.fee,
              StockEventKind.transferIn,
              StockEventKind.transferOut,
              StockEventKind.fundAcquire,
              StockEventKind.fundHoldingBaseline,
            }.contains(kind))) {
      throw const FormatException('基金不能使用卖空、回补、拆股或期权动作');
    }
    if ((kind == StockEventKind.fundAcquire ||
            kind == StockEventKind.fundHoldingBaseline) &&
        (!security.isFund || event.short || event.batchId != null)) {
      throw const FormatException('基金确认或持仓基准的证券品种不合法');
    }
    if ((kind == StockEventKind.fundAcquire ||
            kind == StockEventKind.fundHoldingBaseline) &&
        event.occurredAt.isAfter(fundCutoff)) {
      // 已确认但未到逐笔收益起算日的资金仍是待生效资产；现金扣款由独立申购事实表达。
      cash[event.id] = InvestmentDecimal.zero;
      continue;
    }
    if (security.option != null) {
      final result = _applyOptionEvent(
        event,
        security,
        digits,
        position,
        margins,
        needsReview: reviews.contains(security.id),
      );
      cash[event.id] = result.cash;
      result.cash.toDouble();
      realized = realized + result.realized;
      complete = complete && result.complete;
      continue;
    }
    if (kind.isOptionEvent ||
        event.marginAfter != null ||
        event.settlementConfirmed ||
        event.allowUncoveredAssignment) {
      throw const FormatException('股票不能使用期权事件或结算字段');
    }
    if ({
          StockEventKind.split,
          StockEventKind.transferIn,
          StockEventKind.transferOut,
        }.contains(kind) &&
        fee.units != BigInt.zero) {
      throw const FormatException('拆股或持仓转移的费用请另记独立费用事件');
    }
    final trade = {
      StockEventKind.buy,
      StockEventKind.sell,
      StockEventKind.shortSell,
      StockEventKind.cover,
    }.contains(kind);
    if (trade && (q.units <= BigInt.zero || p.units <= BigInt.zero)) {
      throw const FormatException('成交数量和价格必须大于零');
    }
    var movement = InvestmentDecimal.zero;
    final short = trade
        ? kind == StockEventKind.shortSell || kind == StockEventKind.cover
        : event.short;
    final pos = position(event.securityId, short);
    final gross = q.moneyProduct(p, digits);
    switch (kind) {
      case StockEventKind.fundAcquire:
      case StockEventKind.fundHoldingBaseline:
        final cost = event.carriedCost == null
            ? null
            : InvestmentDecimal.parse(event.carriedCost!);
        if (q.units <= BigInt.zero ||
            p.units <= BigInt.zero ||
            fee.units != BigInt.zero ||
            cost == null ||
            cost.units < BigInt.zero ||
            cost.compareTo(cost.rounded(digits)) != 0 ||
            (kind == StockEventKind.fundAcquire &&
                event.fundSubscriptionId == null)) {
          throw const FormatException('基金确认份额、净值或实际总成本不合法');
        }
        if (kind == StockEventKind.fundHoldingBaseline ||
            pos.quantity.units == BigInt.zero) {
          pos.quantity = q;
          pos.cost = cost;
        } else {
          pos.quantity = pos.quantity + q;
          pos.cost = pos.cost == null ? null : pos.cost! + cost;
        }
      // 申购款已在实际扣款日减少现金；已有持仓基准也不应再次扣现金。
      case StockEventKind.buy:
      case StockEventKind.shortSell:
        movement = kind == StockEventKind.buy ? -gross - fee : gross - fee;
        if (kind == StockEventKind.shortSell && movement.units < BigInt.zero) {
          throw const FormatException('卖空费用超过开仓所得');
        }
        pos.quantity = pos.quantity + q;
        if (pos.cost != null) {
          pos.cost = pos.cost! + (short ? movement : -movement);
        }
      case StockEventKind.sell:
      case StockEventKind.cover:
      case StockEventKind.transferOut:
        if (q.units <= BigInt.zero || q.compareTo(pos.quantity) > 0) {
          throw const FormatException('平仓或转出数量超过持仓');
        }
        final released = pos.cost == null
            ? null
            : q.compareTo(pos.quantity) == 0
            ? pos.cost!
            : pos.cost!.allocated(q, pos.quantity, digits);
        if (kind == StockEventKind.transferOut) {
          if (event.batchId == null ||
              event.carriedCost != released?.toString()) {
            throw const FormatException('持仓转移成本或批次不一致');
          }
        } else {
          movement = kind == StockEventKind.sell ? gross - fee : -gross - fee;
          if (released == null) {
            complete = false;
          } else {
            realized =
                realized + (short ? released + movement : movement - released);
          }
        }
        pos.quantity = pos.quantity - q;
        pos.cost = released == null ? null : pos.cost! - released;
        if (pos.quantity.units == BigInt.zero) {
          pos.cost = InvestmentDecimal.zero;
        }
      case StockEventKind.dividend:
        movement = p.rounded(digits) - fee;
        income = income + movement;
      case StockEventKind.fee:
        movement = -p.rounded(digits) - fee;
        income = income + movement;
      case StockEventKind.split:
        for (final option in securities.values.where(
          (s) => s.option?.underlyingId == security.id,
        )) {
          if ([false, true].any(
            (side) => position(option.id, side).quantity.units > BigInt.zero,
          )) {
            reviews.add(option.id);
          }
        }
        // 同一股票的多空都随拆股调整，成本总额与现金不变。
        for (final direction in [false, true]) {
          final holding = position(event.securityId, direction);
          holding.quantity = holding.quantity.split(q, p);
        }
      case StockEventKind.transferIn:
        if (event.batchId == null || q.units <= BigInt.zero) {
          throw const FormatException('持仓转入批次不合法');
        }
        final cost = event.carriedCost == null
            ? null
            : InvestmentDecimal.parse(event.carriedCost!);
        if (cost != null && cost.units < BigInt.zero) {
          throw const FormatException('转入成本不能为负');
        }
        if (pos.quantity.units == BigInt.zero) {
          pos.cost = cost;
        } else {
          pos.cost = pos.cost == null || cost == null ? null : pos.cost! + cost;
        }
        pos.quantity = pos.quantity + q;
      case StockEventKind.optionBuyOpen:
      case StockEventKind.optionSellClose:
      case StockEventKind.optionSellOpen:
      case StockEventKind.optionBuyClose:
      case StockEventKind.optionExpire:
      case StockEventKind.optionCashSettle:
      case StockEventKind.optionPhysicalSettle:
      case StockEventKind.optionMargin:
        throw const FormatException('期权事件缺少合约');
    }
    movement.toDouble();
    cash[event.id] = movement;
  }
  for (final entry in portfolio.manualPrices.entries) {
    if (!securities.containsKey(entry.key) ||
        InvestmentDecimal.parse(entry.value).units < BigInt.zero) {
      throw const FormatException('参考价引用或数值不合法');
    }
  }
  return StockProjection(
    positions: positions.values
        .where((p) => p.quantity.units != BigInt.zero)
        .toList(),
    cashMovements: cash,
    realized: realized,
    income: income,
    realizedComplete: complete,
    frozenMargins: Map.unmodifiable(margins),
    optionReviews: Set.unmodifiable(reviews),
  );
}

/// 按业务时间再按稳定序号升序排列；重放和用户记录列表共用，补录不会打乱时间线。
int compareStockEvents(StockEvent a, StockEvent b) {
  final time = a.occurredAt.compareTo(b.occurredAt);
  return time != 0 ? time : a.sequence.compareTo(b.sequence);
}

/// 按手填参考价估算所有多空持仓；缺价返回 null，未知成本只影响盈亏完整性。
/// [projection] 是同一 [portfolio] 的重放结果，避免 UI 与资产汇总各写一套公式。
({InvestmentDecimal? marketValue, InvestmentDecimal? unrealized}) valueStocks(
  InvestmentPortfolio portfolio,
  StockProjection projection,
) {
  final digits = CurrencyCatalog.require(portfolio.currencyCode).minorUnit;
  var market = InvestmentDecimal.zero, unrealized = InvestmentDecimal.zero;
  var knownCost = true;
  for (final p in projection.positions) {
    final price = portfolio.manualPrices[p.securityId];
    if (price == null) return (marketValue: null, unrealized: null);
    final security = portfolio.securities.firstWhere(
      (s) => s.id == p.securityId,
    );
    final value = securityPositionValue(
      security,
      p.quantity,
      InvestmentDecimal.parse(price),
      digits,
    );
    market = market + (p.short ? -value : value);
    if (p.cost == null) {
      knownCost = false;
    } else {
      unrealized = unrealized + (p.short ? p.cost! - value : value - p.cost!);
    }
  }
  return (marketValue: market, unrealized: knownCost ? unrealized : null);
}

/// [quantity] 为股票股数或期权张数；期权先乘显式权利金乘数，再按原币现金精度舍入。
/// 持仓卡和账户估值共用本函数，禁止一处乘 100、另一处按股数计价。
InvestmentDecimal securityPositionValue(
  StockSecurity security,
  InvestmentDecimal quantity,
  InvestmentDecimal price,
  int digits,
) =>
    (security.option == null
            ? quantity
            : quantity.split(
                InvestmentDecimal.parse(security.option!.premiumMultiplier),
                InvestmentDecimal.parse('1'),
              ))
        .moneyProduct(price, digits);
