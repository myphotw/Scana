enum EnhancementMode { scanColor, originalColor, grayscale, blackWhite }

enum EnhancementStatus { none, processing, completed, failed }

extension EnhancementModeLabel on EnhancementMode {
  String get label => switch (this) {
    EnhancementMode.scanColor => '스캔',
    EnhancementMode.originalColor => '원본',
    EnhancementMode.grayscale => '그레이',
    EnhancementMode.blackWhite => '흑백',
  };
}

class PageEnhancementResult {
  const PageEnhancementResult({
    required this.outputWidth,
    required this.outputHeight,
    required this.processingMilliseconds,
    this.stageTimings = const {},
  });

  final int outputWidth;
  final int outputHeight;
  final int processingMilliseconds;
  final Map<String, int> stageTimings;
}
