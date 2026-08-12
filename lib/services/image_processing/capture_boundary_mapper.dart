import 'package:scana/models/capture_boundary_snapshot.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/spread_capture_splitter.dart';

class CaptureBoundaryMapper {
  const CaptureBoundaryMapper._();

  /// Converts detector-frame coordinates directly to decoded JPEG coordinates.
  /// Preview layout/crop coordinates deliberately do not participate.
  static PageBoundary? toJpegBoundary(
    CaptureBoundarySnapshot snapshot, {
    required int jpegWidth,
    required int jpegHeight,
    DocumentPageSide? pageSide,
  }) {
    if (snapshot.sourceFrameWidth <= 0 ||
        snapshot.sourceFrameHeight <= 0 ||
        jpegWidth <= 0 ||
        jpegHeight <= 0 ||
        !snapshot.boundary.isValid) {
      return null;
    }
    final normalized = snapshot.boundary.normalized();
    final rotated = _rotate(normalized, snapshot.jpegRotationDegrees);
    final roiLocal = pageSide == null
        ? rotated
        : SpreadCaptureRoiPolicy.toRoiBoundary(rotated, pageSide);
    final scaled = roiLocal
        .scaleTo(jpegWidth, jpegHeight)
        .copyWith(
          confidence: snapshot.confidence,
          stability: snapshot.stability,
          timestamp: snapshot.timestamp,
        );
    return scaled.isValid ? scaled : null;
  }

  static PageBoundary _rotate(PageBoundary boundary, int degrees) {
    DocumentPoint rotate(DocumentPoint point) => switch (degrees) {
      90 => DocumentPoint(1 - point.y, point.x),
      180 => DocumentPoint(1 - point.x, 1 - point.y),
      270 => DocumentPoint(point.y, 1 - point.x),
      _ => point,
    };
    final transformed = switch (degrees) {
      90 => (boundary.left, boundary.top, boundary.right, boundary.bottom),
      180 => (boundary.bottom, boundary.left, boundary.top, boundary.right),
      270 => (boundary.right, boundary.bottom, boundary.left, boundary.top),
      _ => (boundary.top, boundary.right, boundary.bottom, boundary.left),
    };
    return PageBoundary(
      top: transformed.$1.map(rotate).toList(),
      right: transformed.$2.map(rotate).toList(),
      bottom: transformed.$3.map(rotate).toList(),
      left: transformed.$4.map(rotate).toList(),
      confidence: boundary.confidence,
      stability: boundary.stability,
      sourceWidth: 1,
      sourceHeight: 1,
      timestamp: boundary.timestamp,
      clippingEvidence: boundary.clippingEvidence,
    );
  }
}
