import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';

import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/image_processing/quick_corner_edit.dart';

void main() {
  const refined = DocumentCorners(
    topLeft: DocumentPoint(40, 50),
    topRight: DocumentPoint(960, 50),
    bottomRight: DocumentPoint(960, 1450),
    bottomLeft: DocumentPoint(40, 1450),
  );
  const raw = DocumentCorners(
    topLeft: DocumentPoint(100, 120),
    topRight: DocumentPoint(900, 120),
    bottomRight: DocumentPoint(900, 1380),
    bottomLeft: DocumentPoint(100, 1380),
  );

  test('accepted AI Refined corners are the first automatic initial value', () {
    final selection = QuickCornerInitialPolicy.resolve(
      _page(
        ai: _ai(raw: raw, refined: refined, accepted: true),
      ),
    );
    expect(selection?.source, QuickCornerInitialSource.aiRefined);
    expect(selection?.corners, same(refined));
  });

  test('AI Raw precedes OpenCV and final crop when refinement is rejected', () {
    final selection = QuickCornerInitialPolicy.resolve(
      _page(
        ai: _ai(raw: raw, refined: refined, accepted: false),
      ),
    );
    expect(selection?.source, QuickCornerInitialSource.aiRaw);
    expect(selection?.corners, same(raw));
  });

  test('fallback order is OpenCV then final crop then guide', () {
    final boundary = PageBoundary.fromCorners(
      raw,
      sourceWidth: 1000,
      sourceHeight: 1500,
      confidence: 0.8,
      timestamp: DateTime.utc(2026, 8, 12),
    );
    expect(
      QuickCornerInitialPolicy.resolve(_page(boundary: boundary))?.source,
      QuickCornerInitialSource.openCvBoundary,
    );
    expect(
      QuickCornerInitialPolicy.resolve(_page())?.source,
      QuickCornerInitialSource.finalCrop,
    );
    expect(
      QuickCornerInitialPolicy.resolve(
        _page(documentCorners: null, guide: raw),
      )?.source,
      QuickCornerInitialSource.guideFallback,
    );
  });

  test('manual corners remain first when editing again', () {
    final selection = QuickCornerInitialPolicy.resolve(
      _page(
        ai: _ai(raw: raw, refined: refined, accepted: true),
        userAdjusted: true,
      ),
    );
    expect(selection?.source, QuickCornerInitialSource.manual);
    expect(selection?.corners, const TypeMatcher<DocumentCorners>());
  });

  test('corner drag uses source coordinates at current zoom', () {
    final transform = QuickCornerViewportTransform.forSource(
      const Size(4000, 3000),
    );
    final moved = transform.moveSourcePoint(
      point: const DocumentPoint(100, 100),
      screenDelta: const Offset(60, 30),
      viewportScale: 2,
    );
    expect(transform.sceneScale, 0.3);
    expect(moved.x, 200);
    expect(moved.y, 150);
  });

  test('corner drag remains clamped to the raw image', () {
    final transform = QuickCornerViewportTransform.forSource(
      const Size(1000, 1500),
    );
    final moved = transform.moveSourcePoint(
      point: const DocumentPoint(990, 1490),
      screenDelta: const Offset(500, 500),
      viewportScale: 1,
    );
    expect(moved.x, 1000);
    expect(moved.y, 1500);
  });
}

ScanPage _page({
  AiDocumentSegmentationResult? ai,
  PageBoundary? boundary,
  DocumentCorners? documentCorners = const DocumentCorners(
    topLeft: DocumentPoint(60, 70),
    topRight: DocumentPoint(940, 70),
    bottomRight: DocumentPoint(940, 1430),
    bottomLeft: DocumentPoint(60, 1430),
  ),
  DocumentCorners? guide,
  bool userAdjusted = false,
}) => ScanPage(
  pageNo: 1,
  rawImagePath: 'raw.jpg',
  createdTime: DateTime.utc(2026, 8, 12),
  documentSourceWidth: 1000,
  documentSourceHeight: 1500,
  documentCorners: documentCorners,
  captureGuideCorners: guide,
  pageBoundary: boundary,
  aiSegmentationResult: ai,
  hasUserAdjustedCorners: userAdjusted,
);

AiDocumentSegmentationResult _ai({
  required DocumentCorners raw,
  required DocumentCorners refined,
  required bool accepted,
}) => AiDocumentSegmentationResult(
  success: true,
  modelVersion: 'test',
  modelLoadMs: 0,
  preprocessMs: 0,
  inferenceTimeMs: 1,
  postprocessMs: 1,
  totalMs: 2,
  sourceWidth: 1000,
  sourceHeight: 1500,
  maskWidth: 256,
  maskHeight: 256,
  maskCoverage: 0.5,
  pageSide: 'single',
  corners: raw,
  refinementAttempted: true,
  refinementAccepted: accepted,
  refinedCorners: refined,
  refinedStatus: accepted
      ? AiRefinedBoundaryStatus.accepted
      : AiRefinedBoundaryStatus.rejectedAdjacentPage,
);
