import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/services/image_processing/page_corrector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PerspectiveGeometry', () {
    test('uses the longest opposing edges for output size', () {
      const corners = DocumentCorners(
        topLeft: DocumentPoint(10, 20),
        topRight: DocumentPoint(810, 20),
        bottomRight: DocumentPoint(910, 1220),
        bottomLeft: DocumentPoint(0, 1020),
      );

      final size = PerspectiveGeometry.outputSize(corners);

      expect(size.width, 932);
      expect(size.height, 1204);
    });

    test('keeps a 2500 by 3500 page at its source-coordinate density', () {
      const corners = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(2500, 0),
        bottomRight: DocumentPoint(2500, 3500),
        bottomLeft: DocumentPoint(0, 3500),
      );

      final size = PerspectiveGeometry.outputSize(corners);

      expect(size.width, 2500);
      expect(size.height, 3500);
    });

    test('accepts top-left to bottom-left clockwise corner order', () {
      const corners = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(100, 0),
        bottomRight: DocumentPoint(100, 200),
        bottomLeft: DocumentPoint(0, 200),
      );

      expect(PerspectiveGeometry.hasValidCornerOrder(corners), isTrue);
    });

    test('rejects crossed or counter-clockwise corner order', () {
      const crossed = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(100, 200),
        bottomRight: DocumentPoint(100, 0),
        bottomLeft: DocumentPoint(0, 200),
      );
      const counterClockwise = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(0, 200),
        bottomRight: DocumentPoint(100, 200),
        bottomLeft: DocumentPoint(100, 0),
      );

      expect(PerspectiveGeometry.hasValidCornerOrder(crossed), isFalse);
      expect(
        PerspectiveGeometry.hasValidCornerOrder(counterClockwise),
        isFalse,
      );
    });
  });

  group('CurvedPagePolicy', () {
    const visibleCorners = DocumentCorners(
      topLeft: DocumentPoint(40, 50),
      topRight: DocumentPoint(960, 45),
      bottomRight: DocumentPoint(950, 1450),
      bottomLeft: DocumentPoint(45, 1440),
    );

    test('prioritizes a visible page boundary', () {
      final mode = CurvedPagePolicy.selectBoundaryMode(
        corners: visibleCorners,
        sourceWidth: 1000,
        sourceHeight: 1500,
      );

      expect(mode, PageBoundaryMode.detected);
      final region = CurvedPagePolicy.regionFor(mode);
      expect(
        [region.left, region.top, region.right, region.bottom],
        [0, 0, 1, 1],
      );
    });

    test('uses a responsive inset when a boundary reaches the frame', () {
      const clippedCorners = DocumentCorners(
        topLeft: DocumentPoint(0, 0),
        topRight: DocumentPoint(1000, 0),
        bottomRight: DocumentPoint(1000, 1500),
        bottomLeft: DocumentPoint(0, 1500),
      );
      final mode = CurvedPagePolicy.selectBoundaryMode(
        corners: clippedCorners,
        sourceWidth: 1000,
        sourceHeight: 1500,
      );

      expect(mode, PageBoundaryMode.insetFallback);
      final region = CurvedPagePolicy.regionFor(mode);
      expect(region.left, 0.04);
      expect(region.top, 0.04);
      expect(region.right, 0.96);
      expect(region.bottom, 0.96);
    });

    test('rejects low-confidence curvature', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 4, 6, 4, 0],
          imageHeight: 1000,
          confidence: 0.4,
        ),
        isFalse,
      );
    });

    test('accepts a smooth, bounded, asymmetric curve', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 1, 3, 5, 6, 5, 3, 2, 0],
          imageHeight: 1000,
          confidence: 0.85,
        ),
        isTrue,
      );
    });

    test('rejects excessive deformation and abrupt adjacent changes', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 35, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 2, 8, 2, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
    });

    test('rejects NaN and out-of-range remap inputs', () {
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, double.nan, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
      expect(
        CurvedPagePolicy.acceptsCurve(
          offsets: const [0, 10000, 0],
          imageHeight: 1000,
          confidence: 0.9,
        ),
        isFalse,
      );
    });
  });

  group('curved correction adoption', () {
    test('reads full-resolution sharpness diagnostics from native', () async {
      const channel = MethodChannel('test/page_corrector_quality');
      final messenger = TestDefaultBinaryMessengerBinding.instance;
      messenger.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => <String, Object>{
          'outputWidth': 2500,
          'outputHeight': 3500,
          'outcome': 'completed',
          'outputFormat': 'png',
          'sourceWidth': 3024,
          'sourceHeight': 4032,
          'sourceSharpness': 140.0,
          'sourceForegroundSharpness': 190.0,
          'sourceForegroundPixels': 1234,
          'outputSharpness': 130.0,
          'outputForegroundSharpness': 182.0,
          'outputForegroundPixels': 1100,
        },
      );
      addTearDown(
        () => messenger.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final result = await const OpenCvPageCorrector(channel: channel).correct(
        sourceImagePath: '/session/raw.jpg',
        outputImagePath: '/session/corrected.png',
        corners: const DocumentCorners(
          topLeft: DocumentPoint(0, 0),
          topRight: DocumentPoint(2500, 0),
          bottomRight: DocumentPoint(2500, 3500),
          bottomLeft: DocumentPoint(0, 3500),
        ),
        type: CorrectionType.perspective,
        boundaryMode: PageBoundaryMode.detected,
      );

      expect(result.outputFormat, 'png');
      expect(result.sourceQuality.width, 3024);
      expect(result.outputQuality.width, 2500);
      expect(result.outputQuality.foregroundSharpness, 182.0);
    });

    test(
      'persists native rejection reason and confidence diagnostics',
      () async {
        const channel = MethodChannel('test/page_corrector_diagnostics');
        final messenger = TestDefaultBinaryMessengerBinding.instance;
        messenger.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) => throw PlatformException(
            code: 'curve_insufficient_evidence',
            message: 'Stable page curvature was not found.',
            details: const <String, Object>{
              'rejectionReason': 'insufficient_evidence',
              'horizontalLineCount': 1,
              'evidenceCount': 1,
              'minimumEvidenceCount': 2,
              'minimumConfidence': 0.68,
            },
          ),
        );
        addTearDown(
          () => messenger.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        const corrector = OpenCvPageCorrector(channel: channel);
        try {
          await corrector.correct(
            sourceImagePath: '/session/perspective.jpg',
            outputImagePath: '/session/curved.jpg',
            corners: DocumentCorners(
              topLeft: DocumentPoint(0, 0),
              topRight: DocumentPoint(100, 0),
              bottomRight: DocumentPoint(100, 200),
              bottomLeft: DocumentPoint(0, 200),
            ),
            type: CorrectionType.curved,
            boundaryMode: PageBoundaryMode.detected,
          );
          fail('Expected curved correction to be rejected.');
        } on PageCorrectionFailure catch (failure) {
          expect(failure.reason, 'curve_insufficient_evidence');
          expect(
            failure.diagnostics['rejectionReason'],
            'insufficient_evidence',
          );
          expect(failure.diagnostics['horizontalLineCount'], 1);
          expect(failure.diagnostics['minimumConfidence'], 0.68);
        }
      },
    );

    test('calculates coverage, evidence, and consistency confidence', () {
      const components = CurvedConfidenceComponents(
        coverage: 0.8,
        candidateScore: 0.8,
        consistency: 0.9,
      );
      expect(components.confidence, closeTo(0.825, 0.0001));
      expect(components.meetsThreshold, isTrue);
      expect(
        const CurvedConfidenceComponents(
          coverage: 0.48,
          candidateScore: 0.4,
          consistency: 0.5,
        ).meetsThreshold,
        isFalse,
      );
    });

    test('requires curved output to preserve the perspective canvas', () {
      const perspective = PageCorrectionResult(
        outputWidth: 2000,
        outputHeight: 3000,
      );
      expect(
        CorrectionOutputSanity.preservesPerspectiveCanvas(
          perspective: perspective,
          curved: const PageCorrectionResult(
            outputWidth: 2000,
            outputHeight: 3000,
          ),
        ),
        isTrue,
      );
      expect(
        CorrectionOutputSanity.preservesPerspectiveCanvas(
          perspective: perspective,
          curved: const PageCorrectionResult(
            outputWidth: 2600,
            outputHeight: 3000,
          ),
        ),
        isFalse,
      );
    });

    test('accepts boundary, baseline, and composite signal evidence', () {
      expect(
        const CurvedSignalEvidence(boundaryCurves: 2).boundaryPreferred,
        isTrue,
      );
      expect(
        const CurvedSignalEvidence(baselineCurves: 2).hasSufficientSignals,
        isTrue,
      );
      expect(
        const CurvedSignalEvidence(
          boundaryCurves: 1,
          longHorizontalStructures: 1,
        ).hasSufficientSignals,
        isTrue,
      );
      expect(
        const CurvedSignalEvidence(baselineCurves: 1).hasSufficientSignals,
        isFalse,
      );
    });

    test('rejects degraded output and unsafe stretching', () {
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.6,
          maximumStretchFraction: 0.01,
        ),
        isFalse,
      );
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.82,
          maximumStretchFraction: 0.04,
        ),
        isFalse,
      );
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.82,
          maximumStretchFraction: 0.01,
        ),
        isTrue,
      );
    });

    test('classifies flat, mild, strong, and unreliable curvature', () {
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.0008,
          confidence: 0.75,
          coverage: 0.7,
          consistency: 0.8,
          evidenceCount: 3,
        ),
        CurvatureState.flat,
      );
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.004,
          confidence: 0.62,
          coverage: 0.65,
          consistency: 0.82,
          evidenceCount: 3,
        ),
        CurvatureState.mildCurve,
      );
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.012,
          confidence: 0.76,
          coverage: 0.78,
          consistency: 0.84,
          evidenceCount: 4,
        ),
        CurvatureState.strongCurve,
      );
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.004,
          confidence: 0.7,
          coverage: 0.7,
          consistency: 0.35,
          evidenceCount: 3,
        ),
        CurvatureState.unreliable,
      );
    });

    test('mild dewarp uses a conservative fixed strength', () {
      expect(AutomaticCurvaturePolicy.mildDewarpStrength, 0.55);
      expect(AutomaticCurvaturePolicy.mildDewarpStrength, lessThan(1));
    });

    test('measures normalized top and bottom contour curvature', () {
      final contour = _bookContour(topSag: 9, bottomSag: 12);
      const corners = DocumentCorners(
        topLeft: DocumentPoint(0, 20),
        topRight: DocumentPoint(1000, 20),
        bottomRight: DocumentPoint(1000, 1480),
        bottomLeft: DocumentPoint(0, 1480),
      );
      final boundary = PageContourGeometryEvidence.boundaryFromContour(
        contour: contour,
        corners: corners,
        sourceWidth: 1000,
        sourceHeight: 1500,
        spineSide: PageBoundarySide.left,
      );

      expect(boundary, isNotNull);
      final top = PageContourGeometryEvidence.measure(
        points: boundary!.top,
        start: corners.topLeft,
        end: corners.topRight,
        normalization: 1500,
      );
      final bottom = PageContourGeometryEvidence.measure(
        points: boundary.bottom,
        start: corners.bottomRight,
        end: corners.bottomLeft,
        normalization: 1500,
      );
      expect(top.magnitude, greaterThan(0.004));
      expect(bottom.magnitude, greaterThan(top.magnitude));
      expect(top.consistency, greaterThan(0.7));
      expect(bottom.consistency, greaterThan(0.7));
      expect(boundary.left.length, greaterThan(3));
    });

    test('reversed traversal and chord keep the rectified Y-axis sign', () {
      const start = DocumentPoint(0, 20);
      const end = DocumentPoint(1000, 20);
      final points = _horizontalCurve(y: 20, sag: 12);

      final forward = PageContourGeometryEvidence.measure(
        points: points,
        start: start,
        end: end,
        normalization: 1500,
      );
      final reversedTraversal = PageContourGeometryEvidence.measure(
        points: points.reversed.toList(),
        start: start,
        end: end,
        normalization: 1500,
      );
      final reversedChord = PageContourGeometryEvidence.measure(
        points: points,
        start: end,
        end: start,
        normalization: 1500,
      );

      expect(reversedTraversal.direction, forward.direction);
      expect(reversedChord.rawDirection, forward.rawDirection);
      expect(reversedChord.direction, forward.direction);
    });

    test('top and bottom share the rectified image Y-axis convention', () {
      final top = PageContourGeometryEvidence.measure(
        points: _horizontalCurve(y: 20, sag: 12),
        start: const DocumentPoint(0, 20),
        end: const DocumentPoint(1000, 20),
        normalization: 1500,
      );
      final bottom = PageContourGeometryEvidence.measure(
        points: _horizontalCurve(y: 1480, sag: 12),
        start: const DocumentPoint(1000, 1480),
        end: const DocumentPoint(0, 1480),
        normalization: 1500,
      );

      expect(top.rawDirection, 1);
      expect(bottom.rawDirection, 1);
      expect(top.direction, 1);
      expect(bottom.direction, 1);
    });

    test('internal lines keep the same rectified Y-axis sign everywhere', () {
      expect(
        PageContourGeometryEvidence.normalizeInternalDirection(rawDirection: 1),
        1,
      );
      expect(
        PageContourGeometryEvidence.normalizeInternalDirection(
          rawDirection: -1,
        ),
        -1,
      );
    });

    test('raw_001 and raw_002 common signs do not create fake conflict', () {
      for (final direction in const [1, -1]) {
        expect(
          PhysicalCurvatureDirectionPolicy.hasConflict(
            geometryDirections: [direction, direction],
            internalDirections: [direction],
          ),
          isFalse,
        );
        expect(
          AutomaticCurvaturePolicy.classify(
            magnitude: 0.004,
            confidence: 0.944,
            coverage: 1,
            consistency: 0.779,
            evidenceCount: 3,
            pageContourMagnitude: 0.035,
            internalLineMagnitude: 0.0028,
            geometryEvidenceCount: 2,
            internalEvidenceCount: 1,
            evidenceDirectionConsistency: 1,
            contourInternalAgree: true,
          ),
          CurvatureState.mildCurve,
        );
      }
    });

    test('spine direction is excluded while spine support is retained', () {
      expect(
        PhysicalCurvatureDirectionPolicy.hasConflict(
          geometryDirections: const [1, 1],
          internalDirections: const [1],
          spineDirection: -1,
        ),
        isFalse,
      );
      expect(
        const CurvedSignalEvidence(
          boundaryCurves: 1,
          spineBoundaries: 1,
        ).hasSufficientSignals,
        isTrue,
      );
    });

    test('only a physical direction conflict is rejected', () {
      expect(
        PhysicalCurvatureDirectionPolicy.hasConflict(
          geometryDirections: const [1, 1],
          internalDirections: const [-1],
        ),
        isFalse,
        reason: 'One cross-group mismatch is not stable conflict evidence.',
      );
      expect(
        PhysicalCurvatureDirectionPolicy.hasConflict(
          geometryDirections: const [1, 1],
          internalDirections: const [-1, -1],
        ),
        isTrue,
      );
      expect(
        PhysicalCurvatureDirectionPolicy.hasConflict(
          geometryDirections: const [1, -1],
          internalDirections: const [],
        ),
        isTrue,
      );
    });

    test('endpoint artifacts do not dominate contour magnitude', () {
      final points = _horizontalCurve(y: 20, sag: 6).toList();
      points[0] = const DocumentPoint(0, 220);
      points[1] = const DocumentPoint(50, 170);
      points[points.length - 2] = const DocumentPoint(950, 170);
      points[points.length - 1] = const DocumentPoint(1000, 220);

      final metric = PageContourGeometryEvidence.measure(
        points: points,
        start: const DocumentPoint(0, 20),
        end: const DocumentPoint(1000, 20),
        normalization: 1500,
      );

      expect(metric.magnitude, lessThan(0.01));
      expect(metric.direction, 1);
    });

    test('straight page contour remains flat', () {
      final contour = _bookContour(topSag: 0, bottomSag: 0);
      const corners = DocumentCorners(
        topLeft: DocumentPoint(0, 20),
        topRight: DocumentPoint(1000, 20),
        bottomRight: DocumentPoint(1000, 1480),
        bottomLeft: DocumentPoint(0, 1480),
      );
      final boundary = PageContourGeometryEvidence.boundaryFromContour(
        contour: contour,
        corners: corners,
        sourceWidth: 1000,
        sourceHeight: 1500,
      )!;
      final metric = PageContourGeometryEvidence.measure(
        points: boundary.top,
        start: corners.topLeft,
        end: corners.topRight,
        normalization: 1500,
      );
      expect(metric.magnitude, lessThan(0.0001));
      expect(metric.isCurved, isFalse);
    });

    test('page contour evidence promotes a consistent mild candidate', () {
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.004,
          confidence: 0.52,
          coverage: 0.64,
          consistency: 0.66,
          evidenceCount: 2,
          pageContourMagnitude: 0.0045,
          geometryEvidenceCount: 2,
          evidenceDirectionConsistency: 1,
        ),
        CurvatureState.mildCurve,
      );
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.0035,
          confidence: 0.53,
          coverage: 0.62,
          consistency: 0.65,
          evidenceCount: 2,
          pageContourMagnitude: 0.004,
          internalLineMagnitude: 0.002,
          geometryEvidenceCount: 1,
          internalEvidenceCount: 1,
          evidenceDirectionConsistency: 1,
          contourInternalAgree: true,
        ),
        CurvatureState.mildCurve,
      );
    });

    test('raw_001 type uses internal evidence for effective deformation', () {
      final profile = EffectiveDeformationPolicy.profileMagnitude(
        pageContourMagnitude: 0.03521,
        internalLineMagnitude: 0.002793,
        internalEvidenceCount: 1,
      );
      final effective = EffectiveDeformationPolicy.effectiveMagnitude(
        profileMagnitude: profile,
        state: CurvatureState.mildCurve,
      );

      expect(profile, closeTo(0.002793, 0.0000001));
      expect(effective, closeTo(0.00153615, 0.0000001));
      expect(EffectiveDeformationPolicy.isExcessive(effective), isFalse);
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: profile,
          confidence: 0.944812,
          coverage: 1,
          consistency: 0.77925,
          evidenceCount: 3,
          pageContourMagnitude: 0.03521,
          internalLineMagnitude: 0.002793,
          geometryEvidenceCount: 2,
          internalEvidenceCount: 1,
          evidenceDirectionConsistency: 2 / 3,
        ),
        CurvatureState.mildCurve,
      );
    });

    test('raw_003 type clamps contour-only deformation before safety', () {
      final profile = EffectiveDeformationPolicy.profileMagnitude(
        pageContourMagnitude: 0.078513,
        internalLineMagnitude: 0,
        internalEvidenceCount: 0,
      );
      final effective = EffectiveDeformationPolicy.effectiveMagnitude(
        profileMagnitude: profile,
        state: CurvatureState.mildCurve,
      );

      expect(
        profile,
        EffectiveDeformationPolicy.contourOnlyMildMaximumFraction,
      );
      expect(effective, closeTo(0.0033, 0.0000001));
      expect(EffectiveDeformationPolicy.isExcessive(effective), isFalse);
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: profile,
          confidence: 0.955635,
          coverage: 1,
          consistency: 0.822539,
          evidenceCount: 5,
          pageContourMagnitude: 0.078513,
          geometryEvidenceCount: 2,
          evidenceDirectionConsistency: 1,
        ),
        CurvatureState.mildCurve,
      );
      expect(
        EffectiveDeformationPolicy.isExcessive(0.078513),
        isTrue,
        reason: 'Only an actual remap of this size is excessive.',
      );
    });

    test('strong deformation remains driven by the internal profile', () {
      final profile = EffectiveDeformationPolicy.profileMagnitude(
        pageContourMagnitude: 0.06,
        internalLineMagnitude: 0.012,
        internalEvidenceCount: 3,
      );
      expect(profile, 0.012);
      expect(
        EffectiveDeformationPolicy.effectiveMagnitude(
          profileMagnitude: profile,
          state: CurvatureState.strongCurve,
        ),
        0.012,
      );
    });

    test('flat contour noise does not create effective deformation', () {
      final profile = EffectiveDeformationPolicy.profileMagnitude(
        pageContourMagnitude: 0.0008,
        internalLineMagnitude: 0,
        internalEvidenceCount: 0,
      );
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: profile,
          confidence: 0.9,
          coverage: 0.8,
          consistency: 0.9,
          evidenceCount: 3,
          pageContourMagnitude: 0.0008,
        ),
        CurvatureState.flat,
      );
      expect(
        EffectiveDeformationPolicy.effectiveMagnitude(
          profileMagnitude: profile,
          state: CurvatureState.flat,
        ),
        0,
      );
    });

    test('conflicting contour and internal evidence stays unreliable', () {
      expect(
        AutomaticCurvaturePolicy.classify(
          magnitude: 0.006,
          confidence: 0.72,
          coverage: 0.75,
          consistency: 0.78,
          evidenceCount: 4,
          pageContourMagnitude: 0.006,
          internalLineMagnitude: 0.005,
          geometryEvidenceCount: 2,
          internalEvidenceCount: 2,
          evidenceDirectionConsistency: 0.5,
          evidenceConflict: true,
        ),
        CurvatureState.unreliable,
      );
    });

    test('mild validation accepts geometry gain but rejects no gain', () {
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.8,
          maximumStretchFraction: 0.01,
          state: CurvatureState.mildCurve,
          geometryBefore: 0.004,
          geometryAfter: 0.0018,
        ),
        isTrue,
      );
      expect(
        CurvedResultQuality.shouldAdopt(
          perspectiveStraightness: 0.8,
          curvedStraightness: 0.8,
          maximumStretchFraction: 0.01,
          state: CurvatureState.mildCurve,
          geometryBefore: 0.004,
          geometryAfter: 0.004,
        ),
        isFalse,
      );
    });
  });
}

List<DocumentPoint> _bookContour({
  required double topSag,
  required double bottomSag,
}) {
  final points = <DocumentPoint>[];
  for (var index = 0; index <= 20; index++) {
    final t = index / 20;
    points.add(DocumentPoint(1000 * t, 20 + topSag * 4 * t * (1 - t)));
  }
  for (var index = 1; index <= 20; index++) {
    final t = index / 20;
    points.add(DocumentPoint(1000, 20 + 1460 * t));
  }
  for (var index = 1; index <= 20; index++) {
    final t = index / 20;
    points.add(
      DocumentPoint(1000 * (1 - t), 1480 - bottomSag * 4 * t * (1 - t)),
    );
  }
  for (var index = 1; index < 20; index++) {
    final t = index / 20;
    points.add(DocumentPoint(0, 1480 - 1460 * t));
  }
  return points;
}

List<DocumentPoint> _horizontalCurve({
  required double y,
  required double sag,
}) => List.generate(21, (index) {
  final t = index / 20;
  return DocumentPoint(1000 * t, y + sag * 4 * t * (1 - t));
});
