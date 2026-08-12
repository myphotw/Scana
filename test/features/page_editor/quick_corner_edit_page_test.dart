import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/features/page_editor/presentation/quick_corner_edit_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/image_processing/page_corrector.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  late Directory root;
  late ScanSessionManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('quick_corner_widget_');
    final sessionDirectory = Directory(
      path.join(root.path, 'scan_sessions', 'quick-session'),
    );
    await sessionDirectory.create(recursive: true);
    final raw = File(path.join(sessionDirectory.path, 'raw_001.jpg'));
    await raw.writeAsBytes([1, 2, 3]);
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => root,
      ),
      pageCorrector: const _TestCorrector(),
      pageEnhancer: const _TestEnhancer(),
    );
    final session =
        ScanSession(id: 'quick-session', createdTime: DateTime.utc(2026, 8, 12))
          ..addPage(
            ScanPage(
              pageNo: 1,
              rawImagePath: raw.path,
              createdTime: DateTime.utc(2026, 8, 12),
              documentSourceWidth: 1000,
              documentSourceHeight: 1500,
              documentCorners: _corners,
              enhancementMode: EnhancementMode.scanColor,
            ),
          );
    manager.restoreSession(session);
  });

  tearDown(() async {
    manager.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('drag shows magnifier and cancel leaves page unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuickCornerEditPage(sessionManager: manager, pageIndex: 0),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('quick-corner-handle-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-corner-apply')), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('quick-corner-handle-0'))),
    );
    await gesture.moveBy(const Offset(20, 20));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('quick-corner-magnifier')),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('quick-corner-magnifier')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('quick-corner-cancel')));
    await tester.pumpAndSettle();
    final page = manager.currentSession!.pages.single;
    expect(page.cropSource, isNull);
    expect(page.hasUserAdjustedCorners, isFalse);
  });

  testWidgets('apply action is exposed by the focused editor', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: QuickCornerEditPage(sessionManager: manager, pageIndex: 0),
      ),
    );
    await tester.pump();
    final applyFinder = find.byKey(const ValueKey('quick-corner-apply'));
    expect(applyFinder, findsOneWidget);
    expect(tester.widget<FilledButton>(applyFinder).onPressed, isNotNull);
    expect(find.text('취소'), findsOneWidget);
    expect(find.text('적용'), findsOneWidget);
  });
}

const _corners = DocumentCorners(
  topLeft: DocumentPoint(60, 80),
  topRight: DocumentPoint(940, 80),
  bottomRight: DocumentPoint(940, 1420),
  bottomLeft: DocumentPoint(60, 1420),
);

class _TestCorrector implements PageCorrector {
  const _TestCorrector();

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) async {
    await File(outputImagePath).writeAsBytes([4, 5, 6]);
    return const PageCorrectionResult(outputWidth: 900, outputHeight: 1400);
  }
}

class _TestEnhancer implements PageEnhancer {
  const _TestEnhancer();

  @override
  Future<PageEnhancementResult> enhance({
    required String sourceImagePath,
    required String outputImagePath,
    required EnhancementMode mode,
  }) async {
    await File(outputImagePath).writeAsBytes([7, 8, 9]);
    return const PageEnhancementResult(
      outputWidth: 900,
      outputHeight: 1400,
      processingMilliseconds: 1,
    );
  }
}
