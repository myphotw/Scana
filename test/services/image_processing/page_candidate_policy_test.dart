import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/services/image_processing/page_candidate_policy.dart';
import 'package:scana/services/image_processing/page_corrector.dart';

void main() {
  test('keeps a strong flat A4 document candidate', () {
    const document = PageCandidateFeatures(
      kind: PageCandidateKind.document,
      baseScore: 0.86,
      areaRatio: 0.62,
      aspectRatio: 0.7,
      spineStrength: 0,
      spineProximity: 0,
      textDensity: 0.65,
      boundaryCurvature: 0.02,
    );
    const weakBook = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.55,
      areaRatio: 0.4,
      aspectRatio: 0.75,
      spineStrength: 0.1,
      spineProximity: 0.1,
      textDensity: 0.5,
      boundaryCurvature: 0.1,
    );

    expect(PageCandidatePolicy.select([document, weakBook]), document);
  });

  test('rejects an entire open spread in favor of the right page', () {
    const spread = PageCandidateFeatures(
      kind: PageCandidateKind.openBookSpread,
      baseScore: 0.88,
      areaRatio: 0.78,
      aspectRatio: 1.45,
      spineStrength: 0.9,
      spineProximity: 1,
      textDensity: 0.75,
      boundaryCurvature: 0.4,
      twoPageStructure: 0.8,
    );
    const left = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.58,
      areaRatio: 0.38,
      aspectRatio: 0.72,
      spineStrength: 0.9,
      spineProximity: 0.9,
      textDensity: 0.45,
      boundaryCurvature: 0.55,
    );
    const right = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.6,
      areaRatio: 0.4,
      aspectRatio: 0.74,
      spineStrength: 0.9,
      spineProximity: 0.95,
      textDensity: 0.8,
      boundaryCurvature: 0.6,
    );

    expect(PageCandidatePolicy.select([spread, left, right]), right);
  });

  test('supports a left page and strong shadow curved-page evidence', () {
    const spread = PageCandidateFeatures(
      kind: PageCandidateKind.openBookSpread,
      baseScore: 0.84,
      areaRatio: 0.7,
      aspectRatio: 1.35,
      spineStrength: 0.92,
      spineProximity: 1,
      textDensity: 0.6,
      boundaryCurvature: 0.5,
      twoPageStructure: 0.75,
    );
    const leftPage = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.57,
      areaRatio: 0.36,
      aspectRatio: 0.68,
      spineStrength: 0.95,
      spineProximity: 0.95,
      textDensity: 0.72,
      boundaryCurvature: 0.8,
    );

    expect(PageCandidatePolicy.select([spread, leftPage]), leftPage);
  });

  test('does not split a landscape document without two page structures', () {
    const landscapeDocument = PageCandidateFeatures(
      kind: PageCandidateKind.openBookSpread,
      baseScore: 0.84,
      areaRatio: 0.65,
      aspectRatio: 1.3,
      spineStrength: 0.5,
      spineProximity: 0.8,
      textDensity: 0.5,
      boundaryCurvature: 0.08,
      twoPageStructure: 0.1,
    );
    const falseHalf = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.45,
      areaRatio: 0.3,
      aspectRatio: 0.65,
      spineStrength: 0.4,
      spineProximity: 0.5,
      textDensity: 0.3,
      boundaryCurvature: 0.1,
    );

    expect(
      PageCandidatePolicy.select([landscapeDocument, falseHalf]),
      landscapeDocument,
    );
  });

  test('does not render the metadata-only fixed capture guide', () {
    expect(CameraBoundaryOverlayStyle.showsFixedCaptureGuide, isFalse);
  });

  test(
    'uses text and spine structure when page and background are similar',
    () {
      const lowContrastDocument = PageCandidateFeatures(
        kind: PageCandidateKind.document,
        baseScore: 0.5,
        areaRatio: 0.5,
        aspectRatio: 0.7,
        spineStrength: 0,
        spineProximity: 0,
        textDensity: 0.3,
        boundaryCurvature: 0,
      );
      const structuredBookPage = PageCandidateFeatures(
        kind: PageCandidateKind.bookPage,
        baseScore: 0.52,
        areaRatio: 0.38,
        aspectRatio: 0.72,
        spineStrength: 0.85,
        spineProximity: 0.9,
        textDensity: 0.82,
        boundaryCurvature: 0.6,
      );

      expect(
        PageCandidatePolicy.select([lowContrastDocument, structuredBookPage]),
        structuredBookPage,
      );
    },
  );

  test('curved analysis can continue with top and spine signals', () {
    expect(
      const CurvedSignalEvidence(
        boundaryCurves: 1,
        spineBoundaries: 1,
      ).hasSufficientSignals,
      isTrue,
    );
  });

  test('rejects an underline used as a book page bottom edge', () {
    const underlineCandidate = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.82,
      areaRatio: 0.34,
      aspectRatio: 0.72,
      spineStrength: 0.8,
      spineProximity: 0.9,
      textDensity: 0.75,
      boundaryCurvature: 0.4,
      outsideContentContinuation: 0.63,
      contentContainment: 0.65,
    );

    expect(PageCandidatePolicy.isEligible(underlineCandidate), isFalse);
  });

  test('rejects a table rule when page content continues below it', () {
    const tableCandidate = PageCandidateFeatures(
      kind: PageCandidateKind.document,
      baseScore: 0.9,
      areaRatio: 0.5,
      aspectRatio: 0.8,
      spineStrength: 0,
      spineProximity: 0,
      textDensity: 0.9,
      boundaryCurvature: 0,
      outsideContentContinuation: 0.7,
      contentContainment: 0.61,
    );

    expect(PageCandidatePolicy.isEligible(tableCandidate), isFalse);
    expect(PageCandidatePolicy.score(tableCandidate), -1);
  });

  test('book candidates prioritize outer continuity and containment', () {
    const internalRule = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.82,
      areaRatio: 0.32,
      aspectRatio: 0.75,
      spineStrength: 0.8,
      spineProximity: 0.9,
      textDensity: 0.85,
      boundaryCurvature: 0.5,
      outsideContentContinuation: 0.4,
      contentContainment: 0.76,
      outerBoundaryContinuity: 0.3,
    );
    const pageOutline = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.7,
      areaRatio: 0.48,
      aspectRatio: 0.72,
      spineStrength: 0.8,
      spineProximity: 0.9,
      textDensity: 0.72,
      boundaryCurvature: 0.48,
      outsideContentContinuation: 0.05,
      contentContainment: 0.97,
      outerBoundaryContinuity: 0.9,
    );

    expect(
      PageCandidatePolicy.select([internalRule, pageOutline]),
      pageOutline,
    );
  });

  test('rejects a self-intersecting boundary before scoring', () {
    const crossed = PageCandidateFeatures(
      kind: PageCandidateKind.document,
      baseScore: 0.95,
      areaRatio: 0.7,
      aspectRatio: 0.7,
      spineStrength: 0,
      spineProximity: 0,
      textDensity: 0.7,
      boundaryCurvature: 0,
      selfIntersects: true,
    );

    expect(PageCandidatePolicy.isEligible(crossed), isFalse);
  });

  test('rejects a bottom candidate that leaves document content below it', () {
    const internalBottom = PageCandidateFeatures(
      kind: PageCandidateKind.document,
      baseScore: 0.92,
      areaRatio: 0.5,
      aspectRatio: 0.72,
      spineStrength: 0,
      spineProximity: 0,
      textDensity: 0.85,
      boundaryCurvature: 0,
      contentEnvelopeContainment: 0.76,
      bottomContinuity: 0.7,
      outsideContentContinuation: 0.62,
    );

    expect(PageCandidatePolicy.isEligible(internalBottom), isFalse);
  });

  test(
    'prefers a full page over a footer separator with similar confidence',
    () {
      const footerSeparator = PageCandidateFeatures(
        kind: PageCandidateKind.document,
        baseScore: 0.88,
        areaRatio: 0.48,
        aspectRatio: 0.72,
        spineStrength: 0,
        spineProximity: 0,
        textDensity: 0.8,
        boundaryCurvature: 0,
        contentEnvelopeContainment: 0.79,
        outsideContentContinuation: 0.44,
      );
      const fullPage = PageCandidateFeatures(
        kind: PageCandidateKind.document,
        baseScore: 0.78,
        areaRatio: 0.66,
        aspectRatio: 0.72,
        spineStrength: 0,
        spineProximity: 0,
        textDensity: 0.7,
        boundaryCurvature: 0,
        contentEnvelopeContainment: 0.97,
        outerBoundaryContinuity: 0.9,
      );

      expect(PageCandidatePolicy.select([footerSeparator, fullPage]), fullPage);
    },
  );

  test('left spread ROI prioritizes its left outer page edge', () {
    const internalVertical = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.78,
      areaRatio: 0.42,
      aspectRatio: 0.74,
      spineStrength: 0.8,
      spineProximity: 0.9,
      textDensity: 0.8,
      boundaryCurvature: 0.4,
      pageSide: PageCandidateSide.left,
      outerEdgeAnchor: 0.1,
      contentEnvelopeContainment: 0.94,
    );
    const leftPage = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.71,
      areaRatio: 0.46,
      aspectRatio: 0.74,
      spineStrength: 0.52,
      spineProximity: 0.8,
      textDensity: 0.7,
      boundaryCurvature: 0.55,
      pageSide: PageCandidateSide.left,
      outerEdgeAnchor: 0.94,
      outerBoundaryContinuity: 0.9,
      contentEnvelopeContainment: 0.97,
    );

    expect(PageCandidatePolicy.select([internalVertical, leftPage]), leftPage);
  });

  test('right spread ROI prioritizes its right outer page edge', () {
    const spineAdjacent = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.8,
      areaRatio: 0.4,
      aspectRatio: 0.72,
      spineStrength: 0.9,
      spineProximity: 0.95,
      textDensity: 0.8,
      boundaryCurvature: 0.45,
      pageSide: PageCandidateSide.right,
      outerEdgeAnchor: 0.12,
      contentEnvelopeContainment: 0.94,
    );
    const rightPage = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.71,
      areaRatio: 0.46,
      aspectRatio: 0.72,
      spineStrength: 0.5,
      spineProximity: 0.82,
      textDensity: 0.72,
      boundaryCurvature: 0.52,
      pageSide: PageCandidateSide.right,
      outerEdgeAnchor: 0.95,
      outerBoundaryContinuity: 0.9,
      contentEnvelopeContainment: 0.97,
    );

    expect(PageCandidatePolicy.select([spineAdjacent, rightPage]), rightPage);
  });

  test('does not expand into opposite-page content in the overlap zone', () {
    const overlapCandidate = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.82,
      areaRatio: 0.56,
      aspectRatio: 0.78,
      spineStrength: 0.85,
      spineProximity: 0.9,
      textDensity: 0.82,
      boundaryCurvature: 0.5,
      pageSide: PageCandidateSide.left,
      overlapExpansion: 1,
      outerEdgeAnchor: 0.4,
      contentEnvelopeContainment: 0.9,
    );
    const ownedPage = PageCandidateFeatures(
      kind: PageCandidateKind.bookPage,
      baseScore: 0.74,
      areaRatio: 0.45,
      aspectRatio: 0.74,
      spineStrength: 0.65,
      spineProximity: 0.8,
      textDensity: 0.72,
      boundaryCurvature: 0.55,
      pageSide: PageCandidateSide.left,
      outerEdgeAnchor: 0.9,
      contentEnvelopeContainment: 0.97,
      outerBoundaryContinuity: 0.9,
    );

    expect(
      PageCandidatePolicy.select([overlapCandidate, ownedPage]),
      ownedPage,
    );
  });

  test(
    'keeps a ring-bound page with an irregular spine when outer edges agree',
    () {
      const ringBoundPage = PageCandidateFeatures(
        kind: PageCandidateKind.bookPage,
        baseScore: 0.7,
        areaRatio: 0.45,
        aspectRatio: 0.72,
        spineStrength: 0.2,
        spineProximity: 0.35,
        textDensity: 0.75,
        boundaryCurvature: 0.62,
        outerBoundaryContinuity: 0.92,
        contentEnvelopeContainment: 0.98,
        pageSide: PageCandidateSide.left,
        outerEdgeAnchor: 0.95,
      );

      expect(PageCandidatePolicy.isEligible(ringBoundPage), isTrue);
      expect(PageCandidatePolicy.score(ringBoundPage), greaterThan(0));
    },
  );
}
