import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'package:scana/models/image_quality.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/pdf_export/pdf_raster_quality_policy.dart';

/// Thresholds used only to flag suspicious DEBUG artifacts for inspection.
class ScanQualityDiagnosticPolicy {
  const ScanQualityDiagnosticPolicy._();

  static const double backgroundSpeckleWarningMultiplier = 1.75;
  static const double backgroundSpeckleWarningMinimumDelta = 0.01;

  static bool backgroundSpeckleAmplified({
    required double source,
    required double output,
  }) =>
      output > source * backgroundSpeckleWarningMultiplier &&
      output > source + backgroundSpeckleWarningMinimumDelta;
}

/// DEBUG-only stage artifacts and metrics for comparing the exact same page.
class ScanQualityDiagnostics {
  const ScanQualityDiagnostics._();

  static Future<void> recordCurvatureDecision({
    required ScanPage page,
    required String perspectivePath,
    String? curvedPath,
    required CurvatureState state,
    required bool applied,
    required Map<String, Object> diagnostics,
    String? rejectReason,
    String? nativeArtifactStem,
  }) async {
    if (!kDebugMode) return;
    await _safely(() async {
      final directory = await _curvatureDirectory(page);
      await _copyNamed(perspectivePath, directory, 'perspective');
      if (applied && curvedPath != null) {
        await _copyNamed(curvedPath, directory, 'dewarp_preview');
      }
      if (nativeArtifactStem != null) {
        final nativeDirectory = Directory(
          path.join(
            path.dirname(page.rawImagePath),
            'debug_curvature',
            nativeArtifactStem.replaceFirst(RegExp(r'^\.+'), ''),
          ),
        );
        for (final name in [
          'contour_overlay.png',
          'internal_lines_overlay.png',
        ]) {
          final source = File(path.join(nativeDirectory.path, name));
          if (await source.exists()) {
            await source.copy(path.join(directory.path, name));
          }
        }
      }
      final report = <String, Object>{
        'pageNo': page.pageNo,
        'state': state.name,
        'applied': applied,
        'rejectReason': rejectReason ?? 'none',
        ...diagnostics,
      };
      await File(
        path.join(directory.path, 'curvature_report.json'),
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
    });
  }

  static Future<void> recordCorrection({
    required ScanPage page,
    required CorrectionType type,
    required String sourcePath,
    required String outputPath,
    required PageCorrectionResult result,
  }) async {
    if (!kDebugMode) return;
    await _safely(() async {
      final stage = type == CorrectionType.perspective
          ? '02_perspective'
          : '03_curved';
      final report = await _readReport(page);
      if (type == CorrectionType.perspective) {
        await _copyArtifact(page, sourcePath, '01_raw');
        report['raw'] = _stageMetadata(sourcePath, result.sourceQuality);
      }
      await _copyArtifact(page, outputPath, stage);
      report[type.name] = _stageMetadata(outputPath, result.outputQuality);
      await _writeReport(page, report);
      _logReport(page, report);
    });
  }

  static Future<void> recordEnhancement({
    required ScanPage page,
    required String sourcePath,
    required String outputPath,
    required PageEnhancementResult result,
  }) async {
    if (!kDebugMode) return;
    await _safely(() async {
      final report = await _readReport(page);
      if (!report.containsKey('perspective')) {
        await _copyArtifact(page, sourcePath, '02_perspective');
        report['perspective'] = _stageMetadata(
          sourcePath,
          result.sourceQuality,
        );
      }
      await _copyArtifact(page, outputPath, '04_enhanced');
      final enhancedMetadata = _stageMetadata(outputPath, result.outputQuality)
        ..['sourceSharpness'] = result.sourceQuality.sharpness
        ..['sourceForegroundSharpness'] =
            result.sourceQuality.foregroundSharpness
        ..['processingMilliseconds'] = result.processingMilliseconds;
      if (result.sharpeningAmount case final value?) {
        enhancedMetadata['sharpeningAmount'] = value;
      }
      if (result.foregroundDarkeningAmount case final value?) {
        enhancedMetadata['foregroundDarkeningAmount'] = value;
      }
      if (result.sourceLuminanceBlend case final value?) {
        enhancedMetadata['sourceLuminanceBlend'] = value;
      }
      report['enhanced'] = enhancedMetadata;
      await _writeReport(page, report);
      _logReport(page, report);
      if (result.sharpeningAmount case final sharpening?) {
        DebugDiagnostics.instance.log(
          'SCAN_ENHANCEMENT',
          'page=${page.pageNo} sharpening=$sharpening '
              'foregroundDarkening=${result.foregroundDarkeningAmount} '
              'sourceBlend=${result.sourceLuminanceBlend}',
        );
      }
      if (ScanQualityPipelinePolicy.foregroundSharpnessDropped(
        source: result.sourceQuality.foregroundSharpness,
        output: result.outputQuality.foregroundSharpness,
      )) {
        DebugDiagnostics.instance.log(
          'SCAN_QUALITY_WARNING',
          'page=${page.pageNo} foregroundSharpnessDropped '
              'source=${result.sourceQuality.foregroundSharpness.toStringAsFixed(2)} '
              'enhanced=${result.outputQuality.foregroundSharpness.toStringAsFixed(2)}',
        );
      }
      if (result.sourceQuality.backgroundPixels > 0 &&
          result.outputQuality.backgroundPixels > 0 &&
          ScanQualityDiagnosticPolicy.backgroundSpeckleAmplified(
            source: result.sourceQuality.darkSpeckleRatio,
            output: result.outputQuality.darkSpeckleRatio,
          )) {
        DebugDiagnostics.instance.log(
          'SCAN_QUALITY_WARNING',
          'page=${page.pageNo} reason=background_speckle_amplified '
              'source=${result.sourceQuality.darkSpeckleRatio.toStringAsFixed(6)} '
              'enhanced=${result.outputQuality.darkSpeckleRatio.toStringAsFixed(6)}',
        );
      }
    });
  }

  static Future<void> recordPdfSource({
    required String sourceImagePath,
    String? rawImagePath,
    required int pageNo,
  }) async {
    if (!kDebugMode) return;
    await _safely(() async {
      final parent = path.dirname(sourceImagePath);
      final rawCandidates = await Directory(parent)
          .list(followLinks: false)
          .where(
            (entity) =>
                entity is File && path.basename(entity.path).startsWith('raw_'),
          )
          .cast<File>()
          .toList();
      final matchingRaw = rawCandidates.where((file) {
        final token = pageNo.toString().padLeft(3, '0');
        return path.basename(file.path).startsWith('raw_$token');
      }).firstOrNull;
      final rawPath = rawImagePath ?? matchingRaw?.path ?? sourceImagePath;
      final page = ScanPage(
        pageNo: pageNo,
        rawImagePath: rawPath,
        createdTime: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final directory = await _qualityDirectory(page);
      final file = File(sourceImagePath);
      final metadata = <String, Object>{
        'pageNo': pageNo,
        'sourceFile': path.basename(sourceImagePath),
        'format': path
            .extension(sourceImagePath)
            .replaceFirst('.', '')
            .toLowerCase(),
        'bytes': await file.length(),
        'preResize': PdfRasterQualityPolicy.preResize,
      };
      await File(path.join(directory.path, '05_pdf_source.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(metadata),
        flush: true,
      );
      DebugDiagnostics.instance.log(
        'SCAN_QUALITY',
        'page=$pageNo pdfSourcePath=${path.basename(sourceImagePath)} '
            'pdfSourceBytes=${metadata['bytes']} pdfPreResize=false',
      );
    });
  }

  static Future<void> _safely(Future<void> Function() operation) async {
    try {
      await operation();
    } on Object catch (error) {
      DebugDiagnostics.instance.log(
        'SCAN_QUALITY_WARNING',
        'diagnosticArtifactFailed error=$error',
      );
    }
  }

  static Map<String, Object> _stageMetadata(
    String filePath,
    ImageQualityMetrics metrics,
  ) => <String, Object>{
    'file': path.basename(filePath),
    'format': path.extension(filePath).replaceFirst('.', '').toLowerCase(),
    if (metrics.isAvailable) ...metrics.toJson(),
    'bytes': File(filePath).lengthSync(),
  };

  static Future<Map<String, Object>> _readReport(ScanPage page) async {
    final directory = await _qualityDirectory(page);
    final file = File(path.join(directory.path, 'quality_report.json'));
    if (!await file.exists()) return <String, Object>{'pageNo': page.pageNo};
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic>
          ? Map<String, Object>.from(value)
          : <String, Object>{'pageNo': page.pageNo};
    } on Object {
      return <String, Object>{'pageNo': page.pageNo};
    }
  }

  static Future<void> _writeReport(
    ScanPage page,
    Map<String, Object> report,
  ) async {
    final directory = await _qualityDirectory(page);
    await File(path.join(directory.path, 'quality_report.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
  }

  static Future<void> _copyArtifact(
    ScanPage page,
    String sourcePath,
    String stage,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) return;
    final directory = await _qualityDirectory(page);
    final extension = path.extension(sourcePath).toLowerCase();
    await source.copy(path.join(directory.path, '$stage$extension'));
  }

  static Future<void> _copyNamed(
    String sourcePath,
    Directory directory,
    String name,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) return;
    await source.copy(
      path.join(directory.path, '$name${path.extension(sourcePath)}'),
    );
  }

  static Future<Directory> _qualityDirectory(ScanPage page) async {
    final rawStem = path.basenameWithoutExtension(page.rawImagePath);
    final directory = Directory(
      path.join(path.dirname(page.rawImagePath), 'debug_quality', rawStem),
    );
    await directory.create(recursive: true);
    return directory;
  }

  static Future<Directory> _curvatureDirectory(ScanPage page) async {
    final rawStem = path.basenameWithoutExtension(page.rawImagePath);
    final directory = Directory(
      path.join(path.dirname(page.rawImagePath), 'debug_curvature', rawStem),
    );
    await directory.create(recursive: true);
    return directory;
  }

  static void _logReport(ScanPage page, Map<String, Object> report) {
    String metric(String stage, String key) {
      final value = report[stage];
      return value is Map ? '${value[key] ?? 'n/a'}' : 'n/a';
    }

    DebugDiagnostics.instance.log(
      'SCAN_QUALITY',
      'page=${page.pageNo} '
          'rawResolution=${metric('raw', 'width')}x${metric('raw', 'height')} '
          'perspectiveResolution=${metric('perspective', 'width')}x${metric('perspective', 'height')} '
          'enhancedResolution=${metric('enhanced', 'width')}x${metric('enhanced', 'height')} '
          'rawSharpness=${metric('raw', 'sharpness')} '
          'perspectiveSharpness=${metric('perspective', 'sharpness')} '
          'enhancedSharpness=${metric('enhanced', 'sharpness')} '
          'rawForegroundSharpness=${metric('raw', 'foregroundSharpness')} '
          'perspectiveForegroundSharpness=${metric('perspective', 'foregroundSharpness')} '
          'enhancedForegroundSharpness=${metric('enhanced', 'foregroundSharpness')} '
          'perspectiveBackgroundVariance=${metric('perspective', 'backgroundVariance')} '
          'enhancedBackgroundVariance=${metric('enhanced', 'backgroundVariance')} '
          'perspectiveDarkSpeckleRatio=${metric('perspective', 'darkSpeckleRatio')} '
          'enhancedDarkSpeckleRatio=${metric('enhanced', 'darkSpeckleRatio')} '
          'perspectiveFormat=${metric('perspective', 'format')} '
          'enhancedFormat=${metric('enhanced', 'format')} '
          'perspectiveBytes=${metric('perspective', 'bytes')} '
          'enhancedBytes=${metric('enhanced', 'bytes')}',
    );
  }
}
