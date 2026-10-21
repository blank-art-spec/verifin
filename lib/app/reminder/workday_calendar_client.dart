import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'workday_calendar_sync.dart';

/// 可注入的 HTTP 响应；测试提供公开 fixture 字节，生产使用受限 HTTPS 客户端。
typedef HolidayCalendarResponse = ({int statusCode, List<int> bytes});

/// 工作日日历公共数据客户端；只请求年份文件，不发送账户、账目或设备标识。
/// 协议依据：https://github.com/NateScarlet/holiday-cn#通过互联网使用
class HolidayCalendarClient {
  /// [transport] 仅用于测试替换网络；生产留空，固定访问公开数据源的两个 HTTPS 地址。
  const HolidayCalendarClient({this.transport});

  final Future<HolidayCalendarResponse> Function(Uri uri)? transport;
  static const _maxResponseBytes = 65536;
  static const _requestTimeout = Duration(seconds: 12);

  /// 获取 [year] 的完整年度文件；两个地址都尚无文件/只有空占位时返回 null。
  /// CDN 失败或尚未更新时再读 GitHub 原始文件，任一有效文件即可；均无效则保留失败。
  /// [shouldContinue] 在关闭联网或初始化后返回 false，阻止尚未发出的备用地址请求。
  Future<HolidayCalendarDocument?> fetchYear(
    int year, {
    bool Function()? shouldContinue,
  }) async {
    if (year < 2000 || year > 2199) {
      throw ArgumentError.value(year, 'year', '日历年份超出范围');
    }
    Object? lastError;
    for (final uri in [
      Uri.https(
        'cdn.jsdelivr.net',
        '/gh/NateScarlet/holiday-cn@master/$year.json',
      ),
      Uri.https(
        'raw.githubusercontent.com',
        '/NateScarlet/holiday-cn/master/$year.json',
      ),
    ]) {
      if (shouldContinue?.call() == false) return null;
      try {
        final response = await (transport?.call(uri) ?? _download(uri)).timeout(
          _requestTimeout,
        );
        if (shouldContinue?.call() == false) return null;
        if (response.statusCode == HttpStatus.notFound) continue;
        if (response.statusCode != HttpStatus.ok) {
          throw const HttpException('日历数据源返回非成功状态');
        }
        if (response.bytes.length > _maxResponseBytes) {
          throw const FormatException('年度日历响应过大');
        }
        final document = HolidayCalendarDocument.parse(
          jsonDecode(utf8.decode(response.bytes)),
          expectedYear: year,
        );
        if (document != null) return document;
      } catch (error) {
        if (shouldContinue?.call() == false) return null;
        // 地址固定且不含账目；只向上保留异常类型，用户文案由 UI 本地化提供。
        lastError = error;
      }
    }
    if (lastError != null) throw lastError;
    return null;
  }

  /// 分块读取固定来源 [uri]，在累计超出 64 KiB 时立即停止；禁止跟随重定向到其他域名。
  /// 总请求超时后强制关闭客户端，不把超时连接留在后台继续传输。
  Future<HolidayCalendarResponse> _download(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      return await _readResponse(client, uri).timeout(_requestTimeout);
    } finally {
      client.close(force: true);
    }
  }

  /// 用 [client] 读取 [uri] 的状态与解压后字节；长度头只作提前拒绝，仍逐块计数。
  Future<HolidayCalendarResponse> _readResponse(
    HttpClient client,
    Uri uri,
  ) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      return (statusCode: response.statusCode, bytes: const <int>[]);
    }
    if (response.contentLength > _maxResponseBytes) {
      throw const FormatException('年度日历响应过大');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _maxResponseBytes) {
        throw const FormatException('年度日历响应过大');
      }
      bytes.addAll(chunk);
    }
    return (statusCode: response.statusCode, bytes: bytes);
  }
}
