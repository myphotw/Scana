import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/services/image_processing/live_document_detection.dart';

void main() {
  group('PageBoundary to corners', () {
    test('converts a rectangular boundary', () {
      final corners = _boundary().toDocumentCorners();

      expect(corners.topLeft.toJson(), {'x': 10.0, 'y': 20.0});
      expect(corners.topRight.toJson(), {'x': 90.0, 'y': 20.0});
      expect(corners.bottomRight.toJson(), {'x': 90.0, 'y': 180.0});
      expect(corners.bottomLeft.toJson(), {'x': 10.0, 'y': 180.0});
    });

    test('keeps representative corners for curved asymmetric edges', () {
      final boundary = PageBoundary(
        top: const [
          DocumentPoint(12, 20),
          DocumentPoint(50, 28),
          DocumentPoint(92, 23),
        ],
        right: const [
          DocumentPoint(92, 23),
          DocumentPoint(95, 100),
          DocumentPoint(88, 182),
        ],
        bottom: const [
          DocumentPoint(88, 182),
          DocumentPoint(48, 175),
          DocumentPoint(8, 178),
        ],
        left: const [
          DocumentPoint(8, 178),
          DocumentPoint(5, 90),
          DocumentPoint(12, 20),
        ],
        confidence: 0.9,
        stability: 1,
        sourceWidth: 100,
        sourceHeight: 200,
        timestamp: DateTime.utc(2026, 8, 10),
      );

      final corners = boundary.toDocumentCorners();

      expect(corners.topLeft.x, 12);
      expect(corners.topRight.x, 92);
      expect(corners.bottomRight.y, 182);
      expect(corners.bottomLeft.x, 8);
    });
  });

  group('Boundary quality guidance', () {
    test('detects clipped, too-close, too-far, unstable, and ready states', () {
      expect(
        BoundaryQualityAssessment.evaluate(
          _boundary(left: 0, right: 100, clippingEvidence: 0.6),
        ).guidance,
        BoundaryGuidance.clipped,
      );
      expect(
        BoundaryQualityAssessment.evaluate(
          _boundary(
            left: 0.5,
            top: 1,
            right: 99.5,
            bottom: 199,
            clippingEvidence: 0.25,
          ),
        ).guidance,
        BoundaryGuidance.tooClose,
      );
      expect(
        BoundaryQualityAssessment.evaluate(
          _boundary(left: 40, top: 80, right: 60, bottom: 120),
        ).guidance,
        BoundaryGuidance.tooFar,
      );
      expect(
        BoundaryQualityAssessment.evaluate(_boundary(stability: 0.6)).guidance,
        BoundaryGuidance.unstable,
      );
      expect(
        BoundaryQualityAssessment.evaluate(_boundary()).guidance,
        BoundaryGuidance.ready,
      );
    });

    test('accepts a large complete page when no clipping is observed', () {
      expect(
        BoundaryQualityAssessment.evaluate(
          _boundary(left: 1, top: 2, right: 99, bottom: 198),
        ).guidance,
        BoundaryGuidance.ready,
      );
    });

    test('does not call a small high-confidence document too far', () {
      expect(
        BoundaryQualityAssessment.evaluate(
          _boundary(left: 30, top: 50, right: 70, bottom: 150),
        ).guidance,
        BoundaryGuidance.ready,
      );
    });
  });

  test('stabilizes and smooths a multi-point page boundary', () {
    final stabilizer = PageBoundaryStabilizer();
    final now = DateTime.utc(2026, 8, 10);
    for (var index = 0; index < 3; index++) {
      final boundary = _boundary(left: 10 + index.toDouble());
      stabilizer.update(
        DocumentDetectionResult(
          detected: true,
          confidence: 0.9,
          sourceWidth: 100,
          sourceHeight: 200,
          boundary: boundary,
          corners: boundary.toDocumentCorners(),
        ),
        now.add(Duration(milliseconds: index * 100)),
      );
    }
    expect(stabilizer.isStable, isTrue);
    expect(stabilizer.stableNormalizedBoundary!.top, hasLength(24));
    final before = stabilizer.stableNormalizedBoundary!.top.first.x;

    final moved = _boundary(left: 16);
    stabilizer.update(
      DocumentDetectionResult(
        detected: true,
        confidence: 0.9,
        sourceWidth: 100,
        sourceHeight: 200,
        boundary: moved,
        corners: moved.toDocumentCorners(),
      ),
      now.add(const Duration(milliseconds: 350)),
    );

    final after = stabilizer.stableNormalizedBoundary!.top.first.x;
    expect(after, greaterThan(before));
    expect(after, lessThan(0.16));
    stabilizer.miss(now.add(const Duration(milliseconds: 900)));
    expect(stabilizer.isStable, isTrue);
    stabilizer.miss(now.add(const Duration(milliseconds: 1200)));
    expect(stabilizer.isStable, isFalse);
  });

  test('persists the detected spine side', () {
    final restored = PageBoundary.fromJson(
      _boundary()
          .copyWith(spineSide: PageBoundarySide.right, clippingEvidence: 0.5)
          .toJson(),
    );

    expect(restored!.spineSide, PageBoundarySide.right);
    expect(restored.clippingEvidence, 0.5);
  });

  test('rejects a self-intersecting boundary polygon', () {
    final crossed = PageBoundary.fromCorners(
      const DocumentCorners(
        topLeft: DocumentPoint(10, 20),
        topRight: DocumentPoint(90, 180),
        bottomRight: DocumentPoint(90, 20),
        bottomLeft: DocumentPoint(10, 180),
      ),
      sourceWidth: 100,
      sourceHeight: 200,
      confidence: 0.9,
      timestamp: DateTime.utc(2026, 8, 10),
    );

    expect(crossed.isValid, isFalse);
  });

  test(
    'retains a stable outer boundary over a sudden internal-line shrink',
    () {
      final stabilizer = PageBoundaryStabilizer();
      final now = DateTime.utc(2026, 8, 10);
      for (var index = 0; index < 3; index++) {
        final page = _boundary();
        stabilizer.update(
          DocumentDetectionResult(
            detected: true,
            confidence: 0.9,
            sourceWidth: 100,
            sourceHeight: 200,
            boundary: page,
            corners: page.toDocumentCorners(),
          ),
          now.add(Duration(milliseconds: index * 100)),
        );
      }

      final internalLine = _boundary(bottom: 125);
      stabilizer.update(
        DocumentDetectionResult(
          detected: true,
          confidence: 0.9,
          sourceWidth: 100,
          sourceHeight: 200,
          boundary: internalLine,
          corners: internalLine.toDocumentCorners(),
        ),
        now.add(const Duration(milliseconds: 350)),
      );

      final retainedBottom = stabilizer.stableNormalizedBoundary!.closedPolygon
          .map((point) => point.y)
          .reduce((a, b) => a > b ? a : b);
      expect(retainedBottom, closeTo(0.9, 0.001));
    },
  );
}

PageBoundary _boundary({
  double left = 10,
  double top = 20,
  double right = 90,
  double bottom = 180,
  double confidence = 0.9,
  double stability = 1,
  double clippingEvidence = 0,
}) => PageBoundary(
  top: [
    DocumentPoint(left, top),
    DocumentPoint((left + right) / 2, top + 2),
    DocumentPoint(right, top),
  ],
  right: [
    DocumentPoint(right, top),
    DocumentPoint(right - 1, (top + bottom) / 2),
    DocumentPoint(right, bottom),
  ],
  bottom: [
    DocumentPoint(right, bottom),
    DocumentPoint((left + right) / 2, bottom - 2),
    DocumentPoint(left, bottom),
  ],
  left: [
    DocumentPoint(left, bottom),
    DocumentPoint(left + 1, (top + bottom) / 2),
    DocumentPoint(left, top),
  ],
  confidence: confidence,
  stability: stability,
  sourceWidth: 100,
  sourceHeight: 200,
  timestamp: DateTime.utc(2026, 8, 10),
  clippingEvidence: clippingEvidence,
);
