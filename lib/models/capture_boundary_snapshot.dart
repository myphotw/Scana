import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';

enum CaptureBoundarySide { single, left, right }

/// Immutable camera-analysis boundary frozen synchronously at shutter time.
///
/// The boundary remains in the detector's analysis-frame pixel coordinates;
/// UI preview coordinates are never used to derive the JPEG crop.
class CaptureBoundarySnapshot {
  const CaptureBoundarySnapshot({
    required this.captureMode,
    required this.timestamp,
    required this.sourceFrameWidth,
    required this.sourceFrameHeight,
    required this.sensorOrientation,
    required this.deviceOrientationDegrees,
    required this.jpegRotationDegrees,
    required this.mirrored,
    required this.boundary,
    required this.confidence,
    required this.stability,
    required this.side,
  });

  final ScanCaptureMode captureMode;
  final DateTime timestamp;
  final int sourceFrameWidth;
  final int sourceFrameHeight;
  final int sensorOrientation;
  final int deviceOrientationDegrees;
  final int jpegRotationDegrees;
  final bool mirrored;
  final PageBoundary boundary;
  final double confidence;
  final double stability;
  final CaptureBoundarySide side;
}
