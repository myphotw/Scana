import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/pdf_export/pdf_saf_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.myphotw.scana/pdf_storage');
  const storage = AndroidSafPdfStorage(channel: channel);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('SAF picker cancellation is returned as a normal null result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'chooseDirectory');
          return null;
        });

    expect(await storage.chooseDirectory(), isNull);
  });

  test('SAF picker result restores the selected directory', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'chooseDirectory');
          return <String, dynamic>{
            'uri': 'content://documents/tree/primary%3ADocuments',
            'label': 'Documents',
          };
        });

    final directory = await storage.chooseDirectory();
    expect(directory?.label, 'Documents');
    expect(directory?.uri, startsWith('content://documents/tree/'));
  });

  test('recent SAF directory avoids opening a new picker', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getRecentDirectory');
          return <String, dynamic>{
            'uri': 'content://documents/tree/recent',
            'label': 'Recent folder',
          };
        });

    final directory = await storage.recentDirectory();
    expect(directory?.label, 'Recent folder');
  });
}
