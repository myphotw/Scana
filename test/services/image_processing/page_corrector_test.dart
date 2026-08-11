import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/services/image_processing/page_corrector.dart';

void main() {
  group('PerspectiveGeometry', () {
    test('uses the longest opposing edges for output size', () {
      const corners = DocumentCorners(
        topLeft: DocumentPoint(10, 20),
        topRight: DocumentPoint(810, 20),
        bottomRight: DocumentPoint(910, 1220),
        bottomLeft: DocumentPoint(0, 1020),
      );

      final size = PerspectiveGeometry.outputSize(corners);

      expect(size.width, 932);
      expect(size.height, 1204);
    });

    test('accepts top-left to bottom-left clockwise corner order', () {
      const corners = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(100, 0),
        bottomRight: DocumentPoint(100, 200),
        bottomLeft: DocumentPoint(0, 200),
      );

      expect(PerspectiveGeometry.hasValidCornerOrder(corners), isTrue);
    });

    test('rejects crossed or counter-clockwise corner order', () {
      const crossed = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(100, 200),
        bottomRight: DocumentPoint(100, 0),
        bottomLeft: DocumentPoint(0, 200),
      );
      const counterClockwise = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(0, 200),
        bottomRight: DocumentPoint(100, 200),
        bottomLeft: DocumentPoint(100, 0),
      );

      expect(PerspectiveGeometry.hasValidCornerOrder(crossed), isFalse);
      expect(
        PerspectiveGeometry.hasValidCornerOrder(counterClockwise),
        isFalse,
      );
    });
  });

  group('CurvedPagePolicy', () {
    const visibleCorners = DocumentCorners(
      topLeft: DocumentPoint(40, 50),
      topRight: DocumentPoint(960, 45),
      bottomRight: DocumentPoint(950, 1450),
      bottomLeft: DocumentPoint(45, 1440),
    );

    test('prioritizes a visible page boundary', () {
      final mode = CurvedPagePolicy.selectBoundaryMode(
        corners: visibleCorners,
        sourceWidth: 1000,
        sourceHeight: 1500,
      );

      expect(mode, PageBoundaryMode.detected);
      final region = CurvedPagePolicy.regionFor(mode);
      expect(
        [region.left, region.top, region.right, region.bottom],
        [0, 0, 1, 1],
      );
    });

    test('uses a responsive inset when a boundary reaches the frame', () {
      const clippedCorners = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(1000, 0),
        bottomRight: DocumentPoint(1000, 1500),
        bottomLeft: DocumentPoint(0, 1500),
      );
      final mode = CurvedPagePolicy.selectBoundaryMode(
        corners: clippedCorners,
        sourceWidth: 1000,
        sourceHeight: 1500,
      );

      expect(mode, PageBoundaryMode.insetFallback);
      final region = CurvedPagePolicy.regionFor(mode);
      expect(region.left, 0.04);
      expect(region.top, 0.04);
      expect(region.right, 0.96);
      expect(region.bottom, 0.96);
    });

    test('rejects low-confidence curvature', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 4, 6, 4, 0],
          imageHeight: 1000,
          confidence: 0.4,
        ),
        isFalse,
      );
    });

    test('accepts a smooth, bounded, asymmetric curve', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 1, 3, 5, 6, 5, 3, 2, 0],
          imageHeight: 1000,
          confidence: 0.85,
        ),
        isTrue,
      );
    });

    test('rejects excessive deformation and abrupt adjacent changes', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 35, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 2, 8, 2, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
    });

    test('rejects NaN and out-of-range remap inputs', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, double.nan, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 10000, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
    });
  });

  group('curved correction adoption', () {
    test('accepts boundary, baseline, and composite signal evidence', () {
      expect(
        const CurvedSignalEvidence(boundaryCurves: 2).boundaryPreferred,
        isTrue,
      );
      expect(
        const CurvedSignalEvidence(baselineCurves: 2).hasSufficientSignals,
        isTrue,
      );
      expect(
        const CurvedSignalEvidence(
          boundaryCurves: 1,
          longHorizontalStructures: 1,
        ).hasSufficientSignals,
        isTrue,
      );
      expect(
        const CurvedSignalEvidence(baselineCurves: 1).hasSufficientSignals,
        isFalse,
      );
    });

    test('rejects degraded output and unsafe stretching', () {
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.6,
          maximumStretchFraction: 0.01,
        ),
        isFalse,
      );
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.82,
          maximumStretchFraction: 0.04,
        ),
        isFalse,
      );
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.82,
          maximumStretchFraction: 0.01,
        ),
        isTrue,
      );
    });
  });
}
