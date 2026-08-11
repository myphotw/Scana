import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/ocr_result.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';
import 'package:scana/services/pdf_export/pdf_document_opener.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  testWidgets(
    'filename confirmation keeps its controller alive through route reversal',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _FileNameHarness()));
      await tester.tap(find.byKey(const Key('openFileNameDialog')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('pdfFileNameField')), '보고서');
      final editable = tester.widget<EditableText>(find.byType(EditableText));

      await tester.tap(find.text('저장 위치 선택'));
      await tester.pump();

      expect(() => editable.controller.text, returnsNormally);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.text('보고서.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filename cancellation tears down without framework errors', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _FileNameHarness()));
    await tester.tap(find.byKey(const Key('openFileNameDialog')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(find.text('cancelled'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'review repeatedly opens filename and location dialogs without assertions',
    (tester) async {
      final manager = _managerWithOnePage();
      addTearDown(manager.close);
      final destination = _RecordingPdfDestination(
        recent: const PdfDirectoryLocation(
          uri: 'content://recent',
          label: 'Recent folder',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PdfPageReviewPage(
            sessionManager: manager,
            selectedPages: List<ScanPage>.of(manager.currentSession!.pages),
            pdfExportWorkflow: PdfExportWorkflow(
              destinationStorage: destination,
              deleteAfterSuccessfulExport: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.tap(find.byKey(const Key('createReviewedPdfButton')));
        await tester.pumpAndSettle();
        expect(find.byType(PdfFileNameDialog), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('pdfFileNameField')),
          '반복_$attempt',
        );

        await tester.tap(find.text('저장 위치 선택'));
        await tester.pumpAndSettle();
        expect(find.text('PDF 저장 위치'), findsOneWidget);
        expect(find.text('최근 위치: Recent folder'), findsOneWidget);

        await tester.tap(find.text('취소'));
        await tester.pumpAndSettle();
        expect(find.byType(PdfFileNameDialog), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('location choice can repeatedly open and cancel the SAF picker', (
    tester,
  ) async {
    final manager = _managerWithOnePage();
    addTearDown(manager.close);
    final destination = _RecordingPdfDestination(
      recent: const PdfDirectoryLocation(
        uri: 'content://recent',
        label: 'Recent folder',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PdfPageReviewPage(
          sessionManager: manager,
          selectedPages: List<ScanPage>.of(manager.currentSession!.pages),
          pdfExportWorkflow: PdfExportWorkflow(
            destinationStorage: destination,
            deleteAfterSuccessfulExport: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openLocationChoice(tester);
    await tester.tap(find.text('다른 위치 선택'));
    await tester.pumpAndSettle();
    expect(destination.chooseCount, 1);
    expect(tester.takeException(), isNull);

    await _openLocationChoice(tester);
    await tester.tap(find.text('다른 위치 선택'));
    await tester.pumpAndSettle();
    expect(destination.chooseCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR suggestion becomes the editable filename default', (
    tester,
  ) async {
    final manager = _managerWithOnePage();
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PdfPageReviewPage(
          sessionManager: manager,
          selectedPages: List<ScanPage>.of(manager.currentSession!.pages),
          pdfExportWorkflow: PdfExportWorkflow(
            destinationStorage: _RecordingPdfDestination(recent: null),
            deleteAfterSuccessfulExport: () async {},
          ),
          ocrService: const _SuccessfulOcrService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('제안 제목: 사내 품질관리 프로세스 개선안'), findsOneWidget);
    await tester.tap(find.byKey(const Key('createReviewedPdfButton')));
    await tester.pumpAndSettle();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '사내 품질관리 프로세스 개선안');

    await tester.enterText(
      find.byKey(const Key('pdfFileNameField')),
      '사용자 수정 제목',
    );
    expect(editable.controller.text, '사용자 수정 제목');
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR failure uses the stable date-based filename fallback', (
    tester,
  ) async {
    final manager = _managerWithOnePage();
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PdfPageReviewPage(
          sessionManager: manager,
          selectedPages: List<ScanPage>.of(manager.currentSession!.pages),
          pdfExportWorkflow: PdfExportWorkflow(
            destinationStorage: _RecordingPdfDestination(recent: null),
            deleteAfterSuccessfulExport: () async {},
          ),
          clock: () => DateTime(2026, 8, 11, 14, 5),
          ocrService: const _FailingOcrService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('createReviewedPdfButton')));
    await tester.pumpAndSettle();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, 'Scana_20260811_1405');
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'PDF completion retains result, handles missing viewer, and starts a new scan',
    (tester) async {
      final manager = _managerWithOnePage();
      addTearDown(manager.close);
      final destination = _SavingPdfDestination();
      final opener = _RecordingDocumentOpener(PdfOpenResult.noViewer);
      final orientation = _RecordingOrientationController();
      final workflow = _SuccessfulPdfExportWorkflow(
        destinationStorage: destination,
        deleteAfterSuccessfulExport: manager.deleteAfterSuccessfulExport,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: _PdfCompletionHarness(
            manager: manager,
            workflow: workflow,
            opener: opener,
            orientationController: orientation,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('openPdfReview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('createReviewedPdfButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장 위치 선택'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('최근 위치에 저장'));
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byKey(const Key('pdfCompletionOverlay')), findsOneWidget);
      expect(find.text('사내 품질관리 프로세스 개선안.pdf'), findsOneWidget);
      expect(find.text('1페이지'), findsOneWidget);
      expect(manager.currentSession, isNull);
      expect(orientation.calls.last, 'content');
      await tester.tap(find.byKey(const Key('openSavedPdfButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(opener.openedUris, ['content://saved/ocr-title.pdf']);
      expect(find.text('PDF를 열 수 있는 앱이 없습니다.'), findsOneWidget);
      expect(find.byKey(const Key('pdfCompletionOverlay')), findsOneWidget);

      await tester.tap(find.byKey(const Key('startNewScanButton')));
      await tester.pumpAndSettle();
      expect(find.text('Camera 0 Pages'), findsOneWidget);
      expect(find.byType(PdfPageReviewPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openLocationChoice(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('createReviewedPdfButton')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('저장 위치 선택'));
  await tester.pumpAndSettle();
  expect(find.text('PDF 저장 위치'), findsOneWidget);
}

class _FileNameHarness extends StatefulWidget {
  const _FileNameHarness();

  @override
  State<_FileNameHarness> createState() => _FileNameHarnessState();
}

class _FileNameHarnessState extends State<_FileNameHarness> {
  String? _result;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          FilledButton(
            key: const Key('openFileNameDialog'),
            onPressed: _open,
            child: const Text('open'),
          ),
          if (_result != null) Text(_result!),
        ],
      ),
    );
  }

  Future<void> _open() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const PdfFileNameDialog(initialFileName: 'Scana'),
    );
    if (!mounted) return;
    setState(() => _result = result ?? 'cancelled');
  }
}

class _PdfCompletionHarness extends StatefulWidget {
  const _PdfCompletionHarness({
    required this.manager,
    required this.workflow,
    required this.opener,
    required this.orientationController,
  });

  final ScanSessionManager manager;
  final PdfExportWorkflow workflow;
  final PdfDocumentOpener opener;
  final ScreenOrientationController orientationController;

  @override
  State<_PdfCompletionHarness> createState() => _PdfCompletionHarnessState();
}

class _PdfCompletionHarnessState extends State<_PdfCompletionHarness> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const Text('Camera 0 Pages'),
          FilledButton(
            key: const Key('openPdfReview'),
            onPressed: _openReview,
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReview() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PdfPageReviewPage(
          sessionManager: widget.manager,
          selectedPages: List<ScanPage>.of(
            widget.manager.currentSession!.pages,
          ),
          pdfExportWorkflow: widget.workflow,
          ocrService: const _SuccessfulOcrService(),
          pdfDocumentOpener: widget.opener,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }
}

ScanSessionManager _managerWithOnePage() {
  final manager = ScanSessionManager(storage: _TestSessionStorage());
  final session = ScanSession(
    id: 'filename-dialog-test',
    createdTime: DateTime.utc(2026, 8, 11),
  );
  session.addPage(
    ScanPage(
      pageNo: 1,
      rawImagePath: '/missing_raw.jpg',
      createdTime: DateTime.utc(2026, 8, 11),
    ),
  );
  manager.restoreSession(session);
  return manager;
}

class _RecordingPdfDestination implements PdfDestinationStorage {
  _RecordingPdfDestination({required this.recent});

  final PdfDirectoryLocation? recent;
  PdfDirectoryLocation? chosen;
  int chooseCount = 0;

  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async {
    chooseCount++;
    return chosen;
  }

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async => recent;

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) {
    throw UnimplementedError();
  }
}

class _SavingPdfDestination implements PdfDestinationStorage {
  PdfSavedDocument? savedDocument;

  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async => _location;

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async => _location;

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) async {
    savedDocument = PdfSavedDocument(
      uri: 'content://saved/ocr-title.pdf',
      displayName: fileName,
      byteCount: 2048,
    );
    return savedDocument!;
  }

  static const _location = PdfDirectoryLocation(
    uri: 'content://folder/recent',
    label: 'Recent folder',
  );
}

class _SuccessfulPdfExportWorkflow extends PdfExportWorkflow {
  _SuccessfulPdfExportWorkflow({
    required super.destinationStorage,
    required super.deleteAfterSuccessfulExport,
  });

  @override
  Future<PdfExportResult> export({
    required PdfExportSelection selection,
    required String requestedFileName,
    required PdfDirectoryLocation? directory,
    required void Function(PdfExportProgress progress) onProgress,
  }) async {
    onProgress(
      PdfExportProgress(
        completed: selection.pages.length,
        total: selection.pages.length,
      ),
    );
    await deleteAfterSuccessfulExport();
    return PdfExportResult.success(
      PdfSavedDocument(
        uri: 'content://saved/ocr-title.pdf',
        displayName: PdfFileNamePolicy.sanitize(requestedFileName),
        byteCount: 2048,
      ),
      pageCount: selection.pages.length,
    );
  }
}

class _SuccessfulOcrService implements OcrService {
  const _SuccessfulOcrService();

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  }) async => OcrResult(
    fullText: '사내 품질관리 프로세스 개선안',
    blocks: const [
      OcrBlock(
        text: '사내 품질관리 프로세스 개선안',
        lines: [
          OcrLine(
            text: '사내 품질관리 프로세스 개선안',
            confidence: 0.95,
            language: 'ko',
            boundingBox: OcrRect(left: 40, top: 80, right: 960, bottom: 160),
          ),
        ],
      ),
    ],
    sourcePageId: sourcePageId,
    sourceWidth: 1000,
    sourceHeight: 1500,
  );
}

class _FailingOcrService implements OcrService {
  const _FailingOcrService();

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  }) {
    throw StateError('OCR failed');
  }
}

class _RecordingDocumentOpener implements PdfDocumentOpener {
  _RecordingDocumentOpener(this.result);

  final PdfOpenResult result;
  final List<String> openedUris = [];

  @override
  Future<PdfOpenResult> open(String documentUri) async {
    openedUris.add(documentUri);
    return result;
  }
}

class _RecordingOrientationController implements ScreenOrientationController {
  final List<String> calls = [];

  @override
  Future<void> enterContentScreen() async => calls.add('content');

  @override
  Future<void> enterSingleCamera() async => calls.add('singleCamera');

  @override
  Future<void> enterSpreadCamera() async => calls.add('spreadCamera');

  @override
  Future<void> restoreSystemDefault() async => calls.add('systemDefault');
}

class _TestSessionStorage implements ScanSessionStorage {
  @override
  Future<void> createSession(String sessionId) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> deletePageFiles(ScanPage page) async {}

  @override
  Future<CorrectionOutputTarget> prepareCorrectionOutput({
    required String sessionId,
    required String rawImagePath,
    required CorrectionType type,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String> commitCorrectionOutput(CorrectionOutputTarget target) {
    throw UnimplementedError();
  }

  @override
  Future<void> discardCorrectionOutput(CorrectionOutputTarget target) async {}

  @override
  Future<List<ScanSession>> findRecoverableSessions() async => [];

  @override
  Future<void> saveSession(ScanSession session) async {}

  @override
  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  }) {
    throw UnimplementedError();
  }
}
