import 'package:flutter/services.dart';

/// Centralizes the screen-role orientation policy for the scan flow.
abstract interface class ScreenOrientationController {
  Future<void> enterSingleCamera();

  Future<void> enterSpreadCamera();

  Future<void> enterContentScreen();

  Future<void> restoreSystemDefault();
}

class SystemScreenOrientationController implements ScreenOrientationController {
  const SystemScreenOrientationController();

  @override
  Future<void> enterSingleCamera() =>
      _set(const [DeviceOrientation.portraitUp]);

  @override
  Future<void> enterSpreadCamera() => _set(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  @override
  Future<void> enterContentScreen() =>
      _set(const [DeviceOrientation.portraitUp]);

  @override
  Future<void> restoreSystemDefault() => _set(DeviceOrientation.values);

  Future<void> _set(List<DeviceOrientation> orientations) async {
    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } on PlatformException {
      // Orientation support must never block navigation or camera recovery.
    } on MissingPluginException {
      // Widget tests and non-Android hosts do not install the platform channel.
    }
  }
}
