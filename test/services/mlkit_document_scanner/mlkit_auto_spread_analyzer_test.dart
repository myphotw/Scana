import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_analyzer.dart';

void main() {
  test('clear single remains single', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _singleDocument(),
    );

    expect(analysis.layout, MlKitPageLayout.single);
    expect(analysis.isSpread, false);
  });

  test('clear spread is classified conservatively with detected splitX', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _spreadDocument(gutterX: 132),
    );

    expect(analysis.layout, MlKitPageLayout.spread);
    expect(analysis.splitX, inInclusiveRange(128, 136));
    expect(
      analysis.confidence,
      greaterThanOrEqualTo(ConservativeMlKitSpreadAnalyzer.spreadThreshold),
    );
    expect(analysis.fallbackUsed, false);
  });

  test('clear sheet-music spread is classified as spread', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _sheetMusicSpread(weakGutter: false),
    );

    expect(analysis.layout, MlKitPageLayout.spread, reason: _scores(analysis));
  });

  test('weak gutter plus strong dual sheet-music content is spread', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _sheetMusicSpread(weakGutter: true),
    );

    expect(analysis.layout, MlKitPageLayout.spread, reason: _scores(analysis));
    expect(
      analysis.confidence,
      greaterThanOrEqualTo(ConservativeMlKitSpreadAnalyzer.spreadThreshold),
    );
  });

  test('landscape single document is not spread', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _landscapeSingle(),
    );

    expect(analysis.isSpread, false, reason: _scores(analysis));
  });

  test('landscape photo is not spread', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _landscapePhoto(),
    );

    expect(analysis.isSpread, false, reason: _scores(analysis));
  });

  test('one-sided content is not spread', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _oneSidedDocument(),
    );

    expect(analysis.layout, MlKitPageLayout.single, reason: _scores(analysis));
    expect(analysis.rejectReason, 'one_sided_content');
  });

  test('ambiguous evidence remains unsplit', () {
    final analysis = ConservativeMlKitSpreadAnalyzer.analyzeImage(
      _ambiguousDocument(),
    );

    expect(analysis.isSpread, false, reason: _scores(analysis));
  });
}

String _scores(MlKitSpreadAnalysis analysis) {
  final signals = analysis.signals;
  return 'layout=${analysis.layout.name} confidence=${analysis.confidence} '
      'reason=${analysis.rejectReason} left=${signals.leftContentScore} '
      'right=${signals.rightContentScore} balance=${signals.contentBalanceScore} '
      'structure=${signals.pageStructureScore} gutter=${signals.gutterContinuityScore}';
}

image.Image _singleDocument() {
  final result = image.Image(width: 160, height: 240);
  image.fill(result, color: image.ColorRgb8(246, 246, 246));
  for (var y = 28; y < 215; y += 14) {
    for (var lineY = y; lineY < y + 3; lineY++) {
      for (var x = 18; x < 142; x++) {
        result.setPixelRgb(x, lineY, 75, 75, 75);
      }
    }
  }
  return result;
}

image.Image _spreadDocument({
  required int gutterX,
  bool partialGutter = false,
}) {
  final result = image.Image(width: 240, height: 120);
  image.fill(result, color: image.ColorRgb8(246, 246, 246));
  for (var y = 14; y < 108; y += 12) {
    for (var lineY = y; lineY < y + 3; lineY++) {
      for (var x = 14; x < gutterX - 14; x++) {
        result.setPixelRgb(x, lineY, 85, 85, 85);
      }
      for (var x = gutterX + 14; x < 226; x++) {
        result.setPixelRgb(x, lineY, 85, 85, 85);
      }
    }
  }
  for (var y = 0; y < result.height; y++) {
    if (partialGutter && y % 10 >= 4) continue;
    for (var x = gutterX - 3; x <= gutterX + 3; x++) {
      result.setPixelRgb(x, y, 45, 45, 45);
    }
  }
  return result;
}

image.Image _sheetMusicSpread({required bool weakGutter}) {
  const width = 360;
  const height = 210;
  const gutterX = 184;
  final result = image.Image(width: width, height: height);
  image.fill(result, color: image.ColorRgb8(247, 247, 244));
  for (final range in [(18, gutterX - 16), (gutterX + 16, width - 18)]) {
    for (var staffTop = 24; staffTop < height - 28; staffTop += 38) {
      for (var line = 0; line < 5; line++) {
        final y = staffTop + line * 4;
        for (var x = range.$1; x < range.$2; x++) {
          result.setPixelRgb(x, y, 58, 58, 58);
        }
      }
      for (var x = range.$1 + 12; x < range.$2 - 8; x += 24) {
        for (var y = staffTop + 3; y < staffTop + 12; y++) {
          result.setPixelRgb(x, y, 45, 45, 45);
        }
      }
    }
  }
  final gutterColor = weakGutter ? 226 : 72;
  for (var y = 0; y < height; y++) {
    result.setPixelRgb(gutterX, y, gutterColor, gutterColor, gutterColor);
  }
  return result;
}

image.Image _landscapeSingle() {
  final result = image.Image(width: 300, height: 190);
  image.fill(result, color: image.ColorRgb8(247, 247, 247));
  for (var y = 24; y < 170; y += 13) {
    for (var x = 20; x < 280; x++) {
      result.setPixelRgb(x, y, 72, 72, 72);
    }
  }
  return result;
}

image.Image _landscapePhoto() {
  final result = image.Image(width: 300, height: 180);
  for (var y = 0; y < result.height; y++) {
    for (var x = 0; x < result.width; x++) {
      final red = (35 + x * 170 ~/ result.width).clamp(0, 255);
      final green = (28 + y * 150 ~/ result.height).clamp(0, 255);
      final blue = (45 + (x + y) % 120).clamp(0, 255);
      result.setPixelRgb(x, y, red, green, blue);
    }
  }
  return result;
}

image.Image _oneSidedDocument() {
  final result = image.Image(width: 300, height: 180);
  image.fill(result, color: image.ColorRgb8(247, 247, 247));
  for (var y = 20; y < 160; y += 12) {
    for (var x = 18; x < 132; x++) {
      result.setPixelRgb(x, y, 68, 68, 68);
    }
  }
  for (var y = 0; y < result.height; y++) {
    result.setPixelRgb(150, y, 85, 85, 85);
  }
  return result;
}

image.Image _ambiguousDocument() {
  final result = image.Image(width: 300, height: 190);
  image.fill(result, color: image.ColorRgb8(247, 247, 247));
  for (final range in [(32, 132), (168, 268)]) {
    for (var y = 72; y < 112; y += 16) {
      for (var x = range.$1; x < range.$2; x++) {
        result.setPixelRgb(x, y, 120, 120, 120);
      }
    }
  }
  return result;
}
