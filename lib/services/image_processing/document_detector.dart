import 'package:flutter/services.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';

/// Detects a document in a still image without depending on camera UI.
abstract interface class DocumentDetector {
  Future<DocumentDetectionResult> detect(String imagePath);
}

/// Optional ROI role supplied by the two-page capture flow.
enum DocumentPageSide { left, right }

abstract interface class SpreadAwareDocumentDetector
    implements DocumentDetector {
  Future<DocumentDetectionResult> detectForPage(
    String imagePath, {
    required DocumentPageSide pageSide,
  });
}

class OpenCvDocumentDetector implements SpreadAwareDocumentDetector {
  const OpenCvDocumentDetector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.myphotw.scana/document_detector';
  final MethodChannel _channel;

  @override
  Future<DocumentDetectionResult> detect(String imagePath) =>
      _detect(imagePath);

  @override
  Future<DocumentDetectionResult> detectForPage(
    String imagePath, {
    required DocumentPageSide pageSide,
  }) => _detect(imagePath, pageSide: pageSide);

  Future<DocumentDetectionResult> _detect(
    String imagePath, {
    DocumentPageSide? pageSide,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'detectDocument',
      {'imagePath': imagePath, if (pageSide != null) 'pageSide': pageSide.name},
    );
    if (value == null) {
      throw const FormatException('Document detector returned no result.');
    }

    return documentDetectionResultFromNative(value);
  }
}

DocumentDetectionResult documentDetectionResultFromNative(
  Map<String, dynamic> value,
) {
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
  final boundary = PageBoundary.fromJson(value['boundary']);
  final contentSafeCorners = _cornersFromNative(value['contentSafeCorners']);
  final contentBounds = _cornersFromNative(value['contentBounds']);
  return DocumentDetectionResult(
    detected: detected && (corners != null || boundary != null),
    corners: corners,
    boundary: boundary,
    contentSafeCorners: contentSafeCorners,
    contentBounds: contentBounds,
    contentSafeConfidence:
        (value['contentSafeConfidence'] as num?)?.toDouble().clamp(0, 1) ?? 0,
    contentComponentCount: value['contentComponentCount'] as int? ?? 0,
    contentSafeMarginX:
        (value['contentSafeMarginX'] as num?)?.toDouble().clamp(0, 1) ?? 0,
    contentSafeMarginY:
        (value['contentSafeMarginY'] as num?)?.toDouble().clamp(0, 1) ?? 0,
    paperRegionCandidate: value['paperRegionCandidate'] as bool? ?? false,
    confidence: confidence.toDouble().clamp(0.0, 1.0).toDouble(),
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
}

DocumentCorners? _cornersFromNative(Object? value) {
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
