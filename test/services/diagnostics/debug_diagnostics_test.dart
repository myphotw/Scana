import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/services/diagnostics/debug_diagnostics.dart';

void main() {
  test('debug diagnostics persist events, errors, and navigator changes', () {
    final directory = Directory.systemTemp.createTempSync(
      'scana_debug_diagnostics_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final logFile = File('${directory.path}${Platform.pathSeparator}scana.log');
    final diagnostics = DebugDiagnostics.forTesting(logFile);
    final observer = DebugNavigatorObserver(diagnostics: diagnostics);
    final firstRoute = MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/first'),
      builder: (_) => const SizedBox.shrink(),
    );
    final secondRoute = MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/second'),
      builder: (_) => const SizedBox.shrink(),
    );

    diagnostics.log('PDF_FLOW', 'filename_open');
    diagnostics.recordFlutterError(
      FlutterErrorDetails(
        exception: StateError('diagnostic failure'),
        stack: StackTrace.fromString('scana_test_stack'),
        library: 'scana test',
      ),
    );
    diagnostics.recordAsyncError(
      ArgumentError('async failure'),
      StackTrace.fromString('scana_async_stack'),
    );
    diagnostics.didChangeAppLifecycleState(AppLifecycleState.paused);
    observer.didPush(firstRoute, null);
    observer.didPush(secondRoute, firstRoute);
    observer.didPop(secondRoute, firstRoute);

    final contents = logFile.readAsStringSync();
    expect(contents, contains('[PDF_FLOW]'));
    expect(contents, contains('filename_open'));
    expect(contents, contains('[FLUTTER_ERROR]'));
    expect(contents, contains('scana_test_stack'));
    expect(contents, contains('[PLATFORM_ERROR]'));
    expect(contents, contains('scana_async_stack'));
    expect(contents, contains('app_paused'));
    expect(contents, contains('didPush'));
    expect(contents, contains('didPop'));
    expect(contents, contains('/second'));
  });

  testWidgets('debug log export passes the persistent log to native SAF', (
    tester,
  ) async {
    const channel = MethodChannel('com.myphotw.scana/debug_diagnostics');
    final directory = Directory.systemTemp.createTempSync(
      'scana_debug_export_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final logFile = File('${directory.path}${Platform.pathSeparator}scana.log')
      ..writeAsStringSync('persisted diagnostic');
    final diagnostics = DebugDiagnostics.forTesting(logFile);
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return <String, dynamic>{'exported': true};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(await diagnostics.exportLog(), isTrue);
    expect(receivedCall?.method, 'exportDebugLog');
    expect(receivedCall?.arguments['logPath'], logFile.path);
    expect(receivedCall?.arguments['suggestedName'], endsWith('.txt'));
  });
}
