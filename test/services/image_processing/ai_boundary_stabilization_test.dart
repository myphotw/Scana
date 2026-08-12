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

  test('main page ownership combines mask, centroid, and intersection', () {
    final ownership = AiBoundaryStabilizationPolicy.mainPageOwnership(
      aiContainment: 0.98,
      centroidProximity: 0.95,
      componentIntersection: 0.72,
    );
    expect(
      ownership,
      greaterThan(AiBoundaryStabilizationPolicy.minimumOwnership),
    );
  });

  test('adjacent white page growth is strongly penalized', () {
    final penalty = AiBoundaryStabilizationPolicy.adjacentPagePenalty(
      areaExpansion: 1.5,
      spineOvershoot: 0.2,
      narrowConnectionPenalty: 0.8,
    );
    expect(
      penalty,
      greaterThan(AiBoundaryStabilizationPolicy.adjacentRejectionPenalty),
    );
  });

  test('narrow connection valley is found between page components', () {
    expect(
      AiBoundaryStabilizationPolicy.narrowConnectionIndex([
        10,
        95,
        98,
        100,
        96,
        24,
        94,
        99,
        97,
        12,
      ]),
      5,
    );
  });

  test('outer envelope expands past tight AI content boundary', () {
    final offset = AiBoundaryStabilizationPolicy.robustOuterOffset([
      -4,
      2,
      7,
      8,
      9,
      10,
      11,
    ]);
    expect(offset, greaterThan(8));
  });

  test('top curved envelope ignores one inward extreme', () {
    final offset = AiBoundaryStabilizationPolicy.robustOuterOffset([
      8,
      10,
      12,
      14,
      11,
      -35,
      9,
    ]);
    expect(offset, greaterThan(11));
  });

  test('bottom curved envelope keeps page-number margin', () {
    final offset = AiBoundaryStabilizationPolicy.robustOuterOffset([
      9,
      11,
      15,
      16,
      13,
      10,
    ]);
    expect(offset, greaterThanOrEqualTo(14));
  });

  test('left outer edge is reported as outward expansion', () {
    expect(
      AiBoundaryRefinementPolicy.expandsEdge(
        raw,
        _outward,
        AiBoundaryEdge.left,
      ),
      isTrue,
    );
  });

  test('right outer edge is reported as outward expansion', () {
    expect(
      AiBoundaryRefinementPolicy.expandsEdge(
        raw,
        _outward,
        AiBoundaryEdge.right,
      ),
      isTrue,
    );
  });

  test('occlusion color and offset outlier is rejected by robust fit', () {
    final fit = AiBoundaryStabilizationPolicy.robustEdgeFit(
      offsets: [8, 9, 10, -40, 11, 10, 9],
      colorDistances: [3, 4, 3, 80, 4, 3, 4],
    );
    expect(fit.inlierCount, 6);
    expect(fit.offset, inInclusiveRange(8, 11));
    expect(fit.occlusionPenalty, greaterThan(0));
  });

  test('bottom partial occlusion uses stable envelope instead of finger', () {
    const bottom = RobustEdgeFit(
      offset: 0,
      continuity: 0.35,
      occlusionPenalty: 0.72,
      inlierCount: 5,
    );
    expect(
      AiBoundaryStabilizationPolicy.recoverBottomOffset(
        bottom: bottom,
        rawOffset: 0,
        envelopeOffset: 14,
      ),
      14,
    );
  });

  test('excessive expansion retains rejection policy', () {
    final decision = _validate(
      const DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(1200, 0),
        bottomRight: DocumentPoint(1200, 1600),
        bottomLeft: DocumentPoint(0, 1600),
      ),
    );
    expect(decision.rejectionReason, 'excessive_refinement_expansion');
  });

  test('excessive shrink retains raw fallback policy', () {
    final decision = _validate(
      const DocumentCorners(
        topLeft: DocumentPoint(190, 190),
        topRight: DocumentPoint(810, 190),
        bottomRight: DocumentPoint(810, 1310),
        bottomLeft: DocumentPoint(190, 1310),
      ),
    );
    expect(decision.rejectionReason, 'excessive_inward_refinement');
  });

  test('AI containment is preserved at high threshold', () {
    final decision = AiBoundaryRefinementPolicy.validate(
      roughCorners: raw,
      refinedCorners: _outward,
      sourceWidth: 1200,
      sourceHeight: 1600,
      aiContainment: 0.9,
      transitionScore: 0.8,
      reliableEdges: 4,
    );
    expect(decision.rejectionReason, 'ai_foreground_clipped');
  });

  test('robust edge fitting follows the consensus samples', () {
    final fit = AiBoundaryStabilizationPolicy.robustEdgeFit(
      offsets: [12, 11, 13, 12, 12, 10, 90, 11, 13],
      colorDistances: [3, 4, 3, 4, 3, 4, 90, 3, 4],
    );
    expect(fit.offset, closeTo(12, 1));
    expect(fit.continuity, greaterThan(0.8));
  });

  test('Single main page accepts strong ownership without side bias', () {
    expect(
      AiBoundaryStabilizationPolicy.mainPageOwnership(
        aiContainment: 0.96,
        centroidProximity: 0.9,
        componentIntersection: 0.7,
      ),
      greaterThan(0.8),
    );
  });

  test('Spread left trusts left outer edge plus top', () {
    expect(
      AiBoundaryStabilizationPolicy.spreadGeometrySupported(
        pageSide: 'left',
        reliableEdges: const {
          AiBoundaryEdge.top: true,
          AiBoundaryEdge.right: false,
          AiBoundaryEdge.bottom: false,
          AiBoundaryEdge.left: true,
        },
      ),
      isTrue,
    );
  });

  test('Spread right trusts right outer edge plus bottom', () {
    expect(
      AiBoundaryStabilizationPolicy.spreadGeometrySupported(
        pageSide: 'right',
        reliableEdges: const {
          AiBoundaryEdge.top: false,
          AiBoundaryEdge.right: true,
          AiBoundaryEdge.bottom: true,
          AiBoundaryEdge.left: false,
        },
      ),
      isTrue,
    );
  });

  test('one-side occlusion can be marked as recovered', () {
    expect(
      AiBoundaryStabilizationPolicy.statusFor(
        accepted: true,
        rejectionReason: null,
        occlusionPenalty: 0.24,
      ),
      AiRefinedBoundaryStatus.acceptedOcclusionRecovered,
    );
  });

  test('weak spine edge does not reject supported spread geometry', () {
    expect(
      AiBoundaryStabilizationPolicy.spreadGeometrySupported(
        pageSide: 'left',
        reliableEdges: const {
          AiBoundaryEdge.top: true,
          AiBoundaryEdge.right: false,
          AiBoundaryEdge.bottom: true,
          AiBoundaryEdge.left: true,
        },
      ),
      isTrue,
    );
  });

  test('unresolved evidence maps to raw fallback', () {
    expect(
      AiBoundaryStabilizationPolicy.statusFor(
        accepted: false,
        rejectionReason: 'paper_transition_weak',
        occlusionPenalty: 0,
      ),
      AiRefinedBoundaryStatus.rawFallback,
    );
  });

  test('refinement rejection reasons map to explicit status', () {
    expect(
      AiBoundaryStabilizationPolicy.statusFor(
        accepted: false,
        rejectionReason: 'adjacent_page_merge',
        occlusionPenalty: 0,
      ),
      AiRefinedBoundaryStatus.rejectedAdjacentPage,
    );
    expect(
      AiBoundaryStabilizationPolicy.statusFor(
        accepted: false,
        rejectionReason: 'occlusion_unresolved',
        occlusionPenalty: 0.8,
      ),
      AiRefinedBoundaryStatus.rejectedOcclusion,
    );
  });

  test('envelope artifact and refined metrics remain relative/persistent', () {
    final result = AiDocumentSegmentationResult.fromJson({
      ..._metadata,
      'debugEnvelopeOverlayFile': 'debug_ai/page_ai_envelope_overlay.jpg',
    })!;
    expect(result.refinedStatus, AiRefinedBoundaryStatus.accepted);
    expect(result.refinedConfidence, 0.86);
    expect(result.occlusionPenalty, 0.12);
    expect(
      result.debugArtifactFiles,
      contains('debug_ai/page_ai_envelope_overlay.jpg'),
    );
  });
}

AiRefinementDecision _validate(DocumentCorners corners) =>
    AiBoundaryRefinementPolicy.validate(
      roughCorners: const DocumentCorners(
        topLeft: DocumentPoint(100, 100),
        topRight: DocumentPoint(900, 100),
        bottomRight: DocumentPoint(900, 1400),
        bottomLeft: DocumentPoint(100, 1400),
      ),
      refinedCorners: corners,
      sourceWidth: 1200,
      sourceHeight: 1600,
      aiContainment: 0.98,
      transitionScore: 0.8,
      reliableEdges: 4,
    );

const _outward = DocumentCorners(
  topLeft: DocumentPoint(80, 80),
  topRight: DocumentPoint(920, 80),
  bottomRight: DocumentPoint(920, 1420),
  bottomLeft: DocumentPoint(80, 1420),
);

const _metadata = <String, Object?>{
  'success': true,
  'modelVersion': 'v1.2.0',
  'modelLoadMs': 20,
  'preprocessMs': 10,
  'inferenceTimeMs': 24,
  'postprocessMs': 30,
  'totalMs': 64,
  'sourceWidth': 1200,
  'sourceHeight': 1600,
  'maskWidth': 256,
  'maskHeight': 256,
  'maskCoverage': 0.66,
  'pageSide': 'single',
  'refinementAttempted': true,
  'refinementAccepted': true,
  'mainPageOwnershipScore': 0.91,
  'outerEnvelopeConsistency': 0.84,
  'edgeContinuity': 0.88,
  'adjacentPagePenalty': 0.08,
  'occlusionPenalty': 0.12,
  'refinedConfidence': 0.86,
  'refinedStatus': 'accepted',
};
