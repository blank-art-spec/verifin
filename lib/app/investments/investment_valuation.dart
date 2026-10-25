/// 当前与历史资产估值的纯计算入口；不联网、不写账、不读取 Controller。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../currency_catalog.dart';
import '../currency_math.dart';
import '../ledger_math.dart';
import '../models.dart';
import 'investment_decimal.dart';
import 'stock_projection.dart';
import 'stock_cash_math.dart';

/// 投资账户原币估值；未知成本只影响盈亏，缺价格则资产与净值均不完整。
class InvestmentAccountValuation {
  /// [cash] 是真实现金，[frozen] 仅作冻结披露，不在净值中再次扣减。
  const InvestmentAccountValuation({
    required this.cash,
    required this.frozen,
    required this.longValue,
    required this.shortObligation,
    required this.unrealized,
    required this.realized,
    required this.costComplete,
  });
  final double cash, frozen;
  final double? longValue, shortObligation, unrealized, realized;
  final bool costComplete;

  /// 多头、正现金归资产；空头、负现金归负债，不能按账户净额正负抵销。
  AccountAssetAmounts? get amounts =>
      longValue == null || shortObligation == null
      ? null
      : AccountAssetAmounts(
          (cash > 0 ? cash : 0) + longValue!,
          (cash < 0 ? -cash : 0) + shortObligation!,
        );

  /// 现金资产占总资产的比例，范围为 0–1；返回小数比例而不是百分数。
  ///
  /// 负现金属于融资负债，因此分子按 0 计算；已冻结的现金仍属现金资产，
  /// 不减去 [frozen]。价格不完整、估值含非有限数或总资产不大于 0 时返回 null，
  /// 区分“无法计算”与存在有效总资产时的现金占比 0。
  double? get cashShare => shareOfAssets(cash < 0 ? 0 : cash);

  /// 多头持仓市值占总资产的比例，范围为 0–1；股票与期权沿用已计算的 [longValue]。
  ///
  /// 分母为正现金与多头市值之和，不采用扣除融资或空头义务后的净值。
  /// 成本未知不会阻止计算；价格不完整、非有限或总资产不大于 0 时返回 null。
  double? get holdingsShare => shareOfAssets(longValue);

  /// 空头回补义务占总资产的比例，仅作负债披露，不加入现金和多头的资产分布。
  ///
  /// 分子为 [shortObligation]；高杠杆时结果可以大于 1，不截断为 100%。
  /// 价格不完整、非有限或总资产不大于 0 时返回 null；保证金不重复作为义务扣减。
  double? get shortObligationShare => shareOfAssets(shortObligation);

  /// 将原币非负金额 [value] 换算为占本账户总资产的小数比例，供单项持仓共用。
  ///
  /// [value] 应为已按结算币种舍入的市值或空头义务；股票与期权的市值仍由
  /// securityPositionValue 计算，本方法不重算数量、价格或乘数。分母复用
  /// [amounts] 的正现金加多头市值，冻结额不重复扣除，负债不抵销分母。
  ///
  /// 输入为 null、负数或非有限数，整体估值不完整/含非有限数、多头市值或空头义务
  /// 为负数、总资产不大于 0，
  /// 或除法结果超出有限数范围时均返回 null。允许大于 1，以保留真实空头风险。
  double? shareOfAssets(double? value) {
    final longs = longValue, shorts = shortObligation;
    if (value == null ||
        !value.isFinite ||
        value < 0 ||
        !cash.isFinite ||
        longs == null ||
        !longs.isFinite ||
        longs < 0 ||
        shorts == null ||
        !shorts.isFinite ||
        shorts < 0) {
      return null;
    }
    final assetAmounts = amounts;
    if (assetAmounts == null ||
        !assetAmounts.assets.isFinite ||
        !assetAmounts.liabilities.isFinite ||
        assetAmounts.assets <= 0) {
      return null;
    }
    final share = value / assetAmounts.assets;
    if (!share.isFinite) return null;
    // 消除 -0.0，避免格式化后出现没有实际含义的负零占比。
    return share == 0 ? 0 : share;
  }
}

/// 统一股票/期权乘数与多空方向；[portfolio] 的价格须是调用方选定的时点依据。
InvestmentAccountValuation valueInvestmentAccount(
  InvestmentPortfolio portfolio,
  double cash,
) {
  final projection = projectStocks(portfolio),
      digits = CurrencyCatalog.require(portfolio.currencyCode).minorUnit;
  var longs = InvestmentDecimal.zero, shorts = InvestmentDecimal.zero;
  var complete = true;
  for (final position in projection.positions) {
    final raw = portfolio.manualPrices[position.securityId];
    if (raw == null) {
      complete = false;
      continue;
    }
    final price = InvestmentDecimal.parse(raw);
    if (price.units < BigInt.zero) throw const FormatException('参考价不能为负');
    final security = portfolio.securities.firstWhere(
      (s) => s.id == position.securityId,
    );
    final value = securityPositionValue(
      security,
      position.quantity,
      price,
      digits,
    );
    if (position.short) {
      shorts = shorts + value;
    } else {
      longs = longs + value;
    }
  }
  return InvestmentAccountValuation(
    cash: normalizeCurrencyAmount(cash, portfolio.currencyCode),
    frozen: projection.frozenMargin.toDouble(),
    longValue: complete ? longs.toDouble() : null,
    shortObligation: complete ? shorts.toDouble() : null,
    unrealized: valueStocks(portfolio, projection).unrealized?.toDouble(),
    realized: projection.realizedComplete
        ? projection.realized.toDouble()
        : null,
    costComplete:
        projection.realizedComplete &&
        projection.positions.every((p) => p.cost != null),
  );
}

/// 截取 [at] 之前（含同刻）的证券事实；不把未来成交或今日价格带入历史。
InvestmentPortfolio investmentAt(InvestmentPortfolio portfolio, DateTime at) =>
    portfolio.copyWith(
      events: portfolio.events.where((e) => !e.occurredAt.isAfter(at)).toList(),
    );

/// 计算指定时点现金；现金锚点只取当时已生效的最新一条，不能回填较晚校准。
/// [portfolio] 非空时复用投资资金腿，普通账户则沿用余额与日常交易差额。
double accountCashAt({
  required Account account,
  required Iterable<LedgerEntry> entries,
  required Iterable<BalanceAnchor> anchors,
  required DateTime at,
  InvestmentPortfolio? portfolio,
}) {
  final available =
      anchors
          .where(
            (a) =>
                a.accountId == account.id &&
                a.bookId == account.bookId &&
                !a.effectiveAt.isAfter(at),
          )
          .toList()
        ..sort((a, b) => b.effectiveAt.compareTo(a.effectiveAt));
  final anchor = available.firstOrNull;
  final relevant = entries.where(
    (e) => e.bookId == account.bookId && !accountEffectDate(e).isAfter(at),
  );
  if (portfolio != null) {
    return investmentCashBalance(
      portfolio: investmentAt(portfolio, at),
      entries: relevant,
      anchor: anchor,
    );
  }
  var balance = anchor?.balance ?? account.initialBalance;
  for (final entry in relevant) {
    if (anchor == null ||
        accountEffectDate(entry).isAfter(anchor.effectiveAt)) {
      balance += accountDeltaForEntry(entry, account.id);
    }
  }
  return normalizeCurrencyAmount(balance, account.currencyCode);
}

/// 对截止时点会影响现金/仓位/成本的事实做稳定摘要；不包含现价、缓存及快照自身。
/// 历史补录、删除或改规格后旧快照失效；未来成交和日后改参考价不重写过去。
String investmentRevision(
  InvestmentPortfolio p,
  Iterable<LedgerEntry> entries,
  Iterable<BalanceAnchor> anchors,
  DateTime at,
) {
  final past = investmentAt(p, at);
  final ids = {
    ...p.openingHoldings.map((h) => h.securityId),
    ...past.events.map((e) => e.securityId),
  };
  for (final s in p.securities.where((s) => ids.contains(s.id)).toList()) {
    if (s.option != null) ids.add(s.option!.underlyingId);
  }
  final securities = p.securities.where((s) => ids.contains(s.id)).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final events = [...past.events]..sort(compareStockEvents);
  final relatedEntries =
      entries
          .where(
            (e) =>
                e.bookId == p.bookId &&
                entryTouchesAccount(e, p.accountId) &&
                !accountEffectDate(e).isAfter(at),
          )
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  final relatedAnchors =
      anchors
          .where(
            (a) =>
                a.accountId == p.accountId &&
                a.bookId == p.bookId &&
                !a.effectiveAt.isAfter(at),
          )
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'accountId': p.accountId,
            'bookId': p.bookId,
            'currencyCode': p.currencyCode,
            'openedAt': p.openedAt.toIso8601String(),
            'openingCash': p.openingCash,
            'includedEntryIds': p.includedEntryIds,
            'openingHoldings': p.openingHoldings
                .map((v) => v.toJson())
                .toList(),
            'securities': securities.map((v) => v.toJson()).toList(),
            'events': events.map((v) => v.toJson()).toList(),
            'entries': relatedEntries.map((v) => v.toJson()).toList(),
            'anchors': relatedAnchors.map((v) => v.toJson()).toList(),
            'anchorIncludedIds': {
              for (final a in relatedAnchors) a.id: p.anchorIncludedIds[a.id],
            },
          }),
        ),
      )
      .toString();
}

/// 读取某一历史日最后保存的真实依据；无该日快照或账务修订不匹配时返回 null。
InvestmentValuationSnapshot? investmentSnapshotAt(
  InvestmentPortfolio p,
  DateTime at,
  Iterable<LedgerEntry> entries,
  Iterable<BalanceAnchor> anchors,
) {
  final candidates =
      p.valuationSnapshots
          .where(
            (s) =>
                !s.capturedAt.isAfter(at) &&
                calendarDaysBetween(s.capturedAt.toLocal(), at.toLocal()) == 0,
          )
          .toList()
        ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  final s = candidates.firstOrNull;
  return s != null &&
          s.revision == investmentRevision(p, entries, anchors, s.capturedAt)
      ? s
      : null;
}

/// 给资产页、首页、小组件提供同一汇总。当前可用选定参考价；历史必须有当日价格/汇率快照。
/// [current] 只用于实际当前读数；历史数据永远不能回退当前手填价或当前缓存。
ConvertedAccountBalances valueLedgerAccounts({
  required Iterable<Account> accounts,
  required Iterable<LedgerEntry> entries,
  required Iterable<BalanceAnchor> anchors,
  required Iterable<InvestmentPortfolio> portfolios,
  required String bookId,
  required String baseCurrencyCode,
  required Iterable<ExchangeRate> rates,
  required DateTime at,
  bool current = true,
  double Function(Account)? currentCashOf,
}) {
  final selectedAccounts = accounts.where((a) => a.bookId == bookId).toList();
  final cutoff = current ? DateTime.utc(9999) : at;
  final normalCash = currentCashOf == null || !current
      ? _cashBalancesAt(selectedAccounts, entries, anchors, cutoff)
      : const <String, double>{};
  final amounts = <String, double>{},
      assets = <String, double>{},
      debts = <String, double>{};
  final missing = <String>{},
      affected = <String>{},
      stale = <String>{},
      incomplete = <String>{};
  final dates = <String, DateTime>{};
  for (final account in selectedAccounts) {
    final p = portfolios
        .where((p) => p.accountId == account.id && p.bookId == bookId)
        .firstOrNull;
    InvestmentValuationSnapshot? snapshot;
    if (p != null &&
        !current &&
        (at.isBefore(p.openedAt) ||
            (snapshot = investmentSnapshotAt(p, at, entries, anchors)) ==
                null)) {
      incomplete.add(account.id);
      continue;
    }
    // 历史截止前的后续成交仍要重放；只能沿用当日已有价格，新增证券缺价则留空。
    final time = at;
    // 当前余额保留应用既有“全部已录入事实”的语义；历史才按截止时点截断。
    final cash = current && currentCashOf != null
        ? currentCashOf(account)
        : p == null
        ? normalCash[account.id]!
        : accountCashAt(
            account: account,
            entries: entries,
            anchors: anchors,
            at: current ? DateTime.utc(9999) : time,
            portfolio: p,
          );
    final selected = p == null
        ? null
        : (current ? p : investmentAt(p, time)).copyWith(
            manualPrices: snapshot == null
                ? p.manualPrices
                : snapshot.prices.map((id, f) => MapEntry(id, f.price)),
          );
    final parts = selected == null
        ? AccountAssetAmounts.balance(cash)
        : valueInvestmentAccount(selected, cash).amounts;
    if (parts == null) {
      incomplete.add(account.id);
      continue;
    }
    if (snapshot != null &&
        (snapshot.baseCurrencyCode != baseCurrencyCode ||
            snapshot.rateToBase == null)) {
      missing.add(account.currencyCode);
      affected.add(account.id);
      continue;
    }
    final selectedRates = snapshot == null
        ? rates
        : [
            ExchangeRate(
              id: 'snapshot',
              bookId: bookId,
              baseCurrencyCode: baseCurrencyCode,
              currencyCode: account.currencyCode,
              effectiveDate: snapshot.rateDate ?? snapshot.capturedAt,
              rateToBase: snapshot.rateToBase!,
              source: ExchangeRateSource.manual,
              createdAt: snapshot.capturedAt,
              updatedAt: snapshot.capturedAt,
            ),
          ];
    final converted = convertAccountBalancesToBase(
      accounts: [account],
      balanceOf: (_) => cash,
      valuationOf: (_) => parts,
      bookId: bookId,
      baseCurrencyCode: baseCurrencyCode,
      date: time,
      rates: selectedRates,
    );
    amounts.addAll(converted.amountsByAccountId);
    assets.addAll(converted.assetsByAccountId);
    debts.addAll(converted.liabilitiesByAccountId);
    missing.addAll(converted.missingCurrencyCodes);
    affected.addAll(converted.affectedAccountIds);
    dates.addAll(converted.rateDatesByAccountId);
    stale.addAll(converted.staleAccountIds);
  }
  return ConvertedAccountBalances(
    amountsByAccountId: Map.unmodifiable(amounts),
    missingCurrencyCodes: Set.unmodifiable(missing),
    affectedAccountIds: Set.unmodifiable(affected),
    rateDatesByAccountId: Map.unmodifiable(dates),
    staleAccountIds: Set.unmodifiable(stale),
    assetsByAccountId: Map.unmodifiable(assets),
    liabilitiesByAccountId: Map.unmodifiable(debts),
    missingValuationAccountIds: Set.unmodifiable(incomplete),
  );
}

/// 普通账户现金批量重放，避免资产汇总退回“每个账户扫描全部交易”。
/// [at] 截断历史；投资账户的专用资金腿仍由调用方另行计算。
Map<String, double> _cashBalancesAt(
  List<Account> accounts,
  Iterable<LedgerEntry> entries,
  Iterable<BalanceAnchor> anchors,
  DateTime at,
) {
  final byId = {for (final a in accounts) a.id: a},
      latest = <String, BalanceAnchor>{};
  for (final anchor in anchors) {
    final account = byId[anchor.accountId], old = latest[anchor.accountId];
    if (account != null &&
        anchor.bookId == account.bookId &&
        !anchor.effectiveAt.isAfter(at) &&
        (old == null || anchor.effectiveAt.isAfter(old.effectiveAt))) {
      latest[anchor.accountId] = anchor;
    }
  }
  final cash = {
    for (final a in accounts) a.id: latest[a.id]?.balance ?? a.initialBalance,
  };
  for (final entry in entries) {
    final time = accountEffectDate(entry);
    if (time.isAfter(at)) continue;
    for (final id in {
      entry.accountId,
      if (entry.toAccountId != null) entry.toAccountId!,
    }) {
      final account = byId[id], anchor = latest[id];
      if (account != null &&
          account.bookId == entry.bookId &&
          (anchor == null || time.isAfter(anchor.effectiveAt))) {
        cash[id] = cash[id]! + accountDeltaForEntry(entry, id);
      }
    }
  }
  return {
    for (final a in accounts)
      a.id: normalizeCurrencyAmount(cash[a.id]!, a.currencyCode),
  };
}
