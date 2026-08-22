import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_page_mutation_policy.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  late Directory root;
  late AppPrivateSessionStorage storage;
  late ScanSessionManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scana_mlkit_edit_');
    storage = AppPrivateSessionStorage(
      appPrivateDirectoryProvider: () async => root,
    );
    manager = ScanSessionManager(
      storage: storage,
      sessionIdGenerator: () => 'edit-session',
      clock: () => DateTime.utc(2026, 8, 21),
    );
  });

  tearDown(() async {
    manager.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'repeated crop always uses original source and emits lossless PNG',
    () async {
      final page = (await _importPages(root, manager, 1)).single;

      await manager.cropMlKitPageAt(
        0,
        const MlKitCropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
      );
      final first = manager.currentSession!.pages.single;
      final firstOutput = first.editedImagePath!;
      final firstImage = image.decodePng(
        await File(firstOutput).readAsBytes(),
      )!;
      expect(firstImage.width, 160);
      expect(firstImage.height, 80);
      expect(first.rawImagePath, page.rawImagePath);
      expect(first.originalSourcePath, page.rawImagePath);

      await manager.cropMlKitPageAt(
        0,
        const MlKitCropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
      );
      final second = manager.currentSession!.pages.single;
      final secondImage = image.decodePng(
        await File(second.editedImagePath!).readAsBytes(),
      )!;
      expect(secondImage.width, 80);
      expect(secondImage.height, 40);
      expect(second.mlKitCropRect!.left, closeTo(0.3, 0.001));
      expect(second.mlKitCropRect!.right, closeTo(0.7, 0.001));
      expect(await File(firstOutput).exists(), false);
      expect(await File(page.rawImagePath).exists(), true);
    },
  );

  test(
    'rotation metadata advances through 90 180 and 270 losslessly',
    () async {
      await _importPages(root, manager, 1);

      for (final expected in [90, 180, 270]) {
        await manager.rotateMlKitPageAt(0);
        final page = manager.currentSession!.pages.single;
        expect(page.rotation, expected);
        expect(page.editedImagePath, endsWith('.png'));
        expect(page.originalSourcePath, isNot(page.editedImagePath));
        expect(await File(page.originalSourcePath!).exists(), true);
      }
    },
  );

  test(
    'single spread adjustment and restore preserve source and order',
    () async {
      final imported = await _importPages(root, manager, 3);
      final middleSource = imported[1].rawImagePath;

      final split = await manager.splitMlKitPageAt(
        1,
        splitX: 108,
        confidence: 0.82,
        fallbackUsed: false,
      );
      expect(manager.currentSession!.pages.map((page) => page.pageNo), [
        1,
        2,
        3,
        4,
      ]);
      expect(
        manager.currentSession!.pages[0].rawImagePath,
        imported[0].rawImagePath,
      );
      expect(
        manager.currentSession!.pages[3].rawImagePath,
        imported[2].rawImagePath,
      );
      expect(split.pages.map((page) => page.spreadSide), [
        MlKitSpreadSide.left,
        MlKitSpreadSide.right,
      ]);
      expect(
        split.pages.every((page) => page.originalSourcePath == middleSource),
        true,
      );
      expect(await File(middleSource).exists(), true);

      final oldSplitPaths = split.pages
          .map((page) => page.rawImagePath)
          .toList();
      final adjusted = await manager.adjustMlKitSpreadAt(1, 124);
      expect(adjusted.pages.every((page) => page.splitX == 124), true);
      expect(
        adjusted.pages.first.mlKitCropRect!.right,
        closeTo(0.635, 0.001),
      );
      expect(
        adjusted.pages.last.mlKitCropRect!.left,
        closeTo(0.605, 0.001),
      );
      for (final oldPath in oldSplitPaths) {
        expect(await File(oldPath).exists(), false);
      }

      final restored = await manager.restoreMlKitSpreadAt(1);
      expect(restored.pages, hasLength(1));
      expect(restored.pages.single.rawImagePath, middleSource);
      expect(restored.pages.single.sourceType, ScanPageSourceType.mlKit);
      expect(manager.currentSession!.pages.map((page) => page.rawImagePath), [
        imported[0].rawImagePath,
        middleSource,
        imported[2].rawImagePath,
      ]);
    },
  );

  test('selection order recovery and PDF prefer final edited image', () async {
    final imported = await _importPages(root, manager, 2);
    final originalOrder = List<ScanPage>.of(imported);
    final mutation = await manager.splitMlKitPageAt(
      0,
      splitX: 110,
      confidence: 0.9,
      fallbackUsed: false,
    );

    final selection = MlKitPageMutationPolicy.preserveSelection({
      imported[0].rawImagePath,
    }, mutation);
    expect(selection, mutation.pages.map((page) => page.rawImagePath).toSet());
    final order = MlKitPageMutationPolicy.preserveOrder(
      originalOrder,
      mutation,
    );
    expect(order.map((page) => page.rawImagePath), [
      ...mutation.pages.map((page) => page.rawImagePath),
      imported[1].rawImagePath,
    ]);

    await manager.cropMlKitPageAt(
      0,
      const MlKitCropRect(left: 0.05, top: 0.05, right: 0.95, bottom: 0.95),
    );
    await manager.rotateMlKitPageAt(0);
    final edited = manager.currentSession!.pages.first;
    final pdf = PdfExportSelection.fromSessionPages(
      [edited],
      {edited.rawImagePath},
    );
    expect(pdf.pages.single.sourceImagePath, edited.editedImagePath);

    final recovered = await storage.findRecoverableSessions();
    final recoveredEdited = recovered.single.pages.first;
    expect(recoveredEdited.parentSpreadId, edited.parentSpreadId);
    expect(recoveredEdited.originalSourcePath, edited.originalSourcePath);
    expect(recoveredEdited.splitX, edited.splitX);
    expect(recoveredEdited.rotation, 90);
    expect(
      recoveredEdited.mlKitCropRect!.left,
      closeTo(edited.mlKitCropRect!.left, 0.001),
    );
    expect(recoveredEdited.editedImagePath, edited.editedImagePath);
  });

  test(
    'child cleanup retains shared source until the final child is deleted',
    () async {
      final imported = await _importPages(root, manager, 1);
      final sourcePath = imported.single.rawImagePath;
      await manager.splitMlKitPageAt(
        0,
        splitX: 110,
        confidence: 0.9,
        fallbackUsed: false,
      );

      await manager.deletePageAt(0);
      expect(await File(sourcePath).exists(), true);
      expect(manager.pageCount, 1);

      await manager.deletePageAt(0);
      expect(await File(sourcePath).exists(), false);
      expect(manager.pageCount, 0);
    },
  );
}

Future<List<ScanPage>> _importPages(
  Directory root,
  ScanSessionManager manager,
  int count,
) async {
  final target = await manager.prepareMlKitScan();
  final directory = Directory(
    path.join(root.path, 'scan_sessions', target.sessionId, 'mlkit'),
  );
  await directory.create(recursive: true);
  final imports = <MlKitPageImport>[];
  for (var index = 0; index < count; index++) {
    final source = _bookImage(width: 200, height: 100, gutterX: 108 + index);
    final bytes = image.encodeJpg(source, quality: 95);
    final file = File(
      path.join(
        directory.path,
        'page_${(index + 1).toString().padLeft(3, '0')}.jpg',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    imports.add(
      MlKitPageImport(
        scannedPage: MlKitScannedPage(
          filePath: file.path,
          byteCount: bytes.length,
          width: source.width,
          height: source.height,
        ),
        sourceType: ScanPageSourceType.mlKit,
        layout: MlKitPageLayout.single,
        originalSourcePath: file.path,
      ),
    );
  }
  return manager.registerMlKitImports(imports);
}

image.Image _bookImage({
  required int width,
  required int height,
  required int gutterX,
}) {
  final result = image.Image(width: width, height: height);
  image.fill(result, color: image.ColorRgb8(244, 244, 244));
  for (var y = 10; y < height - 10; y += 10) {
    for (var x = 10; x < width - 10; x++) {
      if ((x - gutterX).abs() > 8 && y % 10 < 3) {
        result.setPixelRgb(x, y, 70, 70, 70);
      }
    }
  }
  for (var y = 0; y < height; y++) {
    for (var x = gutterX - 3; x <= gutterX + 3; x++) {
      result.setPixelRgb(x, y, 35, 35, 35);
    }
  }
  return result;
}
