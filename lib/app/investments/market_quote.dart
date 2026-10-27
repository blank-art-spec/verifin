/// 参考行情协议：证券代码及公开价格，与用户账户、持仓数量和真实成交分离。
library;

import '../models/investment.dart';
import '../../l10n/app_localizations.dart';
import 'investment_decimal.dart';

enum QuotePriceUnit { share, premiumUnit }

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

  /// 只供显式诊断构建验证的来源；不等于发布准入，也不能由设备偏好或缓存开启。
  /// 必须同时由构建工厂允许研究来源，才会参与查询及参考估值。
  final bool researchOnly;

  /// 自动轮询的最短间隔；取它与默认五分钟中更严格的一方。
  /// 用户主动刷新不受本地轮询计时限制，来源实际拒绝仍按请求失败处理。
  final Duration minimumInterval;
}

/// 传输请求只包含公开证券身份；账本/账户 ID 和数量不会传给适配器。
class MarketQuoteRequest {
  /// [security] 只提取代码、市场、原币及是否期权，不携带成本、数量或备注。
  MarketQuoteRequest(StockSecurity security)
    : securityId = security.id,
      symbol = security.symbol,
      market = security.market,
      currency = security.currencyCode,
      option = security.option != null;
  final String securityId, symbol, currency;
  final StockMarket market;
  final bool option;
}

/// 一份价格观察保留各字段时间及抓取时间；未知报价时间不得用抓取时间代替。
class MarketQuote {
  /// [last]/[bid]/[ask] 是每股或每单位权利金文本，不是总持仓值。
  /// [delayMinutes] 为来源声明的延迟，可未知；[tradeState] 未确认时保持 unknown。
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
  });
  final String securityId, source, currency;
  final QuotePriceUnit unit;
  final DateTime fetchedAt;
  final String? last, bid, ask;
  final DateTime? lastAt, bidAt, askAt;
  final int? delayMinutes;
  final QuoteTradeState tradeState;

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
                : QuotePriceUnit.share) ||
        fetchedAt.isAfter(now.add(const Duration(minutes: 5))) ||
        (delayMinutes != null && delayMinutes! < 0)) {
      return null;
    }

    /// [time] 必须来自报价字段，不能明显晚于当前或抓取时间。
    bool validTime(DateTime? time) =>
        time != null &&
        !time.isAfter(now.add(const Duration(minutes: 5))) &&
        !time.isAfter(fetchedAt.add(const Duration(minutes: 5)));

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

  /// 仅用于设备缓存，不进入完整账目备份；没有任何用户持仓字段。
  Map<String, Object?> toJson() => {
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
  };

  /// 从设备缓存恢复；字段仍须通过 reference 与当前来源准入门禁，缓存不是授权来源。
  factory MarketQuote.fromJson(Map<String, Object?> json) {
    DateTime? time(String key) =>
        json[key] == null ? null : DateTime.parse(json[key] as String);
    return MarketQuote(
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
    );
  }
}

/// 一个固定主机来源适配器；生产实现必须限制单次15秒/512KiB、不绕过拒绝和跳转。
abstract class MarketQuoteAdapter {
  QuoteSourceCapability get capability;

  /// 判断明确的证券/品种覆盖，不用“支持美股”笼统替代真实覆盖。
  bool supports(MarketQuoteRequest request);

  /// 获取不超过20个公开身份；实现不得读取 Controller 或用户账目。
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests);
}

/// 来源分发器；正式来源须评审，研究来源另受独立诊断构建限制，设备开关不能替代。
class MarketQuoteClient {
  /// [adapters] 是代码注入的来源；默认空集合，构造及通用测试不会访问网络。
  /// [allowResearchSources] 仅由独立 diagnostic 调试构建的显式参数启用，
  /// 不写入设备偏好，不把研究来源的 [QuoteSourceCapability.approved] 改成 true。
  const MarketQuoteClient({
    this.adapters = const [],
    this.allowResearchSources = false,
  });
  final List<MarketQuoteAdapter> adapters;
  final bool allowResearchSources;

  /// 判断 [adapter] 能否在本构建使用：正式准入，或显式诊断构建中的研究来源。
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

  /// 本构建是否有可用来源；正式构建仍只接受 approved，不受旧设备开关影响。
  bool get hasAvailableSources => adapters.any(allowsAdapter);

  /// 当前是否启用了未获发布准入的诊断来源，供界面明确标示验证范围。
  bool get hasResearchSources =>
      allowResearchSources &&
      adapters.any((a) => a.capability.researchOnly && !a.capability.approved);
}
