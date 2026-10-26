import 'package:verifin/app/models.dart';

/// 明确的本地验收合约，不能发送到真实行情接口；股数、乘数与行权现金独立指定。
StockSecurity optionFixture({
  OptionRight right = OptionRight.call,
  OptionSettlement settlement = OptionSettlement.physical,
  String multiplier = '100',
  String shares = '100',
  String exercise = '5000',
  bool confirmed = true,
  String expiry = '2026-12-18',
}) => StockSecurity(
  symbol: 'TEST-AVGO-${right.name}-$expiry-50',
  name: '博通期权验收示例',
  market: StockMarket.us,
  currencyCode: 'USD',
  option: OptionContract(
    underlyingId: avgoFixture.id,
    expiry: expiry,
    right: right,
    strike: '50',
    premiumMultiplier: multiplier,
    settlement: settlement,
    deliverableShares: shares,
    exerciseCash: exercise,
    specification: '本地固定验收规格，非真实合约',
    confirmed: confirmed,
  ),
);

/// 创建不同动作的稳定测试事实；[settled] 是显式确认而非由系统到期自动生成。
StockEvent optionEventFixture(
  StockSecurity security,
  StockEventKind kind, {
  String id = 'option-event',
  String quantity = '1',
  String price = '2',
  String fee = '0',
  int sequence = 1,
  bool short = false,
  String? margin,
  bool settled = false,
  bool uncovered = false,
  DateTime? date,
}) => StockEvent(
  id: id,
  securityId: security.id,
  kind: kind,
  occurredAt: date ?? DateTime(2026, 10, 2 + sequence, 10),
  sequence: sequence,
  quantity: quantity,
  price: price,
  fee: fee,
  short: short,
  marginAfter: margin,
  settlementConfirmed: settled,
  allowUncoveredAssignment: uncovered,
  note: '本地验收示例',
);

/// 构造股票与期权同账户的不可变聚合；[opening] 用于覆盖股票交割及未知期初成本。
InvestmentPortfolio optionPortfolioFixture(
  StockSecurity security, {
  List<StockEvent> events = const [],
  List<StockHolding> opening = const [],
  String price = '3',
}) => InvestmentPortfolio(
  accountId: 'stock-usd',
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime(2026, 10, 1),
  openingCash: '10000',
  securities: [avgoFixture, security],
  openingHoldings: opening,
  events: events,
  manualPrices: {avgoFixture.id: '50', security.id: price},
);

/// 所有金额都是固定测试值，不是博通历史成交或当前行情。
const avgoFixture = StockSecurity(
  symbol: 'AVGO',
  name: '博通',
  market: StockMarket.us,
  currencyCode: 'USD',
);

/// 创建隔离投资账户；[id] 用于同账本转移测试，[currency] 用于币种隔离测试。
Account investmentAccountFixture({
  String id = 'stock-usd',
  String currency = 'USD',
  String bookId = defaultLedgerBookId,
}) => Account(
  id: id,
  bookId: bookId,
  name: '投资测试.$currency',
  type: AccountType.investment,
  groupId: null,
  initialBalance: 10000,
  iconCode: 'investment',
  note: '验收示例',
  includeInAssets: true,
  hidden: false,
  currencyCode: currency,
);

/// 创建稳定顺序的博通事件；[day] 控制补录顺序，[fee] 为独立费用输入。
StockEvent stockEventFixture(
  String id,
  StockEventKind kind,
  String quantity,
  String price, {
  String fee = '0',
  int sequence = 1,
  int day = 2,
}) => StockEvent(
  id: id,
  securityId: avgoFixture.id,
  kind: kind,
  occurredAt: DateTime(2026, 10, day, 10),
  sequence: sequence,
  quantity: quantity,
  price: price,
  fee: fee,
  note: '验收示例',
);

/// 构造纯计算/映射 fixture，覆盖非默认字段及精确报价。
InvestmentPortfolio portfolioFixture({
  String accountId = 'stock-usd',
  List<StockEvent> events = const [],
  List<StockHolding> opening = const [],
  String price = '330',
}) => InvestmentPortfolio(
  accountId: accountId,
  bookId: defaultLedgerBookId,
  currencyCode: 'USD',
  openedAt: DateTime(2026, 10, 1, 10),
  openingCash: '10000',
  includedEntryIds: const ['included'],
  securities: const [avgoFixture],
  openingHoldings: opening,
  events: events,
  manualPrices: {avgoFixture.id: price},
  allowFinancing: false,
);
