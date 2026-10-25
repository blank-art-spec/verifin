import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/app/veri_fin_scope.dart';
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
            const AvgoProbePage(),
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
