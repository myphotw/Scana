import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_capture_mode.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/page_crop.dart';
import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/services/image_processing/document_detector.dart';
import 'package:scana/services/image_processing/ai_document_segmenter.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/image_processing/page_corrector.dart';
import 'package:scana/services/image_processing/spread_capture_splitter.dart';
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

  test('OCR title suggestion persists and survives session recovery', () async {
    await manager.addRawCapture(
      (await _createCapture(testRoot, 'title-source.jpg')).path,
    );

    await manager.updateSuggestedTitle('사내 품질관리 프로세스 개선안', sourcePageNo: 1);

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
    expect(metadata['suggestedTitle'], '사내 품질관리 프로세스 개선안');
    expect(metadata['ocrSourcePageNo'], 1);

    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
    );
    final recovered = (await manager.findRecoverableSessions()).single;

    expect(recovered.suggestedTitle, '사내 품질관리 프로세스 개선안');
    expect(recovered.ocrSourcePageNo, 1);
  });

  test(
    'deleting the last page keeps the session ready for another capture',
    () async {
      await manager.addRawCapture(
        (await _createCapture(testRoot, 'only-page.jpg')).path,
      );

      await manager.deletePageAt(0);

      expect(manager.currentSession?.id, 'session-uuid');
      expect(manager.pageCount, 0);
      final next = await manager.addRawCapture(
        (await _createCapture(testRoot, 'next-page.jpg')).path,
      );
      expect(next.pageNo, 1);
      expect(manager.currentSession?.id, 'session-uuid');
    },
  );

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
      expect(session.pages.first.correctedImagePath, isNull);
      expect(session.pages.first.correctionStatus, CorrectionStatus.none);
      expect(session.pages.first.correctionType, CorrectionType.perspective);
      expect(session.pages.first.pageBoundary, isNull);
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

  test('recovers interrupted or missing correction output as failed', () async {
    final sessionDirectory = Directory(
      path.join(testRoot.path, 'scan_sessions', 'interrupted-session'),
    );
    await sessionDirectory.create(recursive: true);
    await File(
      path.join(sessionDirectory.path, 'raw_001.jpg'),
    ).writeAsBytes([1]);
    await File(path.join(sessionDirectory.path, 'session.json')).writeAsString(
      jsonEncode({
        'id': 'interrupted-session',
        'createdTime': '2026-08-10T01:02:03.000Z',
        'pages': [
          {
            'pageNo': 1,
            'rawImageFile': 'raw_001.jpg',
            'correctedImageFile': 'corrected_001.jpg',
            'createdTime': '2026-08-10T01:02:04.000Z',
            'rotation': 0,
            'correctionStatus': 'processing',
            'correctionType': 'perspective',
          },
        ],
      }),
    );

    final recovered = (await manager.findRecoverableSessions()).single;

    expect(recovered.pages.single.correctionStatus, CorrectionStatus.failed);
    expect(recovered.pages.single.correctedImagePath, isNull);
    expect(await File(recovered.pages.single.rawImagePath).exists(), isTrue);
  });

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
      expect(page.cropSource, CropSource.highResPaperBoundary);

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
      expect(recovered.pages.single.cropSource, CropSource.manualCorners);
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

  test(
    'stores capture-guide corners and persists user corner priority',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        sessionIdGenerator: () => 'guide-session',
      );
      final capture = await _createCapture(testRoot, 'guide.jpg');
      final page = await manager.addRawCapture(
        capture.path,
        captureGuideRegion: const CaptureGuideRegion(
          left: 0.1,
          top: 0.2,
          right: 0.9,
          bottom: 0.8,
        ),
      );

      expect(page.captureGuideCorners?.topLeft.x, 100);
      expect(page.captureGuideCorners?.topLeft.y, 300);
      expect(page.captureGuideCorners?.bottomRight.x, 900);
      expect(page.captureGuideCorners?.bottomRight.y, 1200);
      expect(page.hasUserAdjustedCorners, isFalse);

      const adjusted = DocumentCorners(
        topLeft: DocumentPoint(80, 80),
        topRight: DocumentPoint(920, 80),
        bottomRight: DocumentPoint(920, 1400),
        bottomLeft: DocumentPoint(80, 1400),
      );
      await manager.updateDocumentCornersAt(0, adjusted);
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
      );

      final recovered =
          (await manager.findRecoverableSessions()).single.pages.single;
      expect(recovered.hasUserAdjustedCorners, isTrue);
      expect(recovered.documentCorners?.topLeft.x, 80);
      expect(recovered.captureGuideCorners?.bottomRight.y, 1200);
    },
  );

  test(
    'capture processing automatically creates a Perspective scan result',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        sessionIdGenerator: () => 'automatic-correction-session',
      );
      final capture = await _createCapture(testRoot, 'automatic.jpg');

      final page = await manager.captureAndProcess(capture.path);

      expect(page.correctionStatus, CorrectionStatus.completed);
      expect(page.correctionType, CorrectionType.perspective);
      expect(page.correctedImagePath, isNotNull);
      expect(await File(page.correctedImagePath!).exists(), isTrue);
    },
  );

  test(
    'retake replaces a page only after the new scan result is confirmed',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        sessionIdGenerator: () => 'retake-session',
      );
      final initialCapture = await _createCapture(testRoot, 'initial.jpg');
      final initial = await manager.captureAndProcess(initialCapture.path);
      final oldRawPath = initial.rawImagePath;
      final oldCorrectedPath = initial.correctedImagePath!;
      final retake = await _createCapture(testRoot, 'retake.jpg');

      final replaced = await manager.replacePageAt(0, retake.path);
      final replacement = manager.currentSession!.pages.single;

      expect(replaced, isTrue);
      expect(manager.pageCount, 1);
      expect(replacement.pageNo, 1);
      expect(replacement.rawImagePath, isNot(oldRawPath));
      expect(replacement.correctedImagePath, isNotNull);
      expect(await File(oldRawPath).exists(), isFalse);
      expect(await File(oldCorrectedPath).exists(), isFalse);
      expect(await File(replacement.rawImagePath).exists(), isTrue);
      expect(await File(replacement.correctedImagePath!).exists(), isTrue);
    },
  );

  test('failed retake leaves the previous confirmed page intact', () async {
    manager.close();
    final storage = AppPrivateSessionStorage(
      appPrivateDirectoryProvider: () async => testRoot,
    );
    manager = ScanSessionManager(
      storage: storage,
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      sessionIdGenerator: () => 'failed-retake-session',
    );
    final initialCapture = await _createCapture(testRoot, 'initial.jpg');
    final initial = await manager.captureAndProcess(initialCapture.path);

    manager.close();
    manager = ScanSessionManager(
      storage: storage,
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _FailingPageCorrector(),
    );
    manager.restoreSession((await manager.findRecoverableSessions()).single);
    final retake = await _createCapture(testRoot, 'failed-retake.jpg');

    final replaced = await manager.replacePageAt(0, retake.path);
    final page = manager.currentSession!.pages.single;

    expect(replaced, isFalse);
    expect(page.rawImagePath, initial.rawImagePath);
    expect(page.correctedImagePath, initial.correctedImagePath);
    expect(await File(initial.rawImagePath).exists(), isTrue);
    expect(await File(initial.correctedImagePath!).exists(), isTrue);
  });

  test('persists and recovers a completed corrected image', () async {
    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      sessionIdGenerator: () => 'correction-session',
      clock: () => DateTime.utc(2026, 8, 10, 1, 2, 3),
    );
    final capture = await _createCapture(testRoot, 'correction.jpg');
    await manager.addRawCapture(capture.path);

    final succeeded = await manager.correctPageAt(
      0,
      CorrectionType.perspective,
    );

    final correctedPath =
        manager.currentSession!.pages.single.correctedImagePath;
    expect(succeeded, isTrue);
    expect(correctedPath, isNotNull);
    expect(path.basename(correctedPath!), 'corrected_001.png');
    expect(await File(correctedPath).exists(), isTrue);
    expect(
      manager.currentSession!.pages.single.correctionStatus,
      CorrectionStatus.completed,
    );

    final metadataFile = File(
      path.join(
        testRoot.path,
        'scan_sessions',
        'correction-session',
        'session.json',
      ),
    );
    final metadata = jsonDecode(await metadataFile.readAsString()) as Map;
    final pageMetadata = (metadata['pages'] as List).single as Map;
    expect(pageMetadata['correctedImageFile'], 'corrected_001.png');
    expect(
      path.isAbsolute(pageMetadata['correctedImageFile'] as String),
      isFalse,
    );
    expect(pageMetadata['correctionStatus'], 'completed');
    expect(pageMetadata['correctionType'], 'perspective');

    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
    );
    final recovered = (await manager.findRecoverableSessions()).single;
    expect(recovered.pages.single.correctedImagePath, correctedPath);
    expect(recovered.pages.single.correctionStatus, CorrectionStatus.completed);
  });

  test('failed retry keeps raw and the previous corrected image', () async {
    manager.close();
    final storage = AppPrivateSessionStorage(
      appPrivateDirectoryProvider: () async => testRoot,
    );
    manager = ScanSessionManager(
      storage: storage,
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      sessionIdGenerator: () => 'retry-session',
    );
    final capture = await _createCapture(testRoot, 'retry.jpg');
    await manager.addRawCapture(capture.path);
    await manager.correctPageAt(0, CorrectionType.perspective);
    final previousPage = manager.currentSession!.pages.single;
    final previousCorrectedPath = previousPage.correctedImagePath!;

    manager.close();
    manager = ScanSessionManager(
      storage: storage,
      pageCorrector: const _FailingPageCorrector(),
    );
    manager.restoreSession((await manager.findRecoverableSessions()).single);
    final succeeded = await manager.correctPageAt(
      0,
      CorrectionType.perspective,
    );
    final failedPage = manager.currentSession!.pages.single;

    expect(succeeded, isFalse);
    expect(failedPage.correctionStatus, CorrectionStatus.failed);
    expect(failedPage.correctionType, CorrectionType.perspective);
    expect(failedPage.correctedImagePath, previousCorrectedPath);
    expect(await File(failedPage.rawImagePath).exists(), isTrue);
    expect(await File(previousCorrectedPath).exists(), isTrue);
  });

  test(
    'curved failure protects the newly generated perspective result',
    () async {
      manager.close();
      final corrector = _CurveStageFailingPageCorrector();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: corrector,
        pageEnhancer: const _SuccessfulPageEnhancer(),
        sessionIdGenerator: () => 'protected-perspective-session',
      );
      final capture = await _createCapture(testRoot, 'book-page.jpg');
      await manager.addRawCapture(capture.path);

      final succeeded = await manager.correctPageAt(0, CorrectionType.curved);
      final page = manager.currentSession!.pages.single;

      expect(succeeded, isFalse);
      expect(corrector.calls, [
        CorrectionType.perspective,
        CorrectionType.curved,
      ]);
      expect(page.correctionStatus, CorrectionStatus.failed);
      expect(page.correctionType, CorrectionType.curved);
      expect(page.correctionFailureReason, 'curve_insufficient_evidence');
      expect(path.basename(page.correctedImagePath!), 'corrected_001.png');
      expect(await File(page.correctedImagePath!).exists(), isTrue);
      expect(await File(page.rawImagePath).exists(), isTrue);
      expect(
        _SuccessfulPageEnhancer.lastSource,
        page.correctedImagePath,
        reason: 'fallback enhancement must use the protected perspective',
      );

      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
      );
      final recovered = (await manager.findRecoverableSessions()).single;
      expect(
        recovered.pages.single.correctedImagePath,
        page.correctedImagePath,
      );
      expect(recovered.pages.single.correctionStatus, CorrectionStatus.failed);
      expect(
        recovered.pages.single.correctionFailureReason,
        'curve_insufficient_evidence',
      );
    },
  );

  test('curved success enhances and recovers the curved revision', () async {
    manager.close();
    _SuccessfulPageEnhancer.lastSource = null;
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      pageEnhancer: const _SuccessfulPageEnhancer(),
      sessionIdGenerator: () => 'curved-enhanced-session',
    );
    await manager.addRawCapture(
      (await _createCapture(testRoot, 'curved-enhanced.jpg')).path,
    );

    expect(await manager.correctPageAt(0, CorrectionType.curved), isTrue);
    final page = manager.currentSession!.pages.single;
    expect(page.correctionType, CorrectionType.curved);
    expect(
      path.basename(page.correctedImagePath!),
      startsWith('corrected_curved_'),
    );
    expect(_SuccessfulPageEnhancer.lastSource, page.correctedImagePath);
    expect(page.displayImagePath, page.enhancedImagePath);

    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
    );
    final recovered =
        (await manager.findRecoverableSessions()).single.pages.single;
    expect(recovered.correctionType, CorrectionType.curved);
    expect(recovered.correctedImagePath, page.correctedImagePath);
    expect(recovered.displayImagePath, page.enhancedImagePath);
  });

  test(
    'page deletion removes raw, correction variants, and pending output',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        pageEnhancer: const _SuccessfulPageEnhancer(),
        sessionIdGenerator: () => 'delete-correction-session',
      );
      final capture = await _createCapture(testRoot, 'delete-correction.jpg');
      await manager.addRawCapture(capture.path);
      final rawPath = manager.currentSession!.pages.single.rawImagePath;
      await manager.correctPageAt(0, CorrectionType.perspective);
      final perspectivePath =
          manager.currentSession!.pages.single.correctedImagePath!;
      await manager.correctPageAt(0, CorrectionType.curved);
      final curvedPath =
          manager.currentSession!.pages.single.correctedImagePath!;
      await manager.enhancePageAt(0, EnhancementMode.grayscale);
      final enhancedPath =
          manager.currentSession!.pages.single.enhancedImagePath!;
      final pendingPath = path.join(
        path.dirname(rawPath),
        '.corrected_001.png.pending.png',
      );
      final enhancementPendingPath = path.join(
        path.dirname(rawPath),
        '.enhanced_bw_001.png.pending.png',
      );
      await File(pendingPath).writeAsBytes([9]);
      await File(enhancementPendingPath).writeAsBytes([9]);

      await manager.deletePageAt(0);

      expect(await File(rawPath).exists(), isFalse);
      expect(await File(perspectivePath).exists(), isFalse);
      expect(await File(curvedPath).exists(), isFalse);
      expect(await File(enhancedPath).exists(), isFalse);
      expect(await File(pendingPath).exists(), isFalse);
      expect(await File(enhancementPendingPath).exists(), isFalse);
      expect(manager.pageCount, 0);
    },
  );

  test(
    'uses stable preview corners when high-resolution confidence is low',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _LowConfidenceDocumentDetector(),
        sessionIdGenerator: () => 'preview-fallback-session',
      );
      final capture = await _createCapture(testRoot, 'preview-fallback.jpg');
      const preview = DocumentCorners(
        topLeft: DocumentPoint(0.1, 0.1),
        topRight: DocumentPoint(0.9, 0.1),
        bottomRight: DocumentPoint(0.9, 0.9),
        bottomLeft: DocumentPoint(0.1, 0.9),
      );
      final previewBoundary = _previewBoundary();

      final page = await manager.addRawCapture(
        capture.path,
        stablePreviewCorners: preview,
        stablePreviewBoundary: previewBoundary,
        captureGuideRegion: const CaptureGuideRegion(
          left: 0.2,
          top: 0.2,
          right: 0.8,
          bottom: 0.8,
        ),
      );

      expect(page.documentCorners!.topLeft.x, 100);
      expect(page.documentCorners!.topLeft.y, 150);
      expect(page.captureGuideCorners!.topLeft.x, 200);
      expect(page.pageBoundary, isNotNull);
      expect(page.pageBoundary!.top, hasLength(3));

      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
      );
      final recovered = (await manager.findRecoverableSessions()).single;
      expect(recovered.pages.single.pageBoundary!.top, hasLength(3));
      expect(recovered.pages.single.pageBoundary!.sourceWidth, 1000);
      expect(
        recovered.pages.single.pageBoundary!.spineSide,
        PageBoundarySide.left,
      );
    },
  );

  test('rotation cycles through all right-angle states', () async {
    final capture = await _createCapture(testRoot, 'rotation-cycle.jpg');
    await manager.addRawCapture(capture.path);

    for (final expected in const [90, 180, 270, 0]) {
      await manager.rotatePageAt(0);
      expect(manager.currentSession!.pages.single.rotation, expected);
    }
  });

  test(
    'keeps the displayed sane live boundary ahead of a different high-resolution candidate',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _BoundaryDocumentDetector(),
        sessionIdGenerator: () => 'high-resolution-boundary-session',
      );
      final capture = await _createCapture(testRoot, 'high-boundary.jpg');

      final page = await manager.addRawCapture(
        capture.path,
        stablePreviewBoundary: _previewBoundary(),
      );

      expect(page.pageBoundary!.top.first.x, 100);
      expect(page.documentCorners!.topLeft.x, 100);
      expect(page.cropSource, CropSource.captureLiveBoundary);
    },
  );

  test('rejects a narrow stable-live boundary before crop fallback', () async {
    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _LowConfidenceDocumentDetector(),
      sessionIdGenerator: () => 'narrow-live-session',
    );
    final capture = await _createCapture(testRoot, 'narrow-live.jpg');
    final narrow = PageBoundary.fromCorners(
      const DocumentCorners(
        topLeft: DocumentPoint(0.4, 0.1),
        topRight: DocumentPoint(0.6, 0.1),
        bottomRight: DocumentPoint(0.6, 0.9),
        bottomLeft: DocumentPoint(0.4, 0.9),
      ),
      sourceWidth: 1,
      sourceHeight: 1,
      confidence: 0.9,
      stability: 1,
      timestamp: DateTime.utc(2026, 8, 11),
    );

    final page = await manager.addRawCapture(
      capture.path,
      stablePreviewBoundary: narrow,
      captureGuideRegion: const CaptureGuideRegion(
        left: 0.2,
        top: 0.2,
        right: 0.8,
        bottom: 0.8,
      ),
    );

    expect(page.pageBoundary, isNull);
    expect(page.documentCorners!.topLeft.x, 200);
    expect(page.documentCorners!.topLeft.y, 300);
  });

  test('curved correction uses the rectified coordinate space', () async {
    manager.close();
    final corrector = _RecordingBoundaryCorrector();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _LowConfidenceDocumentDetector(),
      pageCorrector: corrector,
      sessionIdGenerator: () => 'boundary-curve-session',
    );
    final capture = await _createCapture(testRoot, 'boundary-curve.jpg');
    await manager.addRawCapture(
      capture.path,
      stablePreviewBoundary: _previewBoundary(),
    );

    expect(await manager.correctPageAt(0, CorrectionType.curved), isTrue);
    expect(corrector.boundaries, hasLength(2));
    expect(corrector.boundaries.first, isNotNull);
    expect(corrector.boundaries.last, isNull);
    expect(path.basename(corrector.sourcePaths.last), 'corrected_001.png');
    expect(corrector.sourcePaths.last, isNot(capture.path));
    expect(corrector.boundaryModes.last, PageBoundaryMode.insetFallback);
    expect(corrector.corners.last.topLeft.x, 0);
    expect(corrector.corners.last.topLeft.y, 0);
    expect(corrector.corners.last.bottomRight.x, 899);
    expect(corrector.corners.last.bottomRight.y, 1399);
  });

  test(
    'one spread capture creates left then right independent scan pages',
    () async {
      manager.close();
      manager = _spreadManager(testRoot);
      await manager.setCaptureMode(ScanCaptureMode.spread);
      final capture = await _createCapture(testRoot, 'spread.jpg');

      final pages = await manager.captureAndProcessSpread(capture.path);

      expect(pages.map((page) => page.pageNo), [1, 2]);
      expect(manager.currentSession!.captureMode, ScanCaptureMode.spread);
      expect(pages.map((page) => path.basename(page.rawImagePath)), [
        'raw_001.jpg',
        'raw_002.jpg',
      ]);
      expect(pages.every((page) => page.correctedImagePath != null), isTrue);
      expect(await File(capture.path).exists(), isFalse);
    },
  );

  test('continuous spread captures retain left-to-right page order', () async {
    manager.close();
    manager = _spreadManager(testRoot);
    await manager.setCaptureMode(ScanCaptureMode.spread);

    await manager.captureAndProcessSpread(
      (await _createCapture(testRoot, 'spread_1.jpg')).path,
    );
    await manager.captureAndProcessSpread(
      (await _createCapture(testRoot, 'spread_2.jpg')).path,
    );

    expect(manager.currentSession!.pages.map((page) => page.pageNo), [
      1,
      2,
      3,
      4,
    ]);
    expect(
      manager.currentSession!.pages.map(
        (page) => path.basename(page.rawImagePath),
      ),
      ['raw_001.jpg', 'raw_002.jpg', 'raw_003.jpg', 'raw_004.jpg'],
    );
  });

  test(
    'spread capture passes each ROI side to a spread-aware detector',
    () async {
      final detector = _RecordingSpreadAwareDocumentDetector();
      manager.close();
      manager = _spreadManager(testRoot, detector: detector);
      await manager.setCaptureMode(ScanCaptureMode.spread);

      await manager.captureAndProcessSpread(
        (await _createCapture(testRoot, 'spread-side-policy.jpg')).path,
      );

      expect(detector.pageSides, [
        DocumentPageSide.left,
        DocumentPageSide.right,
      ]);
    },
  );

  test('right detection fallback keeps the left Perspective page', () async {
    manager.close();
    manager = _spreadManager(testRoot, detector: const _RightFailingDetector());
    await manager.setCaptureMode(ScanCaptureMode.spread);

    final pages = await manager.captureAndProcessSpread(
      (await _createCapture(testRoot, 'one-side-failure.jpg')).path,
    );

    expect(pages, hasLength(2));
    expect(pages[0].correctedImagePath, isNotNull);
    expect(pages[0].spreadFallbackUsed, isFalse);
    expect(pages[1].correctedImagePath, isNotNull);
    expect(pages[1].spreadFallbackUsed, isTrue);
    expect(await File(pages[1].rawImagePath).exists(), isTrue);
  });

  test('left detection fallback keeps the right Perspective page', () async {
    manager.close();
    manager = _spreadManager(testRoot, detector: const _LeftFailingDetector());
    await manager.setCaptureMode(ScanCaptureMode.spread);

    final pages = await manager.captureAndProcessSpread(
      (await _createCapture(testRoot, 'left-side-failure.jpg')).path,
    );

    expect(pages, hasLength(2));
    expect(pages[0].correctedImagePath, isNotNull);
    expect(pages[0].spreadFallbackUsed, isTrue);
    expect(pages[1].correctedImagePath, isNotNull);
    expect(pages[1].spreadFallbackUsed, isFalse);
  });

  test('spread fallback usage survives session recovery', () async {
    manager.close();
    manager = _spreadManager(testRoot, detector: const _RightFailingDetector());
    await manager.setCaptureMode(ScanCaptureMode.spread);
    await manager.captureAndProcessSpread(
      (await _createCapture(testRoot, 'recover-fallback.jpg')).path,
    );
    manager.close();

    final recoveryManager = _spreadManager(testRoot);
    addTearDown(recoveryManager.close);
    final recovered = (await recoveryManager.findRecoverableSessions()).single;

    expect(recovered.pages[0].spreadFallbackUsed, isFalse);
    expect(recovered.pages[1].spreadFallbackUsed, isTrue);
    expect(recovered.pages[1].correctedImagePath, isNotNull);
  });

  test('recovers the spread capture mode from session metadata', () async {
    manager.close();
    manager = _spreadManager(testRoot);
    await manager.setCaptureMode(ScanCaptureMode.spread);
    await manager.captureAndProcessSpread(
      (await _createCapture(testRoot, 'recover-spread.jpg')).path,
    );
    manager.close();

    final recoveryManager = _spreadManager(testRoot);
    addTearDown(recoveryManager.close);
    final recovered = (await recoveryManager.findRecoverableSessions()).single;
    recoveryManager.restoreSession(recovered);

    expect(recovered.captureMode, ScanCaptureMode.spread);
    expect(recoveryManager.captureMode, ScanCaptureMode.spread);
    expect(recovered.pages, hasLength(2));
  });

  test('default enhancement mode is scan color', () {
    final page = ScanPage(
      pageNo: 1,
      rawImagePath: '/raw.jpg',
      createdTime: DateTime.utc(2026, 8, 10),
    );

    expect(page.enhancementMode, EnhancementMode.scanColor);
    expect(page.enhancementStatus, EnhancementStatus.none);
    expect(page.displayImagePath, '/raw.jpg');
  });

  test('automatic scan color enhancement persists and recovers', () async {
    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      pageEnhancer: const _SuccessfulPageEnhancer(),
      sessionIdGenerator: () => 'enhancement-session',
    );

    final page = await manager.captureAndProcess(
      (await _createCapture(testRoot, 'enhance.jpg')).path,
    );

    expect(page.correctionStatus, CorrectionStatus.completed);
    expect(page.enhancementMode, EnhancementMode.scanColor);
    expect(page.enhancementStatus, EnhancementStatus.completed);
    expect(path.basename(page.enhancedImagePath!), 'enhanced_001.png');
    expect(page.displayImagePath, page.enhancedImagePath);
    expect(await File(page.rawImagePath).exists(), isTrue);
    expect(await File(page.correctedImagePath!).exists(), isTrue);
    expect(await File(page.enhancedImagePath!).exists(), isTrue);

    final metadata =
        jsonDecode(
              await File(
                path.join(
                  testRoot.path,
                  'scan_sessions',
                  'enhancement-session',
                  'session.json',
                ),
              ).readAsString(),
            )
            as Map<String, dynamic>;
    final pageMetadata = (metadata['pages'] as List).single as Map;
    expect(pageMetadata['enhancedImageFile'], 'enhanced_001.png');
    expect(path.isAbsolute(pageMetadata['enhancedImageFile'] as String), false);
    expect(pageMetadata['enhancementMode'], 'scanColor');
    expect(pageMetadata['enhancementStatus'], 'completed');

    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
    );
    final recovered =
        (await manager.findRecoverableSessions()).single.pages.single;
    expect(recovered.enhancedImagePath, page.enhancedImagePath);
    expect(recovered.enhancementMode, EnhancementMode.scanColor);
    expect(recovered.enhancementStatus, EnhancementStatus.completed);
  });

  test('enhancement mode changes use corrected input and persist', () async {
    manager.close();
    final enhancer = _SuccessfulPageEnhancer();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      pageEnhancer: enhancer,
      sessionIdGenerator: () => 'enhancement-modes',
    );
    await manager.captureAndProcess(
      (await _createCapture(testRoot, 'modes.jpg')).path,
    );
    final correctedPath =
        manager.currentSession!.pages.single.correctedImagePath!;

    expect(
      await manager.enhancePageAt(0, EnhancementMode.originalColor),
      isTrue,
    );
    expect(
      manager.currentSession!.pages.single.displayImagePath,
      correctedPath,
    );
    expect(await manager.enhancePageAt(0, EnhancementMode.grayscale), isTrue);
    expect(enhancer.lastSourceImagePath, correctedPath);
    expect(
      path.basename(manager.currentSession!.pages.single.enhancedImagePath!),
      startsWith('enhanced_grayscale_001'),
    );
    expect(await manager.enhancePageAt(0, EnhancementMode.blackWhite), isTrue);

    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
    );
    final recovered =
        (await manager.findRecoverableSessions()).single.pages.single;
    expect(recovered.enhancementMode, EnhancementMode.blackWhite);
    expect(recovered.enhancementStatus, EnhancementStatus.completed);
    expect(recovered.displayImagePath, recovered.enhancedImagePath);
  });

  test('enhancement failure preserves corrected fallback and page', () async {
    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _SuccessfulPageCorrector(),
      pageEnhancer: const _FailingPageEnhancer(),
      sessionIdGenerator: () => 'enhancement-failure',
    );

    final page = await manager.captureAndProcess(
      (await _createCapture(testRoot, 'failure.jpg')).path,
    );

    expect(page.enhancementStatus, EnhancementStatus.failed);
    expect(page.correctionStatus, CorrectionStatus.completed);
    expect(page.displayImagePath, page.correctedImagePath);
    expect(await File(page.rawImagePath).exists(), isTrue);
    expect(await File(page.correctedImagePath!).exists(), isTrue);
  });

  test(
    'Single capture promotes visibility-safe AI final to production crop',
    () async {
      manager.close();
      final ai = _RecordingAiSegmenter();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        pageEnhancer: const _SuccessfulPageEnhancer(),
        aiDocumentSegmenter: ai,
        sessionIdGenerator: () => 'ai-single',
      );

      final page = await manager.captureAndProcess(
        (await _createCapture(testRoot, 'ai-single.jpg')).path,
      );

      expect(ai.pageSides, [null]);
      expect(page.aiSegmentationResult?.success, isTrue);
      expect(page.aiSegmentationResult?.hasUsableRefinedBoundary, isTrue);
      expect(page.aiSegmentationResult?.refinedCorners?.topLeft.x, 20);
      expect(page.cropSource, CropSource.aiRefined);
      expect(page.documentCorners?.topLeft.x, 20);
    },
  );

  test(
    'Spread capture invokes AI independently in left to right order',
    () async {
      manager.close();
      final ai = _RecordingAiSegmenter();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        pageEnhancer: const _SuccessfulPageEnhancer(),
        spreadCaptureSplitter: const _TestSpreadCaptureSplitter(),
        spreadFallbackCropper: const _TestSpreadFallbackCropper(),
        aiDocumentSegmenter: ai,
        sessionIdGenerator: () => 'ai-spread',
      );

      final pages = await manager.captureAndProcessSpread(
        (await _createCapture(testRoot, 'ai-spread.jpg')).path,
      );

      expect(ai.pageSides, [DocumentPageSide.left, DocumentPageSide.right]);
      expect(pages.map((page) => page.pageNo), [1, 2]);
      expect(pages.every((page) => page.aiSegmentationResult != null), isTrue);
    },
  );

  test(
    'AI failure does not affect correction, Gallery source, or page',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        pageEnhancer: const _SuccessfulPageEnhancer(),
        aiDocumentSegmenter: _RecordingAiSegmenter(fail: true),
        sessionIdGenerator: () => 'ai-failure',
      );

      final page = await manager.captureAndProcess(
        (await _createCapture(testRoot, 'ai-failure.jpg')).path,
      );

      expect(page.aiSegmentationResult?.success, isFalse);
      expect(page.correctionStatus, CorrectionStatus.completed);
      expect(page.enhancementStatus, EnhancementStatus.completed);
      expect(page.cropSource, CropSource.openCvFallback);
      expect(await File(page.displayImagePath).exists(), isTrue);
    },
  );

  test(
    'quick corner apply persists manual source and regenerates scan result',
    () async {
      manager.close();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: const _SuccessfulPageCorrector(),
        pageEnhancer: const _SuccessfulPageEnhancer(),
        sessionIdGenerator: () => 'manual-corners',
      );
      final initial = await manager.captureAndProcess(
        (await _createCapture(testRoot, 'manual.jpg')).path,
      );
      final previousCorrected = initial.correctedImagePath;
      final previousEnhanced = initial.enhancedImagePath;
      const manual = DocumentCorners(
        topLeft: DocumentPoint(70, 80),
        topRight: DocumentPoint(930, 75),
        bottomRight: DocumentPoint(940, 1420),
        bottomLeft: DocumentPoint(60, 1415),
      );

      expect(await manager.applyManualCornersAt(0, manual), isTrue);
      final updated = manager.currentSession!.pages.single;
      expect(updated.hasUserAdjustedCorners, isTrue);
      expect(updated.cropSource, CropSource.manualCorners);
      expect(updated.documentCorners?.topLeft.x, 70);
      expect(updated.correctedImagePath, isNot(previousCorrected));
      expect(updated.enhancedImagePath, isNot(previousEnhanced));
      expect(updated.correctionStatus, CorrectionStatus.completed);
      expect(updated.enhancementStatus, EnhancementStatus.completed);

      final metadataFile = File(
        path.join(
          testRoot.path,
          'scan_sessions',
          'manual-corners',
          'session.json',
        ),
      );
      final metadata = jsonDecode(await metadataFile.readAsString()) as Map;
      final pageMetadata = (metadata['pages'] as List).single as Map;
      expect(pageMetadata['cropSource'], 'manualCorners');

      final recovered = (await manager.findRecoverableSessions()).single;
      expect(recovered.pages.single.cropSource, CropSource.manualCorners);
      expect(recovered.pages.single.hasUserAdjustedCorners, isTrue);
      expect(recovered.pages.single.documentCorners?.bottomRight.y, 1420);
    },
  );

  test('failed quick corner apply restores prior page metadata', () async {
    manager.close();
    manager = ScanSessionManager(
      storage: AppPrivateSessionStorage(
        appPrivateDirectoryProvider: () async => testRoot,
      ),
      documentDetector: const _SuccessfulDocumentDetector(),
      pageCorrector: const _FailingPageCorrector(),
      sessionIdGenerator: () => 'manual-failure',
    );
    final initial = await manager.addRawCapture(
      (await _createCapture(testRoot, 'manual-failure.jpg')).path,
    );
    const attempted = DocumentCorners(
      topLeft: DocumentPoint(200, 200),
      topRight: DocumentPoint(800, 200),
      bottomRight: DocumentPoint(800, 1300),
      bottomLeft: DocumentPoint(200, 1300),
    );

    expect(await manager.applyManualCornersAt(0, attempted), isFalse);
    final restored = manager.currentSession!.pages.single;
    expect(
      restored.documentCorners?.topLeft.x,
      initial.documentCorners?.topLeft.x,
    );
    expect(restored.cropSource, initial.cropSource);
    expect(restored.hasUserAdjustedCorners, isFalse);
  });

  test(
    'capture automatically applies mild curvature and persists pipeline state',
    () async {
      manager.close();
      final corrector = _AutomaticCurvaturePageCorrector(
        CurvatureState.mildCurve,
      );
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: corrector,
        pageEnhancer: const _SuccessfulPageEnhancer(),
        sessionIdGenerator: () => 'automatic-mild',
      );

      final page = await manager.captureAndProcess(
        (await _createCapture(testRoot, 'automatic-mild.jpg')).path,
      );

      expect(corrector.calls, [
        CorrectionType.perspective,
        CorrectionType.curved,
      ]);
      expect(page.perspectiveApplied, isTrue);
      expect(page.curvatureState, CurvatureState.mildCurve);
      expect(page.curvedApplied, isTrue);
      expect(page.curvedConfidence, 0.64);
      expect(page.curvatureMagnitude, 0.004);
      expect(page.enhancementApplied, isTrue);
      expect(page.correctionType, CorrectionType.curved);
      expect(
        path.basename(page.correctedImagePath!),
        startsWith('corrected_curved_'),
      );

      final recovered =
          (await manager.findRecoverableSessions()).single.pages.single;
      expect(recovered.curvatureState, CurvatureState.mildCurve);
      expect(recovered.curvedApplied, isTrue);
      expect(recovered.enhancementApplied, isTrue);
    },
  );

  test(
    'automatic curvature reuses AI paper contour as geometry evidence',
    () async {
      manager.close();
      final corrector = _RecordingBoundaryCorrector();
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        aiDocumentSegmenter: _RecordingAiSegmenter(),
        pageCorrector: corrector,
        pageEnhancer: const _SuccessfulPageEnhancer(),
        sessionIdGenerator: () => 'automatic-contour',
      );

      await manager.captureAndProcess(
        (await _createCapture(testRoot, 'automatic-contour.jpg')).path,
      );

      expect(corrector.boundaries.length, 2);
      expect(corrector.boundaryModes.last, PageBoundaryMode.detected);
      expect(corrector.boundaries.last, isNotNull);
      expect(corrector.boundaries.last!.top.length, greaterThan(3));
      expect(corrector.boundaries.last!.bottom.length, greaterThan(3));
      expect(corrector.corners.last.topLeft.x, 20);
      final recovered =
          (await manager.findRecoverableSessions()).single.pages.single;
      expect(recovered.aiSegmentationResult!.paperContour, isNotEmpty);
    },
  );

  test(
    'flat and unreliable curvature keep Perspective as normal success',
    () async {
      for (final state in [CurvatureState.flat, CurvatureState.unreliable]) {
        manager.close();
        manager = ScanSessionManager(
          storage: AppPrivateSessionStorage(
            appPrivateDirectoryProvider: () async => testRoot,
          ),
          documentDetector: const _SuccessfulDocumentDetector(),
          pageCorrector: _AutomaticCurvaturePageCorrector(state),
          pageEnhancer: const _SuccessfulPageEnhancer(),
          sessionIdGenerator: () => 'automatic-${state.name}',
        );

        final page = await manager.captureAndProcess(
          (await _createCapture(testRoot, '${state.name}.jpg')).path,
        );

        expect(page.correctionStatus, CorrectionStatus.completed);
        expect(page.correctionType, CorrectionType.perspective);
        expect(page.perspectiveApplied, isTrue);
        expect(page.curvatureState, state);
        expect(page.curvedApplied, isFalse);
        expect(page.enhancementStatus, EnhancementStatus.completed);
        expect(page.enhancementApplied, isTrue);
        expect(
          path.basename(page.correctedImagePath!),
          startsWith('corrected_'),
        );
      }
    },
  );

  test(
    'Quick Corner reruns automatic curvature without replacing manual corners',
    () async {
      manager.close();
      final corrector = _AutomaticCurvaturePageCorrector(
        CurvatureState.strongCurve,
      );
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: corrector,
        pageEnhancer: const _SuccessfulPageEnhancer(),
        sessionIdGenerator: () => 'manual-auto-curve',
      );
      await manager.captureAndProcess(
        (await _createCapture(testRoot, 'manual-auto-curve.jpg')).path,
      );
      const manual = DocumentCorners(
        topLeft: DocumentPoint(80, 90),
        topRight: DocumentPoint(920, 90),
        bottomRight: DocumentPoint(930, 1410),
        bottomLeft: DocumentPoint(70, 1410),
      );

      expect(await manager.applyManualCornersAt(0, manual), isTrue);
      final page = manager.currentSession!.pages.single;
      expect(page.documentCorners?.topLeft.x, manual.topLeft.x);
      expect(page.documentCorners?.bottomRight.y, manual.bottomRight.y);
      expect(page.cropSource, CropSource.manualCorners);
      expect(page.curvatureState, CurvatureState.strongCurve);
      expect(page.curvedApplied, isTrue);
      expect(page.enhancementApplied, isTrue);
      expect(
        corrector.calls.where((type) => type == CorrectionType.curved).length,
        2,
      );
    },
  );

  test(
    'Spread runs the full automatic pipeline independently left to right',
    () async {
      manager.close();
      final corrector = _AutomaticCurvaturePageCorrector(
        CurvatureState.strongCurve,
      );
      manager = ScanSessionManager(
        storage: AppPrivateSessionStorage(
          appPrivateDirectoryProvider: () async => testRoot,
        ),
        documentDetector: const _SuccessfulDocumentDetector(),
        pageCorrector: corrector,
        pageEnhancer: const _SuccessfulPageEnhancer(),
        spreadCaptureSplitter: const _TestSpreadCaptureSplitter(),
        spreadFallbackCropper: const _TestSpreadFallbackCropper(),
        sessionIdGenerator: () => 'spread-auto-curve',
      );

      final pages = await manager.captureAndProcessSpread(
        (await _createCapture(testRoot, 'spread-auto-curve.jpg')).path,
      );

      expect(pages.map((page) => page.pageNo), [1, 2]);
      expect(corrector.calls, [
        CorrectionType.perspective,
        CorrectionType.curved,
        CorrectionType.perspective,
        CorrectionType.curved,
      ]);
      expect(pages.every((page) => page.curvedApplied), isTrue);
      expect(pages.every((page) => page.enhancementApplied), isTrue);
    },
  );
}

ScanSessionManager _spreadManager(
  Directory root, {
  DocumentDetector detector = const _SuccessfulDocumentDetector(),
  SpreadFallbackCropper fallbackCropper = const _TestSpreadFallbackCropper(),
}) => ScanSessionManager(
  storage: AppPrivateSessionStorage(
    appPrivateDirectoryProvider: () async => root,
  ),
  documentDetector: detector,
  pageCorrector: const _SuccessfulPageCorrector(),
  pageEnhancer: const _SuccessfulPageEnhancer(),
  spreadCaptureSplitter: const _TestSpreadCaptureSplitter(),
  spreadFallbackCropper: fallbackCropper,
  sessionIdGenerator: () => 'session-uuid',
  clock: () => DateTime.utc(2026, 8, 10, 1, 2, 3),
);

PageBoundary _previewBoundary() => PageBoundary(
  top: const [
    DocumentPoint(0.1, 0.1),
    DocumentPoint(0.5, 0.12),
    DocumentPoint(0.9, 0.1),
  ],
  right: const [
    DocumentPoint(0.9, 0.1),
    DocumentPoint(0.91, 0.5),
    DocumentPoint(0.9, 0.9),
  ],
  bottom: const [
    DocumentPoint(0.9, 0.9),
    DocumentPoint(0.5, 0.88),
    DocumentPoint(0.1, 0.9),
  ],
  left: const [
    DocumentPoint(0.1, 0.9),
    DocumentPoint(0.09, 0.5),
    DocumentPoint(0.1, 0.1),
  ],
  confidence: 0.8,
  stability: 1,
  sourceWidth: 1,
  sourceHeight: 1,
  timestamp: DateTime.utc(2026, 8, 10),
  spineSide: PageBoundarySide.left,
);

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

class _RecordingAiSegmenter implements AiDocumentSegmenter {
  _RecordingAiSegmenter({this.fail = false});

  final bool fail;
  final List<DocumentPageSide?> pageSides = [];

  @override
  Future<AiDocumentModelInfo?> getModelInfo() async => null;

  @override
  Future<AiDocumentSegmentationResult> segment(
    String imagePath, {
    DocumentPageSide? pageSide,
    DocumentCorners? openCvCorners,
    DocumentCorners? expectedGuideCorners,
    String? debugOutputDirectory,
    required String debugStem,
  }) async {
    pageSides.add(pageSide);
    return AiDocumentSegmentationResult(
      success: !fail,
      modelVersion: 'test',
      modelLoadMs: 1,
      preprocessMs: 2,
      inferenceTimeMs: 3,
      postprocessMs: 4,
      totalMs: 10,
      sourceWidth: 1000,
      sourceHeight: 1500,
      maskWidth: 256,
      maskHeight: 256,
      confidence: fail ? null : 0.9,
      maskCoverage: fail ? 0 : 0.7,
      pageSide: pageSide?.name ?? 'single',
      corners: fail ? null : openCvCorners,
      refinementAttempted: !fail,
      refinementAccepted: !fail,
      refinedCorners: fail
          ? null
          : const DocumentCorners(
              topLeft: DocumentPoint(20, 20),
              topRight: DocumentPoint(980, 20),
              bottomRight: DocumentPoint(980, 1480),
              bottomLeft: DocumentPoint(20, 1480),
            ),
      paperContour: fail
          ? const []
          : const [
              DocumentPoint(20, 20),
              DocumentPoint(260, 24),
              DocumentPoint(500, 28),
              DocumentPoint(740, 24),
              DocumentPoint(980, 20),
              DocumentPoint(982, 380),
              DocumentPoint(984, 760),
              DocumentPoint(982, 1120),
              DocumentPoint(980, 1480),
              DocumentPoint(740, 1476),
              DocumentPoint(500, 1470),
              DocumentPoint(260, 1476),
              DocumentPoint(20, 1480),
              DocumentPoint(18, 1120),
              DocumentPoint(16, 760),
              DocumentPoint(18, 380),
            ],
      finalCorners: fail
          ? null
          : const DocumentCorners(
              topLeft: DocumentPoint(20, 20),
              topRight: DocumentPoint(980, 20),
              bottomRight: DocumentPoint(980, 1480),
              bottomLeft: DocumentPoint(20, 1480),
            ),
      finalSource: fail ? null : AiFinalBoundarySource.refined,
      totalRefineMs: fail ? 0 : 5,
      rawAreaRatio: fail ? 0 : 0.84,
      refinedAreaRatio: fail ? 0 : 0.93,
      aiContainmentRatio: fail ? 0 : 0.99,
      areaExpansionRatio: fail ? 1 : 1.1,
      paperTransitionScore: fail ? 0 : 0.8,
      mainPageOwnershipScore: fail ? 0 : 0.9,
      outerEnvelopeConsistency: fail ? 0 : 0.85,
      edgeContinuity: fail ? 0 : 0.88,
      adjacentPagePenalty: fail ? 0 : 0.08,
      occlusionPenalty: fail ? 0 : 0.12,
      refinedConfidence: fail ? 0 : 0.87,
      refinedStatus: fail
          ? AiRefinedBoundaryStatus.rawFallback
          : AiRefinedBoundaryStatus.accepted,
      failureReason: fail ? 'test_failure' : null,
    );
  }
}

class _RecordingSpreadAwareDocumentDetector
    implements SpreadAwareDocumentDetector {
  final List<DocumentPageSide> pageSides = [];

  @override
  Future<DocumentDetectionResult> detect(String imagePath) =>
      const _SuccessfulDocumentDetector().detect(imagePath);

  @override
  Future<DocumentDetectionResult> detectForPage(
    String imagePath, {
    required DocumentPageSide pageSide,
  }) {
    pageSides.add(pageSide);
    return const _SuccessfulDocumentDetector().detect(imagePath);
  }
}

class _LowConfidenceDocumentDetector implements DocumentDetector {
  const _LowConfidenceDocumentDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) async {
    return const DocumentDetectionResult(
      detected: false,
      confidence: 0.2,
      sourceWidth: 1000,
      sourceHeight: 1500,
    );
  }
}

class _BoundaryDocumentDetector implements DocumentDetector {
  const _BoundaryDocumentDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) async {
    final boundary = PageBoundary(
      top: const [
        DocumentPoint(50, 50),
        DocumentPoint(500, 65),
        DocumentPoint(950, 50),
      ],
      right: const [
        DocumentPoint(950, 50),
        DocumentPoint(955, 750),
        DocumentPoint(950, 1450),
      ],
      bottom: const [
        DocumentPoint(950, 1450),
        DocumentPoint(500, 1435),
        DocumentPoint(50, 1450),
      ],
      left: const [
        DocumentPoint(50, 1450),
        DocumentPoint(45, 750),
        DocumentPoint(50, 50),
      ],
      confidence: 0.9,
      stability: 0,
      sourceWidth: 1000,
      sourceHeight: 1500,
      timestamp: DateTime.utc(2026, 8, 10),
    );
    return DocumentDetectionResult(
      detected: true,
      confidence: 0.9,
      sourceWidth: 1000,
      sourceHeight: 1500,
      corners: boundary.toDocumentCorners(),
      boundary: boundary,
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

class _RightFailingDetector implements DocumentDetector {
  const _RightFailingDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) {
    if (path.basename(imagePath) == 'raw_002.jpg') {
      return Future.value(
        const DocumentDetectionResult(
          detected: false,
          confidence: 0,
          sourceWidth: 0,
          sourceHeight: 0,
        ),
      );
    }
    return const _SuccessfulDocumentDetector().detect(imagePath);
  }
}

class _LeftFailingDetector implements DocumentDetector {
  const _LeftFailingDetector();

  @override
  Future<DocumentDetectionResult> detect(String imagePath) {
    if (path.basename(imagePath) == 'raw_001.jpg') {
      return Future.value(
        const DocumentDetectionResult(
          detected: false,
          confidence: 0,
          sourceWidth: 1000,
          sourceHeight: 1500,
        ),
      );
    }
    return const _SuccessfulDocumentDetector().detect(imagePath);
  }
}

class _TestSpreadCaptureSplitter implements SpreadCaptureSplitter {
  const _TestSpreadCaptureSplitter();

  @override
  Future<SpreadCaptureParts> split(String capturedImagePath) async {
    final source = File(capturedImagePath);
    final left = File('$capturedImagePath.left.jpg');
    final right = File('$capturedImagePath.right.jpg');
    await source.copy(left.path);
    await source.copy(right.path);
    return SpreadCaptureParts(
      leftImagePath: left.path,
      rightImagePath: right.path,
    );
  }
}

class _TestSpreadFallbackCropper implements SpreadFallbackCropper {
  const _TestSpreadFallbackCropper();

  @override
  Future<void> crop({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentPageSide pageSide,
  }) async {
    await File(outputImagePath).writeAsBytes([9, 8, 7]);
  }
}

class _SuccessfulPageCorrector implements PageCorrector {
  const _SuccessfulPageCorrector();

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

class _AutomaticCurvaturePageCorrector implements PageCorrector {
  _AutomaticCurvaturePageCorrector(this.state);

  final CurvatureState state;
  final List<CorrectionType> calls = [];

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) async {
    calls.add(type);
    if (type == CorrectionType.perspective) {
      await File(outputImagePath).writeAsBytes([4, 5, 6]);
      return const PageCorrectionResult(outputWidth: 900, outputHeight: 1400);
    }
    if (state == CurvatureState.flat || state == CurvatureState.unreliable) {
      throw PageCorrectionFailure(
        state == CurvatureState.flat
            ? CorrectionOutcome.nearlyFlat
            : CorrectionOutcome.lowConfidence,
        null,
        state == CurvatureState.flat
            ? 'curve_nearly_flat'
            : 'curve_low_confidence',
        <String, Object>{
          'curvatureState': state.name,
          'curvatureMagnitude': state == CurvatureState.flat ? 0.0008 : 0.004,
          'confidence': state == CurvatureState.flat ? 0.72 : 0.42,
          'coverage': 0.65,
          'consistency': state == CurvatureState.flat ? 0.8 : 0.3,
          'evidenceCount': 3,
          'rejectReason': state == CurvatureState.flat
              ? 'curvature_too_small'
              : 'evidence_unreliable',
          'detectMs': 12,
        },
      );
    }
    await File(outputImagePath).writeAsBytes([7, 8, 9]);
    return PageCorrectionResult(
      outputWidth: 900,
      outputHeight: 1400,
      diagnostics: <String, Object>{
        'curvatureState': state.name,
        'curvatureMagnitude': state == CurvatureState.mildCurve ? 0.004 : 0.012,
        'confidence': state == CurvatureState.mildCurve ? 0.64 : 0.78,
        'coverage': 0.72,
        'candidateScore': 0.8,
        'consistency': 0.84,
        'evidenceCount': 4,
        'deformationStrength': state == CurvatureState.mildCurve ? 0.55 : 1.0,
        'perspectiveStraightness': 0.7,
        'curvedStraightness': 0.73,
        'detectMs': 14,
        'dewarpMs': 18,
      },
    );
  }
}

class _SuccessfulPageEnhancer implements PageEnhancer {
  const _SuccessfulPageEnhancer();

  static String? lastSource;

  String? get lastSourceImagePath => lastSource;

  @override
  Future<PageEnhancementResult> enhance({
    required String sourceImagePath,
    required String outputImagePath,
    required EnhancementMode mode,
  }) async {
    lastSource = sourceImagePath;
    await File(outputImagePath).writeAsBytes([10, 11, 12]);
    return const PageEnhancementResult(
      outputWidth: 900,
      outputHeight: 1400,
      processingMilliseconds: 4,
    );
  }
}

class _FailingPageEnhancer implements PageEnhancer {
  const _FailingPageEnhancer();

  @override
  Future<PageEnhancementResult> enhance({
    required String sourceImagePath,
    required String outputImagePath,
    required EnhancementMode mode,
  }) {
    throw StateError('Enhancement failed.');
  }
}

class _FailingPageCorrector implements PageCorrector {
  const _FailingPageCorrector();

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) {
    throw StateError('Correction failed.');
  }
}

class _CurveStageFailingPageCorrector implements PageCorrector {
  final List<CorrectionType> calls = [];

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) async {
    calls.add(type);
    if (type == CorrectionType.curved) {
      throw const PageCorrectionFailure(
        CorrectionOutcome.lowConfidence,
        'Stable page curvature was not found.',
        'curve_insufficient_evidence',
        {
          'evidenceCount': 1,
          'minimumEvidenceCount': 2,
          'rejectionReason': 'insufficient_evidence',
        },
      );
    }
    await File(outputImagePath).writeAsBytes([7, 8, 9]);
    return const PageCorrectionResult(outputWidth: 900, outputHeight: 1400);
  }
}

class _RecordingBoundaryCorrector implements PageCorrector {
  final List<PageBoundary?> boundaries = [];
  final List<String> sourcePaths = [];
  final List<String> outputPaths = [];
  final List<PageBoundaryMode> boundaryModes = [];
  final List<DocumentCorners> corners = [];

  @override
  Future<PageCorrectionResult> correct({
    required String sourceImagePath,
    required String outputImagePath,
    required DocumentCorners corners,
    required CorrectionType type,
    required PageBoundaryMode boundaryMode,
    PageBoundary? pageBoundary,
  }) async {
    boundaries.add(pageBoundary);
    sourcePaths.add(sourceImagePath);
    outputPaths.add(outputImagePath);
    boundaryModes.add(boundaryMode);
    this.corners.add(corners);
    await File(outputImagePath).writeAsBytes([1, 2, 3]);
    return const PageCorrectionResult(outputWidth: 900, outputHeight: 1400);
  }
}
