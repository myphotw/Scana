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
  final PageCandidateSide pageSide;
  final bool selfIntersects;
}

/// Mirrors the native candidate-selection intent in deterministic Dart tests.
class PageCandidatePolicy {
  const PageCandidatePolicy._();

  static double score(PageCandidateFeatures candidate) {
    if (!isEligible(candidate)) return -1;
    if (candidate.kind == PageCandidateKind.document) {
      return candidate.baseScore * 0.84 +
          candidate.outerBoundaryContinuity * 0.08 +
          candidate.contentContainment * 0.04 +
          candidate.contentEnvelopeContainment * 0.12 -
          candidate.outsideContentContinuation * 0.16;
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
    return candidate.baseScore * 0.34 +
        candidate.spineStrength * 0.18 +
        candidate.spineProximity * 0.14 +
        candidate.textDensity * 0.14 +
        candidate.boundaryCurvature * 0.08 +
        candidate.outerBoundaryContinuity * 0.08 +
        candidate.contentContainment * 0.05 +
        candidate.contentEnvelopeContainment * 0.13 +
        candidate.outerEdgeAnchor * 0.20 -
        candidate.outsideContentContinuation * 0.20 -
        candidate.overlapExpansion * 0.22 +
        0.06;
  }

  static bool isEligible(PageCandidateFeatures candidate) {
    if (candidate.selfIntersects ||
        candidate.contentContainment < 0.72 ||
        candidate.contentEnvelopeContainment < 0.80) {
      return false;
    }
    final maximumContinuation = candidate.kind == PageCandidateKind.bookPage
        ? 0.42
        : 0.58;
    return candidate.outsideContentContinuation < maximumContinuation;
  }

  static PageCandidateFeatures select(List<PageCandidateFeatures> candidates) {
    return candidates.reduce(
      (best, candidate) => score(candidate) > score(best) ? candidate : best,
    );
  }
}
