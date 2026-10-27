import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/app/models.dart';

import 'market_quote_fixture.dart';

/// 本地研究夹具的来源身份，供协议和页面检查共用，不代表正式发布许可。
const researchFixtureSourceId = 'Tencent Finance';

/// 只返回调用方指定数据的研究适配器，不进行 HTTP 请求，也不伪造正式准入。
class ResearchFixtureQuoteAdapter extends FixtureQuoteAdapter {
  /// [respond] 提供本地确定性响应；[researchOnly] 为 false 时表示普通待审核来源，
  /// 用于确认允许诊断研究不会把其他未通过审核的来源一并放开。
  ResearchFixtureQuoteAdapter(super.respond, {this.researchOnly = true})
    : super(approved: false);

  final bool researchOnly;

  /// 返回独立的研究状态，即使夹具可用，approved 也始终保持 false。
  @override
  QuoteSourceCapability get capability => QuoteSourceCapability(
    researchFixtureSourceId,
    approved: false,
    researchOnly: researchOnly,
    reviewNote: '仅本地研究夹具，不访问腾讯或其他真实接口',
  );

  /// [request] 只接受这些用例使用的两只股票，期权与 TEST 合约始终不受支持。
  @override
  bool supports(MarketQuoteRequest request) =>
      !request.option &&
      ((request.symbol == 'AVGO' &&
              request.market == StockMarket.us &&
              request.currency == 'USD') ||
          (request.symbol == '00700' &&
              request.market == StockMarket.hk &&
              request.currency == 'HKD'));
}
