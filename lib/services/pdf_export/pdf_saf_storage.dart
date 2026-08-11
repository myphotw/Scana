import 'package:flutter/services.dart';

import 'package:scana/services/pdf_export/pdf_export_service.dart';

class AndroidSafPdfStorage implements PdfDestinationStorage {
  const AndroidSafPdfStorage({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.myphotw.scana/pdf_storage';
  final MethodChannel _channel;

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'getRecentDirectory',
    );
    return _directoryFromNative(value);
  }

  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'chooseDirectory',
    );
    return _directoryFromNative(value);
  }

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) async {
    final value = await _channel.invokeMapMethod<String, dynamic>('savePdf', {
      'temporaryPdfPath': temporaryPdfPath,
      'directoryUri': directory.uri,
      'fileName': fileName,
    });
    final uri = value?['uri'];
    final displayName = value?['displayName'];
    final byteCount = value?['byteCount'];
    if (uri is! String || displayName is! String || byteCount is! int) {
      throw const FormatException('SAF returned an invalid PDF result.');
    }
    return PdfSavedDocument(
      uri: uri,
      displayName: displayName,
      byteCount: byteCount,
    );
  }

  static PdfDirectoryLocation? _directoryFromNative(
    Map<String, dynamic>? value,
  ) {
    if (value == null) return null;
    final uri = value['uri'];
    final label = value['label'];
    if (uri is! String || label is! String || uri.isEmpty || label.isEmpty) {
      throw const FormatException('SAF returned an invalid directory.');
    }
    return PdfDirectoryLocation(uri: uri, label: label);
  }
}
