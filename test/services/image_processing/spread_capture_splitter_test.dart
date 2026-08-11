import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/image_processing/spread_capture_splitter.dart';
import 'package:scana/services/image_processing/document_detector.dart';

void main() {
  test('calculates overlap ROI geometry around the manual center guide', () {
    final rois = SpreadCaptureRoiPolicy.forSource(width: 2000, height: 1200);

    expect(rois.left.left, 0);
    expect(rois.left.right, 1100);
    expect(rois.right.left, 900);
    expect(rois.right.right, 2000);
    expect(rois.left.height, 1200);
    expect(rois.right.height, 1200);
  });

  test('keeps ROI coordinates inside the source at odd dimensions', () {
    final rois = SpreadCaptureRoiPolicy.forSource(width: 1001, height: 700);

    expect(rois.left.left, 0);
    expect(rois.left.right, lessThanOrEqualTo(1001));
    expect(rois.right.left, greaterThanOrEqualTo(0));
    expect(rois.right.right, 1001);
    expect(rois.left.right, greaterThan(rois.right.left));
  });

  test('uses the left expected region and reserves its right spine zone', () {
    final region = SpreadPageDetectionPolicy.expectedRegion(
      DocumentPageSide.left,
    );

    expect(region.left, SpreadPageDetectionPolicy.outerMargin);
    expect(region.right, 1 - SpreadPageDetectionPolicy.spineInset);
    expect(region.top, SpreadPageDetectionPolicy.verticalMargin);
    expect(region.bottom, 1 - SpreadPageDetectionPolicy.verticalMargin);
  });

  test('uses the right expected region and reserves its left spine zone', () {
    final region = SpreadPageDetectionPolicy.expectedRegion(
      DocumentPageSide.right,
    );

    expect(region.left, SpreadPageDetectionPolicy.spineInset);
    expect(region.right, 1 - SpreadPageDetectionPolicy.outerMargin);
    expect(region.top, SpreadPageDetectionPolicy.verticalMargin);
    expect(region.bottom, 1 - SpreadPageDetectionPolicy.verticalMargin);
  });
}
