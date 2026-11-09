import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'calendar_days.dart';
import 'models/currency.dart';

/// 仅发送币种与日期，不包含金额、账户或交易数据。日汇率日期取供应方响应。
class FrankfurterClient {
  /// 默认构造保持 const 兼容，创建对象时不会联网。
  /// [clientFactory] 每轮提供独立 HTTP 客户端，仅用于离线测试替换传输。
  /// [clock] 返回当前真实瞬间，用于检查来源日期是否可能已经到来；不替代来源日期。
  const FrankfurterClient({this.clientFactory, this.clock});

  final HttpClient Function()? clientFactory;
  final DateTime Function()? clock;

  /// 查询 [currencies] 中各原币兑换为 [base] 的每日参考汇率，排除原币等于本币的项。
  /// [date] 为空时查询最新观察；非空时只发送其年月日，并拒绝晚于该日的来源观察。
  /// 返回日期保留来源年月日及既有本地 DateTime 载体，不把日历日转换成发布时间。
  /// 单项失败仍整轮失败并由上层保留缓存；请求只包含公开币种和可选日期。
  Future<List<({String currency, DateTime date, double rate})>> fetch({
    required String base,
    required Set<String> currencies,
    DateTime? date,
  }) async {
    final result = <({String currency, DateTime date, double rate})>[];
    final client = (clientFactory?.call() ?? HttpClient())
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      for (final code in currencies.where((c) => c != base)) {
        final uri = Uri.https(
          'api.frankfurter.dev',
          '/v2/rate/${code.toLowerCase()}/${base.toLowerCase()}',
          date == null
              ? null
              : {
                  'date':
                      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                },
        );
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 15));
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode != 200) {
          throw HttpException('汇率来源请求失败：HTTP ${response.statusCode}');
        }
        var length = 0;
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 15),
        )) {
          length += chunk.length;
          if (length > 65536) {
            throw const FormatException('汇率响应超过六十四 KiB 上限');
          }
          bytes.addAll(chunk);
        }
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final rate = (json['rate'] as num).toDouble();
        final published = _observationDate(json['date'], requestedDate: date);
        if (json['base'].toString().toUpperCase() != code ||
            json['quote'].toString().toUpperCase() != base ||
            !rate.isFinite ||
            rate <= 0) {
          throw const FormatException('汇率观察的币种或数值无效');
        }
        result.add((currency: code, date: published, rate: rate));
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }

  /// 校验来源 [raw] 的 YYYY-MM-DD 日历日；[requestedDate] 为可选的历史查询上界。
  /// Frankfurter 汇集全球来源，响应只给观察日期，没有统一的公布时区或日内时刻：
  /// https://frankfurter.dev/#rate 。因此按当前瞬间 UTC+14 的日期排除全球尚未到来的日，
  /// 不能把来源日解释成设备本地零点后与瞬间比较，否则西侧时区会误拒已公布观察。
  /// UTC+14 只用于合法日期上界，不用于换算或保存来源日期；实际使用仍遵守原生效日。
  DateTime _observationDate(Object? raw, {DateTime? requestedDate}) {
    final published = parseCurrencyDateKey(raw);
    if (published == null || published.year < 1) {
      throw const FormatException('汇率来源日期必须是有效的 YYYY-MM-DD 日历日');
    }
    // 这里是已知时区偏移的瞬间换算，不是以二十四小时代替日历日加减。
    final earliestZoneNow = (clock?.call() ?? DateTime.now()).toUtc().add(
      const Duration(hours: 14),
    );
    if (calendarDaysBetween(published, earliestZoneNow) < 0 ||
        (requestedDate != null &&
            calendarDaysBetween(published, requestedDate) < 0)) {
      throw const FormatException('汇率来源日期晚于允许的日历日');
    }
    return published;
  }
}
