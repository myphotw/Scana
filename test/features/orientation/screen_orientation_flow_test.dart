import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/page_editor/presentation/page_editor_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/ocr_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  testWidgets('active spread Camera requests landscape', (tester) async {
    final manager = ScanSessionManager(storage: _MemoryStorage());
    addTearDown(manager.close);
    manager.restoreSession(_session(ScanCaptureMode.spread));
    final orientation = _RecordingOrientationController();

    await tester.pumpWidget(
      MaterialApp(
        home: CameraPreviewPage(
          sessionManager: manager,
          orientationController: orientation,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(orientation.calls.last, 'spreadCamera');
    expect(manager.captureMode, ScanCaptureMode.spread);
  });

  testWidgets('single Camera, Gallery, and Camera return stay portrait', (
    tester,
  ) async {
    final manager = ScanSessionManager(storage: _MemoryStorage());
    addTearDown(manager.close);
    final recovery = _session(ScanCaptureMode.single);
    final orientation = _RecordingOrientationController();

    await tester.pumpWidget(
      MaterialApp(
        home: CameraPreviewPage(
          sessionManager: manager,
          recoverySession: recovery,
          orientationController: orientation,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(orientation.calls.first, 'singleCamera');

    await tester.tap(find.text('이어하기'));
    await tester.pumpAndSettle();
    expect(find.byType(PageManagementPage), findsOneWidget);
    expect(orientation.calls.last, 'content');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(CameraPreviewPage), findsOneWidget);
    expect(orientation.calls.last, 'singleCamera');
    expect(manager.captureMode, ScanCaptureMode.single);
    expect(manager.pageCount, 1);
  });

  testWidgets(
    'spread Camera, Gallery, and Camera return rotate by screen role',
    (tester) async {
      final manager = ScanSessionManager(storage: _MemoryStorage());
      addTearDown(manager.close);
      final recovery = _session(ScanCaptureMode.spread);
      final orientation = _RecordingOrientationController();

      await tester.pumpWidget(
        MaterialApp(
          home: CameraPreviewPage(
            sessionManager: manager,
            recoverySession: recovery,
            orientationController: orientation,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('이어하기'));
      await tester.pumpAndSettle();
      expect(find.byType(PageManagementPage), findsOneWidget);
      expect(orientation.calls.last, 'content');
      expect(manager.captureMode, ScanCaptureMode.spread);
      expect(manager.pageCount, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreviewPage), findsOneWidget);
      expect(orientation.calls.last, 'spreadCamera');
      expect(manager.captureMode, ScanCaptureMode.spread);
      expect(manager.pageCount, 1);
    },
  );

  testWidgets('Gallery, Viewer, Page Editor, and PDF Review request portrait', (
    tester,
  ) async {
    final manager = ScanSessionManager(storage: _MemoryStorage());
    addTearDown(manager.close);
    manager.restoreSession(_session(ScanCaptureMode.spread));
    final orientation = _RecordingOrientationController();

    await tester.pumpWidget(
      MaterialApp(
        home: PageManagementPage(
          sessionManager: manager,
          orientationController: orientation,
        ),
      ),
    );
    await tester.pump();
    expect(orientation.calls.last, 'content');

    orientation.calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: ScanResultViewerPage(
          sessionManager: manager,
          orientationController: orientation,
        ),
      ),
    );
    await tester.pump();
    expect(orientation.calls, ['content']);

    orientation.calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: PageEditorPage(
          sessionManager: manager,
          orientationController: orientation,
        ),
      ),
    );
    await tester.pump();
    expect(orientation.calls, ['content']);

    orientation.calls.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: PdfPageReviewPage(
          sessionManager: manager,
          selectedPages: List.of(manager.currentSession!.pages),
          pdfExportWorkflow: PdfExportWorkflow(
            destinationStorage: const _NoopDestination(),
            deleteAfterSuccessfulExport: () async {},
          ),
          ocrService: const _FailingOcrService(),
          orientationController: orientation,
        ),
      ),
    );
    await tester.pump();
    expect(orientation.calls, ['content']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(orientation.calls, ['content', 'content']);
    expect(manager.captureMode, ScanCaptureMode.spread);
    expect(manager.pageCount, 1);
  });
}

ScanSession _session(ScanCaptureMode mode) =>
    ScanSession(
      id: 'orientation-${mode.name}',
      createdTime: DateTime.utc(2026, 8, 11),
      captureMode: mode,
    )..addPage(
      ScanPage(
        pageNo: 1,
        rawImagePath: '/raw_001.jpg',
        createdTime: DateTime.utc(2026, 8, 11),
      ),
    );

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

class _FailingOcrService implements OcrService {
  const _FailingOcrService();

  @override
  Future<OcrResult> recognize({
    required String imagePath,
    required String sourcePageId,
  }) {
    throw StateError('OCR unavailable in orientation test.');
  }
}

class _NoopDestination implements PdfDestinationStorage {
  const _NoopDestination();

  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async => null;

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async => null;

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) {
    throw UnimplementedError();
  }
}

class _MemoryStorage implements ScanSessionStorage {
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
