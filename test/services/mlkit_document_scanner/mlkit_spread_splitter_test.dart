import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_splitter.dart';

void main() {
  test('spine detection finds a vertical luminance valley in central 30%', () {
    final source = _spreadImage(width: 240, height: 120, gutterX: 126);

    final detection = LosslessMlKitSpreadSplitter.detectSpine(source);

    expect(detection.usedFallback, false);
    expect(detection.splitX, inInclusiveRange(122, 130));
    expect(detection.confidence, greaterThanOrEqualTo(0.28));
  });

  test('uniform spread falls back to the exact center', () {
    final source = _spreadImage(width: 240, height: 120);

    final detection = LosslessMlKitSpreadSplitter.detectSpine(source);

    expect(detection.usedFallback, true);
    expect(detection.splitX, 120);
  });

  test('split keeps resolution, overlap, and lossless PNG outputs', () async {
    final root = await Directory.systemTemp.createTemp('scana_spread_split_');
    addTearDown(() => root.delete(recursive: true));
    final mlKitDirectory = Directory(
      path.join(root.path, 'scan_sessions', 'session', 'mlkit'),
    );
    await mlKitDirectory.create(recursive: true);
    final sourceImage = _spreadImage(width: 240, height: 120, gutterX: 126);
    final sourceBytes = image.encodeJpg(sourceImage, quality: 95);
    final sourceFile = File(path.join(mlKitDirectory.path, 'page_001.jpg'));
    await sourceFile.writeAsBytes(sourceBytes, flush: true);

    final result = await const LosslessMlKitSpreadSplitter().split(
      sessionId: 'session',
      leftPageNo: 1,
      source: MlKitScannedPage(
        filePath: sourceFile.path,
        byteCount: sourceBytes.length,
        width: 240,
        height: 120,
      ),
    );

    expect(result.overlapPixels, 4);
    expect(result.left.height, 120);
    expect(result.right.height, 120);
    expect(result.left.width + result.right.width, 248);
    expect(result.left.filePath, endsWith('page_001_left.png'));
    expect(result.right.filePath, endsWith('page_002_right.png'));
    expect(await _isPng(result.left.filePath), true);
    expect(await _isPng(result.right.filePath), true);
    expect(
      image.decodePng(await File(result.left.filePath).readAsBytes())!.height,
      120,
    );
    expect(
      image.decodePng(await File(result.right.filePath).readAsBytes())!.height,
      120,
    );
  });
}

image.Image _spreadImage({
  required int width,
  required int height,
  int? gutterX,
}) {
  final result = image.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var value = 244;
      if (gutterX != null && (x - gutterX).abs() <= 4) value = 45;
      if ((x == 55 || x == 82 || x == 174 || x == 196) && y % 9 < 5) {
        value = 80;
      }
      result.setPixelRgb(x, y, value, value, value);
    }
  }
  return result;
}

Future<bool> _isPng(String filePath) async {
  final bytes = await File(filePath).readAsBytes();
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return false;
  }
  return true;
}
