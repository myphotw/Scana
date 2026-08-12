import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/image_processing/spread_capture_splitter.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/page_boundary.dart';

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

  test('does not run Perspective for a low-confidence spread boundary', () {
    final page = ScanPage(
      pageNo: 1,
      rawImagePath: 'right.jpg',
      createdTime: DateTime(2026, 8, 11),
      detectionConfidence: 0.54,
      documentCorners: const DocumentCorners(
        topLeft: DocumentPoint(10, 10),
        topRight: DocumentPoint(90, 10),
        bottomRight: DocumentPoint(90, 190),
        bottomLeft: DocumentPoint(10, 190),
      ),
    );

    expect(SpreadPageDetectionPolicy.isStableDetection(page), isFalse);
  });

  test('maps full-frame left live boundary into left overlap ROI', () {
    final mapped = SpreadCaptureRoiPolicy.toRoiBoundary(
      _fullBoundary(0.05, 0.50),
      DocumentPageSide.left,
    );

    expect(mapped.toDocumentCorners().topLeft.x, closeTo(0.05 / 0.55, 0.001));
    expect(mapped.toDocumentCorners().topRight.x, closeTo(0.50 / 0.55, 0.001));
  });

  test('maps full-frame right live boundary into right overlap ROI', () {
    final mapped = SpreadCaptureRoiPolicy.toRoiBoundary(
      _fullBoundary(0.50, 0.95),
      DocumentPageSide.right,
    );

    expect(mapped.toDocumentCorners().topLeft.x, closeTo(0.05 / 0.55, 0.001));
    expect(mapped.toDocumentCorners().topRight.x, closeTo(0.50 / 0.55, 0.001));
  });
}

PageBoundary _fullBoundary(double left, double right) =>
    PageBoundary.fromCorners(
      DocumentCorners(
        topLeft: DocumentPoint(left, 0.1),
        topRight: DocumentPoint(right, 0.1),
        bottomRight: DocumentPoint(right, 0.9),
        bottomLeft: DocumentPoint(left, 0.9),
      ),
      sourceWidth: 1,
      sourceHeight: 1,
      confidence: 0.8,
      stability: 1,
      timestamp: DateTime.utc(2026, 8, 12),
    );
