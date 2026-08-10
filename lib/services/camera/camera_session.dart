import 'package:camera/camera.dart';

/// Owns the initialized camera controller used by the scanning flow.
///
/// Future scan, capture, and image-processing capabilities should use this
/// session instead of accessing the camera plugin from UI widgets.
class CameraSession {
  CameraSession._(this.controller);

  final CameraController controller;

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
      );
      await controller.initialize();

      return CameraStartup.ready(CameraSession._(controller));
    } on CameraException catch (error) {
      return CameraStartup.unavailable(_messageFor(error));
    } catch (_) {
      return const CameraStartup.unavailable('카메라를 초기화할 수 없습니다.');
    }
  }

  Future<void> dispose() => controller.dispose();

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
