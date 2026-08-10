import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  late Directory testRoot;
  late ScanSessionManager manager;

  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('scana_session_test_');
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      sessionIdGenerator: () => 'session-uuid',
      clock: () => DateTime.utc(2026, 8, 10, 1, 2, 3),
    );
  });

  tearDown(() async {
    manager.close();
    if (await testRoot.exists()) {
      await testRoot.delete(recursive: true);
    }
  });

  test('first capture creates a session and ordered raw pages', () async {
    final firstCapture = await _createCapture(testRoot, 'capture_1.jpg');
    final secondCapture = await _createCapture(testRoot, 'capture_2.jpg');

    final firstPage = await manager.addRawCapture(firstCapture.path);
    final secondPage = await manager.addRawCapture(secondCapture.path);

    final expectedDirectory = path.join(
      testRoot.path,
      'scan_sessions',
      'session-uuid',
    );
    expect(manager.currentSession?.id, 'session-uuid');
    expect(manager.pageCount, 2);
    expect(firstPage.pageNo, 1);
    expect(firstPage.rawImagePath, path.join(expectedDirectory, 'raw_001.jpg'));
    expect(secondPage.pageNo, 2);
    expect(
      secondPage.rawImagePath,
      path.join(expectedDirectory, 'raw_002.jpg'),
    );
    expect(firstPage.createdTime, DateTime.utc(2026, 8, 10, 1, 2, 3));
    expect(await File(firstPage.rawImagePath).exists(), isTrue);
    expect(await File(secondPage.rawImagePath).exists(), isTrue);
    expect(await firstCapture.exists(), isFalse);
    expect(await secondCapture.exists(), isFalse);

    final metadata =
        jsonDecode(
              await File(
                path.join(expectedDirectory, 'session.json'),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(metadata['id'], 'session-uuid');
    expect((metadata['pages'] as List).first['rawImageFile'], 'raw_001.jpg');
    expect((metadata['pages'] as List).first['rotation'], 0);
  });

  test('cancel deletes the current temporary session', () async {
    final capture = await _createCapture(testRoot, 'capture.jpg');
    await manager.addRawCapture(capture.path);
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'scan_sessions', 'session-uuid'),
    );

    await manager.cancelSession();

    expect(manager.currentSession, isNull);
    expect(manager.pageCount, 0);
    expect(await sessionDirectory.exists(), isFalse);
  });

  test(
    'successful export cleanup uses the session deletion contract',
    () async {
      final capture = await _createCapture(testRoot, 'capture.jpg');
      await manager.addRawCapture(capture.path);

      await manager.deleteAfterSuccessfulExport();

      expect(manager.currentSession, isNull);
      expect(
        await Directory(
          path.join(testRoot.path, 'scan_sessions', 'session-uuid'),
        ).exists(),
        isFalse,
      );
    },
  );

  test('closing the manager keeps the temporary session', () async {
    final capture = await _createCapture(testRoot, 'capture.jpg');
    await manager.addRawCapture(capture.path);
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'scan_sessions', 'session-uuid'),
    );

    manager.close();

    expect(await sessionDirectory.exists(), isTrue);
  });

  test('finds and restores an existing temporary session', () async {
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'scan_sessions', 'recovered-session'),
    );
    await sessionDirectory.create(recursive: true);
    final secondPage = File(path.join(sessionDirectory.path, 'raw_002.jpg'));
    final firstPage = File(path.join(sessionDirectory.path, 'raw_001.jpg'));
    await secondPage.writeAsBytes([2]);
    await firstPage.writeAsBytes([1]);

    final recoverableSessions = await manager.findRecoverableSessions();

    expect(recoverableSessions, hasLength(1));
    expect(recoverableSessions.single.id, 'recovered-session');
    expect(recoverableSessions.single.pages.map((page) => page.pageNo), [1, 2]);

    manager.restoreSession(recoverableSessions.single);

    expect(manager.currentSession?.id, 'recovered-session');
    expect(manager.pageCount, 2);
  });

  test('deletes a recovered session before starting a new scan', () async {
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'scan_sessions', 'recovered-session'),
    );
    await sessionDirectory.create(recursive: true);

    final recoveredSession = (await manager.findRecoverableSessions()).single;
    await manager.deleteRecoveredSession(recoveredSession);

    expect(await sessionDirectory.exists(), isFalse);
    expect(manager.currentSession, isNull);
  });

  test('persists page rotation and custom order in session metadata', () async {
    final firstCapture = await _createCapture(testRoot, 'capture_1.jpg');
    final secondCapture = await _createCapture(testRoot, 'capture_2.jpg');
    final thirdCapture = await _createCapture(testRoot, 'capture_3.jpg');
    await manager.addRawCapture(firstCapture.path);
    await manager.addRawCapture(secondCapture.path);
    await manager.addRawCapture(thirdCapture.path);

    await manager.rotatePageAt(0);
    await manager.reorderPages(0, 2);
    await manager.deletePageAt(1);

    final pages = manager.currentSession!.pages;
    expect(pages.map((page) => page.pageNo), [1, 2]);
    expect(pages.map((page) => path.basename(page.rawImagePath)), [
      'raw_002.jpg',
      'raw_001.jpg',
    ]);
    expect(pages.last.rotation, 90);
    expect(
      await File(
        path.join(
          testRoot.path,
          'scan_sessions',
          'session-uuid',
          'raw_003.jpg',
        ),
      ).exists(),
      isFalse,
    );

    final metadata =
        jsonDecode(
              await File(
                path.join(
                  testRoot.path,
                  'scan_sessions',
                  'session-uuid',
                  'session.json',
                ),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    final metadataPages = metadata['pages'] as List<dynamic>;
    expect(metadataPages[0]['rawImageFile'], 'raw_002.jpg');
    expect(metadataPages[0]['pageNo'], 1);
    expect(metadataPages[1]['rawImageFile'], 'raw_001.jpg');
    expect(metadataPages[1]['rotation'], 90);
  });

  test(
    'uses session metadata before raw file name order during recovery',
    () async {
      final sessionDirectory = Directory(
        path.join(testRoot.path, 'scan_sessions', 'metadata-session'),
      );
      await sessionDirectory.create(recursive: true);
      await File(
        path.join(sessionDirectory.path, 'raw_001.jpg'),
      ).writeAsBytes([1]);
      await File(
        path.join(sessionDirectory.path, 'raw_002.jpg'),
      ).writeAsBytes([2]);
      await File(
        path.join(sessionDirectory.path, 'session.json'),
      ).writeAsString(
        jsonEncode({
          'id': 'metadata-session',
          'createdTime': '2026-08-10T01:02:03.000Z',
          'pages': [
            {
              'pageNo': 1,
              'rawImageFile': 'raw_002.jpg',
              'createdTime': '2026-08-10T01:02:04.000Z',
              'rotation': 90,
            },
            {
              'pageNo': 2,
              'rawImageFile': 'raw_001.jpg',
              'createdTime': '2026-08-10T01:02:03.000Z',
              'rotation': 0,
            },
          ],
        }),
      );

      final session = (await manager.findRecoverableSessions()).single;

      expect(session.pages.map((page) => path.basename(page.rawImagePath)), [
        'raw_002.jpg',
        'raw_001.jpg',
      ]);
      expect(session.pages.first.rotation, 90);
    },
  );

  test(
    'falls back to raw file recovery when session metadata is corrupt',
    () async {
      final sessionDirectory = Directory(
        path.join(testRoot.path, 'scan_sessions', 'corrupt-metadata-session'),
      );
      await sessionDirectory.create(recursive: true);
      await File(
        path.join(sessionDirectory.path, 'raw_001.jpg'),
      ).writeAsBytes([1]);
      await File(
        path.join(sessionDirectory.path, 'session.json'),
      ).writeAsString('{not valid json');

      final session = (await manager.findRecoverableSessions()).single;

      expect(session.id, 'corrupt-metadata-session');
      expect(session.pages, hasLength(1));
      expect(session.pages.single.rotation, 0);
    },
  );

  test(
    'stores detected document corners and restores them from metadata',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        sessionIdGenerator: () => 'detected-session',
        clock: () => DateTime.utc(2026, 8, 10, 1, 2, 3),
      );
      final capture = await _createCapture(testRoot, 'detected.jpg');

      final page = await manager.addRawCapture(capture.path);

      expect(page.documentSourceWidth, 1000);
      expect(page.documentSourceHeight, 1500);
      expect(page.documentCorners?.topLeft.x, 50);

      const adjustedCorners = DocumentCorners(
        topLeft: DocumentPoint(80, 70),
        topRight: DocumentPoint(920, 70),
        bottomRight: DocumentPoint(900, 1400),
        bottomLeft: DocumentPoint(90, 1400),
      );
      await manager.updateDocumentCornersAt(0, adjustedCorners);

      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
      );
      final recovered = (await manager.findRecoverableSessions()).single;
      expect(recovered.pages.single.documentCorners?.bottomRight.x, 900);
      expect(recovered.pages.single.documentCorners?.bottomRight.y, 1400);
    },
  );

  test('keeps the captured page when document detection throws', () async {
    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _FailingDocumentDetector(),
      sessionIdGenerator: () => 'failed-detection-session',
    );
    final capture = await _createCapture(testRoot, 'undetected.jpg');

    final page = await manager.addRawCapture(capture.path);

    expect(manager.pageCount, 1);
    expect(page.documentCorners, isNull);
    expect(await File(page.rawImagePath).exists(), isTrue);
  });
}

Future<File> _createCapture(Directory root, String name) async {
  final capture = File(path.join(root.path, name));
  return capture.writeAsBytes([1, 2, 3]);
}

class _SuccessfulDocumentDetector implements DocumentDetector {
  const _SuccessfulDocumentDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) async {
    return const DocumentDetectionResult(
      detected: true,
      confidence: 0.9,
      sourceWidth: 1000,
      sourceHeight: 1500,
      corners: DocumentCorners(
        topLeft: DocumentPoint(50, 50),
        topRight: DocumentPoint(950, 50),
        bottomRight: DocumentPoint(950, 1450),
        bottomLeft: DocumentPoint(50, 1450),
      ),
    );
  }
}

class _FailingDocumentDetector implements DocumentDetector {
  const _FailingDocumentDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) {
    throw StateError('Detection failed.');
  }
}
