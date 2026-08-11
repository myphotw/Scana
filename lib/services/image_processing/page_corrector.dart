import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';

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
      throw PageCorrectionFailure(switch (error.code) {
        'curve_nearly_flat' => CorrectionOutcome.nearlyFlat,
        'curve_unsafe' => CorrectionOutcome.unsafeDeformation,
        'curve_not_improved' => CorrectionOutcome.notImproved,
        _ => CorrectionOutcome.lowConfidence,
      }, error.message);
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
    );
  }
}

class PageCorrectionFailure implements Exception {
  const PageCorrectionFailure(this.outcome, [this.message]);

  final CorrectionOutcome outcome;
  final String? message;
}

class CurvedResultQuality {
  const CurvedResultQuality._();

  static bool shouldAdopt({
    required double perspectiveStraightness,
    required double curvedStraightness,
    required double maximumStretchFraction,
  }) =>
      perspectiveStraightness.isFinite &&
      curvedStraightness.isFinite &&
      maximumStretchFraction.isFinite &&
      maximumStretchFraction <= 0.025 &&
      curvedStraightness >= perspectiveStraightness * 0.92;
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
  static const double minimumDeformationFraction = 0.0015;
  static const double maximumDeformationFraction = 0.025;
  static const double maximumAdjacentDifferenceFraction = 0.0025;

  static const Map<String, double> nativeConfiguration = {
    'insetFraction': insetFraction,
    'minimumConfidence': minimumConfidence,
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
