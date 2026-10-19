import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/pdf_editor/existing_pdf_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.myphotw.scana/existing_pdf_editor');
  const platform = AndroidExistingPdfEditorPlatform(channel: channel);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'pickPdf' => <String, Object>{
              'sessionId': '00000000-0000-0000-0000-000000000001',
              'sourcePath': '/work/source.pdf',
              'displayName': 'source.pdf',
              'pageCount': 5,
              'byteCount': 1024,
            },
            'renderThumbnail' => <String, Object>{
              'path': '/work/thumb.png',
              'pageIndex': 2,
            },
            'exportPdf' => <String, Object>{
              'outputPath': '/work/output.pdf',
              'pageCount': 4,
              'byteCount': 900,
            },
            'cleanup' => null,
            _ => throw PlatformException(code: 'unexpected'),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'imports PDF metadata and lazily renders a requested thumbnail',
    () async {
      final document = await platform.pickPdf();
      expect(document?.pageCount, 5);
      expect(document?.displayName, 'source.pdf');

      final thumbnail = await platform.renderThumbnail(
        sessionId: document!.sessionId,
        pageIndex: 2,
      );
      expect(thumbnail, '/work/thumb.png');
      expect(calls.map((call) => call.method), ['pickPdf', 'renderThumbnail']);
    },
  );

  test(
    'PDF picker cancellation returns null without starting an edit',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      expect(await platform.pickPdf(), isNull);
      expect(calls.single.method, 'pickPdf');
    },
  );

  test('passes exact non-duplicated order to the native qpdf editor', () async {
    final result = await platform.exportPdf(
      sessionId: '00000000-0000-0000-0000-000000000001',
      pageOrder: const [2, 0, 4, 1],
    );
    expect(result.pageCount, 4);
    expect(calls.single.arguments['pageOrder'], [2, 0, 4, 1]);
  });

  test(
    'rejects empty, duplicated, and negative page orders before JNI',
    () async {
      await expectLater(
        platform.exportPdf(sessionId: 'session', pageOrder: const []),
        throwsStateError,
      );
      await expectLater(
        platform.exportPdf(sessionId: 'session', pageOrder: const [0, 0]),
        throwsFormatException,
      );
      await expectLater(
        platform.exportPdf(sessionId: 'session', pageOrder: const [-1]),
        throwsFormatException,
      );
      expect(calls, isEmpty);
    },
  );
}
