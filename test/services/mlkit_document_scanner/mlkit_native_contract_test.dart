import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'android/app/src/main/kotlin/com/myphotw/scana/MainActivity.kt',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('native scanner uses the required JPEG-only FULL options', () {
    expect(source, contains('.setGalleryImportAllowed(false)'));
    expect(source, contains('.setPageLimit(20)'));
    expect(
      source,
      contains(
        '.setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)',
      ),
    );
    expect(
      source,
      contains('.setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)'),
    );
    expect(source, contains('options_build_start'));
    expect(
      source,
      contains('val options = GmsDocumentScannerOptions.Builder()'),
    );
    expect(source, contains('optionsNonNull=true'));
    expect(source, contains(r'optionsClass=${options.javaClass.name}'));
    expect(
      source,
      contains(r'optionsIdentity=${System.identityHashCode(options)}'),
    );
  });

  test('scanner client and start intent stages are independently recorded', () {
    expect(source, contains('get_client_start'));
    expect(
      source,
      contains('val scanner = createOfficialSampleScannerClient { options ->'),
    );
    expect(source, contains('return GmsDocumentScanning.getClient(options)'));
    expect(source, contains('get_client_success'));
    expect(source, contains('get_start_intent_start'));
    expect(source, contains('scanner.getStartScanIntent(this@MainActivity)'));
    expect(source, contains('get_start_intent_task_created'));
    expect(source, contains('listener_registration_success'));
  });

  test('native result copies URI bytes without decode and re-encode', () {
    expect(source, contains('contentResolver.openInputStream(page.imageUri)'));
    expect(source, contains('input.copyTo(output)'));
    expect(source, contains('inJustDecodeBounds = true'));
    expect(source, isNot(contains('.compress(')));
    expect(source, contains('File(filesDir, "scan_sessions")'));
    expect(source, contains('"mlkit"'));
  });

  test('native activity result takes and completes each callback once', () {
    expect(source, contains('resetMlKitScan('));
    expect(source, contains('mlkit_scan_in_progress'));
    expect(source, contains('result_ignored no_pending_request'));
  });

  test('native scanner models idle preparing active processing lifecycle', () {
    expect(
      source,
      contains('private var mlKitScanState = MlKitScanState.IDLE'),
    );
    expect(source, contains('mlKitScanState = MlKitScanState.PREPARING'));
    expect(source, contains('mlKitScanState = MlKitScanState.ACTIVE'));
    expect(
      source,
      contains('mlKitScanState = MlKitScanState.PROCESSING_RESULT'),
    );
    expect(source, contains('mlKitScanState = MlKitScanState.IDLE'));
  });

  test('synchronous and asynchronous launch failures reset native state', () {
    expect(
      source,
      contains(
        '} catch (error: Throwable) {\n'
        '            failMlKitLaunch(request, error, preparationStage)\n'
        '        }',
      ),
    );
    expect(
      source,
      contains('resetMlKitScan(request, reason = "launch_error")'),
    );
    expect(source, contains('.addOnFailureListener'));
  });

  test('cancel success and result error each reset native state', () {
    expect(source, contains('resetMlKitScan(pending, reason = "cancel")'));
    expect(source, contains('resetMlKitScan(pending, reason = "success")'));
    expect(
      source,
      contains('resetMlKitScan(pending, reason = "result_error")'),
    );
  });

  test('native guard remains active and a reset permits the next scan', () {
    expect(
      source,
      contains(
        'mlKitScanState != MlKitScanState.IDLE || pendingMlKitScan != null',
      ),
    );
    expect(source, contains('pendingMlKitScan = null'));
    expect(source, contains('mlKitScanState = MlKitScanState.IDLE'));
  });

  test('release and debug share lifecycle code and lifecycle diagnostics', () {
    expect(source, isNot(contains('if (isDebuggable) startMlKitScan')));
    expect(source, contains('native_startScan_received'));
    expect(source, contains('startScan_rejected_already_running'));
    expect(source, contains('getStartScanIntent_success'));
    expect(source, contains('getStartScanIntent_failure'));
    expect(source, contains('scanner_activity_launched'));
    expect(source, contains('result_received'));
    expect(source, contains('scan_state_reset'));
  });

  test('native scanner launch failure preserves actionable diagnostics', () {
    expect(source, contains('.addOnFailureListener'));
    expect(source, contains('(error as? MlKitException)?.errorCode'));
    expect(source, contains('"exceptionClass" to error.javaClass.name'));
    expect(source, contains('"causeClass" to error.cause?.javaClass?.name'));
    expect(
      source,
      contains('isGooglePlayServicesAvailable(this@MainActivity)'),
    );
    expect(source, contains('getErrorString(googlePlayServicesStatus)'));
    expect(source, contains('"googlePlayServicesVersionCode"'));
    expect(source, contains('"buildMode"'));
    expect(source, contains('"packageName" to packageName'));
    expect(source, contains('"versionCode"'));
    expect(source, contains('"versionName"'));
    expect(source, contains('"stage" to stage'));
    expect(source, contains('"exceptionLine"'));
    expect(source, contains('"exceptionOriginClass"'));
    expect(source, contains('"scanaExceptionLine"'));
    expect(source, contains('"requestId" to requestId'));
    expect(source, contains('"scannerState" to scannerState'));
    expect(source, contains('[MLKIT_SCANNER_FAILURE]'));
    expect(source, contains('scana_mlkit_scanner.log'));
    expect(source, contains('details,'));
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      manifest,
      contains('<package android:name="com.google.android.gms" />'),
    );
  });

  test('best effort diagnostics cannot abort scanner failure delivery', () {
    final failure = source.indexOf('private fun failMlKitLaunch(');
    final diagnostics = source.indexOf(
      'private fun mlKitLaunchFailureDetails(',
    );
    final diagnosticsEnd = source.indexOf(
      'private fun android.content.pm.PackageInfo',
      diagnostics,
    );
    final failurePath = source.substring(failure, diagnostics);
    final diagnosticsPath = source.substring(diagnostics, diagnosticsEnd);
    expect(failure, greaterThan(0));
    expect(diagnostics, greaterThan(0));
    expect(failurePath, contains('mlKitLaunchFailureDetails('));
    expect(failurePath, contains('pending.result.error('));
    expect(diagnosticsPath, contains('runCatching'));
    expect(diagnosticsPath, contains('diagnostics_collection_failure'));
  });

  test(
    'scanner preparation has no force unwrap or release-only nullable path',
    () {
      final start = source.indexOf('private fun startMlKitScan(');
      final end = source.indexOf('private fun markMlKitScannerActive(', start);
      final preparation = source.substring(start, end);
      expect(preparation, isNot(contains('!!')));
      expect(preparation, isNot(contains('lateinit')));
      expect(preparation, isNot(contains('BuildConfig.DEBUG')));
      expect(preparation, isNot(contains('!BuildConfig.DEBUG')));
    },
  );

  test('ML Kit scanner and OCR clients are lazy after app startup', () {
    final scanMethod = source.indexOf('private fun startMlKitScan(');
    final scannerClient = source.indexOf(
      'GmsDocumentScanning.getClient(options)',
    );
    expect(scanMethod, greaterThan(0));
    expect(scannerClient, greaterThan(scanMethod));
    expect(
      source,
      isNot(contains('localOcrService = AndroidLocalOcrService()')),
    );
    expect(source, contains('private fun localOcrService()'));
    expect(source, contains('val service = localOcrService()'));
  });

  test('native startup records configure failures without eager engines', () {
    expect(source, contains('startupLog("onCreate_begin")'));
    expect(
      source,
      contains('startupLog("configureFlutterEngine_failed", error)'),
    );
    expect(source, contains('File(directory, "scana_native_startup.log")'));
    expect(source, isNot(contains('OpenCVLoader.initLocal()')));
  });

  test('production release explicitly disables minify and resource shrink', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(gradle, contains('isMinifyEnabled = false'));
    expect(gradle, contains('isShrinkResources = false'));
    expect(File('android/app/proguard-rules.pro').existsSync(), false);
    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(
      File(
        'android/app/src/main/res/mipmap-anydpi/ic_launcher.xml',
      ).existsSync(),
      true,
    );
    expect(
      File(
        'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
      ).existsSync(),
      true,
    );
  });

  test(
    'production Home opens Gallery only after imported pages are registered',
    () {
      final flutterSource = File(
        'lib/features/home/presentation/scan_home_page.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      expect(flutterSource, contains('case MlKitScanWorkflowStatus.imported:'));
      expect(flutterSource, contains('await _openGallery();'));
    },
  );

  test(
    'application starts on one automatic ML Kit scan action without custom camera',
    () {
      final appSource = File(
        'lib/app.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final mainSource = File(
        'lib/main.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final homeSource = File(
        'lib/features/home/presentation/scan_home_page.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');

      expect(appSource, contains('home: ScanHomePage('));
      expect(mainSource, isNot(contains('CameraSession.initializeDefault()')));
      expect(homeSource, contains('await _workflow.run()'));
      expect(homeSource, contains("label: const Text('스캔 시작')"));
      expect(homeSource, isNot(contains('ScanCaptureMode.single')));
      expect(homeSource, isNot(contains('ScanCaptureMode.spread')));
    },
  );
}
