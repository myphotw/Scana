import 'dart:typed_data';

class PdfRasterQualityPolicy {
  const PdfRasterQualityPolicy._();

  static const bool preResize = false;

  /// Returns the exact full-resolution file bytes without a thumbnail or
  /// preview resampling stage.
  static Uint8List sourceBytes(Uint8List bytes) => bytes;
}
