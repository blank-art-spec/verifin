import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 计算环图两侧可供标签使用的最大宽度。
///
/// [size] 是卡片内实际画布大小，[ringSize] 是环的直径。每侧预留 12 像素
/// 给引导线、4 像素给边缘留白；负值归零，调用方可隐藏无法阅读的标签。
double categoryCalloutMaxLabelWidth(Size size, double ringSize) {
  return math.max(0, (size.width - ringSize) / 2 - 16);
}

/// 计算单条环图标签在画布内的位置。
///
/// [size] 为画布大小，[textSize] 为已按可用宽度排版后的文字尺寸；
/// [rightSide] 决定放在环的哪侧，[preferredY] 为引导线理想的纵向中心。
/// 横纵坐标都会钳在 4 像素安全边距内，避免文字画出卡片。
Rect categoryCalloutTextBounds(
  Size size,
  Size textSize, {
  required bool rightSide,
  required double preferredY,
}) {
  const margin = 4.0;
  final x = rightSide ? size.width - margin - textSize.width : margin;
  final y = (preferredY - textSize.height / 2)
      .clamp(margin, math.max(margin, size.height - margin - textSize.height))
      .toDouble();
  return Offset(x, y) & textSize;
}
