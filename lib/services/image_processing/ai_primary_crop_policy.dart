import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/page_crop_decision.dart';

class AiPrimaryCropSelection {
  const AiPrimaryCropSelection({
    required this.corners,
    required this.source,
    required this.confidence,
  });

  final DocumentCorners corners;
  final CropSource source;
  final double confidence;
}

/// Production priority for the final Perspective input.
///
/// Native refinement owns visibility analysis. Dart only accepts its declared
/// final polygon after an independent geometry check; otherwise the existing
/// OpenCV/Q1.x policy remains the fallback.
class AiPrimaryCropPolicy {
  const AiPrimaryCropPolicy._();

  static AiPrimaryCropSelection? select(
    AiDocumentSegmentationResult? result, {
    required DocumentPageSide? pageSide,
    DocumentCorners? expectedGuideCorners,
  }) {
    if (result == null || !result.hasUsableFinalBoundary) return null;
    final modelConfidence = result.confidence ?? 0;
    if (modelConfidence < 0.45 ||
        result.maskCoverage < 0.02 ||
        result.maskCoverage > 0.995 ||
        (result.mainPageOwnershipScore > 0 &&
            result.mainPageOwnershipScore < 0.66) ||
        result.adjacentPagePenalty >= 0.66) {
      return null;
    }
    if (result.finalSource == AiFinalBoundarySource.rawFallback &&
        modelConfidence < 0.58) {
      return null;
    }
    final corners = result.finalCorners!;
    if (!PageCropDecisionPolicy.isSaneCorners(
      corners,
      result.sourceWidth,
      result.sourceHeight,
      pageSide: pageSide,
    )) {
      return null;
    }
    // A guide is an expected/safe search region, not a crop boundary. A real
    // paper edge may extend beyond it, but an almost disjoint AI result is a
    // poor production candidate and should fall back to the existing policy.
    if (expectedGuideCorners != null &&
        !_hasReasonableGuideAgreement(
          corners,
          expectedGuideCorners,
          result.sourceWidth,
          result.sourceHeight,
        )) {
      return null;
    }
    final source = switch (result.finalSource!) {
      AiFinalBoundarySource.refined => CropSource.aiRefined,
      AiFinalBoundarySource.hybrid => CropSource.aiHybrid,
      AiFinalBoundarySource.rawFallback => CropSource.aiRawFallback,
    };
    return AiPrimaryCropSelection(
      corners: corners,
      source: source,
      confidence: result.refinedConfidence > 0
          ? result.refinedConfidence
          : (result.confidence ?? 0).clamp(0.0, 1.0),
    );
  }

  static bool _hasReasonableGuideAgreement(
    DocumentCorners candidate,
    DocumentCorners guide,
    int width,
    int height,
  ) {
    if (width <= 0 || height <= 0) return true;
    ({double left, double top, double right, double bottom}) bounds(
      DocumentCorners corners,
    ) {
      final points = corners.ordered;
      return (
        left: points.map((point) => point.x).reduce((a, b) => a < b ? a : b),
        top: points.map((point) => point.y).reduce((a, b) => a < b ? a : b),
        right: points.map((point) => point.x).reduce((a, b) => a > b ? a : b),
        bottom: points.map((point) => point.y).reduce((a, b) => a > b ? a : b),
      );
    }

    final candidateBounds = bounds(candidate);
    final guideBounds = bounds(guide);
    final guidePaddingX = width * .16;
    final guidePaddingY = height * .16;
    final left = (guideBounds.left - guidePaddingX).clamp(
      0.0,
      width.toDouble(),
    );
    final top = (guideBounds.top - guidePaddingY).clamp(0.0, height.toDouble());
    final right = (guideBounds.right + guidePaddingX).clamp(
      0.0,
      width.toDouble(),
    );
    final bottom = (guideBounds.bottom + guidePaddingY).clamp(
      0.0,
      height.toDouble(),
    );
    final intersectionWidth =
        (candidateBounds.right < right ? candidateBounds.right : right) -
        (candidateBounds.left > left ? candidateBounds.left : left);
    final intersectionHeight =
        (candidateBounds.bottom < bottom ? candidateBounds.bottom : bottom) -
        (candidateBounds.top > top ? candidateBounds.top : top);
    final intersection =
        (intersectionWidth > 0 ? intersectionWidth : 0) *
        (intersectionHeight > 0 ? intersectionHeight : 0);
    final candidateArea =
        (candidateBounds.right - candidateBounds.left) *
        (candidateBounds.bottom - candidateBounds.top);
    return candidateArea <= 0 || intersection / candidateArea >= .35;
  }
}
