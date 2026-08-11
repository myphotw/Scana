import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/orientation/screen_orientation_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('maps each screen role to one centralized orientation policy', () async {
    const controller = SystemScreenOrientationController();

    await controller.enterSingleCamera();
    await controller.enterSpreadCamera();
    await controller.enterContentScreen();
    await controller.restoreSystemDefault();

    expect(calls.map((call) => call.method), {
      'SystemChrome.setPreferredOrientations',
    });
    expect(calls[0].arguments, ['DeviceOrientation.portraitUp']);
    expect(calls[1].arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(calls[2].arguments, ['DeviceOrientation.portraitUp']);
    expect(calls[3].arguments, [
      'DeviceOrientation.portraitUp',
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.portraitDown',
      'DeviceOrientation.landscapeRight',
    ]);
  });
}
