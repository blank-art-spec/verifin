/// 正式入口的行情来源装配；测试默认空客户端，构造阶段不访问网络。
library;

import 'market_quote.dart';
import 'tencent_quote_adapter.dart';
import 'cms_fund_quote_adapter.dart';

/// 为主应用显式装配腾讯股票和招商指定基金来源，所有渠道及构建模式一致。
///
/// 构造不联网；同步器仍须用户主动授权，逐证券采用选择和响应校验保持不变。
/// 沿用历史 [MarketQuoteClient.allowResearchSources] 标记接入固定公开来源，
/// 不把来源的 approved 改为 true，也不代表第三方使用许可已经审核。
/// [tencentTransportFactory]、[cmsTransportFactory] 和 [clock] 只供本地传输测试；
/// 不改变固定来源、请求地址或支持范围，生产入口无需传参。
MarketQuoteClient buildProductionMarketQuoteClient({
  TencentQuoteTransportFactory? tencentTransportFactory,
  CmsFundQuoteTransportFactory? cmsTransportFactory,
  DateTime Function()? clock,
}) {
  return MarketQuoteClient(
    adapters: [
      TencentQuoteAdapter(
        transportFactory: tencentTransportFactory,
        clock: clock,
      ),
      CmsFundQuoteAdapter(transportFactory: cmsTransportFactory, clock: clock),
    ],
    allowResearchSources: true,
  );
}
