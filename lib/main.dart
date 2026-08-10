import 'package:flutter/widgets.dart';

import 'package:scana/app.dart';
import 'package:scana/services/camera/camera_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameraStartup = await CameraSession.initializeDefault();
  runApp(ScanaApp(cameraStartup: cameraStartup));
}
