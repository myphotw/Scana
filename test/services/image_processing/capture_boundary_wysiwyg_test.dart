import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/models/capture_boundary_snapshot.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/image_processing/capture_boundary_mapper.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/live_document_detection.dart';
import 'package:scana/services/image_processing/page_crop_decision.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Capture Snapshot', () {
    test('shutter freezes the currently displayed live boundary', () async {
      final controller = _controller([_liveResult(left: 10)]);
      addTearDown(controller.dispose);
      await controller.submit(_frame);

      final snapshot = _freeze(controller);

      expect(snapshot, isNotNull);
      expect(snapshot!.boundary.top.first.x, closeTo(10, 0.001));
      expect(snapshot.sourceFrameWidth, 100);
      expect(snapshot.sourceFrameHeight, 200);
    });

    test('next live frame cannot mutate an existing snapshot', () async {
      final controller = _controller([
        _liveResult(left: 10),
        _liveResult(left: 24),
      ]);
      addTearDown(controller.dispose);
      await controller.submit(_frame);
      final snapshot = _freeze(controller)!;

      await controller.submit(_frame);

      expect(snapshot.boundary.top.first.x, closeTo(10, 0.001));
      expect(controller.visibleNormalizedBoundary!.top.first.x, isNot(0.1));
    });

    test('continuous captures own independent snapshots', () async {
      final controller = _controller([
        _liveResult(left: 10),
        _liveResult(left: 20),
      ]);
      addTearDown(controller.dispose);
      await controller.submit(_frame);
      final first = _freeze(controller)!;
      await controller.submit(_frame);
      final second = _freeze(controller)!;

      expect(first.boundary.top.first.x, isNot(second.boundary.top.first.x));
      expect(first.timestamp, isNot(second.timestamp));
    });

    test('missing live boundary creates no snapshot and keeps fallback', () {
      final controller = _controller([]);
      addTearDown(controller.dispose);

      expect(_freeze(controller), isNull);
      expect(
        _decide(includeCapture: false).source,
        CropSource.highResPaperBoundary,
      );
    });
  });

  group('Coordinate', () {
    test('portrait analysis maps directly into portrait JPEG coordinates', () {
      final mapped = CaptureBoundaryMapper.toJpegBoundary(
        _snapshot(rotation: 90),
        jpegWidth: 1000,
        jpegHeight: 2000,
      )!;

      expect(mapped.toDocumentCorners().topLeft.x, closeTo(200, 0.01));
      expect(mapped.toDocumentCorners().topLeft.y, closeTo(200, 0.01));
      expect(mapped.toDocumentCorners().bottomRight.x, closeTo(800, 0.01));
      expect(mapped.toDocumentCorners().bottomRight.y, closeTo(1800, 0.01));
    });

    test(
      'landscape analysis maps directly into landscape JPEG coordinates',
      () {
        final mapped = CaptureBoundaryMapper.toJpegBoundary(
          _snapshot(rotation: 0),
          jpegWidth: 2000,
          jpegHeight: 1000,
        )!;

        expect(mapped.toDocumentCorners().topLeft.x, closeTo(200, 0.01));
        expect(mapped.toDocumentCorners().topLeft.y, closeTo(200, 0.01));
        expect(mapped.toDocumentCorners().bottomRight.x, closeTo(1800, 0.01));
        expect(mapped.toDocumentCorners().bottomRight.y, closeTo(800, 0.01));
      },
    );

    test('rotation 90 preserves clockwise corner order', () {
      final mapped = CaptureBoundaryMapper.toJpegBoundary(
        _snapshot(rotation: 90),
        jpegWidth: 1000,
        jpegHeight: 2000,
      )!;
      expect(mapped.isValid, isTrue);
      expect(mapped.toDocumentCorners().topLeft.x, lessThan(500));
    });

    test('rotation 270 preserves clockwise corner order', () {
      final mapped = CaptureBoundaryMapper.toJpegBoundary(
        _snapshot(rotation: 270),
        jpegWidth: 1000,
        jpegHeight: 2000,
      )!;
      expect(mapped.isValid, isTrue);
      expect(mapped.toDocumentCorners().topLeft.x, closeTo(200, 0.01));
    });

    test('Spread left full-frame snapshot maps once into left JPEG ROI', () {
      final mapped = CaptureBoundaryMapper.toJpegBoundary(
        _snapshot(
          rotation: 0,
          left: 0.05,
          right: 0.50,
          side: CaptureBoundarySide.left,
        ),
        jpegWidth: 1100,
        jpegHeight: 1200,
        pageSide: DocumentPageSide.left,
      )!;
      expect(mapped.toDocumentCorners().topLeft.x, closeTo(100, 0.01));
      expect(mapped.toDocumentCorners().topRight.x, closeTo(1000, 0.01));
    });

    test('Spread right full-frame snapshot maps once into right JPEG ROI', () {
      final mapped = CaptureBoundaryMapper.toJpegBoundary(
        _snapshot(
          rotation: 0,
          left: 0.50,
          right: 0.95,
          side: CaptureBoundarySide.right,
        ),
        jpegWidth: 1100,
        jpegHeight: 1200,
        pageSide: DocumentPageSide.right,
      )!;
      expect(mapped.toDocumentCorners().topLeft.x, closeTo(100, 0.01));
      expect(mapped.toDocumentCorners().topRight.x, closeTo(1000, 0.01));
    });
  });

  group('Policy', () {
    test('sane displayed live boundary becomes captureLiveBoundary', () {
      expect(_decide().source, CropSource.captureLiveBoundary);
    });

    test('unsafe live boundary falls through to high-resolution paper', () {
      expect(
        _decide(capture: _pixelBoundary(left: 420, right: 580)).source,
        CropSource.highResPaperBoundary,
      );
    });

    test('high-resolution failure falls through to content safe', () {
      expect(
        _decide(detection: _contentDetection(), includeCapture: false).source,
        CropSource.contentSafe,
      );
    });

    test('content failure falls through to guide', () {
      expect(
        _decide(detection: _emptyDetection(), includeCapture: false).source,
        CropSource.guideFallback,
      );
    });

    test('Spread left and right select crop sources independently', () {
      final left = _decide(pageSide: DocumentPageSide.left);
      final right = _decide(
        pageSide: DocumentPageSide.right,
        includeCapture: false,
        detection: _contentDetection(),
      );
      expect(left.source, CropSource.captureLiveBoundary);
      expect(right.source, CropSource.contentSafe);
    });
  });

  group('Refinement', () {
    test('small high-resolution refinement is accepted', () {
      final result = CaptureBoundaryRefinementPolicy.refine(
        captureBoundary: _pixelBoundary(),
        highResBoundary: _pixelBoundary(
          left: 105,
          top: 105,
          right: 895,
          bottom: 1395,
        ),
      );
      expect(result.accepted, isTrue);
    });

    test('large inward movement is rejected', () {
      final result = CaptureBoundaryRefinementPolicy.refine(
        captureBoundary: _pixelBoundary(),
        highResBoundary: _pixelBoundary(
          left: 180,
          top: 180,
          right: 820,
          bottom: 1320,
        ),
      );
      expect(result.accepted, isFalse);
    });

    test('narrow crop refinement is rejected', () {
      final result = CaptureBoundaryRefinementPolicy.refine(
        captureBoundary: _pixelBoundary(),
        highResBoundary: _pixelBoundary(left: 350, right: 650),
      );
      expect(result.accepted, isFalse);
    });

    test('excessive corner delta is rejected', () {
      final result = CaptureBoundaryRefinementPolicy.refine(
        captureBoundary: _pixelBoundary(),
        highResBoundary: _pixelBoundary(
          left: 30,
          top: 250,
          right: 970,
          bottom: 1250,
        ),
      );
      expect(result.rejectedReason, 'excessive_corner_delta');
    });

    test('minor outward refinement is accepted', () {
      final result = CaptureBoundaryRefinementPolicy.refine(
        captureBoundary: _pixelBoundary(),
        highResBoundary: _pixelBoundary(
          left: 90,
          top: 90,
          right: 910,
          bottom: 1410,
        ),
      );
      expect(result.accepted, isTrue);
    });
  });

  group('WYSIWYG', () {
    test('final crop area remains close to displayed live area', () {
      final decision = _decide();
      final difference = (decision.areaRatioFinal - decision.areaRatioCapture)
          .abs();
      expect(difference, lessThan(0.04));
    });

    test('accepted final corner delta remains within tolerance', () {
      expect(_decide().cornerDeltaPercent, lessThanOrEqualTo(5));
    });

    test('different high-resolution candidate cannot replace sane live', () {
      final decision = _decide(
        detection: _paperDetection(
          boundary: _pixelBoundary(
            left: 250,
            top: 250,
            right: 750,
            bottom: 1250,
          ),
        ),
      );
      expect(decision.source, CropSource.captureLiveBoundary);
      expect(decision.corners.topLeft.x, 100);
    });

    test('displayed stable boundary uses the same capture source', () async {
      final controller = _controller(
        List.filled(3, _liveResult(left: 10, confidence: 0.8)),
      );
      addTearDown(controller.dispose);
      await controller.submit(_frame);
      await controller.submit(_frame);
      await controller.submit(_frame);
      final snapshot = _freeze(controller)!;
      final jpeg = CaptureBoundaryMapper.toJpegBoundary(
        snapshot,
        jpegWidth: 1000,
        jpegHeight: 1500,
      );

      expect(controller.displayLevel, LiveGuideDisplayLevel.stable);
      expect(_decide(capture: jpeg).source, CropSource.captureLiveBoundary);
    });
  });

  group('Persistence', () {
    late Directory root;
    late AppPrivateSessionStorage storage;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('scana_q13_');
      storage = AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => root,
      );
    });
    tearDown(() async => root.delete(recursive: true));

    test('session without cropSource remains backward compatible', () async {
      await _writeLegacySession(root, id: 'missing-source');
      final page =
          (await storage.findRecoverableSessions()).single.pages.single;
      expect(page.cropSource, isNull);
    });

    test(
      'captureLiveBoundary and capture evidence survive serialization',
      () async {
        final session = ScanSession(id: 'capture-source', createdTime: _time);
        await storage.createSession(session.id);
        final raw = File(
          path.join(root.path, 'scan_sessions', session.id, 'raw_001.jpg'),
        );
        await raw.writeAsBytes([1]);
        session.addPage(
          ScanPage(
            pageNo: 1,
            rawImagePath: raw.path,
            createdTime: _time,
            cropSource: CropSource.captureLiveBoundary,
            captureBoundaryConfidence: 0.64,
            captureBoundaryStability: 0.8,
          ),
        );
        await storage.saveSession(session);

        final page =
            (await storage.findRecoverableSessions()).single.pages.single;
        expect(page.cropSource, CropSource.captureLiveBoundary);
        expect(page.captureBoundaryConfidence, 0.64);
        expect(page.captureBoundaryStability, 0.8);
      },
    );

    test('old stableLiveFallback session recovers unchanged', () async {
      await _writeLegacySession(
        root,
        id: 'stable-live',
        cropSource: 'stableLiveFallback',
      );
      final page =
          (await storage.findRecoverableSessions()).single.pages.single;
      expect(page.cropSource, CropSource.stableLiveFallback);
    });
  });
}

final _frame = PreviewLuminanceFrame(
  bytes: Uint8List(0),
  width: 100,
  height: 200,
  rowStride: 100,
);
final _time = DateTime.utc(2026, 8, 12, 12);

LiveDocumentDetectionController _controller(
  List<DocumentDetectionResult> results,
) => LiveDocumentDetectionController(
  detector: _SequenceDetector(results),
  boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
  analysisInterval: Duration.zero,
  clock: _TickingClock().call,
);

CaptureBoundarySnapshot? _freeze(LiveDocumentDetectionController controller) =>
    controller.freezeCaptureBoundary(
      captureMode: ScanCaptureMode.single,
      side: CaptureBoundarySide.single,
      sensorOrientation: 90,
      deviceOrientationDegrees: 0,
      jpegRotationDegrees: 0,
      mirrored: false,
    );

DocumentDetectionResult _liveResult({
  double left = 10,
  double confidence = 0.34,
}) => DocumentDetectionResult(
  detected: true,
  confidence: confidence,
  sourceWidth: 100,
  sourceHeight: 200,
  corners: DocumentCorners(
    topLeft: DocumentPoint(left, 20),
    topRight: const DocumentPoint(90, 20),
    bottomRight: const DocumentPoint(90, 180),
    bottomLeft: DocumentPoint(left, 180),
  ),
);

CaptureBoundarySnapshot _snapshot({
  required int rotation,
  double left = 0.1,
  double right = 0.9,
  CaptureBoundarySide side = CaptureBoundarySide.single,
}) {
  final boundary = _normalizedBoundary(
    left: left,
    right: right,
  ).scaleTo(200, 100);
  return CaptureBoundarySnapshot(
    captureMode: side == CaptureBoundarySide.single
        ? ScanCaptureMode.single
        : ScanCaptureMode.spread,
    timestamp: _time,
    sourceFrameWidth: 200,
    sourceFrameHeight: 100,
    sensorOrientation: 90,
    deviceOrientationDegrees: rotation == 0 ? 90 : 0,
    jpegRotationDegrees: rotation,
    mirrored: false,
    boundary: boundary,
    confidence: 0.7,
    stability: 1,
    side: side,
  );
}

PageCropDecision _decide({
  DocumentDetectionResult? detection,
  PageBoundary? capture,
  DocumentPageSide? pageSide,
  bool includeCapture = true,
}) => PageCropDecisionPolicy.decide(
  detection: detection ?? _paperDetection(),
  captureBoundary: includeCapture ? capture ?? _pixelBoundary() : null,
  guideCorners: _guide,
  pageSide: pageSide,
)!;

DocumentDetectionResult _paperDetection({PageBoundary? boundary}) {
  final value =
      boundary ?? _pixelBoundary(left: 105, top: 105, right: 895, bottom: 1395);
  return DocumentDetectionResult(
    detected: true,
    confidence: 0.85,
    sourceWidth: 1000,
    sourceHeight: 1500,
    corners: value.toDocumentCorners(),
    boundary: value,
  );
}

DocumentDetectionResult _contentDetection() => DocumentDetectionResult(
  detected: false,
  confidence: 0,
  sourceWidth: 1000,
  sourceHeight: 1500,
  contentSafeCorners: _corners(left: 80, top: 90, right: 920, bottom: 1410),
  contentSafeConfidence: 0.7,
  contentComponentCount: 40,
);

const _guide = DocumentCorners(
  topLeft: DocumentPoint(120, 120),
  topRight: DocumentPoint(880, 120),
  bottomRight: DocumentPoint(880, 1380),
  bottomLeft: DocumentPoint(120, 1380),
);

DocumentDetectionResult _emptyDetection() => const DocumentDetectionResult(
  detected: false,
  confidence: 0,
  sourceWidth: 1000,
  sourceHeight: 1500,
);

PageBoundary _pixelBoundary({
  double left = 100,
  double top = 100,
  double right = 900,
  double bottom = 1400,
}) => PageBoundary.fromCorners(
  _corners(left: left, top: top, right: right, bottom: bottom),
  sourceWidth: 1000,
  sourceHeight: 1500,
  confidence: 0.7,
  stability: 1,
  timestamp: _time,
);

PageBoundary _normalizedBoundary({
  double left = 0.1,
  double top = 0.2,
  double right = 0.9,
  double bottom = 0.8,
}) => PageBoundary.fromCorners(
  _corners(left: left, top: top, right: right, bottom: bottom),
  sourceWidth: 1,
  sourceHeight: 1,
  confidence: 0.7,
  stability: 1,
  timestamp: _time,
);

DocumentCorners _corners({
  required double left,
  required double top,
  required double right,
  required double bottom,
}) => DocumentCorners(
  topLeft: DocumentPoint(left, top),
  topRight: DocumentPoint(right, top),
  bottomRight: DocumentPoint(right, bottom),
  bottomLeft: DocumentPoint(left, bottom),
);

Future<void> _writeLegacySession(
  Directory root, {
  required String id,
  String? cropSource,
}) async {
  final directory = Directory(path.join(root.path, 'scan_sessions', id));
  await directory.create(recursive: true);
  await File(path.join(directory.path, 'raw_001.jpg')).writeAsBytes([1]);
  await File(path.join(directory.path, 'session.json')).writeAsString(
    jsonEncode({
      'id': id,
      'createdTime': _time.toIso8601String(),
      'pages': [
        {
          'pageNo': 1,
          'rawImageFile': 'raw_001.jpg',
          'createdTime': _time.toIso8601String(),
          'rotation': 0,
          'cropSource': ?cropSource,
        },
      ],
    }),
  );
}

class _SequenceDetector implements PreviewDocumentDetector {
  _SequenceDetector(this.results);
  final List<DocumentDetectionResult> results;
  int index = 0;

  @override
  Future<DocumentDetectionResult> detect(PreviewLuminanceFrame frame) async {
    if (results.isEmpty) return _emptyDetection();
    return results[index++ % results.length];
  }
}

class _TickingClock {
  var tick = 0;
  DateTime call() => _time.add(Duration(milliseconds: tick++ * 100));
}
