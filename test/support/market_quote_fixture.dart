import 'dart:async';
import 'package:verifin/app/investments/market_quote.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'investment_fixture.dart';

/// 本地夹具适配器，绝不访问真实来源或绕过生产门禁。
class FixtureQuoteAdapter extends MarketQuoteAdapter {
  /// [respond] 可暂停响应以验证离页/关授权；[approved] 模拟评审门禁撤销。
  FixtureQuoteAdapter(
    this.respond, {
    this.approved = true,
    this.minimumInterval = const Duration(minutes: 5),
    this.support,
  });

  /// 可限定各夹具的公开身份范围，以验证多来源串行请求的授权边界。
  final bool Function(MarketQuoteRequest)? support;
  final Future<List<MarketQuote>> Function(List<MarketQuoteRequest>) respond;
  bool approved;
  final Duration minimumInterval;
  int requests = 0;
  List<MarketQuoteRequest> lastRequests = [];
  @override
  QuoteSourceCapability get capability => QuoteSourceCapability(
    '本地测试夹具',
    approved: approved,
    reviewNote: '非生产来源',
    minimumInterval: minimumInterval,
  );

  /// 测试只支持明确 AVGO 身份及本地期权 fixture，不宣称真实市场覆盖。
  @override
  bool supports(MarketQuoteRequest q) =>
      support?.call(q) ??
      (q.symbol == 'AVGO' || q.symbol.startsWith('TEST-AVGO-'));

  /// 捕获请求，确认只包含协议公开字段，返回可控的异步夹具。
  @override
  Future<List<MarketQuote>> fetch(List<MarketQuoteRequest> requests) async {
    this.requests++;
    lastRequests = requests;
    return respond(requests);
  }
}

/// 设备缓存写入失败注入，模拟当前可见报价不能假装已持久保存。
class FailingQuoteStore extends LocalKeyValueStore {
  bool failCache = false, failSettings = false;

  /// 只破坏指定设备键，不修改任何账本或 SQLite 测试数据。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (failCache && key.contains('quote_cache') ||
        failSettings && key.contains('quote_settings')) {
      throw StateError('模拟设备偏好写入失败');
    }
    await super.writeAndFlush(key, value);
  }
}

/// 模拟较慢设备写入，验证并发的开启确认不会盖过用户稍后的关闭意图。
class PausingQuoteStore extends LocalKeyValueStore {
  final release = Completer<void>();

  /// 只暂停行情偏好，缓存写入仍独立完成；不涉及真实磁盘权限或网络。
  @override
  Future<void> writeAndFlush(String key, String value) async {
    if (key.contains('quote_settings')) await release.future;
    await super.writeAndFlush(key, value);
  }
}

/// 为股票夹具构造含真实源时间的参考值，未包含持仓数量/成本/账户信息。
MarketQuote stockQuote(DateTime time, {String price = '330'}) => MarketQuote(
  securityId: avgoFixture.id,
  source: '本地测试夹具',
  currency: 'USD',
  unit: QuotePriceUnit.share,
  fetchedAt: time,
  last: price,
  lastAt: time,
);
