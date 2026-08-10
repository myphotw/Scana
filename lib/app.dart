import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/services/camera/camera_session.dart';

/// Root application shell for Scana.
class ScanaApp extends StatefulWidget {
  const ScanaApp({super.key, this.cameraStartup});

  final CameraStartup? cameraStartup;

  @override
  State<ScanaApp> createState() => _ScanaAppState();
}

class _ScanaAppState extends State<ScanaApp> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    widget.cameraStartup?.session?.dispose();
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
      home: CameraPreviewPage(cameraStartup: widget.cameraStartup),
    );
  }
}
