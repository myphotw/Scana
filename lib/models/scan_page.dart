import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';

enum ScanPageSourceType { scana, mlKit, mlKitSpread }

/// A raw page captured during a scan session.
class ScanPage {
  const ScanPage({
    required this.pageNo,
    required this.rawImagePath,
    required this.createdTime,
    this.sourceType = ScanPageSourceType.scana,
    this.mlKitLayout,
    this.originalSourcePath,
    this.parentSpreadId,
    this.spreadSide,
    this.splitX,
    this.splitConfidence,
    this.splitFallbackUsed = false,
    this.mlKitCropRect,
    this.editedImagePath,
    this.rotation = 0,
    this.documentCorners,
    this.pageBoundary,
    this.documentSourceWidth,
    this.documentSourceHeight,
    this.captureGuideCorners,
    this.detectionConfidence,
    this.cropSource,
    this.captureBoundaryConfidence,
    this.captureBoundaryStability,
    this.aiSegmentationResult,
    this.spreadFallbackUsed = false,
    this.hasUserAdjustedCorners = false,
    this.correctedImagePath,
    this.correctionStatus = CorrectionStatus.none,
    this.correctionType = CorrectionType.perspective,
    this.correctionOutcome = CorrectionOutcome.none,
    this.correctionFailureReason,
    this.perspectiveApplied = false,
    this.curvatureState = CurvatureState.none,
    this.curvedApplied = false,
    this.curvedConfidence,
    this.curvatureMagnitude,
    this.curvedRejectReason,
    this.enhancedImagePath,
    this.enhancementMode = EnhancementMode.scanColor,
    this.enhancementStatus = EnhancementStatus.none,
    this.enhancementApplied = false,
  }) : assert(
         rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270,
       );

  final int pageNo;
  final String rawImagePath;
  final DateTime createdTime;
  final ScanPageSourceType sourceType;
  final MlKitPageLayout? mlKitLayout;
  final String? originalSourcePath;
  final String? parentSpreadId;
  final MlKitSpreadSide? spreadSide;
  final int? splitX;
  final double? splitConfidence;
  final bool splitFallbackUsed;
  final MlKitCropRect? mlKitCropRect;
  final String? editedImagePath;
  final int rotation;
  final DocumentCorners? documentCorners;
  final PageBoundary? pageBoundary;
  final int? documentSourceWidth;
  final int? documentSourceHeight;
  final DocumentCorners? captureGuideCorners;
  final double? detectionConfidence;
  final CropSource? cropSource;
  final double? captureBoundaryConfidence;
  final double? captureBoundaryStability;
  final AiDocumentSegmentationResult? aiSegmentationResult;
  final bool spreadFallbackUsed;
  final bool hasUserAdjustedCorners;
  final String? correctedImagePath;
  final CorrectionStatus correctionStatus;
  final CorrectionType correctionType;
  final CorrectionOutcome correctionOutcome;
  final String? correctionFailureReason;
  final bool perspectiveApplied;
  final CurvatureState curvatureState;
  final bool curvedApplied;
  final double? curvedConfidence;
  final double? curvatureMagnitude;
  final String? curvedRejectReason;
  final String? enhancedImagePath;
  final EnhancementMode enhancementMode;
  final EnhancementStatus enhancementStatus;
  final bool enhancementApplied;

  bool get usesCustomImagePipeline => sourceType == ScanPageSourceType.scana;
  bool get isMlKitPage => !usesCustomImagePipeline;
  bool get isMlKitSpreadChild =>
      sourceType == ScanPageSourceType.mlKitSpread && parentSpreadId != null;
  String get editableSourcePath => originalSourcePath ?? rawImagePath;

  /// Final page appearance shared by Viewer, Gallery, PDF, and thumbnails.
  String get displayImagePath {
    if (isMlKitPage) return editedImagePath ?? rawImagePath;
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
    ScanPageSourceType? sourceType,
    MlKitPageLayout? mlKitLayout,
    String? originalSourcePath,
    String? parentSpreadId,
    MlKitSpreadSide? spreadSide,
    int? splitX,
    double? splitConfidence,
    bool? splitFallbackUsed,
    MlKitCropRect? mlKitCropRect,
    String? editedImagePath,
    bool clearEditedImagePath = false,
    DocumentCorners? documentCorners,
    PageBoundary? pageBoundary,
    int? documentSourceWidth,
    int? documentSourceHeight,
    DocumentCorners? captureGuideCorners,
    double? detectionConfidence,
    CropSource? cropSource,
    double? captureBoundaryConfidence,
    double? captureBoundaryStability,
    AiDocumentSegmentationResult? aiSegmentationResult,
    bool? spreadFallbackUsed,
    bool? hasUserAdjustedCorners,
    String? correctedImagePath,
    CorrectionStatus? correctionStatus,
    CorrectionType? correctionType,
    CorrectionOutcome? correctionOutcome,
    String? correctionFailureReason,
    bool clearCorrectionFailureReason = false,
    bool? perspectiveApplied,
    CurvatureState? curvatureState,
    bool? curvedApplied,
    double? curvedConfidence,
    double? curvatureMagnitude,
    String? curvedRejectReason,
    bool clearCurvatureDiagnostics = false,
    String? enhancedImagePath,
    EnhancementMode? enhancementMode,
    EnhancementStatus? enhancementStatus,
    bool? enhancementApplied,
  }) {
    return ScanPage(
      pageNo: pageNo ?? this.pageNo,
      rawImagePath: rawImagePath,
      createdTime: createdTime,
      sourceType: sourceType ?? this.sourceType,
      mlKitLayout: mlKitLayout ?? this.mlKitLayout,
      originalSourcePath: originalSourcePath ?? this.originalSourcePath,
      parentSpreadId: parentSpreadId ?? this.parentSpreadId,
      spreadSide: spreadSide ?? this.spreadSide,
      splitX: splitX ?? this.splitX,
      splitConfidence: splitConfidence ?? this.splitConfidence,
      splitFallbackUsed: splitFallbackUsed ?? this.splitFallbackUsed,
      mlKitCropRect: mlKitCropRect ?? this.mlKitCropRect,
      editedImagePath: clearEditedImagePath
          ? null
          : editedImagePath ?? this.editedImagePath,
      rotation: rotation ?? this.rotation,
      documentCorners: documentCorners ?? this.documentCorners,
      pageBoundary: pageBoundary ?? this.pageBoundary,
      documentSourceWidth: documentSourceWidth ?? this.documentSourceWidth,
      documentSourceHeight: documentSourceHeight ?? this.documentSourceHeight,
      captureGuideCorners: captureGuideCorners ?? this.captureGuideCorners,
      detectionConfidence: detectionConfidence ?? this.detectionConfidence,
      cropSource: cropSource ?? this.cropSource,
      captureBoundaryConfidence:
          captureBoundaryConfidence ?? this.captureBoundaryConfidence,
      captureBoundaryStability:
          captureBoundaryStability ?? this.captureBoundaryStability,
      aiSegmentationResult: aiSegmentationResult ?? this.aiSegmentationResult,
      spreadFallbackUsed: spreadFallbackUsed ?? this.spreadFallbackUsed,
      hasUserAdjustedCorners:
          hasUserAdjustedCorners ?? this.hasUserAdjustedCorners,
      correctedImagePath: correctedImagePath ?? this.correctedImagePath,
      correctionStatus: correctionStatus ?? this.correctionStatus,
      correctionType: correctionType ?? this.correctionType,
      correctionOutcome: correctionOutcome ?? this.correctionOutcome,
      correctionFailureReason: clearCorrectionFailureReason
          ? null
          : correctionFailureReason ?? this.correctionFailureReason,
      perspectiveApplied: perspectiveApplied ?? this.perspectiveApplied,
      curvatureState: curvatureState ?? this.curvatureState,
      curvedApplied: curvedApplied ?? this.curvedApplied,
      curvedConfidence: clearCurvatureDiagnostics
          ? null
          : curvedConfidence ?? this.curvedConfidence,
      curvatureMagnitude: clearCurvatureDiagnostics
          ? null
          : curvatureMagnitude ?? this.curvatureMagnitude,
      curvedRejectReason: clearCurvatureDiagnostics
          ? null
          : curvedRejectReason ?? this.curvedRejectReason,
      enhancedImagePath: enhancedImagePath ?? this.enhancedImagePath,
      enhancementMode: enhancementMode ?? this.enhancementMode,
      enhancementStatus: enhancementStatus ?? this.enhancementStatus,
      enhancementApplied: enhancementApplied ?? this.enhancementApplied,
    );
  }

  ScanPage rotateClockwise() => copyWith(rotation: (rotation + 90) % 360);

  ScanPage withDetection(
    DocumentDetectionResult detection, {
    DocumentCorners? resolvedCorners,
    PageBoundary? resolvedBoundary,
    CropSource? cropSource,
    double? captureBoundaryConfidence,
    double? captureBoundaryStability,
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
      cropSource: cropSource,
      captureBoundaryConfidence: captureBoundaryConfidence,
      captureBoundaryStability: captureBoundaryStability,
      hasUserAdjustedCorners: false,
    );
  }

  ScanPage withDocumentCorners(DocumentCorners corners) {
    return copyWith(
      documentCorners: corners,
      pageBoundary: pageBoundary?.withRepresentativeCorners(corners),
      cropSource: CropSource.manualCorners,
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
    String? failureReason,
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
      correctionFailureReason: failureReason,
      clearCorrectionFailureReason: status != CorrectionStatus.failed,
      perspectiveApplied:
          type == CorrectionType.perspective &&
              status == CorrectionStatus.completed
          ? true
          : perspectiveApplied,
      curvatureState: type == CorrectionType.perspective
          ? CurvatureState.none
          : curvatureState,
      curvedApplied: type == CorrectionType.perspective
          ? false
          : status == CorrectionStatus.completed,
      clearCurvatureDiagnostics: type == CorrectionType.perspective,
      spreadFallbackUsed: false,
      enhancementStatus: EnhancementStatus.none,
      enhancementApplied: false,
    );
  }

  ScanPage withAutomaticCurvature({
    required CurvatureState state,
    required bool applied,
    double? confidence,
    double? magnitude,
    String? rejectReason,
    String? correctedImagePath,
  }) => copyWith(
    correctedImagePath: correctedImagePath,
    correctionStatus: CorrectionStatus.completed,
    correctionType: applied
        ? CorrectionType.curved
        : CorrectionType.perspective,
    correctionOutcome: applied
        ? CorrectionOutcome.completed
        : state == CurvatureState.flat
        ? CorrectionOutcome.nearlyFlat
        : CorrectionOutcome.completed,
    clearCorrectionFailureReason: true,
    perspectiveApplied: true,
    curvatureState: state,
    curvedApplied: applied,
    curvedConfidence: confidence,
    curvatureMagnitude: magnitude,
    curvedRejectReason: rejectReason,
    enhancementStatus: EnhancementStatus.none,
    enhancementApplied: false,
  );

  ScanPage withEnhancement({
    required EnhancementMode mode,
    required EnhancementStatus status,
    String? enhancedImagePath,
  }) {
    return copyWith(
      enhancementMode: mode,
      enhancementStatus: status,
      enhancedImagePath: enhancedImagePath,
      enhancementApplied: status == EnhancementStatus.completed,
    );
  }

  ScanPage withSpreadFallback(String correctedImagePath) => copyWith(
    correctedImagePath: correctedImagePath,
    correctionStatus: CorrectionStatus.completed,
    correctionType: CorrectionType.perspective,
    correctionOutcome: CorrectionOutcome.completed,
    perspectiveApplied: true,
    curvatureState: CurvatureState.none,
    curvedApplied: false,
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
