import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/veri_fin_scope.dart';
import 'package:verifin/l10n/app_localizations.dart';
import 'package:verifin/pages/profile_pages.dart';

import 'support/test_harness.dart';

List<Finder> _tiles(Finder grid) => find
    .descendant(
      of: grid,
      matching: find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> && key.value.startsWith('profile_tile_');
      }),
    )
    .evaluate()
    .map(
      (element) => find.byElementPredicate((candidate) => candidate == element),
    )
    .toList();

int _firstRowColumns(WidgetTester tester, List<Finder> tiles) {
  final first = tester.getRect(tiles.first);
  return tiles
      .where((tile) => (tester.getRect(tile).top - first.top).abs() < 0.5)
      .length;
}

void _expectAlignedGrid(WidgetTester tester, List<Finder> tiles) {
  final rows = <List<Finder>>[];
  for (final tile in tiles) {
    final rect = tester.getRect(tile);
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    if (rows.isEmpty ||
        (tester.getRect(rows.last.first).top - rect.top).abs() > 0.5) {
      rows.add([]);
    }
    rows.last.add(tile);
    final label = find.descendant(of: tile, matching: find.byType(Text)).first;
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: tester.widget<Text>(label).data,
    );
    expect(tester.getRect(label).left, greaterThanOrEqualTo(rect.left));
    expect(tester.getRect(label).right, lessThanOrEqualTo(rect.right + 0.5));
    expect(tester.getRect(label).bottom, lessThanOrEqualTo(rect.bottom));
  }
  for (final row in rows) {
    final firstIcon = tester.getRect(
      find.descendant(of: row.first, matching: find.byType(VeriIconBox)),
    );
    final firstTexts = find.descendant(
      of: row.first,
      matching: find.byType(Text),
    );
    final firstSubtitle = tester.getRect(firstTexts.last);
    for (final tile in row) {
      final icon = tester.getRect(
        find.descendant(of: tile, matching: find.byType(VeriIconBox)),
      );
      expect(icon.top, closeTo(firstIcon.top, 0.5));
      expect(icon.width, closeTo(firstIcon.width, 0.5));
      expect(icon.height, closeTo(firstIcon.height, 0.5));
      final subtitle = find
          .descendant(of: tile, matching: find.byType(Text))
          .last;
      expect(tester.getRect(subtitle).top, closeTo(firstSubtitle.top, 0.5));
    }
  }
}

void main() {
  useTestDatabases();
  for (final size in [
    const Size(320, 568),
    const Size(360, 800),
    const Size(393, 852),
    const Size(852, 393),
  ]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final locale in [const Locale('zh'), const Locale('en')]) {
        testWidgets('我的宫格 $size 字体 $scale ${locale.languageCode} 两组列数与行内文字对齐', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          final controller = await makeController();
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            VeriFinScope(
              controller: controller,
              child: MaterialApp(
                locale: locale,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: buildVeriFinTheme(
                  locale.languageCode == 'en'
                      ? Brightness.dark
                      : Brightness.light,
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(body: SafeArea(child: ProfilePage())),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final scrollable = find
              .descendant(
                of: find.byType(ProfilePage),
                matching: find.byType(Scrollable),
              )
              .first;
          final bookkeeping = find.byKey(
            const ValueKey<String>('profile_feature_grid_bookkeeping'),
          );
          await tester.scrollUntilVisible(
            bookkeeping,
            150,
            scrollable: scrollable,
          );
          final bookTiles = _tiles(bookkeeping);
          expect(bookTiles, hasLength(5));
          _expectAlignedGrid(tester, bookTiles);
          final columns = _firstRowColumns(tester, bookTiles);
          final tileWidth = tester.getRect(bookTiles.first).width;
          if (size.width >= 360 && scale == 1) expect(columns, 4);

          final tools = find.byKey(
            const ValueKey<String>('profile_feature_grid_tools'),
          );
          await tester.scrollUntilVisible(tools, 150, scrollable: scrollable);
          await tester.pumpAndSettle();
          final toolTiles = _tiles(tools);
          expect(toolTiles, hasLength(9));
          expect(_firstRowColumns(tester, toolTiles), columns);
          expect(
            tester.getRect(toolTiles.first).width,
            closeTo(tileWidth, 0.5),
          );
          _expectAlignedGrid(tester, toolTiles);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
