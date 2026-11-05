/// 期权行情凭证只经设备安全存储，不进入普通偏好、账目或备份。
library;

import '../platform_bridge.dart';

/// 已验证的不可变凭证对；调试输出始终脱敏，不提供通用 JSON 序列化入口。
class OptionQuoteCredentials {
  /// 去除表单首尾空白；只接受两项非空、最多 512 位的可见 ASCII 请求头值。
  factory OptionQuoteCredentials({
    required String keyId,
    required String secretKey,
  }) {
    final key = keyId.trim(), secret = secretKey.trim();
    bool valid(String value) =>
        value.isNotEmpty &&
        value.length <= 512 &&
        RegExp(r'^[\x21-\x7e]+$').hasMatch(value);
    if (!valid(key) || !valid(secret)) {
      throw const FormatException('期权行情凭证格式不合法');
    }
    return OptionQuoteCredentials._(key, secret);
  }

  const OptionQuoteCredentials._(this.keyId, this.secretKey);

  final String keyId, secretKey;

  @override
  String toString() => 'OptionQuoteCredentials(<redacted>)';
}

/// 安全存储失败的固定提示；不携带原生错误、密文、请求头或凭证原文。
class OptionQuoteCredentialStoreException implements Exception {
  const OptionQuoteCredentialStoreException();

  @override
  String toString() => '期权行情凭证的设备安全存储操作失败';
}

/// 可注入的设备凭证存储；null 表示从未保存或已清除，错误必须抛出而非假装为空。
abstract class OptionQuoteCredentialStore {
  Future<OptionQuoteCredentials?> read();
  Future<void> write(OptionQuoteCredentials credentials);
  Future<void> clear();
}

/// 通过既有安全桥调用 Android 加密存储；不在 Dart 偏好中保留任何副本。
class PlatformOptionQuoteCredentialStore implements OptionQuoteCredentialStore {
  const PlatformOptionQuoteCredentialStore();

  @override
  Future<OptionQuoteCredentials?> read() async {
    try {
      final raw = await AppSecurityBridge.readOptionQuoteCredentials();
      if (raw == null) return null;
      final key = raw['keyId'], secret = raw['secretKey'];
      if (key is! String || secret is! String) {
        throw const OptionQuoteCredentialStoreException();
      }
      return OptionQuoteCredentials(keyId: key, secretKey: secret);
    } catch (_) {
      throw const OptionQuoteCredentialStoreException();
    }
  }

  @override
  Future<void> write(OptionQuoteCredentials credentials) async {
    try {
      final saved = await AppSecurityBridge.writeOptionQuoteCredentials(
        keyId: credentials.keyId,
        secretKey: credentials.secretKey,
      );
      if (saved != true) throw const OptionQuoteCredentialStoreException();
    } catch (_) {
      throw const OptionQuoteCredentialStoreException();
    }
  }

  @override
  Future<void> clear() async {
    try {
      final cleared = await AppSecurityBridge.clearOptionQuoteCredentials();
      if (cleared != true) throw const OptionQuoteCredentialStoreException();
    } catch (_) {
      throw const OptionQuoteCredentialStoreException();
    }
  }
}
