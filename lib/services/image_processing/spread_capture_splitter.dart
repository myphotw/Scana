import 'package:flutter/services.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/services/image_processing/document_detector.dart';

/// Geometry policy for a manually aligned, two-page book capture.
class SpreadCaptureRoiPolicy {
  const SpreadCaptureRoiPolicy._();

  static const double overlapFraction = 0.10;

  static SpreadRoiPair forSource({
    required int width,
    required int height,
    double overlap = overlapFraction,
  }) {
    if (width <= 1 || height <= 0) {
      throw ArgumentError.value(width, 'width', 'Must be greater than one.');
    }
    if (overlap < 0 || overlap >= 1) {
      throw ArgumentError.value(overlap, 'overlap', 'Must be in [0, 1).');
    }
    final halfOverlap = overlap / 2;
    final leftWidth = (width * (0.5 + halfOverlap)).round().clamp(1, width);
    final rightStart = (width * (0.5 - halfOverlap)).round().clamp(
      0,
      width - 1,
    );
    return SpreadRoiPair(
      left: SpreadRoi(left: 0, top: 0, width: leftWidth, height: height),
      right: SpreadRoi(
        left: rightStart,
        top: 0,
        width: width - rightStart,
        height: height,
      ),
    );
  }

  /// Converts a normalized full-frame live boundary into the normalized
  /// coordinate space of the saved left/right overlap ROI.
  static PageBoundary toRoiBoundary(
    PageBoundary fullFrameBoundary,
    DocumentPageSide side, {
    double overlap = overlapFraction,
  }) {
    final halfOverlap = overlap / 2;
    final start = side == DocumentPageSide.left ? 0.0 : 0.5 - halfOverlap;
    final end = side == DocumentPageSide.left ? 0.5 + halfOverlap : 1.0;
    final width = end - start;
    final normalized = fullFrameBoundary.normalized();
    return normalized.mapPoints(
      (point) => DocumentPoint(
        ((point.x - start) / width).clamp(0.0, 1.0),
        point.y.clamp(0.0, 1.0),
      ),
      sourceWidth: 1,
      sourceHeight: 1,
    );
  }
}

/// Strong geometric prior used only after a manually center-aligned spread
/// capture has already been split into left and right ROI images.
class SpreadPageDetectionPolicy {
  const SpreadPageDetectionPolicy._();

  static const double outerMargin = 0.03;
  static const double spineInset = 0.09;
  static const double verticalMargin = 0.04;
  // Must match ScanSessionManager's high-resolution reliability gate. A weak
  // native result may leave guide corners on the page model and must not cause
  // Perspective to run as if those corners were a detected boundary.
  static const double minimumBoundaryConfidence = 0.55;

  static CaptureGuideRegion expectedRegion(DocumentPageSide side) {
    return switch (side) {
      DocumentPageSide.left => const CaptureGuideRegion(
        left: outerMargin,
        top: verticalMargin,
        right: 1 - spineInset,
        bottom: 1 - verticalMargin,
      ),
      DocumentPageSide.right => const CaptureGuideRegion(
        left: spineInset,
        top: verticalMargin,
        right: 1 - outerMargin,
        bottom: 1 - verticalMargin,
      ),
    };
  }

  static bool isStableDetection(ScanPage page) =>
      page.documentCorners != null &&
      (page.detectionConfidence ?? 0) >= minimumBoundaryConfidence;
}

class SpreadRoi {
  const SpreadRoi({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  int get right => left + width;
  int get bottom => top + height;
}

class SpreadRoiPair {
  const SpreadRoiPair({required this.left, required this.right});

  final SpreadRoi left;
  final SpreadRoi right;
}

class SpreadCaptureParts {
  const SpreadCaptureParts({
    required this.leftImagePath,
    required this.rightImagePath,
  });

  final String leftImagePath;
  final String rightImagePath;
}

/// Creates independent temporary left/right images before the normal page
/// storage, detection, and Perspective pipeline runs for each side.
abstract interface class SpreadCaptureSplitter {
  Future<SpreadCaptureParts> split(String capturedImagePath);
}

/// Creates a safe axis-aligned page crop when spread boundary confidence is
/// insufficient for Perspective correction.
abstract interface class SpreadFallbackCropper {
  Future<void> crop({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentPageSide pageSide,
  });
}

class OpenCvSpreadFallbackCropper implements SpreadFallbackCropper {
  const OpenCvSpreadFallbackCropper({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.myphotw.scana/document_detector');

  final MethodChannel _channel;

  @override
  Future<void> crop({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentPageSide pageSide,
  }) async {
    final region = SpreadPageDetectionPolicy.expectedRegion(pageSide);
    await _channel.invokeMethod<void>('cropSpreadFallback', {
      'imagePath': sourceImagePath,
      'outputImagePath': outputImagePath,
      'left': region.left,
      'top': region.top,
      'right': region.right,
      'bottom': region.bottom,
    });
  }
}

class OpenCvSpreadCaptureSplitter implements SpreadCaptureSplitter {
  const OpenCvSpreadCaptureSplitter({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.myphotw.scana/document_detector');

  final MethodChannel _channel;

  @override
  Future<SpreadCaptureParts> split(String capturedImagePath) async {
    final value = await _channel
        .invokeMapMethod<String, dynamic>('splitSpreadCapture', {
          'imagePath': capturedImagePath,
          'overlapFraction': SpreadCaptureRoiPolicy.overlapFraction,
        });
    final left = value?['leftImagePath'];
    final right = value?['rightImagePath'];
    if (left is! String || right is! String || left.isEmpty || right.isEmpty) {
      throw const FormatException('Spread splitter returned invalid paths.');
    }
    return SpreadCaptureParts(leftImagePath: left, rightImagePath: right);
  }
}
