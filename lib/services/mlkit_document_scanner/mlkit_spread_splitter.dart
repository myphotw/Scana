import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';

class MlKitSpineDetection {
  const MlKitSpineDetection({
    required this.splitX,
    required this.confidence,
    required this.usedFallback,
  });

  final int splitX;
  final double confidence;
  final bool usedFallback;
}

class MlKitSpreadSplitResult {
  const MlKitSpreadSplitResult({
    required this.left,
    required this.right,
    required this.detection,
    required this.overlapPixels,
    required this.leftCropRect,
    required this.rightCropRect,
  });

  final MlKitScannedPage left;
  final MlKitScannedPage right;
  final MlKitSpineDetection detection;
  final int overlapPixels;
  final MlKitCropRect leftCropRect;
  final MlKitCropRect rightCropRect;
}

abstract interface class MlKitSpreadSplitter {
  Future<MlKitSpreadSplitResult> split({
    required String sessionId,
    required int leftPageNo,
    required MlKitScannedPage source,
    MlKitSpineDetection? detection,
    String? outputStem,
  });
}

/// Splits an already corrected ML Kit spread without resizing or enhancement.
/// The JPEG is decoded once and each exact pixel ROI is encoded as lossless PNG.
class LosslessMlKitSpreadSplitter implements MlKitSpreadSplitter {
  const LosslessMlKitSpreadSplitter();

  static const double overlapFraction = 0.015;
  static const double searchStartFraction = 0.35;
  static const double searchEndFraction = 0.65;
  static const double minimumConfidence = 0.28;

  @override
  Future<MlKitSpreadSplitResult> split({
    required String sessionId,
    required int leftPageNo,
    required MlKitScannedPage source,
    MlKitSpineDetection? detection,
    String? outputStem,
  }) async {
    final bytes = await File(source.filePath).readAsBytes();
    final decoded = image.decodeImage(bytes);
    if (decoded == null || decoded.width < 2 || decoded.height < 1) {
      throw const FormatException('ML Kit spread JPEG could not be decoded.');
    }
    MlKitSpineDetection resolvedDetection;
    try {
      resolvedDetection = detection ?? detectSpine(decoded);
    } on Object catch (error) {
      resolvedDetection = MlKitSpineDetection(
        splitX: decoded.width ~/ 2,
        confidence: 0,
        usedFallback: true,
      );
      if (kDebugMode) {
        DebugDiagnostics.instance.log(
          'MLKIT_SPREAD',
          'session=$sessionId spine_detection_failed fallback=center error=$error',
        );
      }
    }
    final splitX = resolvedDetection.splitX.clamp(1, decoded.width - 1);
    resolvedDetection = MlKitSpineDetection(
      splitX: splitX,
      confidence: resolvedDetection.confidence,
      usedFallback: resolvedDetection.usedFallback,
    );
    final overlapPixels = math.max(
      1,
      (decoded.width * overlapFraction).round(),
    );
    final leftWidth = (resolvedDetection.splitX + overlapPixels).clamp(
      1,
      decoded.width,
    );
    final rightStart = (resolvedDetection.splitX - overlapPixels).clamp(
      0,
      decoded.width - 1,
    );
    final left = image.copyCrop(
      decoded,
      x: 0,
      y: 0,
      width: leftWidth,
      height: decoded.height,
    );
    final right = image.copyCrop(
      decoded,
      x: rightStart,
      y: 0,
      width: decoded.width - rightStart,
      height: decoded.height,
    );
    final sessionDirectory = Directory(
      path.join(path.dirname(path.dirname(source.filePath)), 'mlkit_split'),
    );
    await sessionDirectory.create(recursive: true);
    final leftFile = File(
      path.join(
        sessionDirectory.path,
        outputStem == null
            ? 'page_${leftPageNo.toString().padLeft(3, '0')}_left.png'
            : '${outputStem}_left.png',
      ),
    );
    final rightFile = File(
      path.join(
        sessionDirectory.path,
        outputStem == null
            ? 'page_${(leftPageNo + 1).toString().padLeft(3, '0')}_right.png'
            : '${outputStem}_right.png',
      ),
    );
    final leftBytes = image.encodePng(left);
    final rightBytes = image.encodePng(right);
    await leftFile.writeAsBytes(leftBytes, flush: true);
    try {
      await rightFile.writeAsBytes(rightBytes, flush: true);
    } on Object {
      if (await leftFile.exists()) await leftFile.delete();
      rethrow;
    }
    if (kDebugMode) {
      DebugDiagnostics.instance.log(
        'MLKIT_SPREAD',
        'session=$sessionId source=${decoded.width}x${decoded.height} '
            'splitX=${resolvedDetection.splitX} fallback=${resolvedDetection.usedFallback} '
            'confidence=${resolvedDetection.confidence.toStringAsFixed(3)} '
            'overlap=$overlapPixels left=${left.width}x${left.height} '
            'right=${right.width}x${right.height}',
      );
    }
    return MlKitSpreadSplitResult(
      left: MlKitScannedPage(
        filePath: leftFile.path,
        byteCount: leftBytes.length,
        width: left.width,
        height: left.height,
      ),
      right: MlKitScannedPage(
        filePath: rightFile.path,
        byteCount: rightBytes.length,
        width: right.width,
        height: right.height,
      ),
      detection: resolvedDetection,
      overlapPixels: overlapPixels,
      leftCropRect: MlKitCropRect(
        left: 0,
        top: 0,
        right: leftWidth / decoded.width,
        bottom: 1,
      ),
      rightCropRect: MlKitCropRect(
        left: rightStart / decoded.width,
        top: 0,
        right: 1,
        bottom: 1,
      ),
    );
  }

  static MlKitSpineDetection detectSpine(image.Image source) {
    final width = source.width;
    final height = source.height;
    final center = width ~/ 2;
    if (width < 20 || height < 10) {
      return MlKitSpineDetection(
        splitX: center,
        confidence: 0,
        usedFallback: true,
      );
    }
    final searchStart = (width * searchStartFraction).round();
    final searchEnd = (width * searchEndFraction).round();
    final shoulderDistance = math.max(2, (width * 0.04).round());
    final smoothRadius = math.max(1, (width * 0.004).round());
    final analysisStart = math.max(0, searchStart - shoulderDistance);
    final analysisEnd = math.min(width - 1, searchEnd + shoulderDistance);
    final top = (height * 0.05).round();
    final bottom = math.max(top + 1, (height * 0.95).round());
    final rowStep = math.max(1, (bottom - top) ~/ 512);
    final means = List<double>.filled(width, 0);
    final variances = List<double>.filled(width, 0);
    for (var x = analysisStart; x <= analysisEnd; x++) {
      var sum = 0.0;
      var sumSquares = 0.0;
      var count = 0;
      for (var y = top; y < bottom; y += rowStep) {
        final pixel = source.getPixel(x, y);
        final luminance =
            pixel.r.toDouble() * 0.2126 +
            pixel.g.toDouble() * 0.7152 +
            pixel.b.toDouble() * 0.0722;
        sum += luminance;
        sumSquares += luminance * luminance;
        count++;
      }
      final mean = count == 0 ? 0.0 : sum / count;
      means[x] = mean;
      variances[x] = count == 0
          ? 0.0
          : math.max(0, sumSquares / count - mean * mean);
    }
    final smoothMeans = _movingAverage(
      means,
      analysisStart,
      analysisEnd,
      smoothRadius,
    );
    final smoothVariances = _movingAverage(
      variances,
      analysisStart,
      analysisEnd,
      smoothRadius,
    );
    final candidateMeans = smoothMeans.sublist(searchStart, searchEnd + 1);
    final candidateVariances = smoothVariances.sublist(
      searchStart,
      searchEnd + 1,
    );
    final minMean = candidateMeans.reduce(math.min);
    final maxMean = candidateMeans.reduce(math.max);
    final minVariance = candidateVariances.reduce(math.min);
    final maxVariance = candidateVariances.reduce(math.max);
    final meanRange = math.max(1, maxMean - minMean);
    final varianceRange = math.max(1, maxVariance - minVariance);
    var bestX = center;
    var bestScore = -1.0;
    var bestValleyStrength = 0.0;
    var bestDarkness = 0.0;
    var bestCenterPrior = 0.0;
    for (var x = searchStart; x <= searchEnd; x++) {
      final mean = smoothMeans[x];
      final darkness = ((maxMean - mean) / meanRange).clamp(0.0, 1.0);
      final calmness = ((maxVariance - smoothVariances[x]) / varianceRange)
          .clamp(0.0, 1.0);
      final shoulders =
          (smoothMeans[x - shoulderDistance] +
              smoothMeans[x + shoulderDistance]) /
          2;
      final valleyStrength = ((shoulders - mean) / 30).clamp(0.0, 1.0);
      final centerPrior =
          (1 - (x - center).abs() / math.max(1, searchEnd - center)).clamp(
            0.0,
            1.0,
          );
      final score =
          darkness * 0.38 +
          valleyStrength * 0.32 +
          calmness * 0.18 +
          centerPrior * 0.12;
      if (score > bestScore) {
        bestScore = score;
        bestX = x;
        bestValleyStrength = valleyStrength;
        bestDarkness = darkness;
        bestCenterPrior = centerPrior;
      }
    }
    final confidence =
        (bestValleyStrength * 0.55 +
                bestDarkness * 0.30 +
                bestCenterPrior * 0.15)
            .clamp(0.0, 1.0);
    final fallback =
        confidence < minimumConfidence || bestValleyStrength < 0.08;
    return MlKitSpineDetection(
      splitX: fallback ? center : bestX,
      confidence: confidence,
      usedFallback: fallback,
    );
  }

  static List<double> _movingAverage(
    List<double> source,
    int start,
    int end,
    int radius,
  ) {
    final result = List<double>.filled(source.length, 0);
    final prefix = List<double>.filled(source.length + 1, 0);
    for (var index = start; index <= end; index++) {
      prefix[index + 1] = prefix[index] + source[index];
    }
    for (var index = start; index <= end; index++) {
      final left = math.max(start, index - radius);
      final right = math.min(end, index + radius);
      result[index] = (prefix[right + 1] - prefix[left]) / (right - left + 1);
    }
    return result;
  }
}
