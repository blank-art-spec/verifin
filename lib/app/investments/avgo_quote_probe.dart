/// 公开行情的显式单次验证；不保存报价、不接收持仓，不自动刷新。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../calendar_days.dart';
import 'investment_decimal.dart';

/// 验证失败的安全分类；不携带响应正文、设备地址或账户数据。
enum AvgoProbeFailure { network, timeout, invalidData }

/// 一个来源的验证结果。期权的未知元数据保持未知，不据抓取时间宣称实时。
class AvgoProbeResult {
  /// [lines] 仅含公开市场字段，[status] 为 HTTP 状态，[quoteTime] 是源时间而非请求时间。
  /// [failure] 区分网络、超时和字段异常；HTTP 拒绝直接保留状态，不保存异常原文。
  const AvgoProbeResult({
    required this.source,
    required this.fetchedAt,
    this.status,
    this.lines = const [],
    this.quoteTime,
    this.available = false,
    this.failure,
  });
  final String source;
  final DateTime fetchedAt;
  final int? status;
  final List<String> lines;
  final DateTime? quoteTime;
  final bool available;
  final AvgoProbeFailure? failure;
}

/// 提供测试可注入的 JSON 传输；生产只访问固定公开 HTTPS 主机。
typedef AvgoProbeTransport =
    Future<({int status, Map<String, dynamic>? json})> Function(Uri uri);

class AvgoQuoteProbe {
  /// [transport] 只用于测试/独立验证注入；构造时绝不联网。
  const AvgoQuoteProbe({this.transport});
  final AvgoProbeTransport? transport;

  /// 读取 AVGO 普通股及距今至少三十日的期权配对；只在用户点击后调用。
  Future<List<AvgoProbeResult>> run({DateTime? now}) async {
    final time = now ?? DateTime.now();
    final from = addCalendarDays(
      time.toUtc(),
      30,
    ).toIso8601String().substring(0, 10);
    final stock = Uri.https(
      'query1.finance.yahoo.com',
      '/v8/finance/chart/AVGO',
      {'interval': '1d', 'range': '5d'},
    );
    final options = Uri.https(
      'api.nasdaq.com',
      '/api/quote/AVGO/option-chain',
      {'assetclass': 'stocks', 'limit': '20', 'money': 'at', 'fromdate': from},
    );
    final boundedOptions = options.replace(
      queryParameters: {
        ...options.queryParameters,
        'todate': addCalendarDays(
          time.toUtc(),
          90,
        ).toIso8601String().substring(0, 10),
      },
    );
    return Future.wait([
      _probe(stock, false, time),
      _probe(boundedOptions, true, time),
    ]);
  }

  /// 校验身份及有限正价格，保留来源缺失字段，不把异常/空响应当零。
  Future<AvgoProbeResult> _probe(Uri uri, bool options, DateTime time) async {
    final source = options ? 'Nasdaq' : 'Yahoo Finance';
    int? status;
    try {
      final response = await (transport ?? _get)(uri);
      status = response.status;
      if (response.status != 200 || response.json == null) {
        return AvgoProbeResult(
          source: source,
          fetchedAt: time,
          status: response.status,
        );
      }
      if (!options) {
        final chart = _map(response.json!['chart']);
        final results = chart['result'] as List?;
        final meta = _map(_map(results?.firstOrNull)['meta']);
        if (meta['symbol'] != 'AVGO' ||
            meta['currency'] != 'USD' ||
            meta['instrumentType'] != 'EQUITY') {
          throw const FormatException('行情标识不一致');
        }
        final price = _number(meta['regularMarketPrice']);
        final seconds = meta['regularMarketTime'] as num?;
        final date = seconds == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                seconds.toInt() * 1000,
                isUtc: true,
              );
        if (price == null ||
            date == null ||
            date.isAfter(time.toUtc().add(const Duration(minutes: 5)))) {
          throw const FormatException('价格或报价时间不合法');
        }
        return AvgoProbeResult(
          source: source,
          fetchedAt: time,
          status: 200,
          available: true,
          quoteTime: date,
          lines: ['AVGO · USD $price'],
        );
      }
      final data = _map(response.json!['data']);
      final rows = _map(data['table'])['rows'] as List?;
      final lines = <String>[];
      final candidates = (rows ?? [])
          .whereType<Map>()
          .map((r) => Map<String, Object?>.from(r))
          .toList();
      final underlying = RegExp(
        r'\$([\d,.]+)',
      ).firstMatch(data['lastTrade']?.toString() ?? '');
      final reference = double.tryParse(
        (underlying?[1] ?? '').replaceAll(',', ''),
      );
      if (reference != null) {
        candidates.sort(
          (a, b) =>
              ((double.tryParse(a['strike']?.toString() ?? '') ??
                          double.infinity) -
                      reference)
                  .abs()
                  .compareTo(
                    ((double.tryParse(b['strike']?.toString() ?? '') ??
                                double.infinity) -
                            reference)
                        .abs(),
                  ),
        );
      }
      for (final row in candidates) {
        final match = RegExp(
          r'/avgo--(\d{6})c(\d{8})$',
          caseSensitive: false,
        ).firstMatch(row['drillDownURL'] as String? ?? '');
        if (match == null) continue;
        final strike = _number(row['strike']);
        if (strike == null ||
            InvestmentDecimal.parse(strike)
                    .moneyProduct(InvestmentDecimal.parse('1000'), 0)
                    .toDouble()
                    .toInt() !=
                int.parse(match[2]!)) {
          continue;
        }
        final expiry = DateTime.utc(
          2000 + int.parse(match[1]!.substring(0, 2)),
          int.parse(match[1]!.substring(2, 4)),
          int.parse(match[1]!.substring(4, 6)),
        );
        if (expiry.isBefore(addCalendarDays(time.toUtc(), 30))) continue;
        final pair = <String>[];
        for (final side in ['c', 'p']) {
          final bid = _number(row['${side}_Bid']),
              ask = _number(row['${side}_Ask']),
              last = _number(row['${side}_Last']);
          if (bid == null && ask == null && last == null) continue;
          // 合约身份按来源报告的到期日、行权价、两侧报价映射为 OCC 格式，非凭空列举。
          pair.add(
            'AVGO${match[1]}${side.toUpperCase()}${match[2]} · USD · ${bid ?? '—'} / ${ask ?? '—'} · ${last ?? '—'}',
          );
        }
        if (pair.length == 2) {
          lines.addAll(pair);
          break;
        }
      }
      return AvgoProbeResult(
        source: source,
        fetchedAt: time,
        status: 200,
        available: lines.length >= 2,
        lines: lines,
      );
    } catch (error) {
      // 仅保存错误类别，交由页面记录并显示；不记录可能含网络地址的异常原文。
      final failure = switch (error) {
        TimeoutException() => AvgoProbeFailure.timeout,
        SocketException() ||
        HandshakeException() ||
        HttpException() => AvgoProbeFailure.network,
        _ => AvgoProbeFailure.invalidData,
      };
      return AvgoProbeResult(
        source: source,
        fetchedAt: time,
        status: status,
        failure: failure,
      );
    }
  }

  /// 提取公开价格；缺值、非有限数或负数返回 null，零也不代表确认到期。
  static String? _number(Object? raw) {
    final parsed = num.tryParse(raw.toString().replaceAll(',', ''));
    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    return InvestmentDecimal.parse(parsed.toStringAsFixed(8)).toString();
  }

  /// 将外部 JSON 对象收窄为可空值映射，结构变化时按空对象降级。
  static Map<String, Object?> _map(Object? raw) =>
      raw is Map ? Map<String, Object?>.from(raw) : const {};

  /// 限时读取不超过 512 KiB 的 JSON，不跟随跳转、不附带 Cookie、不绕过 HTTP 拒绝。
  static Future<({int status, Map<String, dynamic>? json})> _get(
    Uri uri,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'VeriFin/1.19.9 public-data-evaluation',
        );
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        if (response.statusCode != 200) {
          return (status: response.statusCode, json: null);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 512 * 1024) {
            throw const FormatException('公开行情响应超过上限');
          }
          bytes.addAll(chunk);
        }
        return (
          status: 200,
          json: jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      })().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }
}
