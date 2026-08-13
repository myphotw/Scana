import 'package:flutter/services.dart';

import 'package:scana/models/page_enhancement.dart';
import 'package:scana/models/image_quality.dart';

abstract interface class PageEnhancer {
  Future<PageEnhancementResult> enhance({
    required String sourceImagePath,
    required String outputImagePath,
    required EnhancementMode mode,
  });
}

class ScanQualityPipelinePolicy {
  const ScanQualityPipelinePolicy._();

  static const String losslessIntermediateExtension = 'png';
  static const double foregroundSharpnessWarningRatio = 0.90;

  static bool isLosslessIntermediatePath(String filePath) =>
      filePath.toLowerCase().endsWith('.png');

  static bool preservesResolution({
    required int sourceWidth,
    required int sourceHeight,
    required int outputWidth,
    required int outputHeight,
  }) => sourceWidth == outputWidth && sourceHeight == outputHeight;

  static bool foregroundSharpnessDropped({
    required double source,
    required double output,
  }) => source > 0 && output < source * foregroundSharpnessWarningRatio;
}

class UnavailablePageEnhancer implements PageEnhancer {
  const UnavailablePageEnhancer();

  @override
  Future<PageEnhancementResult> enhance({
    required String sourceImagePath,
    required String outputImagePath,
    required EnhancementMode mode,
  }) {
    throw UnsupportedError('Page enhancement is unavailable.');
  }
}

class OpenCvPageEnhancer implements PageEnhancer {
  const OpenCvPageEnhancer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.myphotw.scana/page_enhancer';
  final MethodChannel _channel;

  @override
  Future<PageEnhancementResult> enhance({
    required String sourceImagePath,
    required String outputImagePath,
    required EnhancementMode mode,
  }) async {
    final value = await _channel
        .invokeMapMethod<String, dynamic>('enhancePage', {
          'sourceImagePath': sourceImagePath,
          'outputImagePath': outputImagePath,
          'enhancementMode': mode.name,
        });
    final width = value?['outputWidth'];
    final height = value?['outputHeight'];
    final elapsed = value?['processingMilliseconds'];
    if (width is! int ||
        height is! int ||
        elapsed is! int ||
        width <= 0 ||
        height <= 0 ||
        elapsed < 0) {
      throw const FormatException(
        'Page enhancer returned invalid output data.',
      );
    }
    const timingKeys = <String>{
      'backgroundAnalysisMilliseconds',
      'backgroundNormalizationMilliseconds',
      'backgroundWhiteningMilliseconds',
      'foregroundEnhancementMilliseconds',
      'sharpeningMilliseconds',
      'totalEnhancementMilliseconds',
    };
    final stageTimings = <String, int>{};
    for (final key in timingKeys) {
      final timing = value?[key];
      if (timing == null) continue;
      if (timing is! int || timing < 0) {
        throw const FormatException(
          'Page enhancer returned invalid stage timing data.',
        );
      }
      stageTimings[key] = timing;
    }
    return PageEnhancementResult(
      outputWidth: width,
      outputHeight: height,
      processingMilliseconds: elapsed,
      stageTimings: Map.unmodifiable(stageTimings),
      sourceQuality: ImageQualityMetrics.fromNative(value, 'source'),
      outputQuality: ImageQualityMetrics.fromNative(value, 'output'),
      outputFormat: value?['outputFormat'] as String?,
      sharpeningAmount: _optionalFiniteDouble(value?['sharpeningAmount']),
      foregroundDarkeningAmount: _optionalFiniteDouble(
        value?['foregroundDarkeningAmount'],
      ),
      sourceLuminanceBlend: _optionalFiniteDouble(
        value?['sourceLuminanceBlend'],
      ),
    );
  }

  static double? _optionalFiniteDouble(Object? value) {
    if (value == null) return null;
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      throw const FormatException(
        'Page enhancer returned invalid tuning metadata.',
      );
    }
    return value.toDouble();
  }
}
