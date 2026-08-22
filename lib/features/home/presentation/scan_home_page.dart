import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_scan_workflow.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_analyzer.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_splitter.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

class ProductionScanHomeVisibility {
  const ProductionScanHomeVisibility._();

  static bool showsLegacyScanner({required bool debugMode}) => debugMode;
}

/// Production entry point: one scan action auto-classifies each ML Kit page.
class ScanHomePage extends StatefulWidget {
  const ScanHomePage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.recoverySession,
    this.mlKitDocumentScanner = const AndroidMlKitDocumentScanner(),
    this.mlKitSpreadAnalyzer = const ConservativeMlKitSpreadAnalyzer(),
    this.mlKitSpreadSplitter = const LosslessMlKitSpreadSplitter(),
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final CameraStartup? cameraStartup;
  final ScanSession? recoverySession;
  final MlKitDocumentScanner mlKitDocumentScanner;
  final MlKitSpreadAnalyzer mlKitSpreadAnalyzer;
  final MlKitSpreadSplitter mlKitSpreadSplitter;
  final ScreenOrientationController orientationController;

  @override
  State<ScanHomePage> createState() => _ScanHomePageState();
}

class _ScanHomePageState extends State<ScanHomePage> {
  late final MlKitScanWorkflow _workflow;
  bool _isScanning = false;
  bool _recoveryPromptShown = false;
  CameraStartup? _legacyCameraStartup;
  bool _ownsLegacyCameraStartup = false;

  @override
  void initState() {
    super.initState();
    _legacyCameraStartup = widget.cameraStartup;
    _workflow = MlKitScanWorkflow(
      scanner: widget.mlKitDocumentScanner,
      sessionManager: widget.sessionManager,
      spreadAnalyzer: widget.mlKitSpreadAnalyzer,
      spreadSplitter: widget.mlKitSpreadSplitter,
    );
    unawaited(widget.orientationController.enterContentScreen());
    WidgetsBinding.instance.addPostFrameCallback((_) => _showRecoveryPrompt());
  }

  @override
  void dispose() {
    if (_ownsLegacyCameraStartup) {
      unawaited(_legacyCameraStartup?.session?.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scana')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.document_scanner_outlined,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '문서와 책을 자동으로 구분합니다',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    key: const Key('startMlKitScanButton'),
                    onPressed: _isScanning ? null : _startMlKitScan,
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: const Text('스캔 시작'),
                  ),
                  if (_isScanning) ...[
                    const SizedBox(height: 24),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  if (ProductionScanHomeVisibility.showsLegacyScanner(
                    debugMode: kDebugMode,
                  )) ...[
                    const SizedBox(height: 32),
                    OutlinedButton.icon(
                      key: const Key('openLegacyScannerButton'),
                      onPressed: _isScanning ? null : _openLegacyScanner,
                      icon: const Icon(Icons.developer_mode_outlined),
                      label: const Text('DEBUG Legacy Scanner'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startMlKitScan() async {
    if (_isScanning) return;
    setState(() => _isScanning = true);
    DebugDiagnostics.instance.logStartup(
      'MLKIT_SCAN',
      'flutter_startScan_requested',
    );
    try {
      final result = await _workflow.run();
      if (!mounted) return;
      switch (result.status) {
        case MlKitScanWorkflowStatus.imported:
          DebugDiagnostics.instance.log(
            'MLKIT_SCAN',
            'production_gallery_open mode=auto pages=${result.pages.length}',
          );
          await _openGallery();
          break;
        case MlKitScanWorkflowStatus.cancelled:
          break;
        case MlKitScanWorkflowStatus.empty:
          _showMessage('ML Kit 스캔 결과가 없습니다.');
      }
    } on MlKitDocumentScannerException catch (error) {
      DebugDiagnostics.instance.logStartup(
        'MLKIT_SCAN',
        'production_error code=${error.code} details=${error.details} '
            'message=${error.message}',
      );
      if (mounted) {
        _showMessage('ML Kit 스캐너를 시작할 수 없습니다. 잠시 후 다시 시도해주세요.');
      }
    } on Object catch (error) {
      DebugDiagnostics.instance.log('MLKIT_SCAN', 'production_error $error');
      if (mounted) _showMessage('스캔 결과를 가져올 수 없습니다.');
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _openGallery() async {
    await widget.orientationController.enterContentScreen();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => PageManagementPage(
          sessionManager: widget.sessionManager,
          cameraStartup: _legacyCameraStartup,
          orientationController: widget.orientationController,
        ),
      ),
    );
  }

  Future<void> _openLegacyScanner() async {
    var startup = _legacyCameraStartup;
    if (startup == null) {
      setState(() => _isScanning = true);
      startup = await CameraSession.initializeDefault();
      if (!mounted) {
        await startup.session?.dispose();
        return;
      }
      _legacyCameraStartup = startup;
      _ownsLegacyCameraStartup = true;
      setState(() => _isScanning = false);
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => CameraPreviewPage(
          sessionManager: widget.sessionManager,
          cameraStartup: startup,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (mounted) {
      await widget.orientationController.enterContentScreen();
    }
  }

  Future<void> _showRecoveryPrompt() async {
    final recoverySession = widget.recoverySession;
    if (recoverySession == null || _recoveryPromptShown || !mounted) return;
    _recoveryPromptShown = true;
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('이전 스캔 작업이 있습니다.'),
        content: Text('페이지 수: ${recoverySession.pages.length}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('삭제 후 새 스캔'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('이어하기'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    try {
      if (resume == true) {
        widget.sessionManager.restoreSession(recoverySession);
        if (recoverySession.pages.isNotEmpty) await _openGallery();
      } else {
        await widget.sessionManager.deleteRecoveredSession(recoverySession);
      }
    } on FileSystemException {
      if (mounted) _showMessage('이전 스캔 작업을 처리할 수 없습니다.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
