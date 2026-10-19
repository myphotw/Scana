import 'package:flutter/services.dart';

class ExistingPdfDocument {
  const ExistingPdfDocument({
    required this.sessionId,
    required this.sourcePath,
    required this.displayName,
    required this.pageCount,
    required this.byteCount,
  });

  final String sessionId;
  final String sourcePath;
  final String displayName;
  final int pageCount;
  final int byteCount;

  static ExistingPdfDocument fromMap(Map<Object?, Object?> value) {
    final sessionId = value['sessionId'];
    final sourcePath = value['sourcePath'];
    final displayName = value['displayName'];
    final pageCount = value['pageCount'];
    final byteCount = value['byteCount'];
    if (sessionId is! String ||
        sourcePath is! String ||
        displayName is! String ||
        pageCount is! int ||
        byteCount is! int ||
        pageCount <= 0) {
      throw const FormatException('PDF 편집 세션 정보가 잘못되었습니다.');
    }
    return ExistingPdfDocument(
      sessionId: sessionId,
      sourcePath: sourcePath,
      displayName: displayName,
      pageCount: pageCount,
      byteCount: byteCount,
    );
  }
}

class ExistingPdfExport {
  const ExistingPdfExport({
    required this.outputPath,
    required this.pageCount,
    required this.byteCount,
  });

  final String outputPath;
  final int pageCount;
  final int byteCount;
}

abstract interface class ExistingPdfEditorPlatform {
  Future<ExistingPdfDocument?> pickPdf();

  Future<String> renderThumbnail({
    required String sessionId,
    required int pageIndex,
    int maximumWidth = 512,
    int maximumHeight = 720,
  });

  Future<ExistingPdfExport> exportPdf({
    required String sessionId,
    required List<int> pageOrder,
  });

  Future<void> discardOutput({
    required String sessionId,
    required String outputPath,
  });

  Future<void> cleanup(String sessionId);
}

class AndroidExistingPdfEditorPlatform implements ExistingPdfEditorPlatform {
  const AndroidExistingPdfEditorPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.myphotw.scana/existing_pdf_editor';
  final MethodChannel _channel;

  @override
  Future<ExistingPdfDocument?> pickPdf() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>('pickPdf');
    return value == null ? null : ExistingPdfDocument.fromMap(value);
  }

  @override
  Future<String> renderThumbnail({
    required String sessionId,
    required int pageIndex,
    int maximumWidth = 512,
    int maximumHeight = 720,
  }) async {
    final value = await _channel
        .invokeMapMethod<Object?, Object?>('renderThumbnail', {
          'sessionId': sessionId,
          'pageIndex': pageIndex,
          'maximumWidth': maximumWidth,
          'maximumHeight': maximumHeight,
        });
    final path = value?['path'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('PDF 썸네일 경로가 잘못되었습니다.');
    }
    return path;
  }

  @override
  Future<ExistingPdfExport> exportPdf({
    required String sessionId,
    required List<int> pageOrder,
  }) async {
    _validatePageOrder(pageOrder);
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'exportPdf',
      {'sessionId': sessionId, 'pageOrder': pageOrder},
    );
    final outputPath = value?['outputPath'];
    final pageCount = value?['pageCount'];
    final byteCount = value?['byteCount'];
    if (outputPath is! String ||
        outputPath.isEmpty ||
        pageCount is! int ||
        byteCount is! int ||
        pageCount != pageOrder.length ||
        byteCount <= 0) {
      throw const FormatException('편집된 PDF 정보가 잘못되었습니다.');
    }
    return ExistingPdfExport(
      outputPath: outputPath,
      pageCount: pageCount,
      byteCount: byteCount,
    );
  }

  @override
  Future<void> cleanup(String sessionId) =>
      _channel.invokeMethod<void>('cleanup', {'sessionId': sessionId});

  @override
  Future<void> discardOutput({
    required String sessionId,
    required String outputPath,
  }) => _channel.invokeMethod<void>('discardOutput', {
    'sessionId': sessionId,
    'outputPath': outputPath,
  });

  static void _validatePageOrder(List<int> pageOrder) {
    if (pageOrder.isEmpty) {
      throw StateError('모든 페이지를 삭제할 수 없습니다.');
    }
    if (pageOrder.any((index) => index < 0) ||
        pageOrder.toSet().length != pageOrder.length) {
      throw const FormatException('PDF 페이지 순서가 잘못되었습니다.');
    }
  }
}
