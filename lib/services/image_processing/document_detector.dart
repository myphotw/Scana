import 'package:flutter/services.dart';

import 'package:scana/models/document_detection_result.dart';

/// Detects a document in a still image without depending on camera UI.
abstract interface class DocumentDetector {
  Future<DocumentDetectionResult> detect(String imagePath);
}

class OpenCvDocumentDetector implements DocumentDetector {
  const OpenCvDocumentDetector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.myphotw.scana/document_detector';
  final MethodChannel _channel;

  @override
  Future<DocumentDetectionResult> detect(String imagePath) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'detectDocument',
      {'imagePath': imagePath},
    );
    if (value == null) {
      throw const FormatException('Document detector returned no result.');
    }

    final sourceWidth = value['sourceWidth'];
    final sourceHeight = value['sourceHeight'];
    final confidence = value['confidence'];
    final detected = value['detected'];
    if (sourceWidth is! int ||
        sourceHeight is! int ||
        confidence is! num ||
        detected is! bool) {
      throw const FormatException('Document detector returned invalid data.');
    }

    final corners = _cornersFromNative(value['corners']);
    return DocumentDetectionResult(
      detected: detected && corners != null,
      corners: corners,
      confidence: confidence.toDouble().clamp(0.0, 1.0).toDouble(),
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
  }

  static DocumentCorners? _cornersFromNative(Object? value) {
    if (value is! List || value.length != 4) {
      return null;
    }
    final points = value.map(DocumentPoint.fromJson).toList();
    if (points.any((point) => point == null)) {
      return null;
    }
    return DocumentCorners(
      topLeft: points[0]!,
      topRight: points[1]!,
      bottomRight: points[2]!,
      bottomLeft: points[3]!,
    );
  }
}

/// Used in tests and non-Android shells; a failed detection is a valid state.
class NoOpDocumentDetector implements DocumentDetector {
  const NoOpDocumentDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) async {
    return const DocumentDetectionResult(
      detected: false,
      confidence: 0,
      sourceWidth: 0,
      sourceHeight: 0,
    );
  }
}
