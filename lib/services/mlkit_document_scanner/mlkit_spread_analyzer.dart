import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as image;

import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_document_scanner.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_spread_splitter.dart';

class MlKitSpreadSignals {
  const MlKitSpreadSignals({
    this.aspectRatio = 0,
    this.luminanceValleyScore = 0,
    this.gutterShadowScore = 0,
    this.verticalGradientScore = 0,
    this.columnVarianceScore = 0,
    this.gutterContinuityScore = 0,
    this.leftContentScore = 0,
    this.rightContentScore = 0,
    this.contentBalanceScore = 0,
    this.pageStructureScore = 0,
  });

  final double aspectRatio;
  final double luminanceValleyScore;
  final double gutterShadowScore;
  final double verticalGradientScore;
  final double columnVarianceScore;
  final double gutterContinuityScore;
  final double leftContentScore;
  final double rightContentScore;
  final double contentBalanceScore;
  final double pageStructureScore;
}

class MlKitSpreadAnalysis {
  const MlKitSpreadAnalysis({
    required this.layout,
    required this.splitX,
    required this.confidence,
    required this.fallbackUsed,
    this.signals = const MlKitSpreadSignals(),
    this.rejectReason = 'none',
  });

  final MlKitPageLayout layout;
  final int splitX;
  final double confidence;
  final bool fallbackUsed;
  final MlKitSpreadSignals signals;
  final String rejectReason;

  bool get isSpread => layout == MlKitPageLayout.spread;

  MlKitSpineDetection get detection => MlKitSpineDetection(
    splitX: splitX,
    confidence: confidence,
    usedFallback: fallbackUsed,
  );
}

abstract interface class MlKitSpreadAnalyzer {
  Future<MlKitSpreadAnalysis> analyze(MlKitScannedPage source);
}

/// Conservative single/spread classifier for already corrected ML Kit pages.
class ConservativeMlKitSpreadAnalyzer implements MlKitSpreadAnalyzer {
  const ConservativeMlKitSpreadAnalyzer();

  static const double spreadThreshold = 0.72;
  static const double uncertainThreshold = 0.45;

  @override
  Future<MlKitSpreadAnalysis> analyze(MlKitScannedPage source) async {
    final decoded = image.decodeImage(await File(source.filePath).readAsBytes());
    if (decoded == null) {
      throw const FormatException('ML Kit page could not be decoded.');
    }
    return analyzeImage(decoded);
  }

  static MlKitSpreadAnalysis analyzeImage(image.Image source) {
    if (source.width < 20 || source.height < 10) {
      return MlKitSpreadAnalysis(
        layout: MlKitPageLayout.single,
        splitX: source.width ~/ 2,
        confidence: 0,
        fallbackUsed: true,
        signals: MlKitSpreadSignals(
          aspectRatio: source.width / math.max(1, source.height),
        ),
        rejectReason: 'image_too_small',
      );
    }

    final spine = LosslessMlKitSpreadSplitter.detectSpine(source);
    final gutter = _findGutterCandidate(source, preferredX: spine.splitX);
    final candidateSplitX = spine.usedFallback ? gutter.splitX : spine.splitX;
    final left = _pageSideEvidence(
      source,
      0.04,
      candidateSplitX / source.width - 0.025,
    );
    final right = _pageSideEvidence(
      source,
      candidateSplitX / source.width + 0.025,
      0.96,
    );
    final contentBalance = _balance(left.contentScore, right.contentScore);
    final pageStructure = math.sqrt(left.structureScore * right.structureScore);
    final aspectRatio = source.width / math.max(1, source.height);
    final landscapeScore = ((aspectRatio - 1.10) / 0.38).clamp(0.0, 1.0);
    final gutterContinuity = _gutterContinuity(source, candidateSplitX);
    final shadowScore = math.max(spine.confidence, gutter.shadowScore);
    final centralGutter = math.max(
      shadowScore * 0.70 + gutterContinuity * 0.30,
      gutter.lowDensityScore * 0.55 +
          gutter.columnVarianceScore * 0.20 +
          gutter.verticalGradientScore * 0.25,
    );
    final dualContent =
        math.sqrt(left.contentScore * right.contentScore) * contentBalance;
    var confidence =
        centralGutter * 0.30 +
        dualContent * 0.34 +
        pageStructure * 0.24 +
        landscapeScore * 0.12;

    // A weakly shaded book gutter is common in bright sheet music. Promote the
    // conjunction of two page-like content fields and a real central gap; no
    // individual landscape or center-line signal can activate this fast path.
    final clearDualPage =
        aspectRatio >= 1.28 &&
        left.contentScore >= 0.52 &&
        right.contentScore >= 0.52 &&
        contentBalance >= 0.68 &&
        pageStructure >= 0.50 &&
        centralGutter >= 0.44;
    if (clearDualPage) {
      confidence = math.max(confidence, spreadThreshold + 0.03);
    }
    confidence = confidence.clamp(0.0, 1.0);

    final (layout, rejectReason) = _classify(
      confidence: confidence,
      aspectRatio: aspectRatio,
      leftContent: left.contentScore,
      rightContent: right.contentScore,
      contentBalance: contentBalance,
      pageStructure: pageStructure,
      centralGutter: centralGutter,
    );
    return MlKitSpreadAnalysis(
      layout: layout,
      splitX: layout == MlKitPageLayout.spread
          ? candidateSplitX
          : source.width ~/ 2,
      confidence: confidence,
      fallbackUsed: layout != MlKitPageLayout.spread,
      signals: MlKitSpreadSignals(
        aspectRatio: aspectRatio,
        luminanceValleyScore: spine.confidence,
        gutterShadowScore: shadowScore,
        verticalGradientScore: gutter.verticalGradientScore,
        columnVarianceScore: gutter.columnVarianceScore,
        gutterContinuityScore: gutterContinuity,
        leftContentScore: left.contentScore,
        rightContentScore: right.contentScore,
        contentBalanceScore: contentBalance,
        pageStructureScore: pageStructure,
      ),
      rejectReason: rejectReason,
    );
  }

  static (MlKitPageLayout, String) _classify({
    required double confidence,
    required double aspectRatio,
    required double leftContent,
    required double rightContent,
    required double contentBalance,
    required double pageStructure,
    required double centralGutter,
  }) {
    if (aspectRatio < 1.10) return (MlKitPageLayout.single, 'not_landscape');
    if (math.min(leftContent, rightContent) < 0.34) {
      return (MlKitPageLayout.single, 'one_sided_content');
    }
    if (contentBalance < 0.48) {
      return (MlKitPageLayout.single, 'content_unbalanced');
    }
    if (pageStructure < 0.38) {
      return (MlKitPageLayout.single, 'not_page_like');
    }
    if (centralGutter < 0.32) {
      return confidence < uncertainThreshold
          ? (MlKitPageLayout.single, 'no_central_gutter')
          : (MlKitPageLayout.uncertain, 'weak_central_gutter');
    }
    if (confidence >= spreadThreshold) {
      return (MlKitPageLayout.spread, 'none');
    }
    return confidence < uncertainThreshold
        ? (MlKitPageLayout.single, 'low_confidence')
        : (MlKitPageLayout.uncertain, 'below_spread_threshold');
  }

  static _GutterEvidence _findGutterCandidate(
    image.Image source, {
    required int preferredX,
  }) {
    final start = (source.width * 0.35).round();
    final end = (source.width * 0.65).round();
    final shoulder = math.max(3, (source.width * 0.035).round());
    final band = math.max(2, (source.width * 0.009).round());
    var best = _GutterEvidence(splitX: preferredX.clamp(start, end));
    for (var x = start; x <= end; x++) {
      final center = _columnStats(source, x, band);
      final left = _columnStats(source, x - shoulder, band);
      final right = _columnStats(source, x + shoulder, band);
      final shoulderDark = (left.darkDensity + right.darkDensity) / 2;
      final shoulderMean = (left.mean + right.mean) / 2;
      final lowDensity = ((shoulderDark - center.darkDensity) / 0.10).clamp(
        0.0,
        1.0,
      );
      final shadow = ((shoulderMean - center.mean) / 30).clamp(0.0, 1.0);
      final gradient =
          ((center.mean - math.min(left.mean, right.mean)).abs() / 34).clamp(
            0.0,
            1.0,
          );
      final calmness = (1 - center.standardDeviation / 70).clamp(0.0, 1.0);
      final centerPrior =
          (1 -
                  (x - source.width / 2).abs() /
                      math.max(1, (end - start) / 2))
              .clamp(0.0, 1.0);
      final score =
          math.max(lowDensity, shadow) * 0.48 +
          calmness * 0.18 +
          gradient * 0.22 +
          centerPrior * 0.12;
      if (score > best.score) {
        best = _GutterEvidence(
          splitX: x,
          score: score,
          lowDensityScore: lowDensity,
          shadowScore: shadow,
          verticalGradientScore: gradient,
          columnVarianceScore: calmness,
        );
      }
    }
    return best;
  }

  static _ColumnStats _columnStats(
    image.Image source,
    int centerX,
    int radius,
  ) {
    final left = (centerX - radius).clamp(0, source.width - 1);
    final right = (centerX + radius).clamp(left, source.width - 1);
    final top = (source.height * 0.05).round();
    final bottom = math.max(top + 1, (source.height * 0.95).round());
    final yStep = math.max(1, (bottom - top) ~/ 256);
    var sum = 0.0;
    var sumSquares = 0.0;
    var dark = 0;
    var count = 0;
    for (var x = left; x <= right; x++) {
      for (var y = top; y < bottom; y += yStep) {
        final value = _luminance(source.getPixel(x, y));
        sum += value;
        sumSquares += value * value;
        if (value < 205) dark++;
        count++;
      }
    }
    if (count == 0) return const _ColumnStats();
    final mean = sum / count;
    return _ColumnStats(
      mean: mean,
      standardDeviation: math.sqrt(
        math.max(0, sumSquares / count - mean * mean),
      ),
      darkDensity: dark / count,
    );
  }

  static _PageSideEvidence _pageSideEvidence(
    image.Image source,
    double startFraction,
    double endFraction,
  ) {
    final start = (source.width * startFraction.clamp(0.0, 1.0)).round();
    final end = (source.width * endFraction.clamp(0.0, 1.0)).round();
    if (end - start < 4) return const _PageSideEvidence();
    final top = (source.height * 0.05).round();
    final bottom = math.max(top + 1, (source.height * 0.95).round());
    const rows = 10;
    const columns = 8;
    final darkByRow = List<int>.filled(rows, 0);
    final totalByRow = List<int>.filled(rows, 0);
    final darkByColumn = List<int>.filled(columns, 0);
    final totalByColumn = List<int>.filled(columns, 0);
    final xStep = math.max(1, (end - start) ~/ 128);
    final yStep = math.max(1, (bottom - top) ~/ 160);
    var dark = 0;
    var bright = 0;
    var count = 0;
    for (var x = start; x < end; x += xStep) {
      final column =
          (((x - start) * columns) ~/ math.max(1, end - start)).clamp(
            0,
            columns - 1,
          );
      for (var y = top; y < bottom; y += yStep) {
        final row =
            (((y - top) * rows) ~/ math.max(1, bottom - top)).clamp(
              0,
              rows - 1,
            );
        final value = _luminance(source.getPixel(x, y));
        final isDark = value < 205;
        if (isDark) {
          dark++;
          darkByRow[row]++;
          darkByColumn[column]++;
        }
        if (value > 225) bright++;
        totalByRow[row]++;
        totalByColumn[column]++;
        count++;
      }
    }
    if (count == 0) return const _PageSideEvidence();
    final darkDensity = dark / count;
    final brightDensity = bright / count;
    final contentAmount = ((darkDensity - 0.008) / 0.07).clamp(0.0, 1.0);
    final photoPenalty = ((darkDensity - 0.48) / 0.24).clamp(0.0, 1.0);
    final paperScore = ((brightDensity - 0.28) / 0.48).clamp(0.0, 1.0);
    final rowCoverage = _coverage(darkByRow, totalByRow, 0.008);
    final columnCoverage = _coverage(darkByColumn, totalByColumn, 0.008);
    final contentScore =
        contentAmount *
        (0.58 + paperScore * 0.42) *
        (1 - photoPenalty * 0.75);
    final structureScore =
        contentScore * 0.38 +
        paperScore * 0.24 +
        rowCoverage * 0.22 +
        columnCoverage * 0.16;
    return _PageSideEvidence(
      contentScore: contentScore.clamp(0.0, 1.0),
      structureScore: structureScore.clamp(0.0, 1.0),
    );
  }

  static double _coverage(List<int> dark, List<int> total, double minimum) {
    var covered = 0;
    for (var index = 0; index < dark.length; index++) {
      if (total[index] > 0 && dark[index] / total[index] >= minimum) covered++;
    }
    return covered / dark.length;
  }

  static double _gutterContinuity(image.Image source, int splitX) {
    final shoulder = math.max(2, (source.width * 0.035).round());
    final top = (source.height * 0.05).round();
    final bottom = math.max(top + 1, (source.height * 0.95).round());
    final step = math.max(1, (bottom - top) ~/ 256);
    var matching = 0;
    var count = 0;
    for (var y = top; y < bottom; y += step) {
      final center = _luminance(source.getPixel(splitX, y));
      final left = _luminance(
        source.getPixel((splitX - shoulder).clamp(0, source.width - 1), y),
      );
      final right = _luminance(
        source.getPixel((splitX + shoulder).clamp(0, source.width - 1), y),
      );
      final shoulders = (left + right) / 2;
      if ((shoulders - center).abs() >= 10) matching++;
      count++;
    }
    return count == 0 ? 0 : matching / count;
  }

  static double _balance(double left, double right) {
    final maximum = math.max(left, right);
    return maximum <= 0.001
        ? 0
        : (math.min(left, right) / maximum).clamp(0.0, 1.0);
  }

  static double _luminance(image.Pixel pixel) =>
      pixel.r.toDouble() * 0.2126 +
      pixel.g.toDouble() * 0.7152 +
      pixel.b.toDouble() * 0.0722;
}

class _GutterEvidence {
  const _GutterEvidence({
    required this.splitX,
    this.score = -1,
    this.lowDensityScore = 0,
    this.shadowScore = 0,
    this.verticalGradientScore = 0,
    this.columnVarianceScore = 0,
  });

  final int splitX;
  final double score;
  final double lowDensityScore;
  final double shadowScore;
  final double verticalGradientScore;
  final double columnVarianceScore;
}

class _ColumnStats {
  const _ColumnStats({
    this.mean = 0,
    this.standardDeviation = 0,
    this.darkDensity = 0,
  });

  final double mean;
  final double standardDeviation;
  final double darkDensity;
}

class _PageSideEvidence {
  const _PageSideEvidence({this.contentScore = 0, this.structureScore = 0});

  final double contentScore;
  final double structureScore;
}
