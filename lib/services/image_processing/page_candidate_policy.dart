enum PageCandidateKind { document, bookPage, openBookSpread }

enum PageCandidateSide { single, left, right }

class PageCandidateFeatures {
  const PageCandidateFeatures({
    required this.kind,
    required this.baseScore,
    required this.areaRatio,
    required this.aspectRatio,
    required this.spineStrength,
    required this.spineProximity,
    required this.textDensity,
    required this.boundaryCurvature,
    this.twoPageStructure = 0,
    this.outerBoundaryContinuity = 1,
    this.contentContainment = 1,
    this.outsideContentContinuation = 0,
    this.contentEnvelopeContainment = 1,
    this.topContinuity = 0,
    this.bottomContinuity = 0,
    this.outerEdgeAnchor = 0,
    this.overlapExpansion = 0,
    this.occupancy = 1,
    this.borderProximity = 1,
    this.insideOutsideContrast = 1,
    this.paperInterior = 1,
    this.rectangularity = 1,
    this.edgeContinuity = 1,
    this.internalLinePenalty = 0,
    this.smallCandidatePenalty = 0,
    this.widthRatio = 1,
    this.heightRatio = 1,
    this.pageSide = PageCandidateSide.single,
    this.selfIntersects = false,
  });

  final PageCandidateKind kind;
  final double baseScore;
  final double areaRatio;
  final double aspectRatio;
  final double spineStrength;
  final double spineProximity;
  final double textDensity;
  final double boundaryCurvature;
  final double twoPageStructure;
  final double outerBoundaryContinuity;
  final double contentContainment;
  final double outsideContentContinuation;
  final double contentEnvelopeContainment;
  final double topContinuity;
  final double bottomContinuity;
  final double outerEdgeAnchor;
  final double overlapExpansion;
  final double occupancy;
  final double borderProximity;
  final double insideOutsideContrast;
  final double paperInterior;
  final double rectangularity;
  final double edgeContinuity;
  final double internalLinePenalty;
  final double smallCandidatePenalty;
  final double widthRatio;
  final double heightRatio;
  final PageCandidateSide pageSide;
  final bool selfIntersects;
}

/// Mirrors the native candidate-selection intent in deterministic Dart tests.
class PageCandidatePolicy {
  const PageCandidatePolicy._();

  static double score(PageCandidateFeatures candidate) {
    if (!isEligible(candidate)) return -1;
    if (candidate.kind == PageCandidateKind.document) {
      return candidate.baseScore * 0.08 +
          candidate.occupancy * 0.24 +
          candidate.borderProximity * 0.16 +
          candidate.insideOutsideContrast * 0.14 +
          candidate.paperInterior * 0.14 +
          candidate.rectangularity * 0.08 +
          candidate.edgeContinuity * 0.08 +
          candidate.contentEnvelopeContainment * 0.08 -
          candidate.internalLinePenalty * 0.28 -
          candidate.smallCandidatePenalty * 0.22 -
          candidate.outsideContentContinuation * 0.10;
    }
    if (candidate.kind == PageCandidateKind.openBookSpread) {
      final hasCentralSpine =
          candidate.spineStrength >= 0.35 && candidate.spineProximity >= 0.7;
      final looksLikeSpread =
          candidate.aspectRatio >= 1.15 &&
          candidate.areaRatio >= 0.45 &&
          candidate.twoPageStructure >= 0.35;
      return candidate.baseScore -
          (hasCentralSpine && looksLikeSpread ? 0.24 : 0);
    }
    final bookStructure =
        (candidate.spineStrength +
            candidate.spineProximity +
            candidate.textDensity) /
        3;
    final weakUnownedPagePenalty =
        candidate.pageSide == PageCandidateSide.single
        ? (1 - bookStructure) * 0.15
        : 0.0;
    return candidate.baseScore * 0.05 +
        candidate.occupancy * 0.22 +
        candidate.borderProximity * 0.16 +
        candidate.insideOutsideContrast * 0.11 +
        candidate.paperInterior * 0.13 +
        candidate.rectangularity * 0.06 +
        candidate.edgeContinuity * 0.10 +
        candidate.outerEdgeAnchor * 0.11 +
        candidate.contentEnvelopeContainment * 0.06 +
        candidate.spineStrength * 0.05 +
        candidate.spineProximity * 0.04 +
        candidate.textDensity * 0.04 +
        candidate.boundaryCurvature * 0.02 -
        candidate.internalLinePenalty * 0.28 -
        candidate.smallCandidatePenalty * 0.22 -
        candidate.outsideContentContinuation * 0.10 -
        candidate.overlapExpansion * 0.20 -
        weakUnownedPagePenalty;
  }

  static bool isEligible(PageCandidateFeatures candidate) {
    final minimumWidth = candidate.kind == PageCandidateKind.bookPage
        ? 0.42
        : 0.46;
    if (candidate.selfIntersects ||
        candidate.widthRatio < minimumWidth ||
        candidate.heightRatio < 0.48 ||
        candidate.contentContainment < 0.72 ||
        candidate.contentEnvelopeContainment < 0.80) {
      return false;
    }
    final maximumContinuation = candidate.kind == PageCandidateKind.bookPage
        ? 0.42
        : 0.58;
    final minimumArea = candidate.kind == PageCandidateKind.bookPage
        ? 0.24
        : 0.14;
    return candidate.areaRatio >= minimumArea &&
        candidate.outsideContentContinuation < maximumContinuation &&
        candidate.internalLinePenalty < 0.82;
  }

  /// Confidence represents page-boundary evidence, not merely ranking score.
  static double confidence(PageCandidateFeatures candidate) {
    if (!isEligible(candidate)) return 0;
    final evidence =
        candidate.occupancy * 0.23 +
        candidate.borderProximity * 0.15 +
        candidate.insideOutsideContrast * 0.17 +
        candidate.paperInterior * 0.16 +
        candidate.rectangularity * 0.10 +
        candidate.edgeContinuity * 0.19 -
        candidate.internalLinePenalty * 0.24 -
        candidate.smallCandidatePenalty * 0.18;
    return evidence.clamp(0.0, 1.0);
  }

  static PageCandidateFeatures select(List<PageCandidateFeatures> candidates) {
    return candidates.reduce(
      (best, candidate) => score(candidate) > score(best) ? candidate : best,
    );
  }
}
