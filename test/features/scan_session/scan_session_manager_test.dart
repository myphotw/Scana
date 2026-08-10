import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/services/storage/temporary_session_storage.dart';

void main() {
  late Directory testRoot;
  late ScanSessionManager manager;

  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('scana_session_test_');
    manager = ScanSessionManager(
      storage: AppTemporarySessionStorage(
        temporaryDirectoryProvider: () async => testRoot,
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

    final expectedDirectory = path.join(testRoot.path, 'temp', 'session-uuid');
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
  });

  test('cancel deletes the current temporary session', () async {
    final capture = await _createCapture(testRoot, 'capture.jpg');
    await manager.addRawCapture(capture.path);
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'temp', 'session-uuid'),
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
          path.join(testRoot.path, 'temp', 'session-uuid'),
        ).exists(),
        isFalse,
      );
    },
  );

  test('closing the manager keeps the temporary session', () async {
    final capture = await _createCapture(testRoot, 'capture.jpg');
    await manager.addRawCapture(capture.path);
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'temp', 'session-uuid'),
    );

    manager.close();

    expect(await sessionDirectory.exists(), isTrue);
  });
}

Future<File> _createCapture(Directory root, String name) async {
  final capture = File(path.join(root.path, name));
  return capture.writeAsBytes([1, 2, 3]);
}
