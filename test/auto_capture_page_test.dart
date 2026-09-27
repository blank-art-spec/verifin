import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/auto_capture_page.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('自动采集页展示权限开关、状态面板和空队列', (tester) async {
    final controller = await makeController();
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AutoCapturePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('自动记账与智能识别'), findsOneWidget);
    expect(find.text('支付通知监听'), findsOneWidget);
    expect(find.text('消费短信补充'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('暂时没有待处理事件'),
      180,
      scrollable: firstVerticalScrollable(),
    );
    expect(find.text('暂时没有待处理事件'), findsOneWidget);
  });
}
