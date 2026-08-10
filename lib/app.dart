import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/storage/temporary_session_storage.dart';

/// Root application shell for Scana.
class ScanaApp extends StatefulWidget {
  const ScanaApp({super.key, this.cameraStartup, this.sessionManager});

  final CameraStartup? cameraStartup;
  final ScanSessionManager? sessionManager;

  @override
  State<ScanaApp> createState() => _ScanaAppState();
}

class _ScanaAppState extends State<ScanaApp> {
  late final ScanSessionManager _sessionManager;

  @override
  void initState() {
    super.initState();
    _sessionManager =
        widget.sessionManager ??
        ScanSessionManager(storage: AppTemporarySessionStorage());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    unawaited(widget.cameraStartup?.session?.dispose());
    _sessionManager.close();
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
      home: CameraPreviewPage(
        cameraStartup: widget.cameraStartup,
        sessionManager: _sessionManager,
      ),
    );
  }
}
