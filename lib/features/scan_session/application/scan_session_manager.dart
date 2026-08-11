import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/image_processing/page_corrector.dart';
import 'package:scana/services/image_processing/spread_capture_splitter.dart';
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
  Future<List<ScanPage>> captureAndProcessSpread(String capturedImagePath) {
    _ensureOpen();
    final completer = Completer<List<ScanPage>>();
    _processingPageCount += 2;
    notifyListeners();
    _processingTail = _processingTail.then<void>((_) async {
      try {
        completer.complete(await _captureAndProcessSpread(capturedImagePath));
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
  }) async {
    final totalStopwatch = Stopwatch()..start();
    final detectionStopwatch = Stopwatch()..start();
    final page = await addRawCapture(
      capturedImagePath,
      captureGuideRegion: captureGuideRegion,
      stablePreviewCorners: stablePreviewCorners,
      stablePreviewBoundary: stablePreviewBoundary,
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
    String capturedImagePath,
  ) async {
    await _ensureSession();
    final parts = await _spreadCaptureSplitter.split(capturedImagePath);
    try {
      final left = await _captureAndProcessSpreadSide(
        parts.leftImagePath,
        pageSide: DocumentPageSide.left,
      );
      final right = await _captureAndProcessSpreadSide(
        parts.rightImagePath,
        pageSide: DocumentPageSide.right,
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
  }) async {
    final page = await addRawCapture(
      capturedImagePath,
      pageSide: pageSide,
      captureGuideRegion: SpreadPageDetectionPolicy.expectedRegion(pageSide),
    );
    final session = _requireSession();
    final index = session.pages.indexOf(page);
    if (index < 0) return session.pages.last;

    final detectedPage = session.pages[index];
    if (SpreadPageDetectionPolicy.isStableDetection(detectedPage)) {
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
      final resolvedBoundary = _isReliableBoundary(detection)
          ? detection.boundary
          : previewBoundary;
      final resolvedCorners =
          resolvedBoundary?.toDocumentCorners() ??
          (_isReliableDetection(detection) ? detection.corners : null) ??
          previewCorners ??
          previousPage.documentCorners ??
          guideCorners;
      if (resolvedCorners == null) {
        await _storage.deletePageFiles(candidate);
        return false;
      }
      candidate = candidate
          .withDetection(
            detection,
            resolvedCorners: resolvedCorners,
            resolvedBoundary: resolvedBoundary,
          )
          .copyWith(captureGuideCorners: guideCorners);
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
    DocumentPageSide? pageSide,
  }) async {
    try {
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
      final highResReliable =
          _isReliableBoundary(detection) &&
          _isSaneBoundary(detection.boundary, pageSide: pageSide);
      final previewReliable = _isSaneBoundary(
        previewBoundary,
        pageSide: pageSide,
      );
      final resolvedBoundary = highResReliable
          ? detection.boundary
          : previewReliable
          ? previewBoundary
          : null;
      final resolvedCorners =
          resolvedBoundary?.toDocumentCorners() ??
          (_isReliableDetection(detection) &&
                  _isSaneCorners(
                    detection.corners,
                    detection.sourceWidth,
                    detection.sourceHeight,
                    pageSide: pageSide,
                  )
              ? detection.corners
              : null) ??
          (previewReliable ? previewCorners : null) ??
          session.pages[index].documentCorners ??
          guideCorners;
      DebugDiagnostics.instance.log(
        'PAGE_DETECTION',
        'mode=${pageSide == null ? "single" : "spread"} '
            'roiSide=${pageSide?.name ?? "full"} detected=${detection.detected} '
            'confidence=${detection.confidence.toStringAsFixed(3)} '
            'selectedBy=${highResReliable
                ? "highRes"
                : previewReliable
                ? "stableLive"
                : "fallback"} '
            'fallbackUsed=${!highResReliable && !previewReliable} '
            'fallbackReason=${!highResReliable && !previewReliable ? "boundary_sanity_or_confidence" : "none"} '
            'liveBoundary=${_boundarySummary(previewBoundary)} '
            'highResBoundary=${_boundarySummary(detection.boundary)} '
            'finalCropBoundary=${_boundarySummary(resolvedBoundary)}',
      );
      session.updateDetectionAt(
        index,
        detection,
        captureGuideCorners: guideCorners,
        resolvedCorners: resolvedCorners,
        resolvedBoundary: resolvedBoundary,
      );
      await _storage.saveSession(session);
      notifyListeners();
      return resolvedCorners != null;
    } on Object {
      return false;
    }
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

  static bool _isReliableDetection(DocumentDetectionResult detection) =>
      detection.detected &&
      detection.corners != null &&
      detection.confidence >= 0.55;

  static bool _isReliableBoundary(DocumentDetectionResult detection) =>
      detection.detected &&
      detection.boundary?.isValid == true &&
      detection.confidence >= 0.55;

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

  static bool _isSaneBoundary(
    PageBoundary? boundary, {
    DocumentPageSide? pageSide,
  }) {
    if (boundary == null || !boundary.isValid) return false;
    final normalized = boundary.normalized();
    final points = normalized.closedPolygon;
    final minX = points.map((point) => point.x).reduce(math.min);
    final maxX = points.map((point) => point.x).reduce(math.max);
    final minY = points.map((point) => point.y).reduce(math.min);
    final maxY = points.map((point) => point.y).reduce(math.max);
    final width = maxX - minX;
    final height = maxY - minY;
    final area = _normalizedPolygonArea(points);
    return width >= (pageSide == null ? 0.46 : 0.42) &&
        height >= 0.48 &&
        area >= (pageSide == null ? 0.24 : 0.22);
  }

  static bool _isSaneCorners(
    DocumentCorners? corners,
    int width,
    int height, {
    DocumentPageSide? pageSide,
  }) {
    if (corners == null || width <= 0 || height <= 0) return false;
    return _isSaneBoundary(
      PageBoundary.fromCorners(
        corners,
        sourceWidth: width,
        sourceHeight: height,
        confidence: 1,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      pageSide: pageSide,
    );
  }

  static double _normalizedPolygonArea(List<DocumentPoint> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      sum += points[index].x * next.y - next.x * points[index].y;
    }
    return sum.abs() / 2;
  }

  static String _boundarySummary(PageBoundary? boundary) {
    if (boundary == null) return 'none';
    final normalized = boundary.normalized();
    final points = normalized.closedPolygon;
    return 'points=${points.length},area=${_normalizedPolygonArea(points).toStringAsFixed(3)}';
  }
}
