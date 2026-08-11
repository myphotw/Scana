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
  });

  final bool detected;
  final DocumentCorners? corners;
  final PageBoundary? boundary;
  final double confidence;
  final int sourceWidth;
  final int sourceHeight;
}
