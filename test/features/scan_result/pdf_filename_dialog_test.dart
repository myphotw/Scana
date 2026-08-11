import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
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
