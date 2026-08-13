import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/image_quality.dart';

abstract interface class PageCorrector {
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  });
}

enum PageBoundaryMode { detected, insetFallback }

class UnavailablePageCorrector implements PageCorrector {
  const UnavailablePageCorrector();

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) {
    throw UnsupportedError('Page correction is unavailable.');
  }
}

class OpenCvPageCorrector implements PageCorrector {
  const OpenCvPageCorrector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.myphotw.scana/page_corrector';
  final MethodChannel _channel;

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) async {
    if (!PerspectiveGeometry.hasValidCornerOrder(corners)) {
      throw ArgumentError(
        'Document corners must form a clockwise quadrilateral.',
      );
    }
    Map<String, dynamic>? value;
    try {
      value = await _channel.invokeMapMethod<String, dynamic>('correctPage', {
        'sourceImagePath': sourceImagePath,
        'outputImagePath': outputImagePath,
        'correctionType': type.name,
        'pageBoundaryMode': boundaryMode.name,
        'curvePolicy': CurvedPagePolicy.nativeConfiguration,
        'corners': corners.ordered.map((point) => point.toJson()).toList(),
        if (pageBoundary != null) 'pageBoundary': pageBoundary.toJson(),
      });
    } on PlatformException catch (error) {
      throw PageCorrectionFailure(
        switch (error.code) {
          'curve_nearly_flat' => CorrectionOutcome.nearlyFlat,
          'curve_unsafe' => CorrectionOutcome.unsafeDeformation,
          'curve_not_improved' => CorrectionOutcome.notImproved,
          _ => CorrectionOutcome.lowConfidence,
        },
        error.message,
        error.code,
        _diagnostics(error.details),
      );
    }
    final width = value?['outputWidth'];
    final height = value?['outputHeight'];
    if (width is! int || height is! int || width <= 0 || height <= 0) {
      throw const FormatException(
        'Page corrector returned invalid output data.',
      );
    }
    return PageCorrectionResult(
      outputWidth: width,
      outputHeight: height,
      outcome: CorrectionOutcome.values.firstWhere(
        (outcome) => outcome.name == value?['outcome'],
        orElse: () => CorrectionOutcome.completed,
      ),
      diagnostics: _diagnostics(value?['curveDiagnostics']),
      sourceQuality: ImageQualityMetrics.fromNative(value, 'source'),
      outputQuality: ImageQualityMetrics.fromNative(value, 'output'),
      outputFormat: value?['outputFormat'] as String?,
    );
  }

  static Map<String, Object> _diagnostics(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is Object)
          entry.key as String: entry.value as Object,
    };
  }
}

class PageCorrectionFailure implements Exception {
  const PageCorrectionFailure(
    this.outcome, [
    this.message,
    this.reason,
    this.diagnostics = const {},
  ]);

  final CorrectionOutcome outcome;
  final String? message;
  final String? reason;
  final Map<String, Object> diagnostics;
}

class CurvedResultQuality {
  const CurvedResultQuality._();

  static bool shouldAdopt({
    required double perspectiveStraightness,
    required double curvedStraightness,
    required double maximumStretchFraction,
    CurvatureState state = CurvatureState.strongCurve,
    double geometryBefore = 0,
    double geometryAfter = 0,
  }) {
    if (!perspectiveStraightness.isFinite ||
        !curvedStraightness.isFinite ||
        !maximumStretchFraction.isFinite ||
        maximumStretchFraction > 0.025) {
      return false;
    }
    final requiredRatio = state == CurvatureState.mildCurve ? 1.0005 : 1.005;
    final straightnessImproved =
        perspectiveStraightness > 0 &&
        curvedStraightness >= perspectiveStraightness * requiredRatio;
    final geometryImproved =
        state == CurvatureState.mildCurve &&
        geometryBefore >= AutomaticCurvaturePolicy.flatMagnitudeLimit &&
        geometryAfter <= geometryBefore * 0.995;
    return straightnessImproved || geometryImproved;
  }
}

/// Guards adoption of a curved revision before it can replace the stable
/// perspective result. Curved remapping is expected to preserve the rectified
/// canvas; large geometry changes indicate a coordinate-space or remap error.
class CorrectionOutputSanity {
  const CorrectionOutputSanity._();

  static const double maximumDimensionChangeFraction = 0.02;
  static const double maximumAspectRatioChangeFraction = 0.02;

  static bool preservesPerspectiveCanvas({
    required PageCorrectionResult perspective,
    required PageCorrectionResult curved,
  }) {
    if (perspective.outputWidth <= 0 ||
        perspective.outputHeight <= 0 ||
        curved.outputWidth <= 0 ||
        curved.outputHeight <= 0) {
      return false;
    }
    final widthChange =
        (curved.outputWidth - perspective.outputWidth).abs() /
        perspective.outputWidth;
    final heightChange =
        (curved.outputHeight - perspective.outputHeight).abs() /
        perspective.outputHeight;
    final perspectiveAspect =
        perspective.outputWidth / perspective.outputHeight;
    final curvedAspect = curved.outputWidth / curved.outputHeight;
    final aspectChange =
        (curvedAspect - perspectiveAspect).abs() / perspectiveAspect;
    return widthChange <= maximumDimensionChangeFraction &&
        heightChange <= maximumDimensionChangeFraction &&
        aspectChange <= maximumAspectRatioChangeFraction;
  }
}

class CurvedSignalEvidence {
  const CurvedSignalEvidence({
    this.boundaryCurves = 0,
    this.baselineCurves = 0,
    this.longHorizontalStructures = 0,
    this.spineBoundaries = 0,
  });

  final int boundaryCurves;
  final int baselineCurves;
  final int longHorizontalStructures;
  final int spineBoundaries;

  bool get hasSufficientSignals =>
      boundaryCurves >= 2 ||
      baselineCurves +
              longHorizontalStructures +
              boundaryCurves +
              spineBoundaries >=
          2;

  bool get boundaryPreferred => boundaryCurves >= 2;
}

class ContourCurveMetric {
  const ContourCurveMetric({
    required this.magnitude,
    required this.direction,
    required this.consistency,
    this.rawDirection = 0,
  });

  final double magnitude;
  final double direction;
  final double consistency;
  final double rawDirection;

  bool get isCurved => magnitude >= AutomaticCurvaturePolicy.flatMagnitudeLimit;
}

/// Converts the owned AI paper contour into directional page-edge samples.
///
/// The final four-corner polygon remains the Perspective source of truth. The
/// contour is used only as curvature evidence, so exposing it cannot change
/// AI Primary crop selection or Visibility-Safe Boundary scoring.
class PageContourGeometryEvidence {
  const PageContourGeometryEvidence._();

  static double normalizeInternalDirection({required double rawDirection}) =>
      rawDirection;

  static PageBoundary? boundaryFromContour({
    required List<DocumentPoint> contour,
    required DocumentCorners corners,
    required int sourceWidth,
    required int sourceHeight,
    PageBoundarySide? spineSide,
  }) {
    if (contour.length < 12 || sourceWidth <= 0 || sourceHeight <= 0) {
      return null;
    }
    final ordered = corners.ordered;
    final starts = [ordered[0], ordered[1], ordered[2], ordered[3]];
    final ends = [ordered[1], ordered[2], ordered[3], ordered[0]];
    final buckets = List.generate(
      4,
      (_) => <({DocumentPoint point, double t})>[],
    );
    for (final point in contour) {
      if (!point.x.isFinite || !point.y.isFinite) continue;
      var bestSide = 0;
      var bestDistance = double.infinity;
      var bestT = 0.0;
      for (var side = 0; side < 4; side++) {
        final projection = _project(point, starts[side], ends[side]);
        final normalizedDistance =
            projection.distance /
            math.max(1.0, _distance(starts[side], ends[side]));
        if (normalizedDistance < bestDistance) {
          bestDistance = normalizedDistance;
          bestSide = side;
          bestT = projection.t;
        }
      }
      buckets[bestSide].add((point: point, t: bestT));
    }

    List<DocumentPoint>? side(int index) {
      final samples = buckets[index]..sort((a, b) => a.t.compareTo(b.t));
      if (samples.length < 2) return null;
      final output = <DocumentPoint>[starts[index]];
      output.addAll(samples.map((sample) => sample.point));
      output.add(ends[index]);
      return _deduplicate(output);
    }

    final top = side(0);
    final right = side(1);
    final bottom = side(2);
    final left = side(3);
    if (top == null || right == null || bottom == null || left == null) {
      return null;
    }
    final boundary = PageBoundary(
      top: top,
      right: right,
      bottom: bottom,
      left: left,
      confidence: 1,
      stability: 1,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      spineSide: spineSide,
    );
    return boundary.isValid ? boundary : null;
  }

  static ContourCurveMetric measure({
    required List<DocumentPoint> points,
    required DocumentPoint start,
    required DocumentPoint end,
    required double normalization,
  }) {
    if (points.length < 4 || normalization <= 0) {
      return const ContourCurveMetric(
        magnitude: 0,
        direction: 0,
        consistency: 0,
      );
    }
    final horizontalStart = start.x <= end.x ? start : end;
    final horizontalEnd = start.x <= end.x ? end : start;
    final allSamples = points
        .map((point) {
          final projection = _project(point, horizontalStart, horizontalEnd);
          return (
            t: projection.t,
            signed:
                _signedDistance(point, horizontalStart, horizontalEnd) /
                normalization,
          );
        })
        .where((sample) => sample.signed.isFinite)
        .toList();
    final centralSamples = allSamples
        .where((sample) => sample.t >= 0.10 && sample.t <= 0.90)
        .toList();
    final robustSamples = centralSamples.length >= 4
        ? centralSamples
        : allSamples;
    if (robustSamples.length < 4) {
      return const ContourCurveMetric(
        magnitude: 0,
        direction: 0,
        consistency: 0,
      );
    }
    final rawSigned = robustSamples.map((sample) => sample.signed).toList();
    final signed = rawSigned;
    final absolute = signed.map((value) => value.abs()).toList()..sort();
    final magnitude =
        absolute[((absolute.length - 1) * 0.90).round().clamp(
          0,
          absolute.length - 1,
        )];
    final nonFlat = signed
        .where((value) => value.abs() >= magnitude * 0.25)
        .toList();
    final positive = nonFlat.where((value) => value > 0).length;
    final negative = nonFlat.where((value) => value < 0).length;
    final dominant = math.max(positive, negative);
    final rawNonFlat = rawSigned
        .where((value) => value.abs() >= magnitude * 0.25)
        .toList();
    final rawPositive = rawNonFlat.where((value) => value > 0).length;
    final rawNegative = rawNonFlat.where((value) => value < 0).length;
    return ContourCurveMetric(
      magnitude: magnitude,
      direction: positive == negative ? 0 : (positive > negative ? 1 : -1),
      consistency: nonFlat.isEmpty ? 0 : dominant / nonFlat.length,
      rawDirection: rawPositive == rawNegative
          ? 0
          : (rawPositive > rawNegative ? 1 : -1),
    );
  }

  static ({double t, double distance}) _project(
    DocumentPoint point,
    DocumentPoint start,
    DocumentPoint end,
  ) {
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final lengthSquared = dx * dx + dy * dy;
    final t = lengthSquared <= 0
        ? 0.0
        : (((point.x - start.x) * dx + (point.y - start.y) * dy) /
                  lengthSquared)
              .clamp(0.0, 1.0);
    final projected = DocumentPoint(start.x + dx * t, start.y + dy * t);
    return (t: t, distance: _distance(point, projected));
  }

  static double _signedDistance(
    DocumentPoint point,
    DocumentPoint start,
    DocumentPoint end,
  ) {
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length <= 0) return 0;
    final projection = _project(point, start, end);
    final chordX = start.x + dx * projection.t;
    final chordY = start.y + dy * projection.t;
    return (point.x - chordX) * (-dy / length) +
        (point.y - chordY) * (dx / length);
  }

  static double _distance(DocumentPoint first, DocumentPoint second) => math
      .sqrt(math.pow(first.x - second.x, 2) + math.pow(first.y - second.y, 2));

  static List<DocumentPoint> _deduplicate(List<DocumentPoint> points) {
    final output = <DocumentPoint>[];
    for (final point in points) {
      if (output.isEmpty || _distance(output.last, point) > 0.5) {
        output.add(point);
      }
    }
    return output;
  }
}

class AutomaticCurvaturePolicy {
  const AutomaticCurvaturePolicy._();

  static const double flatMagnitudeLimit = 0.0015;
  static const double mildMagnitudeLimit = 0.008;
  static const double mildMinimumConfidence = 0.56;
  static const double mildMinimumCoverage = 0.52;
  static const double mildMinimumConsistency = 0.72;
  static const double mildDewarpStrength = 0.55;

  static CurvatureState classify({
    required double magnitude,
    required double confidence,
    required double coverage,
    required double consistency,
    required int evidenceCount,
    double pageContourMagnitude = 0,
    double internalLineMagnitude = 0,
    int geometryEvidenceCount = 0,
    int internalEvidenceCount = 0,
    double evidenceDirectionConsistency = 1,
    bool contourInternalAgree = false,
    bool evidenceConflict = false,
  }) {
    if (![
          magnitude,
          confidence,
          coverage,
          consistency,
          pageContourMagnitude,
          internalLineMagnitude,
          evidenceDirectionConsistency,
        ].every((v) => v.isFinite) ||
        evidenceCount < 2 ||
        coverage < CurvedPagePolicy.minimumEvidenceCoverage ||
        evidenceConflict) {
      return CurvatureState.unreliable;
    }
    final allComponentsFlat =
        magnitude < flatMagnitudeLimit &&
        pageContourMagnitude < flatMagnitudeLimit &&
        internalLineMagnitude < flatMagnitudeLimit;
    if (allComponentsFlat) return CurvatureState.flat;
    final existingMildRule =
        magnitude < mildMagnitudeLimit &&
        confidence >= mildMinimumConfidence &&
        coverage >= mildMinimumCoverage &&
        consistency >= mildMinimumConsistency;
    final geometryMildRule =
        magnitude < mildMagnitudeLimit &&
        pageContourMagnitude >= flatMagnitudeLimit &&
        evidenceDirectionConsistency >= 0.67 &&
        confidence >= 0.50 &&
        consistency >= CurvedPagePolicy.minimumEvidenceConsistency &&
        (geometryEvidenceCount >= 2 ||
            (geometryEvidenceCount >= 1 &&
                internalEvidenceCount >= 1 &&
                contourInternalAgree));
    if (existingMildRule || geometryMildRule) {
      return CurvatureState.mildCurve;
    }
    if (magnitude >= mildMagnitudeLimit &&
        confidence >= CurvedPagePolicy.minimumConfidence) {
      return CurvatureState.strongCurve;
    }
    return CurvatureState.unreliable;
  }
}

/// Separates page-shape evidence from the raster displacement that is safe to
/// apply. Detection thresholds stay in [AutomaticCurvaturePolicy]; this policy
/// only chooses and caps the deformation profile after classification evidence
/// has been collected.
class EffectiveDeformationPolicy {
  const EffectiveDeformationPolicy._();

  static const double contourOnlyMildMaximumFraction = 0.006;

  static double profileMagnitude({
    required double pageContourMagnitude,
    required double internalLineMagnitude,
    required int internalEvidenceCount,
  }) {
    if (internalEvidenceCount > 0 && internalLineMagnitude.isFinite) {
      return internalLineMagnitude.abs();
    }
    if (!pageContourMagnitude.isFinite) return 0;
    return math.min(pageContourMagnitude.abs(), contourOnlyMildMaximumFraction);
  }

  static double effectiveMagnitude({
    required double profileMagnitude,
    required CurvatureState state,
  }) {
    final strength = state == CurvatureState.mildCurve
        ? AutomaticCurvaturePolicy.mildDewarpStrength
        : state == CurvatureState.strongCurve
        ? 1.0
        : 0.0;
    return profileMagnitude.abs() * strength;
  }

  static bool isExcessive(double effectiveMagnitude) =>
      !effectiveMagnitude.isFinite ||
      effectiveMagnitude > CurvedPagePolicy.maximumDeformationFraction;
}

class PhysicalCurvatureDirectionPolicy {
  const PhysicalCurvatureDirectionPolicy._();

  static bool hasConflict({
    required List<int> geometryDirections,
    required List<int> internalDirections,
    int spineDirection = 0,
  }) {
    if (spineDirection < -1 || spineDirection > 1) {
      throw ArgumentError.value(spineDirection, 'spineDirection');
    }
    final geometry = geometryDirections.where((value) => value != 0).toList();
    final internal = internalDirections.where((value) => value != 0).toList();
    if (_withinGroupConflict(geometry) || _withinGroupConflict(internal)) {
      return true;
    }
    if (geometry.length < 2 || internal.length < 2) return false;
    final geometryDirection = _dominant(geometry);
    final internalDirection = _dominant(internal);
    return geometryDirection != 0 &&
        internalDirection != 0 &&
        geometryDirection != internalDirection &&
        _consistency(geometry) >= 0.67 &&
        _consistency(internal) >= 0.67;
  }

  static bool _withinGroupConflict(List<int> directions) {
    if (directions.isEmpty) return false;
    return directions.any((value) => value > 0) &&
        directions.any((value) => value < 0) &&
        _consistency(directions) < 0.67;
  }

  static double _consistency(List<int> directions) {
    if (directions.isEmpty) return 0;
    final positive = directions.where((value) => value > 0).length;
    final negative = directions.where((value) => value < 0).length;
    return math.max(positive, negative) / directions.length;
  }

  static int _dominant(List<int> directions) {
    final positive = directions.where((value) => value > 0).length;
    final negative = directions.where((value) => value < 0).length;
    return positive == negative ? 0 : (positive > negative ? 1 : -1);
  }
}

/// Mirrors the native confidence composition for deterministic regression
/// tests and readable diagnostics.
class CurvedConfidenceComponents {
  const CurvedConfidenceComponents({
    required this.coverage,
    required this.candidateScore,
    required this.consistency,
  });

  final double coverage;
  final double candidateScore;
  final double consistency;

  double get confidence =>
      coverage * 0.45 + candidateScore * 0.30 + consistency * 0.25;

  bool get meetsThreshold => confidence >= CurvedPagePolicy.minimumConfidence;
}

class NormalizedPageRegion {
  const NormalizedPageRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// Shared safety contract for Dart tests and the Android curved-page engine.
class CurvedPagePolicy {
  const CurvedPagePolicy._();

  static const double insetFraction = 0.04;
  static const double visibleBoundaryMarginFraction = 0.015;
  static const double minimumConfidence = 0.68;
  static const double minimumEvidenceCoverage = 0.48;
  static const double minimumEvidenceConsistency = 0.60;
  static const double minimumDeformationFraction = 0.0015;
  static const double maximumDeformationFraction = 0.025;
  static const double maximumAdjacentDifferenceFraction = 0.0025;

  static const Map<String, double> nativeConfiguration = {
    'insetFraction': insetFraction,
    'minimumConfidence': minimumConfidence,
    'minimumEvidenceCoverage': minimumEvidenceCoverage,
    'minimumEvidenceConsistency': minimumEvidenceConsistency,
    'mildMagnitudeLimit': AutomaticCurvaturePolicy.mildMagnitudeLimit,
    'mildMinimumConfidence': AutomaticCurvaturePolicy.mildMinimumConfidence,
    'mildMinimumCoverage': AutomaticCurvaturePolicy.mildMinimumCoverage,
    'mildMinimumConsistency': AutomaticCurvaturePolicy.mildMinimumConsistency,
    'mildDewarpStrength': AutomaticCurvaturePolicy.mildDewarpStrength,
    'minimumDeformationFraction': minimumDeformationFraction,
    'maximumDeformationFraction': maximumDeformationFraction,
    'maximumAdjacentDifferenceFraction': maximumAdjacentDifferenceFraction,
  };

  static PageBoundaryMode selectBoundaryMode({
    required DocumentCorners corners,
    required int? sourceWidth,
    required int? sourceHeight,
  }) {
    if (sourceWidth == null ||
        sourceHeight == null ||
        sourceWidth <= 0 ||
        sourceHeight <= 0) {
      return PageBoundaryMode.insetFallback;
    }
    final horizontalMargin = sourceWidth * visibleBoundaryMarginFraction;
    final verticalMargin = sourceHeight * visibleBoundaryMarginFraction;
    final points = corners.ordered;
    final hasVisibleLeft =
        points[0].x > horizontalMargin && points[3].x > horizontalMargin;
    final hasVisibleRight =
        points[1].x < sourceWidth - horizontalMargin &&
        points[2].x < sourceWidth - horizontalMargin;
    final hasVisibleTop =
        points[0].y > verticalMargin && points[1].y > verticalMargin;
    final hasVisibleBottom =
        points[2].y < sourceHeight - verticalMargin &&
        points[3].y < sourceHeight - verticalMargin;
    return hasVisibleLeft &&
            hasVisibleRight &&
            hasVisibleTop &&
            hasVisibleBottom
        ? PageBoundaryMode.detected
        : PageBoundaryMode.insetFallback;
  }

  static NormalizedPageRegion regionFor(PageBoundaryMode mode) {
    if (mode == PageBoundaryMode.detected) {
      return const NormalizedPageRegion(left: 0, top: 0, right: 1, bottom: 1);
    }
    return const NormalizedPageRegion(
      left: insetFraction,
      top: insetFraction,
      right: 1 - insetFraction,
      bottom: 1 - insetFraction,
    );
  }

  static bool acceptsCurve({
    required List<double> offsets,
    required int imageHeight,
    required double confidence,
  }) {
    if (offsets.length < 3 ||
        imageHeight <= 1 ||
        !confidence.isFinite ||
        confidence < minimumConfidence ||
        offsets.any((value) => !value.isFinite)) {
      return false;
    }
    final maximumOffset = offsets.map((value) => value.abs()).reduce(math.max);
    if (maximumOffset < imageHeight * minimumDeformationFraction ||
        maximumOffset > imageHeight * maximumDeformationFraction) {
      return false;
    }
    final adjacentLimit = imageHeight * maximumAdjacentDifferenceFraction;
    for (var index = 1; index < offsets.length; index++) {
      if ((offsets[index] - offsets[index - 1]).abs() > adjacentLimit) {
        return false;
      }
    }

    for (final offset in offsets) {
      var previous = -1.0;
      for (var sample = 0; sample <= 64; sample++) {
        final y = (imageHeight - 1) * sample / 64;
        final weight = math.sin(math.pi * y / (imageHeight - 1));
        final mappedY = y + offset * weight;
        if (!mappedY.isFinite ||
            mappedY < 0 ||
            mappedY > imageHeight - 1 ||
            mappedY <= previous) {
          return false;
        }
        previous = mappedY;
      }
    }
    return true;
  }
}

class PerspectiveOutputSize {
  const PerspectiveOutputSize(this.width, this.height);

  final int width;
  final int height;
}

class PerspectiveGeometry {
  const PerspectiveGeometry._();

  static PerspectiveOutputSize outputSize(DocumentCorners corners) {
    final topWidth = _distance(corners.topLeft, corners.topRight);
    final bottomWidth = _distance(corners.bottomLeft, corners.bottomRight);
    final leftHeight = _distance(corners.topLeft, corners.bottomLeft);
    final rightHeight = _distance(corners.topRight, corners.bottomRight);
    return PerspectiveOutputSize(
      math.max(topWidth, bottomWidth).round().clamp(1, 1000000),
      math.max(leftHeight, rightHeight).round().clamp(1, 1000000),
    );
  }

  static bool hasValidCornerOrder(DocumentCorners corners) {
    final points = corners.ordered;
    double? direction;
    for (var index = 0; index < points.length; index++) {
      final first = points[index];
      final second = points[(index + 1) % points.length];
      final third = points[(index + 2) % points.length];
      final cross =
          (second.x - first.x) * (third.y - second.y) -
          (second.y - first.y) * (third.x - second.x);
      if (cross.abs() < 0.0001) {
        return false;
      }
      direction ??= cross.sign;
      if (cross.sign != direction) {
        return false;
      }
    }
    return direction == 1;
  }

  static double _distance(DocumentPoint first, DocumentPoint second) {
    final dx = first.x - second.x;
    final dy = first.y - second.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
