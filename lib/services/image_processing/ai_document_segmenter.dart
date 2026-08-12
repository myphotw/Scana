import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/services/image_processing/document_detector.dart';

class FairScanSegmentationContract {
  const FairScanSegmentationContract._();

  static const modelVersion = 'v1.2.0';
  static const modelAsset =
      'android/app/src/main/assets/models/fairscan_document_segmentation.tflite';
  static const inputWidth = 256;
  static const inputHeight = 256;
  static const inputChannels = 3;
  static const normalizationMean = 127.5;
  static const normalizationScale = 127.5;
  static const maskThreshold = 0.5;
  static const minimumComponentAreaRatio = 0.02;
  static const maximumComponentAreaRatio = 0.995;
  static const maximumComponentAspectRatio = 8.0;
}

class AiMaskComponentPolicy {
  const AiMaskComponentPolicy._();

  static bool hasReasonableAspect(double width, double height) {
    if (width <= 0 || height <= 0) return false;
    final aspect = width > height ? width / height : height / width;
    return aspect <= FairScanSegmentationContract.maximumComponentAspectRatio;
  }

  static double candidateScore({
    required double areaRatio,
    required double centerCoverage,
    required double aspectRatio,
  }) {
    final aspectScore =
        (1 -
                (aspectRatio - 1) /
                    (FairScanSegmentationContract.maximumComponentAspectRatio -
                        1))
            .clamp(0.0, 1.0)
            .toDouble();
    return areaRatio * 0.70 +
        centerCoverage.clamp(0.0, 1.0).toDouble() * 0.20 +
        aspectScore * 0.10;
  }

  static int? largestPlausibleIndex(
    List<double> componentAreas, {
    required double maskArea,
  }) {
    if (maskArea <= 0) return null;
    int? bestIndex;
    var bestArea = -1.0;
    for (var index = 0; index < componentAreas.length; index++) {
      final area = componentAreas[index];
      final ratio = area / maskArea;
      if (ratio >= FairScanSegmentationContract.minimumComponentAreaRatio &&
          ratio <= FairScanSegmentationContract.maximumComponentAreaRatio &&
          area > bestArea) {
        bestArea = area;
        bestIndex = index;
      }
    }
    return bestIndex;
  }
}

class AiDebugArtifactPolicy {
  const AiDebugArtifactPolicy._();

  static String? outputDirectory(
    String sessionDirectory, {
    required bool debugBuild,
  }) => debugBuild ? path.join(sessionDirectory, 'debug_ai') : null;
}

abstract interface class AiDocumentSegmenter {
  Future<AiDocumentSegmentationResult> segment(
    String imagePath, {
    DocumentPageSide? pageSide,
    DocumentCorners? openCvCorners,
    String? debugOutputDirectory,
    required String debugStem,
  });

  Future<AiDocumentModelInfo?> getModelInfo();
}

class NoOpAiDocumentSegmenter implements AiDocumentSegmenter {
  const NoOpAiDocumentSegmenter();

  @override
  Future<AiDocumentModelInfo?> getModelInfo() async => null;

  @override
  Future<AiDocumentSegmentationResult> segment(
    String imagePath, {
    DocumentPageSide? pageSide,
    DocumentCorners? openCvCorners,
    String? debugOutputDirectory,
    required String debugStem,
  }) async => AiDocumentSegmentationResult(
    success: false,
    modelVersion: 'disabled',
    modelLoadMs: 0,
    preprocessMs: 0,
    inferenceTimeMs: 0,
    postprocessMs: 0,
    totalMs: 0,
    sourceWidth: 0,
    sourceHeight: 0,
    maskWidth: 0,
    maskHeight: 0,
    maskCoverage: 0,
    pageSide: pageSide?.name ?? 'single',
    failureReason: 'ai_poc_disabled',
  );
}

class PlatformAiDocumentSegmenter implements AiDocumentSegmenter {
  const PlatformAiDocumentSegmenter({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.myphotw.scana/ai_document_segmenter');

  final MethodChannel _channel;

  @override
  Future<AiDocumentModelInfo?> getModelInfo() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'getModelInfo',
    );
    if (value == null) return null;
    List<int> shape(String key) => switch (value[key]) {
      final List values =>
        values.whereType<num>().map((item) => item.toInt()).toList(),
      _ => const [],
    };
    return AiDocumentModelInfo(
      modelVersion: value['modelVersion'] as String? ?? 'unknown',
      modelLoadMs: (value['modelLoadMs'] as num?)?.toInt() ?? 0,
      inputShape: shape('inputShape'),
      outputShape: shape('outputShape'),
      inputType: value['inputType'] as String? ?? 'unknown',
      outputType: value['outputType'] as String? ?? 'unknown',
      threads: (value['threads'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<AiDocumentSegmentationResult> segment(
    String imagePath, {
    DocumentPageSide? pageSide,
    DocumentCorners? openCvCorners,
    String? debugOutputDirectory,
    required String debugStem,
  }) async {
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'segmentDocument',
        {
          'imagePath': imagePath,
          if (pageSide != null) 'pageSide': pageSide.name,
          if (kDebugMode && debugOutputDirectory != null)
            'debugOutputDirectory': debugOutputDirectory,
          'debugStem': debugStem,
          if (openCvCorners != null)
            'openCvCorners': openCvCorners.ordered
                .map((point) => {'x': point.x, 'y': point.y})
                .toList(),
        },
      );
      if (value == null) {
        return _failure(pageSide, 'empty_native_result');
      }
      final sessionDirectory = path.dirname(imagePath);
      String? relativeArtifact(String key) {
        final absolute = value[key] as String?;
        if (absolute == null || !path.isWithin(sessionDirectory, absolute)) {
          return null;
        }
        return path
            .relative(absolute, from: sessionDirectory)
            .replaceAll('\\', '/');
      }

      final persisted = <String, dynamic>{
        ...value,
        'corners': _cornersFromNative(value['corners'])?.toJson(),
        'refinedCorners': _cornersFromNative(value['refinedCorners'])?.toJson(),
        'debugRawFile': relativeArtifact('debugRawPath'),
        'debugMaskFile': relativeArtifact('debugMaskPath'),
        'debugAiOverlayFile': relativeArtifact('debugAiOverlayPath'),
        'debugAiRawOverlayFile': relativeArtifact('debugAiRawOverlayPath'),
        'debugAiRefinedOverlayFile': relativeArtifact(
          'debugAiRefinedOverlayPath',
        ),
        'debugSearchRoiFile': relativeArtifact('debugSearchRoiPath'),
        'debugEnvelopeOverlayFile': relativeArtifact(
          'debugEnvelopeOverlayPath',
        ),
        'debugOpenCvOverlayFile': relativeArtifact('debugOpenCvOverlayPath'),
      };
      return AiDocumentSegmentationResult.fromJson(persisted) ??
          _failure(pageSide, 'invalid_native_result');
    } on PlatformException catch (error) {
      return _failure(pageSide, error.code);
    } on Object catch (error) {
      return _failure(pageSide, error.runtimeType.toString());
    }
  }

  static AiDocumentSegmentationResult _failure(
    DocumentPageSide? side,
    String reason,
  ) => AiDocumentSegmentationResult(
    success: false,
    modelVersion: 'unknown',
    modelLoadMs: 0,
    preprocessMs: 0,
    inferenceTimeMs: 0,
    postprocessMs: 0,
    totalMs: 0,
    sourceWidth: 0,
    sourceHeight: 0,
    maskWidth: 0,
    maskHeight: 0,
    maskCoverage: 0,
    pageSide: side?.name ?? 'single',
    failureReason: reason,
  );

  static DocumentCorners? _cornersFromNative(Object? value) {
    if (value is! List || value.length != 4) return null;
    final points = value.map(DocumentPoint.fromJson).toList();
    if (points.any((point) => point == null)) return null;
    return DocumentCorners(
      topLeft: points[0]!,
      topRight: points[1]!,
      bottomRight: points[2]!,
      bottomLeft: points[3]!,
    );
  }
}
