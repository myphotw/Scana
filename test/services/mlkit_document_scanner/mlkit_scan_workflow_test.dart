import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:flutter/material.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/ocr_result.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_scan_workflow.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_analyzer.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_splitter.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/ocr/pdf_title_suggestion_service.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  late Directory root;
  late AppPrivateSessionStorage storage;
  late ScanSessionManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scana_mlkit_test_');
    storage = AppPrivateSessionStorage(
      appPrivateDirectoryProvider: () async => root,
    );
    manager = ScanSessionManager(
      storage: storage,
      sessionIdGenerator: () => 'mlkit-session',
      clock: () => DateTime.utc(2026, 8, 21),
    );
  });

  tearDown(() async {
    manager.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'multiple JPEGs register as final ML Kit pages and survive recovery',
    () async {
      final scanner = _FakeScanner((sessionId, startPageNo) async {
        final directory = Directory(
          path.join(root.path, 'scan_sessions', sessionId, 'mlkit'),
        );
        await directory.create(recursive: true);
        final first = File(path.join(directory.path, 'page_001.jpg'));
        final second = File(path.join(directory.path, 'page_002.jpg'));
        await first.writeAsBytes([1, 2, 3, 4], flush: true);
        await second.writeAsBytes([5, 6, 7, 8, 9], flush: true);
        return MlKitScanResult.completed([
          MlKitScannedPage(
            filePath: first.path,
            byteCount: 4,
            width: 2480,
            height: 3508,
          ),
          MlKitScannedPage(
            filePath: second.path,
            byteCount: 5,
            width: 3508,
            height: 2480,
          ),
        ]);
      });
      final workflow = MlKitScanWorkflow(
        scanner: scanner,
        sessionManager: manager,
      );

      final result = await workflow.run();

      expect(result.status, MlKitScanWorkflowStatus.imported);
      expect(result.pages, hasLength(2));
      expect(
        result.pages.every(
          (page) => page.sourceType == ScanPageSourceType.mlKit,
        ),
        true,
      );
      expect(result.pages.every((page) => !page.usesCustomImagePipeline), true);
      expect(result.pages.first.correctedImagePath, isNull);
      expect(result.pages.first.enhancedImagePath, isNull);
      expect(
        result.pages.first.displayImagePath,
        result.pages.first.rawImagePath,
      );

      final recovered = await storage.findRecoverableSessions();
      expect(recovered.single.pages, hasLength(2));
      expect(recovered.single.pages.first.sourceType, ScanPageSourceType.mlKit);
      expect(recovered.single.pages.first.rawImagePath, contains('mlkit'));
    },
  );

  test('cancel removes a newly prepared empty session', () async {
    final workflow = MlKitScanWorkflow(
      scanner: _FakeScanner((_, _) async => const MlKitScanResult.cancelled()),
      sessionManager: manager,
    );

    final result = await workflow.run();

    expect(result.status, MlKitScanWorkflowStatus.cancelled);
    expect(manager.currentSession, isNull);
    expect(await storage.findRecoverableSessions(), isEmpty);
  });

  test('empty result removes a newly prepared empty session', () async {
    final workflow = MlKitScanWorkflow(
      scanner: _FakeScanner(
        (_, _) async => const MlKitScanResult.completed([]),
      ),
      sessionManager: manager,
    );

    final result = await workflow.run();

    expect(result.status, MlKitScanWorkflowStatus.empty);
    expect(manager.currentSession, isNull);
  });

  test('native error removes a newly prepared empty session', () async {
    final workflow = MlKitScanWorkflow(
      scanner: _FakeScanner((_, _) async {
        throw const MlKitDocumentScannerException('native_error', 'failed');
      }),
      sessionManager: manager,
    );

    await expectLater(
      workflow.run(),
      throwsA(isA<MlKitDocumentScannerException>()),
    );
    expect(manager.currentSession, isNull);
  });

  test('automatic single result keeps one ML Kit JPEG as one ScanPage', () async {
    final workflow = MlKitScanWorkflow(
      scanner: _scannerWithSourceCount(root, 1),
      sessionManager: manager,
    );

    final result = await workflow.run();

    expect(result.pages, hasLength(1));
    expect(result.pages.single.sourceType, ScanPageSourceType.mlKit);
    expect(
      result.pages.single.displayImagePath,
      result.pages.single.rawImagePath,
    );
  });

  test(
    'automatic spread result converts one JPEG into left then right pages',
    () async {
      final scanner = _scannerWithSourceCount(root, 1);
      final splitter = _FakeSpreadSplitter();
      final workflow = MlKitScanWorkflow(
        scanner: scanner,
        sessionManager: manager,
        spreadAnalyzer: const _FixedSpreadAnalyzer(),
        spreadSplitter: splitter,
      );

      final result = await workflow.run();

      expect(result.pages, hasLength(2));
      expect(result.pages.map((page) => path.basename(page.rawImagePath)), [
        'page_001_left.png',
        'page_002_right.png',
      ]);
      expect(
        result.pages.every(
          (page) => page.sourceType == ScanPageSourceType.mlKitSpread,
        ),
        true,
      );
      expect(splitter.calls, 1);
      final recovered = await storage.findRecoverableSessions();
      expect(recovered.single.pages.map((page) => page.sourceType), [
        ScanPageSourceType.mlKitSpread,
        ScanPageSourceType.mlKitSpread,
      ]);
    },
  );

  test('clear sheet-music analysis invokes the existing splitter', () async {
    final splitter = _FakeSpreadSplitter();
    final workflow = MlKitScanWorkflow(
      scanner: _sheetMusicScanner(root),
      sessionManager: manager,
      spreadSplitter: splitter,
    );

    final result = await workflow.run();

    expect(splitter.calls, 1);
    expect(result.pages, hasLength(2));
    expect(
      result.pages.every(
        (page) => page.sourceType == ScanPageSourceType.mlKitSpread,
      ),
      true,
    );
  });

  test('multi-page spread creates two ordered pages per ML Kit JPEG', () async {
    final splitter = _FakeSpreadSplitter();
    final workflow = MlKitScanWorkflow(
      scanner: _scannerWithSourceCount(root, 3),
      sessionManager: manager,
      spreadAnalyzer: const _FixedSpreadAnalyzer(),
      spreadSplitter: splitter,
    );

    final result = await workflow.run();

    expect(result.pages, hasLength(6));
    expect(result.pages.map((page) => page.pageNo), [1, 2, 3, 4, 5, 6]);
    expect(splitter.calls, 3);
  });

  test(
    'mixed single spread uncertain pages keep deterministic order',
    () async {
      final splitter = _FakeSpreadSplitter();
      final workflow = MlKitScanWorkflow(
        scanner: _scannerWithSourceCount(root, 3),
        sessionManager: manager,
        spreadAnalyzer: _SequenceAnalyzer([
          MlKitPageLayout.single,
          MlKitPageLayout.spread,
          MlKitPageLayout.uncertain,
        ]),
        spreadSplitter: splitter,
      );

      final result = await workflow.run();

      expect(result.pages.map((page) => page.sourceType), [
        ScanPageSourceType.mlKit,
        ScanPageSourceType.mlKitSpread,
        ScanPageSourceType.mlKitSpread,
        ScanPageSourceType.mlKit,
      ]);
      expect(result.pages.map((page) => page.pageNo), [1, 2, 3, 4]);
      expect(result.pages.last.mlKitLayout, MlKitPageLayout.uncertain);
      final spreadChildren = result.pages.where(
        (page) => page.sourceType == ScanPageSourceType.mlKitSpread,
      );
      expect(spreadChildren.map((page) => page.spreadSide), [
        MlKitSpreadSide.left,
        MlKitSpreadSide.right,
      ]);
      final original = File(spreadChildren.first.originalSourcePath!);
      expect(await original.exists(), true);
      expect(
        spreadChildren.every(
          (page) => page.originalSourcePath == original.path,
        ),
        true,
      );
    },
  );

  test('ML Kit page rejects every custom image pipeline entry', () async {
    final imported = await _importSinglePage(root, manager);
    expect(imported.sourceType, ScanPageSourceType.mlKit);

    expect(await manager.detectPageAt(0), false);
    expect(await manager.correctPageAt(0, CorrectionType.perspective), false);
    expect(await manager.enhancePageAt(0, EnhancementMode.scanColor), false);
    expect(manager.currentSession!.pages.single.correctedImagePath, isNull);
    expect(manager.currentSession!.pages.single.enhancedImagePath, isNull);
  });

  test('PDF and OCR consume the copied full-resolution ML Kit JPEG', () async {
    final page = await _importSinglePage(root, manager);
    final selection = PdfExportSelection.fromSessionPages(
      [page],
      {page.rawImagePath},
    );
    final ocr = _RecordingOcrService();

    await PdfTitleSuggestionService(ocrService: ocr).suggest([page]);

    expect(selection.pages.single.sourceImagePath, page.rawImagePath);
    expect(ocr.imagePath, page.rawImagePath);
  });

  testWidgets('Gallery shows imported ML Kit page without Quick Corner', (
    tester,
  ) async {
    final page = (await tester.runAsync(
      () => _importSinglePage(root, manager),
    ))!;

    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pump();

    expect(find.byKey(const Key('pdfSelectionGallery')), findsOneWidget);
    expect(
      find.byKey(ValueKey('pdf-gallery-page-${page.rawImagePath}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('gallery-quick-corner-${page.rawImagePath}')),
      findsNothing,
    );
    expect(find.text('ML Kit'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });
}

Future<ScanPage> _importSinglePage(
  Directory root,
  ScanSessionManager manager,
) async {
  final target = await manager.prepareMlKitScan();
  final directory = Directory(
    path.join(root.path, 'scan_sessions', target.sessionId, 'mlkit'),
  );
  await directory.create(recursive: true);
  final file = File(path.join(directory.path, 'page_001.jpg'));
  final jpegBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  await file.writeAsBytes(jpegBytes, flush: true);
  return (await manager.registerMlKitPages([
    MlKitScannedPage(
      filePath: file.path,
      byteCount: jpegBytes.length,
      width: 2480,
      height: 3508,
    ),
  ])).single;
}

class _FakeScanner implements MlKitDocumentScanner {
  const _FakeScanner(this.callback);

  final Future<MlKitScanResult> Function(String sessionId, int startPageNo)
  callback;

  @override
  Future<MlKitScanResult> scan({
    required String sessionId,
    required int startPageNo,
  }) => callback(sessionId, startPageNo);
}

MlKitDocumentScanner _scannerWithSourceCount(Directory root, int count) {
  return _FakeScanner((sessionId, startPageNo) async {
    final directory = Directory(
      path.join(root.path, 'scan_sessions', sessionId, 'mlkit'),
    );
    await directory.create(recursive: true);
    final pages = <MlKitScannedPage>[];
    for (var index = 0; index < count; index++) {
      final file = File(
        path.join(directory.path, 'page_${index + startPageNo}.jpg'),
      );
      final bytes = [index + 1, index + 2, index + 3];
      await file.writeAsBytes(bytes, flush: true);
      pages.add(
        MlKitScannedPage(
          filePath: file.path,
          byteCount: bytes.length,
          width: 200,
          height: 100,
        ),
      );
    }
    return MlKitScanResult.completed(pages);
  });
}

MlKitDocumentScanner _sheetMusicScanner(Directory root) {
  return _FakeScanner((sessionId, startPageNo) async {
    final directory = Directory(
      path.join(root.path, 'scan_sessions', sessionId, 'mlkit'),
    );
    await directory.create(recursive: true);
    const width = 360;
    const height = 210;
    const gutterX = 184;
    final source = image.Image(width: width, height: height);
    image.fill(source, color: image.ColorRgb8(247, 247, 244));
    for (final range in [(18, gutterX - 16), (gutterX + 16, width - 18)]) {
      for (var staffTop = 24; staffTop < height - 28; staffTop += 38) {
        for (var line = 0; line < 5; line++) {
          final y = staffTop + line * 4;
          for (var x = range.$1; x < range.$2; x++) {
            source.setPixelRgb(x, y, 58, 58, 58);
          }
        }
      }
    }
    for (var y = 0; y < height; y++) {
      source.setPixelRgb(gutterX, y, 226, 226, 226);
    }
    final bytes = image.encodeJpg(source, quality: 95);
    final file = File(path.join(directory.path, 'page_$startPageNo.jpg'));
    await file.writeAsBytes(bytes, flush: true);
    return MlKitScanResult.completed([
      MlKitScannedPage(
        filePath: file.path,
        byteCount: bytes.length,
        width: width,
        height: height,
      ),
    ]);
  });
}

class _FakeSpreadSplitter implements MlKitSpreadSplitter {
  int calls = 0;

  @override
  Future<MlKitSpreadSplitResult> split({
    required String sessionId,
    required int leftPageNo,
    required MlKitScannedPage source,
    MlKitSpineDetection? detection,
    String? outputStem,
  }) async {
    calls++;
    final directory = Directory(
      path.join(path.dirname(path.dirname(source.filePath)), 'mlkit_split'),
    );
    await directory.create(recursive: true);
    final left = File(
      path.join(
        directory.path,
        'page_${leftPageNo.toString().padLeft(3, '0')}_left.png',
      ),
    );
    final right = File(
      path.join(
        directory.path,
        'page_${(leftPageNo + 1).toString().padLeft(3, '0')}_right.png',
      ),
    );
    await left.writeAsBytes([1, 2], flush: true);
    await right.writeAsBytes([3, 4], flush: true);
    return MlKitSpreadSplitResult(
      left: MlKitScannedPage(
        filePath: left.path,
        byteCount: 2,
        width: 104,
        height: 100,
      ),
      right: MlKitScannedPage(
        filePath: right.path,
        byteCount: 2,
        width: 104,
        height: 100,
      ),
      detection: const MlKitSpineDetection(
        splitX: 100,
        confidence: 0.8,
        usedFallback: false,
      ),
      overlapPixels: 4,
      leftCropRect: const MlKitCropRect(
        left: 0,
        top: 0,
        right: 0.52,
        bottom: 1,
      ),
      rightCropRect: const MlKitCropRect(
        left: 0.48,
        top: 0,
        right: 1,
        bottom: 1,
      ),
    );
  }
}

class _FixedSpreadAnalyzer implements MlKitSpreadAnalyzer {
  const _FixedSpreadAnalyzer();

  @override
  Future<MlKitSpreadAnalysis> analyze(MlKitScannedPage source) async =>
      const MlKitSpreadAnalysis(
        layout: MlKitPageLayout.spread,
        splitX: 100,
        confidence: 0.8,
        fallbackUsed: false,
      );
}

class _SequenceAnalyzer implements MlKitSpreadAnalyzer {
  _SequenceAnalyzer(this.layouts);

  final List<MlKitPageLayout> layouts;
  int _index = 0;

  @override
  Future<MlKitSpreadAnalysis> analyze(MlKitScannedPage source) async {
    final layout = layouts[_index++];
    return MlKitSpreadAnalysis(
      layout: layout,
      splitX: source.width ~/ 2,
      confidence: layout == MlKitPageLayout.spread ? 0.9 : 0.3,
      fallbackUsed: layout != MlKitPageLayout.spread,
    );
  }
}

class _RecordingOcrService implements OcrService {
  String? imagePath;

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  }) async {
    this.imagePath = imagePath;
    return OcrResult(
      fullText: 'Scana Test',
      blocks: const [
        OcrBlock(
          text: 'Scana Test',
          lines: [OcrLine(text: 'Scana Test')],
        ),
      ],
      sourcePageId: sourcePageId,
      sourceWidth: 2480,
      sourceHeight: 3508,
    );
  }
}
