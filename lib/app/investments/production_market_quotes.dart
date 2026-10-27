/// 正式入口的行情来源装配；测试默认空客户端，构造阶段不访问网络。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

import 'market_quote.dart';
import 'tencent_quote_adapter.dart';

/// 判断是否可装配免账号的公开来源研究模式，返回值不代表来源获准发布。
///
/// [debugBuild] 必须是实际调试构建；[flavor] 必须为独立诊断应用 diagnostic；
/// [explicitlyEnabled] 必须来自明确的编译参数。三项缺一即关闭，避免正式包、
/// release/R8 或旧设备偏好误开启尚未核对发布使用条件的来源。
bool permitsQuoteResearch({
  required bool debugBuild,
  required String? flavor,
  required bool explicitlyEnabled,
}) => debugBuild && flavor == 'diagnostic' && explicitlyEnabled;

/// 按当前实际构建生成来源集合，无参数，返回未联网的客户端。
///
/// 只有 diagnostic debug 且带 PUBLIC_QUOTE_RESEARCH=true 时装配腾讯股票来源；
/// 正式构建保持原发布准入规则。设备偏好仅控制用户主动启停，不参与决定来源许可。
MarketQuoteClient buildProductionMarketQuoteClient() {
  final research = permitsQuoteResearch(
    debugBuild: kDebugMode,
    flavor: appFlavor,
    explicitlyEnabled: const bool.fromEnvironment('PUBLIC_QUOTE_RESEARCH'),
  );
  return MarketQuoteClient(
    adapters: research ? [TencentQuoteAdapter()] : const [],
    allowResearchSources: research,
  );
}
