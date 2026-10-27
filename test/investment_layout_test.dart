import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/investment_page.dart';
import 'package:verifin/pages/investment_history_page.dart';
import 'package:verifin/pages/market_quotes_page.dart';
import 'package:verifin/pages/option_editor_page.dart';
import 'support/investment_fixture.dart';
import 'support/test_harness.dart';

/// 检查真实页面在窄屏、大字号和两种主题下的全部滚动内容，不构造替代演示页面。
void main() {
  useTestDatabases();
  for (final width in [360.0, 393.0]) {
    testWidgets('期权说明与字段标签不重叠 $width', (tester) async {
      final c = await makeController(), account = investmentAccountFixture();
      addTearDown(c.dispose);
      c.addAccount(account);
      await c.waitForPendingWrites();
      await c.enableInvestment(
        accountId: account.id,
        openingCash: '10000',
        openedAt: DateTime(2026, 10, 1),
      );
      final option = optionFixture();
      expect(
        await c.saveOptionEvent(
          accountId: account.id,
          security: option,
          underlying: avgoFixture,
          event: optionEventFixture(option, StockEventKind.optionBuyOpen),
          referencePrice: '3',
          underlyingReferencePrice: '330',
        ),
        isTrue,
      );
      await tester.binding.setSurfaceSize(Size(width, 852));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      try {
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 1.6]) {
            await tester.pumpWidget(
              VeriFinScope(
                controller: c,
                child: zhMaterialApp(
                  theme: buildVeriFinTheme(brightness),
                  home: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: OptionEditorPage(
                      accountId: account.id,
                      securityId: option.id,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final l = AppLocalizations.of(
              tester.element(find.byType(OptionEditorPage)),
            );
            final scroll = find
                .descendant(
                  of: find.byType(OptionEditorPage),
                  matching: find.byType(Scrollable),
                )
                .first;
            for (final pair in [
              (l.optionAdjustmentHint, l.optionSpecification, 'source'),
              (l.optionMarginHint, l.investReference, 'reference'),
              (l.investTradeDetails, l.optionContracts, 'quantity'),
            ]) {
              await tester.scrollUntilVisible(
                find.byKey(ValueKey('option-${pair.$3}')),
                pair.$3 == 'quantity' ? -250 : 250,
                scrollable: scroll,
              );
              // 比较标签实际绘制坐标（包含浮动变换），而非只检查 RenderFlex 异常。
              // 说明末行、字段名、输入正文须分别占位，系统大字号也必须有可见间距。
              final label = tester.getRect(find.text(pair.$2));
              expect(
                label.top - tester.getRect(find.text(pair.$1)).bottom,
                greaterThanOrEqualTo(6),
                reason: '${pair.$2} / $scale / $brightness',
              );
              final editable = find.descendant(
                of: find.byKey(ValueKey('option-${pair.$3}')),
                matching: find.byType(EditableText),
              );
              // 外置视觉标签后，读屏仍须从可编辑节点获取字段名，不能只剩输入值。
              expect(tester.getSemantics(editable).label, contains(pair.$2));
              expect(
                tester.getRect(editable).top - label.bottom,
                greaterThanOrEqualTo(6),
              );
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      } finally {
        // Flutter 在测试体结束时检查句柄，须在此释放，不能延后到 addTearDown。
        semantics.dispose();
      }
    });
  }
  for (final width in [360.0, 393.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('证券页面 $width $brightness 完整滚动且不溢出', (tester) async {
        final c = await makeController(), account = investmentAccountFixture();
        addTearDown(c.dispose);
        c.addAccount(account);
        await c.waitForPendingWrites();
        await c.enableInvestment(
          accountId: account.id,
          openingCash: '10000',
          openedAt: DateTime(2026, 10, 1),
        );
        final option = optionFixture();
        expect(
          await c.saveOptionEvent(
            accountId: account.id,
            security: option,
            underlying: avgoFixture,
            event: optionEventFixture(option, StockEventKind.optionBuyOpen),
            referencePrice: '3',
            underlyingReferencePrice: '330',
          ),
          isTrue,
        );
        await c.captureInvestmentValuation(account.id);
        final before = jsonDecode(c.exportDataJson()) as Map<String, dynamic>;
        before.remove('exportedAt');
        await tester.binding.setSurfaceSize(Size(width, 852));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final scale in [1.0, 1.6]) {
          for (final page in <Widget>[
            InvestmentPage(accountId: account.id),
            StockEditorPage(accountId: account.id),
            OptionEditorPage(accountId: account.id),
            InvestmentHistoryPage(accountId: account.id),
            MarketQuotesPage(accountId: account.id),
          ]) {
            await tester.pumpWidget(
              VeriFinScope(
                controller: c,
                child: zhMaterialApp(
                  theme: buildVeriFinTheme(brightness),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 852),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: page,
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final scroll = find
                .descendant(
                  of: find.byType(page.runtimeType),
                  matching: find.byType(Scrollable),
                )
                .first;
            // 逐屏检查，让懒构建的持仓、表单尾部及来源依据都参与真实布局。
            for (var step = 0; step < 50; step++) {
              expect(
                tester.takeException(),
                isNull,
                reason: '${page.runtimeType} / $scale / 第 $step 屏',
              );
              final state = tester.state<ScrollableState>(scroll);
              if (state.position.pixels >= state.position.maxScrollExtent) {
                break;
              }
              await tester.drag(scroll, const Offset(0, -500));
              await tester.pumpAndSettle();
            }
            final state = tester.state<ScrollableState>(scroll);
            expect(state.position.pixels, state.position.maxScrollExtent);
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
        final after = jsonDecode(c.exportDataJson()) as Map<String, dynamic>;
        after.remove('exportedAt');
        expect(after, before, reason: '浏览和取消表单不能写入账目');
      });
    }
  }

  testWidgets('详情字段共用左右边界，大字号完整换行不截断金额', (tester) async {
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: Column(
                children: const [
                  DetailInfoRow(inline: true, label: '现金', value: '6997 USD'),
                  DetailInfoRow(
                    inline: true,
                    label: '冻结保证金',
                    value: '1000 USD',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('现金')).dx,
      tester.getTopLeft(find.text('冻结保证金')).dx,
    );
    expect(
      tester.getTopRight(find.text('6997 USD')).dx,
      tester.getTopRight(find.text('1000 USD')).dx,
    );
    // 标签与金额字号不同，比较真实文字基线，不能用顶部坐标冒充对齐。
    final labelBox = tester.renderObject<RenderBox>(find.text('现金'));
    final valueBox = tester.renderObject<RenderBox>(find.text('6997 USD'));
    expect(
      tester.getTopLeft(find.text('现金')).dy +
          labelBox.getDryBaseline(
            labelBox.constraints,
            TextBaseline.alphabetic,
          )!,
      tester.getTopLeft(find.text('6997 USD')).dy +
          valueBox.getDryBaseline(
            valueBox.constraints,
            TextBaseline.alphabetic,
          )!,
    );
    await tester.pumpWidget(
      zhMaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: const SizedBox(
              width: 280,
              child: DetailInfoRow(
                inline: true,
                label: '保存时本位币净值',
                value: '123456789.12 USD',
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('123456789.12 USD')).dy,
      greaterThan(tester.getBottomLeft(find.text('保存时本位币净值')).dy),
    );
    expect(tester.widget<Text>(find.text('123456789.12 USD')).maxLines, isNull);
    expect(tester.takeException(), isNull);
  });
}
