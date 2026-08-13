import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/capture_boundary_snapshot.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/live_document_detection.dart';
import 'package:scana/services/image_processing/capture_guide_policy.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

/// Full-screen camera entry point for the document scanning flow.
class CameraPreviewPage extends StatefulWidget {
  const CameraPreviewPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.recoverySession,
    this.replacementPageIndex,
    this.previewDocumentDetector,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final CameraStartup? cameraStartup;
  final ScanSessionManager sessionManager;
  final ScanSession? recoverySession;
  final int? replacementPageIndex;
  final PreviewDocumentDetector? previewDocumentDetector;
  final ScreenOrientationController orientationController;

  @override
  State<CameraPreviewPage> createState() => _CameraPreviewPageState();
}

class _CameraPreviewPageState extends State<CameraPreviewPage> {
  bool _isCapturing = false;
  bool _recoveryPromptShown = false;
  late final PreviewDocumentDetector _previewDetector;
  late final SpreadPreviewDocumentDetector? _spreadPreviewDetector;
  late final LiveDocumentDetectionController _liveDetection;
  late final LiveDocumentDetectionController _leftLiveDetection;
  late final LiveDocumentDetectionController _rightLiveDetection;
  DateTime? _lastBoundaryLogAt;
  String? _lastBoundaryLogState;

  @override
  void initState() {
    super.initState();
    DebugDiagnostics.instance.logState(
      'CameraPreviewPage.initState',
      mounted: mounted,
    );
    _previewDetector =
        widget.previewDocumentDetector ?? const OpenCvPreviewDocumentDetector();
    _spreadPreviewDetector = _previewDetector is SpreadPreviewDocumentDetector
        ? _previewDetector
        : null;
    _liveDetection = LiveDocumentDetectionController(
      detector: _previewDetector,
      boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
    );
    _leftLiveDetection = LiveDocumentDetectionController(
      detector: _SpreadPreviewDetectorAdapter(
        detector: _spreadPreviewDetector,
        pageSide: DocumentPageSide.left,
        previewRotation: _previewRotation,
      ),
      boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
    );
    _rightLiveDetection = LiveDocumentDetectionController(
      detector: _SpreadPreviewDetectorAdapter(
        detector: _spreadPreviewDetector,
        pageSide: DocumentPageSide.right,
        previewRotation: _previewRotation,
      ),
      boundaryStabilizer: PageBoundaryStabilizer(minimumConfidence: 0.22),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _applyCaptureOrientation(widget.sessionManager.captureMode);
      await _showRecoveryPrompt();
      if (!mounted) return;
      await _applyCaptureOrientation(widget.sessionManager.captureMode);
      await _startPreviewAnalysis();
    });
  }

  Future<void> _startPreviewAnalysis() async {
    final camera = widget.cameraStartup?.session;
    if (camera == null || !mounted) {
      return;
    }
    try {
      await camera.startPreviewAnalysis((image) {
        if (image.planes.isEmpty) return;
        final plane = image.planes.first;
        final frame = PreviewLuminanceFrame(
          bytes: Uint8List.fromList(plane.bytes),
          width: image.width,
          height: image.height,
          rowStride: plane.bytesPerRow,
        );
        if (widget.sessionManager.captureMode == ScanCaptureMode.spread) {
          if (_spreadPreviewDetector == null) return;
          if (_leftLiveDetection.canAccept) {
            unawaited(_submitPreview(_leftLiveDetection, frame));
          }
          if (_rightLiveDetection.canAccept) {
            unawaited(_submitPreview(_rightLiveDetection, frame));
          }
        } else if (_liveDetection.canAccept) {
          unawaited(_submitPreview(_liveDetection, frame));
        }
      });
    } on CameraException {
      // Optional live guidance must never block still capture.
    }
  }

  int _previewRotation() {
    final controller = widget.cameraStartup?.session?.controller;
    if (controller == null) return 0;
    return CameraPreviewBoundaryTransform.rotationDegrees(
      sensorOrientation: controller.description.sensorOrientation,
      deviceOrientation: controller.value.deviceOrientation,
      isFrontFacing:
          controller.description.lensDirection == CameraLensDirection.front,
    );
  }

  Future<void> _submitPreview(
    LiveDocumentDetectionController controller,
    PreviewLuminanceFrame frame,
  ) async {
    await controller.submit(frame);
    if (!mounted) return;
    _logLiveBoundary();
  }

  void _logLiveBoundary() {
    if (!kDebugMode) return;
    final mode = widget.sessionManager.captureMode;
    final controllers = mode == ScanCaptureMode.single
        ? [_liveDetection]
        : [_leftLiveDetection, _rightLiveDetection];
    String state(LiveDocumentDetectionController value) {
      final boundary = value.visibleNormalizedBoundary;
      return '${value.lastDetected}:${value.hasStableDocument}:'
          '${boundary?.closedPolygon.length ?? 0}';
    }

    final stateKey = '${mode.name}:${controllers.map(state).join('|')}';
    final now = DateTime.now();
    if (_lastBoundaryLogState == stateKey &&
        _lastBoundaryLogAt != null &&
        now.difference(_lastBoundaryLogAt!) < const Duration(seconds: 1)) {
      return;
    }
    _lastBoundaryLogState = stateKey;
    _lastBoundaryLogAt = now;
    String summary(
      String label,
      LiveDocumentDetectionController value,
      CaptureBoundarySide side,
    ) {
      final boundary = value.visibleNormalizedBoundary;
      final bounds = CameraPreviewBoundaryTransform.normalizedBounds(boundary);
      return '${label}Detected=${value.lastDetected} '
          '${label}CandidateAvailable=${boundary != null} '
          '${label}Confidence=${value.lastConfidence.toStringAsFixed(3)} '
          '${label}Stable=${value.hasStableDocument} '
          '${label}DisplayLevel=${value.displayLevelFor(side).name} '
          '${label}BoundaryPoints=${boundary?.closedPolygon.length ?? 0} '
          '${label}MinX=${bounds?.left.toStringAsFixed(3) ?? "n/a"} '
          '${label}MaxX=${bounds?.right.toStringAsFixed(3) ?? "n/a"} '
          '${label}MinY=${bounds?.top.toStringAsFixed(3) ?? "n/a"} '
          '${label}MaxY=${bounds?.bottom.toStringAsFixed(3) ?? "n/a"}';
    }

    final first = controllers.first;
    DebugDiagnostics.instance.log(
      'LIVE_GUIDE',
      'mode=${mode.name} frameWidth=${first.lastFrameWidth} '
          'frameHeight=${first.lastFrameHeight} '
          '${summary(mode == ScanCaptureMode.spread ? 'left' : '', first, mode == ScanCaptureMode.spread ? CaptureBoundarySide.left : CaptureBoundarySide.single)} '
          '${mode == ScanCaptureMode.spread ? summary('right', controllers.last, CaptureBoundarySide.right) : ''}',
    );
  }

  Future<void> _stopPreviewAnalysis() async {
    try {
      await widget.cameraStartup?.session?.stopPreviewAnalysis();
    } on CameraException {
      // The camera may already be transitioning to another route or capture.
    }
  }

  Future<void> _showRecoveryPrompt() async {
    final recoverySession = widget.recoverySession;
    if (recoverySession == null || _recoveryPromptShown || !mounted) {
      return;
    }
    _recoveryPromptShown = true;

    final action = await showDialog<_RecoveryAction>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RecoveryDialog(session: recoverySession),
    );
    if (!mounted || action == null) {
      return;
    }

    try {
      switch (action) {
        case _RecoveryAction.resume:
          widget.sessionManager.restoreSession(recoverySession);
          if (recoverySession.pages.isNotEmpty && mounted) {
            await widget.orientationController.enterContentScreen();
            if (!mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => PageManagementPage(
                  sessionManager: widget.sessionManager,
                  cameraStartup: widget.cameraStartup,
                  orientationController: widget.orientationController,
                ),
              ),
            );
          }
          break;
        case _RecoveryAction.delete:
          await widget.sessionManager.deleteRecoveredSession(recoverySession);
      }
    } on FileSystemException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('이전 스캔 작업을 처리할 수 없습니다.')));
      }
    }
  }

  Future<void> _capturePage() async {
    final cameraSession = widget.cameraStartup?.session;
    if (cameraSession == null || _isCapturing) {
      return;
    }

    setState(() => _isCapturing = true);
    try {
      final isSpread =
          widget.sessionManager.captureMode == ScanCaptureMode.spread;
      final captureGuideRegion = isSpread
          ? null
          : CaptureGuidePolicy.singleForViewport(
              width: MediaQuery.sizeOf(context).width,
              height: MediaQuery.sizeOf(context).height,
            );
      final controller = cameraSession.controller;
      final deviceOrientationDegrees =
          CameraPreviewBoundaryTransform.deviceOrientationDegrees(
            controller.value.deviceOrientation,
          );
      final rotationDegrees = _previewRotation();
      CaptureBoundarySnapshot? freeze(
        LiveDocumentDetectionController detection,
        CaptureBoundarySide side,
      ) => detection.freezeCaptureBoundary(
        captureMode: widget.sessionManager.captureMode,
        side: side,
        sensorOrientation: controller.description.sensorOrientation,
        deviceOrientationDegrees: deviceOrientationDegrees,
        jpegRotationDegrees: rotationDegrees,
        mirrored:
            controller.description.lensDirection == CameraLensDirection.front,
      );
      final singleSnapshot = isSpread
          ? null
          : freeze(_liveDetection, CaptureBoundarySide.single);
      final leftSnapshot = isSpread
          ? freeze(_leftLiveDetection, CaptureBoundarySide.left)
          : null;
      final rightSnapshot = isSpread
          ? freeze(_rightLiveDetection, CaptureBoundarySide.right)
          : null;
      await _stopPreviewAnalysis();
      final capturedImagePath = await cameraSession.captureRawImage();
      final replacementPageIndex = widget.replacementPageIndex;
      if (replacementPageIndex != null) {
        final replaced = await widget.sessionManager.replacePageAt(
          replacementPageIndex,
          capturedImagePath,
          captureGuideRegion: captureGuideRegion,
          captureBoundarySnapshot: singleSnapshot,
        );
        if (mounted) {
          Navigator.of(context).pop(replaced);
        }
        return;
      }
      if (isSpread) {
        unawaited(
          _processSpreadCapture(
            capturedImagePath,
            leftCaptureBoundarySnapshot: leftSnapshot,
            rightCaptureBoundarySnapshot: rightSnapshot,
          ),
        );
      } else {
        unawaited(
          _processCapturedImage(
            capturedImagePath,
            captureGuideRegion!,
            singleSnapshot,
          ),
        );
      }
    } on CameraException catch (_) {
      _showCaptureError();
    } on FileSystemException catch (_) {
      _showCaptureError();
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
        unawaited(_startPreviewAnalysis());
      }
    }
  }

  Future<void> _processCapturedImage(
    String capturedImagePath,
    CaptureGuideRegion captureGuideRegion,
    CaptureBoundarySnapshot? captureBoundarySnapshot,
  ) async {
    try {
      await widget.sessionManager.captureAndProcess(
        capturedImagePath,
        captureGuideRegion: captureGuideRegion,
        captureBoundarySnapshot: captureBoundarySnapshot,
      );
    } on Object {
      _showCaptureError();
    }
  }

  Future<void> _processSpreadCapture(
    String capturedImagePath, {
    CaptureBoundarySnapshot? leftCaptureBoundarySnapshot,
    CaptureBoundarySnapshot? rightCaptureBoundarySnapshot,
  }) async {
    try {
      await widget.sessionManager.captureAndProcessSpread(
        capturedImagePath,
        leftCaptureBoundarySnapshot: leftCaptureBoundarySnapshot,
        rightCaptureBoundarySnapshot: rightCaptureBoundarySnapshot,
      );
    } on Object {
      _showCaptureError();
    }
  }

  Future<void> _setCaptureMode(ScanCaptureMode mode) async {
    await _stopPreviewAnalysis();
    await widget.sessionManager.setCaptureMode(mode);
    _liveDetection.reset();
    _leftLiveDetection.reset();
    _rightLiveDetection.reset();
    await _applyCaptureOrientation(mode);
    unawaited(_startPreviewAnalysis());
    if (mounted) setState(() {});
  }

  Future<void> _applyCaptureOrientation(ScanCaptureMode mode) {
    return mode == ScanCaptureMode.spread
        ? widget.orientationController.enterSpreadCamera()
        : widget.orientationController.enterSingleCamera();
  }

  void _showCaptureError() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('사진을 저장할 수 없습니다.')));
  }

  @override
  Widget build(BuildContext context) {
    final cameraSession = widget.cameraStartup?.session;
    if (cameraSession == null) {
      return _CameraUnavailable(message: widget.cameraStartup?.errorMessage);
    }
    final captureMode = widget.sessionManager.captureMode;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(cameraSession.controller),
          FixedCaptureGuide(mode: captureMode),
          AnimatedBuilder(
            animation: Listenable.merge([
              _liveDetection,
              _leftLiveDetection,
              _rightLiveDetection,
            ]),
            builder: (context, child) => _ScanGuideOverlay(
              boundary: captureMode == ScanCaptureMode.single
                  ? _liveDetection.visibleNormalizedBoundary
                  : null,
              isStable: _liveDetection.hasStableDocument,
              displayLevel: _liveDetection.displayLevel,
              leftBoundary: captureMode == ScanCaptureMode.spread
                  ? _leftLiveDetection.visibleNormalizedBoundary
                  : null,
              leftStable: _leftLiveDetection.hasStableDocument,
              leftDisplayLevel: _leftLiveDetection.displayLevelFor(
                CaptureBoundarySide.left,
              ),
              rightBoundary: captureMode == ScanCaptureMode.spread
                  ? _rightLiveDetection.visibleNormalizedBoundary
                  : null,
              rightStable: _rightLiveDetection.hasStableDocument,
              rightDisplayLevel: _rightLiveDetection.displayLevelFor(
                CaptureBoundarySide.right,
              ),
              previewRotationDegrees: _previewRotation(),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AnimatedBuilder(
                  animation: widget.sessionManager,
                  builder: (context, child) => _CaptureModeSelector(
                    mode: widget.sessionManager.captureMode,
                    onChanged: _isCapturing ? null : _setCaptureMode,
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: AnimatedBuilder(
              animation: widget.sessionManager,
              builder: (context, child) {
                return Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _PageCountBadge(
                      pageCount: widget.sessionManager.pageCount,
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: AnimatedBuilder(
                animation: widget.sessionManager,
                builder: (context, child) {
                  final processing = widget.sessionManager.processingPageCount;
                  if (processing == 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _ProcessingBadge(processingPageCount: processing),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: AnimatedBuilder(
                animation: widget.sessionManager,
                builder: (context, child) {
                  final pages =
                      widget.sessionManager.currentSession?.pages ?? const [];
                  if (pages.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 0, 24),
                    child: RecentScanGalleryButton(
                      page: pages.last,
                      pageCount: pages.length,
                      onTap: _openGallery,
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Align(
              key: const Key('captureButtonSafeArea'),
              alignment: CameraCaptureButtonLayout.alignmentFor(captureMode),
              child: Padding(
                padding: CameraCaptureButtonLayout.paddingFor(captureMode),
                child: FilledButton(
                  key: const Key('captureButton'),
                  onPressed: _isCapturing ? null : _capturePage,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white54,
                    fixedSize: const Size.square(72),
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                  ),
                  child: _isCapturing
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      : const Icon(Icons.camera_alt, size: 30),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openGallery() async {
    await _stopPreviewAnalysis();
    if (!mounted) return;
    await widget.orientationController.enterContentScreen();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PageManagementPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted) return;
    await _applyCaptureOrientation(widget.sessionManager.captureMode);
    unawaited(_startPreviewAnalysis());
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.logState(
      'CameraPreviewPage.dispose',
      mounted: mounted,
    );
    unawaited(_stopPreviewAnalysis());
    _liveDetection.dispose();
    _leftLiveDetection.dispose();
    _rightLiveDetection.dispose();
    super.dispose();
  }
}

class _SpreadPreviewDetectorAdapter implements PreviewDocumentDetector {
  const _SpreadPreviewDetectorAdapter({
    required this.detector,
    required this.pageSide,
    required this.previewRotation,
  });
  final SpreadPreviewDocumentDetector? detector;
  final DocumentPageSide pageSide;
  final int Function() previewRotation;
  @override
  Future<DocumentDetectionResult> detect(PreviewLuminanceFrame frame) {
    final source = detector;
    if (source == null) {
      return Future.error(StateError('Spread preview is unavailable.'));
    }
    return source.detectForPage(
      frame,
      pageSide: pageSide,
      sensorOrientation: previewRotation(),
    );
  }
}

class _ScanGuideOverlay extends StatelessWidget {
  const _ScanGuideOverlay({
    required this.boundary,
    required this.isStable,
    required this.displayLevel,
    required this.previewRotationDegrees,
    this.leftBoundary,
    this.leftStable = false,
    this.leftDisplayLevel = LiveGuideDisplayLevel.none,
    this.rightBoundary,
    this.rightStable = false,
    this.rightDisplayLevel = LiveGuideDisplayLevel.none,
  });

  final PageBoundary? boundary;
  final bool isStable;
  final LiveGuideDisplayLevel displayLevel;
  final int previewRotationDegrees;
  final PageBoundary? leftBoundary;
  final bool leftStable;
  final LiveGuideDisplayLevel leftDisplayLevel;
  final PageBoundary? rightBoundary;
  final bool rightStable;
  final LiveGuideDisplayLevel rightDisplayLevel;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _ScanGuidePainter(
          boundary: boundary,
          isStable: isStable,
          displayLevel: displayLevel,
          leftBoundary: leftBoundary,
          leftStable: leftStable,
          leftDisplayLevel: leftDisplayLevel,
          rightBoundary: rightBoundary,
          rightStable: rightStable,
          rightDisplayLevel: rightDisplayLevel,
          previewRotationDegrees: previewRotationDegrees,
        ),
      ),
    );
  }
}

class CameraCaptureButtonLayout {
  const CameraCaptureButtonLayout._();

  static Alignment alignmentFor(ScanCaptureMode mode) =>
      mode == ScanCaptureMode.spread
      ? Alignment.centerRight
      : Alignment.bottomCenter;

  static EdgeInsets paddingFor(ScanCaptureMode mode) =>
      mode == ScanCaptureMode.spread
      ? const EdgeInsets.only(right: 24)
      : const EdgeInsets.only(bottom: 24);
}

class _CaptureModeSelector extends StatelessWidget {
  const _CaptureModeSelector({required this.mode, required this.onChanged});

  final ScanCaptureMode mode;
  final Future<void> Function(ScanCaptureMode mode)? onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SegmentedButton<ScanCaptureMode>(
        key: const Key('captureModeSelector'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: ScanCaptureMode.single,
            label: Text('1페이지'),
            icon: Icon(Icons.article_outlined),
          ),
          ButtonSegment(
            value: ScanCaptureMode.spread,
            label: Text('2페이지'),
            icon: Icon(Icons.menu_book_outlined),
          ),
        ],
        selected: {mode},
        onSelectionChanged: onChanged == null
            ? null
            : (selection) {
                final selected = selection.first;
                if (selected != mode) {
                  unawaited(onChanged!(selected));
                }
              },
      ),
    );
  }
}

/// Persistent WYSIWYG capture target shown independently from AI detection.
class FixedCaptureGuide extends StatelessWidget {
  const FixedCaptureGuide({super.key, required this.mode});

  final ScanCaptureMode mode;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        key: ValueKey('fixedCaptureGuide-${mode.name}'),
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _FixedCaptureGuidePainter(mode)),
          if (mode == ScanCaptureMode.spread)
            const Center(
              child: SizedBox(
                key: Key('fixedSpreadCenterGuide'),
                width: 2,
                height: double.infinity,
              ),
            ),
          if (mode == ScanCaptureMode.spread)
            const Align(
              alignment: Alignment(0, -0.66),
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black54),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    '책 가운데를 기준선에 맞춰주세요',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FixedCaptureGuidePainter extends CustomPainter {
  const _FixedCaptureGuidePainter(this.mode);

  final ScanCaptureMode mode;

  @override
  void paint(Canvas canvas, Size size) {
    final regions = CaptureGuidePolicy.previewRegions(
      mode,
      width: size.width,
      height: size.height,
    );
    for (final region in regions) {
      final rect = Rect.fromLTRB(
        region.left * size.width,
        region.top * size.height,
        region.right * size.width,
        region.bottom * size.height,
      );
      final outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(rect);
      canvas.drawPath(
        outside,
        Paint()..color = Colors.black.withValues(alpha: 0.10),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.92)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    if (mode == ScanCaptureMode.spread) {
      canvas.drawLine(
        Offset(size.width * .5, 0),
        Offset(size.width * .5, size.height),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.72)
          ..strokeWidth = 5,
      );
      canvas.drawLine(
        Offset(size.width * .5, 0),
        Offset(size.width * .5, size.height),
        Paint()
          ..color = const Color(0xff4ade80)
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FixedCaptureGuidePainter oldDelegate) =>
      oldDelegate.mode != mode;
}

class SpreadCaptureGuide extends StatelessWidget {
  const SpreadCaptureGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Container(
              key: const Key('spreadCenterGuide'),
              width: 2,
              margin: const EdgeInsets.symmetric(vertical: 72),
              color: const Color(0xff4ade80),
            ),
          ),
          const Align(
            alignment: Alignment(0, -0.66),
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  '책 가운데를 기준선에 맞춰주세요',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanGuidePainter extends CustomPainter {
  const _ScanGuidePainter({
    required this.boundary,
    required this.isStable,
    required this.displayLevel,
    required this.previewRotationDegrees,
    this.leftBoundary,
    this.leftStable = false,
    this.leftDisplayLevel = LiveGuideDisplayLevel.none,
    this.rightBoundary,
    this.rightStable = false,
    this.rightDisplayLevel = LiveGuideDisplayLevel.none,
  });

  final PageBoundary? boundary;
  final bool isStable;
  final LiveGuideDisplayLevel displayLevel;
  final int previewRotationDegrees;
  final PageBoundary? leftBoundary;
  final bool leftStable;
  final LiveGuideDisplayLevel leftDisplayLevel;
  final PageBoundary? rightBoundary;
  final bool rightStable;
  final LiveGuideDisplayLevel rightDisplayLevel;
  static DateTime? _lastPaintLogAt;

  @override
  void paint(Canvas canvas, Size size) {
    void draw(PageBoundary? detectedBoundary, LiveGuideDisplayLevel level) {
      if (detectedBoundary == null) return;
      final points = detectedBoundary.closedPolygon
          .map(
            (point) => CameraPreviewBoundaryTransform.toPreviewPoint(
              point,
              size,
              previewRotationDegrees,
            ),
          )
          .toList();
      final polygon = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        polygon.lineTo(point.dx, point.dy);
      }
      polygon.close();
      canvas.drawPath(
        polygon,
        Paint()
          ..color = switch (level) {
            LiveGuideDisplayLevel.stable => const Color(0xff4ade80),
            LiveGuideDisplayLevel.medium => const Color(0xffffd54f),
            LiveGuideDisplayLevel.low => const Color(0xffff7043),
            LiveGuideDisplayLevel.none => Colors.transparent,
          }.withValues(alpha: level == LiveGuideDisplayLevel.stable ? .98 : .82)
          ..style = PaintingStyle.stroke
          ..strokeWidth = level == LiveGuideDisplayLevel.stable ? 3.5 : 2.5
          ..strokeJoin = StrokeJoin.round,
      );
    }

    draw(boundary, displayLevel);
    draw(leftBoundary, leftDisplayLevel);
    draw(rightBoundary, rightDisplayLevel);
    if (kDebugMode) {
      final now = DateTime.now();
      if (_lastPaintLogAt == null ||
          now.difference(_lastPaintLogAt!) >= const Duration(seconds: 1)) {
        _lastPaintLogAt = now;
        final source = [boundary, leftBoundary, rightBoundary]
            .whereType<PageBoundary>()
            .expand((value) => value.closedPolygon)
            .map(
              (point) => CameraPreviewBoundaryTransform.toPreviewPoint(
                point,
                size,
                previewRotationDegrees,
              ),
            )
            .toList();
        final transformed = source.isEmpty
            ? null
            : Rect.fromLTRB(
                source.map((point) => point.dx).reduce(math.min),
                source.map((point) => point.dy).reduce(math.min),
                source.map((point) => point.dx).reduce(math.max),
                source.map((point) => point.dy).reduce(math.max),
              );
        DebugDiagnostics.instance.log(
          'LIVE_BOUNDARY',
          'previewWidth=${size.width.toStringAsFixed(1)} '
              'previewHeight=${size.height.toStringAsFixed(1)} '
              'overlayVisible=${source.isNotEmpty} '
              'transformedMinX=${transformed?.left.toStringAsFixed(1) ?? "n/a"} '
              'transformedMaxX=${transformed?.right.toStringAsFixed(1) ?? "n/a"} '
              'transformedMinY=${transformed?.top.toStringAsFixed(1) ?? "n/a"} '
              'transformedMaxY=${transformed?.bottom.toStringAsFixed(1) ?? "n/a"}',
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ScanGuidePainter oldDelegate) =>
      oldDelegate.boundary != boundary ||
      oldDelegate.isStable != isStable ||
      oldDelegate.displayLevel != displayLevel ||
      oldDelegate.leftBoundary != leftBoundary ||
      oldDelegate.leftStable != leftStable ||
      oldDelegate.leftDisplayLevel != leftDisplayLevel ||
      oldDelegate.rightBoundary != rightBoundary ||
      oldDelegate.rightStable != rightStable ||
      oldDelegate.rightDisplayLevel != rightDisplayLevel ||
      oldDelegate.previewRotationDegrees != previewRotationDegrees;
}

class CameraPreviewBoundaryTransform {
  const CameraPreviewBoundaryTransform._();

  static int rotationDegrees({
    required int sensorOrientation,
    required DeviceOrientation deviceOrientation,
    required bool isFrontFacing,
  }) {
    final deviceDegrees = deviceOrientationDegrees(deviceOrientation);
    return isFrontFacing
        ? (sensorOrientation + deviceDegrees) % 360
        : (sensorOrientation - deviceDegrees + 360) % 360;
  }

  static int deviceOrientationDegrees(DeviceOrientation deviceOrientation) =>
      switch (deviceOrientation) {
        DeviceOrientation.portraitUp => 0,
        DeviceOrientation.landscapeLeft => 90,
        DeviceOrientation.portraitDown => 180,
        DeviceOrientation.landscapeRight => 270,
      };

  static Offset toPreviewPoint(
    DocumentPoint point,
    Size previewSize,
    int rotationDegrees,
  ) {
    final normalized = switch (rotationDegrees) {
      90 => Offset(1 - point.y, point.x),
      180 => Offset(1 - point.x, 1 - point.y),
      270 => Offset(point.y, 1 - point.x),
      _ => Offset(point.x, point.y),
    };
    return Offset(
      normalized.dx * previewSize.width,
      normalized.dy * previewSize.height,
    );
  }

  static Rect? normalizedBounds(PageBoundary? boundary) {
    if (boundary == null || boundary.closedPolygon.isEmpty) return null;
    final points = boundary.closedPolygon;
    return Rect.fromLTRB(
      points.map((point) => point.x).reduce(math.min),
      points.map((point) => point.y).reduce(math.min),
      points.map((point) => point.x).reduce(math.max),
      points.map((point) => point.y).reduce(math.max),
    );
  }
}

class CameraBoundaryOverlayStyle {
  const CameraBoundaryOverlayStyle._();

  static const bool showsFixedCaptureGuide = true;
}

class RecentScanGalleryButton extends StatelessWidget {
  const RecentScanGalleryButton({
    super.key,
    required this.page,
    required this.pageCount,
    required this.onTap,
  });

  final ScanPage page;
  final int pageCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('recentScanGalleryButton'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Ink(
              width: 64,
              height: 88,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Transform.rotate(
                  angle: page.rotation * math.pi / 180,
                  child: Image.file(
                    File(page.displayImagePath),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return const ColoredBox(
                        color: Colors.black54,
                        child: Icon(Icons.image_not_supported_outlined),
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              top: -9,
              right: -9,
              child: Badge(
                key: const Key('recentScanPageCount'),
                label: Text('$pageCount'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageCountBadge extends StatelessWidget {
  const _PageCountBadge({required this.pageCount});

  final int pageCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          '$pageCount Pages',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

class _ProcessingBadge extends StatelessWidget {
  const _ProcessingBadge({required this.processingPageCount});

  final int processingPageCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          '$processingPageCount장 처리 중',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Text(
          message ?? '카메라를 준비하는 중입니다.',
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

enum _RecoveryAction { resume, delete }

class _RecoveryDialog extends StatelessWidget {
  const _RecoveryDialog({required this.session});

  final ScanSession session;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final createdTime =
        '${localizations.formatMediumDate(session.createdTime)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(session.createdTime))}';

    return AlertDialog(
      title: const Text('이전 스캔 작업이 있습니다.'),
      content: Text('생성 시간: $createdTime\n페이지 수: ${session.pages.length}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_RecoveryAction.delete),
          child: const Text('삭제 후 새 스캔'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_RecoveryAction.resume),
          child: const Text('이어하기'),
        ),
      ],
    );
  }
}
