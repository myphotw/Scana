import 'dart:math' as math;

import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';

/// Testable mirror of the native AI refinement acceptance contract.
///
/// Native OpenCV owns pixel analysis; this policy documents and verifies the
/// geometry, ownership, expansion, containment, and fallback limits in Dart.
class AiBoundaryRefinementPolicy {
  const AiBoundaryRefinementPolicy._();

  static const horizontalSearchExpansion = 0.10;
  static const verticalSearchExpansion = 0.14;
  static const minimumSearchExpansion = 0.02;
  static const minimumPaperContainment = 0.82;
  static const maximumPaperExpansion = 1.85;
  static const minimumPaperExpansion = 0.90;
  static const minimumPaperScore = 0.56;
  static const minimumRefinedAreaRatio = 0.96;
  static const maximumRefinedAreaRatio = 1.55;
  static const minimumRefinedContainment = 0.94;
  static const minimumTransitionScore = 0.18;
  static const outwardLimit = 0.10;
  static const spineOutwardLimit = 0.055;
  static const minimumMainPageOwnership = 0.66;
  static const maximumAdjacentPagePenalty = 0.66;
  static const conservativeConfidenceThreshold = 0.58;

  static double outwardLimitFor({
    required String? pageSide,
    required AiBoundaryEdge edge,
  }) {
    final spineEdge =
        (pageSide == 'left' && edge == AiBoundaryEdge.right) ||
        (pageSide == 'right' && edge == AiBoundaryEdge.left);
    return spineEdge ? spineOutwardLimit : outwardLimit;
  }

  static DocumentCorners effectiveCorners({
    required DocumentCorners roughCorners,
    required DocumentCorners? refinedCorners,
    required AiRefinementDecision decision,
  }) => decision.accepted && refinedCorners != null
      ? refinedCorners
      : roughCorners;

  static AiSearchRoi expandSearchRoi({
    required DocumentCorners roughCorners,
    required int sourceWidth,
    required int sourceHeight,
  }) {
    final points = roughCorners.ordered;
    final left = points.map((point) => point.x).reduce(math.min);
    final top = points.map((point) => point.y).reduce(math.min);
    final right = points.map((point) => point.x).reduce(math.max);
    final bottom = points.map((point) => point.y).reduce(math.max);
    final expandX = math.max(
      (right - left) * horizontalSearchExpansion,
      sourceWidth * minimumSearchExpansion,
    );
    final expandY = math.max(
      (bottom - top) * verticalSearchExpansion,
      sourceHeight * minimumSearchExpansion,
    );
    return AiSearchRoi(
      left: (left - expandX).clamp(0, sourceWidth).toDouble(),
      top: (top - expandY).clamp(0, sourceHeight).toDouble(),
      right: (right + expandX).clamp(0, sourceWidth).toDouble(),
      bottom: (bottom + expandY).clamp(0, sourceHeight).toDouble(),
    );
  }

  static double? paperCandidateScore({
    required double aiContainment,
    required double areaExpansion,
    required double transitionScore,
    required bool ownsAiCentroid,
  }) {
    if (!ownsAiCentroid ||
        aiContainment < minimumPaperContainment ||
        areaExpansion < minimumPaperExpansion ||
        areaExpansion > maximumPaperExpansion) {
      return null;
    }
    final expansionScore = (1 - (areaExpansion - 1.16).abs() / 0.75).clamp(
      0.0,
      1.0,
    );
    return aiContainment.clamp(0.0, 1.0) * 0.52 +
        expansionScore * 0.20 +
        transitionScore.clamp(0.0, 1.0) * 0.28;
  }

  static AiRefinementDecision validate({
    required DocumentCorners roughCorners,
    required DocumentCorners? refinedCorners,
    required int sourceWidth,
    required int sourceHeight,
    required double aiContainment,
    required double transitionScore,
    required int reliableEdges,
    double? paperCandidateScore,
    double mainPageOwnership = 1,
    double adjacentPagePenalty = 0,
    bool partialRaw = false,
  }) {
    if (partialRaw) {
      return const AiRefinementDecision.rejected('partial_ai_raw');
    }
    if (refinedCorners == null) {
      return const AiRefinementDecision.rejected('refined_corners_unavailable');
    }
    if (!_insideSource(refinedCorners, sourceWidth, sourceHeight)) {
      return const AiRefinementDecision.rejected(
        'refined_corners_out_of_bounds',
      );
    }
    if (!_isConvex(refinedCorners.ordered)) {
      return const AiRefinementDecision.rejected('refined_boundary_not_convex');
    }
    final rawArea = _area(roughCorners.ordered);
    final refinedArea = _area(refinedCorners.ordered);
    final expansion = rawArea <= 0 ? double.infinity : refinedArea / rawArea;
    if (expansion < minimumRefinedAreaRatio) {
      return AiRefinementDecision.rejected(
        'excessive_inward_refinement',
        areaExpansionRatio: expansion,
      );
    }
    if (expansion > maximumRefinedAreaRatio) {
      return AiRefinementDecision.rejected(
        'excessive_refinement_expansion',
        areaExpansionRatio: expansion,
      );
    }
    if (aiContainment < minimumRefinedContainment) {
      return AiRefinementDecision.rejected(
        'ai_foreground_clipped',
        areaExpansionRatio: expansion,
      );
    }
    if (mainPageOwnership < minimumMainPageOwnership) {
      return AiRefinementDecision.rejected(
        'main_page_ownership_lost',
        areaExpansionRatio: expansion,
      );
    }
    if (adjacentPagePenalty >= maximumAdjacentPagePenalty) {
      return AiRefinementDecision.rejected(
        'adjacent_page_merge',
        areaExpansionRatio: expansion,
      );
    }
    final hasPaperCandidate =
        paperCandidateScore != null && paperCandidateScore >= minimumPaperScore;
    if (reliableEdges < 2 && !hasPaperCandidate) {
      return AiRefinementDecision.rejected(
        'paper_transition_unreliable',
        areaExpansionRatio: expansion,
      );
    }
    if (transitionScore < minimumTransitionScore && !hasPaperCandidate) {
      return AiRefinementDecision.rejected(
        'paper_transition_weak',
        areaExpansionRatio: expansion,
      );
    }
    return AiRefinementDecision.accepted(areaExpansionRatio: expansion);
  }

  static DocumentCorners conservativeCornersFromContour(
    List<DocumentPoint> contour,
  ) {
    if (contour.length < 4) {
      throw ArgumentError.value(contour.length, 'contour', 'needs 4 points');
    }
    final left = contour.map((point) => point.x).reduce(math.min);
    final top = contour.map((point) => point.y).reduce(math.min);
    final right = contour.map((point) => point.x).reduce(math.max);
    final bottom = contour.map((point) => point.y).reduce(math.max);
    // The outer envelope is intentionally conservative: a curved top/bottom
    // between its fitted corner samples must not be clipped by the crop line.
    return DocumentCorners(
      topLeft: DocumentPoint(left, top),
      topRight: DocumentPoint(right, top),
      bottomRight: DocumentPoint(right, bottom),
      bottomLeft: DocumentPoint(left, bottom),
    );
  }

  static bool expandsEdge(
    DocumentCorners rough,
    DocumentCorners refined,
    AiBoundaryEdge edge,
  ) {
    final raw = _bounds(rough.ordered);
    final next = _bounds(refined.ordered);
    return switch (edge) {
      AiBoundaryEdge.top => next.$2 < raw.$2,
      AiBoundaryEdge.right => next.$3 > raw.$3,
      AiBoundaryEdge.bottom => next.$4 > raw.$4,
      AiBoundaryEdge.left => next.$1 < raw.$1,
    };
  }

  /// Rejects masks that look like an internal text/table rectangle rather
  /// than a page-sized object. The thresholds deliberately only reject a
  /// conjunction of weak extents so genuinely small documents remain valid.
  static bool isPartialRaw({
    required double rawAreaRatio,
    required double horizontalExtent,
    required double verticalExtent,
    required bool coversPageCenter,
    required double bottomProximity,
    required bool largeInternalRectangle,
    required String? pageSide,
  }) {
    final severeExtent = horizontalExtent < 0.28 || verticalExtent < 0.34;
    final detachedInternalRegion =
        largeInternalRectangle &&
        horizontalExtent < (pageSide == null ? 0.72 : 0.64) &&
        verticalExtent < 0.70 &&
        bottomProximity < 0.78;
    final tinyOffCenter =
        rawAreaRatio < 0.045 && !coversPageCenter && verticalExtent < 0.52;
    return severeExtent || detachedInternalRegion || tinyOffCenter;
  }

  static AiEdgeExpansionDecision edgeExpansion({
    required double requestedRatio,
    required double transition,
    required double continuity,
    required double ownership,
    required double adjacentPenalty,
    required double occlusionPenalty,
    required bool spineEdge,
  }) {
    final maximum = spineEdge ? spineOutwardLimit : outwardLimit;
    final transitionFactor = ((transition - 0.18) / 0.34).clamp(0.0, 1.0);
    final ownershipFactor =
        ((ownership - minimumMainPageOwnership) /
                (1 - minimumMainPageOwnership))
            .clamp(0.0, 1.0);
    final safety =
        transitionFactor * 0.42 +
        continuity.clamp(0.0, 1.0) * 0.18 +
        ownershipFactor * 0.20 +
        (1 - adjacentPenalty.clamp(0.0, 1.0)) * 0.14 +
        (1 - occlusionPenalty.clamp(0.0, 1.0)) * 0.06;
    final allowed = maximum * safety.clamp(0.0, 1.0);
    final applied = requestedRatio.clamp(0.0, allowed).toDouble();
    return AiEdgeExpansionDecision(
      requestedRatio: requestedRatio,
      appliedRatio: applied,
      conservative: applied + 1e-9 < requestedRatio,
      reliable:
          transition >= minimumTransitionScore &&
          ownership >= minimumMainPageOwnership &&
          adjacentPenalty < maximumAdjacentPagePenalty &&
          occlusionPenalty <=
              AiBoundaryStabilizationPolicy.maximumAcceptedOcclusion,
    );
  }

  static bool _insideSource(DocumentCorners corners, int width, int height) =>
      corners.ordered.every(
        (point) =>
            point.x.isFinite &&
            point.y.isFinite &&
            point.x >= 0 &&
            point.y >= 0 &&
            point.x <= width &&
            point.y <= height,
      );

  static bool _isConvex(List<DocumentPoint> points) {
    double? sign;
    for (var index = 0; index < points.length; index++) {
      final a = points[index];
      final b = points[(index + 1) % points.length];
      final c = points[(index + 2) % points.length];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (cross.abs() < 1e-9) continue;
      final current = cross.sign;
      sign ??= current;
      if (sign != current) return false;
    }
    return sign != null;
  }

  static double _area(List<DocumentPoint> points) {
    var result = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      result += points[index].x * next.y - next.x * points[index].y;
    }
    return result.abs() / 2;
  }

  static (double, double, double, double) _bounds(List<DocumentPoint> points) =>
      (
        points.map((point) => point.x).reduce(math.min),
        points.map((point) => point.y).reduce(math.min),
        points.map((point) => point.x).reduce(math.max),
        points.map((point) => point.y).reduce(math.max),
      );
}

enum AiBoundaryEdge { top, right, bottom, left }

class AiRefinementDecision {
  const AiRefinementDecision.accepted({required this.areaExpansionRatio})
    : accepted = true,
      rejectionReason = null;

  const AiRefinementDecision.rejected(
    this.rejectionReason, {
    this.areaExpansionRatio = 1,
  }) : accepted = false;

  final bool accepted;
  final String? rejectionReason;
  final double areaExpansionRatio;
}

class AiEdgeExpansionDecision {
  const AiEdgeExpansionDecision({
    required this.requestedRatio,
    required this.appliedRatio,
    required this.conservative,
    required this.reliable,
  });

  final double requestedRatio;
  final double appliedRatio;
  final bool conservative;
  final bool reliable;
}

class AiBoundaryStabilizationPolicy {
  const AiBoundaryStabilizationPolicy._();

  static const minimumOwnership = 0.66;
  static const adjacentRejectionPenalty = 0.66;
  static const maximumAcceptedOcclusion = 0.48;

  static double mainPageOwnership({
    required double aiContainment,
    required double centroidProximity,
    required double componentIntersection,
  }) =>
      aiContainment.clamp(0.0, 1.0) * 0.55 +
      centroidProximity.clamp(0.0, 1.0) * 0.25 +
      componentIntersection.clamp(0.0, 1.0) * 0.20;

  static double adjacentPagePenalty({
    required double areaExpansion,
    required double spineOvershoot,
    required double narrowConnectionPenalty,
  }) {
    final growth = ((areaExpansion - 1.24) / 0.34).clamp(0.0, 1.0);
    final overshoot = (spineOvershoot / 0.12).clamp(0.0, 1.0);
    return (growth * 0.42 +
            overshoot * 0.38 +
            narrowConnectionPenalty.clamp(0.0, 1.0) * 0.20)
        .clamp(0.0, 1.0);
  }

  static int? narrowConnectionIndex(List<double> occupancy) {
    if (occupancy.length < 8) return null;
    final trim = math.max(1, (occupancy.length * 0.12).round());
    final core = occupancy.sublist(trim, occupancy.length - trim);
    final reference = _percentile(core, 0.75);
    if (reference <= 0) return null;
    var index = 0;
    var minimum = double.infinity;
    for (
      var candidate = trim;
      candidate < occupancy.length - trim;
      candidate++
    ) {
      if (occupancy[candidate] < minimum) {
        minimum = occupancy[candidate];
        index = candidate;
      }
    }
    return minimum / reference <= 0.42 ? index : null;
  }

  static double robustOuterOffset(List<double> offsets) {
    final outward = offsets.where((value) => value >= 0).toList();
    return outward.isEmpty ? 0 : _percentile(outward, 0.88);
  }

  static RobustEdgeFit robustEdgeFit({
    required List<double> offsets,
    required List<double> colorDistances,
  }) {
    if (offsets.isEmpty || offsets.length != colorDistances.length) {
      return const RobustEdgeFit(
        offset: 0,
        continuity: 0,
        occlusionPenalty: 1,
        inlierCount: 0,
      );
    }
    final offsetMedian = _percentile(offsets, 0.5);
    final offsetMad = _percentile(
      offsets.map((value) => (value - offsetMedian).abs()).toList(),
      0.5,
    ).clamp(0.5, double.infinity);
    final colorMedian = _percentile(colorDistances, 0.5);
    final colorMad = _percentile(
      colorDistances.map((value) => (value - colorMedian).abs()).toList(),
      0.5,
    ).clamp(1.0, double.infinity);
    final inliers = <int>[];
    for (var index = 0; index < offsets.length; index++) {
      if ((offsets[index] - offsetMedian).abs() <= offsetMad * 2.8 &&
          colorDistances[index] <= colorMedian + colorMad * 2.8) {
        inliers.add(index);
      }
    }
    final retained = inliers.map((index) => offsets[index]).toList()..sort();
    final robustOffset = retained.isEmpty ? 0.0 : _trimmedMean(retained, 0.18);
    var jumps = 0;
    for (var index = 1; index < inliers.length; index++) {
      if ((offsets[inliers[index]] - offsets[inliers[index - 1]]).abs() >
          math.max(3.0, offsetMad * 3)) {
        jumps++;
      }
    }
    final outlierRatio = 1 - inliers.length / offsets.length;
    final discontinuity = inliers.length < 2
        ? 1.0
        : jumps / (inliers.length - 1);
    return RobustEdgeFit(
      offset: math.max(0, robustOffset),
      continuity: (1 - discontinuity).clamp(0.0, 1.0),
      occlusionPenalty: (outlierRatio * 0.70 + discontinuity * 0.30).clamp(
        0.0,
        1.0,
      ),
      inlierCount: inliers.length,
    );
  }

  static double recoverBottomOffset({
    required RobustEdgeFit bottom,
    required double rawOffset,
    double? envelopeOffset,
  }) {
    if (bottom.occlusionPenalty <= maximumAcceptedOcclusion) {
      return math.max(rawOffset, bottom.offset);
    }
    return math.max(rawOffset, envelopeOffset ?? rawOffset);
  }

  static bool spreadGeometrySupported({
    required String pageSide,
    required Map<AiBoundaryEdge, bool> reliableEdges,
  }) {
    final outer = pageSide == 'left'
        ? AiBoundaryEdge.left
        : AiBoundaryEdge.right;
    final topOrBottom =
        (reliableEdges[AiBoundaryEdge.top] ?? false) ||
        (reliableEdges[AiBoundaryEdge.bottom] ?? false);
    return (reliableEdges[outer] ?? false) && topOrBottom;
  }

  static double refinedConfidence({
    required double containment,
    required double expansion,
    required double transition,
    required double envelopeConsistency,
    required double edgeContinuity,
    required double adjacentPenalty,
    required double occlusionPenalty,
    required bool geometrySane,
  }) {
    final expansionScore = (1 - (expansion - 1.16).abs() / 0.55).clamp(
      0.0,
      1.0,
    );
    return (containment.clamp(0.0, 1.0) * 0.24 +
            expansionScore * 0.13 +
            transition.clamp(0.0, 1.0) * 0.14 +
            envelopeConsistency.clamp(0.0, 1.0) * 0.14 +
            edgeContinuity.clamp(0.0, 1.0) * 0.13 +
            (geometrySane ? 0.12 : 0) -
            adjacentPenalty.clamp(0.0, 1.0) * 0.18 -
            occlusionPenalty.clamp(0.0, 1.0) * 0.12)
        .clamp(0.0, 1.0);
  }

  static AiRefinedBoundaryStatus statusFor({
    required bool accepted,
    required String? rejectionReason,
    required double occlusionPenalty,
    double refinedConfidence = 1,
    bool conservativeExpansion = false,
  }) {
    if (accepted) {
      if (conservativeExpansion ||
          refinedConfidence <
              AiBoundaryRefinementPolicy.conservativeConfidenceThreshold) {
        return AiRefinedBoundaryStatus.acceptedConservative;
      }
      return occlusionPenalty >= 0.16
          ? AiRefinedBoundaryStatus.acceptedOcclusionRecovered
          : AiRefinedBoundaryStatus.accepted;
    }
    return switch (rejectionReason) {
      'partial_ai_raw' => AiRefinedBoundaryStatus.rejectedPartialRaw,
      'adjacent_page_merge' || 'main_page_ownership_lost' =>
        AiRefinedBoundaryStatus.rejectedAdjacentPage,
      'occlusion_unresolved' => AiRefinedBoundaryStatus.rejectedOcclusion,
      'excessive_refinement_expansion' =>
        AiRefinedBoundaryStatus.rejectedExpansion,
      'excessive_inward_refinement' => AiRefinedBoundaryStatus.rejectedShrink,
      'ai_foreground_clipped' =>
        AiRefinedBoundaryStatus.rejectedForegroundClipped,
      'refined_boundary_not_convex' || 'refined_corners_out_of_bounds' =>
        AiRefinedBoundaryStatus.rejectedGeometry,
      _ => AiRefinedBoundaryStatus.rawFallback,
    };
  }

  static double _percentile(List<double> values, double fraction) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final position = fraction.clamp(0.0, 1.0) * (sorted.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    return sorted[lower] * (upper - position) +
        sorted[upper] * (position - lower);
  }

  static double _trimmedMean(List<double> sorted, double fraction) {
    final trim = (sorted.length * fraction).floor();
    final retained = sorted.sublist(trim, sorted.length - trim);
    return retained.isEmpty
        ? _percentile(sorted, 0.5)
        : retained.reduce((a, b) => a + b) / retained.length;
  }
}

class RobustEdgeFit {
  const RobustEdgeFit({
    required this.offset,
    required this.continuity,
    required this.occlusionPenalty,
    required this.inlierCount,
  });

  final double offset;
  final double continuity;
  final double occlusionPenalty;
  final int inlierCount;
}
