enum CorrectionStatus { none, processing, completed, failed }

enum CorrectionType { perspective, curved }

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
  });

  final int outputWidth;
  final int outputHeight;
  final CorrectionOutcome outcome;
}
