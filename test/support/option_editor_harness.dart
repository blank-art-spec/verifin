import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/pages/option_editor_page.dart';

/// 返回当前可见期权表单的主滚动容器，避免把证券候选浮层当成页面列表。
Finder optionEditorScroll() => find
    .descendant(
      of: find.byType(OptionEditorPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 从表单顶部定位 [target]，不依赖上一个操作留下的滚动方向。
/// [tester] 控制真实页面；本方法只调整测试视口，不直接改变表单草稿。
Future<void> revealOptionEditorTarget(
  WidgetTester tester,
  Finder target,
) async {
  final scroll = optionEditorScroll();
  tester.state<ScrollableState>(scroll).position.jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(target, 240, scrollable: scroll);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// 通过真实折叠按钮展开 [section]，已展开时保持原状，不清空草稿。
/// [section] 为页面约定的 details、settlement 或 extras 分组标识。
Future<void> expandOptionEditorSection(
  WidgetTester tester,
  String section,
) async {
  final toggle = find.byKey(ValueKey('option-$section-toggle'));
  await revealOptionEditorTarget(tester, toggle);
  final expandIcon = find.descendant(
    of: toggle,
    matching: find.byIcon(Icons.expand_more),
  );
  if (expandIcon.evaluate().isNotEmpty) {
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }
}

/// 展开 [field] 所在分组并返回实际文本框，沿用页面稳定的 option- 字段键。
/// 主交易字段无需展开；身份、交割、选填字段分别由对应按钮显式展开。
Future<Finder> revealOptionEditorField(
  WidgetTester tester,
  String field,
) async {
  final section = switch (field) {
    'name' || 'underlying' || 'underlyingName' || 'strike' => 'details',
    'shares' || 'exercise' || 'source' => 'settlement',
    'reference' || 'margin' || 'note' => 'extras',
    _ => null,
  };
  if (section != null) await expandOptionEditorSection(tester, section);
  final input = find.byKey(ValueKey('option-$field'));
  await revealOptionEditorTarget(tester, input);
  return input;
}
