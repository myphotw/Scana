import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/services/image_processing/capture_guide_policy.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/spread_capture_splitter.dart';

void main() {
  test('Single visible guide and persisted expected region use one policy', () {
    final regions = CaptureGuidePolicy.previewRegions(
      ScanCaptureMode.single,
      width: 1080,
      height: 1920,
    );
    final expected = CaptureGuidePolicy.singleForViewport(
      width: 1080,
      height: 1920,
    );
    expect(regions, hasLength(1));
    expect(regions.single.left, expected.left);
    expect(regions.single.top, expected.top);
    expect(regions.single.right, expected.right);
    expect(regions.single.bottom, expected.bottom);
  });

  test(
    'Spread preview guides map from the same left/right overlap ROI policy',
    () {
      final left = CaptureGuidePolicy.spreadForPreview(DocumentPageSide.left);
      final right = CaptureGuidePolicy.spreadForPreview(DocumentPageSide.right);
      expect(left.right, closeTo(.5005, .0001));
      expect(right.left, closeTo(.4995, .0001));
      final leftRoi = CaptureGuidePolicy.spreadForRoi(DocumentPageSide.left);
      final rightRoi = CaptureGuidePolicy.spreadForRoi(DocumentPageSide.right);
      expect(
        leftRoi.right,
        SpreadPageDetectionPolicy.expectedRegion(DocumentPageSide.left).right,
      );
      expect(
        rightRoi.left,
        SpreadPageDetectionPolicy.expectedRegion(DocumentPageSide.right).left,
      );
    },
  );
}
