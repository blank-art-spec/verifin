import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/option_editor_page.dart';

import 'support/investment_fixture.dart';
import 'support/option_editor_harness.dart';
import 'support/test_harness.dart';

/// 打开真实期权页面并使用隔离的内存账户，不请求行情或操作用户账目。
/// [opening] 切换为父页面持有的期初草稿，[specificationOnly] 检查必显规格资料；
/// [locale]、[scale] 与 [size] 用于验证英文、窄屏及大字号下仍能完成折叠操作。
Future<({VeriFinController controller, Account account})> _openEditor(
  WidgetTester tester, {
  bool opening = false,
  bool specificationOnly = false,
  Locale locale = const Locale('zh'),
  double scale = 1,
  Size size = const Size(393, 852),
}) async {
  final controller = await makeController();
  final account = investmentAccountFixture();
  addTearDown(controller.dispose);
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  if (!opening) {
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      ),
      isTrue,
    );
  }
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Localizations.override(
            context: context,
            locale: locale,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: OptionEditorPage(
                accountId: account.id,
                specificationOnly: specificationOnly,
                openingPortfolio: opening
                    ? InvestmentPortfolio(
                        accountId: account.id,
                        bookId: controller.activeBook.id,
                        currencyCode: 'USD',
                        openedAt: DateTime(2026, 10, 1),
                        openingCash: '10000',
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller: controller, account: account);
}

/// 使用稳定分组键查找整行入口，而不是依赖标题具体措辞或箭头位置。
Finder _toggle(String section) =>
    find.byKey(ValueKey('option-$section-toggle'));

/// 在入口左侧空白处点击，验证整行可操作，不要求用户准确命中文字或箭头。
/// [section] 与正式页面的分组标识一致，滚动沿用共用表单测试工具。
Future<void> _tapRow(WidgetTester tester, String section) async {
  final toggle = _toggle(section);
  await revealOptionEditorTarget(tester, toggle);
  final rect = tester.getRect(toggle);
  expect(rect.height, greaterThanOrEqualTo(44));
  await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
  await tester.pumpAndSettle();
}

/// 读取实际无障碍展开状态；必显资料没有折叠能力时应返回 null。
bool? _expanded(WidgetTester tester, String section) => tester
    .getSemantics(_toggle(section))
    .flagsCollection
    .isExpanded
    .toBoolOrNull();

/// 从当前键盘焦点向上寻找 [key]，避免依赖内部 InkWell/Focus 的组件实现细节。
bool _focusIsInside(Key key) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  var found = context.widget.key == key;
  context.visitAncestorElements((element) {
    if (element.widget.key == key) found = true;
    return !found;
  });
  return found;
}

/// 只验证用户可见的折叠行为与可访问性；不固定颜色数值或内部布局树。
/// testWidgets 默认启用并释放语义树，不额外创建需手动管理的 SemanticsHandle。
void main() {
  useTestDatabases();

  testWidgets('三组整行入口明确朗读展开状态，收起再展开保留草稿且不写账', (tester) async {
    final fixture = await _openEditor(tester);
    final before = fixture.controller
        .investmentFor(fixture.account.id)!
        .toJson();
    for (final group in [
      (section: 'details', field: 'name', value: '自行核对的合约名称'),
      (section: 'settlement', field: 'source', value: '券商合约资料'),
      (section: 'extras', field: 'note', value: '保留这段未保存的备注'),
    ]) {
      await revealOptionEditorTarget(tester, _toggle(group.section));
      expect(_expanded(tester, group.section), isFalse);
      expect(
        tester.getSemantics(_toggle(group.section)).flagsCollection.isButton,
        isTrue,
      );
      await _tapRow(tester, group.section);
      expect(_expanded(tester, group.section), isTrue);
      if (group.section == 'settlement') {
        final title = tester.getSemantics(_toggle(group.section)).label;
        expect(find.text(title), findsOneWidget);
      }
      final input = await revealOptionEditorField(tester, group.field);
      await tester.enterText(input, group.value);
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await _tapRow(tester, group.section);
      expect(_expanded(tester, group.section), isFalse);
      expect(find.byKey(ValueKey('option-${group.field}')), findsNothing);
      await _tapRow(tester, group.section);
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('option-${group.field}')))
            .controller!
            .text,
        group.value,
      );
      await _tapRow(tester, group.section);
    }
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.toJson(),
      before,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('分组入口可通过键盘Tab聚焦及空格切换', (tester) async {
    await _openEditor(tester);
    const key = ValueKey('option-details-toggle');
    await revealOptionEditorTarget(tester, find.byKey(key));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    for (var step = 0; step < 30 && !_focusIsInside(key); step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }
    expect(_focusIsInside(key), isTrue);
    expect(_expanded(tester, 'details'), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_expanded(tester, 'details'), isTrue);
    expect(find.byKey(const ValueKey('option-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文窄屏大字号可完整展示并切换三组入口', (tester) async {
    await _openEditor(
      tester,
      locale: const Locale('en'),
      scale: 1.6,
      size: const Size(360, 852),
    );
    for (final section in ['details', 'settlement', 'extras']) {
      await _tapRow(tester, section);
      expect(_expanded(tester, section), isTrue);
      await _tapRow(tester, section);
      expect(_expanded(tester, section), isFalse);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('规格核对页必显合约资料没有无效的收起操作', (tester) async {
    await _openEditor(tester, specificationOnly: true);
    await revealOptionEditorTarget(tester, _toggle('details'));
    expect(_expanded(tester, 'details'), isNull);
    expect(
      tester
          .getSemantics(_toggle('details'))
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isFalse,
    );
    expect(find.byKey(const ValueKey('option-name')), findsOneWidget);
    expect(find.byKey(const ValueKey('option-strike')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('冻结保证金操作中的必显字段没有虚假折叠状态', (tester) async {
    await _openEditor(tester);
    final operation = find.text('操作类型');
    await revealOptionEditorTarget(tester, operation);
    await tester.tap(operation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('冻结保证金').last);
    await tester.pumpAndSettle();
    await revealOptionEditorTarget(tester, _toggle('extras'));
    expect(_expanded(tester, 'extras'), isNull);
    expect(
      tester
          .getSemantics(_toggle('extras'))
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isFalse,
    );
    expect(find.byKey(const ValueKey('option-margin')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('期初更多信息只说明实际隐藏的冻结金额，参考价始终可见', (tester) async {
    final fixture = await _openEditor(tester, opening: true);
    await revealOptionEditorTarget(tester, _toggle('extras'));
    final node = tester.getSemantics(_toggle('extras'));
    expect(node.value, contains('冻结'));
    expect(node.value, isNot(contains('参考价')));
    expect(node.value, isNot(contains('备注')));
    expect(find.byKey(const ValueKey('option-reference')), findsOneWidget);
    expect(find.byKey(const ValueKey('option-margin')), findsNothing);
    await _tapRow(tester, 'extras');
    expect(find.byKey(const ValueKey('option-margin')), findsOneWidget);
    await _tapRow(tester, 'extras');
    expect(find.byKey(const ValueKey('option-margin')), findsNothing);
    expect(find.byKey(const ValueKey('option-reference')), findsOneWidget);
    expect(fixture.controller.investmentFor(fixture.account.id), isNull);
    expect(tester.takeException(), isNull);
  });
}
