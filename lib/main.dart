import 'package:flutter/widgets.dart';

import 'package:scana/app.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/page_corrector.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugDiagnostics.instance.initialize();

  final sessionManager = ScanSessionManager(
    storage: AppPrivateSessionStorage(),
    documentDetector: const OpenCvDocumentDetector(),
    pageCorrector: const OpenCvPageCorrector(),
  );
  final recoverableSessions = await sessionManager.findRecoverableSessions();
  final cameraStartup = await CameraSession.initializeDefault();
  runApp(
    ScanaApp(
      cameraStartup: cameraStartup,
      sessionManager: sessionManager,
      recoverySession: recoverableSessions.firstOrNull,
      ownsInjectedCameraSession: true,
      ownsInjectedSessionManager: true,
    ),
  );
}
