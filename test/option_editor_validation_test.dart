import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/option_editor_page.dart';

import 'support/investment_fixture.dart';
import 'support/option_editor_harness.dart';
import 'support/test_harness.dart';

/// 建立只有现金的隔离账户并打开正式期权页面。
/// [cash] 用于构造资金不足边界；[scale] 覆盖大字号下的错误文字和自动定位。
Future<({VeriFinController controller, Account account})> _openEditor(
  WidgetTester tester, {
  String cash = '10000',
  double scale = 1,
}) async {
  final controller = await makeController();
  final account = investmentAccountFixture();
  addTearDown(controller.dispose);
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: cash,
      openedAt: DateTime(2026, 10, 1),
    ),
    isTrue,
  );
  await tester.binding.setSurfaceSize(const Size(360, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: OptionEditorPage(accountId: account.id),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller: controller, account: account);
}

/// 在真实文本框写入 [value]，并结束键盘输入，避免键盘遮住下一项操作。
Future<void> _enter(WidgetTester tester, String field, String value) async {
  final input = await revealOptionEditorField(tester, field);
  await tester.enterText(input, value);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

/// 填写仅供离线测试的远期标准代码及一张买入事实，不查询或确认真实挂牌。
/// [multiplier] 必须由用例明确给出；参考价刻意留空，用于检查显式估值选择。
Future<void> _fillTrade(
  WidgetTester tester, {
  String multiplier = '100',
  String quantity = '1',
  String fee = '0',
}) async {
  for (final entry in {
    'symbol': 'AVGO991218C00050000',
    'multiplier': multiplier,
    'quantity': quantity,
    'price': '2',
    'fee': fee,
  }.entries) {
    await _enter(tester, entry.key, entry.value);
  }
}

/// 用户主动勾选以成交价暂估；不直接改控制器，验证该授权入口本身可用。
Future<void> _useTradePrice(WidgetTester tester) async {
  final choice = find.byKey(const ValueKey('option-use-trade-price'));
  await revealOptionEditorTarget(tester, choice);
  expect(tester.widget<CheckboxListTile>(choice).value, isFalse);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

/// 点击真实预览按钮，随后让页面完成校验、展开错误分组及滚动定位。
Future<void> _preview(WidgetTester tester) async {
  final preview = find.widgetWithText(OutlinedButton, '预览结算后现金与持仓');
  await revealOptionEditorTarget(tester, preview);
  await tester.tap(preview);
  await tester.pumpAndSettle();
}

/// 读取已展示输入框的局部错误；用于防止退回只有页底笼统提示的旧行为。
String? _errorFor(WidgetTester tester, String field) {
  final decoration = tester
      .widget<TextField>(find.byKey(ValueKey('option-$field')))
      .decoration;
  final error = decoration?.error;
  return error is Text ? error.data : decoration?.errorText;
}

/// 验证简化默认界面、明确估值选择与字段级错误，不替代 Android 真机验收。
void main() {
  useTestDatabases();

  testWidgets('普通开仓默认收起详情和选填项，代码本地补身份但不猜乘数', (tester) async {
    final fixture = await _openEditor(tester);
    expect(find.byKey(const ValueKey('option-source')), findsNothing);
    expect(find.byKey(const ValueKey('option-underlyingPrice')), findsNothing);
    await _enter(tester, 'symbol', 'AVGO991218C00050000');
    final multiplier = await revealOptionEditorField(tester, 'multiplier');
    expect(tester.widget<TextField>(multiplier).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('option-name')), findsNothing);
    expect(find.byKey(const ValueKey('option-reference')), findsNothing);
    final strike = await revealOptionEditorField(tester, 'strike');
    expect(tester.widget<TextField>(strike).controller!.text, '50');
    final underlying = await revealOptionEditorField(tester, 'underlying');
    expect(tester.widget<TextField>(underlying).controller!.text, 'AVGO');
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('漏填乘数时显示字段错误并定位，预览不写入账目', (tester) async {
    final fixture = await _openEditor(tester, scale: 1.6);
    await _fillTrade(tester, multiplier: '');
    await _useTradePrice(tester);
    await _preview(tester);
    expect(_errorFor(tester, 'multiplier'), contains('乘数'));
    expect(
      find.byKey(const ValueKey('option-multiplier')).hitTestable(),
      findsOneWidget,
    );
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(fixture.controller.accountBalance(fixture.account), 10000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('收起的合约详情缺名称时自动展开并定位，不要求用户自行查找', (tester) async {
    final fixture = await _openEditor(tester);
    await _fillTrade(tester);
    await _enter(tester, 'name', '');
    final details = find.byKey(const ValueKey('option-details-toggle'));
    await revealOptionEditorTarget(tester, details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('option-name')), findsNothing);
    await _useTradePrice(tester);
    await _preview(tester);
    expect(_errorFor(tester, 'name'), contains('名称'));
    expect(
      find.byKey(const ValueKey('option-name')).hitTestable(),
      findsOneWidget,
    );
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  for (final invalid in [
    (field: 'quantity', value: '1.5', message: '正整数'),
    (field: 'fee', value: 'abc', message: '有效数字'),
    (field: 'fee', value: '3.231', message: '小数'),
    (field: 'margin', value: '0.001', message: '小数'),
  ]) {
    testWidgets('无效${invalid.field}在对应字段解释原因并保留原输入', (tester) async {
      final fixture = await _openEditor(tester);
      await _fillTrade(tester);
      await _enter(tester, invalid.field, invalid.value);
      await _useTradePrice(tester);
      await _preview(tester);
      final input = find.byKey(ValueKey('option-${invalid.field}'));
      expect(_errorFor(tester, invalid.field), contains(invalid.message));
      expect(tester.widget<TextField>(input).controller!.text, invalid.value);
      expect(input.hitTestable(), findsOneWidget);
      expect(
        fixture.controller.investmentFor(fixture.account.id)!.events,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('未确认交割规格时仍定位已填的非法股数和行权现金', (tester) async {
    final fixture = await _openEditor(tester);
    await _fillTrade(tester);
    await _useTradePrice(tester);
    await expandOptionEditorSection(tester, 'settlement');
    final settlement = find.text('核对合约规格');
    await revealOptionEditorTarget(tester, settlement);
    await tester.tap(settlement);
    await tester.pumpAndSettle();
    await tester.tap(find.text('实物行权 / 指派').last);
    await tester.pumpAndSettle();
    await _enter(tester, 'shares', '-1');
    await _enter(tester, 'exercise', 'abc');
    await _preview(tester);
    expect(_errorFor(tester, 'shares'), contains('不小于 0'));
    expect(_errorFor(tester, 'exercise'), contains('有效数字'));
    expect(
      find.byKey(const ValueKey('option-shares')).hitTestable(),
      findsOneWidget,
    );
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('更换完整代码不会覆盖手填行权价，但必须定位身份冲突才能保存', (tester) async {
    final fixture = await _openEditor(tester);
    await _fillTrade(tester);
    await _useTradePrice(tester);
    await _enter(tester, 'strike', '60');
    await _enter(tester, 'symbol', 'AVGO991218C00070000');
    final details = find.byKey(const ValueKey('option-details-toggle'));
    await revealOptionEditorTarget(tester, details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('option-strike')), findsNothing);
    await _preview(tester);
    final strike = find.byKey(const ValueKey('option-strike'));
    expect(_errorFor(tester, 'strike'), contains('完整代码不一致'));
    expect(tester.widget<TextField>(strike).controller!.text, '60');
    expect(strike.hitTestable(), findsOneWidget);
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('参考价漏填会展开并定位，明确选成交价暂估后才允许预览保存', (tester) async {
    final fixture = await _openEditor(tester);
    await _fillTrade(tester);
    await _preview(tester);
    final reference = find.byKey(const ValueKey('option-reference'));
    expect(reference.hitTestable(), findsOneWidget);
    expect(_errorFor(tester, 'reference'), isNotNull);
    expect(tester.widget<TextField>(reference).controller!.text, isEmpty);
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );

    await _useTradePrice(tester);
    await _preview(tester);
    final save = find.widgetWithText(FilledButton, '保存');
    await revealOptionEditorTarget(tester, save);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = fixture.controller.investmentFor(fixture.account.id)!;
    expect(saved.events, hasLength(1));
    expect(saved.events.single.price, '2');
    expect(saved.manualPrices[saved.events.single.securityId], '2');
    expect(fixture.controller.accountBalance(fixture.account), 9800);
    expect(tester.takeException(), isNull);
  });

  testWidgets('现金不足直接解释资金原因，不再仅提示检查所有字段', (tester) async {
    final fixture = await _openEditor(tester, cash: '100');
    await _fillTrade(tester);
    await _useTradePrice(tester);
    await _preview(tester);
    expect(find.textContaining(RegExp('现金.*不足|不足.*现金')), findsWidgets);
    expect(
      fixture.controller.investmentFor(fixture.account.id)!.events,
      isEmpty,
    );
    expect(fixture.controller.accountBalance(fixture.account), 100);
    expect(tester.takeException(), isNull);
  });
}
