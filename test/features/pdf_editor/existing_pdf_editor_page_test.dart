import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/pdf_editor/presentation/existing_pdf_editor_page.dart';
import 'package:scana/services/pdf_editor/existing_pdf_editor.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';

void main() {
  late Directory temporaryDirectory;
  late File thumbnail;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'pdf_editor_ui_',
    );
    thumbnail = File('${temporaryDirectory.path}/thumbnail.png');
    await thumbnail.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  testWidgets('deletes and restores a page without changing the source PDF', (
    tester,
  ) async {
    final platform = _FakeEditorPlatform(thumbnail.path);
    await tester.pumpWidget(
      MaterialApp(home: _page(platform: platform, pageCount: 5)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('deletePdfPage-1')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('restorePdfPage-1')),
      300,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('restorePdfPage-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('restorePdfPage-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('deletePdfPage-1')), findsOneWidget);
    expect(platform.exportCalls, 0);
  });

  testWidgets('prevents deleting the final page', (tester) async {
    final platform = _FakeEditorPlatform(thumbnail.path);
    await tester.pumpWidget(
      MaterialApp(home: _page(platform: platform, pageCount: 1)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('deletePdfPage-0')));
    await tester.pump();
    expect(find.text('모든 페이지를 삭제할 수 없습니다.'), findsOneWidget);
    expect(find.byKey(const ValueKey('deletePdfPage-0')), findsOneWidget);
  });

  testWidgets('save cancellation keeps the editor and source session', (
    tester,
  ) async {
    final platform = _FakeEditorPlatform(thumbnail.path);
    final storage = _FakeStorage();
    await tester.pumpWidget(
      MaterialApp(
        home: _page(platform: platform, pageCount: 5, storage: storage),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('saveExistingPdfButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장 위치 선택'));
    await tester.pumpAndSettle();

    expect(platform.exportCalls, 0);
    expect(find.byType(ExistingPdfEditorPage), findsOneWidget);
  });

  testWidgets('storage failure discards output but preserves edit session', (
    tester,
  ) async {
    final platform = _FakeEditorPlatform(thumbnail.path);
    await tester.pumpWidget(
      MaterialApp(
        home: _page(
          platform: platform,
          pageCount: 5,
          storage: _FailingStorage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('saveExistingPdfButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장 위치 선택'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('최근 위치 사용'));
    await tester.pumpAndSettle();

    expect(platform.exportCalls, 1);
    expect(platform.discardCalls, 1);
    expect(platform.cleanupCalls, 0);
    expect(find.byType(ExistingPdfEditorPage), findsOneWidget);
    expect(find.textContaining('원본 PDF는 변경되지 않았습니다.'), findsOneWidget);
  });
}

Widget _page({
  required _FakeEditorPlatform platform,
  required int pageCount,
  PdfDestinationStorage? storage,
}) => ExistingPdfEditorPage(
  document: ExistingPdfDocument(
    sessionId: '00000000-0000-0000-0000-000000000001',
    sourcePath: '/work/source.pdf',
    displayName: 'source.pdf',
    pageCount: pageCount,
    byteCount: 1024,
  ),
  editorPlatform: platform,
  destinationStorage: storage ?? _FakeStorage(),
);

class _FakeEditorPlatform implements ExistingPdfEditorPlatform {
  _FakeEditorPlatform(this.thumbnailPath);

  final String thumbnailPath;
  int exportCalls = 0;
  int cleanupCalls = 0;
  int discardCalls = 0;

  @override
  Future<void> cleanup(String sessionId) async => cleanupCalls++;

  @override
  Future<void> discardOutput({
    required String sessionId,
    required String outputPath,
  }) async => discardCalls++;

  @override
  Future<ExistingPdfExport> exportPdf({
    required String sessionId,
    required List<int> pageOrder,
  }) async {
    exportCalls++;
    return ExistingPdfExport(
      outputPath: '/work/output.pdf',
      pageCount: pageOrder.length,
      byteCount: 900,
    );
  }

  @override
  Future<ExistingPdfDocument?> pickPdf() async => null;

  @override
  Future<String> renderThumbnail({
    required String sessionId,
    required int pageIndex,
    int maximumWidth = 512,
    int maximumHeight = 720,
  }) async => thumbnailPath;
}

class _FakeStorage implements PdfDestinationStorage {
  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async => null;

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async => null;

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) => throw UnimplementedError();
}

class _FailingStorage implements PdfDestinationStorage {
  @override
  Future<PdfDirectoryLocation?> chooseDirectory() async => null;

  @override
  Future<PdfDirectoryLocation?> recentDirectory() async =>
      const PdfDirectoryLocation(uri: 'content://documents/tree', label: '문서');

  @override
  Future<PdfSavedDocument> save({
    required String temporaryPdfPath,
    required PdfDirectoryLocation directory,
    required String fileName,
  }) => throw const FileSystemException('write failed');
}
