import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/main.dart';
import 'package:verifin/pages/home_page.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('首页先显示概览，再用可展开摘要容纳多张信用账户', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 1400);
    addTearDown(tester.view.reset);
    final controller = await makeController();
    for (var index = 1; index <= 3; index++) {
      expect(
        await controller.addAccountDraft(
          Account(
            id: 'credit-$index',
            bookId: controller.activeBook.id,
            name: '测试信用卡$index',
            type: AccountType.creditCard,
            groupId: null,
            initialBalance: -index * 100,
            iconCode: 'credit',
            note: '',
            includeInAssets: true,
            hidden: false,
            statementDay: 25,
            dueDay: 13,
          ),
        ),
        isTrue,
      );
    }
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('信用账户 · 3 个'), findsOneWidget);
    expect(find.text('测试信用卡1'), findsNothing);
    expect(find.byType(CreditAccountCycleCard), findsNothing);
    expect(
      tester.getRect(find.byType(HomeTrendPanel)).top,
      lessThan(tester.getRect(find.text('信用账户 · 3 个')).top),
    );

    await tester.tap(find.byKey(const Key('home_credit_show_all')));
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    await tester.drag(firstVerticalScrollable(), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('测试信用卡1'), findsOneWidget);
    await tester.tap(find.text('测试信用卡1'));
    await tester.pumpAndSettle();
    expect(find.byType(CreditAccountCycleCard), findsOneWidget);
    expect(find.text('本账期净消费'), findsOneWidget);
    expect(find.text('已出账待还'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
