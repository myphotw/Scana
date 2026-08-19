import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:scana/models/image_quality.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/diagnostics/scan_quality_diagnostics.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';
import 'package:scana/services/pdf_export/pdf_raster_quality_policy.dart';

void main() {
  test('lossless intermediate policy uses PNG and preserves resolution', () {
    expect(ScanQualityPipelinePolicy.losslessIntermediateExtension, 'png');
    expect(
      ScanQualityPipelinePolicy.isLosslessIntermediatePath(
        '/session/corrected_001.png',
      ),
      isTrue,
    );
    expect(
      ScanQualityPipelinePolicy.preservesResolution(
        sourceWidth: 3024,
        sourceHeight: 4032,
        outputWidth: 3024,
        outputHeight: 4032,
      ),
      isTrue,
    );
    expect(
      ScanQualityPipelinePolicy.preservesResolution(
        sourceWidth: 3024,
        sourceHeight: 4032,
        outputWidth: 1200,
        outputHeight: 1600,
      ),
      isFalse,
    );
  });

  test('foreground warning is diagnostic and uses a meaningful drop', () {
    expect(
      ScanQualityPipelinePolicy.foregroundSharpnessDropped(
        source: 100,
        output: 95,
      ),
      isFalse,
    );
    expect(
      ScanQualityPipelinePolicy.foregroundSharpnessDropped(
        source: 100,
        output: 80,
      ),
      isTrue,
    );
  });

  test('PDF raster policy returns the identical full-resolution bytes', () {
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    expect(PdfRasterQualityPolicy.preResize, isFalse);
    expect(identical(PdfRasterQualityPolicy.sourceBytes(bytes), bytes), isTrue);
  });

  test('native Scan Color restores the stable M8.1 enhancement policy', () {
    final source = File(
      'android/app/src/main/kotlin/com/myphotw/scana/imageprocessing/'
      'OpenCvPageEnhancer.kt',
    ).readAsStringSync();
    expect(source, contains('Size(5.0, 5.0)'));
    expect(source, contains('SOURCE_LUMINANCE_BLEND = 0.07'));
    expect(source, contains('FOREGROUND_MAX_LUMINANCE = 205.0'));
    expect(source, contains('SHARPEN_AMOUNT = 0.17'));
    expect(source, contains('FOREGROUND_DARKENING_AMOUNT = 0.20'));
    expect(source, contains('1.0 - FOREGROUND_DARKENING_AMOUNT * strength'));
    expect(source, contains('blendBrighterWithMask'));
    expect(source, contains('blendDarkerWithMask'));
    expect(source, contains('neutralizePaperChroma'));
    expect(source, isNot(contains('fineDarkDetail')));
    expect(source, isNot(contains('broadDarkDetail')));
    expect(source, isNot(contains('MORPH_BLACKHAT')));
    expect(source, isNot(contains('staffMask')));
    expect(source, isNot(contains('preserveSourceForeground')));
    expect(source, isNot(contains('FOREGROUND_SOURCE_PRESERVATION')));
    expect(source, isNot(contains('MORPH_OPEN')));
    expect(
      RegExp(r'Imgproc\.GaussianBlur\(').allMatches(source).length,
      9,
      reason: 'Readability tuning must not add another blur stage.',
    );
  });

  test('production Perspective warp uses cubic resampling only', () {
    final source = File(
      'android/app/src/main/kotlin/com/myphotw/scana/imageprocessing/'
      'OpenCvPageCorrector.kt',
    ).readAsStringSync();
    final normalized = source.replaceAll('\r\n', '\n');
    final productionStart = normalized.indexOf('private fun applyPerspective(');
    final helperStart = normalized.indexOf(
      'private fun warpPerspectiveWithTiming(',
    );
    final production = normalized.substring(productionStart, helperStart);

    expect(production, contains('Imgproc.INTER_CUBIC'));
    expect(production, isNot(contains('Imgproc.INTER_LINEAR')));
    expect(production, isNot(contains('Imgproc.INTER_LANCZOS4')));
    expect(
      normalized,
      contains(
        'warpPerspectiveWithTiming(\n'
        '                source,\n'
        '                transform,\n'
        '                Imgproc.INTER_CUBIC,',
      ),
    );
    expect(normalized, contains('Core.BORDER_REPLICATE'));
    expect(normalized, contains('Scalar.all(255.0)'));
  });

  test('DEBUG Perspective comparison keeps all interpolation variants', () {
    final source = File(
      'android/app/src/main/kotlin/com/myphotw/scana/imageprocessing/'
      'OpenCvPageCorrector.kt',
    ).readAsStringSync();
    final comparisonStart = source.indexOf(
      'private fun writePerspectiveInterpolationComparison(',
    );
    final variantWriterStart = source.indexOf(
      'private fun writePerspectiveComparisonVariant(',
    );
    final comparison = source.substring(comparisonStart, variantWriterStart);

    expect(comparison, contains('Imgproc.INTER_LINEAR'));
    expect(comparison, contains('Imgproc.INTER_LANCZOS4'));
    expect(comparison, contains('perspective_linear.png'));
    expect(comparison, contains('perspective_cubic.png'));
    expect(comparison, contains('perspective_lanczos4.png'));
    expect(comparison, contains('interpolation_report.json'));
    expect(comparison, contains('"productionInterpolation", "INTER_CUBIC"'));
    expect(comparison, contains('"linearMs"'));
    expect(comparison, contains('"cubicMs"'));
    expect(comparison, contains('"lanczos4Ms"'));
    expect(comparison, contains('"linearLaplacianVariance"'));
    expect(comparison, contains('"cubicLaplacianVariance"'));
    expect(comparison, contains('"lanczos4LaplacianVariance"'));
    expect(
      comparison,
      contains(
        'debug_quality/\${sourceFile.nameWithoutExtension}/'
        'interpolation_compare',
      ),
    );
  });

  test('background speckle warning requires a substantial regression', () {
    expect(
      ScanQualityDiagnosticPolicy.backgroundSpeckleAmplified(
        source: 0.02,
        output: 0.025,
      ),
      isFalse,
    );
    expect(
      ScanQualityDiagnosticPolicy.backgroundSpeckleAmplified(
        source: 0.02,
        output: 0.05,
      ),
      isTrue,
    );
  });

  test('DEBUG quality artifacts preserve each processing stage', () async {
    final root = await Directory.systemTemp.createTemp('scana_quality_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final session = Directory(path.join(root.path, 'scan_sessions', 'quality'));
    await session.create(recursive: true);
    final raw = File(path.join(session.path, 'raw_001.jpg'));
    final perspective = File(path.join(session.path, 'corrected_001.png'));
    final enhanced = File(path.join(session.path, 'enhanced_001.png'));
    await raw.writeAsBytes([1, 2, 3]);
    await perspective.writeAsBytes([4, 5, 6, 7]);
    await enhanced.writeAsBytes([8, 9, 10, 11, 12]);
    final page = ScanPage(
      pageNo: 1,
      rawImagePath: raw.path,
      createdTime: DateTime.utc(2026, 8, 13),
    );
    const rawQuality = ImageQualityMetrics(
      width: 3024,
      height: 4032,
      sharpness: 120,
      foregroundSharpness: 160,
      foregroundPixels: 500,
    );
    const perspectiveQuality = ImageQualityMetrics(
      width: 2500,
      height: 3500,
      sharpness: 110,
      foregroundSharpness: 150,
      foregroundPixels: 450,
      backgroundVariance: 5.5,
      darkSpeckleRatio: 0.02,
      backgroundPixels: 100000,
    );
    const enhancedQuality = ImageQualityMetrics(
      width: 2500,
      height: 3500,
      sharpness: 115,
      foregroundSharpness: 152,
      foregroundPixels: 450,
      backgroundVariance: 4.5,
      darkSpeckleRatio: 0.018,
      backgroundPixels: 100000,
    );

    await ScanQualityDiagnostics.recordCorrection(
      page: page,
      type: CorrectionType.perspective,
      sourcePath: raw.path,
      outputPath: perspective.path,
      result: const PageCorrectionResult(
        outputWidth: 2500,
        outputHeight: 3500,
        sourceQuality: rawQuality,
        outputQuality: perspectiveQuality,
        outputFormat: 'png',
      ),
    );
    await ScanQualityDiagnostics.recordEnhancement(
      page: page,
      sourcePath: perspective.path,
      outputPath: enhanced.path,
      result: const PageEnhancementResult(
        outputWidth: 2500,
        outputHeight: 3500,
        processingMilliseconds: 240,
        sourceQuality: perspectiveQuality,
        outputQuality: enhancedQuality,
        outputFormat: 'png',
        sharpeningAmount: 0.17,
        foregroundDarkeningAmount: 0.20,
        sourceLuminanceBlend: 0.07,
      ),
    );
    await ScanQualityDiagnostics.recordPdfSource(
      sourceImagePath: enhanced.path,
      rawImagePath: raw.path,
      pageNo: 1,
    );

    final qualityDirectory = Directory(
      path.join(session.path, 'debug_quality', 'raw_001'),
    );
    expect(
      File(path.join(qualityDirectory.path, '01_raw.jpg')).existsSync(),
      true,
    );
    expect(
      File(path.join(qualityDirectory.path, '02_perspective.png')).existsSync(),
      true,
    );
    expect(
      File(path.join(qualityDirectory.path, '04_enhanced.png')).existsSync(),
      true,
    );
    final report =
        jsonDecode(
              File(
                path.join(qualityDirectory.path, 'quality_report.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect((report['raw'] as Map)['sharpness'], 120);
    expect((report['perspective'] as Map)['format'], 'png');
    expect((report['enhanced'] as Map)['foregroundSharpness'], 152);
    expect((report['enhanced'] as Map)['darkSpeckleRatio'], 0.018);
    expect((report['enhanced'] as Map)['sharpeningAmount'], 0.17);
    expect((report['enhanced'] as Map)['foregroundDarkeningAmount'], 0.20);
    expect((report['enhanced'] as Map)['sourceLuminanceBlend'], 0.07);
    final pdfMetadata =
        jsonDecode(
              File(
                path.join(qualityDirectory.path, '05_pdf_source.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(pdfMetadata['sourceFile'], 'enhanced_001.png');
    expect(pdfMetadata['preResize'], false);
  });
}
