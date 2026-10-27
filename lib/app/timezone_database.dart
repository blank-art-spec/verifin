/// 提醒与证券源时间共用完整 IANA 时区资产，避免重复打包及并发初始化覆盖。
library;

import 'dart:io' show gzip;

import 'package:flutter/services.dart' show rootBundle;
import 'package:timezone/timezone.dart' as tz;

Future<void>? _databaseReady;

/// 确保完整时区数据库已载入，无参数；返回可等待的初始化 Future。
///
/// 多个调用者共用同一次读取；不修改设备的本地时区，不发网络请求。资产仍使用
/// 已校验的 latest_all.tzf.gz，保留历史和别名。失败向调用方传播，调用方负责反馈，
/// 下次调用允许重试，不让一次临时读取失败永久阻断提醒或美股报价时间解析。
Future<void> ensureTimezoneDatabase() => _databaseReady ??= _loadDatabase();

/// 从应用内既有 gzip 资产载入 IANA 数据，无参数；成功后初始化共享 tz 数据库。
/// 读取失败仅清除本次初始化缓存后重新抛出，由通知或行情领域记录并处理错误。
Future<void> _loadDatabase() async {
  try {
    final data = await rootBundle.load('assets/timezone/latest_all.tzf.gz');
    final packed = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    tz.initializeDatabase(gzip.decode(packed));
  } catch (_) {
    // 不吞掉异常；清除失败 Future 使下一次领域调用可按既有反馈流程重试。
    _databaseReady = null;
    rethrow;
  }
}
