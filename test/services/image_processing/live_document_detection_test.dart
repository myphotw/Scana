import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/services/image_processing/live_document_detection.dart';

void main() {
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
}

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
