import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/option_quote_credential_store.dart';

/// 只模拟既有原生通道的返回值，不读写设备上的真实凭证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('verifin/app');
  const store = PlatformOptionQuoteCredentialStore();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('安全存储固定三项出站协议，空结果与有效凭证可区分', () async {
    final calls = <MethodCall>[];
    Object? result;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return result;
    });
    expect(await store.read(), isNull);
    result = {'keyId': 'fixture-key', 'secretKey': 'fixture-secret'};
    final loaded = (await store.read())!;
    expect(loaded.keyId, 'fixture-key');
    expect(loaded.secretKey, 'fixture-secret');
    expect(loaded.toString(), isNot(contains('fixture')));
    result = true;
    await store.write(loaded);
    await store.clear();
    expect(calls.map((call) => call.method), [
      'readOptionQuoteCredentials',
      'readOptionQuoteCredentials',
      'writeOptionQuoteCredentials',
      'clearOptionQuoteCredentials',
    ]);
    expect(calls[2].arguments, {
      'keyId': 'fixture-key',
      'secretKey': 'fixture-secret',
    });
    expect(calls[0].arguments, isNull);
    expect(calls[3].arguments, isNull);
  });

  test('凭证对验证请求头字符与长度，调试输出不包含密钥', () {
    final credentials = OptionQuoteCredentials(
      keyId: '  fixture-key  ',
      secretKey: ' fixture-secret ',
    );
    expect(credentials.keyId, 'fixture-key');
    expect(credentials.secretKey, 'fixture-secret');
    expect('$credentials', isNot(contains('fixture-secret')));
    for (final secret in [
      '',
      'with space',
      'line\nbreak',
      'a' * 513,
      '非ASCII',
    ]) {
      expect(
        () => OptionQuoteCredentials(keyId: 'fixture-key', secretKey: secret),
        throwsFormatException,
      );
    }
    expect(
      () => OptionQuoteCredentials(keyId: '', secretKey: 'fixture-secret'),
      throwsFormatException,
    );
  });

  test('损坏原生结果不能伪装未配置，原生异常不回显敏感内容', () async {
    for (final result in <Object?>[
      false,
      'SECRET-ERROR',
      <String, Object?>{},
      {'keyId': 'fixture-key', 'secretKey': 42},
      {'keyId': '', 'secretKey': ''},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => result);
      await expectLater(
        store.read(),
        throwsA(isA<OptionQuoteCredentialStoreException>()),
      );
    }
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'read_failed',
        message: 'SECRET-ERROR',
        details: 'fixture-secret',
      );
    });
    try {
      await store.read();
      fail('原生读取失败必须向调用方返回失败');
    } on OptionQuoteCredentialStoreException catch (error) {
      expect(error.toString(), isNot(contains('SECRET-ERROR')));
      expect(error.toString(), isNot(contains('fixture-secret')));
    }
  });

  test('写入和清除只有 true 算成功，缺插件也不能假报已保存', () async {
    final credentials = OptionQuoteCredentials(
      keyId: 'fixture-key',
      secretKey: 'fixture-secret',
    );
    for (final result in [false, null]) {
      messenger.setMockMethodCallHandler(channel, (_) async => result);
      await expectLater(
        store.write(credentials),
        throwsA(isA<OptionQuoteCredentialStoreException>()),
      );
      await expectLater(
        store.clear(),
        throwsA(isA<OptionQuoteCredentialStoreException>()),
      );
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException('fixture-secret'),
    );
    await expectLater(
      store.read(),
      throwsA(isA<OptionQuoteCredentialStoreException>()),
    );
    await expectLater(
      store.write(credentials),
      throwsA(isA<OptionQuoteCredentialStoreException>()),
    );
    await expectLater(
      store.clear(),
      throwsA(isA<OptionQuoteCredentialStoreException>()),
    );
  });
}
