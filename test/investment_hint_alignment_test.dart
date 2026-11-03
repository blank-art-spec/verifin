import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/common_widgets.dart';
import 'package:verifin/app/investments/investment_widgets.dart';
import 'package:verifin/l10n/app_localizations.dart';

/// 使用真实页面主题挂载 [text] 对应的提示；[width] 与 [scale] 模拟手机和系统字号。
/// [locale]、[brightness] 覆盖中英文与深浅色；[accessibleSpacing] 同时开启系统粗体、
/// 行高、字距和词距偏好，确保测量和最终正文不会因辅助设置而使用不同的排版参数。
Future<void> _pumpHint(
  WidgetTester tester,
  String text, {
  required double width,
  required double scale,
  required Locale locale,
  required Brightness brightness,
  bool accessibleSpacing = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 852));
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildVeriFinTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 852),
          textScaler: TextScaler.linear(scale),
          boldText: accessibleSpacing,
          lineHeightScaleFactorOverride: accessibleSpacing ? 2 : null,
          letterSpacingOverride: accessibleSpacing ? 1 : null,
          wordSpacingOverride: accessibleSpacing ? 3 : null,
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: VeriCard(child: InvestmentHint(text)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 以 [tester] 读取真实正文和图标几何位置，验证图标中心对齐正文首行而非整段文字。
/// [text] 定位完整正文，[multiline] 区分短说明与悬挂缩进的多行说明；独立排版器只读取
/// RenderParagraph 已采用的有效参数，不访问组件内部 helper 或图标占位容器。
void _expectFirstLineAlignment(
  WidgetTester tester,
  String text, {
  required bool multiline,
}) {
  final hint = find.byType(InvestmentHint);
  final label = find.text(text);
  final icon = find.descendant(
    of: hint,
    matching: find.byIcon(Icons.info_outline),
  );
  final paragraph = tester.renderObject<RenderParagraph>(label);
  final painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  );
  try {
    painter.layout(
      minWidth: paragraph.constraints.minWidth,
      maxWidth: paragraph.constraints.maxWidth,
    );
    final lines = painter.computeLineMetrics();
    expect(lines, isNotEmpty);
    expect(lines.length, multiline ? greaterThan(1) : 1);
    final textOrigin = paragraph.localToGlobal(Offset.zero);
    final iconBounds = tester.getRect(icon);
    expect(
      iconBounds.center.dy,
      closeTo(textOrigin.dy + lines.first.height / 2, 0.5),
      reason: '信息图标应在实际首行行高中居中，不能固定顶端或居中整段说明',
    );
    expect(iconBounds.right, lessThan(textOrigin.dx));

    // 分别读取每行开头字符的真实选择框，核对续行仍从右侧文字列开始。
    // 不把字体回退造成的同一行多个字符 run 误当作多行，也不要求各行具有相同宽度。
    for (final line in lines) {
      final start = paragraph
          .getPositionForOffset(Offset(0, line.baseline - line.ascent / 2))
          .offset;
      expect(start, lessThan(text.length));
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
        boxHeightStyle: ui.BoxHeightStyle.tight,
      );
      expect(boxes, isNotEmpty);
      expect(
        textOrigin.dx + boxes.first.left,
        closeTo(textOrigin.dx + lines.first.left, 0.5),
        reason: '换行后应保留提示文字的悬挂缩进',
      );
      expect(line.width, lessThanOrEqualTo(paragraph.size.width + 0.5));
    }
    final labelWidget = tester.widget<Text>(label);
    expect(labelWidget.maxLines, isNull);
    expect(labelWidget.overflow, isNot(TextOverflow.ellipsis));
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(
      textOrigin.dy + paragraph.size.height,
      lessThanOrEqualTo(tester.getRect(hint).bottom + 0.5),
    );
    expect(tester.takeException(), isNull);
  } finally {
    painter.dispose();
  }
}

/// 同一矩阵用短句和长句分别检查单行与多行，覆盖窄屏、字体放大和字体回退。
/// 测试不比较组件内部占位值；原先 Row.start 的大字号图标会明显高于真实首行中心。
void main() {
  for (final width in [393.0, 360.0]) {
    for (final scale in [1.0, 1.8]) {
      for (final locale in [const Locale('zh'), const Locale('en')]) {
        final brightness = (locale.languageCode == 'zh') == (scale == 1)
            ? Brightness.light
            : Brightness.dark;
        testWidgets(
          '提示首行对齐 $width / $scale / ${locale.languageCode} / ${brightness.name}',
          (tester) async {
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final chinese = locale.languageCode == 'zh';
            for (final multiline in [false, true]) {
              final text = multiline
                  ? chinese
                        ? '尚未录入证券，暂无行情资料。录入证券交易或已有持仓后，可在这里查看。请核对证券名称、市场及品种，参考行情不会改写实际成交和现金。'
                        : 'No securities have been recorded yet. Record a securities trade or existing holdings to view quote details here. Review the name, market and instrument type before using the information.'
                  : chinese
                  ? '暂无行情'
                  : 'No data';
              await _pumpHint(
                tester,
                text,
                width: width,
                scale: scale,
                locale: locale,
                brightness: brightness,
              );
              _expectFirstLineAlignment(tester, text, multiline: multiline);
            }
          },
        );
      }
    }
  }

  testWidgets('缩小字号时装饰图标仍对齐首行，不超出实际行高', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const text = '尚未录入证券，暂无行情资料。';
    await _pumpHint(
      tester,
      text,
      width: 360,
      scale: 0.8,
      locale: const Locale('zh'),
      brightness: Brightness.dark,
    );
    _expectFirstLineAlignment(tester, text, multiline: false);
  });

  testWidgets('系统粗体及辅助行高字距词距下仍按实际首行对齐并保持换行缩进', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const text =
        'No securities have been recorded yet. Record a securities trade or existing holdings to view their quote details here.';
    await _pumpHint(
      tester,
      text,
      width: 360,
      scale: 1.6,
      locale: const Locale('en'),
      brightness: Brightness.light,
      accessibleSpacing: true,
    );
    _expectFirstLineAlignment(tester, text, multiline: true);
  });
}
