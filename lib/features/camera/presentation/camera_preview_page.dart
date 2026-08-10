import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/services/camera/camera_session.dart';

/// Full-screen camera entry point for the document scanning flow.
class CameraPreviewPage extends StatefulWidget {
  const CameraPreviewPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
  });

  final CameraStartup? cameraStartup;
  final ScanSessionManager sessionManager;

  @override
  State<CameraPreviewPage> createState() => _CameraPreviewPageState();
}

class _CameraPreviewPageState extends State<CameraPreviewPage> {
  bool _isCapturing = false;

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
