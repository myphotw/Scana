import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'package:scana/features/page_editor/presentation/page_editor_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/camera/camera_session.dart';

/// Full-screen camera entry point for the document scanning flow.
class CameraPreviewPage extends StatefulWidget {
  const CameraPreviewPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.recoverySession,
  });

  final CameraStartup? cameraStartup;
  final ScanSessionManager sessionManager;
  final ScanSession? recoverySession;

  @override
  State<CameraPreviewPage> createState() => _CameraPreviewPageState();
}

class _CameraPreviewPageState extends State<CameraPreviewPage> {
  bool _isCapturing = false;
  bool _recoveryPromptShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showRecoveryPrompt());
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
      final capturedImagePath = await cameraSession.captureRawImage();
      await widget.sessionManager.addRawCapture(capturedImagePath);
    } on CameraException catch (_) {
      _showCaptureError();
    } on FileSystemException catch (_) {
      _showCaptureError();
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(cameraSession.controller),
          const _ScanGuideOverlay(),
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
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (context) => PageEditorPage(
                              sessionManager: widget.sessionManager,
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
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
}

class _ScanGuideOverlay extends StatelessWidget {
  const _ScanGuideOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(painter: _ScanGuidePainter()),
          const Align(
            alignment: Alignment(0, 0.68),
            child: DecoratedBox(
              decoration: BoxDecoration(color: Colors.black54),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  '문서를 가이드 안에 맞춰 주세요',
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
  @override
  void paint(Canvas canvas, Size size) {
    final guideWidth = size.width * 0.78;
    final guideHeight = math.min(size.height * 0.68, guideWidth * 1.414);
    final guide = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: guideWidth,
        height: guideHeight,
      ),
      const Radius.circular(16),
    );
    final dimmedArea = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(guide);
    canvas.drawPath(dimmedArea, Paint()..color = Colors.black38);
    canvas.drawRRect(
      guide,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
                File(page.rawImagePath),
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
