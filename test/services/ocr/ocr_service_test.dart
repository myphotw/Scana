import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/ocr/ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/local_ocr');
  final messenger = TestDefaultBinaryMessengerBinding.instance;

  tearDown(() {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('parses Korean OCR blocks, lines, confidence and geometry', () async {
    MethodCall? received;
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      received = call;
      return <String, Object>{
        'fullText': '사내 품질관리 프로세스 개선안\n품질혁신팀',
        'sourcePageId': 'raw_001.jpg',
        'sourceWidth': 1200,
        'sourceHeight': 1800,
        'blocks': [
          {
            'text': '사내 품질관리 프로세스 개선안',
            'language': 'ko',
            'boundingBox': {
              'left': 120,
              'top': 130,
              'right': 1050,
              'bottom': 230,
            },
            'lines': [
              {
                'text': '사내 품질관리 프로세스 개선안',
                'language': 'ko',
                'confidence': 0.94,
                'boundingBox': {
                  'left': 120,
                  'top': 130,
                  'right': 1050,
                  'bottom': 230,
                },
              },
            ],
          },
        ],
      };
    });
    const service = AndroidLocalOcrService(channel: channel);

    final result = await service.recognize(
      imagePath: '/enhanced_001.jpg',
      sourcePageId: 'raw_001.jpg',
    );

    expect(received?.method, 'recognizeText');
    expect(received?.arguments, {
      'imagePath': '/enhanced_001.jpg',
      'sourcePageId': 'raw_001.jpg',
    });
    expect(result.sourceWidth, 1200);
    expect(result.blocks.single.language, 'ko');
    expect(result.lines.single.confidence, closeTo(0.94, 0.001));
    expect(result.lines.single.boundingBox!.top, 130);
  });

  test('rejects malformed OCR results', () async {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{'fullText': 'invalid'},
    );
    const service = AndroidLocalOcrService(channel: channel);

    expect(
      service.recognize(imagePath: '/image.jpg', sourcePageId: 'raw.jpg'),
      throwsFormatException,
    );
  });
}
