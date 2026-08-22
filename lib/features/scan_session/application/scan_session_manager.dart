import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/models/capture_boundary_snapshot.dart';
import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/image_processing/page_corrector.dart';
import 'package:scana/services/image_processing/spread_capture_splitter.dart';
import 'package:scana/services/image_processing/page_crop_decision.dart';
import 'package:scana/services/image_processing/capture_boundary_mapper.dart';
import 'package:scana/services/image_processing/ai_document_segmenter.dart';
import 'package:scana/services/image_processing/ai_primary_crop_policy.dart';
import 'package:scana/services/image_processing/capture_guide_policy.dart';
import 'package:scana/services/storage/scan_session_storage.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/diagnostics/scan_quality_diagnostics.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_page_raster_editor.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_analyzer.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_splitter.dart';

typedef SessionIdGenerator = String Function();
typedef Clock = DateTime Function();

class MlKitScanTarget {
  const MlKitScanTarget({
    required this.sessionId,
    required this.startPageNo,
    required this.createdSession,
  });

  final String sessionId;
  final int startPageNo;
  final bool createdSession;
}

class MlKitPageImport {
  const MlKitPageImport({
    required this.scannedPage,
    required this.sourceType,
    required this.layout,
    required this.originalSourcePath,
    this.parentSpreadId,
    this.spreadSide,
    this.splitX,
    this.splitConfidence,
    this.splitFallbackUsed = false,
    this.cropRect = MlKitCropRect.full,
  });

  final MlKitScannedPage scannedPage;
  final ScanPageSourceType sourceType;
  final MlKitPageLayout layout;
  final String originalSourcePath;
  final String? parentSpreadId;
  final MlKitSpreadSide? spreadSide;
  final int? splitX;
  final double? splitConfidence;
  final bool splitFallbackUsed;
  final MlKitCropRect cropRect;
}

class MlKitPageMutation {
  const MlKitPageMutation({required this.oldRawPaths, required this.pages});

  final List<String> oldRawPaths;
  final List<ScanPage> pages;
}

/// Cleanup contract shared by cancel and the future successful-export flow.
abstract interface class ScanSessionCleanup {
  Future<void> cancelSession();

  Future<void> deleteAfterSuccessfulExport();
}

/// Creates a session on the first capture and owns its ordered raw pages.
class ScanSessionManager extends ChangeNotifier implements ScanSessionCleanup {
  factory ScanSessionManager({
    required ScanSessionStorage storage,
    DocumentDetector documentDetector = const NoOpDocumentDetector(),
    PageCorrector pageCorrector = const UnavailablePageCorrector(),
    PageEnhancer pageEnhancer = const UnavailablePageEnhancer(),
    SpreadCaptureSplitter spreadCaptureSplitter =
        const OpenCvSpreadCaptureSplitter(),
    SpreadFallbackCropper spreadFallbackCropper =
        const OpenCvSpreadFallbackCropper(),
    AiDocumentSegmenter? aiDocumentSegmenter,
    MlKitSpreadAnalyzer mlKitSpreadAnalyzer =
        const ConservativeMlKitSpreadAnalyzer(),
    MlKitSpreadSplitter mlKitSpreadSplitter =
        const LosslessMlKitSpreadSplitter(),
    MlKitPageRasterEditor mlKitPageRasterEditor =
        const LosslessMlKitPageRasterEditor(),
    SessionIdGenerator sessionIdGenerator = _newUuid,
    Clock clock = DateTime.now,
  }) {
    return ScanSessionManager._(
      storage: storage,
      documentDetector: documentDetector,
      pageCorrector: pageCorrector,
      pageEnhancer: pageEnhancer,
      spreadCaptureSplitter: spreadCaptureSplitter,
      spreadFallbackCropper: spreadFallbackCropper,
      aiDocumentSegmenter: aiDocumentSegmenter,
      mlKitSpreadAnalyzer: mlKitSpreadAnalyzer,
      mlKitSpreadSplitter: mlKitSpreadSplitter,
      mlKitPageRasterEditor: mlKitPageRasterEditor,
      sessionIdGenerator: sessionIdGenerator,
      clock: clock,
    );
  }

  ScanSessionManager._({
    required this._storage,
    required this._documentDetector,
    required this._pageCorrector,
    required this._pageEnhancer,
    required this._spreadCaptureSplitter,
    required this._spreadFallbackCropper,
    required this._aiDocumentSegmenter,
    required this._mlKitSpreadAnalyzer,
    required this._mlKitSpreadSplitter,
    required this._mlKitPageRasterEditor,
    required this._sessionIdGenerator,
    required this._clock,
  }) {
    DebugDiagnostics.instance.log('STATE', 'ScanSessionManager.created');
  }

  final ScanSessionStorage _storage;
  final DocumentDetector _documentDetector;
  final PageCorrector _pageCorrector;
  final PageEnhancer _pageEnhancer;
  final SpreadCaptureSplitter _spreadCaptureSplitter;
  final SpreadFallbackCropper _spreadFallbackCropper;
  final AiDocumentSegmenter? _aiDocumentSegmenter;
  final MlKitSpreadAnalyzer _mlKitSpreadAnalyzer;
  final MlKitSpreadSplitter _mlKitSpreadSplitter;
  final MlKitPageRasterEditor _mlKitPageRasterEditor;
  final SessionIdGenerator _sessionIdGenerator;
  final Clock _clock;

  ScanSession? _currentSession;
  bool _isClosed = false;
  Future<void> _processingTail = Future<void>.value();
  int _processingPageCount = 0;
  ScanCaptureMode _captureMode = ScanCaptureMode.single;

  ScanSession? get currentSession => _currentSession;
  int get pageCount => _currentSession?.pages.length ?? 0;
  int get processingPageCount => _processingPageCount;
  ScanCaptureMode get captureMode =>
      _currentSession?.captureMode ?? _captureMode;

  Future<void> setCaptureMode(ScanCaptureMode mode) async {
    _ensureOpen();
    _captureMode = mode;
    final session = _currentSession;
    if (session != null) {
      session.captureMode = mode;
      await _storage.saveSession(session);
    }
    notifyListeners();
  }

  Future<MlKitScanTarget> prepareMlKitScan() async {
    _ensureOpen();
    final createdSession = _currentSession == null;
    final session = await _ensureSession();
    return MlKitScanTarget(
      sessionId: session.id,
      startPageNo: session.pages.length + 1,
      createdSession: createdSession,
    );
  }

  Future<List<ScanPage>> registerMlKitPages(
    List<MlKitScannedPage> scannedPages, {
    ScanPageSourceType sourceType = ScanPageSourceType.mlKit,
  }) => registerMlKitImports(
    scannedPages
        .map(
          (page) => MlKitPageImport(
            scannedPage: page,
            sourceType: sourceType,
            layout: sourceType == ScanPageSourceType.mlKitSpread
                ? MlKitPageLayout.spread
                : MlKitPageLayout.single,
            originalSourcePath: page.filePath,
          ),
        )
        .toList(growable: false),
  );

  Future<List<ScanPage>> registerMlKitImports(
    List<MlKitPageImport> imports,
  ) async {
    _ensureOpen();
    if (imports.isEmpty) return const [];
    final session = _requireSession();
    for (final pageImport in imports) {
      final page = pageImport.scannedPage;
      final file = File(page.filePath);
      if (!await file.exists() || await file.length() != page.byteCount) {
        throw const FileSystemException(
          'An ML Kit scan image is missing or incomplete.',
        );
      }
      if (!await File(pageImport.originalSourcePath).exists()) {
        throw const FileSystemException(
          'The editable ML Kit source is missing.',
        );
      }
    }
    final imported = <ScanPage>[];
    for (final pageImport in imports) {
      final scannedPage = pageImport.scannedPage;
      final page = ScanPage(
        pageNo: session.pages.length + 1,
        rawImagePath: scannedPage.filePath,
        createdTime: _clock(),
        sourceType: pageImport.sourceType,
        mlKitLayout: pageImport.layout,
        originalSourcePath: pageImport.originalSourcePath,
        parentSpreadId: pageImport.parentSpreadId,
        spreadSide: pageImport.spreadSide,
        splitX: pageImport.splitX,
        splitConfidence: pageImport.splitConfidence,
        splitFallbackUsed: pageImport.splitFallbackUsed,
        mlKitCropRect: pageImport.cropRect,
        documentSourceWidth: scannedPage.width,
        documentSourceHeight: scannedPage.height,
      );
      session.addPage(page);
      imported.add(page);
      DebugDiagnostics.instance.log(
        'MLKIT_SCAN',
        'registered pageNo=${page.pageNo} bytes=${scannedPage.byteCount} '
            'size=${scannedPage.width}x${scannedPage.height}',
      );
    }
    await _storage.saveSession(session);
    notifyListeners();
    return List.unmodifiable(imported);
  }

  Future<void> discardEmptyMlKitTarget(MlKitScanTarget target) async {
    if (!target.createdSession) return;
    final session = _currentSession;
    if (session == null ||
        session.id != target.sessionId ||
        session.pages.isNotEmpty) {
      return;
    }
    await _storage.deleteSession(session.id);
    _currentSession = null;
    if (!_isClosed) notifyListeners();
  }

  Future<List<ScanSession>> findRecoverableSessions() {
    _ensureOpen();
    return _storage.findRecoverableSessions();
  }

  void restoreSession(ScanSession session) {
    _ensureOpen();
    if (_currentSession != null) {
      throw StateError('A scan session is already active.');
    }
    _currentSession = session;
    _captureMode = session.captureMode;
    notifyListeners();
  }

  Future<void> deleteRecoveredSession(ScanSession session) async {
    _ensureOpen();
    if (_currentSession?.id == session.id) {
      await cancelSession();
      return;
    }
    await _storage.deleteSession(session.id);
  }

  Future<ScanPage> addRawCapture(
    String capturedImagePath, {
    DocumentPageSide? pageSide,
    CaptureGuideRegion? captureGuideRegion,
    DocumentCorners? stablePreviewCorners,
    PageBoundary? stablePreviewBoundary,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
  }) async {
    _ensureOpen();
    final session = await _ensureSession();
    final pageNo = session.pages.length + 1;
    final rawImagePath = await _storage.storeRawPage(
      sessionId: session.id,
      pageNo: pageNo,
      capturedImagePath: capturedImagePath,
    );
    final page = ScanPage(
      pageNo: pageNo,
      rawImagePath: rawImagePath,
      createdTime: _clock(),
    );
    session.addPage(page);
    await _storage.saveSession(session);
    notifyListeners();
    await _detectPage(
      session,
      session.pages.length - 1,
      captureGuideRegion: captureGuideRegion,
      stablePreviewCorners: stablePreviewCorners,
      stablePreviewBoundary: stablePreviewBoundary,
      captureBoundarySnapshot: captureBoundarySnapshot,
      pageSide: pageSide,
    );
    return session.pages.last;
  }

  /// Creates a page and automatically prepares its default Perspective result.
  /// A failed detection or correction leaves the raw page available as fallback.
  Future<ScanPage> captureAndProcess(
    String capturedImagePath, {
    CaptureGuideRegion? captureGuideRegion,
    DocumentCorners? stablePreviewCorners,
    PageBoundary? stablePreviewBoundary,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
  }) {
    _ensureOpen();
    final completer = Completer<ScanPage>();
    _processingPageCount++;
    notifyListeners();
    _processingTail = _processingTail.then<void>((_) async {
      try {
        completer.complete(
          await _captureAndProcess(
            capturedImagePath,
            captureGuideRegion: captureGuideRegion,
            stablePreviewCorners: stablePreviewCorners,
            stablePreviewBoundary: stablePreviewBoundary,
            captureBoundarySnapshot: captureBoundarySnapshot,
          ),
        );
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _processingPageCount--;
        if (!_isClosed) notifyListeners();
      }
    });
    return completer.future;
  }

  /// Queues two independent ROI pages in deterministic left-to-right order.
  /// The original camera file is never shared by ScanPages: the splitter makes
  /// separate temporary ROI files, which are then moved into separate raw files.
  Future<List<ScanPage>> captureAndProcessSpread(
    String capturedImagePath, {
    PageBoundary? leftStablePreviewBoundary,
    PageBoundary? rightStablePreviewBoundary,
    CaptureBoundarySnapshot? leftCaptureBoundarySnapshot,
    CaptureBoundarySnapshot? rightCaptureBoundarySnapshot,
  }) {
    _ensureOpen();
    final completer = Completer<List<ScanPage>>();
    _processingPageCount += 2;
    notifyListeners();
    _processingTail = _processingTail.then<void>((_) async {
      try {
        completer.complete(
          await _captureAndProcessSpread(
            capturedImagePath,
            leftStablePreviewBoundary: leftStablePreviewBoundary,
            rightStablePreviewBoundary: rightStablePreviewBoundary,
            leftCaptureBoundarySnapshot: leftCaptureBoundarySnapshot,
            rightCaptureBoundarySnapshot: rightCaptureBoundarySnapshot,
          ),
        );
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _processingPageCount -= 2;
        if (!_isClosed) notifyListeners();
      }
    });
    return completer.future;
  }

  Future<ScanPage> _captureAndProcess(
    String capturedImagePath, {
    DocumentPageSide? pageSide,
    CaptureGuideRegion? captureGuideRegion,
    DocumentCorners? stablePreviewCorners,
    PageBoundary? stablePreviewBoundary,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
  }) async {
    final totalStopwatch = Stopwatch()..start();
    final detectionStopwatch = Stopwatch()..start();
    final page = await addRawCapture(
      capturedImagePath,
      captureGuideRegion: captureGuideRegion,
      stablePreviewCorners: stablePreviewCorners,
      stablePreviewBoundary: stablePreviewBoundary,
      captureBoundarySnapshot: captureBoundarySnapshot,
      pageSide: pageSide,
    );
    detectionStopwatch.stop();
    DebugDiagnostics.instance.log(
      'IMAGE_PROCESSING',
      'Detection: ${detectionStopwatch.elapsedMilliseconds} ms',
    );
    final session = _requireSession();
    final index = session.pages.indexOf(page);
    if (index >= 0 && page.documentCorners != null) {
      final correctionStopwatch = Stopwatch()..start();
      await _runAutomaticCorrectionPipelineAt(
        index,
        enhancementMode: EnhancementMode.scanColor,
      );
      correctionStopwatch.stop();
      DebugDiagnostics.instance.log(
        'IMAGE_PROCESSING',
        'Automatic correction: ${correctionStopwatch.elapsedMilliseconds} ms',
      );
      // Curvature analysis and Enhancement are part of the same automatic job.
    }
    totalStopwatch.stop();
    DebugDiagnostics.instance.log(
      'IMAGE_PROCESSING',
      'Total: ${totalStopwatch.elapsedMilliseconds} ms',
    );
    return session.pages[index >= 0 ? index : session.pages.length - 1];
  }

  Future<List<ScanPage>> _captureAndProcessSpread(
    String capturedImagePath, {
    PageBoundary? leftStablePreviewBoundary,
    PageBoundary? rightStablePreviewBoundary,
    CaptureBoundarySnapshot? leftCaptureBoundarySnapshot,
    CaptureBoundarySnapshot? rightCaptureBoundarySnapshot,
  }) async {
    await _ensureSession();
    final parts = await _spreadCaptureSplitter.split(capturedImagePath);
    try {
      final left = await _captureAndProcessSpreadSide(
        parts.leftImagePath,
        pageSide: DocumentPageSide.left,
        stablePreviewBoundary: leftStablePreviewBoundary,
        captureBoundarySnapshot: leftCaptureBoundarySnapshot,
      );
      final right = await _captureAndProcessSpreadSide(
        parts.rightImagePath,
        pageSide: DocumentPageSide.right,
        stablePreviewBoundary: rightStablePreviewBoundary,
        captureBoundarySnapshot: rightCaptureBoundarySnapshot,
      );
      return [left, right];
    } finally {
      for (final temporaryPath in [parts.leftImagePath, parts.rightImagePath]) {
        final temporary = File(temporaryPath);
        if (await temporary.exists()) {
          await temporary.delete();
        }
      }
      final original = File(capturedImagePath);
      if (await original.exists()) {
        await original.delete();
      }
    }
  }

  Future<ScanPage> _captureAndProcessSpreadSide(
    String capturedImagePath, {
    required DocumentPageSide pageSide,
    PageBoundary? stablePreviewBoundary,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
  }) async {
    final page = await addRawCapture(
      capturedImagePath,
      pageSide: pageSide,
      captureGuideRegion: CaptureGuidePolicy.spreadForRoi(pageSide),
      stablePreviewBoundary: stablePreviewBoundary,
      captureBoundarySnapshot: captureBoundarySnapshot,
    );
    final session = _requireSession();
    final index = session.pages.indexOf(page);
    if (index < 0) return session.pages.last;

    final detectedPage = session.pages[index];
    if (detectedPage.documentCorners != null &&
        detectedPage.cropSource != CropSource.guideFallback) {
      final corrected = await _runAutomaticCorrectionPipelineAt(
        index,
        enhancementMode: EnhancementMode.scanColor,
      );
      if (corrected) {
        return session.pages[index];
      }
    }
    final fallbackCreated = await _createSpreadFallback(
      session,
      index,
      pageSide,
    );
    if (fallbackCreated) {
      await _completeAutomaticPipelineFromPerspectiveAt(
        index,
        enhancementMode: EnhancementMode.scanColor,
      );
    }
    return session.pages[index];
  }

  Future<bool> _createSpreadFallback(
    ScanSession session,
    int index,
    DocumentPageSide pageSide,
  ) async {
    final page = session.pages[index];
    CorrectionOutputTarget? outputTarget;
    try {
      outputTarget = await _storage.prepareCorrectionOutput(
        sessionId: session.id,
        rawImagePath: page.rawImagePath,
        type: CorrectionType.perspective,
      );
      await _spreadFallbackCropper.crop(
        sourceImagePath: page.rawImagePath,
        outputImagePath: outputTarget.workingPath,
        pageSide: pageSide,
      );
      final correctedImagePath = await _storage.commitCorrectionOutput(
        outputTarget,
      );
      session.replacePageAt(index, page.withSpreadFallback(correctedImagePath));
      await _storage.saveSession(session);
      notifyListeners();
      return true;
    } on Object {
      if (outputTarget != null) {
        try {
          await _storage.discardCorrectionOutput(outputTarget);
        } on Object {
          // Raw ROI remains the final safety fallback.
        }
      }
      session.updateCorrectionAt(
        index,
        status: CorrectionStatus.failed,
        type: CorrectionType.perspective,
      );
      await _storage.saveSession(session);
      notifyListeners();
      return false;
    }
  }

  /// Replaces one page only after the replacement raw image and Perspective
  /// result have both been persisted successfully.
  Future<bool> replacePageAt(
    int index,
    String capturedImagePath, {
    CaptureGuideRegion? captureGuideRegion,
    DocumentCorners? stablePreviewCorners,
    PageBoundary? stablePreviewBoundary,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
  }) async {
    _ensureOpen();
    final session = _requireSession();
    final previousPage = session.pages[index];
    ScanPage? candidate;
    try {
      final rawImagePath = await _storage.storeRawPage(
        sessionId: session.id,
        pageNo: previousPage.pageNo,
        capturedImagePath: capturedImagePath,
      );
      candidate = ScanPage(
        pageNo: previousPage.pageNo,
        rawImagePath: rawImagePath,
        createdTime: _clock(),
      );
      final detection = await _documentDetector.detect(rawImagePath);
      final guideCorners =
          captureGuideRegion != null &&
              detection.sourceWidth > 0 &&
              detection.sourceHeight > 0
          ? captureGuideRegion.toSourceCorners(
              detection.sourceWidth,
              detection.sourceHeight,
            )
          : null;
      final previewCorners = _previewCornersForSource(
        stablePreviewCorners,
        detection.sourceWidth,
        detection.sourceHeight,
      );
      final previewBoundary = _previewBoundaryForSource(
        stablePreviewBoundary,
        detection.sourceWidth,
        detection.sourceHeight,
      );
      final effectivePreviewBoundary =
          previewBoundary ??
          _boundaryFromCorners(
            previewCorners,
            detection.sourceWidth,
            detection.sourceHeight,
            confidence: 1,
          );
      final captureBoundary = captureBoundarySnapshot == null
          ? effectivePreviewBoundary
          : CaptureBoundaryMapper.toJpegBoundary(
              captureBoundarySnapshot,
              jpegWidth: detection.sourceWidth,
              jpegHeight: detection.sourceHeight,
            );
      final openCvDecision = PageCropDecisionPolicy.decide(
        detection: detection,
        guideCorners: guideCorners ?? previousPage.documentCorners,
        captureBoundary: captureBoundary,
      );
      final aiSegmentation = await _runAiComparison(
        imagePath: rawImagePath,
        pageSide: null,
        openCvCorners: openCvDecision?.corners,
        expectedGuideCorners: guideCorners,
        openCvConfidence: detection.confidence,
        cropSource: openCvDecision?.source,
      );
      final decision = _selectProductionCrop(
        aiSegmentation: aiSegmentation,
        openCvDecision: openCvDecision,
        sourceWidth: detection.sourceWidth,
        sourceHeight: detection.sourceHeight,
        pageSide: null,
        expectedGuideCorners: guideCorners,
      );
      if (decision == null) {
        await _storage.deletePageFiles(candidate);
        return false;
      }
      candidate = candidate
          .withDetection(
            detection,
            resolvedCorners: decision.corners,
            resolvedBoundary: decision.boundary,
            cropSource: decision.source,
            captureBoundaryConfidence:
                captureBoundarySnapshot?.confidence ??
                captureBoundary?.confidence,
            captureBoundaryStability:
                captureBoundarySnapshot?.stability ??
                captureBoundary?.stability,
          )
          .copyWith(
            captureGuideCorners: guideCorners,
            aiSegmentationResult: aiSegmentation,
          );
      final corrected = await _createPerspectiveResult(session, candidate);
      if (corrected == null) {
        await _storage.deletePageFiles(candidate);
        return false;
      }

      final automaticGeometry = await _createAutomaticCurvedResult(
        session,
        corrected,
      );
      final enhanced = await _createEnhancedResult(
        session,
        automaticGeometry,
        EnhancementMode.scanColor,
      );
      session.replacePageAt(index, enhanced);
      await _storage.saveSession(session);
      await _storage.deletePageFiles(previousPage);
      notifyListeners();
      return true;
    } on Object {
      if (candidate != null) {
        try {
          await _storage.deletePageFiles(candidate);
        } on Object {
          // The previous confirmed page remains intact.
        }
      }
      return false;
    }
  }

  Future<MlKitSpreadAnalysis> analyzeMlKitPageAt(int index) async {
    _ensureOpen();
    final page = _requireSession().pages[index];
    if (!page.isMlKitPage) {
      throw StateError('Only ML Kit pages support spread analysis.');
    }
    return _mlKitSpreadAnalyzer.analyze(await _mlKitSourceDescriptor(page));
  }

  Future<MlKitPageMutation> cropMlKitPageAt(
    int index,
    MlKitCropRect previewCrop,
  ) async {
    _ensureOpen();
    final session = _requireSession();
    final previous = session.pages[index];
    if (!previous.isMlKitPage) {
      throw StateError('Only ML Kit pages support lossless crop editing.');
    }
    final unrotated = MlKitCropRect.unrotate(previewCrop, previous.rotation);
    final absolute = (previous.mlKitCropRect ?? MlKitCropRect.full).compose(
      unrotated,
    );
    final raster = await _mlKitPageRasterEditor.render(
      page: previous,
      cropRect: absolute,
    );
    final updated = previous.copyWith(
      mlKitCropRect: raster.cropRect,
      editedImagePath: raster.page.filePath,
      documentSourceWidth: raster.page.width,
      documentSourceHeight: raster.page.height,
    );
    session.replacePageAt(index, updated);
    await _storage.saveSession(session);
    await _deleteUnreferencedMlKitFiles([previous], session.pages);
    notifyListeners();
    return MlKitPageMutation(
      oldRawPaths: [previous.rawImagePath],
      pages: [session.pages[index]],
    );
  }

  Future<MlKitPageMutation> rotateMlKitPageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    final previous = session.pages[index];
    if (!previous.isMlKitPage) {
      throw StateError('Only ML Kit pages use the lossless edit rotation.');
    }
    final raster = await _mlKitPageRasterEditor.render(
      page: previous,
      cropRect: previous.mlKitCropRect ?? MlKitCropRect.full,
    );
    final updated = previous.copyWith(
      rotation: (previous.rotation + 90) % 360,
      mlKitCropRect: raster.cropRect,
      editedImagePath: raster.page.filePath,
      documentSourceWidth: raster.page.width,
      documentSourceHeight: raster.page.height,
    );
    session.replacePageAt(index, updated);
    await _storage.saveSession(session);
    await _deleteUnreferencedMlKitFiles([previous], session.pages);
    notifyListeners();
    return MlKitPageMutation(
      oldRawPaths: [previous.rawImagePath],
      pages: [session.pages[index]],
    );
  }

  Future<MlKitPageMutation> splitMlKitPageAt(
    int index, {
    required int splitX,
    required double confidence,
    required bool fallbackUsed,
  }) async {
    _ensureOpen();
    final session = _requireSession();
    final previous = session.pages[index];
    if (!previous.isMlKitPage || previous.isMlKitSpreadChild) {
      throw StateError('The page cannot be converted to a spread.');
    }
    final source = await _mlKitSourceDescriptor(previous);
    final groupId = 'spread_${const Uuid().v4().replaceAll('-', '')}';
    final split = await _mlKitSpreadSplitter.split(
      sessionId: session.id,
      leftPageNo: previous.pageNo,
      source: source,
      detection: MlKitSpineDetection(
        splitX: splitX,
        confidence: confidence,
        usedFallback: fallbackUsed,
      ),
      outputStem: groupId,
    );
    final children = _spreadChildren(
      previous: previous,
      split: split,
      parentSpreadId: groupId,
    );
    session.replacePageRange(index, 1, children);
    await _storage.saveSession(session);
    await _deleteUnreferencedMlKitFiles([previous], session.pages);
    notifyListeners();
    return MlKitPageMutation(
      oldRawPaths: [previous.rawImagePath],
      pages: session.pages
          .where((page) => page.parentSpreadId == groupId)
          .toList(growable: false),
    );
  }

  Future<MlKitPageMutation> adjustMlKitSpreadAt(int index, int splitX) async {
    _ensureOpen();
    final session = _requireSession();
    final selected = session.pages[index];
    final groupId = selected.parentSpreadId;
    if (!selected.isMlKitSpreadChild || groupId == null) {
      throw StateError('The page is not an editable spread child.');
    }
    final previous = session.pages
        .where((page) => page.parentSpreadId == groupId)
        .toList(growable: false);
    final oldPaths = previous.map((page) => page.rawImagePath).toList();
    final source = await _mlKitSourceDescriptor(selected);
    final outputStem = 'spread_${const Uuid().v4().replaceAll('-', '')}';
    final split = await _mlKitSpreadSplitter.split(
      sessionId: session.id,
      leftPageNo: previous.first.pageNo,
      source: source,
      detection: MlKitSpineDetection(
        splitX: splitX,
        confidence: selected.splitConfidence ?? 1,
        usedFallback: false,
      ),
      outputStem: outputStem,
    );
    final children = _spreadChildren(
      previous: selected,
      split: split,
      parentSpreadId: groupId,
      leftRotation: previous
          .where((page) => page.spreadSide == MlKitSpreadSide.left)
          .firstOrNull
          ?.rotation,
      rightRotation: previous
          .where((page) => page.spreadSide == MlKitSpreadSide.right)
          .firstOrNull
          ?.rotation,
    );
    session.replacePagesByRawPath(oldPaths.toSet(), children);
    await _storage.saveSession(session);
    await _deleteUnreferencedMlKitFiles(previous, session.pages);
    notifyListeners();
    return MlKitPageMutation(
      oldRawPaths: oldPaths,
      pages: session.pages
          .where((page) => page.parentSpreadId == groupId)
          .toList(growable: false),
    );
  }

  Future<MlKitPageMutation> restoreMlKitSpreadAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    final selected = session.pages[index];
    final groupId = selected.parentSpreadId;
    if (!selected.isMlKitSpreadChild || groupId == null) {
      throw StateError('The page is not an editable spread child.');
    }
    final previous = session.pages
        .where((page) => page.parentSpreadId == groupId)
        .toList(growable: false);
    final oldPaths = previous.map((page) => page.rawImagePath).toList();
    final source = await _mlKitSourceDescriptor(selected);
    final restored = ScanPage(
      pageNo: previous.map((page) => page.pageNo).reduce(math.min),
      rawImagePath: source.filePath,
      createdTime: previous.first.createdTime,
      sourceType: ScanPageSourceType.mlKit,
      mlKitLayout: MlKitPageLayout.single,
      originalSourcePath: source.filePath,
      splitX: selected.splitX,
      splitConfidence: selected.splitConfidence,
      splitFallbackUsed: selected.splitFallbackUsed,
      mlKitCropRect: MlKitCropRect.full,
      rotation: previous.first.rotation,
      documentSourceWidth: source.width,
      documentSourceHeight: source.height,
    );
    session.replacePagesByRawPath(oldPaths.toSet(), [restored]);
    await _storage.saveSession(session);
    await _deleteUnreferencedMlKitFiles(previous, session.pages);
    notifyListeners();
    final current = session.pages.firstWhere(
      (page) => page.rawImagePath == source.filePath,
    );
    return MlKitPageMutation(oldRawPaths: oldPaths, pages: [current]);
  }

  Future<void> deletePageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
    if (page.isMlKitPage) {
      session.removePageAt(index);
      await _storage.saveSession(session);
      await _deleteUnreferencedMlKitFiles([page], session.pages);
    } else {
      await _storage.deletePageFiles(page);
      session.removePageAt(index);
      await _storage.saveSession(session);
    }
    notifyListeners();
  }

  Future<void> reorderPages(int oldIndex, int newIndex) async {
    _ensureOpen();
    final session = _requireSession();
    session.reorderPages(oldIndex, newIndex);
    await _storage.saveSession(session);
    notifyListeners();
  }

  Future<void> rotatePageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    session.rotatePageAt(index);
    await _storage.saveSession(session);
    notifyListeners();
  }

  Future<void> updateDocumentCornersAt(
    int index,
    DocumentCorners corners,
  ) async {
    _ensureOpen();
    final session = _requireSession();
    if (!session.pages[index].usesCustomImagePipeline) {
      DebugDiagnostics.instance.log(
        'MLKIT_SCAN',
        'custom corners skipped pageNo=${session.pages[index].pageNo}',
      );
      return;
    }
    session.updateDocumentCornersAt(index, corners);
    await _storage.saveSession(session);
    notifyListeners();
  }

  /// Applies user-confirmed corners and rebuilds the full-resolution scan
  /// result. The existing corrected/enhanced revisions remain referenced until
  /// the replacement succeeds, so a failed retry never destroys the page.
  Future<bool> applyManualCornersAt(int index, DocumentCorners corners) async {
    _ensureOpen();
    final session = _requireSession();
    final previousPage = session.pages[index];
    if (!previousPage.usesCustomImagePipeline) return false;
    final stopwatch = Stopwatch()..start();
    await updateDocumentCornersAt(index, corners);
    final corrected = await _runAutomaticCorrectionPipelineAt(
      index,
      enhancementMode: previousPage.enhancementMode,
    );
    if (!corrected) {
      session.replacePageAt(index, previousPage);
      await _storage.saveSession(session);
      notifyListeners();
    }
    stopwatch.stop();
    final page = _requireSession().pages[index];
    DebugDiagnostics.instance.log(
      'QUICK_CORNER_EDIT',
      'apply pageNo=${page.pageNo} corrected=$corrected '
          'enhancement=${page.enhancementStatus.name} '
          'totalMs=${stopwatch.elapsedMilliseconds}',
    );
    return corrected;
  }

  Future<bool> detectPageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    if (!session.pages[index].usesCustomImagePipeline) return false;
    return _detectPage(session, index);
  }

  Future<bool> _runAutomaticCorrectionPipelineAt(
    int index, {
    required EnhancementMode enhancementMode,
  }) async {
    final perspectiveApplied = await correctPageAt(
      index,
      CorrectionType.perspective,
      enhanceAfterCorrection: false,
    );
    if (!perspectiveApplied) return false;
    await _completeAutomaticPipelineFromPerspectiveAt(
      index,
      enhancementMode: enhancementMode,
    );
    return true;
  }

  Future<void> _completeAutomaticPipelineFromPerspectiveAt(
    int index, {
    required EnhancementMode enhancementMode,
  }) async {
    final session = _requireSession();
    final geometryResult = await _createAutomaticCurvedResult(
      session,
      session.pages[index],
    );
    session.replacePageAt(index, geometryResult);
    await _storage.saveSession(session);
    notifyListeners();
    await enhancePageAt(index, enhancementMode);
  }

  Future<ScanPage> _createAutomaticCurvedResult(
    ScanSession session,
    ScanPage perspectivePage,
  ) async {
    final perspectivePath = perspectivePage.correctedImagePath;
    if (perspectivePath == null) return perspectivePage;
    CorrectionOutputTarget? outputTarget;
    final stopwatch = Stopwatch()..start();
    try {
      outputTarget = await _storage.prepareCorrectionOutput(
        sessionId: session.id,
        rawImagePath: perspectivePage.rawImagePath,
        type: CorrectionType.curved,
      );
      final sourceWidth = _imageWidthFromPage(perspectivePage);
      final sourceHeight = _imageHeightFromPage(perspectivePage);
      final curvatureBoundary = _curvatureBoundaryForPage(perspectivePage);
      final result = await _pageCorrector.correct(
        sourceImagePath: perspectivePath,
        outputImagePath: outputTarget.workingPath,
        // The raster is already rectified, but raw-coordinate corners and the
        // owned paper contour preserve normalized outer-edge curvature.
        corners:
            perspectivePage.documentCorners ??
            _fullImageCornersFromSize(sourceWidth, sourceHeight),
        type: CorrectionType.curved,
        boundaryMode: curvatureBoundary == null
            ? PageBoundaryMode.insetFallback
            : PageBoundaryMode.detected,
        pageBoundary: curvatureBoundary,
      );
      final state = result.curvatureState;
      if (state != CurvatureState.mildCurve &&
          state != CurvatureState.strongCurve) {
        final artifactStem = path.basenameWithoutExtension(
          outputTarget.workingPath,
        );
        await _storage.discardCorrectionOutput(outputTarget);
        stopwatch.stop();
        final fallbackState = state == CurvatureState.flat
            ? CurvatureState.flat
            : CurvatureState.unreliable;
        _logAutomaticCurvature(
          perspectivePage,
          result.diagnostics,
          stopwatch.elapsedMilliseconds,
          fallbackState,
          false,
          'missing_or_non_applicable_state',
        );
        await ScanQualityDiagnostics.recordCurvatureDecision(
          page: perspectivePage,
          perspectivePath: perspectivePath,
          state: fallbackState,
          applied: false,
          diagnostics: result.diagnostics,
          rejectReason: 'missing_or_non_applicable_state',
          nativeArtifactStem: artifactStem,
        );
        return perspectivePage.withAutomaticCurvature(
          state: fallbackState,
          applied: false,
          confidence: result.curvedConfidence,
          magnitude: result.curvatureMagnitude,
          rejectReason: 'missing_or_non_applicable_state',
        );
      }
      final curvedPath = await _storage.commitCorrectionOutput(outputTarget);
      await ScanQualityDiagnostics.recordCorrection(
        page: perspectivePage,
        type: CorrectionType.curved,
        sourcePath: perspectivePath,
        outputPath: curvedPath,
        result: result,
      );
      stopwatch.stop();
      _logAutomaticCurvature(
        perspectivePage,
        result.diagnostics,
        stopwatch.elapsedMilliseconds,
        state,
        true,
        null,
      );
      await ScanQualityDiagnostics.recordCurvatureDecision(
        page: perspectivePage,
        perspectivePath: perspectivePath,
        curvedPath: curvedPath,
        state: state,
        applied: true,
        diagnostics: result.diagnostics,
        nativeArtifactStem: path.basenameWithoutExtension(
          outputTarget.workingPath,
        ),
      );
      return perspectivePage.withAutomaticCurvature(
        state: state,
        applied: true,
        confidence: result.curvedConfidence,
        magnitude: result.curvatureMagnitude,
        correctedImagePath: curvedPath,
      );
    } on Object catch (error) {
      final artifactStem = outputTarget == null
          ? null
          : path.basenameWithoutExtension(outputTarget.workingPath);
      if (outputTarget != null) {
        try {
          await _storage.discardCorrectionOutput(outputTarget);
        } on Object {
          // Perspective remains the confirmed geometry fallback.
        }
      }
      stopwatch.stop();
      final failure = error is PageCorrectionFailure ? error : null;
      final diagnostics = failure?.diagnostics ?? const <String, Object>{};
      final state = _curvatureStateFromFailure(failure);
      final rejectReason =
          diagnostics['rejectReason'] as String? ??
          diagnostics['rejectionReason'] as String? ??
          failure?.reason ??
          'curvature_analysis_failed';
      _logAutomaticCurvature(
        perspectivePage,
        diagnostics,
        stopwatch.elapsedMilliseconds,
        state,
        false,
        rejectReason,
      );
      await ScanQualityDiagnostics.recordCurvatureDecision(
        page: perspectivePage,
        perspectivePath: perspectivePath,
        state: state,
        applied: false,
        diagnostics: diagnostics,
        rejectReason: rejectReason,
        nativeArtifactStem: artifactStem,
      );
      return perspectivePage.withAutomaticCurvature(
        state: state,
        applied: false,
        confidence: (diagnostics['confidence'] as num?)?.toDouble(),
        magnitude: (diagnostics['curvatureMagnitude'] as num?)?.toDouble(),
        rejectReason: rejectReason,
      );
    }
  }

  static CurvatureState _curvatureStateFromFailure(
    PageCorrectionFailure? failure,
  ) {
    final serialized = failure?.diagnostics['curvatureState'];
    return CurvatureState.values.firstWhere(
      (state) => state.name == serialized,
      orElse: () => failure?.outcome == CorrectionOutcome.nearlyFlat
          ? CurvatureState.flat
          : CurvatureState.unreliable,
    );
  }

  static void _logAutomaticCurvature(
    ScanPage page,
    Map<String, Object> diagnostics,
    int totalMilliseconds,
    CurvatureState state,
    bool applied,
    String? rejectReason,
  ) {
    DebugDiagnostics.instance.log(
      'CURVED_AUTO',
      'page=${page.pageNo} state=${state.name} applied=$applied '
          'detectMs=${diagnostics['detectMs'] ?? totalMilliseconds} '
          'dewarpMs=${diagnostics['dewarpMs'] ?? 0} '
          'combinedMagnitude=${diagnostics['combinedMagnitude'] ?? diagnostics['curvatureMagnitude'] ?? 0} '
          'pageContourMagnitude=${diagnostics['pageContourMagnitude'] ?? 0} '
          'topCurve=${diagnostics['topCurve'] ?? 0} '
          'bottomCurve=${diagnostics['bottomCurve'] ?? 0} '
          'spineCurve=${diagnostics['spineCurve'] ?? 0} '
          'internalLineMagnitude=${diagnostics['internalLineMagnitude'] ?? 0} '
          'effectiveDeformationMagnitude=${diagnostics['effectiveDeformationMagnitude'] ?? 0} '
          'topRawSign=${diagnostics['topRawSign'] ?? 0} '
          'bottomRawSign=${diagnostics['bottomRawSign'] ?? 0} '
          'spineRawSign=${diagnostics['spineRawSign'] ?? 0} '
          'topNormalizedSign=${diagnostics['topNormalizedSign'] ?? 0} '
          'bottomNormalizedSign=${diagnostics['bottomNormalizedSign'] ?? 0} '
          'spineNormalizedSign=${diagnostics['spineNormalizedSign'] ?? 0} '
          'directionConflictBeforeNormalization=${diagnostics['directionConflictBeforeNormalization'] ?? false} '
          'directionConflictAfterNormalization=${diagnostics['directionConflictAfterNormalization'] ?? false} '
          'signConvention=${diagnostics['signConvention'] ?? "unknown"} '
          'horizontalDirectionVotes=${diagnostics['horizontalDirectionVotes'] ?? const <String, Object>{}} '
          'spineUsedForDirectionConflict=${diagnostics['spineUsedForDirectionConflict'] ?? false} '
          'coverage=${diagnostics['coverage'] ?? 0} '
          'evidence=${diagnostics['evidenceCount'] ?? 0} '
          'consistency=${diagnostics['consistency'] ?? 0} '
          'confidence=${diagnostics['confidence'] ?? 0} '
          'deformationStrength=${diagnostics['deformationStrength'] ?? 0} '
          'straightnessBefore=${diagnostics['perspectiveStraightness'] ?? 0} '
          'straightnessAfter=${diagnostics['curvedStraightness'] ?? 0} '
          'geometryBefore=${diagnostics['geometryBefore'] ?? 0} '
          'geometryAfter=${diagnostics['geometryAfter'] ?? 0} '
          'rejectReason=${rejectReason ?? "none"} totalMs=$totalMilliseconds',
    );
  }

  static int _imageWidthFromPage(ScanPage page) {
    final qualityWidth = page.documentSourceWidth;
    return qualityWidth != null && qualityWidth > 1 ? qualityWidth : 2;
  }

  static int _imageHeightFromPage(ScanPage page) {
    final qualityHeight = page.documentSourceHeight;
    return qualityHeight != null && qualityHeight > 1 ? qualityHeight : 2;
  }

  static DocumentCorners _fullImageCornersFromSize(int width, int height) {
    final right = (width - 1).toDouble();
    final bottom = (height - 1).toDouble();
    return DocumentCorners(
      topLeft: const DocumentPoint(0, 0),
      topRight: DocumentPoint(right, 0),
      bottomRight: DocumentPoint(right, bottom),
      bottomLeft: DocumentPoint(0, bottom),
    );
  }

  static PageBoundary? _curvatureBoundaryForPage(ScanPage page) {
    final corners = page.documentCorners;
    final width = page.documentSourceWidth;
    final height = page.documentSourceHeight;
    final ai = page.aiSegmentationResult;
    if (corners != null &&
        width != null &&
        height != null &&
        ai != null &&
        ai.paperContour.isNotEmpty) {
      final spineSide = switch (ai.pageSide) {
        'left' => PageBoundarySide.right,
        'right' => PageBoundarySide.left,
        _ => null,
      };
      final boundary = PageContourGeometryEvidence.boundaryFromContour(
        contour: ai.paperContour,
        corners: corners,
        sourceWidth: width,
        sourceHeight: height,
        spineSide: spineSide,
      );
      if (boundary != null) return boundary;
    }
    final existing = page.pageBoundary;
    if (existing != null &&
        (existing.top.length >= 4 || existing.bottom.length >= 4)) {
      return existing;
    }
    return null;
  }

  Future<bool> correctPageAt(
    int index,
    CorrectionType type, {
    bool enhanceAfterCorrection = true,
  }) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
    if (!page.usesCustomImagePipeline) {
      DebugDiagnostics.instance.log(
        'MLKIT_SCAN',
        'custom correction skipped pageNo=${page.pageNo}',
      );
      return false;
    }
    final corners = page.documentCorners;
    if (corners == null) {
      session.updateCorrectionAt(
        index,
        status: CorrectionStatus.failed,
        type: type,
      );
      await _storage.saveSession(session);
      notifyListeners();
      return false;
    }

    CorrectionOutputTarget? outputTarget;
    String? protectedPerspectivePath;
    PageCorrectionResult? protectedPerspectiveResult;
    final enhancementMode = page.enhancementMode;
    try {
      session.updateCorrectionAt(
        index,
        status: CorrectionStatus.processing,
        type: type,
      );
      await _storage.saveSession(session);
      notifyListeners();

      final boundaryMode = CurvedPagePolicy.selectBoundaryMode(
        corners: corners,
        sourceWidth: page.documentSourceWidth,
        sourceHeight: page.documentSourceHeight,
      );
      var correctionSourcePath = page.rawImagePath;
      if (type == CorrectionType.curved) {
        outputTarget = await _storage.prepareCorrectionOutput(
          sessionId: session.id,
          rawImagePath: page.rawImagePath,
          type: CorrectionType.perspective,
        );
        protectedPerspectiveResult = await _pageCorrector.correct(
          sourceImagePath: page.rawImagePath,
          outputImagePath: outputTarget.workingPath,
          corners: corners,
          type: CorrectionType.perspective,
          boundaryMode: boundaryMode,
          pageBoundary: page.pageBoundary,
        );
        protectedPerspectivePath = await _storage.commitCorrectionOutput(
          outputTarget,
        );
        await ScanQualityDiagnostics.recordCorrection(
          page: page,
          type: CorrectionType.perspective,
          sourcePath: page.rawImagePath,
          outputPath: protectedPerspectivePath,
          result: protectedPerspectiveResult,
        );
        outputTarget = null;
        correctionSourcePath = protectedPerspectivePath;
        session.updateCorrectionAt(
          index,
          status: CorrectionStatus.processing,
          type: type,
          correctedImagePath: protectedPerspectivePath,
        );
        await _storage.saveSession(session);
        notifyListeners();
      }

      outputTarget = await _storage.prepareCorrectionOutput(
        sessionId: session.id,
        rawImagePath: page.rawImagePath,
        type: type,
      );
      final curvedInputCorners = protectedPerspectiveResult == null
          ? corners
          : _fullImageCorners(protectedPerspectiveResult);
      final curvatureBoundary = type == CorrectionType.curved
          ? _curvatureBoundaryForPage(page)
          : null;
      final correctionResult = await _pageCorrector.correct(
        sourceImagePath: correctionSourcePath,
        outputImagePath: outputTarget.workingPath,
        corners: type == CorrectionType.curved && curvatureBoundary != null
            ? corners
            : curvedInputCorners,
        type: type,
        boundaryMode: type == CorrectionType.curved
            ? curvatureBoundary == null
                  ? PageBoundaryMode.insetFallback
                  : PageBoundaryMode.detected
            : boundaryMode,
        // Only normalized deviation from each raw contour chord is reused;
        // absolute RAW coordinates are never applied to the rectified raster.
        pageBoundary: type == CorrectionType.curved
            ? curvatureBoundary
            : page.pageBoundary,
      );
      if (protectedPerspectiveResult != null &&
          !CorrectionOutputSanity.preservesPerspectiveCanvas(
            perspective: protectedPerspectiveResult,
            curved: correctionResult,
          )) {
        throw const PageCorrectionFailure(
          CorrectionOutcome.unsafeDeformation,
          'Curved output changed the perspective canvas unexpectedly.',
        );
      }
      final correctedImagePath = await _storage.commitCorrectionOutput(
        outputTarget,
      );
      await ScanQualityDiagnostics.recordCorrection(
        page: page,
        type: type,
        sourcePath: correctionSourcePath,
        outputPath: correctedImagePath,
        result: correctionResult,
      );
      session.updateCorrectionAt(
        index,
        status: CorrectionStatus.completed,
        type: type,
        correctedImagePath: correctedImagePath,
        outcome: correctionResult.outcome,
      );
      if (type == CorrectionType.curved) {
        DebugDiagnostics.instance.log(
          'CURVED_CORRECTION',
          'accepted ${_diagnosticsSummary(correctionResult.diagnostics)}',
        );
      }
      await _storage.saveSession(session);
      notifyListeners();
      if (enhanceAfterCorrection) {
        try {
          await enhancePageAt(index, enhancementMode);
        } on Object catch (error) {
          DebugDiagnostics.instance.log(
            'IMAGE_PROCESSING',
            'Enhancement state update failed after correction: $error',
          );
        }
      }
      return true;
    } on Object catch (error) {
      if (outputTarget != null) {
        try {
          await _storage.discardCorrectionOutput(outputTarget);
        } on Object {
          // The failed working file is not referenced by session metadata.
        }
      }
      session.updateCorrectionAt(
        index,
        status: CorrectionStatus.failed,
        type: type,
        correctedImagePath: protectedPerspectivePath,
        outcome: error is PageCorrectionFailure
            ? error.outcome
            : type == CorrectionType.curved
            ? CorrectionOutcome.lowConfidence
            : CorrectionOutcome.none,
        failureReason: error is PageCorrectionFailure
            ? error.reason
            : 'correction_failed',
      );
      if (type == CorrectionType.curved) {
        DebugDiagnostics.instance.log(
          'CURVED_CORRECTION',
          'rejected reason=${error is PageCorrectionFailure ? error.reason : "correction_failed"} '
              '${error is PageCorrectionFailure ? _diagnosticsSummary(error.diagnostics) : "error=$error"}',
        );
      }
      try {
        await _storage.saveSession(session);
      } on Object {
        // Raw page and previous correction remain available in memory and disk.
      }
      notifyListeners();
      if (protectedPerspectivePath != null && enhanceAfterCorrection) {
        try {
          await enhancePageAt(index, enhancementMode);
        } on Object catch (enhancementError) {
          DebugDiagnostics.instance.log(
            'IMAGE_PROCESSING',
            'Perspective fallback enhancement failed: $enhancementError',
          );
        }
      }
      return false;
    }
  }

  static DocumentCorners _fullImageCorners(PageCorrectionResult result) {
    final right = (result.outputWidth - 1).toDouble();
    final bottom = (result.outputHeight - 1).toDouble();
    return DocumentCorners(
      topLeft: const DocumentPoint(0, 0),
      topRight: DocumentPoint(right, 0),
      bottomRight: DocumentPoint(right, bottom),
      bottomLeft: DocumentPoint(0, bottom),
    );
  }

  static String _diagnosticsSummary(Map<String, Object> diagnostics) =>
      diagnostics.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(' ');

  Future<bool> enhancePageAt(int index, EnhancementMode mode) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
    if (!page.usesCustomImagePipeline) {
      DebugDiagnostics.instance.log(
        'MLKIT_SCAN',
        'custom enhancement skipped pageNo=${page.pageNo}',
      );
      return false;
    }
    session.updateEnhancementAt(
      index,
      mode: mode,
      status: EnhancementStatus.processing,
    );
    await _storage.saveSession(session);
    notifyListeners();

    final enhanced = await _createEnhancedResult(session, page, mode);
    session.replacePageAt(index, enhanced);
    await _storage.saveSession(session);
    notifyListeners();
    return enhanced.enhancementStatus == EnhancementStatus.completed;
  }

  Future<void> updateSuggestedTitle(
    String title, {
    required int sourcePageNo,
  }) async {
    _ensureOpen();
    final session = _requireSession();
    session.updateSuggestedTitle(title, sourcePageNo);
    await _storage.saveSession(session);
    notifyListeners();
  }

  @override
  Future<void> cancelSession() async {
    final session = _currentSession;
    if (session == null) {
      return;
    }

    await _storage.deleteSession(session.id);
    _currentSession = null;
    if (!_isClosed) {
      notifyListeners();
    }
  }

  @override
  Future<void> deleteAfterSuccessfulExport() => cancelSession();

  /// Releases in-memory listeners without deleting the persisted session.
  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    DebugDiagnostics.instance.log('STATE', 'ScanSessionManager.close');
    dispose();
  }

  Future<ScanSession> _ensureSession() async {
    final activeSession = _currentSession;
    if (activeSession != null) {
      return activeSession;
    }

    final session = ScanSession(
      id: _sessionIdGenerator(),
      createdTime: _clock(),
      captureMode: _captureMode,
    );
    await _storage.createSession(session.id);
    await _storage.saveSession(session);
    _currentSession = session;
    return session;
  }

  ScanSession _requireSession() {
    final session = _currentSession;
    if (session == null) {
      throw StateError('No active scan session.');
    }
    return session;
  }

  Future<bool> _detectPage(
    ScanSession session,
    int index, {
    CaptureGuideRegion? captureGuideRegion,
    DocumentCorners? stablePreviewCorners,
    PageBoundary? stablePreviewBoundary,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
    DocumentPageSide? pageSide,
  }) async {
    try {
      final existingPage = session.pages[index];
      if (existingPage.hasUserAdjustedCorners &&
          existingPage.documentCorners != null) {
        DebugDiagnostics.instance.log(
          'IMAGE_PROCESSING',
          'Detection skipped for manual corners pageNo=${existingPage.pageNo}',
        );
        return true;
      }
      final rawImagePath = session.pages[index].rawImagePath;
      final detector = _documentDetector;
      final detection =
          pageSide != null && detector is SpreadAwareDocumentDetector
          ? await detector.detectForPage(rawImagePath, pageSide: pageSide)
          : await detector.detect(rawImagePath);
      final guideCorners =
          captureGuideRegion != null &&
              detection.sourceWidth > 0 &&
              detection.sourceHeight > 0
          ? captureGuideRegion.toSourceCorners(
              detection.sourceWidth,
              detection.sourceHeight,
            )
          : null;
      final previewCorners = _previewCornersForSource(
        stablePreviewCorners,
        detection.sourceWidth,
        detection.sourceHeight,
      );
      final previewBoundary = _previewBoundaryForSource(
        stablePreviewBoundary,
        detection.sourceWidth,
        detection.sourceHeight,
      );
      final effectivePreviewBoundary =
          previewBoundary ??
          _boundaryFromCorners(
            previewCorners,
            detection.sourceWidth,
            detection.sourceHeight,
            confidence: 1,
          );
      final captureBoundary = captureBoundarySnapshot == null
          ? effectivePreviewBoundary
          : CaptureBoundaryMapper.toJpegBoundary(
              captureBoundarySnapshot,
              jpegWidth: detection.sourceWidth,
              jpegHeight: detection.sourceHeight,
              pageSide: pageSide,
            );
      final openCvDecision = PageCropDecisionPolicy.decide(
        detection: detection,
        guideCorners: guideCorners ?? session.pages[index].documentCorners,
        captureBoundary: captureBoundary,
        pageSide: pageSide,
      );
      final aiSegmentation = await _runAiComparison(
        imagePath: rawImagePath,
        pageSide: pageSide,
        openCvCorners: openCvDecision?.corners,
        expectedGuideCorners: guideCorners,
        openCvConfidence: detection.confidence,
        cropSource: openCvDecision?.source,
      );
      final decision = _selectProductionCrop(
        aiSegmentation: aiSegmentation,
        openCvDecision: openCvDecision,
        sourceWidth: detection.sourceWidth,
        sourceHeight: detection.sourceHeight,
        pageSide: pageSide,
        expectedGuideCorners: guideCorners,
      );
      final aiSelection = AiPrimaryCropPolicy.select(
        aiSegmentation,
        pageSide: pageSide,
        expectedGuideCorners: guideCorners,
      );
      final resolvedBoundary = decision?.boundary;
      final resolvedCorners = decision?.corners;
      final finalMetrics = _cornerMetrics(
        resolvedCorners,
        detection.sourceWidth,
        detection.sourceHeight,
      );
      DebugDiagnostics.instance.log(
        'CAPTURE_BOUNDARY',
        'mode=${pageSide == null ? "single" : "spread"} '
            'roiSide=${pageSide?.name ?? "full"} '
            'snapshotAvailable=${captureBoundarySnapshot != null} '
            'snapshotConfidence=${captureBoundarySnapshot?.confidence.toStringAsFixed(3) ?? "0.000"} '
            'snapshotStable=${captureBoundarySnapshot?.stability.toStringAsFixed(3) ?? "0.000"} '
            'liveFrameSize=${captureBoundarySnapshot == null ? "none" : "${captureBoundarySnapshot.sourceFrameWidth}x${captureBoundarySnapshot.sourceFrameHeight}"} '
            'jpegSize=${detection.sourceWidth}x${detection.sourceHeight} '
            'liveCorners=${_boundaryCornersSummary(captureBoundarySnapshot?.boundary)} '
            'convertedJpegCorners=${_boundaryCornersSummary(captureBoundary)} '
            'paperBoundaryAvailable=${detection.boundary != null} '
            'paperBoundaryConfidence=${detection.confidence.toStringAsFixed(3)} '
            'paperRegionCandidate=${detection.paperRegionCandidate} '
            'contentSafeAvailable=${detection.contentSafeCorners != null} '
            'contentComponentCount=${detection.contentComponentCount} '
            'contentBounds=${_cornersSummary(detection.contentBounds, detection.sourceWidth, detection.sourceHeight)} '
            'safeMargin=${detection.contentSafeMarginX.toStringAsFixed(3)},${detection.contentSafeMarginY.toStringAsFixed(3)} '
            'stableLiveAvailable=${effectivePreviewBoundary != null} '
            'stableLiveConfidence=${effectivePreviewBoundary?.confidence.toStringAsFixed(3) ?? "0.000"} '
            'selectedCropSource=${decision?.source.name ?? "none"} '
            'openCvCandidateSource=${openCvDecision?.source.name ?? "none"} '
            'aiFinalSource=${aiSegmentation?.finalSource?.serializedName ?? "none"} '
            'refineAttempted=${decision?.refineAttempted ?? false} '
            'refineAccepted=${decision?.refineAccepted ?? false} '
            'refineRejectedReason=${decision?.refineRejectedReason ?? "not_attempted"} '
            'cornerDeltaPercent=${decision?.cornerDeltaPercent.toStringAsFixed(3) ?? "0.000"} '
            'finalCorners=${_cornersSummary(resolvedCorners, detection.sourceWidth, detection.sourceHeight)} '
            'finalWidthRatio=${finalMetrics.$1.toStringAsFixed(3)} '
            'finalHeightRatio=${finalMetrics.$2.toStringAsFixed(3)} '
            'finalAreaRatio=${finalMetrics.$3.toStringAsFixed(3)} '
            'fallbackReason=${decision?.fallbackReason ?? "no_safe_crop"}',
      );
      if (aiSelection == null &&
          openCvDecision?.source == CropSource.captureLiveBoundary) {
        final areaDifference = openCvDecision!.areaRatioCapture <= 0
            ? 0.0
            : ((openCvDecision.areaRatioFinal - openCvDecision.areaRatioCapture)
                          .abs() /
                      openCvDecision.areaRatioCapture) *
                  100;
        if (openCvDecision.cornerDeltaPercent > 4 || areaDifference > 8) {
          DebugDiagnostics.instance.log(
            'CAPTURE_BOUNDARY_WARNING',
            'final crop differs from displayed live boundary by '
                'corner=${openCvDecision.cornerDeltaPercent.toStringAsFixed(2)}% '
                'area=${areaDifference.toStringAsFixed(2)}%',
          );
        }
      }
      session.updateDetectionAt(
        index,
        detection,
        captureGuideCorners: guideCorners,
        resolvedCorners: resolvedCorners,
        resolvedBoundary: resolvedBoundary,
        cropSource: decision?.source,
        captureBoundaryConfidence:
            captureBoundarySnapshot?.confidence ?? captureBoundary?.confidence,
        captureBoundaryStability:
            captureBoundarySnapshot?.stability ?? captureBoundary?.stability,
      );
      if (aiSegmentation != null) {
        session.updateAiSegmentationAt(index, aiSegmentation);
      }
      await _storage.saveSession(session);
      notifyListeners();
      return resolvedCorners != null;
    } on Object {
      return false;
    }
  }

  PageCropDecision? _selectProductionCrop({
    required AiDocumentSegmentationResult? aiSegmentation,
    required PageCropDecision? openCvDecision,
    required int sourceWidth,
    required int sourceHeight,
    required DocumentPageSide? pageSide,
    DocumentCorners? expectedGuideCorners,
  }) {
    final aiSelection = AiPrimaryCropPolicy.select(
      aiSegmentation,
      pageSide: pageSide,
      expectedGuideCorners: expectedGuideCorners,
    );
    if (aiSelection != null) {
      return PageCropDecision(
        source: aiSelection.source,
        corners: aiSelection.corners,
        boundary: _boundaryFromCorners(
          aiSelection.corners,
          sourceWidth,
          sourceHeight,
          confidence: aiSelection.confidence,
        ),
        fallbackReason: 'none',
      );
    }
    // Tests/embedders may deliberately run without the AI service. Preserve
    // their legacy source semantics; `openCvFallback` means AI was attempted.
    if (aiSegmentation == null) return openCvDecision;
    if (openCvDecision == null ||
        openCvDecision.source == CropSource.guideFallback) {
      return openCvDecision;
    }
    return PageCropDecision(
      source: CropSource.openCvFallback,
      corners: openCvDecision.corners,
      boundary: openCvDecision.boundary,
      captureBoundary: openCvDecision.captureBoundary,
      fallbackReason: 'ai_final_unavailable',
      refineAttempted: openCvDecision.refineAttempted,
      refineAccepted: openCvDecision.refineAccepted,
      refineRejectedReason: openCvDecision.refineRejectedReason,
      cornerDeltaPercent: openCvDecision.cornerDeltaPercent,
      areaRatioCapture: openCvDecision.areaRatioCapture,
      areaRatioFinal: openCvDecision.areaRatioFinal,
    );
  }

  Future<AiDocumentSegmentationResult?> _runAiComparison({
    required String imagePath,
    required DocumentPageSide? pageSide,
    required DocumentCorners? openCvCorners,
    DocumentCorners? expectedGuideCorners,
    required double openCvConfidence,
    required CropSource? cropSource,
  }) async {
    final segmenter = _aiDocumentSegmenter;
    if (segmenter == null) return null;
    final sessionDirectory = path.dirname(imagePath);
    final rawStem = path.basenameWithoutExtension(imagePath);
    final sideToken = pageSide?.name ?? 'single';
    final result = await segmenter.segment(
      imagePath,
      pageSide: pageSide,
      openCvCorners: openCvCorners,
      expectedGuideCorners: expectedGuideCorners,
      debugOutputDirectory: AiDebugArtifactPolicy.outputDirectory(
        sessionDirectory,
        debugBuild: kDebugMode,
      ),
      debugStem: '${rawStem}_$sideToken',
    );
    DebugDiagnostics.instance.log(
      'AI_SEGMENTATION',
      'mode=${pageSide == null ? "single" : "spread"} '
          'pageSide=$sideToken success=${result.success} '
          'modelLoadMs=${result.modelLoadMs} '
          'preprocessMs=${result.preprocessMs} '
          'inferenceMs=${result.inferenceTimeMs} '
          'postprocessMs=${result.postprocessMs} totalMs=${result.totalMs} '
          'maskCoverage=${result.maskCoverage.toStringAsFixed(4)} '
          'aiConfidence=${result.confidence?.toStringAsFixed(4) ?? "none"} '
          'aiCorners=${_cornersSummary(result.corners, result.sourceWidth, result.sourceHeight)} '
          'opencvConfidence=${openCvConfidence.toStringAsFixed(4)} '
          'opencvCropSource=${cropSource?.name ?? "none"} '
          'opencvCorners=${_cornersSummary(openCvCorners, result.sourceWidth, result.sourceHeight)} '
          'failureReason=${result.failureReason ?? "none"}',
    );
    DebugDiagnostics.instance.log(
      'AI_REFINEMENT',
      'mode=${pageSide == null ? "single" : "spread"} '
          'pageSide=$sideToken attempted=${result.refinementAttempted} '
          'accepted=${result.refinementAccepted} '
          'maskToSearchRoiMs=${result.maskToSearchRoiMs} '
          'paperCandidateMs=${result.paperCandidateMs} '
          'edgeRefineMs=${result.edgeRefineMs} '
          'cornerEstimateMs=${result.cornerEstimateMs} '
          'totalRefineMs=${result.totalRefineMs} '
          'aiInferenceMs=${result.inferenceTimeMs} '
          'totalAiDetectorMs=${result.totalMs} '
          'rawAreaRatio=${result.rawAreaRatio.toStringAsFixed(4)} '
          'refinedAreaRatio=${result.refinedAreaRatio.toStringAsFixed(4)} '
          'aiContainmentRatio=${result.aiContainmentRatio.toStringAsFixed(4)} '
          'areaExpansionRatio=${result.areaExpansionRatio.toStringAsFixed(4)} '
          'paperTransitionScore=${result.paperTransitionScore.toStringAsFixed(4)} '
          'ownership=${result.mainPageOwnershipScore.toStringAsFixed(4)} '
          'envelopeConsistency=${result.outerEnvelopeConsistency.toStringAsFixed(4)} '
          'edgeContinuity=${result.edgeContinuity.toStringAsFixed(4)} '
          'adjacentPagePenalty=${result.adjacentPagePenalty.toStringAsFixed(4)} '
          'occlusionPenalty=${result.occlusionPenalty.toStringAsFixed(4)} '
          'refinedConfidence=${result.refinedConfidence.toStringAsFixed(4)} '
          'refinedStatus=${result.refinedStatus.serializedName} '
          'rawCorners=${_cornersSummary(result.corners, result.sourceWidth, result.sourceHeight)} '
          'refinedCorners=${_cornersSummary(result.refinedCorners, result.sourceWidth, result.sourceHeight)} '
          'aiFinalSource=${result.finalSource?.serializedName ?? "none"} '
          'aiFinalCorners=${_cornersSummary(result.finalCorners, result.sourceWidth, result.sourceHeight)} '
          'edgeVisibility=${result.edgeVisibilities.values.map((edge) => "${edge.edge.name}:${edge.status.serializedName}").join(",")} '
          'failureReason=${result.refinementFailureReason ?? "none"}',
    );
    return result;
  }

  Future<ScanPage?> _createPerspectiveResult(
    ScanSession session,
    ScanPage page,
  ) async {
    final corners = page.documentCorners;
    if (corners == null) {
      return null;
    }
    CorrectionOutputTarget? outputTarget;
    try {
      final boundaryMode = CurvedPagePolicy.selectBoundaryMode(
        corners: corners,
        sourceWidth: page.documentSourceWidth,
        sourceHeight: page.documentSourceHeight,
      );
      outputTarget = await _storage.prepareCorrectionOutput(
        sessionId: session.id,
        rawImagePath: page.rawImagePath,
        type: CorrectionType.perspective,
      );
      final result = await _pageCorrector.correct(
        sourceImagePath: page.rawImagePath,
        outputImagePath: outputTarget.workingPath,
        corners: corners,
        type: CorrectionType.perspective,
        boundaryMode: boundaryMode,
        pageBoundary: page.pageBoundary,
      );
      final correctedImagePath = await _storage.commitCorrectionOutput(
        outputTarget,
      );
      await ScanQualityDiagnostics.recordCorrection(
        page: page,
        type: CorrectionType.perspective,
        sourcePath: page.rawImagePath,
        outputPath: correctedImagePath,
        result: result,
      );
      return page.withCorrection(
        status: CorrectionStatus.completed,
        type: CorrectionType.perspective,
        correctedImagePath: correctedImagePath,
      );
    } on Object {
      if (outputTarget != null) {
        try {
          await _storage.discardCorrectionOutput(outputTarget);
        } on Object {
          // The candidate will be removed by the caller.
        }
      }
      return null;
    }
  }

  Future<ScanPage> _createEnhancedResult(
    ScanSession session,
    ScanPage page,
    EnhancementMode mode,
  ) async {
    if (mode == EnhancementMode.originalColor) {
      return page.withEnhancement(
        mode: mode,
        status: EnhancementStatus.completed,
      );
    }
    final sourceImagePath = page.correctedImagePath;
    final enhancementStorage = _storage;
    if (sourceImagePath == null) {
      return page.withEnhancement(mode: mode, status: EnhancementStatus.failed);
    }
    if (enhancementStorage is! EnhancementSessionStorage) {
      return page.withEnhancement(mode: mode, status: EnhancementStatus.failed);
    }
    final enhancementOutputStorage =
        enhancementStorage as EnhancementSessionStorage;

    EnhancementOutputTarget? outputTarget;
    final stopwatch = Stopwatch()..start();
    try {
      final preparedTarget = await enhancementOutputStorage
          .prepareEnhancementOutput(
            sessionId: session.id,
            rawImagePath: page.rawImagePath,
            mode: mode,
          );
      outputTarget = preparedTarget;
      final result = await _pageEnhancer.enhance(
        sourceImagePath: sourceImagePath,
        outputImagePath: preparedTarget.workingPath,
        mode: mode,
      );
      final enhancedImagePath = await enhancementOutputStorage
          .commitEnhancementOutput(preparedTarget);
      await ScanQualityDiagnostics.recordEnhancement(
        page: page,
        sourcePath: sourceImagePath,
        outputPath: enhancedImagePath,
        result: result,
      );
      stopwatch.stop();
      DebugDiagnostics.instance.log(
        'IMAGE_PROCESSING',
        'Scan Enhancement: ${stopwatch.elapsedMilliseconds} ms '
            'native=${result.processingMilliseconds} ms mode=${mode.name}',
      );
      return page.withEnhancement(
        mode: mode,
        status: EnhancementStatus.completed,
        enhancedImagePath: enhancedImagePath,
      );
    } on Object catch (error) {
      stopwatch.stop();
      if (outputTarget != null) {
        try {
          await enhancementOutputStorage.discardEnhancementOutput(outputTarget);
        } on Object {
          // The corrected image remains the final fallback.
        }
      }
      DebugDiagnostics.instance.log(
        'IMAGE_PROCESSING',
        'Scan Enhancement failed after ${stopwatch.elapsedMilliseconds} ms '
            'mode=${mode.name} error=$error',
      );
      return page.withEnhancement(mode: mode, status: EnhancementStatus.failed);
    }
  }

  Future<MlKitScannedPage> _mlKitSourceDescriptor(ScanPage page) async {
    final sourcePath = page.editableSourcePath;
    final file = File(sourcePath);
    final bytes = await file.readAsBytes();
    final decoded = image.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException(
        'ML Kit editable source could not be decoded.',
      );
    }
    return MlKitScannedPage(
      filePath: sourcePath,
      byteCount: bytes.length,
      width: decoded.width,
      height: decoded.height,
    );
  }

  List<ScanPage> _spreadChildren({
    required ScanPage previous,
    required MlKitSpreadSplitResult split,
    required String parentSpreadId,
    int? leftRotation,
    int? rightRotation,
  }) => [
    ScanPage(
      pageNo: previous.pageNo,
      rawImagePath: split.left.filePath,
      createdTime: previous.createdTime,
      sourceType: ScanPageSourceType.mlKitSpread,
      mlKitLayout: MlKitPageLayout.spread,
      originalSourcePath: previous.editableSourcePath,
      parentSpreadId: parentSpreadId,
      spreadSide: MlKitSpreadSide.left,
      splitX: split.detection.splitX,
      splitConfidence: split.detection.confidence,
      splitFallbackUsed: split.detection.usedFallback,
      mlKitCropRect: split.leftCropRect,
      rotation: leftRotation ?? previous.rotation,
      documentSourceWidth: split.left.width,
      documentSourceHeight: split.left.height,
    ),
    ScanPage(
      pageNo: previous.pageNo + 1,
      rawImagePath: split.right.filePath,
      createdTime: previous.createdTime,
      sourceType: ScanPageSourceType.mlKitSpread,
      mlKitLayout: MlKitPageLayout.spread,
      originalSourcePath: previous.editableSourcePath,
      parentSpreadId: parentSpreadId,
      spreadSide: MlKitSpreadSide.right,
      splitX: split.detection.splitX,
      splitConfidence: split.detection.confidence,
      splitFallbackUsed: split.detection.usedFallback,
      mlKitCropRect: split.rightCropRect,
      rotation: rightRotation ?? previous.rotation,
      documentSourceWidth: split.right.width,
      documentSourceHeight: split.right.height,
    ),
  ];

  Future<void> _deleteUnreferencedMlKitFiles(
    Iterable<ScanPage> removed,
    Iterable<ScanPage> remaining,
  ) async {
    String normalized(String value) => path.normalize(value).toLowerCase();
    final protected = <String>{
      for (final page in remaining) normalized(page.rawImagePath),
      for (final page in remaining)
        if (page.originalSourcePath != null)
          normalized(page.originalSourcePath!),
      for (final page in remaining)
        if (page.editedImagePath != null) normalized(page.editedImagePath!),
    };
    final candidates = <String>{
      for (final page in removed) page.rawImagePath,
      for (final page in removed)
        if (page.originalSourcePath != null) page.originalSourcePath!,
      for (final page in removed)
        if (page.editedImagePath != null) page.editedImagePath!,
    };
    for (final candidate in candidates) {
      if (protected.contains(normalized(candidate))) continue;
      final file = File(candidate);
      if (await file.exists()) await file.delete();
    }
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('The scan session manager is closed.');
    }
  }

  static String _newUuid() => const Uuid().v4();

  static DocumentCorners? _previewCornersForSource(
    DocumentCorners? normalized,
    int width,
    int height,
  ) {
    if (normalized == null || width <= 0 || height <= 0) return null;
    DocumentPoint scale(DocumentPoint point) => DocumentPoint(
      point.x.clamp(0.0, 1.0) * width,
      point.y.clamp(0.0, 1.0) * height,
    );
    return DocumentCorners(
      topLeft: scale(normalized.topLeft),
      topRight: scale(normalized.topRight),
      bottomRight: scale(normalized.bottomRight),
      bottomLeft: scale(normalized.bottomLeft),
    );
  }

  static PageBoundary? _previewBoundaryForSource(
    PageBoundary? normalized,
    int width,
    int height,
  ) {
    if (normalized == null || width <= 0 || height <= 0) return null;
    return normalized.scaleTo(width, height);
  }

  static PageBoundary? _boundaryFromCorners(
    DocumentCorners? corners,
    int width,
    int height, {
    required double confidence,
  }) {
    if (corners == null || width <= 0 || height <= 0) return null;
    final boundary = PageBoundary.fromCorners(
      corners,
      sourceWidth: width,
      sourceHeight: height,
      confidence: confidence,
      stability: 1,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
    return boundary.isValid ? boundary : null;
  }

  static double _normalizedPolygonArea(List<DocumentPoint> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      sum += points[index].x * next.y - next.x * points[index].y;
    }
    return sum.abs() / 2;
  }

  static (double, double, double) _cornerMetrics(
    DocumentCorners? corners,
    int width,
    int height,
  ) {
    if (corners == null || width <= 0 || height <= 0) return (0, 0, 0);
    final normalized = corners.ordered
        .map((point) => DocumentPoint(point.x / width, point.y / height))
        .toList();
    final widthRatio =
        normalized.map((point) => point.x).reduce(math.max) -
        normalized.map((point) => point.x).reduce(math.min);
    final heightRatio =
        normalized.map((point) => point.y).reduce(math.max) -
        normalized.map((point) => point.y).reduce(math.min);
    return (widthRatio, heightRatio, _normalizedPolygonArea(normalized));
  }

  static String _cornersSummary(
    DocumentCorners? corners,
    int width,
    int height,
  ) {
    if (corners == null || width <= 0 || height <= 0) return 'none';
    return corners.ordered
        .map(
          (point) =>
              '(${(point.x / width).toStringAsFixed(3)},${(point.y / height).toStringAsFixed(3)})',
        )
        .join(',');
  }

  static String _boundaryCornersSummary(PageBoundary? boundary) {
    if (boundary == null) return 'none';
    return boundary
        .toDocumentCorners()
        .ordered
        .map(
          (point) =>
              '(${point.x.toStringAsFixed(1)},${point.y.toStringAsFixed(1)})',
        )
        .join(',');
  }
}
