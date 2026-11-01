import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/credit_card.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/models.dart';

const _parent = CreditAccount(
  id: 'credit-parent',
  bookId: 'book',
  name: '信用卡',
  institution: '',
  cardLast4: '',
  currencyCode: 'CNY',
  creditLimit: null,
  statementDay: 25,
  dueRuleType: CreditDueRuleType.fixedDay,
  dueDay: 13,
  daysAfterStatement: null,
  cycleBudget: null,
);

Account _account(String currency) => Account(
  id: currency.toLowerCase(),
  bookId: 'book',
  name: currency,
  type: AccountType.creditCard,
  groupId: null,
  initialBalance: 0,
  iconCode: 'credit',
  note: '',
  includeInAssets: true,
  hidden: false,
  currencyCode: currency,
  creditAccountId: _parent.id,
  statementDay: 25,
  dueDay: 13,
);

ExchangeRate _rate(String currency, double value, DateTime date) =>
    ExchangeRate(
      id: '$currency-${date.toIso8601String()}',
      bookId: 'book',
      baseCurrencyCode: 'CNY',
      currencyCode: currency,
      effectiveDate: date,
      rateToBase: value,
      source: ExchangeRateSource.online,
      createdAt: date,
      updatedAt: date,
    );

List<ExchangeRate> _rates() => [
  _rate('USD', 7, DateTime(2026, 10, 1)),
  _rate('USD', 6.6567, DateTime(2026, 11, 1)),
  _rate('USD', 9.9, DateTime(2026, 12, 1)),
  _rate('HKD', 0.8, DateTime(2026, 10, 1)),
  _rate('HKD', 0.85, DateTime(2026, 11, 1)),
];

LedgerEntry _expense(
  String id,
  String currency,
  double amount, {
  double? reference,
  double cachedBase = 999,
  DateTime? date,
  String? cycleId,
}) => LedgerEntry(
  id: id,
  bookId: 'book',
  type: EntryType.expense,
  amount: amount,
  currencyCode: currency,
  accountAmount: amount,
  baseAmount: cachedBase,
  referenceBaseAmount: reference,
  categoryId: 'expense',
  accountId: currency.toLowerCase(),
  note: '',
  occurredAt: date ?? DateTime(2026, 10, 8),
  billingCycleId: cycleId,
);

LedgerEntry _repayment(String id, double received, DateTime date) =>
    LedgerEntry(
      id: id,
      bookId: 'book',
      type: EntryType.transfer,
      amount: received * 7,
      currencyCode: 'CNY',
      accountAmount: received * 7,
      toAccountAmount: received,
      accountId: 'bank',
      toAccountId: 'usd',
      categoryId: 'transfer',
      note: '',
      occurredAt: date,
    );

LedgerEntry _refund(
  String id,
  double amount, {
  double? reference,
  DateTime? settledAt,
}) => LedgerEntry(
  id: id,
  bookId: 'book',
  type: EntryType.refund,
  amount: amount,
  currencyCode: 'USD',
  accountAmount: amount,
  baseAmount: 999,
  referenceBaseAmount: reference,
  accountId: 'usd',
  categoryId: 'expense',
  note: '',
  occurredAt: DateTime(2026, 10, 30),
  refundOf: 'original',
  settledAt: settledAt,
);

BillingStatement _statement({
  required DateTime date,
  required double amount,
  double paid = 0,
}) => BillingStatement(
  id: 'statement-${billingCycleIdFor(date)}',
  bookId: 'book',
  accountId: 'usd',
  currencyCode: 'USD',
  statementDate: date,
  periodStart: DateTime(date.year, date.month - 1, 25),
  periodEnd: date,
  statementAmount: amount,
  minimumPayment: 0,
  dueDate: creditDueDate(_parent, date),
  paidAmount: paid,
  status: BillingStatementStatus.open,
);

CreditCycleOverview _overview({
  required List<LedgerEntry> entries,
  required DateTime now,
  CreditAccount parent = _parent,
  List<Account>? accounts,
  List<ExchangeRate>? rates,
  List<BillingStatement> statements = const [],
  Map<String, double> balances = const {},
}) => buildCreditCycleOverview(
  creditAccount: parent,
  accounts: accounts ?? [_account('CNY'), _account('USD')],
  entries: entries,
  statements: statements,
  allocations: const [],
  baseCurrencyCode: 'CNY',
  now: now,
  balanceOf: (account) => balances[account.id] ?? 0,
  convertToCreditCurrency: (amount, source, date) {
    // 保留生产传入日期，让回归能发现错误使用消费日或出账日的情况。
    final converted = convertCurrencyAmount(
      amount: amount,
      sourceCurrencyCode: source,
      targetCurrencyCode: parent.currencyCode,
      baseCurrencyCode: 'CNY',
      bookId: 'book',
      date: date,
      rates: rates ?? _rates(),
    );
    return converted is ConvertedCurrencyAmount ? converted.amount : null;
  },
);

CreditStatementOverview _usdOverview(
  List<LedgerEntry> entries,
  DateTime now, {
  List<BillingStatement> statements = const [],
}) => creditStatementOverview(
  account: _account('USD'),
  entries: entries,
  statements: statements,
  now: now,
);

void main() {
  test('已出账美元记录优先明确折算额，原币待还与最新负债估值各自保留', () {
    final original = _expense(
      'chatgpt',
      'USD',
      21.02,
      reference: 140.93,
      cachedBase: 139.92,
    );
    final now = DateTime(2026, 11, 2, 12);
    final overview = _overview(
      entries: [original],
      now: now,
      balances: {'usd': -21.02},
    );
    expect(overview.billedOutstanding, closeTo(140.93, 0.001));
    expect(overview.dueOutstandingAmount, closeTo(140.93, 0.001));
    expect(overview.totalDebt, closeTo(139.92, 0.001));
    expect(overview.missingConversion, isFalse);
    expect(_usdOverview([original], now).billedOutstanding, 21.02);
    expect(original.baseAmount, 139.92);
    expect(original.referenceBaseAmount, 140.93);
    expect(original.accountAmount, 21.02);
  });

  test('未填折算的已出账记录忽略旧缓存，按查看当天有效汇率变化', () {
    final original = _expense('floating', 'USD', 21.02, cachedBase: 140.93);
    final october = _overview(entries: [original], now: DateTime(2026, 10, 26));
    final november = _overview(entries: [original], now: DateTime(2026, 11, 2));
    expect(october.billedOutstanding, closeTo(147.14, 0.001));
    expect(october.dueOutstandingAmount, closeTo(147.14, 0.001));
    expect(november.billedOutstanding, closeTo(139.92, 0.001));
    expect(november.dueOutstandingAmount, closeTo(139.92, 0.001));
    expect(original.baseAmount, 140.93);
    expect(original.referenceBaseAmount, isNull);
  });

  test('同账期多币种逐笔区分已填和未填折算，不能先合并原币再换汇', () {
    final entries = [
      _expense('cny', 'CNY', 50),
      _expense('usd-fixed', 'USD', 21.02, reference: 140.93),
      _expense('usd-floating', 'USD', 10),
      _expense('hkd-floating', 'HKD', 10),
    ];
    final now = DateTime(2026, 11, 2);
    final overview = _overview(
      entries: entries,
      accounts: [_account('CNY'), _account('USD'), _account('HKD')],
      now: now,
    );
    expect(overview.billedOutstanding, closeTo(266, 0.001));
    expect(overview.dueOutstandingAmount, closeTo(266, 0.001));
    expect(_usdOverview(entries, now).billedOutstanding, 31.02);
  });

  test('单笔已出账消费部分还款按剩余原币比例保留折算，全额还款后归零', () {
    final original = _expense('original', 'USD', 10, reference: 72);
    final partial = _repayment('partial', 4, DateTime(2026, 10, 26));
    final now = DateTime(2026, 11, 2);
    final entries = [original, partial];
    final overview = _overview(entries: entries, now: now);
    expect(overview.billedOutstanding, closeTo(43.20, 0.001));
    expect(overview.dueOutstandingAmount, closeTo(43.20, 0.001));
    expect(overview.earlyRepayment, 0);
    expect(_usdOverview(entries, now).billedOutstanding, 6);

    final fullyPaid = [
      ...entries,
      _repayment('remaining', 6, DateTime(2026, 10, 27)),
    ];
    final cleared = _overview(entries: fullyPaid, now: now);
    expect(cleared.billedOutstanding, 0);
    expect(cleared.dueOutstandingAmount, 0);
    expect(_usdOverview(fullyPaid, now).billedOutstanding, 0);
  });

  test('到账退款自身优先折算额否则当天换汇，全额退回不留汇率尾差', () {
    final original = _expense('original', 'USD', 10, reference: 72);
    final now = DateTime(2026, 11, 2, 12);
    for (final scenario in [
      (amount: 2.0, reference: 15.0, expected: 57.0),
      (amount: 2.0, reference: null, expected: 58.69),
      (amount: 10.0, reference: null, expected: 0.0),
      (amount: 10.0, reference: 74.0, expected: 0.0),
    ]) {
      final refund = _refund(
        'refund',
        scenario.amount,
        reference: scenario.reference,
        settledAt: DateTime(2026, 11, 2),
      );
      final entries = [original, refund];
      final overview = _overview(entries: entries, now: now);
      expect(
        overview.billedOutstanding,
        closeTo(scenario.expected, 0.001),
        reason: '退款 ${scenario.amount} USD，参考额 ${scenario.reference}',
      );
      expect(overview.dueOutstandingAmount, closeTo(scenario.expected, 0.001));
      expect(
        _usdOverview(entries, now).billedOutstanding,
        closeTo(10 - scenario.amount, 0.001),
      );
    }
  });

  test('待到账未来到账和跨账户退款不冲抵原账户已出账折算额', () {
    final original = _expense('original', 'USD', 10, reference: 72);
    final now = DateTime(2026, 11, 2, 12);
    final pending = _refund('pending', 2, reference: 15);
    final future = _refund(
      'future',
      2,
      reference: 15,
      settledAt: DateTime(2026, 11, 3),
    );
    final elsewhere = _refund(
      'elsewhere',
      2,
      reference: 15,
      settledAt: DateTime(2026, 11, 2),
    ).copyWith(accountId: 'other-usd');
    for (final refund in [pending, future, elsewhere]) {
      final entries = [original, refund];
      final overview = _overview(entries: entries, now: now);
      expect(overview.billedOutstanding, 72, reason: refund.id);
      expect(overview.dueOutstandingAmount, 72, reason: refund.id);
      expect(_usdOverview(entries, now).billedOutstanding, 10);
    }
  });

  test('主体和子账户同币种时使用实际原币，不把本币参考额当作原币', () {
    final original = _expense('original', 'USD', 21.02, reference: 140.93);
    final overview = _overview(
      entries: [original],
      accounts: [_account('USD')],
      parent: _parent.copyWith(currencyCode: 'USD'),
      now: DateTime(2026, 11, 2),
      balances: {'usd': -21.02},
    );
    expect(overview.billedOutstanding, 21.02);
    expect(overview.dueOutstandingAmount, 21.02);
    expect(overview.totalDebt, 21.02);
  });

  test('正式账单覆盖保持权威，未来账单不提前覆盖，账单日显式归期优先', () {
    final now = DateTime(2026, 11, 2);
    final original = _expense('original', 'USD', 10, reference: 72);
    final formal = _statement(
      date: DateTime(2026, 10, 25),
      amount: 10,
      paid: 4,
    );
    final overview = _overview(
      entries: [original, _expense('cny', 'CNY', 50)],
      statements: [formal],
      rates: [_rate('USD', 6.6567, DateTime(2026, 10, 1))],
      now: now,
    );
    expect(overview.billedOutstanding, closeTo(89.94, 0.001));
    expect(overview.dueOutstandingAmount, closeTo(89.94, 0.001));
    expect(
      _usdOverview([original], now, statements: [formal]).billedOutstanding,
      6,
    );

    final future = _statement(date: DateTime(2026, 11, 25), amount: 999);
    final boundaryEntries = [
      _expense(
        'explicit-previous',
        'USD',
        10,
        reference: 70,
        date: DateTime(2026, 10, 25, 12),
        cycleId: '2026-10-25',
      ),
      _expense(
        'implicit-next',
        'USD',
        2,
        reference: 14,
        date: DateTime(2026, 10, 25, 12),
      ),
    ];
    final before = _overview(
      entries: boundaryEntries,
      statements: [future],
      now: DateTime(2026, 10, 24, 23, 59),
    );
    expect(before.billedOutstanding, 0);
    final after = _overview(
      entries: boundaryEntries,
      statements: [future],
      now: now,
    );
    expect(after.billedOutstanding, 70);
    expect(after.dueOutstandingAmount, 70);
    final detail = _usdOverview(boundaryEntries, now, statements: [future]);
    expect(detail.billedOutstanding, 10);
    expect(detail.unbilledAmount, 2);
    expect(detail.latestStatement, isNull);
  });

  test('同时刻消费以稳定顺序分摊还款，反向输入不改变剩余参考折算额', () {
    final first = _expense('a-fixed', 'USD', 10, reference: 70);
    final second = _expense('b-fixed', 'USD', 10, reference: 80);
    final payment = _repayment('payment', 10, DateTime(2026, 10, 26));
    final now = DateTime(2026, 11, 2);
    for (final entries in [
      [first, second, payment],
      [payment, second, first],
    ]) {
      final overview = _overview(entries: entries, now: now);
      expect(overview.billedOutstanding, 80);
      expect(overview.dueOutstandingAmount, 80);
      expect(overview.earlyRepayment, 0);
      expect(_usdOverview(entries, now).billedOutstanding, 10);
    }
  });

  test('参考折算只需要目标币种汇率，未填参考且缺率明确返回缺失', () {
    final fixed = _expense('fixed', 'USD', 21.02, reference: 140.93);
    final now = DateTime(2026, 11, 2);
    final cny = _overview(entries: [fixed], now: now, rates: []);
    expect(cny.billedOutstanding, closeTo(140.93, 0.001));
    expect(cny.dueOutstandingAmount, closeTo(140.93, 0.001));
    expect(cny.missingConversion, isFalse);

    final hkd = _overview(
      entries: [fixed],
      parent: _parent.copyWith(currencyCode: 'HKD'),
      accounts: [_account('USD')],
      rates: [_rate('HKD', 0.85, DateTime(2026, 11, 1))],
      now: now,
    );
    expect(hkd.billedOutstanding, closeTo(165.80, 0.001));
    expect(hkd.dueOutstandingAmount, closeTo(165.80, 0.001));
    expect(hkd.missingConversion, isFalse);

    final missingSource = _overview(
      entries: [_expense('floating', 'USD', 21.02, cachedBase: 140.93)],
      rates: [],
      now: now,
    );
    expect(missingSource.billedOutstanding, 0);
    expect(missingSource.dueOutstandingAmount, isNull);
    expect(missingSource.missingConversion, isTrue);

    final missingTarget = _overview(
      entries: [fixed],
      parent: _parent.copyWith(currencyCode: 'HKD'),
      accounts: [_account('USD')],
      rates: [],
      now: now,
    );
    expect(missingTarget.dueOutstandingAmount, isNull);
    expect(missingTarget.missingConversion, isTrue);
  });

  test('小额部分还款按目标币种分位舍入，全额还清不留比例尾差', () {
    final original = _expense('original', 'USD', 0.03, reference: 0.20);
    final partial = _repayment('partial', 0.01, DateTime(2026, 10, 26));
    final now = DateTime(2026, 11, 2);
    final entries = [original, partial];
    final overview = _overview(entries: entries, now: now);
    expect(overview.billedOutstanding, closeTo(0.13, 0.001));
    expect(overview.dueOutstandingAmount, closeTo(0.13, 0.001));
    expect(_usdOverview(entries, now).billedOutstanding, 0.02);

    final fullyPaid = [
      ...entries,
      _repayment('remaining', 0.02, DateTime(2026, 10, 27)),
    ];
    final cleared = _overview(entries: fullyPaid, now: now);
    expect(cleared.billedOutstanding, 0);
    expect(cleared.dueOutstandingAmount, 0);
    expect(_usdOverview(fullyPaid, now).billedOutstanding, 0);
  });
}
