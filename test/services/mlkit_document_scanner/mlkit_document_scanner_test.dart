import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scana/features/home/presentation/scan_home_page.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/mlkit_document_scanner');
  const scanner = AndroidMlKitDocumentScanner(channel: channel);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('bridge returns multiple copied JPEG pages', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return {
            'status': 'completed',
            'pages': [
              {
                'filePath': '/private/mlkit/page_001.jpg',
                'byteCount': 1200,
                'width': 2480,
                'height': 3508,
              },
              {
                'filePath': '/private/mlkit/page_002.jpg',
                'byteCount': 1300,
                'width': 2480,
                'height': 3508,
              },
            ],
          };
        });

    final result = await scanner.scan(sessionId: 'session-id', startPageNo: 1);

    expect(received?.method, 'startScan');
    expect(received?.arguments, {'sessionId': 'session-id', 'startPageNo': 1});
    expect(result.status, MlKitScanStatus.completed);
    expect(result.pages, hasLength(2));
    expect(result.pages.last.byteCount, 1300);
  });

  test('bridge preserves cancellation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {'status': 'cancelled'},
        );

    final result = await scanner.scan(sessionId: 'session-id', startPageNo: 1);

    expect(result.status, MlKitScanStatus.cancelled);
    expect(result.pages, isEmpty);
  });

  test('bridge preserves native error code', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(
            code: 'mlkit_18',
            message: 'unsupported device',
            details: const <String, Object?>{
              'exceptionClass': 'com.google.mlkit.common.MlKitException',
              'errorCode': 18,
              'googlePlayServicesStatus': 0,
              'googlePlayServicesStatusName': 'SUCCESS',
            },
          );
        });

    await expectLater(
      scanner.scan(sessionId: 'session-id', startPageNo: 1),
      throwsA(
        isA<MlKitDocumentScannerException>()
            .having((error) => error.code, 'code', 'mlkit_18')
            .having((error) => error.message, 'message', 'unsupported device')
            .having((error) => error.details['errorCode'], 'errorCode', 18)
            .having(
              (error) => error.details['exceptionClass'],
              'exceptionClass',
              'com.google.mlkit.common.MlKitException',
            ),
      ),
    );
  });

  test('bridge accepts a completed empty result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {'status': 'completed', 'pages': <Object>[]},
        );

    final result = await scanner.scan(sessionId: 'session-id', startPageNo: 1);

    expect(result.status, MlKitScanStatus.completed);
    expect(result.pages, isEmpty);
  });

  test('release visibility policy hides only the legacy scanner entry', () {
    expect(
      ProductionScanHomeVisibility.showsLegacyScanner(debugMode: true),
      true,
    );
    expect(
      ProductionScanHomeVisibility.showsLegacyScanner(debugMode: false),
      false,
    );
  });
}
