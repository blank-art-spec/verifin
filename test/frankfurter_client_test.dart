import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/frankfurter_client.dart';
import 'package:verifin/app/models/currency.dart';
import 'package:verifin/app/timezone_database.dart';

/// 读取本轮真实 USD/CNY 响应，不联网；变体测试只在各自副本中改字段。
Map<String, Object?> _fixture() =>
    jsonDecode(
          File(
            'test/fixtures/frankfurter/usd_cny_20261109.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

/// 仅返回预设 JSON 的本地响应，沿用 Stream 订阅与取消语义。
class _Response extends Stream<List<int>> implements HttpClientResponse {
  /// [payload] 是本例响应对象；统一模拟 HTTP 200，不访问真实网络。
  _Response(Map<String, Object?> payload)
    : bytes = utf8.encode(jsonEncode(payload));

  final List<int> bytes;
  @override
  final int statusCode = 200;

  /// 将唯一响应块交给 [onData]，其他参数按 Stream.listen 原样传递。
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// 未使用的响应能力不模拟，防止测试意外掩盖新增 HTTP 行为。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 在 close 时提供单个预设响应，不进行额外请求或自动重试。
class _Request implements HttpClientRequest {
  /// [response] 是本例唯一响应，由内存客户端创建。
  _Request(this.response);

  final _Response response;

  /// 结束当前内存请求并交付响应，模拟实际请求发送完成后的等待结果。
  @override
  Future<HttpClientResponse> close() async => response;

  /// 未使用的请求能力保持未实现，所有行为必须由生产客户端显式调用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 捕获实际 GET 地址并记录关闭状态的离线 HTTP 客户端。
class _Client implements HttpClient {
  /// [payload] 为各请求返回的测试 JSON；本文件每个客户端只用于一轮查询。
  _Client(this.payload);

  final Map<String, Object?> payload;
  final uris = <Uri>[];
  bool forceClosed = false;
  @override
  Duration? connectionTimeout;

  /// 记录 [uri] 的完整公开参数，再返回当前用例的固定响应。
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    uris.add(uri);
    return _Request(_Response(payload));
  }

  /// [force] 记录生产 finally 是否强制释放连接，不触碰系统网络状态。
  @override
  void close({bool force = false}) => forceClosed = force;

  /// 只提供测试会用到的 HTTP 功能，意外的新访问应暴露为测试错误。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 注入本例 [client] 和真实瞬间 [now]，避免依赖运行机器的当前时间或网络。
FrankfurterClient _subject(_Client client, DateTime now) =>
    FrankfurterClient(clientFactory: () => client, clock: () => now);

/// 用 [date] 替换真实响应的来源日；其余字段沿用原始观察，不声称变体是真实汇率。
Map<String, Object?> _dated(Object? date) => _fixture()..['date'] = date;

/// 注册跨时区日历日、严格日期及历史上界检查；不运行 Android 或访问真实服务。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTimezoneDatabase);

  test('真实来源日不因当前瞬间在西侧时区仍属前一天而被拒绝', () async {
    final instant = DateTime.utc(2026, 11, 9, 7, 16);
    final losAngeles = tz.TZDateTime.from(
      instant,
      tz.getLocation('America/Los_Angeles'),
    );
    expect(currencyDateKey(losAngeles), '2026-11-08');
    // 明确展示旧比较的误判：来源日已经公布，但把它补成洛杉矶零点会晚于当前瞬间。
    final localSourceMidnight = tz.TZDateTime(
      tz.getLocation('America/Los_Angeles'),
      2026,
      11,
      9,
    );
    expect(localSourceMidnight.isAfter(instant), isTrue);
    for (final now in [
      instant,
      losAngeles,
      tz.TZDateTime.from(instant, tz.getLocation('Asia/Shanghai')),
    ]) {
      final client = _Client(_fixture());
      final result = await _subject(
        client,
        now,
      ).fetch(base: 'CNY', currencies: {'USD', 'CNY'});
      final observation = result.single;
      expect(observation.currency, 'USD');
      expect(observation.rate, 6.6642);
      expect(observation.date, DateTime(2026, 11, 9));
      expect(observation.date.isUtc, isFalse);
      expect(currencyDateKey(observation.date), '2026-11-09');
      expect(
        client.uris.single.toString(),
        'https://api.frankfurter.dev/v2/rate/usd/cny',
      );
      expect(client.forceClosed, isTrue);
    }
  });

  test('全球最早时区刚进入来源日才允许，不把下一日提前变成已发生日', () async {
    for (final now in [
      DateTime.utc(2026, 11, 8, 9, 59, 59),
      DateTime.utc(2026, 11, 8, 10),
    ]) {
      final client = _Client(_fixture());
      final pending = _subject(
        client,
        now,
      ).fetch(base: 'CNY', currencies: {'USD'});
      if (now.hour == 9) {
        await expectLater(pending, throwsFormatException);
      } else {
        expect((await pending).single.date, DateTime(2026, 11, 9));
      }
      expect(client.forceClosed, isTrue);
    }
    final future = _Client(_dated('2026-11-10'));
    await expectLater(
      _subject(
        future,
        DateTime.utc(2026, 11, 9, 7),
      ).fetch(base: 'CNY', currencies: {'USD'}),
      throwsFormatException,
    );
    expect(future.forceClosed, isTrue);
  });

  test('历史请求保留原年月日，并只接纳请求日或更早的来源观察', () async {
    final requested = DateTime.utc(2026, 11, 7, 23, 59);
    for (final responseDate in ['2026-11-06', '2026-11-07', '2026-11-08']) {
      final client = _Client(_dated(responseDate));
      final pending = _subject(
        client,
        DateTime.utc(2026, 11, 9, 7),
      ).fetch(base: 'CNY', currencies: {'USD'}, date: requested);
      if (responseDate == '2026-11-08') {
        await expectLater(pending, throwsFormatException);
      } else {
        expect(currencyDateKey((await pending).single.date), responseDate);
      }
      expect(client.uris.single.queryParameters, {'date': '2026-11-07'});
      expect(client.forceClosed, isTrue);
    }
  });

  test('日期严格要求真实 YYYY-MM-DD，不接纳溢出、时间戳或隐式归一', () async {
    for (final invalid in <Object?>[
      null,
      20261109,
      '',
      '2026-11-9',
      '20261109',
      ' 2026-11-09',
      '2026-11-09 ',
      '2026-11-09T00:00:00Z',
      '2026-02-29',
      '2026-02-30',
      '2026-13-01',
      '2026-00-01',
      '2026-11-00',
      '2026-11-31',
      '0000-01-01',
    ]) {
      final client = _Client(_dated(invalid));
      await expectLater(
        _subject(
          client,
          DateTime.utc(2026, 11, 10),
        ).fetch(base: 'CNY', currencies: {'USD'}),
        throwsFormatException,
        reason: '$invalid',
      );
      expect(client.forceClosed, isTrue);
    }
    final leap = _Client(_dated('2024-02-29'));
    final result = await _subject(
      leap,
      DateTime.utc(2026, 11, 10),
    ).fetch(base: 'CNY', currencies: {'USD'});
    expect(result.single.date, DateTime(2024, 2, 29));
    expect(leap.forceClosed, isTrue);
  });

  test('接受跨时区观察仍保留原生效日，下游不会提前采用较晚日期', () async {
    final client = _Client(_fixture());
    final observation = (await _subject(
      client,
      DateTime.utc(2026, 11, 9, 7),
    ).fetch(base: 'CNY', currencies: {'USD'})).single;
    final rate = ExchangeRate(
      id: '公开参考汇率测试',
      bookId: 'book',
      baseCurrencyCode: 'CNY',
      currencyCode: observation.currency,
      effectiveDate: observation.date,
      rateToBase: observation.rate,
      source: ExchangeRateSource.online,
      createdAt: DateTime(2026, 11, 8),
      updatedAt: DateTime(2026, 11, 8),
    );
    expect(rate.toJson()['effectiveDate'], '2026-11-09');
    expect(
      ExchangeRate.fromJson(rate.toJson()).effectiveDate,
      observation.date,
    );
    expect(
      exchangeRateAt(
        bookId: 'book',
        baseCurrencyCode: 'CNY',
        currencyCode: 'USD',
        date: DateTime(2026, 11, 8),
        rates: [rate],
      ),
      isNull,
    );
    expect(
      exchangeRateAt(
        bookId: 'book',
        baseCurrencyCode: 'CNY',
        currencyCode: 'USD',
        date: DateTime(2026, 11, 9),
        rates: [rate],
      ),
      same(rate),
    );
  });

  test('日期修复仍拒绝错误币对和非正汇率，默认 const 构造保持可用', () async {
    expect(const FrankfurterClient(), isA<FrankfurterClient>());
    for (final payload in [
      _fixture()..['base'] = 'EUR',
      _fixture()..['quote'] = 'JPY',
      _fixture()..['rate'] = 0,
      _fixture()..['rate'] = -1,
    ]) {
      final client = _Client(payload);
      await expectLater(
        _subject(
          client,
          DateTime.utc(2026, 11, 9, 7),
        ).fetch(base: 'CNY', currencies: {'USD'}),
        throwsFormatException,
      );
      expect(client.forceClosed, isTrue);
    }
  });
}
