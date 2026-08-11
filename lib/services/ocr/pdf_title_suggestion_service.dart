import 'package:scana/models/ocr_result.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';

class PdfTitleSuggestion {
  const PdfTitleSuggestion({
    required this.title,
    required this.sourcePageNo,
    required this.ocrResult,
  });

  final String title;
  final int sourcePageNo;
  final OcrResult ocrResult;
}

class PdfTitleExtractor {
  const PdfTitleExtractor();

  static const int maximumLength = 50;

  String? extract(OcrResult result) {
    final candidates = <_TitleCandidate>[];
    var readingOrder = 0;
    for (final line in result.lines) {
      final normalized = _normalize(line.text);
      if (!_isMeaningful(normalized)) {
        readingOrder++;
        continue;
      }
      final box = line.boundingBox;
      final topRatio = box == null || result.sourceHeight <= 0
          ? (readingOrder / 20).clamp(0.0, 1.0)
          : (box.top / result.sourceHeight).clamp(0.0, 1.0);
      if (topRatio > 0.62 && candidates.isNotEmpty) {
        readingOrder++;
        continue;
      }
      final heightRatio = box == null || result.sourceHeight <= 0
          ? 0.0
          : (box.height / result.sourceHeight).clamp(0.0, 0.2);
      final phraseLengthScore =
          normalized.length >= 4 && normalized.length <= 36
          ? 1.4
          : normalized.length <= maximumLength
          ? 0.7
          : 0.1;
      final confidence = line.confidence ?? 0.5;
      final score =
          (1.0 - topRatio) * 4.0 +
          heightRatio * 45.0 +
          phraseLengthScore +
          confidence * 0.4 -
          (_looksLikeSentence(normalized) ? 0.8 : 0.0);
      candidates.add(
        _TitleCandidate(text: normalized, score: score, order: readingOrder),
      );
      readingOrder++;
    }
    if (candidates.isEmpty) return null;
    candidates.sort((first, second) {
      final scoreOrder = second.score.compareTo(first.score);
      return scoreOrder != 0 ? scoreOrder : first.order.compareTo(second.order);
    });
    return PdfFileNamePolicy.sanitizeBaseName(
      _truncate(candidates.first.text, maximumLength),
    );
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _isMeaningful(String value) {
    if (value.length < 2 || !RegExp(r'[가-힣A-Za-z]').hasMatch(value)) {
      return false;
    }
    if (RegExp(r'^\d+$').hasMatch(value)) return false;
    if (RegExp(
      r'^(?:page\s*)?\d+(?:\s*/\s*\d+)?$',
      caseSensitive: false,
    ).hasMatch(value)) {
      return false;
    }
    if (RegExp(
      r'^\d{4}[./년-]\s*\d{1,2}(?:[./월-]\s*\d{1,2}일?)?$',
    ).hasMatch(value)) {
      return false;
    }
    return true;
  }

  static bool _looksLikeSentence(String value) =>
      value.length > 40 || RegExp(r'[.!?。]$').hasMatch(value);

  static String _truncate(String value, int maximumLength) {
    if (value.length <= maximumLength) return value;
    final shortened = value.substring(0, maximumLength + 1);
    final lastSpace = shortened.lastIndexOf(' ');
    return (lastSpace >= maximumLength ~/ 2
            ? shortened.substring(0, lastSpace)
            : shortened.substring(0, maximumLength))
        .trimRight();
  }
}

class PdfTitleSuggestionService {
  const PdfTitleSuggestionService({
    required this.ocrService,
    this.extractor = const PdfTitleExtractor(),
  });

  final OcrService ocrService;
  final PdfTitleExtractor extractor;

  Future<PdfTitleSuggestion?> suggest(List<ScanPage> orderedPages) async {
    for (final page in orderedPages.take(2)) {
      try {
        final result = await ocrService.recognize(
          imagePath: page.displayImagePath,
          sourcePageId: page.rawImagePath,
        );
        final title = extractor.extract(result);
        if (title != null && title.isNotEmpty) {
          return PdfTitleSuggestion(
            title: title,
            sourcePageNo: page.pageNo,
            ocrResult: result,
          );
        }
      } on Object {
        // OCR is optional; the next page or date fallback remains available.
      }
    }
    return null;
  }
}

class _TitleCandidate {
  const _TitleCandidate({
    required this.text,
    required this.score,
    required this.order,
  });

  final String text;
  final double score;
  final int order;
}
