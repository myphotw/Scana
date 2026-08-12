import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/page_crop_decision.dart';

void main() {
  group('Paper Region', () {
    for (final fixture in const [
      'white paper with black music staff',
      'yellow paper',
      'soft shadow',
      'black background',
      'bright background',
      'many internal horizontal lines',
      'large table',
      'partially missing outer edge',
    ]) {
      test('$fixture keeps a trustworthy full paper candidate first', () {
        final decision = _decide(_paperResult(paperRegion: true));
        expect(decision.source, CropSource.highResPaperBoundary);
        expect(decision.corners.topLeft.x, 60);
      });
    }
  });

  group('Content Safe', () {
    test('paper failure with sufficient text selects content safe crop', () {
      expect(_decide(_contentResult()).source, CropSource.contentSafe);
    });

    test('content bounds carry proportional margin metadata', () {
      final result = _contentResult();
      expect(result.contentSafeMarginX, closeTo(0.08, 0.001));
      expect(result.contentSafeMarginY, closeTo(0.09, 0.001));
      expect(result.contentBounds?.topLeft.x, 150);
      expect(_decide(result).corners.topLeft.x, 80);
    });

    test('narrow content crop is rejected', () {
      final result = _contentResult(
        safe: _corners(left: 360, top: 80, right: 640, bottom: 1420),
      );
      expect(_decide(result).source, CropSource.guideFallback);
    });

    test('sparse page does not use content fallback', () {
      expect(
        _decide(_contentResult(componentCount: 3)).source,
        CropSource.guideFallback,
      );
    });

    test('blank page does not use content fallback', () {
      expect(_decide(_emptyResult()).source, CropSource.guideFallback);
    });

    test('unreliable noisy background components are excluded', () {
      expect(
        _decide(_contentResult(confidence: 0.2, componentCount: 400)).source,
        CropSource.guideFallback,
      );
    });

    test('out-of-ROI content crop is rejected by geometry validation', () {
      final result = _contentResult(
        safe: _corners(left: -30, top: 0, right: 900, bottom: 1400),
      );
      expect(_decide(result).source, CropSource.guideFallback);
    });
  });

  group('Fallback priority', () {
    test('paper precedes content', () {
      final paper = _paperResult().copyWithContent(_contentResult());
      expect(_decide(paper).source, CropSource.highResPaperBoundary);
    });

    test('content precedes guide', () {
      expect(_decide(_contentResult()).source, CropSource.contentSafe);
    });

    test('sane stable-live precedes guide', () {
      expect(
        _decide(_emptyResult(), stable: _boundary()).source,
        CropSource.captureLiveBoundary,
      );
    });

    test('narrow stable-live is rejected in favor of guide', () {
      expect(
        _decide(
          _emptyResult(),
          stable: _boundary(left: 0.34, right: 0.66),
        ).source,
        CropSource.guideFallback,
      );
    });

    test('spread sides may select different crop sources', () {
      final left = _decide(_paperResult(), side: DocumentPageSide.left);
      final right = _decide(_contentResult(), side: DocumentPageSide.right);
      expect(left.source, CropSource.highResPaperBoundary);
      expect(right.source, CropSource.contentSafe);
    });

    test('one spread-side detection failure remains independently safe', () {
      final left = _decide(_paperResult(), side: DocumentPageSide.left);
      final right = _decide(_emptyResult(), side: DocumentPageSide.right);
      expect(left.source, CropSource.highResPaperBoundary);
      expect(right.source, CropSource.guideFallback);
    });

    test('content fallback retains a conservative page area', () {
      final decision = _decide(_contentResult());
      final points = decision.corners.ordered;
      final width = points[1].x - points[0].x;
      final height = points[3].y - points[0].y;
      expect(width / 1000, greaterThanOrEqualTo(0.68));
      expect(height / 1500, greaterThanOrEqualTo(0.68));
    });
  });

  test(
    'native fallback metadata is decoded even when paper is not detected',
    () {
      final result = documentDetectionResultFromNative({
        'detected': false,
        'confidence': 0.2,
        'sourceWidth': 1000,
        'sourceHeight': 1500,
        'contentSafeCorners': _corners(
          left: 80,
          top: 90,
          right: 920,
          bottom: 1410,
        ).ordered.map((point) => point.toJson()).toList(),
        'contentBounds': _corners(
          left: 150,
          top: 180,
          right: 850,
          bottom: 1320,
        ).ordered.map((point) => point.toJson()).toList(),
        'contentSafeConfidence': 0.72,
        'contentComponentCount': 48,
        'contentSafeMarginX': 0.08,
        'contentSafeMarginY': 0.09,
        'paperRegionCandidate': false,
      });

      expect(result.detected, isFalse);
      expect(result.contentSafeCorners, isNotNull);
      expect(result.contentComponentCount, 48);
      expect(_decide(result).source, CropSource.contentSafe);
    },
  );
}

extension on DocumentDetectionResult {
  DocumentDetectionResult copyWithContent(DocumentDetectionResult content) {
    return DocumentDetectionResult(
      detected: detected,
      corners: corners,
      boundary: boundary,
      confidence: confidence,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      paperRegionCandidate: paperRegionCandidate,
      contentSafeCorners: content.contentSafeCorners,
      contentBounds: content.contentBounds,
      contentSafeConfidence: content.contentSafeConfidence,
      contentComponentCount: content.contentComponentCount,
      contentSafeMarginX: content.contentSafeMarginX,
      contentSafeMarginY: content.contentSafeMarginY,
    );
  }
}

PageCropDecision _decide(
  DocumentDetectionResult result, {
  PageBoundary? stable,
  DocumentPageSide? side,
}) => PageCropDecisionPolicy.decide(
  detection: result,
  guideCorners: _guide,
  captureBoundary: stable,
  pageSide: side,
)!;

DocumentDetectionResult _paperResult({bool paperRegion = false}) {
  final corners = _corners(left: 60, top: 60, right: 940, bottom: 1440);
  return DocumentDetectionResult(
    detected: true,
    corners: corners,
    boundary: PageBoundary.fromCorners(
      corners,
      sourceWidth: 1000,
      sourceHeight: 1500,
      confidence: 0.82,
      timestamp: DateTime.utc(2026, 8, 12),
    ),
    confidence: 0.82,
    sourceWidth: 1000,
    sourceHeight: 1500,
    paperRegionCandidate: paperRegion,
  );
}

DocumentDetectionResult _contentResult({
  DocumentCorners? safe,
  int componentCount = 48,
  double confidence = 0.72,
}) => DocumentDetectionResult(
  detected: false,
  confidence: 0.2,
  sourceWidth: 1000,
  sourceHeight: 1500,
  contentSafeCorners:
      safe ?? _corners(left: 80, top: 90, right: 920, bottom: 1410),
  contentBounds: _corners(left: 150, top: 180, right: 850, bottom: 1320),
  contentSafeConfidence: confidence,
  contentComponentCount: componentCount,
  contentSafeMarginX: 0.08,
  contentSafeMarginY: 0.09,
);

const _guide = DocumentCorners(
  topLeft: DocumentPoint(120, 120),
  topRight: DocumentPoint(880, 120),
  bottomRight: DocumentPoint(880, 1380),
  bottomLeft: DocumentPoint(120, 1380),
);

DocumentDetectionResult _emptyResult() => const DocumentDetectionResult(
  detected: false,
  confidence: 0,
  sourceWidth: 1000,
  sourceHeight: 1500,
);

DocumentCorners _corners({
  required double left,
  required double top,
  required double right,
  required double bottom,
}) => DocumentCorners(
  topLeft: DocumentPoint(left, top),
  topRight: DocumentPoint(right, top),
  bottomRight: DocumentPoint(right, bottom),
  bottomLeft: DocumentPoint(left, bottom),
);

PageBoundary _boundary({double left = 0.1, double right = 0.9}) =>
    PageBoundary.fromCorners(
      _corners(left: left, top: 0.1, right: right, bottom: 0.9),
      sourceWidth: 1,
      sourceHeight: 1,
      confidence: 0.7,
      stability: 1,
      timestamp: DateTime.utc(2026, 8, 12),
    );
