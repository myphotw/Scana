import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/services/image_processing/ai_primary_crop_policy.dart';
import 'package:scana/services/image_processing/ai_boundary_refinement.dart';

void main() {
  const finalCorners = DocumentCorners(
    topLeft: DocumentPoint(40, 30),
    topRight: DocumentPoint(960, 30),
    bottomRight: DocumentPoint(960, 1480),
    bottomLeft: DocumentPoint(40, 1480),
  );

  test('AI final source maps to production CropSource', () {
    for (final pair in <(AiFinalBoundarySource, CropSource)>[
      (AiFinalBoundarySource.refined, CropSource.aiRefined),
      (AiFinalBoundarySource.hybrid, CropSource.aiHybrid),
      (AiFinalBoundarySource.rawFallback, CropSource.aiRawFallback),
    ]) {
      final selected = AiPrimaryCropPolicy.select(
        _result(finalCorners: finalCorners, source: pair.$1),
        pageSide: null,
      );
      expect(selected?.source, pair.$2);
      expect(selected?.corners.topLeft.x, 40);
    }
  });

  test('invalid or absent AI final boundary falls through', () {
    expect(
      AiPrimaryCropPolicy.select(
        _result(
          finalCorners: const DocumentCorners(
            topLeft: DocumentPoint(490, 740),
            topRight: DocumentPoint(510, 740),
            bottomRight: DocumentPoint(510, 760),
            bottomLeft: DocumentPoint(490, 760),
          ),
          source: AiFinalBoundarySource.hybrid,
        ),
        pageSide: null,
      ),
      isNull,
    );
    expect(AiPrimaryCropPolicy.select(_result(), pageSide: null), isNull);
  });

  test('almost disjoint AI final loses the expected-guide sanity check', () {
    const guide = DocumentCorners(
      topLeft: DocumentPoint(80, 120),
      topRight: DocumentPoint(520, 120),
      bottomRight: DocumentPoint(520, 1380),
      bottomLeft: DocumentPoint(80, 1380),
    );
    const otherPage = DocumentCorners(
      topLeft: DocumentPoint(700, 120),
      topRight: DocumentPoint(980, 120),
      bottomRight: DocumentPoint(980, 1380),
      bottomLeft: DocumentPoint(700, 1380),
    );
    expect(
      AiPrimaryCropPolicy.select(
        _result(finalCorners: otherPage, source: AiFinalBoundarySource.refined),
        pageSide: null,
        expectedGuideCorners: guide,
      ),
      isNull,
    );
  });

  test('edge visibility metadata remains session-json compatible', () {
    final original = _result(
      finalCorners: finalCorners,
      source: AiFinalBoundarySource.hybrid,
      edges: const {
        AiBoundaryEdgeName.bottom: AiEdgeVisibility(
          edge: AiBoundaryEdgeName.bottom,
          transitionScore: 0.12,
          supportingSampleRatio: 0.25,
          borderDistance: 0.01,
          occlusionPenalty: 0.2,
          confidence: 0.31,
          status: AiEdgeVisibilityStatus.outOfFrame,
        ),
      },
    );
    final restored = AiDocumentSegmentationResult.fromJson(original.toJson());
    expect(restored?.finalSource, AiFinalBoundarySource.hybrid);
    expect(restored?.finalCorners?.bottomLeft.y, 1480);
    expect(
      restored?.edgeVisibilities[AiBoundaryEdgeName.bottom]?.status,
      AiEdgeVisibilityStatus.outOfFrame,
    );
  });

  test('unknown border edge is not treated as a confirmed inward edge', () {
    expect(
      AiEdgeVisibilityPolicy.classify(
        transitionScore: 0.08,
        supportingSampleRatio: 0.12,
        borderDistance: 0.01,
        occlusionPenalty: 0.1,
        reliable: false,
      ),
      AiEdgeVisibilityStatus.outOfFrame,
    );
    expect(
      AiEdgeVisibilityPolicy.classify(
        transitionScore: 0.65,
        supportingSampleRatio: 0.8,
        borderDistance: 0.12,
        occlusionPenalty: 0.1,
        reliable: true,
      ),
      AiEdgeVisibilityStatus.confirmed,
    );
  });

  test('bottom weak and unknown edges receive larger content-safe padding', () {
    expect(
      AiEdgeVisibilityPolicy.minimumOutwardMargin(
        AiBoundaryEdgeName.bottom,
        AiEdgeVisibilityStatus.weak,
      ),
      greaterThan(
        AiEdgeVisibilityPolicy.minimumOutwardMargin(
          AiBoundaryEdgeName.top,
          AiEdgeVisibilityStatus.weak,
        ),
      ),
    );
    expect(
      AiEdgeVisibilityPolicy.minimumOutwardMargin(
        AiBoundaryEdgeName.bottom,
        AiEdgeVisibilityStatus.unknown,
      ),
      0.070,
    );
  });
}

AiDocumentSegmentationResult _result({
  DocumentCorners? finalCorners,
  AiFinalBoundarySource? source,
  Map<AiBoundaryEdgeName, AiEdgeVisibility> edges = const {},
}) => AiDocumentSegmentationResult(
  success: true,
  modelVersion: 'test',
  modelLoadMs: 0,
  preprocessMs: 1,
  inferenceTimeMs: 2,
  postprocessMs: 1,
  totalMs: 4,
  sourceWidth: 1000,
  sourceHeight: 1500,
  maskWidth: 256,
  maskHeight: 256,
  confidence: 0.9,
  maskCoverage: 0.6,
  pageSide: 'single',
  finalCorners: finalCorners,
  finalSource: source,
  edgeVisibilities: edges,
  refinedConfidence: 0.8,
  mainPageOwnershipScore: 0.9,
);
