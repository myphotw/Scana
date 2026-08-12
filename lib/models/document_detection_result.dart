export 'package:scana/models/document_geometry.dart';

import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/page_boundary.dart';

/// Result returned by a detector independently of camera or editor UI.
class DocumentDetectionResult {
  const DocumentDetectionResult({
    required this.detected,
    required this.confidence,
    required this.sourceWidth,
    required this.sourceHeight,
    this.corners,
    this.boundary,
    this.contentSafeCorners,
    this.contentBounds,
    this.contentSafeConfidence = 0,
    this.contentComponentCount = 0,
    this.contentSafeMarginX = 0,
    this.contentSafeMarginY = 0,
    this.paperRegionCandidate = false,
  });

  final bool detected;
  final DocumentCorners? corners;
  final PageBoundary? boundary;

  /// Conservative crop inferred from meaningful foreground components.
  final DocumentCorners? contentSafeCorners;
  final DocumentCorners? contentBounds;
  final double contentSafeConfidence;
  final int contentComponentCount;
  final double contentSafeMarginX;
  final double contentSafeMarginY;

  /// True when the selected high-resolution candidate came from the paper mask.
  final bool paperRegionCandidate;
  final double confidence;
  final int sourceWidth;
  final int sourceHeight;
}
