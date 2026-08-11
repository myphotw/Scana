import 'package:camera/camera.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';

/// Owns the initialized camera controller used by the scanning flow.
class CameraSession {
  CameraSession._(this.controller) {
    DebugDiagnostics.instance.log('STATE', 'CameraSession.created');
  }

  final CameraController controller;
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  Future<String> captureRawImage() async {
    final capturedImage = await controller.takePicture();
    return capturedImage.path;
  }

  bool get isAnalyzingPreview => controller.value.isStreamingImages;

  /// Reuses the app-start controller after returning from result routes.
  /// No controller is recreated here, and a disposed controller is never read.
  Future<bool> ensurePreviewReady() async {
    if (_isDisposed || !controller.value.isInitialized) return false;
    if (controller.value.isPreviewPaused) {
      await controller.resumePreview();
    }
    return !_isDisposed && controller.value.isInitialized;
  }

  Future<void> startPreviewAnalysis(
    void Function(CameraImage image) onFrame,
  ) async {
    if (!await ensurePreviewReady() || controller.value.isStreamingImages) {
      return;
    }
    await controller.startImageStream(onFrame);
  }

  Future<void> stopPreviewAnalysis() async {
    if (!_isDisposed && controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
  }

  /// Initializes the preferred rear camera before the app UI is displayed.
  static Future<CameraStartup> initializeDefault() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        return const CameraStartup.unavailable('사용 가능한 카메라가 없습니다.');
      }

      final selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();

      return CameraStartup.ready(CameraSession._(controller));
    } on CameraException catch (error) {
      return CameraStartup.unavailable(_messageFor(error));
    } catch (_) {
      return const CameraStartup.unavailable('카메라를 초기화할 수 없습니다.');
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    DebugDiagnostics.instance.log('STATE', 'CameraSession.dispose');
    await controller.dispose();
  }

  static String _messageFor(CameraException error) {
    return switch (error.code) {
      'CameraAccessDenied' => '카메라 권한이 필요합니다.',
      'CameraAccessDeniedWithoutPrompt' => '설정에서 카메라 권한을 허용해 주세요.',
      _ => '카메라를 초기화할 수 없습니다.',
    };
  }
}

/// The result of the app-start camera initialization.
class CameraStartup {
  const CameraStartup.ready(this.session) : errorMessage = null;

  const CameraStartup.unavailable(this.errorMessage) : session = null;

  final CameraSession? session;
  final String? errorMessage;

  bool get isReady => session != null;
}
