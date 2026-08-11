import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/page_enhancement.dart';

/// A raw page captured during a scan session.
class ScanPage {
  const ScanPage({
    required this.pageNo,
    required this.rawImagePath,
    required this.createdTime,
    this.rotation = 0,
    this.documentCorners,
    this.pageBoundary,
    this.documentSourceWidth,
    this.documentSourceHeight,
    this.captureGuideCorners,
    this.detectionConfidence,
    this.spreadFallbackUsed = false,
    this.hasUserAdjustedCorners = false,
    this.correctedImagePath,
    this.correctionStatus = CorrectionStatus.none,
    this.correctionType = CorrectionType.perspective,
    this.correctionOutcome = CorrectionOutcome.none,
    this.enhancedImagePath,
    this.enhancementMode = EnhancementMode.scanColor,
    this.enhancementStatus = EnhancementStatus.none,
  }) : assert(
         rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270,
       );

  final int pageNo;
  final String rawImagePath;
  final DateTime createdTime;
  final int rotation;
  final DocumentCorners? documentCorners;
  final PageBoundary? pageBoundary;
  final int? documentSourceWidth;
  final int? documentSourceHeight;
  final DocumentCorners? captureGuideCorners;
  final double? detectionConfidence;
  final bool spreadFallbackUsed;
  final bool hasUserAdjustedCorners;
  final String? correctedImagePath;
  final CorrectionStatus correctionStatus;
  final CorrectionType correctionType;
  final CorrectionOutcome correctionOutcome;
  final String? enhancedImagePath;
  final EnhancementMode enhancementMode;
  final EnhancementStatus enhancementStatus;

  /// Final page appearance shared by Viewer, Gallery, PDF, and thumbnails.
  String get displayImagePath {
    if (enhancementMode == EnhancementMode.originalColor) {
      return correctedImagePath ?? rawImagePath;
    }
    if (enhancementStatus == EnhancementStatus.completed &&
        enhancedImagePath != null) {
      return enhancedImagePath!;
    }
    return correctedImagePath ?? rawImagePath;
  }

  ScanPage copyWith({
    int? pageNo,
    int? rotation,
    DocumentCorners? documentCorners,
    PageBoundary? pageBoundary,
    int? documentSourceWidth,
    int? documentSourceHeight,
    DocumentCorners? captureGuideCorners,
    double? detectionConfidence,
    bool? spreadFallbackUsed,
    bool? hasUserAdjustedCorners,
    String? correctedImagePath,
    CorrectionStatus? correctionStatus,
    CorrectionType? correctionType,
    CorrectionOutcome? correctionOutcome,
    String? enhancedImagePath,
    EnhancementMode? enhancementMode,
    EnhancementStatus? enhancementStatus,
  }) {
    return ScanPage(
      pageNo: pageNo ?? this.pageNo,
      rawImagePath: rawImagePath,
      createdTime: createdTime,
      rotation: rotation ?? this.rotation,
      documentCorners: documentCorners ?? this.documentCorners,
      pageBoundary: pageBoundary ?? this.pageBoundary,
      documentSourceWidth: documentSourceWidth ?? this.documentSourceWidth,
      documentSourceHeight: documentSourceHeight ?? this.documentSourceHeight,
      captureGuideCorners: captureGuideCorners ?? this.captureGuideCorners,
      detectionConfidence: detectionConfidence ?? this.detectionConfidence,
      spreadFallbackUsed: spreadFallbackUsed ?? this.spreadFallbackUsed,
      hasUserAdjustedCorners:
          hasUserAdjustedCorners ?? this.hasUserAdjustedCorners,
      correctedImagePath: correctedImagePath ?? this.correctedImagePath,
      correctionStatus: correctionStatus ?? this.correctionStatus,
      correctionType: correctionType ?? this.correctionType,
      correctionOutcome: correctionOutcome ?? this.correctionOutcome,
      enhancedImagePath: enhancedImagePath ?? this.enhancedImagePath,
      enhancementMode: enhancementMode ?? this.enhancementMode,
      enhancementStatus: enhancementStatus ?? this.enhancementStatus,
    );
  }

  ScanPage rotateClockwise() => copyWith(rotation: (rotation + 90) % 360);

  ScanPage withDetection(
    DocumentDetectionResult detection, {
    DocumentCorners? resolvedCorners,
    PageBoundary? resolvedBoundary,
  }) {
    return copyWith(
      documentCorners: resolvedCorners ?? detection.corners,
      pageBoundary: resolvedBoundary ?? detection.boundary,
      documentSourceWidth: detection.sourceWidth > 0
          ? detection.sourceWidth
          : documentSourceWidth,
      documentSourceHeight: detection.sourceHeight > 0
          ? detection.sourceHeight
          : documentSourceHeight,
      detectionConfidence: detection.confidence,
      hasUserAdjustedCorners: false,
    );
  }

  ScanPage withDocumentCorners(DocumentCorners corners) {
    return copyWith(
      documentCorners: corners,
      pageBoundary: pageBoundary?.withRepresentativeCorners(corners),
      hasUserAdjustedCorners: true,
      correctionStatus: CorrectionStatus.none,
      enhancementStatus: EnhancementStatus.none,
    );
  }

  ScanPage withCorrection({
    required CorrectionStatus status,
    required CorrectionType type,
    String? correctedImagePath,
    CorrectionOutcome? outcome,
  }) {
    return copyWith(
      correctionStatus: status,
      correctionType: type,
      correctedImagePath: correctedImagePath,
      correctionOutcome:
          outcome ??
          (status == CorrectionStatus.completed
              ? CorrectionOutcome.completed
              : CorrectionOutcome.none),
      spreadFallbackUsed: false,
      enhancementStatus: EnhancementStatus.none,
    );
  }

  ScanPage withEnhancement({
    required EnhancementMode mode,
    required EnhancementStatus status,
    String? enhancedImagePath,
  }) {
    return copyWith(
      enhancementMode: mode,
      enhancementStatus: status,
      enhancedImagePath: enhancedImagePath,
    );
  }

  ScanPage withSpreadFallback(String correctedImagePath) => copyWith(
    correctedImagePath: correctedImagePath,
    correctionStatus: CorrectionStatus.completed,
    correctionType: CorrectionType.perspective,
    correctionOutcome: CorrectionOutcome.completed,
    spreadFallbackUsed: true,
  );
}

/// Normalized Camera guide bounds, persisted as source-pixel corners after
/// still-image dimensions become available from document detection.
class CaptureGuideRegion {
  const CaptureGuideRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  }) : assert(left >= 0 && top >= 0 && right <= 1 && bottom <= 1),
       assert(left < right && top < bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  DocumentCorners toSourceCorners(int width, int height) {
    return DocumentCorners(
      topLeft: DocumentPoint(left * width, top * height),
      topRight: DocumentPoint(right * width, top * height),
      bottomRight: DocumentPoint(right * width, bottom * height),
      bottomLeft: DocumentPoint(left * width, bottom * height),
    );
  }
}
