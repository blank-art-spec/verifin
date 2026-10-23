/// 股票投资的权威数据：每个真实币种账户一份聚合，事件与现金规则原子保存。
library;

import '../../l10n/app_localizations.dart';
import 'option_contract.dart';
import 'investment_valuation_snapshot.dart';

enum StockMarket {
  us,
  cn,
  hk;

  /// 返回市场本地化名称；市场参与证券身份，不能只按代码去重。
  String label(AppLocalizations l) => switch (this) {
    us => l.investMarketUS,
    cn => l.investMarketCN,
    hk => l.investMarketHK,
  };
}

enum StockEventKind {
  buy,
  sell,
  shortSell,
  cover,
  dividend,
  fee,
  split,
  transferIn,
  transferOut,
  optionBuyOpen,
  optionSellClose,
  optionSellOpen,
  optionBuyClose,
  optionExpire,
  optionCashSettle,
  optionPhysicalSettle,
  optionMargin;

  /// 返回事件动作名称，投资事件不映射为日常收入/支出。
  String label(AppLocalizations l) => switch (this) {
    buy => l.investBuy,
    sell => l.investSell,
    shortSell => l.investShort,
    cover => l.investCover,
    dividend => l.investDividend,
    fee => l.investFee,
    split => l.investSplit,
    transferIn => l.investTransferIn,
    transferOut => l.investTransferOut,
    optionBuyOpen => l.optionBuyOpen,
    optionSellClose => l.optionSellClose,
    optionSellOpen => l.optionSellOpen,
    optionBuyClose => l.optionBuyClose,
    optionExpire => l.optionExpire,
    optionCashSettle => l.optionCashSettlement,
    optionPhysicalSettle => l.optionPhysical,
    optionMargin => l.optionMargin,
  };
}

/// 证券稳定身份，沿用股票阶段命名；[option] 非空时表示独立期权合约。
class StockSecurity {
  /// [symbol] 为来源代码（港股保留前导零），[currencyCode] 为实际结算币种。
  const StockSecurity({
    required this.symbol,
    required this.name,
    required this.market,
    required this.currencyCode,
    this.option,
  });
  final String symbol, name, currencyCode;
  final StockMarket market;
  final OptionContract? option;

  /// 市场、品种及原始代码共同构成身份，港股前导零不丢失。
  String get id =>
      '${market.name}:${option == null ? 'stock' : 'option'}:$symbol';

  /// 序列化证券身份，价格和数量不放入静态证券定义。
  Map<String, Object?> toJson() => {
    'symbol': symbol,
    'name': name,
    'market': market.name,
    'currencyCode': currencyCode,
    if (option != null) 'option': option!.toJson(),
  };

  /// 严格解析身份；未知市场不能回落为美股。
  factory StockSecurity.fromJson(Map<String, Object?> json) => StockSecurity(
    symbol: json['symbol'] as String,
    name: json['name'] as String,
    market: StockMarket.values.byName(json['market'] as String),
    currencyCode: json['currencyCode'] as String,
    option: json['option'] == null
        ? null
        : OptionContract.fromJson(
            Map<String, Object?>.from(json['option'] as Map),
          ),
  );
}

/// 期初持仓与持仓转移共用的数量/成本载体；null 成本明确表示未知。
class StockHolding {
  /// [short] 区分多空；[cost] 是多头总成本或空头净开仓所得，不是每股价格。
  const StockHolding({
    required this.securityId,
    required this.short,
    required this.quantity,
    this.cost,
  });
  final String securityId, quantity;
  final bool short;
  final String? cost;

  /// 保留精确文本及未知成本，备份时不转为 double。
  Map<String, Object?> toJson() => {
    'securityId': securityId,
    'short': short,
    'quantity': quantity,
    'cost': cost,
  };

  /// 从备份/SQLite 载入一条期初持仓。
  factory StockHolding.fromJson(Map<String, Object?> json) => StockHolding(
    securityId: json['securityId'] as String,
    short: json['short'] as bool,
    quantity: json['quantity'] as String,
    cost: json['cost'] as String?,
  );
}

/// 一笔不可拆开的投资事实，现金腿由事件类型确定，不再复制为 LedgerEntry。
class StockEvent {
  /// [id] 同时作为幂等键；[sequence] 保证同一时刻稳定重放。
  /// [quantity]/[price] 均为精确文本；股息以 price 表示税前到账额，fee 表示代扣税。
  /// 拆股以 quantity:price 表示新股数:旧股数；转移必须成对保存并共享 batchId。
  const StockEvent({
    required this.id,
    required this.securityId,
    required this.kind,
    required this.occurredAt,
    required this.sequence,
    required this.quantity,
    required this.price,
    this.fee = '0',
    this.note = '',
    this.carriedCost,
    this.short = false,
    this.batchId,
    this.marginAfter,
    this.settlementConfirmed = false,
    this.allowUncoveredAssignment = false,
  });
  final String id, securityId, quantity, price, fee, note;
  final StockEventKind kind;
  final DateTime occurredAt;
  final int sequence;
  final String? carriedCost, batchId;
  final bool short;

  /// 用户确认该事件完成后此合约的现金冻结总额，null 表示未变更，不自动释放。
  final String? marginAfter;

  /// 到期/现金/实物结算必须显式确认；裸认购指派另需确认股票空头义务。
  final bool settlementConfirmed, allowUncoveredAssignment;

  /// 导出成交的完整事实；不保存可与事件不一致的第二份现金余额。
  Map<String, Object?> toJson() => {
    'id': id,
    'securityId': securityId,
    'kind': kind.name,
    'occurredAt': occurredAt.toIso8601String(),
    'sequence': sequence,
    'quantity': quantity,
    'price': price,
    'fee': fee,
    'note': note,
    'carriedCost': carriedCost,
    'short': short,
    'batchId': batchId,
    'marginAfter': marginAfter,
    'settlementConfirmed': settlementConfirmed,
    'allowUncoveredAssignment': allowUncoveredAssignment,
  };

  /// 严格读取事件，未知动作直接拒绝，不默认为买入。
  factory StockEvent.fromJson(Map<String, Object?> json) => StockEvent(
    id: json['id'] as String,
    securityId: json['securityId'] as String,
    kind: StockEventKind.values.byName(json['kind'] as String),
    occurredAt: DateTime.parse(json['occurredAt'] as String),
    sequence: json['sequence'] as int,
    quantity: json['quantity'] as String,
    price: json['price'] as String,
    fee: json['fee'] as String,
    note: json['note'] as String,
    carriedCost: json['carriedCost'] as String?,
    short: json['short'] as bool,
    batchId: json['batchId'] as String?,
    marginAfter: json['marginAfter'] as String?,
    settlementConfirmed: json['settlementConfirmed'] as bool? ?? false,
    allowUncoveredAssignment:
        json['allowUncoveredAssignment'] as bool? ?? false,
  );
}

/// 用户确认的期初、证券定义、成交及手填价格组成一个原子账户聚合。
class InvestmentPortfolio {
  /// [includedEntryIds] 固定生效时点已包含的普通交易，解决同秒补录的重复现金问题。
  /// [openingCash] 只代表现金；旧总资产须显式拆分后启用，不能自动猜测。
  InvestmentPortfolio({
    required this.accountId,
    required this.bookId,
    required this.currencyCode,
    required this.openedAt,
    required this.openingCash,
    List<String> includedEntryIds = const [],
    List<StockSecurity> securities = const [],
    List<StockHolding> openingHoldings = const [],
    List<StockEvent> events = const [],
    Map<String, String> manualPrices = const {},
    Map<String, List<String>> anchorIncludedIds = const {},
    Set<String> marketPriceIds = const {},
    List<InvestmentValuationSnapshot> valuationSnapshots = const [],
    this.allowFinancing = false,
  }) : includedEntryIds = List.unmodifiable(includedEntryIds),
       securities = List.unmodifiable(securities),
       openingHoldings = List.unmodifiable(openingHoldings),
       events = List.unmodifiable(events),
       manualPrices = Map.unmodifiable(manualPrices),
       marketPriceIds = Set.unmodifiable(marketPriceIds),
       valuationSnapshots = List.unmodifiable(valuationSnapshots),
       anchorIncludedIds = Map.unmodifiable({
         for (final entry in anchorIncludedIds.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       });
  final String accountId, bookId, currencyCode, openingCash;
  final DateTime openedAt;
  final List<String> includedEntryIds;
  final List<StockSecurity> securities;
  final List<StockHolding> openingHoldings;
  final List<StockEvent> events;
  final Map<String, String> manualPrices;

  /// 用户明确选择采用行情的证券 ID；默认全部手填，缓存不覆写原手填价格。
  final Set<String> marketPriceIds;

  /// 历史估值依据；不把临时缓存或当前参考价自动回填历史。
  final List<InvestmentValuationSnapshot> valuationSnapshots;

  /// 现金锚点 id → 核对时已包含的同刻交易/投资事件，键带 entry:/stock: 前缀。
  final Map<String, List<String>> anchorIncludedIds;
  final bool allowFinancing;

  /// 产生新聚合；仅返回新对象，提交成功前不修改 Controller 内存。
  InvestmentPortfolio copyWith({
    List<StockSecurity>? securities,
    List<StockEvent>? events,
    Map<String, String>? manualPrices,
    Map<String, List<String>>? anchorIncludedIds,
    List<StockHolding>? openingHoldings,
    Set<String>? marketPriceIds,
    List<InvestmentValuationSnapshot>? valuationSnapshots,
  }) => InvestmentPortfolio(
    accountId: accountId,
    bookId: bookId,
    currencyCode: currencyCode,
    openedAt: openedAt,
    openingCash: openingCash,
    includedEntryIds: includedEntryIds,
    securities: securities ?? this.securities,
    openingHoldings: openingHoldings ?? this.openingHoldings,
    events: events ?? this.events,
    manualPrices: manualPrices ?? this.manualPrices,
    allowFinancing: allowFinancing,
    anchorIncludedIds: anchorIncludedIds ?? this.anchorIncludedIds,
    marketPriceIds: marketPriceIds ?? this.marketPriceIds,
    valuationSnapshots: valuationSnapshots ?? this.valuationSnapshots,
  );

  /// 完整用户投资数据进入 JSON v12；历史依据保存，临时行情缓存不进入备份。
  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'bookId': bookId,
    'currencyCode': currencyCode,
    'openedAt': openedAt.toIso8601String(),
    'openingCash': openingCash,
    'includedEntryIds': includedEntryIds,
    'securities': securities.map((v) => v.toJson()).toList(),
    'openingHoldings': openingHoldings.map((v) => v.toJson()).toList(),
    'events': events.map((v) => v.toJson()).toList(),
    'manualPrices': manualPrices,
    'allowFinancing': allowFinancing,
    'anchorIncludedIds': anchorIncludedIds,
    'marketPriceIds': marketPriceIds.toList()..sort(),
    'valuationSnapshots': valuationSnapshots.map((v) => v.toJson()).toList(),
  };

  /// 读取聚合；数值语义及跨账户引用还需由投影器、Controller 统一校验。
  factory InvestmentPortfolio.fromJson(
    Map<String, Object?> json,
  ) => InvestmentPortfolio(
    accountId: json['accountId'] as String,
    bookId: json['bookId'] as String,
    currencyCode: json['currencyCode'] as String,
    openedAt: DateTime.parse(json['openedAt'] as String),
    openingCash: json['openingCash'] as String,
    includedEntryIds: List<String>.from(json['includedEntryIds'] as List),
    securities: (json['securities'] as List)
        .map((v) => StockSecurity.fromJson(Map<String, Object?>.from(v as Map)))
        .toList(),
    openingHoldings: (json['openingHoldings'] as List)
        .map((v) => StockHolding.fromJson(Map<String, Object?>.from(v as Map)))
        .toList(),
    events: (json['events'] as List)
        .map((v) => StockEvent.fromJson(Map<String, Object?>.from(v as Map)))
        .toList(),
    manualPrices: Map<String, String>.from(json['manualPrices'] as Map),
    allowFinancing: json['allowFinancing'] as bool,
    marketPriceIds: Set<String>.from(
      json['marketPriceIds'] as List? ?? const [],
    ),
    valuationSnapshots: (json['valuationSnapshots'] as List? ?? const [])
        .map(
          (v) => InvestmentValuationSnapshot.fromJson(
            Map<String, Object?>.from(v as Map),
          ),
        )
        .toList(),
    anchorIncludedIds: {
      for (final e in (json['anchorIncludedIds'] as Map? ?? {}).entries)
        e.key as String: List<String>.from(e.value as List),
    },
  );
}
