import 'dart:math' as math;

import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/spread_capture_splitter.dart';

/// One geometry contract for the visible capture target and its processing
/// prior. It is a preference, never a forced crop boundary.
class CaptureGuidePolicy {
  const CaptureGuidePolicy._();

  static CaptureGuideRegion singleForViewport({
    required double width,
    required double height,
  }) {
    final guideWidth = width * .78;
    final guideHeight = math.min(height * .68, guideWidth * 1.414);
    final left = (width - guideWidth) / 2 / width;
    final top = (height - guideHeight) / 2 / height;
    return CaptureGuideRegion(
      left: left,
      top: top,
      right: 1 - left,
      bottom: 1 - top,
    );
  }

  /// The same local expected region consumed by each saved spread ROI.
  static CaptureGuideRegion spreadForRoi(DocumentPageSide side) =>
      SpreadPageDetectionPolicy.expectedRegion(side);

  /// Converts each overlap-ROI local guide into the full-frame guide that is
  /// drawn in the camera preview. The center remains the actual 50/50 split.
  static CaptureGuideRegion spreadForPreview(DocumentPageSide side) {
    final local = spreadForRoi(side);
    final overlap = SpreadCaptureRoiPolicy.overlapFraction / 2;
    final roiLeft = side == DocumentPageSide.left ? 0.0 : .5 - overlap;
    const roiWidth = .5 + SpreadCaptureRoiPolicy.overlapFraction / 2;
    return CaptureGuideRegion(
      left: roiLeft + local.left * roiWidth,
      top: local.top,
      right: roiLeft + local.right * roiWidth,
      bottom: local.bottom,
    );
  }

  static List<CaptureGuideRegion> previewRegions(
    ScanCaptureMode mode, {
    required double width,
    required double height,
  }) => mode == ScanCaptureMode.single
      ? [singleForViewport(width: width, height: height)]
      : [
          spreadForPreview(DocumentPageSide.left),
          spreadForPreview(DocumentPageSide.right),
        ];
}
