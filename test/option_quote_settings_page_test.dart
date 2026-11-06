import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/pages/option_quote_settings_page.dart';

import 'support/test_harness.dart';

final _keyId = find.byKey(const ValueKey('optionQuoteKeyId'));
final _secretKey = find.byKey(const ValueKey('optionQuoteSecretKey'));

/// 打开真实路由并捕获返回值，不构造控制器、偏好存储或网络客户端。
Future<void> _open(
  WidgetTester tester, {
  bool configured = false,
  bool loadFailed = false,
  required Future<bool> Function(String, String) onSave,
  ValueChanged<bool?>? onResult,
}) async {
  await tester.pumpWidget(
    zhMaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => OptionQuoteSettingsPage(
                    configured: configured,
                    loadFailed: loadFailed,
                    onSave: onSave,
                  ),
                ),
              );
              onResult?.call(result);
            },
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}

/// 两个字段仍是草稿；输入本身不触发外部回调。
Future<void> _enterCredentials(WidgetTester tester) async {
  await tester.enterText(_keyId, '  example-key-id  ');
  await tester.enterText(_secretKey, '  example-secret  ');
  await tester.pump();
}

void main() {
  testWidgets('已有配置不回显秘密，空字段不启用保存且输入关闭自动学习', (tester) async {
    var calls = 0;
    await _open(
      tester,
      configured: true,
      onSave: (_, _) async {
        calls++;
        return true;
      },
    );
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields, hasLength(2));
    for (final field in fields) {
      expect(field.controller!.text, isEmpty);
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isEmpty);
    }
    expect(
      tester.widget<SaveHeaderAction>(find.byType(SaveHeaderAction)).onPressed,
      isNull,
    );
    expect(find.textContaining('免费 Basic 账户'), findsOneWidget);
    expect(find.textContaining('可稍后配置'), findsOneWidget);
    expect(find.textContaining('重启后自动恢复'), findsOneWidget);
    expect(find.textContaining('本机已保存。填写两项凭证'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('完整凭证只在保存后提交，规范化首尾空格并返回成功', (tester) async {
    final calls = <(String, String)>[];
    bool? result;
    await _open(
      tester,
      onSave: (keyId, secretKey) async {
        calls.add((keyId, secretKey));
        return true;
      },
      onResult: (value) => result = value,
    );
    await _enterCredentials(tester);
    expect(calls, isEmpty);
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(calls, [('example-key-id', 'example-secret')]);
    expect(result, isTrue);
    expect(find.byType(OptionQuoteSettingsPage), findsNothing);
  });

  testWidgets('单项、内部空白、控制字符和过长凭证不会提交', (tester) async {
    var calls = 0;
    await _open(
      tester,
      onSave: (_, _) async {
        calls++;
        return true;
      },
    );
    await tester.enterText(_keyId, 'example-key-id');
    await tester.pump();
    expect(
      tester.widget<SaveHeaderAction>(find.byType(SaveHeaderAction)).onPressed,
      isNull,
    );
    for (final invalid in [
      'two words',
      'a\tb',
      'a\u0000b',
      '非ASCII',
      'x' * 513,
    ]) {
      await tester.enterText(_secretKey, invalid);
      await tester.pump();
      expect(
        tester
            .widget<SaveHeaderAction>(find.byType(SaveHeaderAction))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TextField>(_secretKey).decoration!.errorText,
        isNotNull,
      );
    }
    expect(calls, 0);
  });

  testWidgets('取消返回保留草稿，不保存退出不会交付凭证', (tester) async {
    var calls = 0;
    bool? result;
    await _open(
      tester,
      onSave: (_, _) async {
        calls++;
        return true;
      },
      onResult: (value) => result = value,
    );
    await _enterCredentials(tester);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_secretKey).controller!.text,
      '  example-secret  ',
    );
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不保存'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(result, isNull);
    expect(find.byType(OptionQuoteSettingsPage), findsNothing);
  });

  testWidgets('返回确认中的保存同样返回成功', (tester) async {
    bool? result;
    await _open(
      tester,
      onSave: (_, _) async => true,
      onResult: (value) => result = value,
    );
    await _enterCredentials(tester);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(OptionQuoteSettingsPage), findsNothing);
  });

  for (final throwsError in [false, true]) {
    testWidgets('保存失败保留草稿且错误原文不泄露：$throwsError', (tester) async {
      await _open(
        tester,
        onSave: (_, _) async {
          if (throwsError) throw StateError('sensitive-error-payload');
          return false;
        },
      );
      await _enterCredentials(tester);
      await tester.tap(find.byTooltip('保存'));
      // 提示带持续计时动画；等到 settle 会推进到八秒后提示已自动消失。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.byType(OptionQuoteSettingsPage), findsOneWidget);
      expect(
        tester.widget<TextField>(_secretKey).controller!.text,
        '  example-secret  ',
      );
      expect(find.text('未保存，请稍后重试。'), findsOneWidget);
      expect(find.text('未保存，请稍后重试。').hitTestable(), findsOneWidget);
      expect(find.textContaining('sensitive-error-payload'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('保存进行中禁止修改、重复提交、清除和返回', (tester) async {
    final pending = Completer<bool>();
    var calls = 0;
    await _open(
      tester,
      configured: true,
      onSave: (_, _) {
        calls++;
        return pending.future;
      },
    );
    await _enterCredentials(tester);
    await tester.tap(find.byTooltip('保存'));
    await tester.pump();
    expect(calls, 1);
    expect(
      tester.widget<SaveHeaderAction>(find.byType(SaveHeaderAction)).onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(_keyId).enabled, isFalse);
    expect(tester.widget<TextField>(_secretKey).enabled, isFalse);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byWidgetPredicate((widget) => widget is OutlinedButton),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    expect(find.text('保存修改？'), findsNothing);
    expect(find.byType(OptionQuoteSettingsPage), findsOneWidget);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(OptionQuoteSettingsPage), findsNothing);
  });

  testWidgets('明确清除已保存凭证交付空凭证并返回成功', (tester) async {
    final calls = <(String, String)>[];
    bool? result;
    await _open(
      tester,
      configured: true,
      onSave: (keyId, secretKey) async {
        calls.add((keyId, secretKey));
        return true;
      },
      onResult: (value) => result = value,
    );
    await tester.ensureVisible(find.text('清除已保存凭证'));
    await tester.tap(find.text('清除已保存凭证'));
    await tester.pumpAndSettle();
    expect(calls, [('', '')]);
    expect(result, isTrue);
    expect(find.byType(OptionQuoteSettingsPage), findsNothing);
  });

  testWidgets('读取失败不声称未配置，保留错误提示并允许主动清除', (tester) async {
    final calls = <(String, String)>[];
    await _open(
      tester,
      loadFailed: true,
      onSave: (keyId, secretKey) async {
        calls.add((keyId, secretKey));
        return true;
      },
    );
    expect(find.text('本机凭证读取失败，请重新配置或清除已保存凭证。'), findsOneWidget);
    expect(find.text('填写两项凭证后保存。'), findsNothing);
    expect(find.textContaining('本机已保存。'), findsNothing);
    expect(calls, isEmpty);
    await tester.ensureVisible(find.text('清除已保存凭证'));
    await tester.tap(find.text('清除已保存凭证'));
    await tester.pumpAndSettle();
    expect(calls, [('', '')]);
    expect(find.byType(OptionQuoteSettingsPage), findsNothing);
  });
}
