import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/services/image_processing/ai_boundary_refinement.dart';

void main() {
  const raw = DocumentCorners(
    topLeft: DocumentPoint(100, 100),
    topRight: DocumentPoint(900, 100),
    bottomRight: DocumentPoint(900, 1400),
    bottomLeft: DocumentPoint(100, 1400),
  );
  const outward = DocumentCorners(
    topLeft: DocumentPoint(80, 80),
    topRight: DocumentPoint(920, 80),
    bottomRight: DocumentPoint(920, 1420),
    bottomLeft: DocumentPoint(80, 1420),
  );

  test('AI raw bbox expands by responsive ratios', () {
    final roi = AiBoundaryRefinementPolicy.expandSearchRoi(
      roughCorners: raw,
      sourceWidth: 1200,
      sourceHeight: 1600,
    );
    expect(roi.left, 20);
    expect(roi.right, 980);
    expect(roi.top, 0);
    expect(roi.bottom, 1582);
  });

  test('search ROI is clamped to source bounds', () {
    final roi = AiBoundaryRefinementPolicy.expandSearchRoi(
      roughCorners: const DocumentCorners(
        topLeft: DocumentPoint(2, 3),
        topRight: DocumentPoint(998, 3),
        bottomRight: DocumentPoint(998, 1498),
        bottomLeft: DocumentPoint(2, 1498),
      ),
      sourceWidth: 1000,
      sourceHeight: 1500,
    );
    expect(roi.left, 0);
    expect(roi.top, 0);
    expect(roi.right, 1000);
    expect(roi.bottom, 1500);
  });

  test('paper candidate is created from ownership, overlap and transition', () {
    final score = AiBoundaryRefinementPolicy.paperCandidateScore(
      aiContainment: 0.97,
      areaExpansion: 1.16,
      transitionScore: 0.8,
      ownsAiCentroid: true,
    );
    expect(score, isNotNull);
    expect(score!, greaterThan(AiBoundaryRefinementPolicy.minimumPaperScore));
  });

  test('AI overlap contributes strongly to paper candidate score', () {
    final high = AiBoundaryRefinementPolicy.paperCandidateScore(
      aiContainment: 0.98,
      areaExpansion: 1.15,
      transitionScore: 0.6,
      ownsAiCentroid: true,
    )!;
    final low = AiBoundaryRefinementPolicy.paperCandidateScore(
      aiContainment: 0.83,
      areaExpansion: 1.15,
      transitionScore: 0.6,
      ownsAiCentroid: true,
    )!;
    expect(high, greaterThan(low));
  });

  test('nearby unrelated paper without main-page ownership is rejected', () {
    expect(
      AiBoundaryRefinementPolicy.paperCandidateScore(
        aiContainment: 0.95,
        areaExpansion: 1.2,
        transitionScore: 0.9,
        ownsAiCentroid: false,
      ),
      isNull,
    );
  });

  test('adjacent-page merge with excessive area is rejected', () {
    expect(
      AiBoundaryRefinementPolicy.paperCandidateScore(
        aiContainment: 1,
        areaExpansion: 2.1,
        transitionScore: 0.9,
        ownsAiCentroid: true,
      ),
      isNull,
    );
  });

  test('outward refinement with paper evidence is accepted', () {
    final decision = _validate(raw, outward);
    expect(decision.accepted, isTrue);
    expect(decision.areaExpansionRatio, greaterThan(1));
  });

  test('excessive inward refinement is rejected', () {
    final decision = _validate(
      raw,
      const DocumentCorners(
        topLeft: DocumentPoint(180, 180),
        topRight: DocumentPoint(820, 180),
        bottomRight: DocumentPoint(820, 1320),
        bottomLeft: DocumentPoint(180, 1320),
      ),
    );
    expect(decision.rejectionReason, 'excessive_inward_refinement');
  });

  test('excessive expansion is rejected', () {
    final decision = _validate(
      raw,
      const DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(1200, 0),
        bottomRight: DocumentPoint(1200, 1600),
        bottomLeft: DocumentPoint(0, 1600),
      ),
      width: 1200,
      height: 1600,
    );
    expect(decision.rejectionReason, 'excessive_refinement_expansion');
  });

  test('refined boundary must contain AI foreground', () {
    final decision = AiBoundaryRefinementPolicy.validate(
      roughCorners: raw,
      refinedCorners: outward,
      sourceWidth: 1200,
      sourceHeight: 1600,
      aiContainment: 0.8,
      transitionScore: 0.8,
      reliableEdges: 4,
    );
    expect(decision.rejectionReason, 'ai_foreground_clipped');
  });

  for (final edge in AiBoundaryEdge.values) {
    test('${edge.name} edge refines outward', () {
      expect(
        AiBoundaryRefinementPolicy.expandsEdge(raw, outward, edge),
        isTrue,
      );
    });
  }

  test('self-intersecting corner ordering is rejected', () {
    final decision = _validate(
      raw,
      const DocumentCorners(
        topLeft: DocumentPoint(80, 80),
        topRight: DocumentPoint(920, 1420),
        bottomRight: DocumentPoint(920, 80),
        bottomLeft: DocumentPoint(80, 1420),
      ),
    );
    expect(decision.rejectionReason, 'refined_boundary_not_convex');
  });

  test('curved outer contour produces conservative four corners', () {
    final corners =
        AiBoundaryRefinementPolicy.conservativeCornersFromContour(const [
          DocumentPoint(80, 110),
          DocumentPoint(300, 80),
          DocumentPoint(700, 82),
          DocumentPoint(920, 115),
          DocumentPoint(925, 1400),
          DocumentPoint(500, 1430),
          DocumentPoint(75, 1395),
        ]);
    expect(corners.topLeft.x, 75);
    expect(corners.topRight.x, 925);
    expect(corners.bottomRight.y, 1430);
    expect(corners.bottomLeft.x, 75);
  });

  test('refinement failure falls back to AI raw boundary', () {
    const decision = AiRefinementDecision.rejected('paper_transition_weak');
    final effective = AiBoundaryRefinementPolicy.effectiveCorners(
      roughCorners: raw,
      refinedCorners: outward,
      decision: decision,
    );
    expect(effective, same(raw));
  });

  test('Single uses the unrestricted outward edge policy', () {
    for (final edge in AiBoundaryEdge.values) {
      expect(
        AiBoundaryRefinementPolicy.outwardLimitFor(pageSide: null, edge: edge),
        AiBoundaryRefinementPolicy.outwardLimit,
      );
    }
  });

  test('Spread left limits only the right spine edge', () {
    expect(
      AiBoundaryRefinementPolicy.outwardLimitFor(
        pageSide: 'left',
        edge: AiBoundaryEdge.right,
      ),
      AiBoundaryRefinementPolicy.spineOutwardLimit,
    );
    expect(
      AiBoundaryRefinementPolicy.outwardLimitFor(
        pageSide: 'left',
        edge: AiBoundaryEdge.left,
      ),
      AiBoundaryRefinementPolicy.outwardLimit,
    );
  });

  test('Spread right limits only the left spine edge', () {
    expect(
      AiBoundaryRefinementPolicy.outwardLimitFor(
        pageSide: 'right',
        edge: AiBoundaryEdge.left,
      ),
      AiBoundaryRefinementPolicy.spineOutwardLimit,
    );
    expect(
      AiBoundaryRefinementPolicy.outwardLimitFor(
        pageSide: 'right',
        edge: AiBoundaryEdge.right,
      ),
      AiBoundaryRefinementPolicy.outwardLimit,
    );
  });

  test('DEBUG refined artifact path remains session-relative', () {
    final result = AiDocumentSegmentationResult.fromJson({
      ..._metadata,
      'debugAiRefinedOverlayFile': 'debug_ai/raw_ai_refined_overlay.jpg',
      'debugSearchRoiFile': 'debug_ai/raw_ai_search_roi.jpg',
    })!;
    expect(
      result.debugArtifactFiles,
      contains('debug_ai/raw_ai_refined_overlay.jpg'),
    );
    expect(result.toJson().toString(), isNot(contains('C:/')));
  });

  test('refinement timing and quality metadata survive serialization', () {
    final result = AiDocumentSegmentationResult.fromJson(_metadata)!;
    expect(result.totalRefineMs, 71);
    expect(result.maskToSearchRoiMs, 3);
    expect(result.paperCandidateMs, 28);
    expect(result.edgeRefineMs, 31);
    expect(result.cornerEstimateMs, 9);
    expect(result.hasUsableRefinedBoundary, isTrue);
    expect(result.areaExpansionRatio, 1.12);
    expect(result.toJson()['aiContainmentRatio'], 0.98);
  });

  test('older AI-PoC 1 metadata falls back without refinement', () {
    final result = AiDocumentSegmentationResult.fromJson({
      ..._metadata,
      'refinementAttempted': false,
      'refinementAccepted': false,
      'refinedCorners': null,
    })!;
    expect(result.hasUsableBoundary, isTrue);
    expect(result.hasUsableRefinedBoundary, isFalse);
  });

  test(
    'partial content rectangle is rejected while a small page may remain',
    () {
      expect(
        AiBoundaryRefinementPolicy.isPartialRaw(
          rawAreaRatio: 0.18,
          horizontalExtent: 0.5,
          verticalExtent: 0.55,
          coversPageCenter: true,
          bottomProximity: 0.68,
          largeInternalRectangle: true,
          pageSide: null,
        ),
        isTrue,
      );
      expect(
        AiBoundaryRefinementPolicy.isPartialRaw(
          rawAreaRatio: 0.18,
          horizontalExtent: 0.5,
          verticalExtent: 0.55,
          coversPageCenter: true,
          bottomProximity: 0.88,
          largeInternalRectangle: false,
          pageSide: null,
        ),
        isFalse,
      );
    },
  );

  test('low transition independently limits one edge expansion', () {
    final weak = AiBoundaryRefinementPolicy.edgeExpansion(
      requestedRatio: 0.09,
      transition: 0.19,
      continuity: 0.8,
      ownership: 0.9,
      adjacentPenalty: 0.05,
      occlusionPenalty: 0.05,
      spineEdge: false,
    );
    final strong = AiBoundaryRefinementPolicy.edgeExpansion(
      requestedRatio: 0.09,
      transition: 0.75,
      continuity: 0.8,
      ownership: 0.9,
      adjacentPenalty: 0.05,
      occlusionPenalty: 0.05,
      spineEdge: false,
    );
    expect(weak.appliedRatio, lessThan(strong.appliedRatio));
    expect(weak.conservative, isTrue);
  });

  test('adjacent page and weak ownership cap expansion', () {
    final safe = AiBoundaryRefinementPolicy.edgeExpansion(
      requestedRatio: 0.1,
      transition: 0.8,
      continuity: 0.9,
      ownership: 0.95,
      adjacentPenalty: 0.05,
      occlusionPenalty: 0.05,
      spineEdge: false,
    );
    final risky = AiBoundaryRefinementPolicy.edgeExpansion(
      requestedRatio: 0.1,
      transition: 0.8,
      continuity: 0.9,
      ownership: 0.67,
      adjacentPenalty: 0.8,
      occlusionPenalty: 0.05,
      spineEdge: false,
    );
    expect(risky.appliedRatio, lessThan(safe.appliedRatio));
    expect(risky.reliable, isFalse);
  });

  test('hard reject policy separates ownership adjacent and clipping', () {
    final ownership = AiBoundaryRefinementPolicy.validate(
      roughCorners: raw,
      refinedCorners: outward,
      sourceWidth: 1200,
      sourceHeight: 1600,
      aiContainment: 0.98,
      transitionScore: 0.8,
      reliableEdges: 4,
      mainPageOwnership: 0.4,
    );
    final adjacent = AiBoundaryRefinementPolicy.validate(
      roughCorners: raw,
      refinedCorners: outward,
      sourceWidth: 1200,
      sourceHeight: 1600,
      aiContainment: 0.98,
      transitionScore: 0.8,
      reliableEdges: 4,
      adjacentPagePenalty: 0.9,
    );
    expect(ownership.rejectionReason, 'main_page_ownership_lost');
    expect(adjacent.rejectionReason, 'adjacent_page_merge');
    expect(
      AiBoundaryStabilizationPolicy.statusFor(
        accepted: false,
        rejectionReason: 'ai_foreground_clipped',
        occlusionPenalty: 0,
      ),
      AiRefinedBoundaryStatus.rejectedForegroundClipped,
    );
  });

  test('safe but clamped result reports accepted conservative', () {
    expect(
      AiBoundaryStabilizationPolicy.statusFor(
        accepted: true,
        rejectionReason: null,
        occlusionPenalty: 0,
        refinedConfidence: 0.7,
        conservativeExpansion: true,
      ),
      AiRefinedBoundaryStatus.acceptedConservative,
    );
  });
}

AiRefinementDecision _validate(
  DocumentCorners rough,
  DocumentCorners refined, {
  int width = 1200,
  int height = 1600,
}) => AiBoundaryRefinementPolicy.validate(
  roughCorners: rough,
  refinedCorners: refined,
  sourceWidth: width,
  sourceHeight: height,
  aiContainment: 0.98,
  transitionScore: 0.8,
  reliableEdges: 4,
);

const _metadata = <String, Object?>{
  'success': true,
  'modelVersion': 'v1.2.0',
  'modelLoadMs': 40,
  'preprocessMs': 10,
  'inferenceTimeMs': 45,
  'postprocessMs': 80,
  'totalMs': 135,
  'sourceWidth': 1200,
  'sourceHeight': 1600,
  'maskWidth': 256,
  'maskHeight': 256,
  'maskCoverage': 0.62,
  'pageSide': 'single',
  'corners': {
    'topLeft': {'x': 100.0, 'y': 100.0},
    'topRight': {'x': 900.0, 'y': 100.0},
    'bottomRight': {'x': 900.0, 'y': 1400.0},
    'bottomLeft': {'x': 100.0, 'y': 1400.0},
  },
  'refinementAttempted': true,
  'refinementAccepted': true,
  'refinedCorners': {
    'topLeft': {'x': 80.0, 'y': 80.0},
    'topRight': {'x': 920.0, 'y': 80.0},
    'bottomRight': {'x': 920.0, 'y': 1420.0},
    'bottomLeft': {'x': 80.0, 'y': 1420.0},
  },
  'maskToSearchRoiMs': 3,
  'paperCandidateMs': 28,
  'edgeRefineMs': 31,
  'cornerEstimateMs': 9,
  'totalRefineMs': 71,
  'rawAreaRatio': 0.54,
  'refinedAreaRatio': 0.60,
  'aiContainmentRatio': 0.98,
  'areaExpansionRatio': 1.12,
  'paperTransitionScore': 0.72,
};
