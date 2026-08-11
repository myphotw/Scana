import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/ocr_result.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/ocr/pdf_title_suggestion_service.dart';

void main() {
  const extractor = PdfTitleExtractor();

  test('prefers a large meaningful Korean line near the page top', () {
    final result = _result([
      _line('2026년 8월', top: 30, height: 30),
      _line('사내 품질관리 프로세스 개선안', top: 100, height: 72),
      _line('품질혁신팀에서 다음과 같이 개선안을 제안합니다.', top: 420, height: 25),
    ]);

    expect(extractor.extract(result), '사내 품질관리 프로세스 개선안');
  });

  test('excludes page numbers, numeric-only lines, dates and empty text', () {
    final result = _result([
      _line('1 / 20', top: 10, height: 30),
      _line('20260811', top: 40, height: 30),
      _line('2026-08-11', top: 70, height: 30),
      _line('   ', top: 100, height: 30),
      _line('월간 운영 보고서', top: 150, height: 45),
    ]);

    expect(extractor.extract(result), '월간 운영 보고서');
    expect(
      extractor.extract(_result([_line('1234', top: 20, height: 30)])),
      isNull,
    );
  });

  test('normalizes, sanitizes and truncates long title candidates', () {
    final longTitle = '분기별   품질관리 개선 계획 및 세부 실행 방안과 담당 조직별 추진 일정 종합 보고서 초안';
    final title = extractor.extract(
      _result([_line(longTitle, top: 80, height: 70)]),
    );

    expect(title, isNotNull);
    expect(title!.length, lessThanOrEqualTo(PdfTitleExtractor.maximumLength));
    expect(title, isNot(contains('  ')));
  });

  test(
    'uses enhanced, corrected, then raw OCR input and second-page fallback',
    () async {
      final service = _RecordingOcrService([
        StateError('first page failed'),
        _result([_line('두 번째 페이지 제목', top: 90, height: 65)]),
      ]);
      final suggestionService = PdfTitleSuggestionService(ocrService: service);
      final pages = [
        ScanPage(
          pageNo: 1,
          rawImagePath: '/raw_1.jpg',
          correctedImagePath: '/corrected_1.jpg',
          enhancedImagePath: '/enhanced_1.jpg',
          enhancementStatus: EnhancementStatus.completed,
          createdTime: DateTime.utc(2026, 8, 11),
        ),
        ScanPage(
          pageNo: 2,
          rawImagePath: '/raw_2.jpg',
          correctedImagePath: '/corrected_2.jpg',
          createdTime: DateTime.utc(2026, 8, 11),
        ),
      ];

      final suggestion = await suggestionService.suggest(pages);

      expect(service.imagePaths, ['/enhanced_1.jpg', '/corrected_2.jpg']);
      expect(suggestion?.title, '두 번째 페이지 제목');
      expect(suggestion?.sourcePageNo, 2);
    },
  );

  test('OCR failure and empty OCR return no suggestion', () async {
    final service = _RecordingOcrService([
      StateError('failed'),
      _result([_line('', top: 10, height: 10)]),
    ]);
    final pages = [_page(1, '/raw_1.jpg'), _page(2, '/raw_2.jpg')];

    expect(
      await PdfTitleSuggestionService(ocrService: service).suggest(pages),
      isNull,
    );
  });
}

OcrResult _result(List<OcrLine> lines) => OcrResult(
  fullText: lines.map((line) => line.text).join('\n'),
  blocks: [OcrBlock(text: 'block', lines: lines)],
  sourcePageId: 'source',
  sourceWidth: 1000,
  sourceHeight: 1000,
);

OcrLine _line(String text, {required double top, required double height}) =>
    OcrLine(
      text: text,
      boundingBox: OcrRect(
        left: 50,
        top: top,
        right: 950,
        bottom: top + height,
      ),
      confidence: 0.9,
      language: 'ko',
    );

ScanPage _page(int pageNo, String rawPath) => ScanPage(
  pageNo: pageNo,
  rawImagePath: rawPath,
  createdTime: DateTime.utc(2026, 8, 11),
);

class _RecordingOcrService implements OcrService {
  _RecordingOcrService(this.results);

  final List<Object> results;
  final List<String> imagePaths = [];
  var _index = 0;

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  }) async {
    imagePaths.add(imagePath);
    final value = results[_index++];
    if (value is OcrResult) return value;
    throw value;
  }
}
