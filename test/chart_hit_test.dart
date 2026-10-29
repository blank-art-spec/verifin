import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/app_theme.dart';
import 'package:verifin/app/chart_painters.dart';

/// 在周围保留透明保护区绘制气泡，并返回实际非透明像素相对于图表的边界。
/// [size] 是真实可用画布，[anchor] 覆盖左右端点，[tooltip] 使用英文长提示和长金额；
/// 不预先裁剪测试画布，因此修复前越界的背景或文字会被检测到，不能被截图边界掩盖。
Future<Rect> _tooltipPaintBounds(
  Size size,
  Offset anchor,
  ChartTooltip tooltip,
) async {
  const guard = 48;
  final width = size.width.toInt() + guard * 2;
  final height = size.height.toInt() + guard * 2;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..translate(guard.toDouble(), guard.toDouble());
  drawChartTooltip(
    canvas,
    size,
    anchor,
    tooltip,
    textScaler: const TextScaler.linear(1.5),
  );
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) throw StateError('图表提示没有生成可核对的像素');
    var left = width, top = height, right = -1, bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (bytes.getUint8((y * width + x) * 4 + 3) == 0) continue;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
    if (right < left || bottom < top) return Rect.zero;
    return Rect.fromLTRB(
      (left - guard).toDouble(),
      (top - guard).toDouble(),
      (right + 1 - guard).toDouble(),
      (bottom + 1 - guard).toDouble(),
    );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

/// 注册命中几何与真实气泡绘制边界检查；全部数据在本地构造，不连接外部行情。
void main() {
  for (final anchor in [const Offset(0, 70), const Offset(236, 150)]) {
    testWidgets('360dp基金图英文大字号长提示限宽换行且不越界 $anchor', (tester) async {
      // 360dp 页面扣除页面、卡片及图表边距后的典型画布，测试的是实际绘制而非文本存在。
      const size = Size(236, 170);
      const tooltip = ChartTooltip(
        title: 'Tuesday, October 27, 2026',
        lines: [
          ChartTooltipLine(text: '1098.15 USD'),
          ChartTooltipLine(
            text: 'NAV-period reference return: +123456789.12 USD',
            color: veriRoyal,
          ),
        ],
      );
      final bounds = await tester.runAsync(
        () => _tooltipPaintBounds(size, anchor, tooltip),
      );
      expect(bounds, isNotNull);
      final painted = bounds!;
      expect(painted.isEmpty, isFalse);
      expect(painted.left, greaterThanOrEqualTo(0));
      expect(painted.top, greaterThanOrEqualTo(0));
      expect(painted.right, lessThanOrEqualTo(size.width));
      expect(painted.bottom, lessThanOrEqualTo(size.height));
      expect(painted.height, greaterThan(80));
      expect(tester.takeException(), isNull);
    });
  }

  group('trendChartRect 绘图区内边距', () {
    const size = Size(100, 50);

    test('有 X/Y 轴标签：左留标签宽度、右侧不额外留白、底留 22', () {
      final rect = trendChartRect(size, hasXLabels: true, hasYLabels: true);
      expect(rect, const Rect.fromLTWH(30, 0, 70, 28));
    });

    test('无轴标签：不额外留右侧空白，占满宽度', () {
      final rect = trendChartRect(size, hasXLabels: false, hasYLabels: false);
      expect(rect, const Rect.fromLTWH(0, 0, 100, 50));
    });

    test('仅 Y 轴标签：左留标签宽度、右侧不额外留白、底不缩', () {
      final rect = trendChartRect(size, hasXLabels: false, hasYLabels: true);
      expect(rect, const Rect.fromLTWH(30, 0, 70, 50));
    });

    test('长金额标签可按实际宽度扩大左侧留白', () {
      final rect = trendChartRect(
        size,
        hasXLabels: true,
        hasYLabels: true,
        yLabelWidth: 46,
      );
      expect(rect, const Rect.fromLTWH(46, 0, 54, 28));
    });
  });

  group('barChartRect 绘图区内边距', () {
    const size = Size(100, 50);

    test('有 X/Y 轴标签：左留 30、右留 4、底留 22', () {
      final rect = barChartRect(size, hasXLabels: true, hasYLabels: true);
      expect(rect, const Rect.fromLTWH(30, 0, 66, 28));
    });

    test('无 Y 轴标签：占满宽度（无右内边距）', () {
      final rect = barChartRect(size, hasXLabels: false, hasYLabels: false);
      expect(rect, const Rect.fromLTWH(0, 0, 100, 50));
    });
  });

  group('chartNearestIndex 折线命中最近点', () {
    const rect = Rect.fromLTWH(0, 0, 100, 50);

    test('空数据返回 null', () {
      expect(chartNearestIndex(const Offset(50, 25), rect, 0), isNull);
    });

    test('单点：区内任意位置命中 0', () {
      expect(chartNearestIndex(const Offset(50, 25), rect, 1), 0);
    });

    test('按横坐标比例取最近点', () {
      expect(chartNearestIndex(const Offset(0, 25), rect, 5), 0);
      expect(chartNearestIndex(const Offset(25, 25), rect, 5), 1);
      expect(chartNearestIndex(const Offset(50, 25), rect, 5), 2);
      expect(chartNearestIndex(const Offset(100, 25), rect, 5), 4);
    });

    test('左右越界按 clamp 命中端点', () {
      expect(chartNearestIndex(const Offset(-8, 25), rect, 5), 0);
      expect(chartNearestIndex(const Offset(108, 25), rect, 5), 4);
    });

    test('落在膨胀区(14)之外返回 null', () {
      expect(chartNearestIndex(const Offset(200, 25), rect, 5), isNull);
      expect(chartNearestIndex(const Offset(50, 100), rect, 5), isNull);
    });
  });

  group('chartSlotIndex 柱状图命中槽位', () {
    const rect = Rect.fromLTWH(0, 0, 100, 50);

    test('空数据返回 null', () {
      expect(chartSlotIndex(const Offset(50, 25), rect, 0), isNull);
    });

    test('按等宽槽位 floor 命中', () {
      // count 4 → gap 25。
      expect(chartSlotIndex(const Offset(0, 25), rect, 4), 0);
      expect(chartSlotIndex(const Offset(24, 25), rect, 4), 0);
      expect(chartSlotIndex(const Offset(25, 25), rect, 4), 1);
      expect(chartSlotIndex(const Offset(99, 25), rect, 4), 3);
    });

    test('右边界 clamp 到最后一个槽位', () {
      expect(chartSlotIndex(const Offset(100, 25), rect, 4), 3);
    });

    test('落在膨胀区(10)之外返回 null', () {
      expect(chartSlotIndex(const Offset(200, 25), rect, 4), isNull);
      expect(chartSlotIndex(const Offset(50, 100), rect, 4), isNull);
    });
  });
}
