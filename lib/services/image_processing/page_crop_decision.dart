import 'dart:math' as math;

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/services/image_processing/document_detector.dart';

class PageCropDecision {
  const PageCropDecision({
    required this.source,
    required this.corners,
    required this.fallbackReason,
    this.boundary,
    this.captureBoundary,
    this.refineAttempted = false,
    this.refineAccepted = false,
    this.refineRejectedReason = 'not_attempted',
    this.cornerDeltaPercent = 0,
    this.areaRatioCapture = 0,
    this.areaRatioFinal = 0,
  });

  final CropSource source;
  final DocumentCorners corners;
  final PageBoundary? boundary;
  final String fallbackReason;
  final PageBoundary? captureBoundary;
  final bool refineAttempted;
  final bool refineAccepted;
  final String refineRejectedReason;
  final double cornerDeltaPercent;
  final double areaRatioCapture;
  final double areaRatioFinal;
}

/// Final-crop policy. Preview visibility deliberately does not use these
/// thresholds: showing a weak candidate is useful, applying it to pixels is not.
class PageCropDecisionPolicy {
  const PageCropDecisionPolicy._();

  static const double minimumPaperConfidence = 0.55;
  static const double minimumContentConfidence = 0.48;
  static const int minimumContentComponents = 10;

  static PageCropDecision? decide({
    required DocumentDetectionResult detection,
    required DocumentCorners? guideCorners,
    PageBoundary? captureBoundary,
    DocumentPageSide? pageSide,
  }) {
    final paperBoundary =
        detection.boundary ??
        _boundaryFromCorners(
          detection.corners,
          detection.sourceWidth,
          detection.sourceHeight,
          detection.confidence,
        );
    if (isSaneCaptureBoundary(captureBoundary, pageSide: pageSide)) {
      final refinement = CaptureBoundaryRefinementPolicy.refine(
        captureBoundary: captureBoundary!,
        highResBoundary:
            detection.detected &&
                detection.confidence >= minimumPaperConfidence &&
                isSaneBoundary(paperBoundary, pageSide: pageSide)
            ? paperBoundary
            : null,
      );
      return PageCropDecision(
        source: CropSource.captureLiveBoundary,
        corners: refinement.boundary.toDocumentCorners(),
        boundary: refinement.boundary,
        captureBoundary: captureBoundary,
        fallbackReason: 'none',
        refineAttempted: refinement.attempted,
        refineAccepted: refinement.accepted,
        refineRejectedReason: refinement.rejectedReason,
        cornerDeltaPercent: refinement.cornerDeltaPercent,
        areaRatioCapture: refinement.captureAreaRatio,
        areaRatioFinal: refinement.finalAreaRatio,
      );
    }
    if (detection.detected &&
        detection.confidence >= minimumPaperConfidence &&
        isSaneBoundary(paperBoundary, pageSide: pageSide)) {
      return PageCropDecision(
        source: CropSource.highResPaperBoundary,
        corners: paperBoundary!.toDocumentCorners(),
        boundary: paperBoundary,
        fallbackReason: 'none',
      );
    }

    final contentCorners = detection.contentSafeCorners;
    if (contentCorners != null &&
        detection.contentSafeConfidence >= minimumContentConfidence &&
        detection.contentComponentCount >= minimumContentComponents &&
        isSaneCorners(
          contentCorners,
          detection.sourceWidth,
          detection.sourceHeight,
          pageSide: pageSide,
          contentSafe: true,
        )) {
      return PageCropDecision(
        source: CropSource.contentSafe,
        corners: contentCorners,
        fallbackReason: paperBoundary == null
            ? 'paper_boundary_unavailable'
            : 'paper_boundary_unreliable',
      );
    }

    if (guideCorners != null) {
      return PageCropDecision(
        source: CropSource.guideFallback,
        corners: guideCorners,
        fallbackReason: captureBoundary == null
            ? 'capture_live_paper_and_content_unavailable'
            : 'capture_live_unsafe_and_fallbacks_unavailable',
      );
    }
    return null;
  }

  static bool isSaneBoundary(
    PageBoundary? boundary, {
    DocumentPageSide? pageSide,
  }) {
    if (boundary == null || !boundary.isValid) return false;
    final normalized = boundary.normalized();
    final points = normalized.closedPolygon;
    if (points.any(
      (point) => point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1,
    )) {
      return false;
    }
    final width = _extent(points.map((point) => point.x));
    final height = _extent(points.map((point) => point.y));
    final area = normalizedArea(points);
    final minimumWidth = pageSide == null ? 0.46 : 0.42;
    const minimumHeight = 0.48;
    final minimumArea = pageSide == null ? 0.24 : 0.22;
    return width >= minimumWidth &&
        height >= minimumHeight &&
        area >= minimumArea &&
        boundary.clippingEvidence < 0.88;
  }

  static bool isSaneCaptureBoundary(
    PageBoundary? boundary, {
    DocumentPageSide? pageSide,
  }) {
    if (!isSaneBoundary(boundary, pageSide: pageSide)) return false;
    final points = boundary!.normalized().closedPolygon;
    return _extent(points.map((point) => point.x)) >=
            (pageSide == null ? 0.52 : 0.48) &&
        _extent(points.map((point) => point.y)) >= 0.56 &&
        normalizedArea(points) >= (pageSide == null ? 0.32 : 0.30);
  }

  static bool isSaneCorners(
    DocumentCorners? corners,
    int width,
    int height, {
    DocumentPageSide? pageSide,
    bool contentSafe = false,
  }) {
    if (corners == null || width <= 0 || height <= 0) return false;
    final boundary = PageBoundary.fromCorners(
      corners,
      sourceWidth: width,
      sourceHeight: height,
      confidence: 1,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
    if (!boundary.isValid) return false;
    if (!contentSafe) return isSaneBoundary(boundary, pageSide: pageSide);
    final normalized = boundary.normalized();
    final points = normalized.closedPolygon;
    if (points.any(
      (point) => point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1,
    )) {
      return false;
    }
    return _extent(points.map((point) => point.x)) >= 0.68 &&
        _extent(points.map((point) => point.y)) >= 0.68 &&
        normalizedArea(points) >= 0.48;
  }

  static double normalizedArea(List<DocumentPoint> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      sum += points[index].x * next.y - next.x * points[index].y;
    }
    return sum.abs() / 2;
  }

  static double _extent(Iterable<double> values) {
    final list = values.toList();
    return list.reduce(math.max) - list.reduce(math.min);
  }

  static PageBoundary? _boundaryFromCorners(
    DocumentCorners? corners,
    int width,
    int height,
    double confidence,
  ) {
    if (corners == null || width <= 0 || height <= 0) return null;
    final boundary = PageBoundary.fromCorners(
      corners,
      sourceWidth: width,
      sourceHeight: height,
      confidence: confidence,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
    return boundary.isValid ? boundary : null;
  }
}

class CaptureBoundaryRefinementResult {
  const CaptureBoundaryRefinementResult({
    required this.boundary,
    required this.attempted,
    required this.accepted,
    required this.rejectedReason,
    required this.cornerDeltaPercent,
    required this.captureAreaRatio,
    required this.finalAreaRatio,
  });

  final PageBoundary boundary;
  final bool attempted;
  final bool accepted;
  final String rejectedReason;
  final double cornerDeltaPercent;
  final double captureAreaRatio;
  final double finalAreaRatio;
}

class CaptureBoundaryRefinementPolicy {
  const CaptureBoundaryRefinementPolicy._();

  static const double maximumCornerDelta = 0.05;
  static const double maximumMeanCornerDelta = 0.035;
  static const double maximumInwardEdgeMove = 0.025;
  static const double minimumRetainedArea = 0.96;
  static const double minimumRetainedExtent = 0.96;

  static CaptureBoundaryRefinementResult refine({
    required PageBoundary captureBoundary,
    PageBoundary? highResBoundary,
  }) {
    final capture = captureBoundary.normalized();
    final captureArea = PageCropDecisionPolicy.normalizedArea(
      capture.closedPolygon,
    );
    if (highResBoundary == null || !highResBoundary.isValid) {
      return _result(
        captureBoundary,
        attempted: false,
        accepted: false,
        reason: 'high_res_boundary_unavailable',
        delta: 0,
        captureArea: captureArea,
        finalArea: captureArea,
      );
    }
    final refined = highResBoundary.normalized();
    final captureCorners = capture.toDocumentCorners().ordered;
    final refinedCorners = refined.toDocumentCorners().ordered;
    final deltas = List.generate(4, (index) {
      final dx = captureCorners[index].x - refinedCorners[index].x;
      final dy = captureCorners[index].y - refinedCorners[index].y;
      return math.sqrt(dx * dx + dy * dy);
    });
    final maximumDelta = deltas.reduce(math.max);
    final meanDelta = deltas.reduce((a, b) => a + b) / deltas.length;
    final captureBounds = _bounds(capture.closedPolygon);
    final refinedBounds = _bounds(refined.closedPolygon);
    final refinedArea = PageCropDecisionPolicy.normalizedArea(
      refined.closedPolygon,
    );
    String? rejection;
    if (maximumDelta > maximumCornerDelta ||
        meanDelta > maximumMeanCornerDelta) {
      rejection = 'excessive_corner_delta';
    } else if (refinedArea < captureArea * minimumRetainedArea) {
      rejection = 'area_shrunk';
    } else if (refinedBounds.$3 - refinedBounds.$1 <
            (captureBounds.$3 - captureBounds.$1) * minimumRetainedExtent ||
        refinedBounds.$4 - refinedBounds.$2 <
            (captureBounds.$4 - captureBounds.$2) * minimumRetainedExtent) {
      rejection = 'extent_shrunk';
    } else if (refinedBounds.$1 - captureBounds.$1 > maximumInwardEdgeMove ||
        captureBounds.$3 - refinedBounds.$3 > maximumInwardEdgeMove ||
        refinedBounds.$2 - captureBounds.$2 > maximumInwardEdgeMove ||
        captureBounds.$4 - refinedBounds.$4 > maximumInwardEdgeMove) {
      rejection = 'inward_edge_move';
    }
    final accepted = rejection == null;
    final finalBoundary = accepted ? highResBoundary : captureBoundary;
    return _result(
      finalBoundary,
      attempted: true,
      accepted: accepted,
      reason: rejection ?? 'none',
      delta: meanDelta * 100,
      captureArea: captureArea,
      finalArea: accepted ? refinedArea : captureArea,
    );
  }

  static (double, double, double, double) _bounds(List<DocumentPoint> points) =>
      (
        points.map((point) => point.x).reduce(math.min),
        points.map((point) => point.y).reduce(math.min),
        points.map((point) => point.x).reduce(math.max),
        points.map((point) => point.y).reduce(math.max),
      );

  static CaptureBoundaryRefinementResult _result(
    PageBoundary boundary, {
    required bool attempted,
    required bool accepted,
    required String reason,
    required double delta,
    required double captureArea,
    required double finalArea,
  }) => CaptureBoundaryRefinementResult(
    boundary: boundary,
    attempted: attempted,
    accepted: accepted,
    rejectedReason: reason,
    cornerDeltaPercent: delta,
    captureAreaRatio: captureArea,
    finalAreaRatio: finalArea,
  );
}
