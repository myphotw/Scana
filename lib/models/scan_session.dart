import 'package:scana/models/scan_page.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/models/ai_document_segmentation_result.dart';

/// Groups the raw pages that belong to one scanning operation.
class ScanSession {
  ScanSession({
    required this.id,
    required this.createdTime,
    this.captureMode = ScanCaptureMode.single,
    this.suggestedTitle,
    this.ocrSourcePageNo,
  });

  final String id;
  final DateTime createdTime;
  ScanCaptureMode captureMode;
  String? suggestedTitle;
  int? ocrSourcePageNo;
  final List<ScanPage> _pages = [];

  List<ScanPage> get pages => List.unmodifiable(_pages);

  void addPage(ScanPage page) {
    _pages.add(page);
  }

  ScanPage removePageAt(int index) {
    final page = _pages.removeAt(index);
    _renumberPages();
    return page;
  }

  void replacePageAt(int index, ScanPage page) {
    _pages[index] = page.copyWith(pageNo: _pages[index].pageNo);
  }

  void replacePageRange(int index, int count, List<ScanPage> replacements) {
    _pages.replaceRange(index, index + count, replacements);
    _renumberPages();
  }

  void replacePagesByRawPath(
    Set<String> rawPaths,
    List<ScanPage> replacements,
  ) {
    final indices = <int>[
      for (var index = 0; index < _pages.length; index++)
        if (rawPaths.contains(_pages[index].rawImagePath)) index,
    ];
    if (indices.isEmpty) return;
    final insertionIndex = indices.first;
    _pages.removeWhere((page) => rawPaths.contains(page.rawImagePath));
    _pages.insertAll(insertionIndex.clamp(0, _pages.length), replacements);
    _renumberPages();
  }

  void reorderPages(int oldIndex, int newIndex) {
    final page = _pages.removeAt(oldIndex);
    _pages.insert(newIndex, page);
    _renumberPages();
  }

  void rotatePageAt(int index) {
    _pages[index] = _pages[index].rotateClockwise();
  }

  void updateDetectionAt(
    int index,
    DocumentDetectionResult detection, {
    DocumentCorners? captureGuideCorners,
    DocumentCorners? resolvedCorners,
    PageBoundary? resolvedBoundary,
    CropSource? cropSource,
    double? captureBoundaryConfidence,
    double? captureBoundaryStability,
  }) {
    _pages[index] = _pages[index]
        .withDetection(
          detection,
          resolvedCorners: resolvedCorners,
          resolvedBoundary: resolvedBoundary,
          cropSource: cropSource,
          captureBoundaryConfidence: captureBoundaryConfidence,
          captureBoundaryStability: captureBoundaryStability,
        )
        .copyWith(captureGuideCorners: captureGuideCorners);
  }

  void updateAiSegmentationAt(int index, AiDocumentSegmentationResult result) {
    _pages[index] = _pages[index].copyWith(aiSegmentationResult: result);
  }

  void updateDocumentCornersAt(int index, DocumentCorners corners) {
    _pages[index] = _pages[index].withDocumentCorners(corners);
  }

  void updateCorrectionAt(
    int index, {
    required CorrectionStatus status,
    required CorrectionType type,
    String? correctedImagePath,
    CorrectionOutcome? outcome,
    String? failureReason,
  }) {
    _pages[index] = _pages[index].withCorrection(
      status: status,
      type: type,
      correctedImagePath: correctedImagePath,
      outcome: outcome,
      failureReason: failureReason,
    );
  }

  void updateEnhancementAt(
    int index, {
    required EnhancementMode mode,
    required EnhancementStatus status,
    String? enhancedImagePath,
  }) {
    _pages[index] = _pages[index].withEnhancement(
      mode: mode,
      status: status,
      enhancedImagePath: enhancedImagePath,
    );
  }

  void updateSuggestedTitle(String title, int sourcePageNo) {
    suggestedTitle = title;
    ocrSourcePageNo = sourcePageNo;
  }

  void _renumberPages() {
    for (var index = 0; index < _pages.length; index++) {
      _pages[index] = _pages[index].copyWith(pageNo: index + 1);
    }
  }
}
