import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';

void main() {
  const tabletBody = Size(2560, 1400);

  test('90-degree portrait document uses tablet body height', () {
    final rendered = ScanResultPreviewLayout.containedRenderedSize(
      imageSize: const Size(1500, 1000),
      availableBody: tabletBody,
      rotation: 90,
    );

    expect(rendered.height, 1400);
    expect(rendered.width, closeTo(933.3333, 0.001));
  });

  test('270-degree portrait document uses tablet body height', () {
    final rendered = ScanResultPreviewLayout.containedRenderedSize(
      imageSize: const Size(1500, 1000),
      availableBody: tabletBody,
      rotation: 270,
    );

    expect(rendered.height, 1400);
    expect(rendered.width, closeTo(933.3333, 0.001));
  });

  test('90-degree landscape source becomes a tall page using full body height', () {
    final rendered = ScanResultPreviewLayout.containedRenderedSize(
      imageSize: const Size(1000, 1500),
      availableBody: tabletBody,
      rotation: 90,
    );

    expect(rendered.height, 1400);
    expect(rendered.width, closeTo(2100, 0.001));
  });

  test('0 and 180 degrees keep original layout constraints', () {
    for (final rotation in [0, 180]) {
      expect(
        ScanResultPreviewLayout.imageLayoutSize(tabletBody, rotation),
        tabletBody,
      );
    }
  });
}
