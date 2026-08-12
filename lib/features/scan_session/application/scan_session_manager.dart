import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import 'package:scana/models/scan_page.dart';
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
import 'package:scana/services/storage/scan_session_storage.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';

typedef SessionIdGenerator = String Function();
typedef Clock = DateTime Function();

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
      final perspectiveStopwatch = Stopwatch()..start();
      final corrected = await correctPageAt(
        index,
        CorrectionType.perspective,
        enhanceAfterCorrection: false,
      );
      perspectiveStopwatch.stop();
      DebugDiagnostics.instance.log(
        'IMAGE_PROCESSING',
        'Perspective: ${perspectiveStopwatch.elapsedMilliseconds} ms',
      );
      if (corrected) {
        await enhancePageAt(index, EnhancementMode.scanColor);
      }
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
      captureGuideRegion: SpreadPageDetectionPolicy.expectedRegion(pageSide),
      stablePreviewBoundary: stablePreviewBoundary,
      captureBoundarySnapshot: captureBoundarySnapshot,
    );
    final session = _requireSession();
    final index = session.pages.indexOf(page);
    if (index < 0) return session.pages.last;

    final detectedPage = session.pages[index];
    if (detectedPage.documentCorners != null &&
        detectedPage.cropSource != CropSource.guideFallback) {
      final corrected = await correctPageAt(
        index,
        CorrectionType.perspective,
        enhanceAfterCorrection: false,
      );
      if (corrected) {
        await enhancePageAt(index, EnhancementMode.scanColor);
        return session.pages[index];
      }
    }
    final fallbackCreated = await _createSpreadFallback(
      session,
      index,
      pageSide,
    );
    if (fallbackCreated) {
      await enhancePageAt(index, EnhancementMode.scanColor);
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
      final decision = PageCropDecisionPolicy.decide(
        detection: detection,
        guideCorners: guideCorners ?? previousPage.documentCorners,
        captureBoundary: captureBoundary,
      );
      if (decision == null) {
        await _storage.deletePageFiles(candidate);
        return false;
      }
      final aiSegmentation = await _runAiComparison(
        imagePath: rawImagePath,
        pageSide: null,
        openCvCorners: decision.corners,
        openCvConfidence: detection.confidence,
        cropSource: decision.source,
      );
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

      final enhanced = await _createEnhancedResult(
        session,
        corrected,
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

  Future<void> deletePageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
    await _storage.deletePageFiles(page);
    session.removePageAt(index);
    await _storage.saveSession(session);
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
    final stopwatch = Stopwatch()..start();
    await updateDocumentCornersAt(index, corners);
    final corrected = await correctPageAt(
      index,
      CorrectionType.perspective,
      enhanceAfterCorrection: true,
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
    return _detectPage(_requireSession(), index);
  }

  Future<bool> correctPageAt(
    int index,
    CorrectionType type, {
    bool enhanceAfterCorrection = true,
  }) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
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
        await _pageCorrector.correct(
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
      final correctionResult = await _pageCorrector.correct(
        sourceImagePath: correctionSourcePath,
        outputImagePath: outputTarget.workingPath,
        corners: corners,
        type: type,
        boundaryMode: boundaryMode,
        pageBoundary: page.pageBoundary,
      );
      final correctedImagePath = await _storage.commitCorrectionOutput(
        outputTarget,
      );
      session.updateCorrectionAt(
        index,
        status: CorrectionStatus.completed,
        type: type,
        correctedImagePath: correctedImagePath,
        outcome: correctionResult.outcome,
      );
      await _storage.saveSession(session);
      notifyListeners();
      if (enhanceAfterCorrection) {
        try {
          await enhancePageAt(index, session.pages[index].enhancementMode);
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
      );
      try {
        await _storage.saveSession(session);
      } on Object {
        // Raw page and previous correction remain available in memory and disk.
      }
      notifyListeners();
      return false;
    }
  }

  Future<bool> enhancePageAt(int index, EnhancementMode mode) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
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
      final decision = PageCropDecisionPolicy.decide(
        detection: detection,
        guideCorners: guideCorners ?? session.pages[index].documentCorners,
        captureBoundary: captureBoundary,
        pageSide: pageSide,
      );
      final resolvedBoundary = decision?.boundary;
      final resolvedCorners = decision?.corners;
      final aiSegmentation = await _runAiComparison(
        imagePath: rawImagePath,
        pageSide: pageSide,
        openCvCorners: resolvedCorners,
        openCvConfidence: detection.confidence,
        cropSource: decision?.source,
      );
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
      if (decision?.source == CropSource.captureLiveBoundary) {
        final areaDifference = decision!.areaRatioCapture <= 0
            ? 0.0
            : ((decision.areaRatioFinal - decision.areaRatioCapture).abs() /
                      decision.areaRatioCapture) *
                  100;
        if (decision.cornerDeltaPercent > 4 || areaDifference > 8) {
          DebugDiagnostics.instance.log(
            'CAPTURE_BOUNDARY_WARNING',
            'final crop differs from displayed live boundary by '
                'corner=${decision.cornerDeltaPercent.toStringAsFixed(2)}% '
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

  Future<AiDocumentSegmentationResult?> _runAiComparison({
    required String imagePath,
    required DocumentPageSide? pageSide,
    required DocumentCorners? openCvCorners,
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
      await _pageCorrector.correct(
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
