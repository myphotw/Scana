import 'dart:io';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';

class MlKitEditedRaster {
  const MlKitEditedRaster({required this.page, required this.cropRect});

  final MlKitScannedPage page;
  final MlKitCropRect cropRect;
}

abstract interface class MlKitPageRasterEditor {
  Future<MlKitEditedRaster> render({
    required ScanPage page,
    required MlKitCropRect cropRect,
  });
}

/// Regenerates every edit from the preserved ML Kit source into lossless PNG.
class LosslessMlKitPageRasterEditor implements MlKitPageRasterEditor {
  const LosslessMlKitPageRasterEditor();

  @override
  Future<MlKitEditedRaster> render({
    required ScanPage page,
    required MlKitCropRect cropRect,
  }) async {
    final sourceFile = File(page.editableSourcePath);
    final decoded = image.decodeImage(await sourceFile.readAsBytes());
    if (decoded == null || decoded.width < 1 || decoded.height < 1) {
      throw const FormatException(
        'ML Kit editable source could not be decoded.',
      );
    }
    final safe = cropRect.clamped();
    final left = (safe.left * decoded.width).floor().clamp(
      0,
      decoded.width - 1,
    );
    final top = (safe.top * decoded.height).floor().clamp(
      0,
      decoded.height - 1,
    );
    final right = (safe.right * decoded.width).ceil().clamp(
      left + 1,
      decoded.width,
    );
    final bottom = (safe.bottom * decoded.height).ceil().clamp(
      top + 1,
      decoded.height,
    );
    final cropped = image.copyCrop(
      decoded,
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
    final sessionRoot = path.dirname(path.dirname(page.editableSourcePath));
    final outputDirectory = Directory(path.join(sessionRoot, 'mlkit_edited'));
    await outputDirectory.create(recursive: true);
    final stem = path
        .basenameWithoutExtension(page.rawImagePath)
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final outputFile = File(
      path.join(
        outputDirectory.path,
        'edited_${stem}_${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    final bytes = image.encodePng(cropped);
    await outputFile.writeAsBytes(bytes, flush: true);
    return MlKitEditedRaster(
      page: MlKitScannedPage(
        filePath: outputFile.path,
        byteCount: bytes.length,
        width: cropped.width,
        height: cropped.height,
      ),
      cropRect: MlKitCropRect(
        left: left / decoded.width,
        top: top / decoded.height,
        right: right / decoded.width,
        bottom: bottom / decoded.height,
      ),
    );
  }
}
