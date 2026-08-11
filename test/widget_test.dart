import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/app.dart';
import 'package:scana/features/page_editor/presentation/page_editor_page.dart';
import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  testWidgets('creates the Scana camera entry screen', (tester) async {
    await tester.pumpWidget(const ScanaApp());

    expect(find.byType(ScanaApp), findsOneWidget);
    expect(find.text('카메라를 준비하는 중입니다.'), findsOneWidget);
  });

  testWidgets('renders the two-page manual center guide', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SpreadCaptureGuide())),
    );

    expect(find.byKey(const Key('spreadCenterGuide')), findsOneWidget);
    expect(find.text('책 가운데를 기준선에 맞춰주세요'), findsOneWidget);
  });

  test('single mode keeps the shutter at bottom center', () {
    expect(
      CameraCaptureButtonLayout.alignmentFor(ScanCaptureMode.single),
      Alignment.bottomCenter,
    );
    expect(
      CameraCaptureButtonLayout.paddingFor(ScanCaptureMode.single),
      const EdgeInsets.only(bottom: 24),
    );
  });

  test('spread landscape mode places the shutter at safe right center', () {
    expect(
      CameraCaptureButtonLayout.alignmentFor(ScanCaptureMode.spread),
      Alignment.centerRight,
    );
    expect(
      CameraCaptureButtonLayout.paddingFor(ScanCaptureMode.spread),
      const EdgeInsets.only(right: 24),
    );
    expect(
      CameraCaptureButtonLayout.alignmentFor(ScanCaptureMode.spread),
      isNot(Alignment.bottomRight),
    );
  });

  testWidgets('last viewer deletion returns to the camera route', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('Camera Preview'))),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) => ScanResultViewerPage(sessionManager: manager),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(find.text('Camera Preview'), findsOneWidget);
    expect(manager.currentSession, isNotNull);
    expect(manager.pageCount, 0);
  });

  testWidgets('viewer keeps the next page valid after deleting first page', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(2);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: ScanResultViewerPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(find.text('1 / 1'), findsOneWidget);
    expect(manager.currentSession!.pages.single.rawImagePath, '/raw_2.jpg');
    expect(tester.takeException(), isNull);
  });

  testWidgets('viewer keeps the previous page valid after deleting last page', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(2);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ScanResultViewerPage(
          sessionManager: manager,
          initialPageIndex: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(find.text('1 / 1'), findsOneWidget);
    expect(manager.currentSession!.pages.single.rawImagePath, '/raw_1.jpg');
    expect(tester.takeException(), isNull);
  });

  testWidgets('zero-page recovery stays on camera preview', (tester) async {
    final manager = ScanSessionManager(storage: _TestSessionStorage());
    addTearDown(manager.close);
    final emptySession = ScanSession(
      id: 'empty-recovered-session',
      createdTime: DateTime.utc(2026, 8, 10),
    );

    await tester.pumpWidget(
      ScanaApp(sessionManager: manager, recoverySession: emptySession),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이어하기'));
    await tester.pumpAndSettle();

    expect(manager.currentSession?.id, 'empty-recovered-session');
    expect(find.byKey(const ValueKey('scan-result-page-view')), findsNothing);
    expect(find.text('카메라를 준비하는 중입니다.'), findsOneWidget);
  });

  testWidgets('last page deletion from management returns to camera route', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('Camera Preview'))),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) => PageManagementPage(sessionManager: manager),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('페이지 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(find.text('Camera Preview'), findsOneWidget);
    expect(manager.currentSession, isNotNull);
    expect(manager.pageCount, 0);
  });

  testWidgets('shows and resumes a recovered session', (tester) async {
    final session = ScanSession(
      id: 'recovered-session',
      createdTime: DateTime.utc(2026, 8, 10, 1, 2),
    );
    session.addPage(
      ScanPage(
        pageNo: 1,
        rawImagePath: '/scan_sessions/raw_001.jpg',
        createdTime: DateTime.utc(2026, 8, 10, 1, 2),
      ),
    );
    final manager = ScanSessionManager(storage: _TestSessionStorage());

    await tester.pumpWidget(
      ScanaApp(sessionManager: manager, recoverySession: session),
    );
    await tester.pumpAndSettle();

    expect(find.text('이전 스캔 작업이 있습니다.'), findsOneWidget);
    expect(find.textContaining('페이지 수: 1'), findsOneWidget);
    expect(find.text('이어하기'), findsOneWidget);

    await tester.tap(find.text('이어하기'));
    await tester.pumpAndSettle();

    expect(manager.currentSession?.id, 'recovered-session');
  });

  testWidgets('corner preview does not overlap the action toolbar', (
    tester,
  ) async {
    final manager = ScanSessionManager(storage: _TestSessionStorage());
    addTearDown(manager.close);
    final session = ScanSession(
      id: 'corner-session',
      createdTime: DateTime.utc(2026, 8, 10),
    );
    session.addPage(
      ScanPage(
        pageNo: 1,
        rawImagePath: '/missing/raw_001.jpg',
        createdTime: DateTime.utc(2026, 8, 10),
        documentSourceWidth: 1000,
        documentSourceHeight: 1500,
        documentCorners: const DocumentCorners(
          topLeft: DocumentPoint(0, 0),
          topRight: DocumentPoint(1000, 0),
          bottomRight: DocumentPoint(1000, 1500),
          bottomLeft: DocumentPoint(0, 1500),
        ),
      ),
    );
    manager.restoreSession(session);

    await tester.pumpWidget(
      MaterialApp(home: PageEditorPage(sessionManager: manager)),
    );
    await tester.tap(find.text('페이지 1'));
    await tester.pumpAndSettle();

    final preview = tester.getRect(
      find.byKey(const ValueKey('page-editor-image-preview')),
    );
    final toolbar = tester.getRect(
      find.byKey(const ValueKey('page-editor-action-toolbar')),
    );
    final bottomRight = tester.getRect(
      find.byKey(const ValueKey('document-corner-2')),
    );

    expect(preview.bottom, lessThanOrEqualTo(toolbar.top));
    expect(bottomRight.right, lessThanOrEqualTo(preview.right));
    expect(bottomRight.bottom, lessThanOrEqualTo(preview.bottom));
    expect(find.text('모서리 저장'), findsOneWidget);
  });

  testWidgets(
    'scan result viewer defaults to corrected image and supports pages',
    (tester) async {
      final manager = ScanSessionManager(storage: _TestSessionStorage());
      addTearDown(manager.close);
      final session = ScanSession(
        id: 'viewer-session',
        createdTime: DateTime.utc(2026, 8, 10),
      );
      for (var index = 1; index <= 2; index++) {
        session.addPage(
          ScanPage(
            pageNo: index,
            rawImagePath: '/raw_$index.jpg',
            correctedImagePath: '/corrected_$index.jpg',
            createdTime: DateTime.utc(2026, 8, 10),
          ),
        );
      }
      manager.restoreSession(session);

      await tester.pumpWidget(
        MaterialApp(home: ScanResultViewerPage(sessionManager: manager)),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('scan-result-page-view')),
        findsOneWidget,
      );
      expect(find.text('재촬영'), findsOneWidget);
      expect(find.text('편집'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('viewer-rotate-button')));
      await tester.pumpAndSettle();
      expect(manager.currentSession!.pages.first.rotation, 90);
      final viewerRotation = tester.widget<Transform>(
        find.byKey(const ValueKey('viewer-page-rotation-1')),
      );
      expect(viewerRotation.transform.storage[0], closeTo(0, 0.0001));
      expect(viewerRotation.transform.storage[1], closeTo(1, 0.0001));

      await tester.pumpWidget(
        MaterialApp(home: PageManagementPage(sessionManager: manager)),
      );
      await tester.pumpAndSettle();
      final thumbnailRotation = tester.widget<Transform>(
        find.byKey(const ValueKey('managed-thumbnail-rotation-1')),
      );
      expect(
        thumbnailRotation.transform.storage[0],
        closeTo(math.cos(math.pi / 2), 0.0001),
      );
      expect(
        thumbnailRotation.transform.storage[1],
        closeTo(math.sin(math.pi / 2), 0.0001),
      );
    },
  );
  testWidgets(
    'detailed editing hides raw corners until corner editing is chosen',
    (tester) async {
      final manager = ScanSessionManager(storage: _TestSessionStorage());
      addTearDown(manager.close);
      final session = ScanSession(
        id: 'detail-session',
        createdTime: DateTime.utc(2026, 8, 10),
      );
      session.addPage(
        ScanPage(
          pageNo: 1,
          rawImagePath: '/raw.jpg',
          correctedImagePath: '/corrected.jpg',
          createdTime: DateTime.utc(2026, 8, 10),
        ),
      );
      manager.restoreSession(session);

      await tester.pumpWidget(
        MaterialApp(
          home: PageEditorPage(
            sessionManager: manager,
            initialPageIndex: 0,
            showPageList: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('모서리 수정'), findsOneWidget);
      await tester.tap(find.text('모서리 수정'));
      await tester.pumpAndSettle();
      expect(find.text('스캔본으로 돌아가기'), findsOneWidget);
    },
  );
}

ScanSessionManager _viewerManagerWithPages(int count) {
  final manager = ScanSessionManager(storage: _TestSessionStorage());
  final session = ScanSession(
    id: 'viewer-$count',
    createdTime: DateTime.utc(2026, 8, 10),
  );
  for (var index = 1; index <= count; index++) {
    session.addPage(
      ScanPage(
        pageNo: index,
        rawImagePath: '/raw_$index.jpg',
        createdTime: DateTime.utc(2026, 8, 10),
      ),
    );
  }
  manager.restoreSession(session);
  return manager;
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
