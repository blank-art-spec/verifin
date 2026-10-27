import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_controller.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/investment_page.dart';

import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 载入正式测试备份并选中投资账本，返回由调用方释放的隔离控制器。
/// [locale] 同时设置控制器语言，避免英文页面与金额格式偏好使用不同语言。
Future<VeriFinController> _sampleController({
  Locale locale = const Locale('zh'),
}) async {
  final controller = await makeController();
  controller.importDataJson(
    File('docs/dev/verifin-sample-backup.json').readAsStringSync(),
  );
  await controller.waitForPendingWrites();
  controller.switchLedgerBook('book_investment');
  controller.setLocalePreference(
    locale.languageCode == 'en' ? LocalePreference.en : LocalePreference.zh,
  );
  return controller;
}

/// 在真实证券页中使用给定屏幕、字号、语言和主题，不构造替代演示布局。
/// [tester] 驱动页面，[controller] 提供原生产读取路径；[accountId] 为真实币种账户。
/// [width] 与 [scale] 分别控制逻辑宽度及文字缩放，结束后恢复测试屏幕尺寸。
Future<void> _pumpAllocationPage(
  WidgetTester tester,
  VeriFinController controller, {
  String accountId = 'acc_investment_usd',
  double width = 393,
  double scale = 1,
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    VeriFinScope(
      controller: controller,
      child: MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildVeriFinTheme(brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 852),
            textScaler: TextScaler.linear(scale),
          ),
          child: InvestmentPage(accountId: accountId),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 按本地化业务标签读取概览指标，避免把持仓卡中的同名字段误当成概览。
/// [tester] 提供当前组件树，[label] 是本次界面的完整本地化指标名。
SummaryMetric _metric(WidgetTester tester, String label) =>
    tester.widget<SummaryMetric>(
      find.byWidgetPredicate(
        (widget) => widget is SummaryMetric && widget.label == label,
      ),
    );

/// 滚动到 [titleText] 对应的真实持仓卡，并核对其占比行和完整文字布局。
/// [percentage] 为固定预期显示值，[short] 决定多头占比或空头义务占比标签；
/// [l] 来自当前页面，确保中英文用例走同一业务断言。方法只读取界面，不修改账目。
Future<void> _expectPositionShare(
  WidgetTester tester,
  String titleText,
  String percentage,
  AppLocalizations l, {
  bool short = false,
}) async {
  final scroll = find
      .descendant(
        of: find.byType(InvestmentPage),
        matching: find.byType(Scrollable),
      )
      .first;
  final title = find.text(titleText);
  await tester.scrollUntilVisible(
    title,
    180,
    scrollable: scroll,
    maxScrolls: 50,
  );
  final card = find.ancestor(of: title, matching: find.byType(VeriCard)).first;
  final shareRow = find.descendant(
    of: card,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is DetailInfoRow &&
          widget.label == (short ? l.investShortShare : l.investHoldingsShare),
    ),
  );
  await tester.scrollUntilVisible(
    shareRow,
    180,
    scrollable: scroll,
    maxScrolls: 50,
  );
  expect(tester.widget<DetailInfoRow>(shareRow).value, percentage);
  final text = find.descendant(of: shareRow, matching: find.text(percentage));
  expect(text, findsOneWidget);
  expect(tester.widget<Text>(text).maxLines, isNull);
  expect(tester.takeException(), isNull);
}

/// 覆盖三地模板、实时改价、零资产和空头义务的用户可见行为。
/// 无参数、无返回值；所有场景使用隔离控制器，不连接设备或真实行情服务。
void main() {
  useTestDatabases();
  for (final scenario in [
    (
      locale: const Locale('zh'),
      width: 393.0,
      scale: 1.0,
      brightness: Brightness.light,
    ),
    (
      locale: const Locale('zh'),
      width: 360.0,
      scale: 1.5,
      brightness: Brightness.dark,
    ),
    (
      locale: const Locale('en'),
      width: 393.0,
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      locale: const Locale('en'),
      width: 360.0,
      scale: 1.5,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets(
      '证券占比中英文、窄屏与字号 ${scenario.locale} ${scenario.width} ${scenario.scale}',
      (tester) async {
        final controller = await _sampleController(locale: scenario.locale);
        addTearDown(controller.dispose);
        final before = jsonDecode(controller.exportDataJson()) as Map;
        before.remove('exportedAt');
        await _pumpAllocationPage(
          tester,
          controller,
          locale: scenario.locale,
          width: scenario.width,
          scale: scenario.scale,
          brightness: scenario.brightness,
        );
        final l = AppLocalizations.of(
          tester.element(find.byType(InvestmentPage)),
        );
        expect(
          _metric(tester, l.investCash).detail,
          '${l.investCashShare} 74.6%',
        );
        expect(
          _metric(tester, l.investLongValue).detail,
          '${l.investHoldingsShare} 25.4%',
        );
        expect(_metric(tester, l.investShortObligation).detail, isNull);
        expect(find.text(l.investAllocationHint), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _expectPositionShare(tester, '博通 · AVGO', '19.0%', l);
        await _expectPositionShare(tester, '谷歌 · GOOG', '6.3%', l);

        // 四舍五入后的单项显示之和不必等于合计显示值；只浏览不能改账。
        final after = jsonDecode(controller.exportDataJson()) as Map;
        after.remove('exportedAt');
        expect(after, before);
      },
    );
  }

  for (final width in [393.0, 360.0]) {
    testWidgets('三地模板：中远海能 A 股持仓与占比 $width', (tester) async {
      final controller = await _sampleController();
      addTearDown(controller.dispose);
      await _pumpAllocationPage(
        tester,
        controller,
        accountId: 'acc_investment_cny',
        width: width,
      );
      final l = AppLocalizations.of(
        tester.element(find.byType(InvestmentPage)),
      );
      expect(
        _metric(tester, l.investCash).detail,
        '${l.investCashShare} 67.3%',
      );
      expect(
        _metric(tester, l.investLongValue).detail,
        '${l.investHoldingsShare} 32.7%',
      );
      await _expectPositionShare(tester, '中远海能 · 600026', '32.7%', l);
    });

    testWidgets('三地模板：腾讯股票及认购多头、认沽空头 $width', (tester) async {
      final controller = await _sampleController();
      addTearDown(controller.dispose);
      await _pumpAllocationPage(
        tester,
        controller,
        accountId: 'acc_investment_hkd',
        width: width,
      );
      final l = AppLocalizations.of(
        tester.element(find.byType(InvestmentPage)),
      );
      expect(
        _metric(tester, l.investCash).detail,
        '${l.investCashShare} 59.0%',
      );
      expect(
        _metric(tester, l.investLongValue).detail,
        '${l.investHoldingsShare} 41.0%',
      );
      expect(
        _metric(tester, l.investShortObligation).detail,
        '${l.investShortShare} 0.4%',
      );
      await _expectPositionShare(tester, '腾讯控股 · 00700', '39.6%', l);
      await _expectPositionShare(
        tester,
        '腾讯控股认购期权示例 · TEST-TCH-CALL-20261230-440',
        '1.4%',
        l,
      );
      await _expectPositionShare(
        tester,
        '腾讯控股认沽期权示例 · TEST-TCH-PUT-20261230-380',
        '0.4%',
        l,
        short: true,
      );
      expect(
        controller
            .investmentProjection('acc_investment_hkd')!
            .frozenMargin
            .toDouble(),
        10000,
      );
    });
  }

  testWidgets('更新 GOOG 参考价会重算占比，现金与成交事实不变', (tester) async {
    final controller = await _sampleController();
    addTearDown(controller.dispose);
    final events = controller
        .investmentFor('acc_investment_usd')!
        .events
        .map((event) => event.toJson())
        .toList();
    await _pumpAllocationPage(tester, controller);
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
    expect(_metric(tester, l.investCash).detail, '${l.investCashShare} 74.6%');
    expect(
      await controller.setStockReferencePrice(
        'acc_investment_usd',
        'us:stock:GOOG',
        '220',
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(_metric(tester, l.investCash).detail, '${l.investCashShare} 70.2%');
    expect(
      _metric(tester, l.investLongValue).detail,
      '${l.investHoldingsShare} 29.8%',
    );
    await _expectPositionShare(tester, '谷歌 · GOOG', '11.9%', l);
    final usd = controller.accounts.singleWhere(
      (account) => account.id == 'acc_investment_usd',
    );
    expect(controller.accountBalance(usd), 7756);
    expect(controller.accountAssetValue(usd), 11056);
    expect(
      controller
          .investmentFor(usd.id)!
          .events
          .map((event) => event.toJson())
          .toList(),
      events,
    );
  });

  testWidgets('零资产占比显示未知，不制造零分母百分比', (tester) async {
    final controller = await makeController();
    final account = investmentAccountFixture();
    addTearDown(controller.dispose);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '0',
      ),
      isTrue,
    );
    await _pumpAllocationPage(tester, controller, accountId: account.id);
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
    expect(
      _metric(tester, l.investCash).detail,
      '${l.investCashShare} ${l.investUnknown}',
    );
    expect(
      _metric(tester, l.investLongValue).detail,
      '${l.investHoldingsShare} ${l.investUnknown}',
    );
    expect(find.textContaining('NaN'), findsNothing);
    expect(find.textContaining('Infinity'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空头义务使用独立占比标签，冻结资金不从现金占比扣除', (tester) async {
    final controller = await makeController();
    final account = investmentAccountFixture();
    final option = optionFixture(right: OptionRight.put);
    addTearDown(controller.dispose);
    controller.addAccount(account);
    await controller.waitForPendingWrites();
    expect(
      await controller.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
        securities: const [avgoFixture],
        openingHoldings: [
          StockHolding(
            securityId: avgoFixture.id,
            short: false,
            quantity: '1',
            cost: '100',
          ),
        ],
        manualPrices: {avgoFixture.id: '100'},
      ),
      isTrue,
    );
    expect(
      await controller.saveOptionEvent(
        accountId: account.id,
        security: option,
        underlying: avgoFixture,
        event: optionEventFixture(
          option,
          StockEventKind.optionSellOpen,
          fee: '1',
          margin: '1000',
        ),
        referencePrice: '1',
        underlyingReferencePrice: '100',
      ),
      isTrue,
    );
    await _pumpAllocationPage(tester, controller, accountId: account.id);
    final l = AppLocalizations.of(tester.element(find.byType(InvestmentPage)));
    expect(_metric(tester, l.investCash).detail, '${l.investCashShare} 99.0%');
    expect(
      _metric(tester, l.investLongValue).detail,
      '${l.investHoldingsShare} 1.0%',
    );
    expect(
      _metric(tester, l.investShortObligation).detail,
      '${l.investShortShare} 1.0%',
    );
    expect(find.text(l.investAllocationLiabilityHint), findsOneWidget);
    await _expectPositionShare(
      tester,
      '${option.name} · ${option.symbol}',
      '1.0%',
      l,
      short: true,
    );
    expect(controller.accountBalance(account), 10199);
    expect(
      controller.investmentProjection(account.id)!.frozenMargin.toDouble(),
      1000,
    );
  });
}
