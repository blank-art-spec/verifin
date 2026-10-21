import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/reminder/china_workday_calendar.dart';
import 'package:verifin/app/reminder/workday_calendar_client.dart';
import 'package:verifin/app/reminder/workday_calendar_sync.dart';

import 'support/workday_calendar_fixture.dart';

/// 使用真实年度文件校验数据协议和受限网络路径；由用户手动运行，不访问公网。
void main() {
  test('真实 2026 年样例与人工核对的内置日历全年口径一致', () {
    final doc = HolidayCalendarDocument.parse(
      workdayCalendarFixture(),
      expectedYear: 2026,
    )!;
    final calendar = WorkdayCalendarSettings(documents: {2026: doc}).calendar;
    for (var day = 1; day <= 365; day++) {
      final date = DateTime.utc(2026, 1, day);
      expect(
        calendar.isWorkday(date),
        mainlandChinaWorkdayCalendar.isWorkday(date),
        reason: '$date',
      );
    }
    expect(doc.days.length, 39);
    expect(doc.papers.single, startsWith('https://www.gov.cn/'));
    expect(
      HolidayCalendarDocument.parse(doc.toJson(), expectedYear: 2026)!.toJson(),
      doc.toJson(),
    );
  });

  test('真实 2027 年空占位不是完整日历', () {
    final json = jsonDecode(
      File('test/fixtures/holiday_cn/2027_unpublished.json').readAsStringSync(),
    );
    expect(HolidayCalendarDocument.parse(json, expectedYear: 2027), isNull);
  });

  test('错误年份、无效日期、重复、来源错误和缺少整类节日均拒绝', () {
    final badInputs = <Map<String, Object?>>[];
    final wrongYear = workdayCalendarFixture()..['year'] = '2026';
    badInputs.add(wrongYear);
    for (final date in ['2026-02-30', '2027-01-01', '2026-1-01']) {
      final json = workdayCalendarFixture();
      ((json['days']! as List).first as Map<String, Object?>)['date'] = date;
      badInputs.add(json);
    }
    final duplicate = workdayCalendarFixture();
    (duplicate['days']! as List).add((duplicate['days']! as List).first);
    badInputs.add(duplicate);
    for (final source in [
      'http://www.gov.cn/zhengce/test.htm',
      'https://gov.cn.example.com/zhengce/test.htm',
    ]) {
      badInputs.add(workdayCalendarFixture()..['papers'] = [source]);
    }
    final incomplete = workdayCalendarFixture();
    (incomplete['days']! as List).removeWhere(
      (item) => (item as Map)['name'] == '端午节',
    );
    badInputs.add(incomplete);
    final badFlag = workdayCalendarFixture();
    ((badFlag['days']! as List).first as Map<String, Object?>)['isOffDay'] =
        'true';
    badInputs.add(badFlag);
    for (final json in badInputs) {
      expect(
        () => HolidayCalendarDocument.parse(json, expectedYear: 2026),
        throwsFormatException,
      );
    }
  });

  test('合并中秋国庆节名可接受；下一年对上一年十二月的修订不会伪造其他年份覆盖', () {
    final combined = workdayCalendarFixture();
    for (final item
        in (combined['days']! as List).cast<Map<String, Object?>>()) {
      if (item['name'] == '中秋节' || item['name'] == '国庆节') {
        item['name'] = '中秋节、国庆节';
      }
    }
    expect(
      HolidayCalendarDocument.parse(combined, expectedYear: 2026),
      isNotNull,
    );
    // 隔离测试修订，明确不代表真实 2027 年安排。
    final future = workdayCalendarFixtureForYear(2027);
    (future['days']! as List).add({
      'name': '元旦',
      'date': '2026-12-31',
      'isOffDay': true,
    });
    final doc = HolidayCalendarDocument.parse(future, expectedYear: 2027)!;
    final calendar = WorkdayCalendarSettings(documents: {2027: doc}).calendar;
    expect(calendar.isWorkday(DateTime(2026, 12, 31)), isFalse);
    expect(calendar.supportedYears, [2026, 2027]);
    expect(calendar.isWorkday(DateTime(2025, 12, 31)), isNull);
  });

  test('只请求年份路径；CDN 失败会尝试 GitHub 原始文件', () async {
    final requests = <Uri>[];
    final client = HolidayCalendarClient(
      transport: (uri) async {
        requests.add(uri);
        if (uri.host == 'cdn.jsdelivr.net') {
          throw const SocketException('隔离网络失败');
        }
        return (
          statusCode: 200,
          bytes: utf8.encode(jsonEncode(workdayCalendarFixture())),
        );
      },
    );
    expect((await client.fetchYear(2026))!.year, 2026);
    expect(requests.map((uri) => uri.host), [
      'cdn.jsdelivr.net',
      'raw.githubusercontent.com',
    ]);
    expect(
      requests.every(
        (uri) =>
            uri.scheme == 'https' &&
            uri.path.endsWith('/2026.json') &&
            !uri.hasQuery,
      ),
      isTrue,
    );
  });

  test('404 与空占位保持缺失；HTML、错误年份、重定向、异常状态和超限正文不能入库', () async {
    for (final status in [200, 404]) {
      final client = HolidayCalendarClient(
        transport: (_) async => (
          statusCode: status,
          bytes: utf8.encode(
            File(
              'test/fixtures/holiday_cn/2027_unpublished.json',
            ).readAsStringSync(),
          ),
        ),
      );
      expect(await client.fetchYear(2027), isNull);
    }
    for (final bytes in [
      utf8.encode('<html>服务故障</html>'),
      List<int>.filled(65537, 32),
      utf8.encode(jsonEncode(workdayCalendarFixture()..['year'] = 2025)),
    ]) {
      final client = HolidayCalendarClient(
        transport: (_) async => (statusCode: 200, bytes: bytes),
      );
      await expectLater(client.fetchYear(2026), throwsFormatException);
    }
    for (final status in [301, 500]) {
      final client = HolidayCalendarClient(
        transport: (_) async => (statusCode: status, bytes: const <int>[]),
      );
      await expectLater(client.fetchYear(2026), throwsA(isA<HttpException>()));
    }
  });

  test('关闭联网后不再发备用地址请求，也不接受已返回的结果', () async {
    final gate = Completer<HolidayCalendarResponse>();
    var allowed = true;
    var calls = 0;
    final client = HolidayCalendarClient(
      transport: (_) {
        calls++;
        return gate.future;
      },
    );
    final running = client.fetchYear(2026, shouldContinue: () => allowed);
    allowed = false;
    gate.complete((statusCode: 500, bytes: const <int>[]));
    expect(await running, isNull);
    expect(calls, 1);
  });
}
