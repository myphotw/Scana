import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/image_processing/page_candidate_policy.dart';

PageCandidateFeatures page({
  PageCandidateKind kind = PageCandidateKind.document,
  PageCandidateSide side = PageCandidateSide.single,
  double area = 0.68,
  double occupancy = 0.92,
  double border = 0.88,
  double contrast = 0.72,
  double paper = 0.86,
  double rectangularity = 0.86,
  double continuity = 0.84,
  double internalPenalty = 0.04,
  double smallPenalty = 0,
  double width = 0.78,
  double height = 0.88,
  double outerAnchor = 0.9,
  double spine = 0.5,
}) => PageCandidateFeatures(
  kind: kind,
  baseScore: 0.72,
  areaRatio: area,
  aspectRatio: 0.72,
  spineStrength: spine,
  spineProximity: spine,
  textDensity: 0.7,
  boundaryCurvature: 0.18,
  pageSide: side,
  occupancy: occupancy,
  borderProximity: border,
  insideOutsideContrast: contrast,
  paperInterior: paper,
  rectangularity: rectangularity,
  edgeContinuity: continuity,
  outerEdgeAnchor: outerAnchor,
  internalLinePenalty: internalPenalty,
  smallCandidatePenalty: smallPenalty,
  widthRatio: width,
  heightRatio: height,
  contentEnvelopeContainment: 0.96,
  contentContainment: 0.94,
  outerBoundaryContinuity: continuity,
);

void main() {
  test('white paper with dark body content has strong confidence', () {
    expect(PageCandidatePolicy.confidence(page()), greaterThan(0.70));
  });

  test('single long horizontal rule is not a page boundary', () {
    final rule = page(
      area: 0.20,
      occupancy: 0.12,
      border: 0.08,
      contrast: 0.04,
      internalPenalty: 0.9,
      smallPenalty: 0.8,
      height: 0.08,
    );
    expect(PageCandidatePolicy.isEligible(rule), isFalse);
  });

  test('full music page outranks repeated staff-line candidate', () {
    final fullPage = page(paper: 0.78, contrast: 0.54);
    final staves = page(
      area: 0.34,
      occupancy: 0.34,
      border: 0.16,
      contrast: 0.06,
      paper: 0.82,
      continuity: 0.92,
      internalPenalty: 0.86,
      smallPenalty: 0.55,
      height: 0.34,
    );
    expect(PageCandidatePolicy.select([staves, fullPage]), fullPage);
  });

  test('full page outranks a large internal table', () {
    final fullPage = page();
    final table = page(
      area: 0.42,
      occupancy: 0.48,
      border: 0.22,
      contrast: 0.08,
      internalPenalty: 0.72,
      smallPenalty: 0.35,
    );
    expect(PageCandidatePolicy.select([table, fullPage]), fullPage);
  });

  test('full page outranks an internal rectangular frame', () {
    final fullPage = page();
    final frame = page(
      area: 0.38,
      occupancy: 0.4,
      border: 0.18,
      contrast: 0.05,
      internalPenalty: 0.78,
      smallPenalty: 0.45,
    );
    expect(PageCandidatePolicy.select([frame, fullPage]), fullPage);
  });

  test('dark desk outside the page increases usable contrast evidence', () {
    expect(
      PageCandidatePolicy.confidence(page(contrast: 0.92)),
      greaterThan(0.8),
    );
  });

  test('bright background does not reject a large paper-like page', () {
    final brightBackground = page(contrast: 0.16, paper: 0.9);
    expect(PageCandidatePolicy.isEligible(brightBackground), isTrue);
    expect(PageCandidatePolicy.confidence(brightBackground), greaterThan(0.55));
  });

  test('weak page shadow is tolerated', () {
    final shadow = page(contrast: 0.42, paper: 0.66, continuity: 0.7);
    expect(PageCandidatePolicy.confidence(shadow), greaterThan(0.55));
  });

  test('one partially missing outer edge keeps a conservative candidate', () {
    final partialEdge = page(continuity: 0.48, contrast: 0.5);
    expect(PageCandidatePolicy.isEligible(partialEdge), isTrue);
    expect(PageCandidatePolicy.confidence(partialEdge), greaterThan(0.5));
  });

  test('page occupying most of the ROI receives a higher score', () {
    final large = page();
    final medium = page(
      area: 0.4,
      occupancy: 0.42,
      border: 0.45,
      smallPenalty: 0.2,
    );
    expect(
      PageCandidatePolicy.score(large),
      greaterThan(PageCandidatePolicy.score(medium)),
    );
  });

  test('small centered rectangle is rejected', () {
    final centered = page(
      area: 0.12,
      occupancy: 0,
      border: 0,
      smallPenalty: 1,
      width: 0.28,
      height: 0.24,
    );
    expect(PageCandidatePolicy.isEligible(centered), isFalse);
  });

  test('left spread page rewards its outer edge', () {
    final left = page(
      kind: PageCandidateKind.bookPage,
      side: PageCandidateSide.left,
      outerAnchor: 0.94,
    );
    final inner = page(
      kind: PageCandidateKind.bookPage,
      side: PageCandidateSide.left,
      outerAnchor: 0.08,
      border: 0.4,
    );
    expect(PageCandidatePolicy.select([inner, left]), left);
  });

  test('right spread page rewards its outer edge', () {
    final right = page(
      kind: PageCandidateKind.bookPage,
      side: PageCandidateSide.right,
      outerAnchor: 0.94,
    );
    final inner = page(
      kind: PageCandidateKind.bookPage,
      side: PageCandidateSide.right,
      outerAnchor: 0.08,
      border: 0.4,
    );
    expect(PageCandidatePolicy.select([inner, right]), right);
  });

  test('left spread page remains usable with a weak spine edge', () {
    final left = page(
      kind: PageCandidateKind.bookPage,
      side: PageCandidateSide.left,
      spine: 0.08,
      continuity: 0.66,
    );
    expect(PageCandidatePolicy.confidence(left), greaterThan(0.55));
  });

  test('right spread page remains usable with a weak spine edge', () {
    final right = page(
      kind: PageCandidateKind.bookPage,
      side: PageCandidateSide.right,
      spine: 0.08,
      continuity: 0.66,
    );
    expect(PageCandidatePolicy.confidence(right), greaterThan(0.55));
  });

  test('narrow crop is rejected before perspective use', () {
    final narrow = page(
      kind: PageCandidateKind.bookPage,
      area: 0.28,
      width: 0.22,
      height: 0.88,
      smallPenalty: 0.7,
    );
    expect(PageCandidatePolicy.isEligible(narrow), isFalse);
    expect(PageCandidatePolicy.confidence(narrow), 0);
  });

  test('overly wide background candidate loses without a paper transition', () {
    final pageEdge = page(area: 0.68, contrast: 0.76, paper: 0.86);
    final background = page(
      area: 0.9,
      occupancy: 1,
      border: 1,
      contrast: 0.04,
      paper: 0.44,
      continuity: 0.46,
      internalPenalty: 0.28,
    );
    expect(PageCandidatePolicy.select([background, pageEdge]), pageEdge);
  });

  test('ambiguous music content crop loses to the wider page boundary', () {
    final fullPage = page(area: 0.72, width: 0.86, height: 0.9);
    final contentCrop = page(
      area: 0.48,
      width: 0.72,
      height: 0.68,
      occupancy: 0.58,
      border: 0.5,
      internalPenalty: 0.68,
      smallPenalty: 0.24,
    );
    expect(PageCandidatePolicy.select([contentCrop, fullPage]), fullPage);
  });
}
