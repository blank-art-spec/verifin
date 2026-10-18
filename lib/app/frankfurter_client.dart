import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 仅发送币种与日期，不包含金额、账户或交易数据。日汇率日期取供应方响应。
class FrankfurterClient {
  const FrankfurterClient();
  Future<List<({String currency, DateTime date, double rate})>> fetch({
    required String base,
    required Set<String> currencies,
    DateTime? date,
  }) async {
    final result = <({String currency, DateTime date, double rate})>[];
    final client = HttpClient()
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
          throw HttpException(
            'Exchange rate provider returned ${response.statusCode}',
          );
        }
        var length = 0;
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 15),
        )) {
          length += chunk.length;
          if (length > 65536) {
            throw const FormatException('Exchange rate response too large');
          }
          bytes.addAll(chunk);
        }
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final rate = (json['rate'] as num).toDouble();
        final published = DateTime.parse(json['date'] as String);
        if (json['base'].toString().toUpperCase() != code ||
            json['quote'].toString().toUpperCase() != base ||
            !rate.isFinite ||
            rate <= 0 ||
            published.isAfter(DateTime.now())) {
          throw const FormatException('Invalid exchange rate observation');
        }
        result.add((currency: code, date: published, rate: rate));
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }
}
