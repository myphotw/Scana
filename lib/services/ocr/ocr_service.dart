import 'package:flutter/services.dart';

import 'package:scana/models/ocr_result.dart';

abstract interface class OcrService {
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  });
}

class AndroidLocalOcrService implements OcrService {
  const AndroidLocalOcrService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.myphotw.scana/local_ocr';
  final MethodChannel _channel;

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'recognizeText',
      {'imagePath': imagePath, 'sourcePageId': sourcePageId},
    );
    if (value == null) {
      throw const FormatException('OCR returned no result.');
    }
    final fullText = value['fullText'];
    final nativeSourcePageId = value['sourcePageId'];
    final sourceWidth = value['sourceWidth'];
    final sourceHeight = value['sourceHeight'];
    final nativeBlocks = value['blocks'];
    if (fullText is! String ||
        nativeSourcePageId is! String ||
        sourceWidth is! int ||
        sourceHeight is! int ||
        sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        nativeBlocks is! List) {
      throw const FormatException('OCR returned invalid result metadata.');
    }
    return OcrResult(
      fullText: fullText,
      blocks: nativeBlocks
          .map<OcrBlock>(_blockFromNative)
          .toList(growable: false),
      sourcePageId: nativeSourcePageId,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
  }

  static OcrBlock _blockFromNative(Object? value) {
    if (value is! Map) {
      throw const FormatException('OCR returned an invalid text block.');
    }
    final text = value['text'];
    final nativeLines = value['lines'];
    if (text is! String || nativeLines is! List) {
      throw const FormatException('OCR returned invalid block metadata.');
    }
    return OcrBlock(
      text: text,
      lines: nativeLines.map<OcrLine>(_lineFromNative).toList(growable: false),
      boundingBox: _rectFromNative(value['boundingBox']),
      language: _optionalString(value['language']),
    );
  }

  static OcrLine _lineFromNative(Object? value) {
    if (value is! Map || value['text'] is! String) {
      throw const FormatException('OCR returned an invalid text line.');
    }
    final confidenceValue = value['confidence'];
    final confidence = confidenceValue is num
        ? confidenceValue.toDouble()
        : null;
    return OcrLine(
      text: value['text'] as String,
      boundingBox: _rectFromNative(value['boundingBox']),
      confidence: confidence,
      language: _optionalString(value['language']),
    );
  }

  static OcrRect? _rectFromNative(Object? value) {
    if (value == null) return null;
    if (value is! Map) {
      throw const FormatException('OCR returned an invalid bounding box.');
    }
    final left = value['left'];
    final top = value['top'];
    final right = value['right'];
    final bottom = value['bottom'];
    if (left is! num || top is! num || right is! num || bottom is! num) {
      throw const FormatException('OCR returned invalid rectangle values.');
    }
    return OcrRect(
      left: left.toDouble(),
      top: top.toDouble(),
      right: right.toDouble(),
      bottom: bottom.toDouble(),
    );
  }

  static String? _optionalString(Object? value) =>
      value is String && value.isNotEmpty && value != 'und' ? value : null;
}
