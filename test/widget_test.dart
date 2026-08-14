import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/app.dart';
import 'package:scana/features/page_editor/presentation/page_editor_page.dart';
import 'package:scana/features/page_editor/presentation/quick_corner_edit_page.dart';
import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/services/storage/scan_session_storage.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

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

  testWidgets('fixed single and spread guides remain independent from AI', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              FixedCaptureGuide(mode: ScanCaptureMode.single),
              FixedCaptureGuide(mode: ScanCaptureMode.spread),
            ],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('fixedCaptureGuide-single')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('fixedCaptureGuide-spread')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fixedSpreadCenterGuide')), findsOneWidget);
    expect(find.byKey(const Key('exportDebugLogButton')), findsNothing);
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

  test('PDF gallery uses at least two responsive columns', () {
    expect(PdfSelectionGalleryLayout.columnCount(360), 2);
    expect(PdfSelectionGalleryLayout.columnCount(900), 4);
  });

  test(
    'page preview contain sizing preserves portrait and landscape documents',
    () {
      final portrait = applyBoxFit(
        BoxFit.contain,
        const Size(1000, 1500),
        const Size(1600, 1200),
      );
      final landscape = applyBoxFit(
        BoxFit.contain,
        const Size(1500, 1000),
        const Size(1600, 1200),
      );

      expect(portrait.destination, const Size(800, 1200));
      expect(landscape.destination, const Size(1600, 1066.6666666666667));
    },
  );

  testWidgets('viewer preview fills the phone body without action overlap', (
    tester,
  ) async {
    await _expectViewerPreviewUsesAvailableArea(tester, const Size(390, 844));
  });

  testWidgets('viewer preview fills the portrait tablet body', (tester) async {
    await _expectViewerPreviewUsesAvailableArea(tester, const Size(1600, 2560));
  });

  testWidgets('viewer preview fills the landscape tablet body', (tester) async {
    await _expectViewerPreviewUsesAvailableArea(tester, const Size(2560, 1600));
  });

  testWidgets('gallery actions stay below the scan thumbnail', (tester) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();

    final image = tester.getRect(
      find.byKey(const ValueKey('managed-thumbnail-rotation-1')),
    );
    final actions = tester.getRect(
      find.byKey(const ValueKey('gallery-action-row-/raw_1.jpg')),
    );
    expect(actions.top, greaterThanOrEqualTo(image.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery action row stays inside cards on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = _viewerManagerWithPages(2);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(
      find.byKey(const ValueKey('pdf-gallery-page-/raw_1.jpg')),
    );
    final actions = tester.getRect(
      find.byKey(const ValueKey('gallery-action-row-/raw_1.jpg')),
    );
    expect(actions.left, greaterThanOrEqualTo(card.left));
    expect(actions.right, lessThanOrEqualTo(card.right));
    expect(actions.bottom, lessThanOrEqualTo(card.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('PDF completion is disabled until a gallery page is selected', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(2);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pdfSelectionGallery')), findsOneWidget);
    expect(find.text('0페이지 선택됨'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('reviewSelectedPagesButton')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('pdfGalleryCard-/raw_1.jpg')));
    await tester.pump();

    expect(find.text('1페이지 선택됨'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('reviewSelectedPagesButton')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('gallery supports select all and deselect all', (tester) async {
    final manager = _viewerManagerWithPages(3);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('toggleSelectAllButton')));
    await tester.pump();
    expect(find.text('3페이지 선택됨'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNWidgets(4));

    await tester.tap(find.byKey(const Key('toggleSelectAllButton')));
    await tester.pump();
    expect(find.text('0페이지 선택됨'), findsOneWidget);
  });

  testWidgets('Gallery quick corner edit returns to the same Gallery', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('gallery-quick-corner-/raw_1.jpg')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QuickCornerEditPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-corner-cancel-appbar')));
    await tester.pumpAndSettle();
    expect(find.byType(PageManagementPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pdfGalleryCard-/raw_1.jpg')),
      findsOneWidget,
    );
  });

  testWidgets('gallery completion opens review with only selected pages', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(3);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pdfGalleryCard-/raw_1.jpg')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pdfGalleryCard-/raw_3.jpg')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reviewSelectedPagesButton')));
    await tester.pumpAndSettle();

    expect(find.byType(PdfPageReviewPage), findsOneWidget);
    expect(find.byKey(const Key('pdfPageReviewGrid')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pdf-review-card-/raw_1.jpg')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pdf-review-card-/raw_2.jpg')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('pdf-review-card-/raw_3.jpg')),
      findsOneWidget,
    );
  });

  testWidgets(
    'review back preserves gallery selection across repeated pushes',
    (tester) async {
      final manager = _viewerManagerWithPages(2);
      addTearDown(manager.close);
      await tester.pumpWidget(
        MaterialApp(home: PageManagementPage(sessionManager: manager)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pdfGalleryCard-/raw_1.jpg')));
      await tester.pump();

      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byKey(const Key('reviewSelectedPagesButton')));
        await tester.pumpAndSettle();
        expect(find.byType(PdfPageReviewPage), findsOneWidget);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.text('1페이지 선택됨'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('PDF Review quick corner edit returns to the same order', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toggleSelectAllButton')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reviewSelectedPagesButton')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('pdf-review-action-row-/raw_1.jpg')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('pdf-review-quick-corner-/raw_1.jpg')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QuickCornerEditPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick-corner-cancel-appbar')));
    await tester.pumpAndSettle();
    expect(find.byType(PdfPageReviewPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pdf-review-card-/raw_1.jpg')),
      findsOneWidget,
    );
  });

  testWidgets(
    'review tap keeps order and long press drag updates PDF numbers',
    (tester) async {
      final manager = _viewerManagerWithPages(3);
      addTearDown(manager.close);
      await tester.pumpWidget(
        MaterialApp(home: PageManagementPage(sessionManager: manager)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('toggleSelectAllButton')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('reviewSelectedPagesButton')));
      await tester.pumpAndSettle();

      final firstCard = find.byKey(
        const ValueKey('pdf-review-card-/raw_1.jpg'),
      );
      await tester.tap(firstCard);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pdfReviewViewer')), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: firstCard, matching: find.text('1')),
        findsOneWidget,
      );

      final thirdCard = find.byKey(
        const ValueKey('pdf-review-card-/raw_3.jpg'),
      );
      final gesture = await tester.startGesture(tester.getCenter(firstCard));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.moveTo(tester.getCenter(thirdCard));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final liveOrder = tester.widget<Semantics>(
        find.byKey(const Key('pdfReviewOrder')),
      );
      expect(
        liveOrder.properties.value,
        '/raw_2.jpg|/raw_3.jpg|/raw_1.jpg',
        reason: 'PDF order must change while the pointer is still down.',
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: firstCard, matching: find.text('3')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('review blocks duplicate PDF flows before SAF starts', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toggleSelectAllButton')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('reviewSelectedPagesButton')));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('createReviewedPdfButton')),
    );
    button.onPressed!();
    button.onPressed!();
    await tester.pump();

    expect(find.text('PDF 파일명'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('injected ScanSessionManager is not disposed by ScanaApp', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    await tester.pumpWidget(ScanaApp(sessionManager: manager));
    await tester.pumpWidget(const SizedBox.shrink());

    expect(manager.pageCount, 1);
    await manager.findRecoverableSessions();
    manager.close();
  });

  testWidgets('gallery back preserves pages for additional capture', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(2);
    addTearDown(manager.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Camera Preview')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PageManagementPage(sessionManager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Camera Preview'), findsOneWidget);
    expect(manager.pageCount, 2);
  });

  testWidgets('gallery reflects pages added by continued capture', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Camera Preview')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PageManagementPage(sessionManager: manager),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('pdfGalleryCard-/raw_1.jpg')),
      findsOneWidget,
    );

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    final session = manager.currentSession!;
    session.addPage(
      ScanPage(
        pageNo: 2,
        rawImagePath: '/raw_2.jpg',
        createdTime: DateTime.utc(2026, 8, 11),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => PageManagementPage(sessionManager: manager),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('pdfGalleryCard-/raw_2.jpg')),
      findsOneWidget,
    );
  });

  testWidgets('recent scan thumbnail is the gallery entry and shows count', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RecentScanGalleryButton(
              page: ScanPage(
                pageNo: 2,
                rawImagePath: '/missing.jpg',
                createdTime: DateTime.utc(2026, 8, 11),
              ),
              pageCount: 12,
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('12'), findsOneWidget);
    await tester.tap(find.byKey(const Key('recentScanGalleryButton')));
    expect(tapped, isTrue);
    expect(find.text('촬영 완료'), findsNothing);
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
      ScanaApp(
        sessionManager: manager,
        recoverySession: emptySession,
        orientationController: _NoopOrientationController(),
      ),
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

  testWidgets('nested viewer and gallery pop once after last page deletion', (
    tester,
  ) async {
    final manager = _viewerManagerWithPages(1);
    addTearDown(manager.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('Camera Preview')),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => ScanResultViewerPage(sessionManager: manager),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('페이지 관리'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('페이지 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();

    expect(find.text('Camera Preview'), findsOneWidget);
    expect(manager.pageCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery resume opens gallery and Back returns to camera', (
    tester,
  ) async {
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
      ScanaApp(
        sessionManager: manager,
        recoverySession: session,
        orientationController: _NoopOrientationController(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('이전 스캔 작업이 있습니다.'), findsOneWidget);
    expect(find.textContaining('페이지 수: 1'), findsOneWidget);
    expect(find.text('이어하기'), findsOneWidget);

    await tester.tap(find.text('이어하기'));
    await tester.pumpAndSettle();

    expect(manager.currentSession?.id, 'recovered-session');
    expect(find.byKey(const Key('pdfSelectionGallery')), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(manager.currentSession?.id, 'recovered-session');
    expect(find.text('카메라를 준비하는 중입니다.'), findsOneWidget);
  });

  testWidgets('recovery deletion returns to a new camera state', (
    tester,
  ) async {
    final session =
        ScanSession(
          id: 'delete-recovered-session',
          createdTime: DateTime.utc(2026, 8, 10),
        )..addPage(
          ScanPage(
            pageNo: 1,
            rawImagePath: '/scan_sessions/raw_001.jpg',
            createdTime: DateTime.utc(2026, 8, 10),
          ),
        );
    final manager = ScanSessionManager(storage: _TestSessionStorage());
    addTearDown(manager.close);

    await tester.pumpWidget(
      ScanaApp(
        sessionManager: manager,
        recoverySession: session,
        orientationController: _NoopOrientationController(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제 후 새 스캔'));
    await tester.pumpAndSettle();

    expect(manager.currentSession, isNull);
    expect(find.byKey(const Key('pdfSelectionGallery')), findsNothing);
    expect(find.text('카메라를 준비하는 중입니다.'), findsOneWidget);
  });

  testWidgets('Viewer and Gallery prefer the completed enhanced image', (
    tester,
  ) async {
    final manager = ScanSessionManager(storage: _TestSessionStorage());
    addTearDown(manager.close);
    final session =
        ScanSession(
          id: 'enhanced-viewer-session',
          createdTime: DateTime.utc(2026, 8, 10),
        )..addPage(
          ScanPage(
            pageNo: 1,
            rawImagePath: '/raw.jpg',
            correctedImagePath: '/corrected.jpg',
            enhancedImagePath: '/enhanced.jpg',
            enhancementStatus: EnhancementStatus.completed,
            createdTime: DateTime.utc(2026, 8, 10),
          ),
        );
    manager.restoreSession(session);

    await tester.pumpWidget(
      MaterialApp(home: ScanResultViewerPage(sessionManager: manager)),
    );
    await tester.pump();
    var image = tester.widget<Image>(find.byType(Image).first);
    expect((image.image as FileImage).file.path, '/enhanced.jpg');
    expect(image.filterQuality, FilterQuality.medium);

    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: manager)),
    );
    await tester.pump();
    image = tester.widget<Image>(find.byType(Image).first);
    expect((image.image as FileImage).file.path, '/enhanced.jpg');
    expect(
      find.byKey(const ValueKey('page-processing-/raw.jpg')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Page Editor keeps automatic scan preview separate from corner edit',
    (tester) async {
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

      expect(
        find.byKey(const ValueKey('editor-corrected-rotation')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('document-corner-2')), findsNothing);
      expect(find.text('원근 보정'), findsNothing);
      expect(find.text('보정 실행'), findsNothing);
      expect(find.text('모서리 수정'), findsOneWidget);
    },
  );

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
      expect(find.text('모서리 수정'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
      final retakeRect = tester.getRect(
        find.byKey(const ValueKey('viewer-retake-button')),
      );
      final cornerRect = tester.getRect(
        find.byKey(const ValueKey('viewer-quick-corner-button')),
      );
      final deleteRect = tester.getRect(
        find.byKey(const ValueKey('viewer-delete-button')),
      );
      expect(retakeRect.height, cornerRect.height);
      expect(cornerRect.height, deleteRect.height);

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
    'Page Editor shows automatic scan and opens focused corner editing',
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

      expect(
        find.byKey(const ValueKey('page-enhancement-mode-selector')),
        findsOneWidget,
      );
      await tester.tap(find.text(EnhancementMode.originalColor.label));
      await tester.pumpAndSettle();
      expect(
        manager.currentSession!.pages.single.enhancementMode,
        EnhancementMode.originalColor,
      );
      expect(
        manager.currentSession!.pages.single.enhancementStatus,
        EnhancementStatus.completed,
      );

      expect(find.text('원근 보정'), findsNothing);
      expect(find.text('책/곡면 문서 보정'), findsNothing);
      expect(find.text('다시 보정'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('page-editor-quick-corner-button')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(QuickCornerEditPage), findsOneWidget);
    },
  );
  testWidgets('DEBUG Page Editor exposes AI segmentation comparison', (
    tester,
  ) async {
    final manager = ScanSessionManager(storage: _TestSessionStorage());
    addTearDown(manager.close);
    final session = ScanSession(
      id: 'ai-comparison-session',
      createdTime: DateTime.utc(2026, 8, 12),
    );
    session.addPage(
      ScanPage(
        pageNo: 1,
        rawImagePath: '/raw.jpg',
        createdTime: DateTime.utc(2026, 8, 12),
        aiSegmentationResult: const AiDocumentSegmentationResult(
          success: true,
          modelVersion: 'v1.2.0',
          modelLoadMs: 20,
          preprocessMs: 10,
          inferenceTimeMs: 80,
          postprocessMs: 10,
          totalMs: 100,
          sourceWidth: 1000,
          sourceHeight: 1500,
          maskWidth: 256,
          maskHeight: 256,
          confidence: 0.9,
          maskCoverage: 0.7,
          pageSide: 'single',
          refinementAttempted: true,
          refinementAccepted: true,
          mainPageOwnershipScore: 0.91,
          outerEnvelopeConsistency: 0.86,
          edgeContinuity: 0.9,
          adjacentPagePenalty: 0.08,
          occlusionPenalty: 0.12,
          refinedConfidence: 0.88,
          refinedStatus: AiRefinedBoundaryStatus.accepted,
        ),
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
    await tester.tap(
      find.byKey(const ValueKey('ai-detection-comparison-button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 검출 비교'), findsWidgets);
    expect(find.byKey(const ValueKey('ai-comparison-raw')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-comparison-openCv')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-comparison-aiRaw')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-comparison-aiRefined')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ai-comparison-aiMask')), findsOneWidget);
    expect(find.textContaining('ownership 0.91'), findsOneWidget);
    expect(find.textContaining('accepted'), findsOneWidget);
  });

  test('Page Editor development controls are hidden for release builds', () {
    expect(
      PageEditorDebugUiPolicy.showDeveloperControls(isDebugBuild: true),
      isTrue,
    );
    expect(
      PageEditorDebugUiPolicy.showDeveloperControls(isDebugBuild: false),
      isFalse,
    );
  });

  testWidgets('DEBUG Page Editor reads the latest curvature report', (
    tester,
  ) async {
    final sessionDirectory = Directory.systemTemp.createTempSync(
      'scana-curvature-diagnostics-',
    );
    addTearDown(() {
      if (sessionDirectory.existsSync()) {
        sessionDirectory.deleteSync(recursive: true);
      }
    });
    final rawPath = path.join(sessionDirectory.path, 'raw_001.jpg');
    final reportDirectory = Directory(
      path.join(sessionDirectory.path, 'debug_curvature', 'raw_001'),
    );
    reportDirectory.createSync(recursive: true);
    File(
      path.join(reportDirectory.path, 'curvature_report.json'),
    ).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object>{
        'state': 'mildCurve',
        'applied': true,
        'pageContourMagnitude': 0.0042,
        'topCurve': 0.0031,
        'bottomCurve': 0.0042,
        'spineCurve': 0.0024,
        'internalLineMagnitude': 0.0018,
        'effectiveDeformationMagnitude': 0.00099,
        'topRawSign': 1,
        'bottomRawSign': -1,
        'spineRawSign': 1,
        'topNormalizedSign': 1,
        'bottomNormalizedSign': 1,
        'spineNormalizedSign': 1,
        'directionConflictBeforeNormalization': true,
        'directionConflictAfterNormalization': false,
        'signConvention': 'rectified_y_axis',
        'horizontalDirectionVotes': <String, Object>{
          'top': 1,
          'bottom': 1,
          'internal': <int>[1],
        },
        'spineUsedForDirectionConflict': false,
        'coverage': 0.74,
        'evidenceCount': 4,
        'consistency': 0.82,
        'confidence': 0.78,
        'deformationStrength': 0.35,
        'perspectiveStraightness': 0.71,
        'curvedStraightness': 0.84,
        'geometryBefore': 0.0042,
        'geometryAfter': 0.0021,
        'rejectReason': 'none',
        'detectMs': 120,
        'dewarpMs': 80,
      }),
    );

    final manager = ScanSessionManager(storage: _TestSessionStorage());
    addTearDown(manager.close);
    final session = ScanSession(
      id: 'curvature-diagnostics-session',
      createdTime: DateTime.utc(2026, 8, 13),
    );
    session.addPage(
      ScanPage(
        pageNo: 1,
        rawImagePath: rawPath,
        createdTime: DateTime.utc(2026, 8, 13),
        curvatureState: CurvatureState.mildCurve,
        curvedApplied: true,
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

    expect(
      find.byKey(const ValueKey('curvature-diagnostics-button')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('curvature-diagnostics-button')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('곡면보정 진단'), findsWidgets);
    expect(find.byKey(const ValueKey('curvature-value-state')), findsOneWidget);
    expect(find.text('MILD_CURVE'), findsOneWidget);
    expect(find.text('0.0042'), findsWidgets);
    expect(find.text('0.35'), findsOneWidget);
    expect(find.text('0.00099'), findsOneWidget);
    expect(find.text('rectified_y_axis'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('curvature-value-totalMs')),
    );
    await tester.pump();
    expect(find.text('200'), findsOneWidget);
    expect(find.text('none'), findsOneWidget);
    expect(find.byKey(const ValueKey('curvature-report-raw')), findsOneWidget);
  });
}

Future<void> _expectViewerPreviewUsesAvailableArea(
  WidgetTester tester,
  Size screenSize,
) async {
  tester.view.physicalSize = screenSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final manager = _viewerManagerWithPages(1);
  addTearDown(manager.close);

  await tester.pumpWidget(
    MaterialApp(home: ScanResultViewerPage(sessionManager: manager)),
  );
  await tester.pumpAndSettle();

  final preview = tester.getRect(
    find.byKey(const ValueKey('viewer-page-preview-area-1')),
  );
  final imageFinder = find.descendant(
    of: find.byKey(const ValueKey('viewer-page-preview-area-1')),
    matching: find.byType(Image),
  );
  final image = tester.widget<Image>(imageFinder);
  final imageRect = tester.getRect(imageFinder);
  final actions = tester.getRect(
    find.byKey(const ValueKey('viewer-retake-button')),
  );

  expect(preview.width, closeTo(screenSize.width, 0.1));
  expect(preview.bottom, lessThanOrEqualTo(actions.top));
  expect(imageRect.size, preview.size);
  expect(image.fit, BoxFit.contain);
  expect(image.image, isA<FileImage>());
  expect(tester.takeException(), isNull);
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

class _NoopOrientationController implements ScreenOrientationController {
  @override
  Future<void> enterContentScreen() async {}

  @override
  Future<void> enterSingleCamera() async {}

  @override
  Future<void> enterSpreadCamera() async {}

  @override
  Future<void> restoreSystemDefault() async {}
}
