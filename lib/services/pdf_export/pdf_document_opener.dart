import 'package:flutter/services.dart';

enum PdfOpenResult { opened, noViewer }

abstract interface class PdfDocumentOpener {
  Future<PdfOpenResult> open(String documentUri);
}

class AndroidPdfDocumentOpener implements PdfDocumentOpener {
  const AndroidPdfDocumentOpener({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.myphotw.scana/pdf_document';
  final MethodChannel _channel;

  @override
  Future<PdfOpenResult> open(String documentUri) async {
    final value = await _channel.invokeMapMethod<String, dynamic>('openPdf', {
      'documentUri': documentUri,
    });
    final opened = value?['opened'];
    if (opened is! bool) {
      throw const FormatException('PDF viewer returned an invalid result.');
    }
    return opened ? PdfOpenResult.opened : PdfOpenResult.noViewer;
  }
}
