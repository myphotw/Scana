import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_analyzer.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_splitter.dart';

enum MlKitScanWorkflowStatus { imported, cancelled, empty }

class MlKitScanWorkflowResult {
  const MlKitScanWorkflowResult._(this.status, this.pages);

  const MlKitScanWorkflowResult.imported(List<ScanPage> pages)
    : this._(MlKitScanWorkflowStatus.imported, pages);

  const MlKitScanWorkflowResult.cancelled()
    : this._(MlKitScanWorkflowStatus.cancelled, const []);

  const MlKitScanWorkflowResult.empty()
    : this._(MlKitScanWorkflowStatus.empty, const []);

  final MlKitScanWorkflowStatus status;
  final List<ScanPage> pages;
}

class MlKitScanWorkflow {
  const MlKitScanWorkflow({
    required this.scanner,
    required this.sessionManager,
    this.spreadAnalyzer = const ConservativeMlKitSpreadAnalyzer(),
    this.spreadSplitter = const LosslessMlKitSpreadSplitter(),
  });

  final MlKitDocumentScanner scanner;
  final ScanSessionManager sessionManager;
  final MlKitSpreadAnalyzer spreadAnalyzer;
  final MlKitSpreadSplitter spreadSplitter;

  Future<MlKitScanWorkflowResult> run() async {
    final target = await sessionManager.prepareMlKitScan();
    try {
      final scanResult = await scanner.scan(
        sessionId: target.sessionId,
        startPageNo: target.startPageNo,
      );
      if (scanResult.status == MlKitScanStatus.cancelled) {
        await sessionManager.discardEmptyMlKitTarget(target);
        return const MlKitScanWorkflowResult.cancelled();
      }
      if (scanResult.pages.isEmpty) {
        await sessionManager.discardEmptyMlKitTarget(target);
        return const MlKitScanWorkflowResult.empty();
      }
      final imports = <MlKitPageImport>[];
      for (var index = 0; index < scanResult.pages.length; index++) {
        final source = scanResult.pages[index];
        MlKitSpreadAnalysis analysis;
        try {
          analysis = await spreadAnalyzer.analyze(source);
        } on Object catch (error) {
          analysis = MlKitSpreadAnalysis(
            layout: MlKitPageLayout.uncertain,
            splitX: source.width ~/ 2,
            confidence: 0,
            fallbackUsed: true,
          );
          DebugDiagnostics.instance.log(
            'MLKIT_SPREAD',
            'auto_analysis_failed page=${index + 1} fallback=single error=$error',
          );
        }
        _logSpreadDiagnostics(
          pageIndex: index,
          source: source,
          analysis: analysis,
          splitterInvoked: analysis.isSpread,
        );
        if (analysis.isSpread) {
          final split = await spreadSplitter.split(
            sessionId: target.sessionId,
            leftPageNo: target.startPageNo + imports.length,
            source: source,
            detection: analysis.detection,
          );
          final parentSpreadId =
              'spread_${target.startPageNo + index}_'
              '${path.basenameWithoutExtension(source.filePath)}';
          imports
            ..add(
              MlKitPageImport(
                scannedPage: split.left,
                sourceType: ScanPageSourceType.mlKitSpread,
                layout: MlKitPageLayout.spread,
                originalSourcePath: source.filePath,
                parentSpreadId: parentSpreadId,
                spreadSide: MlKitSpreadSide.left,
                splitX: split.detection.splitX,
                splitConfidence: split.detection.confidence,
                splitFallbackUsed: split.detection.usedFallback,
                cropRect: split.leftCropRect,
              ),
            )
            ..add(
              MlKitPageImport(
                scannedPage: split.right,
                sourceType: ScanPageSourceType.mlKitSpread,
                layout: MlKitPageLayout.spread,
                originalSourcePath: source.filePath,
                parentSpreadId: parentSpreadId,
                spreadSide: MlKitSpreadSide.right,
                splitX: split.detection.splitX,
                splitConfidence: split.detection.confidence,
                splitFallbackUsed: split.detection.usedFallback,
                cropRect: split.rightCropRect,
              ),
            );
        } else {
          imports.add(
            MlKitPageImport(
              scannedPage: source,
              sourceType: ScanPageSourceType.mlKit,
              layout: analysis.layout,
              originalSourcePath: source.filePath,
              splitX: analysis.splitX,
              splitConfidence: analysis.confidence,
              splitFallbackUsed: analysis.fallbackUsed,
            ),
          );
        }
      }
      final pages = await sessionManager.registerMlKitImports(imports);
      return MlKitScanWorkflowResult.imported(pages);
    } on Object {
      await sessionManager.discardEmptyMlKitTarget(target);
      rethrow;
    }
  }

  void _logSpreadDiagnostics({
    required int pageIndex,
    required MlKitScannedPage source,
    required MlKitSpreadAnalysis analysis,
    required bool splitterInvoked,
  }) {
    final signals = analysis.signals;
    String score(double value) => value.toStringAsFixed(3);
    DebugDiagnostics.instance.log(
      'MLKIT_SPREAD',
      'page=${pageIndex + 1} width=${source.width} height=${source.height} '
          'aspectRatio=${signals.aspectRatio.toStringAsFixed(3)} '
          'candidateSplitX=${analysis.splitX} '
          'luminanceValleyScore=${score(signals.luminanceValleyScore)} '
          'gutterShadowScore=${score(signals.gutterShadowScore)} '
          'verticalGradientScore=${score(signals.verticalGradientScore)} '
          'columnVarianceScore=${score(signals.columnVarianceScore)} '
          'gutterContinuityScore=${score(signals.gutterContinuityScore)} '
          'leftContentScore=${score(signals.leftContentScore)} '
          'rightContentScore=${score(signals.rightContentScore)} '
          'contentBalanceScore=${score(signals.contentBalanceScore)} '
          'pageStructureScore=${score(signals.pageStructureScore)} '
          'splitConfidence=${score(analysis.confidence)} '
          'classification=${analysis.layout.name} '
          'rejectReason=${analysis.rejectReason} '
          'splitterInvoked=$splitterInvoked',
    );
  }
}
