import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/pages/sheets.dart';

import 'support/test_harness.dart';

/// 从真实页面打开公共编辑弹层；保存回调由用例控制，不需要账目 Controller。
Future<void> _openEditor(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open,
) async {
  await tester.pumpWidget(
    zhMaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('打开账本编辑'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开账本编辑'));
  await tester.pumpAndSettle();
}

/// 通过真实类型选择控件修改本地草稿，而不是直接调用内部状态或保存回调。
Future<void> _chooseInvestment(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('ledger_book_type_field')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('投资账本').last);
  await tester.pumpAndSettle();
}

/// 保存期间尝试下拖和系统返回；两条退出路径均不得绕过正在进行的提交。
Future<void> _attemptBusyDismiss(WidgetTester tester, Finder save) async {
  final sheet = find.byType(BottomSheet);
  expect(sheet, findsOneWidget);
  // 拖拽关闭在 Flutter 内直接 pop，单靠 PopScope 无法保护异步提交。
  expect(tester.widget<BottomSheet>(sheet).enableDrag, isFalse);
  expect(tester.widget<FilledButton>(save).onPressed, isNull);
  final rect = tester.getRect(sheet);
  await tester.dragFrom(
    Offset(rect.center.dx, rect.top + 4),
    const Offset(0, 500),
  );
  await tester.pumpAndSettle();
  expect(sheet, findsOneWidget);
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(sheet, findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('新建账本保存中下拖与系统返回不取消，失败保留名称类型并允许正常返回', (tester) async {
    final pending = Completer<bool>();
    var completed = false;
    var saveCount = 0;
    ({String name, String currencyCode, LedgerBookType bookType})? result;
    ({String name, String currencyCode, LedgerBookType bookType})? submitted;
    await _openEditor(tester, (context) async {
      result = await showLedgerBookEditorSheet(
        context: context,
        initialCurrencyCode: 'USD',
        onSave: (draft) {
          submitted = draft;
          saveCount++;
          return pending.future;
        },
      );
      completed = true;
    });
    final name = find.byKey(const Key('ledger_book_name_field'));
    await tester.enterText(name, '仍在保存的投资账本');
    await _chooseInvestment(tester);
    final save = find.byKey(const Key('ledger_book_save_button'));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saveCount, 1);
    expect(submitted?.name, '仍在保存的投资账本');
    expect(submitted?.currencyCode, 'USD');
    expect(submitted?.bookType, LedgerBookType.investment);
    await _attemptBusyDismiss(tester, save);
    expect(completed, isFalse);
    expect(saveCount, 1);

    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.widget<TextField>(name).controller!.text, '仍在保存的投资账本');
    expect(
      tester
          .widget<SelectField>(find.byKey(const Key('ledger_book_type_field')))
          .value,
      '投资账本',
    );
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(completed, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(completed, isTrue);
    expect(result, isNull);
    expect(saveCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修改账本类型保存中下拖与系统返回不取消，失败保留选择并允许正常返回', (tester) async {
    final pending = Completer<bool>();
    var completed = false;
    var saveCount = 0;
    LedgerBookType? result;
    LedgerBookType? submitted;
    await _openEditor(tester, (context) async {
      result = await showLedgerBookTypeEditorSheet(
        context: context,
        initialType: LedgerBookType.normal,
        onSave: (type) {
          submitted = type;
          saveCount++;
          return pending.future;
        },
      );
      completed = true;
    });
    await _chooseInvestment(tester);
    final save = find.byKey(const Key('ledger_book_type_save'));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saveCount, 1);
    expect(submitted, LedgerBookType.investment);
    await _attemptBusyDismiss(tester, save);
    expect(completed, isFalse);
    expect(saveCount, 1);

    pending.complete(false);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectField>(find.byKey(const Key('ledger_book_type_field')))
          .value,
      '投资账本',
    );
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(completed, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(completed, isTrue);
    expect(result, isNull);
    expect(saveCount, 1);
    expect(tester.takeException(), isNull);
  });
}
