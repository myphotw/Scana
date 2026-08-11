import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/storage/scan_session_storage.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';

/// Root application shell for Scana.
class ScanaApp extends StatefulWidget {
  const ScanaApp({
    super.key,
    this.cameraStartup,
    this.sessionManager,
    this.recoverySession,
    this.ownsInjectedCameraSession = false,
    this.ownsInjectedSessionManager = false,
  });

  final CameraStartup? cameraStartup;
  final ScanSessionManager? sessionManager;
  final ScanSession? recoverySession;
  final bool ownsInjectedCameraSession;
  final bool ownsInjectedSessionManager;

  @override
  State<ScanaApp> createState() => _ScanaAppState();
}

class _ScanaAppState extends State<ScanaApp> {
  late final ScanSessionManager _sessionManager;
  late final bool _ownsSessionManager;
  late final DebugNavigatorObserver _navigatorObserver;

  @override
  void initState() {
    super.initState();
    _sessionManager =
        widget.sessionManager ??
        ScanSessionManager(storage: AppPrivateSessionStorage());
    _ownsSessionManager =
        widget.sessionManager == null || widget.ownsInjectedSessionManager;
    _navigatorObserver = DebugNavigatorObserver();
    DebugDiagnostics.instance.logState('ScanaApp.initState', mounted: mounted);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.logState('ScanaApp.dispose', mounted: mounted);
    if (widget.ownsInjectedCameraSession) {
      unawaited(widget.cameraStartup?.session?.dispose());
    }
    if (_ownsSessionManager) {
      _sessionManager.close();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scana',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      navigatorObservers: [_navigatorObserver],
      home: CameraPreviewPage(
        cameraStartup: widget.cameraStartup,
        sessionManager: _sessionManager,
        recoverySession: widget.recoverySession,
      ),
    );
  }
}
