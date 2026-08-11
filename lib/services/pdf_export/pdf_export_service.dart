import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:scana/models/scan_page.dart';

enum PdfPageSizingMode { fitImage }

class PdfPageSizingPolicy {
  const PdfPageSizingPolicy({this.mode = PdfPageSizingMode.fitImage});

  final PdfPageSizingMode mode;

  PdfPageFormat pageFormat({
    required int pixelWidth,
    required int pixelHeight,
    required int rotation,
  }) {
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      throw const FormatException('PDF image dimensions are invalid.');
    }
    final swapsAxes = rotation == 90 || rotation == 270;
    return _formatForAxes(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      swapsAxes: swapsAxes,
    );
  }

  PdfPageFormat pageFormatForOrientation({
    required int pixelWidth,
    required int pixelHeight,
    required PdfImageOrientation orientation,
  }) {
    return _formatForAxes(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      swapsAxes: _orientationSwapsAxes(orientation),
    );
  }

  PdfPageFormat _formatForAxes({
    required int pixelWidth,
    required int pixelHeight,
    required bool swapsAxes,
  }) {
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      throw const FormatException('PDF image dimensions are invalid.');
    }
    final width = swapsAxes ? pixelHeight.toDouble() : pixelWidth.toDouble();
    final height = swapsAxes ? pixelWidth.toDouble() : pixelHeight.toDouble();
    final scale = PdfPageFormat.a4.height / math.max(width, height);
    return PdfPageFormat(width * scale, height * scale);
  }
}

class PdfExportPage {
  const PdfExportPage({
    required this.sourceImagePath,
    required this.rotation,
    required this.pageNo,
  });

  final String sourceImagePath;
  final int rotation;
  final int pageNo;

  Map<String, Object> toMessage() => {
    'sourceImagePath': sourceImagePath,
    'rotation': rotation,
    'pageNo': pageNo,
  };
}

class PdfExportSelection {
  const PdfExportSelection(this.pages);

  final List<PdfExportPage> pages;

  factory PdfExportSelection.fromSessionPages(
    List<ScanPage> sessionPages,
    Set<String> selectedRawPaths,
  ) {
    return PdfExportSelection(
      sessionPages
          .where((page) => selectedRawPaths.contains(page.rawImagePath))
          .map(
            (page) => PdfExportPage(
              sourceImagePath: page.displayImagePath,
              rotation: page.rotation,
              pageNo: page.pageNo,
            ),
          )
          .toList(growable: false),
    );
  }

  /// Builds an export selection in the exact order chosen in the gallery.
  ///
  /// The session page order is intentionally left untouched so users can
  /// prepare a one-off PDF order without changing their scan session.
  factory PdfExportSelection.fromOrderedRawPaths(
    List<ScanPage> sessionPages,
    List<String> orderedRawPaths,
  ) {
    final pagesByRawPath = {
      for (final page in sessionPages) page.rawImagePath: page,
    };
    return PdfExportSelection(
      orderedRawPaths
          .map((rawPath) => pagesByRawPath[rawPath])
          .whereType<ScanPage>()
          .map(
            (page) => PdfExportPage(
              sourceImagePath: page.displayImagePath,
              rotation: page.rotation,
              pageNo: page.pageNo,
            ),
          )
          .toList(growable: false),
    );
  }
}

class PdfFileNamePolicy {
  const PdfFileNamePolicy._();

  static String defaultBaseName(DateTime time) =>
      'Scana_${time.year.toString().padLeft(4, '0')}'
      '${time.month.toString().padLeft(2, '0')}'
      '${time.day.toString().padLeft(2, '0')}_'
      '${time.hour.toString().padLeft(2, '0')}'
      '${time.minute.toString().padLeft(2, '0')}';

  static String sanitize(String input) {
    var value = input.trim();
    if (value.toLowerCase().endsWith('.pdf')) {
      value = value.substring(0, value.length - 4).trim();
    }
    value = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (value.isEmpty) {
      throw const FormatException('PDF file name is empty.');
    }
    if (value.length > 120) value = value.substring(0, 120).trimRight();
    return '$value.pdf';
  }
}

class PdfExportProgress {
  const PdfExportProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

abstract interface class PdfGenerator {
  Future<void> generate({
    required List<PdfExportPage> pages,
    required String outputPath,
    required void Function(PdfExportProgress progress) onProgress,
  });
}

class DartPdfGenerator implements PdfGenerator {
  const DartPdfGenerator();

  @override
  Future<void> generate({
    required List<PdfExportPage> pages,
    required String outputPath,
    required void Function(PdfExportProgress progress) onProgress,
  }) async {
    final receivePort = ReceivePort();
    final completer = Completer<void>();
    late final StreamSubscription<Object?> subscription;
    subscription = receivePort.listen((message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'progress':
          onProgress(
            PdfExportProgress(
              completed: message['completed'] as int,
              total: pages.length,
            ),
          );
        case 'success':
          if (!completer.isCompleted) completer.complete();
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(
              StateError(
                message['message'] as String? ?? 'PDF creation failed.',
              ),
            );
          }
      }
    });
    try {
      await Isolate.spawn<Map<String, Object>>(_generatePdfInIsolate, {
        'sendPort': receivePort.sendPort,
        'pages': pages.map((page) => page.toMessage()).toList(),
        'outputPath': outputPath,
      });
      await completer.future;
    } finally {
      await subscription.cancel();
      receivePort.close();
    }
  }
}

Future<void> _generatePdfInIsolate(Map<String, Object> request) async {
  final sendPort = request['sendPort']! as SendPort;
  try {
    final pageValues = request['pages']! as List<Object?>;
    final document = pw.Document(
      creator: 'Scana',
      producer: 'Scana offline PDF export',
    );
    const sizingPolicy = PdfPageSizingPolicy();
    for (var index = 0; index < pageValues.length; index++) {
      final value = pageValues[index]! as Map<Object?, Object?>;
      final imagePath = value['sourceImagePath']! as String;
      final rotation = value['rotation']! as int;
      final bytes = await File(imagePath).readAsBytes();
      final decodedImage = pw.MemoryImage(bytes);
      final orientation = _rotatePdfOrientation(
        decodedImage.orientation,
        rotation,
      );
      final image = pw.MemoryImage(bytes, orientation: orientation);
      final imageWidth = decodedImage.width;
      final imageHeight = decodedImage.height;
      if (imageWidth == null || imageHeight == null) {
        throw FormatException('Image decode failed: $imagePath');
      }
      final pageFormat = sizingPolicy.pageFormatForOrientation(
        pixelWidth: imageWidth,
        pixelHeight: imageHeight,
        orientation: orientation,
      );
      document.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.SizedBox.expand(
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
        ),
      );
      sendPort.send({'type': 'progress', 'completed': index + 1});
    }
    final bytes = await document.save(enableEventLoopBalancing: true);
    await File(
      request['outputPath']! as String,
    ).writeAsBytes(bytes, flush: true);
    sendPort.send({'type': 'success'});
  } on Object catch (error) {
    sendPort.send({'type': 'error', 'message': error.toString()});
  }
}

PdfImageOrientation _rotatePdfOrientation(
  PdfImageOrientation orientation,
  int rotation,
) {
  final quarterTurns = switch (rotation) {
    0 => 0,
    90 => 1,
    180 => 2,
    270 => 3,
    _ => throw ArgumentError.value(rotation, 'rotation'),
  };
  final groupStart = orientation.index < 4 ? 0 : 4;
  return PdfImageOrientation.values[groupStart +
      (orientation.index - groupStart + quarterTurns) % 4];
}

bool _orientationSwapsAxes(PdfImageOrientation orientation) =>
    orientation == PdfImageOrientation.topRight ||
    orientation == PdfImageOrientation.bottomLeft ||
    orientation == PdfImageOrientation.rightTop ||
    orientation == PdfImageOrientation.leftBottom;

class PdfDirectoryLocation {
  const PdfDirectoryLocation({required this.uri, required this.label});

  final String uri;
  final String label;
}

class PdfSavedDocument {
  const PdfSavedDocument({
    required this.uri,
    required this.displayName,
    required this.byteCount,
  });

  final String uri;
  final String displayName;
  final int byteCount;
}

abstract interface class PdfDestinationStorage {
  Future<PdfDirectoryLocation?> recentDirectory();

  Future<PdfDirectoryLocation?> chooseDirectory();

  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  });
}

enum PdfExportStatus { success, cancelled }

class PdfExportResult {
  const PdfExportResult._({required this.status, this.savedDocument});

  const PdfExportResult.cancelled() : this._(status: PdfExportStatus.cancelled);

  const PdfExportResult.success(PdfSavedDocument document)
    : this._(status: PdfExportStatus.success, savedDocument: document);

  final PdfExportStatus status;
  final PdfSavedDocument? savedDocument;
}

typedef TemporaryDirectoryProvider = Future<Directory> Function();

class PdfExportWorkflow {
  PdfExportWorkflow({
    required this.destinationStorage,
    required this.deleteAfterSuccessfulExport,
    this.generator = const DartPdfGenerator(),
    this.temporaryDirectoryProvider = getTemporaryDirectory,
  });

  final PdfDestinationStorage destinationStorage;
  final Future<void> Function() deleteAfterSuccessfulExport;
  final PdfGenerator generator;
  final TemporaryDirectoryProvider temporaryDirectoryProvider;

  Future<PdfExportResult> export({
    required PdfExportSelection selection,
    required String requestedFileName,
    required PdfDirectoryLocation? directory,
    required void Function(PdfExportProgress progress) onProgress,
  }) async {
    if (directory == null) return const PdfExportResult.cancelled();
    if (selection.pages.isEmpty) {
      throw StateError('At least one page must be selected.');
    }
    for (final page in selection.pages) {
      if (!await File(page.sourceImagePath).exists()) {
        throw FileSystemException(
          'PDF source image is missing.',
          page.sourceImagePath,
        );
      }
    }
    final fileName = PdfFileNamePolicy.sanitize(requestedFileName);
    final temporaryDirectory = await temporaryDirectoryProvider();
    await temporaryDirectory.create(recursive: true);
    final temporaryPdf = File(
      path.join(
        temporaryDirectory.path,
        '.scana_export_${DateTime.now().microsecondsSinceEpoch}.pdf',
      ),
    );
    try {
      await generator.generate(
        pages: selection.pages,
        outputPath: temporaryPdf.path,
        onProgress: onProgress,
      );
      await _validatePdf(temporaryPdf);
      final saved = await destinationStorage.save(
        temporaryPdfPath: temporaryPdf.path,
        directory: directory,
        fileName: fileName,
      );
      if (saved.byteCount <= 0) {
        throw const FileSystemException('Saved PDF is empty.');
      }
      await deleteAfterSuccessfulExport();
      return PdfExportResult.success(saved);
    } finally {
      if (await temporaryPdf.exists()) await temporaryPdf.delete();
    }
  }

  static Future<void> _validatePdf(File file) async {
    if (!await file.exists() || await file.length() < 8) {
      throw const FileSystemException('Temporary PDF was not created.');
    }
    final handle = await file.open();
    try {
      final header = await handle.read(5);
      if (String.fromCharCodes(header) != '%PDF-') {
        throw const FormatException('Generated file is not a PDF.');
      }
    } finally {
      await handle.close();
    }
  }
}
