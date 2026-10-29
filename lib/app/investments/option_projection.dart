part of 'stock_projection.dart';

/// 校验合约及标的引用；未知交割可以保留，已确认的单股实物规格必须完整。
void _validateOptionContract(
  StockSecurity security,
  Map<String, StockSecurity> securities,
) {
  final o = security.option!;
  final underlying = securities[o.underlyingId];
  final expiry = DateTime.tryParse(o.expiry);
  if (underlying == null ||
      !underlying.isStock ||
      underlying.currencyCode != security.currencyCode ||
      underlying.market != security.market ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(o.expiry) ||
      expiry == null ||
      expiry.toIso8601String().substring(0, 10) != o.expiry ||
      InvestmentDecimal.parse(o.strike).units <= BigInt.zero ||
      InvestmentDecimal.parse(o.premiumMultiplier).units <= BigInt.zero ||
      InvestmentDecimal.parse(o.deliverableShares).units < BigInt.zero ||
      InvestmentDecimal.parse(o.exerciseCash).units < BigInt.zero ||
      (o.confirmed && o.specification.trim().isEmpty)) {
    throw const FormatException('期权身份、日期、币种或规格不完整');
  }
  if (o.confirmed &&
      o.settlement == OptionSettlement.physical &&
      (InvestmentDecimal.parse(o.deliverableShares).units <= BigInt.zero ||
          InvestmentDecimal.parse(o.exerciseCash).units <= BigInt.zero)) {
    throw const FormatException('实物交割须确认每张交割股数和行权现金');
  }
}

/// 张数必须为正整数；股票碎股、交割股数和权利金乘数不套用此限制。
void _requireOptionQuantity(InvestmentDecimal q) {
  if (q.units <= BigInt.zero ||
      q.units % InvestmentDecimal.scale != BigInt.zero) {
    throw const FormatException('期权张数必须为正整数');
  }
}

/// 以用户确认的交易日比较到期日；只判断是否待确认，绝不因日期自动生成平仓。
bool optionExpired(OptionContract contract, DateTime date) => DateTime.utc(
  date.year,
  date.month,
  date.day,
).isAfter(DateTime.parse('${contract.expiry}T00:00:00Z'));

/// 重放一笔期权事件及全部隐含腿；[position] 只访问本次临时投影，异常即丢弃整份草稿。
/// [margins] 存每个合约的绝对冻结额；[needsReview] 阻止拆股后沿用旧规格交易/行权。
({InvestmentDecimal cash, InvestmentDecimal realized, bool complete})
_applyOptionEvent(
  StockEvent e,
  StockSecurity security,
  int digits,
  StockPosition Function(String, bool) position,
  Map<String, InvestmentDecimal> margins, {
  required bool needsReview,
}) {
  final o = security.option!,
      q = InvestmentDecimal.parse(e.quantity),
      price = InvestmentDecimal.parse(e.price),
      fee = InvestmentDecimal.parse(e.fee);
  if (!e.kind.isOptionEvent || e.batchId != null) {
    throw const FormatException('期权必须使用独立的开平仓或结算动作');
  }
  final trade = {
    StockEventKind.optionBuyOpen,
    StockEventKind.optionSellClose,
    StockEventKind.optionSellOpen,
    StockEventKind.optionBuyClose,
  }.contains(e.kind);
  final opening = {
    StockEventKind.optionBuyOpen,
    StockEventKind.optionSellOpen,
  }.contains(e.kind);
  final short = trade
      ? {
          StockEventKind.optionSellOpen,
          StockEventKind.optionBuyClose,
        }.contains(e.kind)
      : e.short;
  var cash = InvestmentDecimal.zero, realized = InvestmentDecimal.zero;
  var complete = true;
  if (e.kind != StockEventKind.optionMargin) _requireOptionQuantity(q);
  if (e.marginAfter != null) {
    final margin = InvestmentDecimal.parse(e.marginAfter!);
    if (margin.units < BigInt.zero ||
        margin.compareTo(margin.rounded(digits)) != 0) {
      throw const FormatException('冻结保证金必须是有效原币金额');
    }
    margins[security.id] = margin;
  }
  if (e.kind == StockEventKind.optionMargin) {
    if (e.marginAfter == null ||
        q.units != BigInt.zero ||
        price.units != BigInt.zero ||
        fee.units != BigInt.zero) {
      throw const FormatException('保证金核对仅改变确认冻结额，不产生现金或费用');
    }
    return (cash: cash, realized: realized, complete: complete);
  }
  final p = position(security.id, short);
  if (trade) {
    if (optionExpired(o, e.occurredAt) ||
        needsReview ||
        price.units <= BigInt.zero) {
      throw const FormatException('到期、规格待处理或无效价格不能记录开平仓');
    }
    final gross = securityPositionValue(security, q, price, digits);
    if (opening) {
      cash = short ? gross - fee : -gross - fee;
      if (short && cash.units < BigInt.zero) {
        throw const FormatException('开仓费用超过权利金');
      }
      p.quantity = p.quantity + q;
      if (p.cost != null) p.cost = p.cost! + (short ? cash : -cash);
      return (cash: cash, realized: realized, complete: complete);
    }
  } else {
    if (!e.settlementConfirmed) throw const FormatException('请明确确认实际到期或结算结果');
    if (e.kind == StockEventKind.optionExpire &&
        DateTime.utc(
          e.occurredAt.year,
          e.occurredAt.month,
          e.occurredAt.day,
        ).isBefore(DateTime.parse('${o.expiry}T00:00:00Z'))) {
      throw const FormatException('到期日前不能确认无价值到期');
    }
    if (e.kind != StockEventKind.optionExpire &&
        (!o.confirmed || o.settlement == OptionSettlement.unsupported)) {
      throw const FormatException('规格待补全，保留持仓等待实际结算资料');
    }
  }
  if (q.compareTo(p.quantity) > 0) {
    throw const FormatException('平仓或交割张数超过指定方向持仓');
  }
  final released = p.cost == null
      ? null
      : q.compareTo(p.quantity) == 0
      ? p.cost!
      : p.cost!.allocated(q, p.quantity, digits);
  if (e.kind == StockEventKind.optionPhysicalSettle) {
    if (price.units != BigInt.zero) {
      throw const FormatException('实物交割现金由确认的每张规格计算，不能重复填写现金交割额');
    }
    if (o.settlement != OptionSettlement.physical ||
        needsReview ||
        released == null) {
      throw const FormatException('实物交割需要已核对的单股规格及完整权利金成本');
    }
    final shares = InvestmentDecimal.parse(
      o.deliverableShares,
    ).split(q, InvestmentDecimal.parse('1'));
    final exercise = q.moneyProduct(
      InvestmentDecimal.parse(o.exerciseCash),
      digits,
    );
    final buyStock =
        (o.right == OptionRight.call && !short) ||
        (o.right == OptionRight.put && short);
    final stock = position(o.underlyingId, false);
    if (buyStock) {
      final basis = exercise + fee + (short ? -released : released);
      if (basis.units < BigInt.zero) {
        throw const FormatException('交割成本为负，需人工核对成本分配');
      }
      cash = -exercise - fee;
      stock.quantity = stock.quantity + shares;
      if (stock.cost != null) stock.cost = stock.cost! + basis;
    } else {
      final net = exercise - fee + (short ? released : -released);
      final covered = stock.quantity.compareTo(shares) >= 0
          ? shares
          : stock.quantity;
      final uncovered = shares - covered;
      if (uncovered.units > BigInt.zero &&
          !(short &&
              o.right == OptionRight.call &&
              e.allowUncoveredAssignment)) {
        throw const FormatException('交割股票不足；裸认购指派须另行确认股票空头义务');
      }
      final coveredNet = covered.compareTo(shares) == 0
          ? net
          : net.allocated(covered, shares, digits);
      if (covered.units > BigInt.zero) {
        final stockCost = stock.cost == null
            ? null
            : covered.compareTo(stock.quantity) == 0
            ? stock.cost!
            : stock.cost!.allocated(covered, stock.quantity, digits);
        stock.quantity = stock.quantity - covered;
        if (stockCost == null) {
          complete = false;
        } else {
          realized = coveredNet - stockCost;
          stock.cost = stock.cost! - stockCost;
        }
        if (stock.quantity.units == BigInt.zero) {
          stock.cost = InvestmentDecimal.zero;
        }
      }
      if (uncovered.units > BigInt.zero) {
        final proceeds = net - coveredNet;
        if (proceeds.units < BigInt.zero) {
          throw const FormatException('股票空头交割净所得为负，需人工核对');
        }
        final obligation = position(o.underlyingId, true);
        obligation.quantity = obligation.quantity + uncovered;
        if (obligation.cost != null) {
          obligation.cost = obligation.cost! + proceeds;
        }
      }
      cash = exercise - fee;
    }
  } else {
    if (e.kind == StockEventKind.optionExpire && price.units != BigInt.zero) {
      throw const FormatException('无价值到期不能同时填写交割金额');
    }
    if (e.kind == StockEventKind.optionCashSettle &&
        (o.settlement != OptionSettlement.cash ||
            price.compareTo(price.rounded(digits)) != 0)) {
      throw const FormatException('现金结算须填写原币实际总额，且合约为现金交割');
    }
    final gross = trade
        ? securityPositionValue(security, q, price, digits)
        : e.kind == StockEventKind.optionExpire
        ? InvestmentDecimal.zero
        : price;
    cash = (short ? -gross : gross) - fee;
    if (released == null) {
      complete = false;
    } else {
      realized = short ? released + cash : cash - released;
    }
  }
  p.quantity = p.quantity - q;
  p.cost = p.quantity.units == BigInt.zero
      ? InvestmentDecimal.zero
      : released == null
      ? null
      : p.cost! - released;
  return (cash: cash, realized: realized, complete: complete);
}
