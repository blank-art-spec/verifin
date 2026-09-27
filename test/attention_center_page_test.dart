import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/attention_center_page.dart';
import 'package:verifin/pages/transaction_detail_page.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('异常中心空态会明确告知当前无待处理问题', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AttentionCenterPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('异常处理中心'), findsOneWidget);
    expect(find.text('待处理 0'), findsOneWidget);
    expect(find.text('暂无待处理异常'), findsOneWidget);
  });

  testWidgets('对账金额冲突显示金额并可进入交易详情', (tester) async {
    final controller = await makeController();
    addTearDown(controller.dispose);
    final category = controller.categories.firstWhere(
      (item) => item.type == EntryType.expense,
    );
    controller.addEntry(
      LedgerEntry(
        id: 'attention-conflict',
        bookId: controller.activeBook.id,
        type: EntryType.expense,
        amount: 128,
        categoryId: category.id,
        accountId: '',
        note: '对账冲突测试',
        occurredAt: DateTime(2026, 9, 27),
        reconciliationStatus: ReconciliationStatus.amountConflict,
      ),
    );
    await tester.pumpWidget(
      VeriFinScope(
        controller: controller,
        child: zhMaterialApp(home: const AttentionCenterPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('待处理 1'), findsOneWidget);
    expect(find.text('金额冲突'), findsWidgets);
    expect(find.text('对账冲突测试'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);

    await tester.tap(find.text('对账冲突测试'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionDetailPage), findsOneWidget);
  });
}
