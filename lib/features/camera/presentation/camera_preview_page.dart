import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/image_processing/live_document_detection.dart';

/// Full-screen camera entry point for the document scanning flow.
class CameraPreviewPage extends StatefulWidget {
  const CameraPreviewPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.recoverySession,
    this.replacementPageIndex,
    this.previewDocumentDetector,
  });

  final CameraStartup? cameraStartup;
  final ScanSessionManager sessionManager;
  final ScanSession? recoverySession;
  final int? replacementPageIndex;
  final PreviewDocumentDetector? previewDocumentDetector;

  @override
  State<CameraPreviewPage> createState() => _CameraPreviewPageState();
}

class _CameraPreviewPageState extends State<CameraPreviewPage> {
  bool _isCapturing = false;
  bool _recoveryPromptShown = false;
  late final LiveDocumentDetectionController _liveDetection;

  @override
  void initState() {
    super.initState();
    _liveDetection = LiveDocumentDetectionController(
      detector:
          widget.previewDocumentDetector ??
          const OpenCvPreviewDocumentDetector(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _showRecoveryPrompt();
      await _applyCaptureOrientation(widget.sessionManager.captureMode);
      await _startPreviewAnalysis();
    });
  }

  Future<void> _startPreviewAnalysis() async {
    final camera = widget.cameraStartup?.session;
    if (camera == null ||
        !mounted ||
        widget.sessionManager.captureMode == ScanCaptureMode.spread) {
      return;
    }
    try {
      await camera.startPreviewAnalysis((image) {
        if (!_liveDetection.canAccept || image.planes.isEmpty) return;
        final plane = image.planes.first;
        unawaited(
          _liveDetection.submit(
            PreviewLuminanceFrame(
              bytes: Uint8List.fromList(plane.bytes),
              width: image.width,
              height: image.height,
              rowStride: plane.bytesPerRow,
            ),
          ),
        );
      });
    } on CameraException {
      // Optional live guidance must never block still capture.
    }
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
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => ScanResultViewerPage(
                  sessionManager: widget.sessionManager,
                  cameraStartup: widget.cameraStartup,
                ),
              ),
            );
            if (mounted) unawaited(_startPreviewAnalysis());
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
          : _ScanGuideGeometry.regionFor(MediaQuery.sizeOf(context));
      final previewBoundary = isSpread
          ? null
          : _liveDetection.stableNormalizedBoundary;
      final stablePreviewBoundary = previewBoundary == null
          ? null
          : PreviewCornerMapper.boundaryToUpright(
              previewBoundary,
              cameraSession.controller.description.sensorOrientation,
            );
      final stablePreviewCorners = stablePreviewBoundary?.toDocumentCorners();
      await _stopPreviewAnalysis();
      final capturedImagePath = await cameraSession.captureRawImage();
      final replacementPageIndex = widget.replacementPageIndex;
      if (replacementPageIndex != null) {
        final replaced = await widget.sessionManager.replacePageAt(
          replacementPageIndex,
          capturedImagePath,
          captureGuideRegion: captureGuideRegion,
          stablePreviewCorners: stablePreviewCorners,
          stablePreviewBoundary: stablePreviewBoundary,
        );
        if (mounted) {
          Navigator.of(context).pop(replaced);
        }
        return;
      }
      if (isSpread) {
        unawaited(_processSpreadCapture(capturedImagePath));
      } else {
        unawaited(
          _processCapturedImage(
            capturedImagePath,
            captureGuideRegion!,
            stablePreviewCorners,
            stablePreviewBoundary,
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
    DocumentCorners? stablePreviewCorners,
    PageBoundary? stablePreviewBoundary,
  ) async {
    try {
      await widget.sessionManager.captureAndProcess(
        capturedImagePath,
        captureGuideRegion: captureGuideRegion,
        stablePreviewCorners: stablePreviewCorners,
        stablePreviewBoundary: stablePreviewBoundary,
      );
    } on Object {
      _showCaptureError();
    }
  }

  Future<void> _processSpreadCapture(String capturedImagePath) async {
    try {
      await widget.sessionManager.captureAndProcessSpread(capturedImagePath);
    } on Object {
      _showCaptureError();
    }
  }

  Future<void> _setCaptureMode(ScanCaptureMode mode) async {
    await _stopPreviewAnalysis();
    await widget.sessionManager.setCaptureMode(mode);
    _liveDetection.reset();
    await _applyCaptureOrientation(mode);
    if (mode == ScanCaptureMode.single) {
      unawaited(_startPreviewAnalysis());
    }
    if (mounted) setState(() {});
  }

  Future<void> _applyCaptureOrientation(ScanCaptureMode mode) {
    return SystemChrome.setPreferredOrientations(
      mode == ScanCaptureMode.spread
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : DeviceOrientation.values,
    );
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
          AnimatedBuilder(
            animation: _liveDetection,
            builder: (context, child) => _ScanGuideOverlay(
              boundary:
                  widget.sessionManager.captureMode == ScanCaptureMode.spread
                  ? null
                  : _liveDetection.visibleNormalizedBoundary,
              isStable: _liveDetection.hasStableDocument,
              sensorOrientation:
                  cameraSession.controller.description.sensorOrientation,
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
          if (widget.sessionManager.captureMode == ScanCaptureMode.spread)
            const SpreadCaptureGuide(),
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
                    child: _LatestPageThumbnail(
                      page: pages.last,
                      onTap: () => _openViewer(pages.length - 1),
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
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 20, 30),
                child: FilledButton.tonalIcon(
                  onPressed: _finishCapture,
                  icon: const Icon(Icons.check),
                  label: const Text('촬영 완료'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _finishCapture() async {
    final processing = widget.sessionManager.processingPageCount;
    if (processing > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$processing장 처리 중입니다. 완료 후 이동할 수 있습니다.')),
      );
      return;
    }
    if (widget.sessionManager.pageCount == 0) return;
    await _stopPreviewAnalysis();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PageManagementPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
        ),
      ),
    );
    if (mounted) unawaited(_startPreviewAnalysis());
  }

  Future<void> _openViewer(int initialPageIndex) async {
    await _stopPreviewAnalysis();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ScanResultViewerPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
          initialPageIndex: initialPageIndex,
        ),
      ),
    );
    if (mounted) unawaited(_startPreviewAnalysis());
  }

  @override
  void dispose() {
    unawaited(_stopPreviewAnalysis());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    _liveDetection.dispose();
    super.dispose();
  }
}

class _ScanGuideOverlay extends StatelessWidget {
  const _ScanGuideOverlay({
    required this.boundary,
    required this.isStable,
    required this.sensorOrientation,
  });

  final PageBoundary? boundary;
  final bool isStable;
  final int sensorOrientation;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _ScanGuidePainter(
              boundary: boundary,
              isStable: isStable,
              sensorOrientation: sensorOrientation,
            ),
          ),
          Align(
            alignment: Alignment(0, 0.68),
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Colors.black54),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  BoundaryQualityAssessment.evaluate(boundary).message,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
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
    required this.sensorOrientation,
  });

  final PageBoundary? boundary;
  final bool isStable;
  final int sensorOrientation;

  @override
  void paint(Canvas canvas, Size size) {
    final detectedBoundary = boundary;
    if (detectedBoundary != null) {
      final points = detectedBoundary.closedPolygon
          .map((point) => _previewPoint(point, size, sensorOrientation))
          .toList();
      final polygon = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        polygon.lineTo(point.dx, point.dy);
      }
      polygon.close();
      canvas.drawPath(
        polygon,
        Paint()
          ..color = (isStable ? const Color(0xff4ade80) : Colors.white70)
              .withValues(alpha: 0.12)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        polygon,
        Paint()
          ..color = isStable ? const Color(0xff4ade80) : Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  static Offset _previewPoint(DocumentPoint point, Size size, int orientation) {
    final normalized = switch (orientation) {
      90 => Offset(1 - point.y, point.x),
      180 => Offset(1 - point.x, 1 - point.y),
      270 => Offset(point.y, 1 - point.x),
      _ => Offset(point.x, point.y),
    };
    return Offset(normalized.dx * size.width, normalized.dy * size.height);
  }

  @override
  bool shouldRepaint(covariant _ScanGuidePainter oldDelegate) =>
      oldDelegate.boundary != boundary ||
      oldDelegate.isStable != isStable ||
      oldDelegate.sensorOrientation != sensorOrientation;
}

class CameraBoundaryOverlayStyle {
  const CameraBoundaryOverlayStyle._();

  /// The normalized capture guide remains metadata-only fallback.
  static const bool showsFixedCaptureGuide = false;
}

class _ScanGuideGeometry {
  const _ScanGuideGeometry._();

  static Rect rectFor(Size size) {
    final guideWidth = size.width * 0.78;
    final guideHeight = math.min(size.height * 0.68, guideWidth * 1.414);
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: guideWidth,
      height: guideHeight,
    );
  }

  static CaptureGuideRegion regionFor(Size size) {
    final rect = rectFor(size);
    return CaptureGuideRegion(
      left: rect.left / size.width,
      top: rect.top / size.height,
      right: rect.right / size.width,
      bottom: rect.bottom / size.height,
    );
  }
}

class _LatestPageThumbnail extends StatelessWidget {
  const _LatestPageThumbnail({required this.page, required this.onTap});

  final ScanPage page;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
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
                File(page.correctedImagePath ?? page.rawImagePath),
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
