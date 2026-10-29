import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/calendar_days.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/currency_math.dart';
import 'package:verifin/app/investments/fund_reference_history.dart';
import 'package:verifin/app/investments/investment_decimal.dart';
import 'package:verifin/app/investments/quote_format.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/fund_entry_page.dart';
import 'package:verifin/pages/fund_reference_history_section.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 仅用于本地表单与现金语义验收的固定基金身份，不向任何网络来源发送测试请求。
const _fund = StockSecurity(
  symbol: 'HK0001039582',
  name: '招商美元货币市场基金 B 类',
  market: StockMarket.hk,
  currencyCode: 'USD',
  type: InvestmentSecurityType.fund,
);

/// 将香港日期 [date] 平移 [days] 个日历日，并重建 UTC 零点载体。
/// 通用日历运算会返回本地日期，不能直接把该结果当成领域要求的纯香港日期。
DateTime _shiftFundDate(DateTime date, int days) {
  final shifted = addCalendarDays(date, days);
  return DateTime.utc(shifted.year, shifted.month, shifted.day);
}

/// 创建独立美元证券账户；[holding] 仅为核对持仓卡入口建立真实期初持仓。
Future<({VeriFinController controller, Account account})> _ready({
  bool holding = false,
}) async {
  final controller = await makeController();
  final account = investmentAccountFixture();
  controller.addAccount(account);
  await controller.waitForPendingWrites();
  expect(
    await controller.enableInvestment(
      accountId: account.id,
      openingCash: '10000',
      openedAt: hongKongFundDayStart(
        _shiftFundDate(hongKongFundDate(DateTime.now()), -30),
      ),
      securities: holding ? [_fund] : [],
      openingHoldings: holding
          ? [
              StockHolding(
                securityId: _fund.id,
                short: false,
                quantity: '10',
                cost: '1000',
              ),
            ]
          : [],
      manualPrices: holding ? {_fund.id: '109.8290'} : {},
    ),
    isTrue,
  );
  addTearDown(controller.dispose);
  return (controller: controller, account: account);
}

/// 在真实导航栈推入 [page]，保存成功能够正常返回；[size] 用于窄屏滚动验收。
Future<void> _pumpEntry(
  WidgetTester tester,
  VeriFinController controller,
  Widget page, {
  Size size = const Size(393, 852),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: zhMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push<void>(MaterialPageRoute(builder: (_) => page)),
              child: const Text('打开基金表单'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开基金表单'));
  await tester.pumpAndSettle();
}

/// 通过用户滚动找到 [target]；先回到页首，避免上一步位于页尾时误向下寻找上方字段。
Future<void> _reveal(WidgetTester tester, Finder target) async {
  final scrollable = firstVerticalScrollable();
  await tester.drag(scrollable, const Offset(0, 5000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: scrollable,
    maxScrolls: 45,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// 用正式金额键盘输入 [amount]；[field] 对应业务字段，不绕过只读现金限制直接改控制器。
Future<void> _money(WidgetTester tester, String field, String amount) async {
  final input = find.byKey(ValueKey('fund-$field'));
  await _reveal(tester, input);
  await tester.tap(input);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('number_key_C')));
  for (final character in amount.split('')) {
    await tester.tap(find.byKey(Key('number_key_$character')));
  }
  await tester.pump();
  await tester.tap(find.byKey(const Key('number_pad_ok')));
  await tester.pumpAndSettle();
}

/// 净值/份额按原始十进制文本填写；[field] 不用于现金金额，避免绕开共享数字键盘。
Future<void> _decimal(WidgetTester tester, String field, String value) async {
  final input = find.byKey(ValueKey('fund-$field'));
  await _reveal(tester, input);
  await tester.enterText(input, value);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

/// 显式核对当前基准后保存；仅供已经填齐的旧基准编辑场景复用用户点击顺序。
Future<void> _saveReviewedHolding(WidgetTester tester) async {
  final reviewed = find.byKey(const Key('fund-reviewed'));
  await _reveal(tester, reviewed);
  await tester.tap(reviewed);
  await tester.pumpAndSettle();
  final save = find.byKey(const Key('fund-save'));
  await _reveal(tester, save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

/// 用正式锚点菜单选择 [rule]；选择只更新草稿，保存前仍须用户重新核对。
Future<void> _chooseAccrualRule(
  WidgetTester tester,
  FundAccrualRule rule,
) async {
  final choice = find.byKey(const Key('fund-accrual-rule'));
  await _reveal(tester, choice);
  await tester.tap(
    find.descendant(of: choice, matching: find.byType(SettingsRow)),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(ValueKey('veri_menu_item_fund-accrual-${rule.name}')),
  );
  await tester.pumpAndSettle();
}

/// 保存一笔已付、尚未确认的 [security] 申购，并进入真实确认表单。
/// [id] 用于隔离订单，测试不读取公开行情，也不把估计日期当作自动成交事实。
Future<void> _openPaidConfirmation(
  WidgetTester tester,
  VeriFinController controller,
  Account account, {
  required String id,
  StockSecurity security = _fund,
}) async {
  final today = hongKongFundDate(DateTime.now());
  expect(
    await controller.saveFundSubscription(
      accountId: account.id,
      security: security,
      subscription: FundSubscription(
        id: id,
        securityId: security.id,
        requestedAt: hongKongFundDayStart(_shiftFundDate(today, -3)),
        paidAt: hongKongFundDayStart(_shiftFundDate(today, -2)),
        cashAmount: '1000',
      ),
    ),
    isTrue,
  );
  await _pumpEntry(
    tester,
    controller,
    FundEntryPage(
      accountId: account.id,
      mode: FundEntryMode.purchase,
      subscriptionId: id,
    ),
  );
  final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
  await _reveal(tester, find.text(l.fundConfirmSubscription));
  await tester.tap(find.text(l.fundConfirmSubscription));
  await tester.pumpAndSettle();
}

/// 验收真实页面的金额入口、未确认资金和显式核对行为，不用替代页面镜像生产布局。
void main() {
  useTestDatabases();

  testWidgets('证券交易区提供两个基金金额入口，已有香港基金卡复用同一入口', (tester) async {
    final ready = await _ready(holding: true);
    final c = ready.controller;
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      VeriFinScope(
        controller: c,
        child: zhMaterialApp(home: InvestmentPage(accountId: ready.account.id)),
      ),
    );
    await tester.pumpAndSettle();
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
    final operations = find.byKey(const Key('fund-operations'));
    await _reveal(tester, operations);
    await tester.tap(operations);
    await tester.pumpAndSettle();
    expect(find.text(l.fundBuyByAmount), findsOneWidget);
    expect(find.text(l.fundRecordHolding), findsOneWidget);
    await tester.tap(find.text(l.fundBuyByAmount));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FundEntryPage>(find.byType(FundEntryPage)).mode,
      FundEntryMode.purchase,
    );
    expect(find.byType(StockEditorPage), findsNothing);
    Navigator.of(tester.element(find.byType(FundEntryPage))).pop();
    await tester.pumpAndSettle();

    final title = find.text('${_fund.name} · ${_fund.symbol}');
    await _reveal(tester, title);
    final card = find
        .ancestor(of: title, matching: find.byType(VeriCard))
        .first;
    final cardOperations = find.descendant(
      of: card,
      matching: find.byType(FundOperationsButton),
    );
    await _reveal(tester, cardOperations);
    await tester.tap(cardOperations);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l.fundRecordHolding));
    await tester.pumpAndSettle();
    final entry = tester.widget<FundEntryPage>(find.byType(FundEntryPage));
    expect(entry.mode, FundEntryMode.holdingBaseline);
    expect(entry.securityId, _fund.id);
    expect(c.investmentFor(ready.account.id)!.events, isEmpty);
    expect(c.accountBalance(ready.account), 10000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('金额买入只按实际扣款形成在途资金，估算净值不会自动确认份额', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.purchase,
        securityId: _fund.id,
      ),
    );
    final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    await _money(tester, 'cashAmount', '1401.31');
    await _decimal(tester, 'nav', '109.8290');
    await _reveal(tester, find.text(l.fundAlreadyPaid));
    await tester.tap(find.text(l.fundAlreadyPaid));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('fund-save'));
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final portfolio = c.investmentFor(ready.account.id)!;
    expect(portfolio.fundSubscriptions, hasLength(1));
    final subscription = portfolio.fundSubscriptions.single;
    expect(subscription.cashAmount, '1401.31');
    expect(subscription.paidAt, isNotNull);
    expect(subscription.confirmation, isNull);
    expect(portfolio.events, isEmpty);
    expect(portfolio.manualPrices, isEmpty);
    expect(c.investmentProjection(ready.account.id)!.positions, isEmpty);
    expect(c.accountBalance(ready.account), closeTo(8598.69, 0.000001));
    expect(c.accountAssetValue(ready.account), closeTo(10000, 0.000001));
    expect(c.entries, isEmpty);
    expect(find.byType(FundEntryPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final holding in [
    (nav: '140.251', profit: 1.2),
    (nav: '140.011', profit: -1.2),
  ]) {
    testWidgets('窄屏实际份额自动计算浮盈 ${holding.profit}，无需手填浮盈且不重复扣现金', (tester) async {
      final ready = await _ready();
      final c = ready.controller;
      await _pumpEntry(
        tester,
        c,
        FundEntryPage(
          accountId: ready.account.id,
          mode: FundEntryMode.holdingBaseline,
          securityId: _fund.id,
        ),
        size: const Size(320, 640),
      );
      final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
      expect(find.byKey(const ValueKey('fund-unrealized')), findsNothing);
      await _money(tester, 'cost', '1401.31');
      await _decimal(tester, 'nav', holding.nav);
      final save = find.byKey(const Key('fund-save'));
      if (holding.profit > 0) {
        // 先明确核对但漏填实际份额，仍不能保存；金额与净值不再被用来反推已有份额。
        await _reveal(tester, find.byKey(const Key('fund-reviewed')));
        await tester.tap(find.byKey(const Key('fund-reviewed')));
        await tester.pumpAndSettle();
        await _reveal(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(c.investmentFor(ready.account.id)!.events, isEmpty);
        expect(find.text(l.fundSaveValidation), findsOneWidget);
      }
      await _decimal(tester, 'confirmedQuantity', '10');
      final calculated = find.byWidgetPredicate(
        (widget) =>
            widget is DetailInfoRow &&
            widget.label == l.fundCalculatedUnrealized,
      );
      await _reveal(tester, calculated);
      expect(
        tester.widget<DetailInfoRow>(calculated).value,
        formatSignedUserMoney(holding.profit, 'USD'),
      );
      await _reveal(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(c.investmentFor(ready.account.id)!.events, isEmpty);
      expect(find.text(l.fundSaveValidation), findsOneWidget);
      expect(find.byType(FundEntryPage), findsOneWidget);

      await _reveal(tester, find.byKey(const Key('fund-reviewed')));
      await tester.tap(find.byKey(const Key('fund-reviewed')));
      await tester.pumpAndSettle();
      await _reveal(tester, save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final baseline = c.investmentFor(ready.account.id)!.events.single;
      expect(baseline.kind, StockEventKind.fundHoldingBaseline);
      expect(baseline.carriedCost, '1401.31');
      expect(baseline.reportedUnrealized, isNull);
      expect(baseline.quantityInferred, isFalse);
      expect(baseline.quantity, '10');
      expect(c.accountBalance(ready.account), 10000);
      expect(c.entries, isEmpty);
      expect(find.byType(FundEntryPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧推算份额编辑时加载原份额，保留原始证据直到实际基准依据改变', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    final at = DateTime.now().subtract(const Duration(hours: 2));
    expect(
      await c.saveFundHoldingBaseline(
        accountId: ready.account.id,
        security: _fund,
        referencePrice: '100',
        event: StockEvent(
          id: 'legacy-baseline',
          securityId: _fund.id,
          kind: StockEventKind.fundHoldingBaseline,
          occurredAt: at,
          sequence: 1,
          quantity: '10',
          price: '100',
          carriedCost: '1000',
          reportedUnrealized: '0',
          fundNavDate: hongKongFundDate(at),
          quantityInferred: true,
        ),
      ),
      isTrue,
    );
    var baseline = c.investmentFor(ready.account.id)!.events.single;
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.holdingBaseline,
        baselineEvent: baseline,
      ),
    );
    final quantity = find.byKey(const ValueKey('fund-confirmedQuantity'));
    await _reveal(tester, quantity);
    expect(tester.widget<TextField>(quantity).controller!.text, '10');
    expect(find.byKey(const ValueKey('fund-unrealized')), findsNothing);
    await _saveReviewedHolding(tester);
    baseline = c.investmentFor(ready.account.id)!.events.single;
    expect(baseline.quantityInferred, isTrue);
    expect(baseline.reportedUnrealized, '0');

    // 只改成本不改份额：旧报告浮盈不再约束新基准，份额本身仍保留原推算来源。
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.holdingBaseline,
        baselineEvent: baseline,
      ),
    );
    await _money(tester, 'cost', '1100');
    await _saveReviewedHolding(tester);
    baseline = c.investmentFor(ready.account.id)!.events.single;
    expect(baseline.carriedCost, '1100');
    expect(baseline.reportedUnrealized, isNull);
    expect(baseline.quantityInferred, isTrue);

    // 明确录入不同的实际份额后，才把份额从历史推算状态改为实际持仓状态。
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.holdingBaseline,
        baselineEvent: baseline,
      ),
    );
    await _decimal(tester, 'confirmedQuantity', '11');
    await _saveReviewedHolding(tester);
    baseline = c.investmentFor(ready.account.id)!.events.single;
    expect(baseline.quantity, '11');
    expect(baseline.quantityInferred, isFalse);
    expect(c.accountBalance(ready.account), 10000);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未付款申请切到取消时金额和付款状态只读，取消不制造实际扣款', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    expect(
      await c.saveFundSubscription(
        accountId: ready.account.id,
        security: _fund,
        subscription: FundSubscription(
          id: 'ui-unpaid-cancel',
          securityId: _fund.id,
          requestedAt: DateTime.now().subtract(const Duration(hours: 1)),
          cashAmount: '1401.31',
        ),
      ),
      isTrue,
    );
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.purchase,
        subscriptionId: 'ui-unpaid-cancel',
      ),
    );
    final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    // 先留下一份未保存付款草稿；切取消必须展示原事实，而不是暗中丢掉一份看似已发生的扣款。
    await _money(tester, 'cashAmount', '1405');
    await _money(tester, 'fee', '1.20');
    await _reveal(tester, find.text(l.fundAlreadyPaid));
    await tester.tap(find.text(l.fundAlreadyPaid));
    await tester.pumpAndSettle();
    final cancel = find.widgetWithText(TextButton, l.fundCancelSubscription);
    await _reveal(tester, cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    final amount = find.byKey(const ValueKey('fund-cashAmount'));
    await _reveal(tester, amount);
    expect(tester.widget<TextField>(amount).readOnly, isTrue);
    expect(tester.widget<TextField>(amount).onTap, isNull);
    expect(tester.widget<TextField>(amount).controller!.text, '1401.31');
    final fee = find.byKey(const ValueKey('fund-fee'));
    await _reveal(tester, fee);
    expect(tester.widget<TextField>(fee).readOnly, isTrue);
    expect(tester.widget<TextField>(fee).onTap, isNull);
    expect(tester.widget<TextField>(fee).controller!.text, '0');
    final paid = find.ancestor(
      of: find.text(l.fundAlreadyPaid),
      matching: find.byType(CompactSwitchRow),
    );
    await _reveal(tester, paid);
    expect(tester.widget<CompactSwitchRow>(paid).value, isFalse);
    expect(tester.widget<CompactSwitchRow>(paid).onChanged, isNull);
    expect(find.text(l.fundPaidAt), findsNothing);
    await tester.tap(find.text(l.fundAlreadyPaid));
    await tester.pumpAndSettle();
    expect(tester.widget<CompactSwitchRow>(paid).value, isFalse);

    // 返回申请仍能继续原草稿，再切取消则再次显示已保存事实；模式切换不会误记账或无故清空草稿。
    final application = find.widgetWithText(TextButton, l.fundRecordPayment);
    await _reveal(tester, application);
    await tester.tap(application);
    await tester.pumpAndSettle();
    await _reveal(tester, amount);
    expect(tester.widget<TextField>(amount).controller!.text, '1405.00');
    await _reveal(tester, fee);
    expect(tester.widget<TextField>(fee).controller!.text, '1.20');
    await _reveal(tester, paid);
    expect(tester.widget<CompactSwitchRow>(paid).value, isTrue);
    await _reveal(tester, cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('fund-save'));
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final subscription = c
        .investmentFor(ready.account.id)!
        .fundSubscriptions
        .single;
    expect(subscription.cancelledAt, isNotNull);
    expect(subscription.paidAt, isNull);
    expect(subscription.cashAmount, '1401.31');
    expect(c.accountBalance(ready.account), 10000);
    expect(c.investmentProjection(ready.account.id)!.positions, isEmpty);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待确认申请保留独立日期和真实扣款限制，确认必须再次核对', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    final now = DateTime.now();
    final requested = now.subtract(const Duration(hours: 48));
    final paid = now.subtract(const Duration(hours: 24));
    final expected = _shiftFundDate(hongKongFundDate(now), -1);
    expect(
      await c.saveFundSubscription(
        accountId: ready.account.id,
        security: _fund,
        subscription: FundSubscription(
          id: 'ui-pending',
          securityId: _fund.id,
          requestedAt: requested,
          paidAt: paid,
          cashAmount: '1401.31',
          expectedConfirmationDate: expected,
        ),
      ),
      isTrue,
    );
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.purchase,
        subscriptionId: 'ui-pending',
      ),
    );
    final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    final amount = find.byKey(const ValueKey('fund-cashAmount'));
    await _reveal(tester, amount);
    final amountField = tester.widget<TextField>(amount);
    expect(amountField.readOnly, isTrue);
    expect(amountField.onTap, isNull);
    final paidSwitch = find.ancestor(
      of: find.text(l.fundAlreadyPaid),
      matching: find.byType(CompactSwitchRow),
    );
    await _reveal(tester, paidSwitch);
    expect(tester.widget<CompactSwitchRow>(paidSwitch).onChanged, isNull);
    final paidDate = find.ancestor(
      of: find.text(l.fundPaidAt),
      matching: find.byType(ListTile),
    );
    await _reveal(tester, paidDate);
    expect(tester.widget<ListTile>(paidDate).onTap, isNull);
    expect(
      c.investmentFor(ready.account.id)!.fundSubscriptions.single.confirmation,
      isNull,
    );
    expect(c.investmentFor(ready.account.id)!.events, isEmpty);

    await _reveal(tester, find.text(l.fundConfirmSubscription));
    await tester.tap(find.text(l.fundConfirmSubscription));
    await tester.pumpAndSettle();
    final requestedDate = find.ancestor(
      of: find.text(l.fundRequestedAt),
      matching: find.byType(ListTile),
    );
    await _reveal(tester, requestedDate);
    expect(tester.widget<ListTile>(requestedDate).onTap, isNull);
    await _money(tester, 'fee', '1.31');
    await _decimal(tester, 'nav', '109.8290');
    // 主动选择原独立起算规则后，原有三个日期的输入与取消行为仍须完整可用。
    await _chooseAccrualRule(tester, FundAccrualRule.explicitStartDate);
    // 三个日期分别打开各自选择器；取消选择不提前确认、不改真实扣款。
    for (final label in [
      l.fundNavDate,
      l.fundConfirmedAt,
      l.fundEarningStartDate,
    ]) {
      final field = find.ancestor(
        of: find.text(label),
        matching: find.byType(ListTile),
      );
      await _reveal(tester, field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      final cancel = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      ).cancelButtonLabel;
      await tester.tap(find.text(cancel));
      await tester.pumpAndSettle();
    }
    final save = find.byKey(const Key('fund-save'));
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text(l.fundSaveValidation), findsOneWidget);
    expect(c.investmentFor(ready.account.id)!.events, isEmpty);
    await _reveal(tester, find.byKey(const Key('fund-reviewed')));
    await tester.tap(find.byKey(const Key('fund-reviewed')));
    await tester.pumpAndSettle();
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final portfolio = c.investmentFor(ready.account.id)!;
    expect(portfolio.fundSubscriptions.single.confirmation, isNotNull);
    expect(
      portfolio.fundSubscriptions.single.confirmation!.accrualRule,
      FundAccrualRule.explicitStartDate,
    );
    expect(portfolio.fundSubscriptions.single.paidAt, paid);
    expect(portfolio.fundSubscriptions.single.fee, '1.31');
    expect(
      portfolio.fundSubscriptions.single.expectedConfirmationDate,
      expected,
    );
    expect(portfolio.events.single.kind, StockEventKind.fundAcquire);
    expect(portfolio.events.single.quantityInferred, isTrue);
    expect(c.accountBalance(ready.account), closeTo(8598.69, 0.000001));
    expect(c.entries, isEmpty);
    expect(find.byType(FundEntryPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CMS 新确认默认按成交净值日归属，独立起算日不作为第二个门槛', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    await _openPaidConfirmation(
      tester,
      c,
      ready.account,
      id: 'ui-cms-new-rule',
    );
    final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    final choice = find.byKey(const Key('fund-accrual-rule'));
    await _reveal(tester, choice);
    expect(
      tester.widget<VeriAnchoredChoice<FundAccrualRule>>(choice).selected,
      FundAccrualRule.dealNavDate,
    );
    expect(find.text(l.fundEarningStartDate), findsNothing);
    await _reveal(tester, find.text(l.fundDealNavDateHint));
    expect(find.text(l.fundDealNavDateHint), findsOneWidget);
    await _reveal(tester, find.text(l.fundDealNavBasisDate));
    expect(find.text(l.fundDealNavBasisDate), findsOneWidget);
    await _decimal(tester, 'nav', '100');
    await _decimal(tester, 'confirmedQuantity', '10');
    await _saveReviewedHolding(tester);
    final portfolio = c.investmentFor(ready.account.id)!;
    final confirmation = portfolio.fundSubscriptions.single.confirmation!;
    expect(confirmation.accrualRule, FundAccrualRule.dealNavDate);
    expect(confirmation.earningStartDate, confirmation.navDate);
    expect(portfolio.events.single.quantityInferred, isFalse);
    expect(c.accountBalance(ready.account), 9000);
    expect(c.entries, isEmpty);
    expect(find.byType(FundEntryPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账户入口未指定基金时须先选择，CMS 申请再确认仍默认成交净值规则', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(accountId: ready.account.id, mode: FundEntryMode.purchase),
    );
    var l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    final choose = find.byWidgetPredicate(
      (widget) => widget is SettingsRow && widget.title == l.fundChoose,
    );
    await _reveal(tester, choose);
    expect(tester.widget<SettingsRow>(choose).trailing, l.fundChoose);
    await tester.tap(choose);
    await tester.pumpAndSettle();
    await tester.tap(find.text('${l.fundCmsUsdName} · ${_fund.symbol}'));
    await tester.pumpAndSettle();
    await _money(tester, 'cashAmount', '1000');
    await _reveal(tester, find.text(l.fundAlreadyPaid));
    await tester.tap(find.text(l.fundAlreadyPaid));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('fund-save'));
    await _reveal(tester, save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final request = c.investmentFor(ready.account.id)!.fundSubscriptions.single;
    expect(request.securityId, _fund.id);
    expect(request.confirmation, isNull);

    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.purchase,
        subscriptionId: request.id,
      ),
    );
    l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    await _reveal(tester, find.text(l.fundConfirmSubscription));
    await tester.tap(find.text(l.fundConfirmSubscription));
    await tester.pumpAndSettle();
    final rule = find.byKey(const Key('fund-accrual-rule'));
    await _reveal(tester, rule);
    expect(
      tester.widget<VeriAnchoredChoice<FundAccrualRule>>(rule).selected,
      FundAccrualRule.dealNavDate,
    );
    expect(find.text(l.fundEarningStartDate), findsNothing);
    await _decimal(tester, 'nav', '100');
    await _decimal(tester, 'confirmedQuantity', '10');
    await _saveReviewedHolding(tester);
    expect(
      c
          .investmentFor(ready.account.id)!
          .fundSubscriptions
          .single
          .confirmation!
          .accrualRule,
      FundAccrualRule.dealNavDate,
    );
    expect(c.accountBalance(ready.account), 9000);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CMS 旧确认保留独立起算日，明确切换后重核且不再次扣款', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    final today = hongKongFundDate(DateTime.now());
    final navDate = _shiftFundDate(today, -3);
    final legacyStart = _shiftFundDate(today, 1);
    const id = 'ui-cms-legacy-rule';
    expect(
      await c.saveFundSubscription(
        accountId: ready.account.id,
        security: _fund,
        subscription: FundSubscription(
          id: id,
          securityId: _fund.id,
          requestedAt: hongKongFundDayStart(_shiftFundDate(today, -6)),
          paidAt: hongKongFundDayStart(_shiftFundDate(today, -5)),
          cashAmount: '1000',
        ),
      ),
      isTrue,
    );
    expect(
      await c.confirmFundSubscription(
        accountId: ready.account.id,
        subscriptionId: id,
        confirmation: FundSubscriptionConfirmation(
          confirmedAt: hongKongFundDayStart(_shiftFundDate(today, -1)),
          navDate: navDate,
          earningStartDate: legacyStart,
          nav: '100',
          quantity: '10',
        ),
      ),
      isTrue,
    );
    final before = c.investmentFor(ready.account.id)!;
    await _pumpEntry(
      tester,
      c,
      FundEntryPage(
        accountId: ready.account.id,
        mode: FundEntryMode.purchase,
        subscriptionId: id,
      ),
    );
    final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    final choice = find.byKey(const Key('fund-accrual-rule'));
    await _reveal(tester, choice);
    expect(
      tester.widget<VeriAnchoredChoice<FundAccrualRule>>(choice).selected,
      FundAccrualRule.explicitStartDate,
    );
    await _reveal(tester, find.text(l.fundLegacyAccrualHint));
    expect(find.text(l.fundLegacyAccrualHint), findsOneWidget);
    await _reveal(tester, find.text(l.fundEarningStartDate));
    expect(find.text(l.fundEarningStartDate), findsOneWidget);
    expect(c.investmentFor(ready.account.id)!.toJson(), before.toJson());

    // 已勾选后改变规则必须撤销勾选，防止对照旧日期的核对状态被沿用到新口径。
    final reviewed = find.byKey(const Key('fund-reviewed'));
    await _reveal(tester, reviewed);
    await tester.tap(reviewed);
    await tester.pumpAndSettle();
    await _chooseAccrualRule(tester, FundAccrualRule.dealNavDate);
    await _reveal(tester, reviewed);
    expect(tester.widget<CheckboxListTile>(reviewed).value, isFalse);
    expect(find.text(l.fundEarningStartDate), findsNothing);
    expect(
      c
          .investmentFor(ready.account.id)!
          .fundSubscriptions
          .single
          .confirmation!
          .earningStartDate,
      legacyStart,
    );
    await _saveReviewedHolding(tester);
    final after = c.investmentFor(ready.account.id)!;
    expect(after.events.single.id, before.events.single.id);
    expect(
      after.events.single.occurredAt.isBefore(before.events.single.occurredAt),
      isTrue,
    );
    expect(after.fundSubscriptions.single.confirmation!.navDate, navDate);
    expect(
      after.fundSubscriptions.single.confirmation!.earningStartDate,
      navDate,
    );
    expect(
      after.fundSubscriptions.single.confirmation!.accrualRule,
      FundAccrualRule.dealNavDate,
    );
    expect(c.accountBalance(ready.account), 9000);
    expect(c.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('其他香港美元基金保留原独立起算日，不套用 CMS B 类规则', (tester) async {
    final ready = await _ready();
    final c = ready.controller;
    const other = StockSecurity(
      symbol: 'HK0001039574',
      name: '其他香港美元基金测试标的',
      market: StockMarket.hk,
      currencyCode: 'USD',
      type: InvestmentSecurityType.fund,
    );
    await _openPaidConfirmation(
      tester,
      c,
      ready.account,
      id: 'ui-other-fund-rule',
      security: other,
    );
    final l = AppLocalizations.of(tester.element(find.byType(FundEntryPage)));
    expect(find.byKey(const Key('fund-accrual-rule')), findsNothing);
    expect(find.text(l.fundEarningStartDate), findsOneWidget);
    expect(find.text(l.fundDealNavDateHint), findsNothing);
    await _decimal(tester, 'nav', '100');
    await _decimal(tester, 'confirmedQuantity', '10');
    await _saveReviewedHolding(tester);
    final confirmation = c
        .investmentFor(ready.account.id)!
        .fundSubscriptions
        .single
        .confirmation!;
    expect(confirmation.accrualRule, FundAccrualRule.explicitStartDate);
    expect(c.accountBalance(ready.account), 9000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('基金历史展示真实净值区间及已包含的申购费用，不把周末区间称为单日', (tester) async {
    final ready = await _ready();
    final first = DateTime.utc(2026, 10, 23);
    final next = DateTime.utc(2026, 10, 26);
    await _pumpEntry(
      tester,
      ready.controller,
      Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FundReferenceHistorySection(
              account: ready.account,
              security: _fund,
              points: [
                FundReferenceDay(
                  date: first,
                  nav: InvestmentDecimal.parse('100'),
                  quantity: InvestmentDecimal.parse('10'),
                  marketValue: InvestmentDecimal.parse('1000'),
                  dailyProfit: null,
                  cumulativeProfit: InvestmentDecimal.zero,
                  cash: 9000,
                  accountAssets: 10000,
                  accountLiabilities: 0,
                  accountNetValue: 10000,
                  missingSecurityIds: const {},
                ),
                FundReferenceDay(
                  date: next,
                  profitFromDate: first,
                  nav: InvestmentDecimal.parse('101'),
                  quantity: InvestmentDecimal.parse('11'),
                  marketValue: InvestmentDecimal.parse('1111'),
                  dailyProfit: InvestmentDecimal.parse('9'),
                  subscriptionAdjustment: InvestmentDecimal.parse('-1'),
                  cumulativeProfit: InvestmentDecimal.parse('9'),
                  cash: 8898,
                  accountAssets: 10009,
                  accountLiabilities: 0,
                  accountNetValue: 10009,
                  missingSecurityIds: const {},
                ),
              ],
            ),
          ],
        ),
      ),
      size: const Size(360, 740),
    );
    final context = tester.element(find.byType(FundReferenceHistorySection));
    final l = AppLocalizations.of(context);
    final interval = l.fundReferenceProfitInterval(
      formatQuoteTime(context, first, dateOnly: true),
      formatQuoteTime(context, next, dateOnly: true),
    );
    await _reveal(tester, find.text(l.fundReferenceProfitIntervalLabel).first);
    expect(find.text(interval), findsWidgets);
    await _reveal(tester, find.text(l.fundReferenceSubscriptionAdjustment));
    expect(find.text(l.fundReferenceSubscriptionAdjustment), findsOneWidget);
    expect(find.text(l.fundReferenceDailyProfit), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
