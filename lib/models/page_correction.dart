import 'package:scana/models/image_quality.dart';

enum CorrectionStatus { none, processing, completed, failed }

enum CorrectionType { perspective, curved }

enum CurvatureState { none, flat, mildCurve, strongCurve, unreliable }

enum CorrectionOutcome {
  none,
  completed,
  nearlyFlat,
  lowConfidence,
  unsafeDeformation,
  notImproved,
}

class PageCorrectionResult {
  const PageCorrectionResult({
    required this.outputWidth,
    required this.outputHeight,
    this.outcome = CorrectionOutcome.completed,
    this.diagnostics = const {},
    this.sourceQuality = const ImageQualityMetrics.empty(),
    this.outputQuality = const ImageQualityMetrics.empty(),
    this.outputFormat,
  });

  final int outputWidth;
  final int outputHeight;
  final CorrectionOutcome outcome;
  final Map<String, Object> diagnostics;
  final ImageQualityMetrics sourceQuality;
  final ImageQualityMetrics outputQuality;
  final String? outputFormat;

  CurvatureState get curvatureState => CurvatureState.values.firstWhere(
    (state) => state.name == diagnostics['curvatureState'],
    orElse: () => CurvatureState.none,
  );

  double? get curvatureMagnitude =>
      (diagnostics['curvatureMagnitude'] as num?)?.toDouble();

  double? get curvedConfidence =>
      (diagnostics['confidence'] as num?)?.toDouble();
}
