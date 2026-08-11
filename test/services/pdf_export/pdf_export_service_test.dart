import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scana_pdf_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'selected pages follow session list order and prefer corrected images',
    () {
      final pages = [
        _page(3, '/raw_3.jpg', corrected: '/corrected_3.jpg'),
        _page(1, '/raw_1.jpg'),
        _page(4, '/raw_4.jpg', corrected: '/corrected_4.jpg'),
        _page(2, '/raw_2.jpg'),
      ];

      final selection = PdfExportSelection.fromSessionPages(pages, {
        '/raw_3.jpg',
        '/raw_4.jpg',
        '/raw_2.jpg',
      });

      expect(selection.pages.map((page) => page.pageNo), [3, 4, 2]);
      expect(selection.pages.map((page) => page.sourceImagePath), [
        '/corrected_3.jpg',
        '/corrected_4.jpg',
        '/raw_2.jpg',
      ]);
    },
  );

  test('selection preserves all supported rotation metadata', () {
    final pages = [
      _page(1, '/0.jpg', rotation: 0),
      _page(2, '/90.jpg', rotation: 90),
      _page(3, '/180.jpg', rotation: 180),
      _page(4, '/270.jpg', rotation: 270),
    ];

    final selection = PdfExportSelection.fromSessionPages(
      pages,
      pages.map((page) => page.rawImagePath).toSet(),
    );

    expect(selection.pages.map((page) => page.rotation), [0, 90, 180, 270]);
  });

  test('review final order is preserved as the PDF page order', () {
    final pages = [
      _page(1, '/raw_1.jpg'),
      _page(2, '/raw_2.jpg', corrected: '/corrected_2.jpg'),
      _page(3, '/raw_3.jpg'),
    ];
    final reordered = ['/raw_3.jpg', '/raw_1.jpg', '/raw_2.jpg'];
    final selection = PdfExportSelection.fromOrderedRawPaths(pages, reordered);

    expect(selection.pages.map((page) => page.pageNo), [3, 1, 2]);
    expect(selection.pages.last.sourceImagePath, '/corrected_2.jpg');
    expect(pages.map((page) => page.pageNo), [1, 2, 3]);
  });

  test('ordered selection ignores pages deleted after gallery entry', () {
    final selection = PdfExportSelection.fromOrderedRawPaths(
      [_page(1, '/raw_1.jpg')],
      ['/deleted.jpg', '/raw_1.jpg'],
    );

    expect(selection.pages.map((page) => page.pageNo), [1]);
  });

  test('fitImage sizing preserves aspect and swaps axes for quarter turns', () {
    const policy = PdfPageSizingPolicy();
    final upright = policy.pageFormat(
      pixelWidth: 1000,
      pixelHeight: 2000,
      rotation: 0,
    );
    final rotated = policy.pageFormat(
      pixelWidth: 1000,
      pixelHeight: 2000,
      rotation: 90,
    );

    expect(upright.height / upright.width, closeTo(2, 0.0001));
    expect(rotated.width / rotated.height, closeTo(2, 0.0001));
  });

  test('sanitizes names and appends the PDF extension exactly once', () {
    expect(PdfFileNamePolicy.sanitize('회의:자료'), '회의_자료.pdf');
    expect(PdfFileNamePolicy.sanitize(' report.PDF '), 'report.pdf');
    expect(() => PdfFileNamePolicy.sanitize('  ... '), throwsFormatException);
  });

  test('zero selected pages never generates or deletes a session', () async {
    final generator = _RecordingGenerator();
    var cleanupCalls = 0;
    final workflow = _workflow(
      root,
      generator: generator,
      cleanup: () async => cleanupCalls++,
    );

    await expectLater(
      workflow.export(
        selection: const PdfExportSelection([]),
        requestedFileName: 'empty',
        directory: _directory,
        onProgress: (_) {},
      ),
      throwsStateError,
    );

    expect(generator.pages, isEmpty);
    expect(cleanupCalls, 0);
  });

  test('missing page file protects the session', () async {
    var cleanupCalls = 0;
    final workflow = _workflow(root, cleanup: () async => cleanupCalls++);

    await expectLater(
      workflow.export(
        selection: const PdfExportSelection([
          PdfExportPage(
            sourceImagePath: '/missing.jpg',
            rotation: 0,
            pageNo: 1,
          ),
        ]),
        requestedFileName: 'missing',
        directory: _directory,
        onProgress: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(cleanupCalls, 0);
  });

  test('cancelled destination selection protects the session', () async {
    var cleanupCalls = 0;
    final workflow = _workflow(root, cleanup: () async => cleanupCalls++);

    final result = await workflow.export(
      selection: const PdfExportSelection([]),
      requestedFileName: 'cancelled',
      directory: null,
      onProgress: (_) {},
    );

    expect(result.status, PdfExportStatus.cancelled);
    expect(cleanupCalls, 0);
  });

  test('PDF generation failure protects source files and session', () async {
    final source = await _writeImage(root, 'source.png');
    var cleanupCalls = 0;
    final workflow = _workflow(
      root,
      generator: const _FailingGenerator(),
      cleanup: () async => cleanupCalls++,
    );

    await expectLater(
      workflow.export(
        selection: PdfExportSelection([
          PdfExportPage(sourceImagePath: source.path, rotation: 0, pageNo: 1),
        ]),
        requestedFileName: 'failed',
        directory: _directory,
        onProgress: (_) {},
      ),
      throwsStateError,
    );

    expect(await source.exists(), isTrue);
    expect(cleanupCalls, 0);
  });

  test('SAF write failure protects the session', () async {
    final source = await _writeImage(root, 'source.png');
    var cleanupCalls = 0;
    final workflow = PdfExportWorkflow(
      destinationStorage: const _FakeDestination(failSave: true),
      deleteAfterSuccessfulExport: () async => cleanupCalls++,
      generator: _RecordingGenerator(),
      temporaryDirectoryProvider: () async => root,
    );

    await expectLater(
      workflow.export(
        selection: PdfExportSelection([
          PdfExportPage(sourceImagePath: source.path, rotation: 0, pageNo: 1),
        ]),
        requestedFileName: 'write-failed',
        directory: _directory,
        onProgress: (_) {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(cleanupCalls, 0);
  });

  test(
    'successful save deletes the session only after destination success',
    () async {
      final source = await _writeImage(root, 'source.png');
      final events = <String>[];
      final destination = _FakeDestination(events: events);
      final workflow = PdfExportWorkflow(
        destinationStorage: destination,
        deleteAfterSuccessfulExport: () async => events.add('cleanup'),
        generator: _RecordingGenerator(events: events),
        temporaryDirectoryProvider: () async => root,
      );

      final result = await workflow.export(
        selection: PdfExportSelection([
          PdfExportPage(sourceImagePath: source.path, rotation: 270, pageNo: 1),
        ]),
        requestedFileName: '회의자료',
        directory: _directory,
        onProgress: (_) {},
      );

      expect(result.status, PdfExportStatus.success);
      expect(result.savedDocument!.displayName, '회의자료.pdf');
      expect(events, ['generate', 'save', 'cleanup']);
    },
  );

  test('successful export removes the real session from recovery', () async {
    final storage = AppPrivateSessionStorage(
      appPrivateDirectoryProvider: () async => root,
    );
    final manager = ScanSessionManager(
      storage: storage,
      sessionIdGenerator: () => 'pdf-session',
    );
    addTearDown(manager.close);
    final capture = await _writeImage(root, 'capture.png');
    final page = await manager.addRawCapture(capture.path);
    final workflow = PdfExportWorkflow(
      destinationStorage: const _FakeDestination(),
      deleteAfterSuccessfulExport: manager.deleteAfterSuccessfulExport,
      generator: _RecordingGenerator(),
      temporaryDirectoryProvider: () async => root,
    );

    await workflow.export(
      selection: PdfExportSelection([
        PdfExportPage(
          sourceImagePath: page.rawImagePath,
          rotation: page.rotation,
          pageNo: page.pageNo,
        ),
      ]),
      requestedFileName: 'complete',
      directory: _directory,
      onProgress: (_) {},
    );

    expect(manager.currentSession, isNull);
    expect(await storage.findRecoverableSessions(), isEmpty);
  });

  test('single and spread pages use the same export selection layer', () {
    final single = PdfExportSelection.fromSessionPages(
      [_page(1, '/single.jpg')],
      {'/single.jpg'},
    );
    final spread = PdfExportSelection.fromSessionPages(
      [_page(1, '/left.jpg'), _page(2, '/right.jpg')],
      {'/left.jpg', '/right.jpg'},
    );

    expect(ScanCaptureMode.single, isNot(ScanCaptureMode.spread));
    expect(single.pages, hasLength(1));
    expect(spread.pages.map((page) => page.pageNo), [1, 2]);
  });

  test(
    'Dart PDF generator creates a real PDF with all rotation values',
    () async {
      final image = await _writeImage(root, 'pixel.png');
      final output = path.join(root.path, 'actual.pdf');
      final progress = <int>[];
      await const DartPdfGenerator().generate(
        pages: [
          for (final rotation in [0, 90, 180, 270])
            PdfExportPage(
              sourceImagePath: image.path,
              rotation: rotation,
              pageNo: rotation,
            ),
        ],
        outputPath: output,
        onProgress: (value) => progress.add(value.completed),
      );

      final bytes = await File(output).readAsBytes();
      final content = latin1.decode(bytes, allowInvalid: true);
      expect(utf8.decode(bytes.take(5).toList()), '%PDF-');
      expect(RegExp(r'/Type\s*/Page(?!s)').allMatches(content), hasLength(4));
      expect(progress, [1, 2, 3, 4]);
    },
  );
}

const _directory = PdfDirectoryLocation(uri: 'content://tree', label: 'Scana');

ScanPage _page(int pageNo, String raw, {String? corrected, int rotation = 0}) =>
    ScanPage(
      pageNo: pageNo,
      rawImagePath: raw,
      createdTime: DateTime.utc(2026, 8, 11),
      correctedImagePath: corrected,
      rotation: rotation,
      correctionStatus: corrected == null
          ? CorrectionStatus.none
          : CorrectionStatus.completed,
    );

PdfExportWorkflow _workflow(
  Directory root, {
  PdfGenerator? generator,
  Future<void> Function()? cleanup,
}) => PdfExportWorkflow(
  destinationStorage: const _FakeDestination(),
  deleteAfterSuccessfulExport: cleanup ?? () async {},
  generator: generator ?? _RecordingGenerator(),
  temporaryDirectoryProvider: () async => root,
);

class _RecordingGenerator implements PdfGenerator {
  _RecordingGenerator({this.events});

  final List<String>? events;
  List<PdfExportPage> pages = [];

  @override
  Future<void> generate({
    required List<PdfExportPage> pages,
    required String outputPath,
    required void Function(PdfExportProgress progress) onProgress,
  }) async {
    this.pages = List.of(pages);
    events?.add('generate');
    await File(outputPath).writeAsString('%PDF-1.5\n%%EOF', flush: true);
    onProgress(PdfExportProgress(completed: pages.length, total: pages.length));
  }
}

class _FailingGenerator implements PdfGenerator {
  const _FailingGenerator();

  @override
  Future<void> generate({
    required List<PdfExportPage> pages,
    required String outputPath,
    required void Function(PdfExportProgress progress) onProgress,
  }) {
    throw StateError('generation failed');
  }
}

class _FakeDestination implements PdfDestinationStorage {
  const _FakeDestination({this.failSave = false, this.events});

  final bool failSave;
  final List<String>? events;

  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async => _directory;

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async => null;

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) async {
    events?.add('save');
    if (failSave) throw const FileSystemException('SAF write failed');
    return PdfSavedDocument(
      uri: 'content://saved/$fileName',
      displayName: fileName,
      byteCount: await File(temporaryPdfPath).length(),
    );
  }
}

Future<File> _writeImage(Directory root, String name) {
  return File(path.join(root.path, name)).writeAsBytes(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
    flush: true,
  );
}
