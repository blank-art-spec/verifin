import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/sheets.dart';

import 'support/test_harness.dart';

/// 创建账户选择测试所需的普通账户或信用子账户。
/// [id] 同时作为测试名称；[currency] 是账户币种；[parent] 关联已有信用主体。
Account _pickerAccount(
  String id, {
  String currency = 'CNY',
  String? parent,
  AccountType type = AccountType.creditCard,
}) => Account(
  id: id,
  bookId: 'default',
  name: id,
  type: type,
  groupId: null,
  initialBalance: 0,
  iconCode: type.supportsCredit ? 'credit' : 'cash',
  note: '',
  includeInAssets: true,
  hidden: false,
  currencyCode: currency,
  creditAccountId: parent,
);

/// 打开真实账户选择器；[includeParents] 区分普通记账与转账的选择方式。
/// [tester] 驱动界面，[controller] 提供当前账本，选择结果只返回而不写账。
/// [brightness] 指定浅色或深色主题，用于检查两套主题中的相同对齐规则。
Future<void> _openPicker(
  WidgetTester tester,
  VeriFinController controller, {
  bool includeParents = true,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAccountPickerSheet(
                context: context,
                title: '选择账户',
                accounts: controller.accounts,
                selectedId: '人民币账户',
                balanceOf: controller.accountBalance,
                noneLabel: includeParents ? '无账户' : null,
                noneHint: includeParents ? '只记金额，不影响账户余额' : null,
                includeCreditParents: includeParents,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// 返回包含 [label] 的列表行，避免把弹窗外的账户名称当成候选项。
Finder _row(String label) => find.ancestor(
  of: find.textContaining(label, findRichText: true),
  matching: find.byType(ListTile),
);

/// 注册去重、选中、布局与转账候选回归，所有数据都由内存仓储隔离。
void main() {
  useTestDatabases();

  testWidgets('普通记账只列信用父账户，普通账户保留且未选择时不写账', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    expect(await c.addAccountDraft(_pickerAccount('人民币账户')), isTrue);
    final parentId = c.accounts.single.creditAccountId!;
    expect(
      await c.addAccountDraft(
        _pickerAccount('美元账户', currency: 'USD', parent: parentId),
      ),
      isTrue,
    );
    expect(
      await c.addAccountDraft(_pickerAccount('现金', type: AccountType.cash)),
      isTrue,
    );
    await _openPicker(tester, c);

    // 同一信用主体只占一行；不显示其美元子账户，普通现金账户仍可选。
    expect(_row('人民币账户'), findsOneWidget);
    expect(_row('美元账户'), findsNothing);
    expect(_row('现金'), findsOneWidget);
    expect(find.textContaining('(父账户)'), findsNothing);
    final selectedParent = _row('人民币账户');
    expect(
      find.descendant(of: selectedParent, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(
      tester.getTopLeft(_row('无账户')).dy,
      lessThan(tester.getTopLeft(selectedParent).dy),
    );
    expect(c.entries, isEmpty);
  });

  for (final width in <double>[393, 360]) {
    for (final brightness in Brightness.values) {
      testWidgets('无账户、信用父账户和普通账户的图标文字对齐 $width $brightness', (tester) async {
        tester.view.physicalSize = Size(width, 852);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = width == 360
            ? 1.5
            : 1;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final c = await makeController();
        addTearDown(c.dispose);
        expect(await c.addAccountDraft(_pickerAccount('人民币账户')), isTrue);
        expect(
          await c.addAccountDraft(_pickerAccount('现金', type: AccountType.cash)),
          isTrue,
        );
        await _openPicker(tester, c, brightness: brightness);

        final none = tester.widget<ListTile>(_row('无账户'));
        final parent = tester.widget<ListTile>(_row('人民币账户'));
        final cash = tester.widget<ListTile>(_row('现金'));
        final iconLeft = tester.getTopLeft(find.byWidget(none.leading!)).dx;
        final textLeft = tester.getTopLeft(find.byWidget(none.title!)).dx;
        for (final tile in <ListTile>[parent, cash]) {
          expect(tester.getTopLeft(find.byWidget(tile.leading!)).dx, iconLeft);
          expect(tester.getTopLeft(find.byWidget(tile.title!)).dx, textLeft);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('转账仍可直接选择各币种子账户', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    expect(await c.addAccountDraft(_pickerAccount('人民币账户')), isTrue);
    expect(
      await c.addAccountDraft(
        _pickerAccount(
          '美元账户',
          currency: 'USD',
          parent: c.accounts.single.creditAccountId,
        ),
      ),
      isTrue,
    );
    await _openPicker(tester, c, includeParents: false);

    expect(_row('人民币账户'), findsOneWidget);
    expect(_row('美元账户'), findsOneWidget);
    expect(_row('无账户'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });
}
