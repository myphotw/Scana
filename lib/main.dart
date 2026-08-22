import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:scana/app.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/page_corrector.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/image_processing/ai_document_segmenter.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DebugDiagnostics.instance.initialize();
  DebugDiagnostics.instance.logStartup('STARTUP', 'flutter_binding_ready');

  final sessionManager = createProductionSessionManager(
    storage: AppPrivateSessionStorage(),
    debugMode: kDebugMode,
  );
  final recoverableSessions = await loadRecoverableSessionsSafely(
    sessionManager,
  );
  runApp(
    ScanaApp(
      sessionManager: sessionManager,
      recoverySession: recoverableSessions.firstOrNull,
      ownsInjectedSessionManager: true,
    ),
  );
  DebugDiagnostics.instance.logStartup('STARTUP', 'runApp_called');
}

@visibleForTesting
ScanSessionManager createProductionSessionManager({
  required ScanSessionStorage storage,
  required bool debugMode,
}) => ScanSessionManager(
  storage: storage,
  documentDetector: debugMode
      ? const OpenCvDocumentDetector()
      : const NoOpDocumentDetector(),
  pageCorrector: debugMode
      ? const OpenCvPageCorrector()
      : const UnavailablePageCorrector(),
  pageEnhancer: debugMode
      ? const OpenCvPageEnhancer()
      : const UnavailablePageEnhancer(),
  aiDocumentSegmenter: debugMode
      ? const PlatformAiDocumentSegmenter()
      : null,
);

@visibleForTesting
Future<List<ScanSession>> loadRecoverableSessionsSafely(
  ScanSessionManager sessionManager,
) async {
  try {
    final sessions = await sessionManager.findRecoverableSessions();
    DebugDiagnostics.instance.logStartup(
      'STARTUP',
      'session_recovery_complete count=${sessions.length}',
    );
    return sessions;
  } on Object catch (error, stackTrace) {
    // A damaged or inaccessible previous session must never block first paint.
    DebugDiagnostics.instance.logStartup(
      'STARTUP',
      'session_recovery_failed type=${error.runtimeType} '
          'message=$error\nstack=$stackTrace',
    );
    return const [];
  }
}
