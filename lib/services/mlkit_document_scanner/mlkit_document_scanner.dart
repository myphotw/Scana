import 'package:flutter/services.dart';

import 'package:scana/services/diagnostics/debug_diagnostics.dart';

class MlKitScannedPage {
  const MlKitScannedPage({
    required this.filePath,
    required this.byteCount,
    required this.width,
    required this.height,
  });

  final String filePath;
  final int byteCount;
  final int width;
  final int height;

  factory MlKitScannedPage.fromMap(Map<Object?, Object?> value) {
    final filePath = value['filePath'];
    final byteCount = value['byteCount'];
    final width = value['width'];
    final height = value['height'];
    if (filePath is! String ||
        filePath.isEmpty ||
        byteCount is! int ||
        byteCount <= 0 ||
        width is! int ||
        width <= 0 ||
        height is! int ||
        height <= 0) {
      throw const FormatException('ML Kit returned invalid JPEG metadata.');
    }
    return MlKitScannedPage(
      filePath: filePath,
      byteCount: byteCount,
      width: width,
      height: height,
    );
  }
}

enum MlKitScanStatus { completed, cancelled }

class MlKitScanResult {
  const MlKitScanResult._({required this.status, required this.pages});

  const MlKitScanResult.completed(List<MlKitScannedPage> pages)
    : this._(status: MlKitScanStatus.completed, pages: pages);

  const MlKitScanResult.cancelled()
    : this._(status: MlKitScanStatus.cancelled, pages: const []);

  final MlKitScanStatus status;
  final List<MlKitScannedPage> pages;
}

class MlKitDocumentScannerException implements Exception {
  const MlKitDocumentScannerException(
    this.code,
    this.message, {
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'MlKitDocumentScannerException($code, $message)';
}

abstract interface class MlKitDocumentScanner {
  Future<MlKitScanResult> scan({
    required String sessionId,
    required int startPageNo,
  });
}

class AndroidMlKitDocumentScanner implements MlKitDocumentScanner {
  const AndroidMlKitDocumentScanner({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.myphotw.scana/mlkit_document_scanner';
  final MethodChannel _channel;

  @override
  Future<MlKitScanResult> scan({
    required String sessionId,
    required int startPageNo,
  }) async {
    try {
      DebugDiagnostics.instance.logStartup(
        'MLKIT_SCAN',
        'flutter_method_channel_startScan_requested '
            'session=$sessionId startPageNo=$startPageNo',
      );
      final value = await _channel.invokeMapMethod<Object?, Object?>(
        'startScan',
        {'sessionId': sessionId, 'startPageNo': startPageNo},
      );
      if (value == null) {
        throw const FormatException('ML Kit returned no scan result.');
      }
      if (value['status'] == 'cancelled') {
        return const MlKitScanResult.cancelled();
      }
      if (value['status'] != 'completed' || value['pages'] is! List) {
        throw const FormatException('ML Kit returned an invalid scan result.');
      }
      final pages = (value['pages']! as List<Object?>)
          .map((page) {
            if (page is! Map) {
              throw const FormatException(
                'ML Kit returned invalid page metadata.',
              );
            }
            return MlKitScannedPage.fromMap(page.cast<Object?, Object?>());
          })
          .toList(growable: false);
      return MlKitScanResult.completed(pages);
    } on PlatformException catch (error) {
      final rawDetails = error.details;
      throw MlKitDocumentScannerException(
        error.code,
        error.message ?? 'ML Kit document scanner failed.',
        details: rawDetails is Map
            ? Map<String, Object?>.from(rawDetails)
            : const <String, Object?>{},
      );
    }
  }
}
