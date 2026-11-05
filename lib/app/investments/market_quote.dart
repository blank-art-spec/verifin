/// 参考行情协议：证券代码及公开价格，与用户账户、持仓数量和真实成交分离。
library;

import '../models/investment.dart';
import '../models/option_contract.dart';
import '../../l10n/app_localizations.dart';
import 'investment_decimal.dart';
import 'us_option_symbol.dart';

enum QuotePriceUnit { share, premiumUnit, fundUnit }

enum QuoteTradeState {
  unknown,
  open,
  closed,
  halted;

  /// 显示来源明确声明的交易状态；不根据本机时间猜交易所开收盘。
  String label(AppLocalizations l) => switch (this) {
    unknown => l.marketStateUnknown,
    open => l.marketOpen,
    closed => l.marketClosed,
    halted => l.marketHalted,
  };
}

/// 来源准入事实；代码能联网不代表允许自动估值，须同时核对字段及使用条件。
class QuoteSourceCapability {
  /// [approved] 是代码评审后的门禁，不从缓存、用户输入或网页响应接受授权标记。
  const QuoteSourceCapability(
    this.id, {
    required this.approved,
    required this.reviewNote,
    this.researchOnly = false,
    this.minimumInterval = const Duration(minutes: 5),
  });
  final String id, reviewNote;
  final bool approved;

  /// 历史命名：标记由工厂显式接入的公开来源，不再表示仅限诊断构建。
  /// 必须同时由客户端允许此类来源才参与查询及参考估值；不等于使用许可已审核，
  /// 也不能由设备偏好、缓存或网络响应改变。
  final bool researchOnly;

  /// 自动轮询的最短间隔；取它与默认五分钟中更严格的一方。
  /// 用户主动刷新不受本地轮询计时限制，来源实际拒绝仍按请求失败处理。
  final Duration minimumInterval;
}

/// 传输请求只包含公开证券身份；账本/账户 ID 和数量不会传给适配器。
class MarketQuoteRequest {
  /// [security] 只提取代码、市场、原币及品种；期权额外提取公开合约身份。
  /// 不携带数量、成本、交割说明或其他用户备注，来源不能从这些字段得到持仓信息。
  MarketQuoteRequest(StockSecurity security)
    : securityId = security.id,
      symbol = security.symbol,
      market = security.market,
      currency = security.currencyCode,
      option = security.option != null,
      fund = security.isFund,
      optionExpiry = security.option?.expiry,
      optionRight = security.option?.right,
      optionStrike = security.option?.strike,
      optionUnderlyingSymbol =
          security.option?.underlyingId.startsWith('us:stock:') == true
          ? security.option!.underlyingId.substring('us:stock:'.length)
          : null;

  /// 未保存的美股期权只从完整代码提取公开身份，不创建证券或猜测交割乘数。
  /// 输入统一为大写；非标准、TEST 或无效日期/行权价抛出 FormatException。
  factory MarketQuoteRequest.usOptionSymbol(String symbol) {
    final normalized = symbol.trim().toUpperCase();
    final identity = parseUsOptionSymbol(normalized);
    if (identity == null) throw const FormatException('无法识别完整美股期权代码');
    final thousand = BigInt.from(1000);
    final whole = identity.strikeThousandths ~/ thousand;
    final fraction = (identity.strikeThousandths % thousand).toString().padLeft(
      3,
      '0',
    );
    return MarketQuoteRequest._usOption(
      normalized,
      underlyingSymbol: identity.underlyingSymbol,
      expiry: identity.expiry,
      right: identity.right,
      strike: InvestmentDecimal.parse('$whole.$fraction').toString(),
    );
  }

  MarketQuoteRequest._usOption(
    this.symbol, {
    required String underlyingSymbol,
    required String expiry,
    required OptionRight right,
    required String strike,
  }) : securityId = 'us:option:$symbol',
       market = StockMarket.us,
       currency = 'USD',
       option = true,
       fund = false,
       optionUnderlyingSymbol = underlyingSymbol,
       optionExpiry = expiry,
       optionRight = right,
       optionStrike = strike;
  final String securityId, symbol, currency;
  final StockMarket market;
  final bool option, fund;
  final String? optionExpiry, optionStrike, optionUnderlyingSymbol;
  final OptionRight? optionRight;
}

/// 草稿查询只返回本次观察，不创建持仓、保存缓存或开启自动行情。
enum DraftOptionQuoteStatus {
  available,
  networkDisabled,
  credentialsRequired,
  unsupported,
  noQuote,
  failed,
  cancelled,
}

class DraftOptionQuoteResult {
  const DraftOptionQuoteResult(this.status, {this.quote})
    : assert((status == DraftOptionQuoteStatus.available) == (quote != null));

  final DraftOptionQuoteStatus status;
  final MarketQuote? quote;
}

/// 一条公开基金净值观察；只有日期和每份净值，没有持仓、收益流水或账户信息。
class FundNavPoint {
  /// [date] 为 UTC 零点承载的来源公历日，[price] 保留来源的正数净值文本和尾随零。
  /// 单点可便捷构造；放入 [FundNavHistory] 或序列化时统一验证精度和纯日期约束。
  const FundNavPoint({required this.date, required this.price});

  final DateTime date;
  final String price;

  /// 保存只读缓存字段；日期字符串仅为存储格式，不是给用户拼接的显示文案。
  Map<String, Object?> toJson() {
    _validateFundNavPoint(this);
    return {'date': date.toIso8601String().substring(0, 10), 'price': price};
  }

  /// 严格恢复一个日期/净值对象；[json] 来自设备缓存，不接受 DateTime 的溢出归一。
  /// YYYY-MM-DD 只有日精度，解析成 UTC 年月日不代表来源于零点发布净值。
  factory FundNavPoint.fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        json['date'] is! String ||
        json['price'] is! String) {
      throw const FormatException('基金净值历史点缺少有效的日期或数字文本');
    }
    final text = json['date']! as String;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
      throw const FormatException('基金净值历史日期格式不合法');
    }
    final year = int.parse(text.substring(0, 4));
    final month = int.parse(text.substring(5, 7));
    final day = int.parse(text.substring(8, 10));
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw const FormatException('基金净值历史日期不是有效公历日');
    }
    final point = FundNavPoint(date: date, price: json['price']! as String);
    _validateFundNavPoint(point);
    return point;
  }
}

/// 一份有界、严格升序且不可变的公开净值历史，只进入设备参考缓存。
class FundNavHistory {
  /// [points] 按来源日期升序排列，不允许空、重复或非法净值；最多接受 4096 点。
  /// 只读取上限加一条，避免错误 Iterable 在验证前无界增长；不截断后假装历史完整。
  FundNavHistory(Iterable<FundNavPoint> points)
    : points = List<FundNavPoint>.unmodifiable(points.take(maximumPoints + 1)) {
    if (this.points.isEmpty || this.points.length > maximumPoints) {
      throw const FormatException('基金净值历史为空或超过四千零九十六点上限');
    }
    DateTime? previous;
    for (final point in this.points) {
      _validateFundNavPoint(point);
      if (previous != null && !point.date.isAfter(previous)) {
        throw const FormatException('基金净值历史日期重复或未严格升序');
      }
      previous = point.date;
    }
  }

  static const maximumPoints = 4096;
  final List<FundNavPoint> points;

  /// 保存已经验证的公开点序列，不复制其他份额，不改写净值尾零，也不生成收入数据。
  List<Map<String, Object?>> toJson() => [
    for (final point in points) point.toJson(),
  ];

  /// 从有界缓存数组恢复历史；[json] 不是数组或超限时先拒绝，不创建超大对象序列。
  factory FundNavHistory.fromJson(Object? json) {
    if (json is! List<Object?> || json.isEmpty || json.length > maximumPoints) {
      throw const FormatException('基金净值历史缓存不是允许长度的数组');
    }
    return FundNavHistory(json.map(FundNavPoint.fromJson));
  }
}

/// 验证单点的 UTC 纯日期及正精确净值；[point] 可来自构造或反序列化，不接受假零。
void _validateFundNavPoint(FundNavPoint point) {
  if (!isCanonicalQuoteDate(point.date) ||
      point.date.year < 1900 ||
      point.date.year > 9999) {
    throw const FormatException('基金净值历史点必须使用有效的 UTC 纯日期');
  }
  _fundNavNumber(point.price);
}

/// 将 [price] 作为来源原始净值文本验证；不接受空格、指数、零、负数或超精度。
/// 返回八位定点数只用于精确比较，缓存和界面仍保留原始字符串的尾随零。
InvestmentDecimal _fundNavNumber(String price) {
  if (!RegExp(r'^\d{1,12}(\.\d{1,8})?$').hasMatch(price)) {
    throw const FormatException('基金净值历史点必须使用支持精度的正数字文本');
  }
  final number = InvestmentDecimal.parse(price);
  if (number.units <= BigInt.zero) {
    throw const FormatException('基金净值历史点必须使用支持精度的正数字文本');
  }
  return number;
}

/// 一份价格观察保留各字段时间及抓取时间；未知报价时间不得用抓取时间代替。
class MarketQuote {
  /// [last]/[bid]/[ask] 是每股或每单位权利金文本，不是总持仓值。
  /// [delayMinutes] 为来源声明的延迟，可未知；[tradeState] 未确认时保持 unknown。
  /// [dateOnly] 表示来源只给净值日期；[lastAt] 须以 UTC 年月日承载该日期，
  /// 零点只属于序列化格式，界面和历史依据不得将其显示为实际报价时刻。
  /// [navHistory] 为同一基金份额的公开净值历史，只参与参考计算与设备缓存，
  /// 不能进入交易表、自动收入或由当前估值冒充的历史账目快照。
  const MarketQuote({
    required this.securityId,
    required this.source,
    required this.currency,
    required this.unit,
    required this.fetchedAt,
    this.last,
    this.bid,
    this.ask,
    this.lastAt,
    this.bidAt,
    this.askAt,
    this.delayMinutes,
    this.tradeState = QuoteTradeState.unknown,
    this.dateOnly = false,
    this.navHistory,
  });
  final String securityId, source, currency;
  final QuotePriceUnit unit;
  final DateTime fetchedAt;
  final String? last, bid, ask;
  final DateTime? lastAt, bidAt, askAt;
  final int? delayMinutes;
  final QuoteTradeState tradeState;
  final bool dateOnly;
  final FundNavHistory? navHistory;

  /// 对有效股票/期权报价显示超过二十四小时的事实提示，不推断交易所状态。
  /// 休市期间也可能出现旧报价；提示不改变采用规则，基金日净值不使用此阈值。
  bool isOlderThanOneDay(MarketQuoteRequest request, DateTime now) {
    if (request.fund || dateOnly) return false;
    final value = reference(request, now);
    return value != null &&
        now.difference(value.time) > const Duration(hours: 24);
  }

  /// 校验身份、单位和字段时间；期权优先有效双边中间值，否则用带时间的正成交价。
  /// 不将零/负数、时间未知、明显未来时间或抓取成功自动解释成有效估值。
  ({String price, DateTime time, bool midpoint})? reference(
    MarketQuoteRequest request,
    DateTime now,
  ) {
    if (securityId != request.securityId ||
        currency != request.currency ||
        unit !=
            (request.option
                ? QuotePriceUnit.premiumUnit
                : request.fund
                ? QuotePriceUnit.fundUnit
                : QuotePriceUnit.share) ||
        fetchedAt.isAfter(now.add(const Duration(minutes: 5))) ||
        (delayMinutes != null && delayMinutes! < 0) ||
        (navHistory != null &&
            (!request.fund || request.option || !_hasValidFundHistory(now))) ||
        (dateOnly &&
            (!request.fund ||
                request.option ||
                request.market != StockMarket.hk ||
                bid != null ||
                ask != null ||
                lastAt == null ||
                !isCanonicalQuoteDate(lastAt!)))) {
      return null;
    }

    /// [time] 必须来自报价字段，不能明显晚于当前或抓取时间。
    bool validTime(DateTime? time) {
      if (time == null) return false;
      if (dateOnly) {
        return isHongKongQuoteDateAtOrBefore(time, now) &&
            isHongKongQuoteDateAtOrBefore(time, fetchedAt);
      }
      return !time.isAfter(now.add(const Duration(minutes: 5))) &&
          !time.isAfter(fetchedAt.add(const Duration(minutes: 5)));
    }

    /// 缺字段返回 null；非法精度/非有限数交由外层降级，不生成零价。
    InvestmentDecimal? number(String? text) {
      if (text == null) return null;
      final value = InvestmentDecimal.parse(text);
      return value.units < BigInt.zero ? null : value;
    }

    try {
      final b = number(bid), a = number(ask), l = number(last);
      if (request.option &&
          b != null &&
          a != null &&
          b.units > BigInt.zero &&
          a.units > BigInt.zero &&
          b.compareTo(a) <= 0 &&
          validTime(bidAt) &&
          validTime(askAt)) {
        final middle = (b + a).allocated(
          InvestmentDecimal.parse('1'),
          InvestmentDecimal.parse('2'),
          8,
        );
        return (
          price: middle.toString(),
          time: bidAt!.isBefore(askAt!) ? bidAt! : askAt!,
          midpoint: true,
        );
      }
      if (l != null && l.units > BigInt.zero && validTime(lastAt)) {
        return (price: l.toString(), time: lastAt!, midpoint: false);
      }
    } on FormatException {
      // 单个来源字段无效即不可估值；保留手填/旧缓存，错误由同步层反馈。
    }
    return null;
  }

  /// 核对历史与当前观察的品种、单位、源日期和末点；[instant] 为允许的真实当前时刻。
  /// 构造时已保证所有点严格升序，因此末点不晚于抓取日和当前日即可排除全部未来点。
  bool _hasValidFundHistory(DateTime instant) {
    final history = navHistory;
    if (history == null) return true;
    if (!dateOnly ||
        unit != QuotePriceUnit.fundUnit ||
        lastAt == null ||
        last == null ||
        bid != null ||
        ask != null ||
        !isCanonicalQuoteDate(lastAt!)) {
      return false;
    }
    final tail = history.points.last;
    if (tail.date != lastAt ||
        !isHongKongQuoteDateAtOrBefore(tail.date, fetchedAt) ||
        !isHongKongQuoteDateAtOrBefore(tail.date, instant)) {
      return false;
    }
    try {
      return _fundNavNumber(tail.price).compareTo(_fundNavNumber(last!)) == 0;
    } on FormatException {
      // 损坏的最新净值不能被完整历史掩盖，调用方保留原有手填依据和旧缓存。
      return false;
    }
  }

  /// 仅用于设备缓存，不进入完整账目备份；没有任何用户持仓字段。
  Map<String, Object?> toJson() {
    if (!_hasValidFundHistory(fetchedAt)) {
      throw const FormatException('基金净值历史与报价单位、日期或末点不一致');
    }
    return {
      'securityId': securityId,
      'source': source,
      'currency': currency,
      'unit': unit.name,
      'fetchedAt': fetchedAt.toIso8601String(),
      'last': last,
      'bid': bid,
      'ask': ask,
      'lastAt': lastAt?.toIso8601String(),
      'bidAt': bidAt?.toIso8601String(),
      'askAt': askAt?.toIso8601String(),
      'delayMinutes': delayMinutes,
      'tradeState': tradeState.name,
      if (dateOnly) 'dateOnly': true,
      if (navHistory != null) 'navHistory': navHistory!.toJson(),
    };
  }

  /// 从设备缓存恢复；字段仍须通过 reference 与当前来源准入门禁，缓存不是授权来源。
  factory MarketQuote.fromJson(Map<String, Object?> json) {
    /// [key] 是原有时间字段名；带历史的纯日报价还会核对规范 UTC 存储格式及末点。
    DateTime? time(String key) =>
        json[key] == null ? null : DateTime.parse(json[key] as String);
    final quote = MarketQuote(
      securityId: json['securityId'] as String,
      source: json['source'] as String,
      currency: json['currency'] as String,
      unit: QuotePriceUnit.values.byName(json['unit'] as String),
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      last: json['last'] as String?,
      bid: json['bid'] as String?,
      ask: json['ask'] as String?,
      lastAt: time('lastAt'),
      bidAt: time('bidAt'),
      askAt: time('askAt'),
      delayMinutes: json['delayMinutes'] as int?,
      tradeState: QuoteTradeState.values.byName(json['tradeState'] as String),
      dateOnly: json['dateOnly'] as bool? ?? false,
      navHistory: json['navHistory'] == null
          ? null
          : FundNavHistory.fromJson(json['navHistory']),
    );
    if (!quote._hasValidFundHistory(quote.fetchedAt) ||
        (quote.navHistory != null &&
            json['lastAt'] != quote.lastAt?.toIso8601String())) {
      throw const FormatException('基金净值历史缓存与报价日期或末点不一致');
    }
    return quote;
  }
}

/// 判断 [date] 是否为规范的纯日期载体，拒绝带本地时区或隐藏时分秒的假日期精度。
/// 此 UTC 零点仅用于排序与存储年月日，不代表来源实际公布时刻。
bool isCanonicalQuoteDate(DateTime date) =>
    date.isUtc &&
    date.hour == 0 &&
    date.minute == 0 &&
    date.second == 0 &&
    date.millisecond == 0 &&
    date.microsecond == 0;

/// 判断香港来源的净值日期 [date] 是否不晚于真实时刻 [instant] 在香港的日期。
/// 香港全年 UTC+8，不采用设备时区；这里比较日历日期，不声称来源在零点发布净值。
bool isHongKongQuoteDateAtOrBefore(DateTime date, DateTime instant) {
  if (!isCanonicalQuoteDate(date)) return false;
  final hk = instant.toUtc().add(const Duration(hours: 8));
  return !date.isAfter(DateTime.utc(hk.year, hk.month, hk.day));
}

/// 一个固定主机来源适配器；生产实现必须限制单次15秒/512KiB、不绕过拒绝和跳转。
abstract class MarketQuoteAdapter {
  QuoteSourceCapability get capability;

  /// 判断明确的证券/品种覆盖，不用“支持美股”笼统替代真实覆盖。
  bool supports(MarketQuoteRequest request);

  /// 获取不超过20个公开身份；实现不得读取 Controller 或用户账目。
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests);
}

/// 来源分发器；通用入口默认空来源，主应用工厂显式接入固定公开来源。
class MarketQuoteClient {
  /// [adapters] 是代码注入的来源；默认空集合，构造及通用测试不会访问网络。
  /// [allowResearchSources] 是历史命名，由工厂代码显式允许 researchOnly 来源，
  /// 不受构建渠道限制、不写入设备偏好，也不将来源的 approved 改成 true。
  const MarketQuoteClient({
    this.adapters = const [],
    this.allowResearchSources = false,
  });
  final List<MarketQuoteAdapter> adapters;
  final bool allowResearchSources;

  /// 判断 [adapter] 能否由此客户端使用：已审核，或由代码显式接入的公开来源。
  /// 同步、缓存恢复和页面开关共用此判断，避免仅放开界面却绕过请求/缓存校验。
  bool allowsAdapter(MarketQuoteAdapter adapter) =>
      adapter.capability.approved ||
      (allowResearchSources && adapter.capability.researchOnly);

  /// 返回本构建允许且明确覆盖该证券的适配器；不提供任意主机的用户覆盖入口。
  MarketQuoteAdapter? adapterFor(MarketQuoteRequest request) => adapters
      .where((a) => allowsAdapter(a) && a.supports(request))
      .firstOrNull;

  /// 有通过来源门禁的代码适配器时才允许用户启用联网。
  bool get hasApprovedSources => adapters.any((a) => a.capability.approved);

  /// 此客户端是否有可用来源；空客户端不能靠旧设备开关或缓存获得来源。
  bool get hasAvailableSources => adapters.any(allowsAdapter);

  /// 历史命名：当前是否接入了尚未声明 approved 的公开来源，供界面说明覆盖范围。
  bool get hasResearchSources =>
      allowResearchSources &&
      adapters.any((a) => a.capability.researchOnly && !a.capability.approved);
}
