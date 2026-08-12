import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/live_document_detection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final frame = PreviewLuminanceFrame(
    bytes: Uint8List(0),
    width: 100,
    height: 200,
    rowStride: 100,
  );

  test(
    'prevents duplicate analysis while native detection is running',
    () async {
      final detector = _CompletingDetector();
      final controller = LiveDocumentDetectionController(
        detector: detector,
        analysisInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      final first = controller.submit(frame);
      expect(await controller.submit(frame), isFalse);
      expect(detector.calls, 1);
      detector.completer.complete(_result());
      expect(await first, isTrue);
    },
  );

  test('stabilizes, smooths, retains, then expires document corners', () {
    final stabilizer = DocumentCornerStabilizer();
    final start = DateTime.utc(2026, 8, 10);

    stabilizer.update(_result(left: 10), start);
    stabilizer.update(
      _result(left: 11),
      start.add(const Duration(milliseconds: 100)),
    );
    stabilizer.update(
      _result(left: 12),
      start.add(const Duration(milliseconds: 200)),
    );
    expect(stabilizer.isStable, isTrue);
    final before = stabilizer.stableNormalizedCorners!.topLeft.x;

    stabilizer.update(
      _result(left: 16),
      start.add(const Duration(milliseconds: 300)),
    );
    final smoothed = stabilizer.stableNormalizedCorners!.topLeft.x;
    expect(smoothed, greaterThan(before));
    expect(smoothed, lessThan(0.16));

    stabilizer.update(
      _result(confidence: 0.1),
      start.add(const Duration(milliseconds: 850)),
    );
    expect(stabilizer.isStable, isTrue);
    stabilizer.update(
      _result(confidence: 0.1),
      start.add(const Duration(milliseconds: 1100)),
    );
    expect(stabilizer.isStable, isFalse);
  });

  test('maps stable preview corners into upright still coordinates', () {
    const landscape = DocumentCorners(
      topLeft: DocumentPoint(0.1, 0.2),
      topRight: DocumentPoint(0.9, 0.2),
      bottomRight: DocumentPoint(0.9, 0.8),
      bottomLeft: DocumentPoint(0.1, 0.8),
    );

    final upright = PreviewCornerMapper.toUpright(landscape, 90);

    expect(upright.topLeft.x, closeTo(0.2, 0.0001));
    expect(upright.topLeft.y, closeTo(0.1, 0.0001));
    expect(upright.bottomRight.x, closeTo(0.8, 0.0001));
    expect(upright.bottomRight.y, closeTo(0.9, 0.0001));
  });

  test('maps all boundary edges into upright order', () {
    final boundary = PageBoundary.fromCorners(
      const DocumentCorners(
        topLeft: DocumentPoint(0.1, 0.2),
        topRight: DocumentPoint(0.9, 0.2),
        bottomRight: DocumentPoint(0.9, 0.8),
        bottomLeft: DocumentPoint(0.1, 0.8),
      ),
      sourceWidth: 1,
      sourceHeight: 1,
      confidence: 0.9,
      stability: 1,
      timestamp: DateTime.utc(2026, 8, 10),
    );

    final upright = PreviewCornerMapper.boundaryToUpright(boundary, 90);

    expect(upright.top.first.x, closeTo(0.2, 0.0001));
    expect(upright.top.last.x, closeTo(0.8, 0.0001));
    expect(upright.right.first.y, closeTo(0.1, 0.0001));
    expect(upright.right.last.y, closeTo(0.9, 0.0001));
  });

  test(
    'detected unstable boundary stays visible before stabilization',
    () async {
      final controller = LiveDocumentDetectionController(
        detector: _ImmediateDetector(_result(confidence: 0.3)),
        boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
        analysisInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.submit(frame);

      expect(controller.lastDetected, isTrue);
      expect(controller.visibleNormalizedBoundary, isNotNull);
      expect(controller.hasStableDocument, isFalse);
    },
  );

  test(
    'low confidence best candidate remains visible in orange level',
    () async {
      final controller = LiveDocumentDetectionController(
        detector: _ImmediateDetector(_result(confidence: 0.12)),
        boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
        analysisInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.submit(frame);

      expect(controller.visibleNormalizedBoundary, isNotNull);
      expect(controller.hasStableDocument, isFalse);
      expect(controller.displayLevel, LiveGuideDisplayLevel.low);
    },
  );

  test(
    'normal-distance medium candidate is displayed without stability',
    () async {
      final controller = LiveDocumentDetectionController(
        detector: _ImmediateDetector(_result(left: 20, confidence: 0.34)),
        boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.45),
        analysisInterval: Duration.zero,
      );
      addTearDown(controller.dispose);

      await controller.submit(frame);

      expect(controller.visibleNormalizedBoundary, isNotNull);
      expect(controller.displayLevel, LiveGuideDisplayLevel.medium);
    },
  );

  test('live guide maps confidence and stability to display levels', () {
    expect(
      LiveGuidePolicy.levelFor(
        candidateAvailable: false,
        confidence: 1,
        stable: true,
      ),
      LiveGuideDisplayLevel.none,
    );
    expect(
      LiveGuidePolicy.levelFor(
        candidateAvailable: true,
        confidence: 0.12,
        stable: false,
      ),
      LiveGuideDisplayLevel.low,
    );
    expect(
      LiveGuidePolicy.levelFor(
        candidateAvailable: true,
        confidence: 0.34,
        stable: false,
      ),
      LiveGuideDisplayLevel.medium,
    );
    expect(
      LiveGuidePolicy.levelFor(
        candidateAvailable: true,
        confidence: 0.7,
        stable: true,
      ),
      LiveGuideDisplayLevel.stable,
    );
  });

  test('three matching boundaries become strongly stable', () async {
    final controller = LiveDocumentDetectionController(
      detector: _ImmediateDetector(_result(confidence: 0.7)),
      boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
      analysisInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.submit(frame);
    await controller.submit(frame);
    await controller.submit(frame);

    expect(controller.hasStableDocument, isTrue);
    expect(controller.stableNormalizedBoundary, isNotNull);
  });

  test('spread left-only candidate remains independently visible', () async {
    final left = _controller(_result(confidence: 0.3));
    final right = _controller(_result(confidence: 0));
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    await Future.wait([left.submit(frame), right.submit(frame)]);

    expect(left.visibleNormalizedBoundary, isNotNull);
    expect(right.visibleNormalizedBoundary, isNull);
  });

  test('spread right-only candidate remains independently visible', () async {
    final left = _controller(_result(confidence: 0));
    final right = _controller(_result(confidence: 0.3));
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    await Future.wait([left.submit(frame), right.submit(frame)]);

    expect(left.visibleNormalizedBoundary, isNull);
    expect(right.visibleNormalizedBoundary, isNotNull);
  });

  test('spread both candidates remain independently visible', () async {
    final left = _controller(_result(left: 8, confidence: 0.3));
    final right = _controller(_result(left: 52, confidence: 0.32));
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    await Future.wait([left.submit(frame), right.submit(frame)]);

    expect(left.visibleNormalizedBoundary, isNotNull);
    expect(right.visibleNormalizedBoundary, isNotNull);
  });

  test(
    'spread preview sends side and rotation and keeps full-frame points',
    () async {
      const channel = MethodChannel('test/spread-preview');
      MethodCall? call;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (value) async {
            call = value;
            return _nativeBoundaryResult();
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const detector = OpenCvPreviewDocumentDetector(channel: channel);

      final result = await detector.detectForPage(
        frame,
        pageSide: DocumentPageSide.right,
        sensorOrientation: 180,
      );

      expect(call?.method, 'detectPreviewFrame');
      expect((call?.arguments as Map)['pageSide'], 'right');
      expect((call?.arguments as Map)['sensorOrientation'], 180);
      expect(result.boundary!.top.first.x, 45);
      expect(result.boundary!.sourceWidth, 100);
    },
  );
}

LiveDocumentDetectionController _controller(DocumentDetectionResult result) =>
    LiveDocumentDetectionController(
      detector: _ImmediateDetector(result),
      boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.45),
      analysisInterval: Duration.zero,
    );

Map<String, Object> _nativeBoundaryResult() => {
  'detected': true,
  'confidence': 0.7,
  'sourceWidth': 100,
  'sourceHeight': 200,
  'corners': [
    {'x': 45.0, 'y': 20.0},
    {'x': 95.0, 'y': 20.0},
    {'x': 95.0, 'y': 180.0},
    {'x': 45.0, 'y': 180.0},
  ],
  'boundary': {
    'top': [
      {'x': 45.0, 'y': 20.0},
      {'x': 95.0, 'y': 20.0},
    ],
    'right': [
      {'x': 95.0, 'y': 20.0},
      {'x': 95.0, 'y': 180.0},
    ],
    'bottom': [
      {'x': 95.0, 'y': 180.0},
      {'x': 45.0, 'y': 180.0},
    ],
    'left': [
      {'x': 45.0, 'y': 180.0},
      {'x': 45.0, 'y': 20.0},
    ],
    'confidence': 0.7,
    'stability': 0.0,
    'sourceWidth': 100,
    'sourceHeight': 200,
    'timestamp': DateTime.utc(2026, 8, 11).millisecondsSinceEpoch,
  },
};

DocumentDetectionResult _result({double left = 10, double confidence = 0.9}) {
  return DocumentDetectionResult(
    detected: confidence > 0,
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
}

class _CompletingDetector implements PreviewDocumentDetector {
  final completer = Completer<DocumentDetectionResult>();
  int calls = 0;

  @override
  Future<DocumentDetectionResult> detect(PreviewLuminanceFrame frame) {
    calls++;
    return completer.future;
  }
}

class _ImmediateDetector implements PreviewDocumentDetector {
  _ImmediateDetector(this.result);

  final DocumentDetectionResult result;

  @override
  Future<DocumentDetectionResult> detect(PreviewLuminanceFrame frame) async =>
      result;
}
