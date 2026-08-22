import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/home/presentation/scan_home_page.dart';
import 'package:scana/main.dart' as app_main;
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  testWidgets('ScanHomePage constructs without legacy services', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('scana_release_graph_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final manager = app_main.createProductionSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => root,
      ),
      debugMode: false,
    );
    addTearDown(manager.close);

    await tester.pumpWidget(
      MaterialApp(
        home: ScanHomePage(
          sessionManager: manager,
          mlKitDocumentScanner: _CountingScanner(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('스캔 시작'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('startup does not invoke ML Kit scanner', (tester) async {
    final root = Directory.systemTemp.createTempSync('scana_lazy_scan_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final manager = app_main.createProductionSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => root,
      ),
      debugMode: false,
    );
    addTearDown(manager.close);
    final scanner = _CountingScanner();

    await tester.pumpWidget(
      MaterialApp(
        home: ScanHomePage(
          sessionManager: manager,
          mlKitDocumentScanner: scanner,
        ),
      ),
    );
    await tester.pump();

    expect(scanner.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ML Kit launch failure hides native diagnostics from users', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('scana_mlkit_failure_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final manager = app_main.createProductionSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => root,
      ),
      debugMode: false,
    );
    addTearDown(manager.close);
    await tester.runAsync(manager.prepareMlKitScan);
    final scanner = _FailingScanner();

    await tester.pumpWidget(
      MaterialApp(
        home: ScanHomePage(
          sessionManager: manager,
          mlKitDocumentScanner: scanner,
          orientationController: const _NoOpOrientationController(),
        ),
      ),
    );
    await tester.tap(find.text('스캔 시작'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(scanner.calls, 1);
    expect(find.textContaining('ML Kit 스캐너를 시작할 수 없습니다.'), findsOneWidget);
    expect(find.textContaining('code: 14'), findsNothing);
    expect(find.textContaining('stage:'), findsNothing);
    expect(find.textContaining('scanaLine:'), findsNothing);
    expect(find.textContaining('module is preparing'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'single tap and rapid double tap invoke one scan until lifecycle completes',
    (tester) async {
      final root = Directory.systemTemp.createTempSync('scana_single_flight_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final manager = app_main.createProductionSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => root,
        ),
        debugMode: false,
      );
      addTearDown(manager.close);
      await tester.runAsync(manager.prepareMlKitScan);
      final scanner = _BlockingScanner();

      await tester.pumpWidget(
        MaterialApp(
          home: ScanHomePage(
            sessionManager: manager,
            mlKitDocumentScanner: scanner,
            orientationController: const _NoOpOrientationController(),
          ),
        ),
      );
      final startButton = find.byKey(const Key('startMlKitScanButton'));

      await tester.tap(startButton);
      await tester.tap(startButton);
      await tester.pump();

      expect(scanner.calls, 1);
      expect(tester.widget<FilledButton>(startButton).onPressed, isNull);

      scanner.completeNext(const MlKitScanResult.cancelled());
      await tester.pump();
      await tester.pump();

      expect(tester.widget<FilledButton>(startButton).onPressed, isNotNull);
      await tester.tap(startButton);
      await tester.pump();
      expect(scanner.calls, 2);

      scanner.completeNext(const MlKitScanResult.cancelled());
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'release service graph uses unavailable legacy implementations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'scana_release_graph_',
      );
      final manager = app_main.createProductionSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => root,
        ),
        debugMode: false,
      );
      addTearDown(() async {
        manager.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      final target = await manager.prepareMlKitScan();

      expect(target.sessionId, isNotEmpty);
      expect(manager.currentSession, isNotNull);
    },
  );

  test('recovery failure cannot block first Flutter frame', () async {
    final manager = app_main.createProductionSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async =>
            throw const FileSystemException('unavailable'),
      ),
      debugMode: false,
    );
    addTearDown(manager.close);

    final recovered = await app_main.loadRecoverableSessionsSafely(manager);

    expect(recovered, isEmpty);
  });

  test('release configuration hides legacy UI', () {
    expect(
      ProductionScanHomeVisibility.showsLegacyScanner(debugMode: false),
      false,
    );
    expect(
      ProductionScanHomeVisibility.showsLegacyScanner(debugMode: true),
      true,
    );
  });
}

class _CountingScanner implements MlKitDocumentScanner {
  int calls = 0;

  @override
  Future<MlKitScanResult> scan({
    required String sessionId,
    required int startPageNo,
  }) async {
    calls++;
    return const MlKitScanResult.cancelled();
  }
}

class _FailingScanner implements MlKitDocumentScanner {
  int calls = 0;

  @override
  Future<MlKitScanResult> scan({
    required String sessionId,
    required int startPageNo,
  }) async {
    calls++;
    throw const MlKitDocumentScannerException(
      'mlkit_14',
      'module is preparing',
      details: <String, Object?>{
        'exceptionClass': 'com.google.mlkit.common.MlKitException',
        'errorCode': 14,
        'stage': 'get_start_intent',
        'exceptionLine': 'MainActivity.kt:762',
        'exceptionOriginClass': 'com.google.mlkit.ScannerClient',
        'scanaExceptionLine': 'MainActivity.kt:774',
      },
    );
  }
}

class _BlockingScanner implements MlKitDocumentScanner {
  final List<Completer<MlKitScanResult>> _pending = [];
  int calls = 0;

  @override
  Future<MlKitScanResult> scan({
    required String sessionId,
    required int startPageNo,
  }) {
    calls++;
    final completer = Completer<MlKitScanResult>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(MlKitScanResult result) {
    _pending.removeAt(0).complete(result);
  }
}

class _NoOpOrientationController implements ScreenOrientationController {
  const _NoOpOrientationController();

  @override
  Future<void> enterContentScreen() async {}

  @override
  Future<void> enterSingleCamera() async {}

  @override
  Future<void> enterSpreadCamera() async {}

  @override
  Future<void> restoreSystemDefault() async {}
}
