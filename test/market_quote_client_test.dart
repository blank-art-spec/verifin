import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/avgo_quote_probe.dart';

/// 读取 2026-10-23 的最小真实公开字段样例；单元测试从不访问网络。
Map<String, dynamic> quoteFixture(String name) =>
    jsonDecode(File('test/fixtures/investments/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('真实股价及认购认沽样例按身份解析，期权缺时间仍明确未知', () async {
    final requests = <Uri>[];
    final probe = AvgoQuoteProbe(
      transport: (uri) async {
        requests.add(uri);
        return (
          status: 200,
          json: quoteFixture(
            uri.host.contains('yahoo')
                ? 'avgo_yahoo_20261023.json'
                : 'avgo_nasdaq_20261023.json',
          ),
        );
      },
    );
    expect(requests, isEmpty);
    final result = await probe.run(now: DateTime.utc(2026, 10, 23));
    expect(result.every((r) => r.available), isTrue);
    expect(result.first.quoteTime, isNotNull);
    expect(result.first.lines.single, contains('AVGO · USD'));
    expect(result.last.quoteTime, isNull);
    expect(result.last.lines, hasLength(2));
    expect(result.last.lines.first, contains('AVGO261204C00325000'));
    expect(result.last.lines.last, contains('AVGO261204P00325000'));
    expect(requests.last.queryParameters['limit'], '20');
    expect(requests.last.queryParameters, contains('todate'));
    expect(requests.every((uri) => uri.scheme == 'https'), isTrue);
  });

  test('访问限制、空链和未来股价时间均不伪装为有效行情', () async {
    final blocked = AvgoQuoteProbe(
      transport: (_) async => (status: 401, json: null),
    );
    final denied = await blocked.run(now: DateTime.utc(2026, 10, 23));
    expect(denied.every((r) => !r.available && r.status == 401), isTrue);
    final empty = AvgoQuoteProbe(
      transport: (_) async => (
        status: 200,
        json: <String, dynamic>{
          'data': {
            'table': {'rows': null},
          },
        },
      ),
    );
    expect((await empty.run()).every((r) => !r.available), isTrue);
    final future = AvgoQuoteProbe(
      transport: (uri) async => (
        status: 200,
        json: quoteFixture(
          uri.host.contains('yahoo')
              ? 'avgo_yahoo_20261023.json'
              : 'avgo_nasdaq_20261023.json',
        ),
      ),
    );
    expect(
      (await future.run(now: DateTime.utc(2026, 1))).first.available,
      isFalse,
    );
  });

  test('错误证券、畸形结构和来源超时降级，不编造零报价', () async {
    final wrong = quoteFixture('avgo_yahoo_20261023.json');
    final chart = wrong['chart'] as Map<String, dynamic>;
    final result = chart['result'] as List;
    final item = result.first as Map<String, dynamic>;
    (item['meta'] as Map<String, dynamic>)['symbol'] = 'OTHER';
    final probe = AvgoQuoteProbe(
      transport: (_) async => (status: 200, json: wrong),
    );
    expect(
      (await probe.run()).every((r) => !r.available && r.lines.isEmpty),
      isTrue,
    );
    final timeout = AvgoQuoteProbe(
      transport: (_) async => throw const SocketException('测试网络不可用'),
    );
    expect((await timeout.run()).every((r) => !r.available), isTrue);
    expect(
      (await timeout.run()).every((r) => r.failure == AvgoProbeFailure.network),
      isTrue,
    );
    final slow = AvgoQuoteProbe(
      transport: (_) async => throw TimeoutException('测试超时'),
    );
    expect(
      (await slow.run()).every((r) => r.failure == AvgoProbeFailure.timeout),
      isTrue,
    );
    expect((await probe.run()).first.failure, AvgoProbeFailure.invalidData);
  });
}
