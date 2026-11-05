import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/pages/investment_setup_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  testWidgets('期初现金草稿绑定首次币种，账户换币后禁止保存且保留原输入', (tester) async {
    final c = await makeController();
    addTearDown(c.dispose);
    final account = investmentAccountFixture().copyWith(initialBalance: 0);
    c.addAccount(account);
    await c.waitForPendingWrites();
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: InvestmentSetupPage(accountId: account.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('opening-cash')), '5000');
    await tester.pumpAndSettle();

    // 尚未落账的账户仍可编辑币种，但已打开的现金草稿不能被重新解释。
    expect(
      await c.saveAccountDraft(account.copyWith(currencyCode: 'HKD')),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未保存：'), findsOneWidget);
    expect(find.byKey(const Key('opening-save')), findsNothing);
    expect(find.byKey(const Key('opening-cash')), findsNothing);
    expect(c.investmentFor(account.id), isNull);
    expect(
      c.accountBalance(c.accounts.singleWhere((a) => a.id == account.id)),
      0,
    );

    // 恢复原币种后才重新展示同一份草稿，过程中不能提前创建投资组合。
    expect(await c.saveAccountDraft(account), isTrue);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('opening-cash')))
          .controller!
          .text,
      '5000',
    );
    expect(c.investmentFor(account.id), isNull);
    expect(tester.takeException(), isNull);
  });
}
