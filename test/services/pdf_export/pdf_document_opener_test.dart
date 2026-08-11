import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/pdf_export/pdf_document_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/pdf_document');
  final messenger = TestDefaultBinaryMessengerBinding.instance;

  tearDown(() {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('opens the saved content URI through the native PDF viewer', () async {
    MethodCall? received;
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      received = call;
      return <String, Object>{'opened': true};
    });
    const opener = AndroidPdfDocumentOpener(channel: channel);

    expect(
      await opener.open('content://documents/report.pdf'),
      PdfOpenResult.opened,
    );
    expect(received?.method, 'openPdf');
    expect(received?.arguments, {
      'documentUri': 'content://documents/report.pdf',
    });
  });

  test('reports when no PDF viewer is installed', () async {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{'opened': false},
    );
    const opener = AndroidPdfDocumentOpener(channel: channel);

    expect(
      await opener.open('content://documents/report.pdf'),
      PdfOpenResult.noViewer,
    );
  });
}
