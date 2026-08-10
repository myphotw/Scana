import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'package:scana/services/camera/camera_session.dart';

/// Full-screen entry point for the document scanning flow.
///
/// This milestone intentionally contains only the live camera preview. Capture
/// controls and scan overlays will be composed here in later milestones.
class CameraPreviewPage extends StatelessWidget {
  const CameraPreviewPage({super.key, this.cameraStartup});

  final CameraStartup? cameraStartup;

  @override
  Widget build(BuildContext context) {
    final session = cameraStartup?.session;
    if (session == null) {
      return _CameraUnavailable(message: cameraStartup?.errorMessage);
    }

    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(child: CameraPreview(session.controller)),
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
