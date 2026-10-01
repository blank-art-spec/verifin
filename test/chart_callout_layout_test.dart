import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/chart_callout_layout.dart';

void main() {
  test('窄屏分类环图标签始终留在实际画布内', () {
    for (final width in <double>[260, 333, 393]) {
      final canvas = Size(width, 152);
      final labelWidth = categoryCalloutMaxLabelWidth(canvas, 126);
      expect(labelWidth, lessThan((width - 126) / 2));
      for (final rightSide in <bool>[false, true]) {
        for (final y in <double>[0, 76, 152]) {
          final bounds = categoryCalloutTextBounds(
            canvas,
            Size(labelWidth, 15),
            rightSide: rightSide,
            preferredY: y,
          );
          expect(bounds.left, greaterThanOrEqualTo(4));
          expect(bounds.right, lessThanOrEqualTo(width - 4));
          expect(bounds.top, greaterThanOrEqualTo(4));
          expect(bounds.bottom, lessThanOrEqualTo(148));
        }
      }
    }
  });
}
