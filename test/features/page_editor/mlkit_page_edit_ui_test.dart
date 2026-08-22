import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import 'package:scana/features/page_editor/presentation/mlkit_crop_editor_page.dart';
import 'package:scana/features/page_editor/presentation/mlkit_page_edit_page.dart';
import 'package:scana/features/page_editor/presentation/mlkit_split_line_editor_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  testWidgets('PDF selection exposes ML Kit Edit instead of Quick Corner', (
    tester,
  ) async {
    final fixture = await tester.runAsync(_fixture);
    addTearDown(() async {
      fixture!.manager.close();
      await fixture.root.delete(recursive: true);
    });
    final page = fixture!.manager.currentSession!.pages.single;

    await tester.pumpWidget(
      MaterialApp(home: PageManagementPage(sessionManager: fixture.manager)),
    );
    await tester.pump();

    expect(
      find.byKey(ValueKey('gallery-mlkit-edit-${page.rawImagePath}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('gallery-quick-corner-${page.rawImagePath}')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(ValueKey('gallery-mlkit-edit-${page.rawImagePath}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MlKitPageEditPage), findsOneWidget);
    expect(find.byKey(const Key('editMlKitCropButton')), findsOneWidget);
    expect(find.byKey(const Key('convertMlKitToSpreadButton')), findsOneWidget);
    expect(find.text('모서리 수정'), findsNothing);
  });

  testWidgets('crop editor presents draggable crop handles and apply action', (
    tester,
  ) async {
    final fixture = await tester.runAsync(_fixture);
    addTearDown(() async {
      fixture!.manager.close();
      await fixture.root.delete(recursive: true);
    });
    final page = fixture!.manager.currentSession!.pages.single;

    await tester.pumpWidget(
      MaterialApp(
        home: MlKitCropEditorPage(
          imagePath: page.rawImagePath,
          imageWidth: 200,
          imageHeight: 100,
          rotation: 0,
        ),
      ),
    );

    expect(find.byKey(const Key('mlKitCropEditor')), findsOneWidget);
    expect(find.byKey(const Key('cropHandleTopLeft')), findsOneWidget);
    expect(find.byKey(const Key('cropHandleBottomRight')), findsOneWidget);
    expect(find.byKey(const Key('applyMlKitCropButton')), findsOneWidget);
  });

  testWidgets('split line editor exposes constrained draggable line', (
    tester,
  ) async {
    final fixture = await tester.runAsync(_fixture);
    addTearDown(() async {
      fixture!.manager.close();
      await fixture.root.delete(recursive: true);
    });
    final page = fixture!.manager.currentSession!.pages.single;

    await tester.pumpWidget(
      MaterialApp(
        home: MlKitSplitLineEditorPage(
          sourceImagePath: page.rawImagePath,
          sourceWidth: 200,
          sourceHeight: 100,
          initialSplitX: 104,
        ),
      ),
    );

    expect(find.byKey(const Key('mlKitSplitLineEditor')), findsOneWidget);
    expect(find.byKey(const Key('mlKitSplitDragHandle')), findsOneWidget);
    expect(find.byKey(const Key('applyMlKitSplitButton')), findsOneWidget);
    expect(find.textContaining('overlap 1.5%'), findsOneWidget);
  });
}

class _Fixture {
  const _Fixture(this.root, this.manager);

  final Directory root;
  final ScanSessionManager manager;
}

Future<_Fixture> _fixture() async {
  final root = await Directory.systemTemp.createTemp('scana_mlkit_edit_ui_');
  final manager = ScanSessionManager(
    storage: AppPrivateSessionStorage(
      appPrivateDirectoryProvider: () async => root,
    ),
    sessionIdGenerator: () => 'ui-session',
  );
  final target = await manager.prepareMlKitScan();
  final directory = Directory(
    path.join(root.path, 'scan_sessions', target.sessionId, 'mlkit'),
  );
  await directory.create(recursive: true);
  final source = image.Image(width: 200, height: 100);
  image.fill(source, color: image.ColorRgb8(240, 240, 240));
  final bytes = image.encodeJpg(source);
  final file = File(path.join(directory.path, 'page_001.jpg'));
  await file.writeAsBytes(bytes, flush: true);
  await manager.registerMlKitImports([
    MlKitPageImport(
      scannedPage: MlKitScannedPage(
        filePath: file.path,
        byteCount: bytes.length,
        width: 200,
        height: 100,
      ),
      sourceType: ScanPageSourceType.mlKit,
      layout: MlKitPageLayout.single,
      originalSourcePath: file.path,
    ),
  ]);
  return _Fixture(root, manager);
}
