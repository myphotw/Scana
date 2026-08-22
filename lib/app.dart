import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scana/features/home/presentation/scan_home_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/storage/scan_session_storage.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

/// Root application shell for Scana.
class ScanaApp extends StatefulWidget {
  const ScanaApp({
    super.key,
    this.cameraStartup,
    this.sessionManager,
    this.recoverySession,
    this.ownsInjectedCameraSession = false,
    this.ownsInjectedSessionManager = false,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final CameraStartup? cameraStartup;
  final ScanSessionManager? sessionManager;
  final ScanSession? recoverySession;
  final bool ownsInjectedCameraSession;
  final bool ownsInjectedSessionManager;
  final ScreenOrientationController orientationController;

  @override
  State<ScanaApp> createState() => _ScanaAppState();
}

class _ScanaAppState extends State<ScanaApp> with WidgetsBindingObserver {
  late final ScanSessionManager _sessionManager;
  late final bool _ownsSessionManager;
  late final DebugNavigatorObserver _navigatorObserver;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionManager =
        widget.sessionManager ??
        ScanSessionManager(storage: AppPrivateSessionStorage());
    _ownsSessionManager =
        widget.sessionManager == null || widget.ownsInjectedSessionManager;
    _navigatorObserver = DebugNavigatorObserver();
    DebugDiagnostics.instance.logState('ScanaApp.initState', mounted: mounted);
    _showSystemBars();
  }

  void _showSystemBars() =>
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _showSystemBars();
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.logState('ScanaApp.dispose', mounted: mounted);
    WidgetsBinding.instance.removeObserver(this);
    if (widget.ownsInjectedCameraSession) {
      unawaited(widget.cameraStartup?.session?.dispose());
    }
    if (_ownsSessionManager) {
      _sessionManager.close();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(widget.orientationController.restoreSystemDefault());
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
      home: ScanHomePage(
        cameraStartup: widget.cameraStartup,
        sessionManager: _sessionManager,
        recoverySession: widget.recoverySession,
        orientationController: widget.orientationController,
      ),
    );
  }
}
