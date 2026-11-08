import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/fund_security_search.dart';
import 'package:verifin/app/investments/security_search.dart';
import 'package:verifin/app/models/investment.dart';

/// 保存真实公开身份响应，记录请求只包含 ISIN、不包含账户或币种。
class _PublicFundTransport implements SecuritySearchTransport {
  _PublicFundTransport(this.html, {this.status = 200});
  final String html;
  final int status;
  final requests = <Uri>[];
  bool closed = false;

  @override
  Future<SecuritySearchResponse> get(Uri uri) async {
    requests.add(uri);
    return SecuritySearchResponse(
      statusCode: status,
      body: Stream.value(utf8.encode(html)),
    );
  }

  @override
  void close() => closed = true;
}

/// 从实际匿名请求保留的身份片段读取，不手工编造供应方字段。
String _identity(String isin) => File(
  'test/fixtures/investments/tiger_fund_identity_${isin}_20261108.html',
).readAsStringSync();

/// 关闭连接时才释放挂起的请求，模拟超时后的网络异常，不允许触发新的补充查询。
class _PendingFundTransport implements SecuritySearchTransport {
  final pending = Completer<SecuritySearchResponse>();
  final requests = <Uri>[];

  @override
  Future<SecuritySearchResponse> get(Uri uri) {
    requests.add(uri);
    return pending.future;
  }

  @override
  void close() {
    if (!pending.isCompleted) {
      pending.completeError(const SocketException('connection closed'));
    }
  }
}

void main() {
  test('按ISIN查询未预置的平安港元P类，来源自行返回份额币种', () async {
    final transport = _PublicFundTransport(_identity('HK0000996873'));
    final results = await FundSecuritySearchClient(
      transportFactory: () => transport,
    ).search('HK0000996873', market: StockMarket.hk, currencyCode: 'HKD');
    expect(results, hasLength(1));
    expect(results.single.name, '平安港元货币基金 P类');
    expect(results.single.isin, 'HK0000996873');
    expect(results.single.shareClass, 'P');
    expect(results.single.currencyCode, 'HKD');
    expect(results.single.hasCompleteIdentity, isTrue);
    expect(
      results.single.sourceUrl.toString(),
      'https://www.laohu8.com/FUND/HK0000996873',
    );
    expect(
      transport.requests.single.toString(),
      'https://www.laohu8.com/FUND/HK0000996873',
    );
    expect(transport.closed, isTrue);
  });

  test('多家公司及非HK前缀ISIN共用目录，明确份额类别来自原始名称', () async {
    for (final sample in [
      ('HK0001039582', 'B', 'USD', '招商美元货币市场基金 B类'),
      ('HK0000945037', 'A', 'USD', '惠理美元货币基金A 美元'),
      ('LU0395794307', 'A', 'EUR', 'JPM GLOBAL INCOME (DIV) "A" (EUR) INC'),
    ]) {
      final transport = _PublicFundTransport(_identity(sample.$1));
      final result =
          await FundSecuritySearchClient(
            transportFactory: () => transport,
          ).search(
            ' ${sample.$1.toLowerCase()} ',
            market: StockMarket.hk,
            currencyCode: sample.$3,
          );
      expect(result.single.isin, sample.$1);
      expect(result.single.shareClass, sample.$2);
      expect(result.single.currencyCode, sample.$3);
      expect(result.single.name, sample.$4);
      expect(result.single.hasCompleteIdentity, isTrue);
      expect(transport.requests.single.path, '/FUND/${sample.$1}');
      expect(transport.requests.single.hasQuery, isFalse);
    }
  });

  test('币种及用户所选市场不影响按ISIN发现身份，也不补猜来源币种', () async {
    final transport = _PublicFundTransport(_identity('HK0000996873'));
    final result = await FundSecuritySearchClient(
      transportFactory: () => transport,
    ).search('HK0000996873', market: StockMarket.cn, currencyCode: 'USD');
    expect(result.single.currencyCode, 'HKD');
    expect(
      result.single.toSecurity(market: StockMarket.cn).market,
      StockMarket.cn,
    );
    expect(
      transport.requests.single.toString(),
      'https://www.laohu8.com/FUND/HK0000996873',
    );
  });

  test('非法形状和校验位在联网前区分为输入错误', () async {
    final transport = _PublicFundTransport('');
    final client = FundSecuritySearchClient(transportFactory: () => transport);
    for (final input in [
      'HK0000996874',
      'HK000099687',
      'HK00009968730',
      'HK000099\u200b6873',
      'HK0000996873\nX',
      '000198',
      'https://www.laohu8.com/FUND/HK0000996873',
    ]) {
      await expectLater(
        client.search(input, market: StockMarket.hk, currencyCode: 'HKD'),
        throwsA(isA<FundSearchInvalidIsinException>()),
      );
    }
    expect(
      await client.search('', market: StockMarket.hk, currencyCode: 'HKD'),
      isEmpty,
    );
    expect(transport.requests, isEmpty);
    expect(isValidFundIsin('US0378331005'), isTrue);
    expect(isValidFundIsin('LU0395794307'), isTrue);
  });

  test('目录未收录与请求失败区分，均关闭本次连接', () async {
    for (final status in [404, 403, 429, 503, 302]) {
      final transport = _PublicFundTransport('', status: status);
      final result = FundSecuritySearchClient(
        transportFactory: () => transport,
      ).search('HK0000000007', market: StockMarket.hk, currencyCode: 'HKD');
      if (status == 404) {
        expect(await result, isEmpty);
      } else {
        await expectLater(result, throwsA(isA<HttpException>()));
      }
      expect(transport.closed, isTrue);
    }
  });

  test('查询总超时关闭主请求，不在超时后继续请求官方补充来源', () async {
    final transport = _PendingFundTransport();
    await expectLater(
      FundSecuritySearchClient(
        transportFactory: () => transport,
        requestTimeout: const Duration(milliseconds: 5),
      ).search('HK0001039582', market: StockMarket.hk, currencyCode: 'USD'),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.host, 'www.laohu8.com');
  });

  test('不接受别的ISIN、错配symbol、注释脚本伪造或重复身份块', () async {
    final valid = _identity('HK0000996873');
    for (final malformed in [
      valid.replaceAll('HK0000996873', 'HK0001039582'),
      valid.replaceAll('HK0000996873.HKD', 'HK0001039582.HKD'),
      '<script>$valid</script>',
      '<!--$valid-->',
      '$valid$valid',
      '<textarea id="__APP_DATA__">invalid json</textarea>',
      '<textarea id="__APP_DATA__">{"fundInfo":null}</textarea>',
    ]) {
      final transport = _PublicFundTransport(malformed);
      await expectLater(
        FundSecuritySearchClient(
          transportFactory: () => transport,
        ).search('HK0000996873', market: StockMarket.hk, currencyCode: 'HKD'),
        throwsFormatException,
      );
      expect(transport.closed, isTrue);
    }
  });

  test('份额类别缺失或互相矛盾时展示原名与来源，不允许直接确认', () async {
    for (final name in [
      '平安港元货币基金',
      '平安港元货币基金 P类 A类',
      '某基金 USD',
      '某基金 ACC',
      '某基金 "GROWTH"',
      '某基金 "A" 投资策略',
    ]) {
      final jsonName = jsonEncode(name);
      final encodedName = const HtmlEscape().convert(
        jsonName.substring(1, jsonName.length - 1),
      );
      final transport = _PublicFundTransport(
        _identity('HK0000996873').replaceAll('平安港元货币基金 P类', encodedName),
      );
      final result = await FundSecuritySearchClient(
        transportFactory: () => transport,
      ).search('HK0000996873', market: StockMarket.hk, currencyCode: 'HKD');
      expect(result.single.name, name);
      expect(result.single.shareClass, isNull);
      expect(result.single.hasCompleteIdentity, isFalse);
      expect(
        () => result.single.toSecurity(market: StockMarket.hk),
        throwsStateError,
      );
    }
  });

  test('精确身份存在但来源没有份额币种时保留未知，不借用账户币种', () async {
    final html = _identity(
      'HK0000996873',
    ).replaceAll(',&quot;symbol&quot;:&quot;HK0000996873.HKD&quot;', '');
    final result = await FundSecuritySearchClient(
      transportFactory: () => _PublicFundTransport(html),
    ).search('HK0000996873', market: StockMarket.hk, currencyCode: 'HKD');
    expect(result.single.isin, 'HK0000996873');
    expect(result.single.name, '平安港元货币基金 P类');
    expect(result.single.currencyCode, isNull);
    expect(result.single.hasCompleteIdentity, isFalse);
  });
}
