import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/investments/investment_security_autocomplete.dart';
import 'package:verifin/app/investments/investment_security_suggestions.dart';
import 'package:verifin/app/models.dart';

import 'support/test_harness.dart';

/// 以窄屏、大字号和键盘遮挡验证真实浮层的宽高、滚动及外部控制器生命周期。
void main() {
  testWidgets('窄屏大字号候选在键盘上方滚动，选择后仍沿用外部控制器', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // FlutterView 的边距使用物理像素；固定 DPR1 才能真实模拟 300dp 键盘。
    // Portal 的安全区来自根 Overlay，不能只靠 home 内的 MediaQuery 声明键盘高度。
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    InvestmentSecuritySuggestion? selected;
    final suggestions = List.generate(
      16,
      (index) => InvestmentSecuritySuggestion(
        security: StockSecurity(
          symbol: 'TEST-$index',
          name: '用于验证完整换行的证券名称与长代码 $index',
          market: StockMarket.us,
          currencyCode: 'USD',
        ),
      ),
    );
    await tester.pumpWidget(
      zhMaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 852),
            viewInsets: EdgeInsets.only(bottom: 300),
            textScaler: TextScaler.linear(1.8),
          ),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.fromLTRB(16, 180, 16, 0),
              child: InvestmentSecurityAutocomplete(
                controller: controller,
                fieldKey: const Key('symbol'),
                label: '证券代码',
                suggestions: suggestions,
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('symbol')), 'TEST');
    await tester.pumpAndSettle();
    final panel = find.byKey(const Key('investment-security-options'));
    final panelRect = tester.getRect(panel);
    expect(panelRect.left, greaterThanOrEqualTo(16));
    expect(panelRect.right, lessThanOrEqualTo(344));
    expect(panelRect.height, lessThanOrEqualTo(240));
    expect(panelRect.top, greaterThanOrEqualTo(0));
    expect(panelRect.bottom, lessThanOrEqualTo(552));
    final last = find.byKey(
      const ValueKey('investment-security-us:stock:TEST-15'),
    );
    await tester.scrollUntilVisible(
      last,
      150,
      scrollable: find.descendant(of: panel, matching: find.byType(Scrollable)),
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(selected?.security.symbol, 'TEST-15');
    expect(controller.text, 'TEST-15');
    expect(panel, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.text = '外部控制器仍可编辑';
    expect(tester.takeException(), isNull);
  });

  testWidgets('异步新候选主动展开且键盘可选择，未命中继续手填', (tester) async {
    final controller = TextEditingController(text: 'bt');
    addTearDown(controller.dispose);
    InvestmentSecuritySuggestion? selected;
    var results = <InvestmentSecuritySuggestion>[];
    var request = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Padding(
                padding: const EdgeInsets.all(16),
                child: InvestmentSecurityAutocomplete(
                  controller: controller,
                  fieldKey: const Key('symbol'),
                  label: '证券代码',
                  suggestions: results,
                  openRequest: request,
                  onSelected: (value) => selected = value,
                ),
              );
            },
          ),
        ),
      ),
    );
    rebuild(() {
      results = [
        const InvestmentSecuritySuggestion(
          security: StockSecurity(
            symbol: 'AVGO',
            name: '博通',
            market: StockMarket.us,
            currencyCode: 'USD',
          ),
          matchedQuery: 'bt',
        ),
      ];
      request++;
    });
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('investment-security-options')),
      findsOneWidget,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(selected?.security.symbol, 'AVGO');
    await tester.enterText(find.byKey(const Key('symbol')), 'NEW-MANUAL');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    expect(controller.text, 'NEW-MANUAL');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('上下键后异步候选缩短不会沿用旧索引或滚动到已移除证券', (tester) async {
    final controller = TextEditingController(text: 'TEST');
    addTearDown(controller.dispose);
    InvestmentSecuritySuggestion? selected;
    var results = List.generate(
      16,
      (index) => InvestmentSecuritySuggestion(
        security: StockSecurity(
          symbol: 'TEST-$index',
          name: '候选 $index',
          market: StockMarket.us,
          currencyCode: 'USD',
        ),
      ),
    );
    var request = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Padding(
                padding: const EdgeInsets.all(16),
                child: InvestmentSecurityAutocomplete(
                  controller: controller,
                  fieldKey: const Key('symbol'),
                  label: '证券代码',
                  suggestions: results,
                  openRequest: request,
                  onSelected: (value) => selected = value,
                ),
              );
            },
          ),
        ),
      ),
    );
    rebuild(() => request++);
    await tester.pumpAndSettle();
    for (var index = 0; index < 10; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    // 不先推进帧：上方箭头登记的延后滚动可能与这一轮候选替换交错。
    rebuild(() => results = [results.last]);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(selected?.security.symbol, 'TEST-15');
    expect(controller.text, 'TEST-15');
    expect(tester.takeException(), isNull);
  });

  testWidgets('聚焦代码框完全滚出视口后不残留覆盖表单的候选浮层', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            key: const Key('form-list'),
            // 非懒加载的列保留离屏输入，确保测到的是几何可见性，而非 Sliver 的离屏管理。
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                InvestmentSecurityAutocomplete(
                  controller: controller,
                  fieldKey: const Key('symbol'),
                  label: '证券代码',
                  suggestions: const [
                    InvestmentSecuritySuggestion(
                      security: StockSecurity(
                        symbol: 'TEST',
                        name: '本地证券',
                        market: StockMarket.us,
                        currencyCode: 'USD',
                      ),
                    ),
                  ],
                  onSelected: (_) {},
                ),
                const SizedBox(height: 1600),
              ],
            ),
          ),
        ),
      ),
    );
    final input = find.byKey(const Key('symbol'));
    await tester.enterText(input, 'TEST');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('investment-security-options')),
      findsOneWidget,
    );
    // 固定滚动到 210dp，避免测试惯性把输入框甩出缓存后销毁，误测成生命周期用例。
    // 保留原焦点和真实组件，验证同一输入框离开视口后实际浮层不再绘制。
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(210);
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    expect(tester.getRect(input).bottom, lessThan(0));
    expect(find.byKey(const Key('investment-security-options')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
