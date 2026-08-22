import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class DebugDiagnostics with WidgetsBindingObserver {
  DebugDiagnostics._();

  @visibleForTesting
  DebugDiagnostics.forTesting(File logFile) {
    _logFile = logFile;
    _installed = true;
  }

  static final DebugDiagnostics instance = DebugDiagnostics._();
  static const _channel = MethodChannel('com.myphotw.scana/debug_diagnostics');

  File? _logFile;
  String _currentRoute = 'uninitialized';
  AppLifecycleState? _lifecycleState;
  FlutterExceptionHandler? _previousFlutterErrorHandler;
  ErrorCallback? _previousPlatformErrorHandler;
  bool _installed = false;

  String? get logPath => _logFile?.path;
  String get currentRoute => _currentRoute;
  AppLifecycleState? get lifecycleState => _lifecycleState;

  Future<void> initialize() async {
    if (_installed) return;
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final diagnosticsDirectory = Directory(
        '${supportDirectory.path}${Platform.pathSeparator}startup',
      );
      await diagnosticsDirectory.create(recursive: true);
      _logFile = File(
        '${diagnosticsDirectory.path}${Platform.pathSeparator}scana_startup.log',
      );
    } on Object catch (error) {
      debugPrint('[STARTUP] diagnostics initialization failed: $error');
    }
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _installErrorHandlers();
    _installed = true;
    logStartup('STARTUP', 'diagnostics_initialized path=${_logFile?.path}');
  }

  void _installErrorHandlers() {
    _previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      recordFlutterError(details);
      final previous = _previousFlutterErrorHandler;
      if (previous == null) {
        FlutterError.presentError(details);
      } else {
        previous(details);
      }
    };
    _previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      recordAsyncError(error, stack);
      return _previousPlatformErrorHandler?.call(error, stack) ?? false;
    };
  }

  void setCurrentRoute(Route<dynamic>? route) {
    _currentRoute = route == null
        ? 'null'
        : '${route.runtimeType}(name=${route.settings.name ?? 'null'})';
  }

  void recordFlutterError(FlutterErrorDetails details) {
    logStartup(
      'FLUTTER_ERROR',
      'exception=${details.exceptionAsString()}\n'
          'library=${details.library ?? 'unknown'}\n'
          'context=${details.context?.toDescription() ?? 'unknown'}\n'
          'stack=${details.stack ?? StackTrace.current}',
    );
  }

  void recordAsyncError(Object error, StackTrace stack) {
    logStartup('PLATFORM_ERROR', 'exception=$error\nstack=$stack');
  }

  void log(String category, String message) {
    if (!kDebugMode) return;
    logStartup(category, message);
  }

  void logStartup(String category, String message) {
    final file = _logFile;
    if (file == null) return;
    final timestamp = DateTime.now().toIso8601String();
    final lifecycle = _lifecycleState?.name ?? 'unknown';
    final entry =
        '[$timestamp][$category] route=$_currentRoute '
        'lifecycle=$lifecycle $message\n';
    try {
      file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
    } on Object catch (error) {
      debugPrint('[DIAGNOSTICS] log write failed: $error');
    }
  }

  void logState(
    String event, {
    bool? mounted,
    bool? routeCurrent,
    bool? exportFlowActive,
  }) {
    log(
      'STATE',
      '$event mounted=${mounted ?? 'n/a'} '
          'routeCurrent=${routeCurrent ?? 'n/a'} '
          'exportFlowActive=${exportFlowActive ?? 'n/a'}',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    log('APP_LIFECYCLE', 'app_${state.name}');
  }

  Future<bool> exportLog() async {
    if (!kDebugMode || _logFile == null) return false;
    log('DIAGNOSTICS', 'export_requested');
    final result = await _channel
        .invokeMapMethod<String, dynamic>('exportDebugLog', {
          'logPath': _logFile!.path,
          'suggestedName':
              'scana_debug_${DateTime.now().millisecondsSinceEpoch}.txt',
        });
    final exported = result?['exported'] == true;
    log('DIAGNOSTICS', 'export_result exported=$exported');
    return exported;
  }
}

class DebugNavigatorObserver extends NavigatorObserver {
  DebugNavigatorObserver({DebugDiagnostics? diagnostics})
    : _diagnostics = diagnostics ?? DebugDiagnostics.instance;

  final DebugDiagnostics _diagnostics;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _diagnostics.setCurrentRoute(route);
    _diagnostics.log(
      'NAVIGATOR',
      'didPush route=${_route(route)} previous=${_route(previousRoute)}',
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _diagnostics.setCurrentRoute(previousRoute);
    _diagnostics.log(
      'NAVIGATOR',
      'didPop route=${_route(route)} previous=${_route(previousRoute)}',
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _diagnostics.setCurrentRoute(previousRoute);
    _diagnostics.log(
      'NAVIGATOR',
      'didRemove route=${_route(route)} previous=${_route(previousRoute)}',
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _diagnostics.setCurrentRoute(newRoute);
    _diagnostics.log(
      'NAVIGATOR',
      'didReplace new=${_route(newRoute)} old=${_route(oldRoute)}',
    );
  }

  String _route(Route<dynamic>? route) => route == null
      ? 'null'
      : '${route.runtimeType}(name=${route.settings.name ?? 'null'})';
}
