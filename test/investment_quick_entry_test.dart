import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/entry_sheets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/entry_detail_page.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/quick_entry.dart';
import 'package:verifin/pages/transaction_entry_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 通过可点击和可长按的真实按钮调用共享入口，保留现有手势偏好语义。
Widget _quickEntryHome() => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: FilledButton(
        key: const Key('launch-quick-entry'),
        onPressed: () => startQuickEntry(context: context),
        onLongPress: () => startQuickEntry(context: context, longPress: true),
        child: const Text('新增记录'),
      ),
    ),
  ),
);

void main() {
  useTestDatabases();

  testWidgets('普通账本手动新增仍先计算器，取消零写入，确认金额后才进入普通明细', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: _quickEntryHome()),
      ),
    );
    await tester.tap(find.byKey(const Key('launch-quick-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(NumberPadSheet), findsOneWidget);
    expect(find.byType(TransactionEntryPage), findsNothing);
    expect(find.byType(EntryDetailPage), findsNothing);
    Navigator.of(tester.element(find.byType(NumberPadSheet))).pop();
    await tester.pumpAndSettle();
    expect(c.entries, isEmpty);
    expect(find.byType(EntryDetailPage), findsNothing);

    await tester.tap(find.byKey(const Key('launch-quick-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number_key_8')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    expect(find.byType(NumberPadSheet), findsNothing);
    expect(find.byType(EntryDetailPage), findsOneWidget);
    expect(find.byType(TransactionEntryPage), findsNothing);
    expect(
      tester
          .widget<EntryDetailPage>(find.byType(EntryDetailPage))
          .initialAmount,
      8,
    );
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [
    FabActionMode.manual,
    FabActionMode.manualTapAiLongPress,
  ]) {
    testWidgets('投资账本 ${mode.name} 点击直接投资表单，普通页签按需输入金额', (tester) async {
      final c = await makeController();
      addTearDown(c.dispose);
      expect(
        await c.changeLedgerBookType(
          c.activeBook.id,
          LedgerBookType.investment,
        ),
        isTrue,
      );
      c.setFabActionMode(mode);
      final account = investmentAccountFixture(id: 'quick-entry-securities');
      expect(
        await c.createSecuritiesAccount(account: account, openingCash: '10000'),
        isTrue,
      );
      final bookId = c.activeBook.id;
      await tester.pumpWidget(
        VeriFinScope(
          controller: c,
          child: zhMaterialApp(home: _quickEntryHome()),
        ),
      );
      await tester.tap(find.byKey(const Key('launch-quick-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(NumberPadSheet), findsNothing);
      expect(find.byType(TransactionEntryPage), findsOneWidget);
      expect(
        tester
            .widget<TransactionEntryPage>(find.byType(TransactionEntryPage))
            .bookId,
        bookId,
      );
      expect(find.byType(StockEditorPage), findsOneWidget);
      expect(find.byKey(const ValueKey('stock-symbol')), findsOneWidget);
      expect(find.byType(EntryDetailPage), findsNothing);
      // 分段控件只给选中项的前景动画副本挂 Key，未选项按用户可见文案点击。
      await tester.tap(
        find
            .descendant(
              of: find.byKey(const Key('transaction-entry-mode')),
              matching: find.text('普通记账'),
            )
            .hitTestable()
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(EntryDetailPage), findsOneWidget);
      expect(find.byType(NumberPadSheet), findsNothing);
      expect(c.entries, isEmpty);
      expect(c.investmentFor(account.id)!.events, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in [FabActionMode.ai, FabActionMode.manualTapAiLongPress]) {
    testWidgets('投资账本 ${mode.name} 主动 AI 动作保持原配置引导', (tester) async {
      final c = await makeController();
      addTearDown(c.dispose);
      await c.changeLedgerBookType(c.activeBook.id, LedgerBookType.investment);
      c.setFabActionMode(mode);
      await tester.pumpWidget(
        VeriFinScope(
          controller: c,
          child: zhMaterialApp(home: _quickEntryHome()),
        ),
      );
      if (mode == FabActionMode.ai) {
        await tester.tap(find.byKey(const Key('launch-quick-entry')));
      } else {
        await tester.longPress(find.byKey(const Key('launch-quick-entry')));
      }
      await tester.pumpAndSettle();
      expect(find.text('尚未配置 AI'), findsOneWidget);
      expect(find.text('去设置'), findsOneWidget);
      expect(find.byType(NumberPadSheet), findsNothing);
      expect(find.byType(TransactionEntryPage), findsNothing);
      expect(c.entries, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('计算器打开后切换账本，确认旧金额不会进入其他账本的录入页', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final originalBook = c.activeBook.id;
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: _quickEntryHome()),
      ),
    );
    await tester.tap(find.byKey(const Key('launch-quick-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number_key_8')));
    await tester.pump();
    expect(
      await c.createLedgerBook('切换后的投资账本', bookType: LedgerBookType.investment),
      isTrue,
    );
    expect(c.activeBook.id, isNot(originalBook));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('number_pad_ok')));
    await tester.pumpAndSettle();
    expect(find.byType(NumberPadSheet), findsNothing);
    expect(find.byType(EntryDetailPage), findsNothing);
    expect(find.byType(TransactionEntryPage), findsNothing);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
