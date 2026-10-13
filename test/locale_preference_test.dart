import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/main.dart';

import 'support/in_memory_ledger_repository.dart';

/// 验证默认中文、既有语言选择和实际界面；不使用会预置中文的共享脚手架，
/// 从而覆盖真实的「尚未保存语言偏好」场景，避免测试掩盖默认值错误。
void main() {
  test('缺失或无效的语言键回落中文，显式跟随系统仍保留', () {
    for (final value in <String?>[null, '', 'unknown-locale']) {
      expect(LocalePreference.fromStorage(value), LocalePreference.zh);
    }
    expect(LocalePreference.fromStorage('system'), LocalePreference.system);
  });

  test('英文系统首次启动默认中文，种子数据和重启保持一致', () async {
    final store = LocalKeyValueStore();
    final repository = InMemoryLedgerRepository();
    final controller = await VeriFinController.create(
      store,
      repository: repository,
      systemIsEnglish: true,
    );
    expect(controller.localePreference, LocalePreference.zh);
    expect(controller.localePreferenceListenable.value, LocalePreference.zh);
    expect(controller.activeBook.name, '日常账本');
    expect(
      controller.categories.map((category) => category.label),
      contains('餐饮'),
    );
    controller.dispose();

    // 未手动选择语言时也应在冷启动后继续使用默认中文，不随系统语言改变。
    final restarted = await VeriFinController.create(
      store,
      repository: repository,
      systemIsEnglish: true,
    );
    addTearDown(restarted.dispose);
    expect(restarted.localePreference, LocalePreference.zh);
    expect(restarted.activeBook.name, '日常账本');
  });

  test('已保存英文选择不被中文默认值覆盖', () async {
    final store = LocalKeyValueStore()..write('verifin.locale.v1', 'en');
    final controller = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      systemIsEnglish: false,
    );
    addTearDown(controller.dispose);
    expect(controller.localePreference, LocalePreference.en);
    expect(controller.activeBook.name, 'Daily Ledger');
    expect(store.read('verifin.locale.v1'), 'en');
  });

  testWidgets('英文系统未保存语言偏好时，实际导航显示中文', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    // 只跳过隐私同意与引导，不写语言键，验证 MaterialApp 读取真正的默认值。
    final store = LocalKeyValueStore()
      ..write('verifin.privacy_consent.v1', 'true')
      ..write('verifin.onboarding.v1', 'true');
    final controller = await VeriFinController.create(
      store,
      repository: InMemoryLedgerRepository(),
      systemIsEnglish: true,
    );
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('main_bottom_nav')),
        matching: find.text('首页'),
      ),
      findsOneWidget,
    );
    // 应用根组件卸载时负责销毁控制器，测试只卸载界面，避免重复释放通知器。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
