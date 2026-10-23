import 'package:verifin/app/models.dart';

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
