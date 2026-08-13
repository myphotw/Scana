class ImageQualityMetrics {
  const ImageQualityMetrics({
    required this.width,
    required this.height,
    required this.sharpness,
    required this.foregroundSharpness,
    required this.foregroundPixels,
    this.backgroundVariance = 0,
    this.darkSpeckleRatio = 0,
    this.backgroundPixels = 0,
  });

  factory ImageQualityMetrics.fromNative(
    Map<Object?, Object?>? value,
    String prefix,
  ) {
    final width = value?['${prefix}Width'];
    final height = value?['${prefix}Height'];
    final sharpness = value?['${prefix}Sharpness'];
    final foregroundSharpness = value?['${prefix}ForegroundSharpness'];
    final foregroundPixels = value?['${prefix}ForegroundPixels'];
    final backgroundVariance = value?['${prefix}BackgroundVariance'] ?? 0;
    final darkSpeckleRatio = value?['${prefix}DarkSpeckleRatio'] ?? 0;
    final backgroundPixels = value?['${prefix}BackgroundPixels'] ?? 0;
    if (width is! int ||
        height is! int ||
        sharpness is! num ||
        foregroundSharpness is! num ||
        foregroundPixels is! int ||
        backgroundVariance is! num ||
        darkSpeckleRatio is! num ||
        backgroundPixels is! int ||
        width <= 0 ||
        height <= 0 ||
        !sharpness.isFinite ||
        !foregroundSharpness.isFinite ||
        !backgroundVariance.isFinite ||
        !darkSpeckleRatio.isFinite ||
        foregroundPixels < 0 ||
        backgroundVariance < 0 ||
        darkSpeckleRatio < 0 ||
        darkSpeckleRatio > 1 ||
        backgroundPixels < 0) {
      return const ImageQualityMetrics.empty();
    }
    return ImageQualityMetrics(
      width: width,
      height: height,
      sharpness: sharpness.toDouble(),
      foregroundSharpness: foregroundSharpness.toDouble(),
      foregroundPixels: foregroundPixels,
      backgroundVariance: backgroundVariance.toDouble(),
      darkSpeckleRatio: darkSpeckleRatio.toDouble(),
      backgroundPixels: backgroundPixels,
    );
  }

  const ImageQualityMetrics.empty()
    : width = 0,
      height = 0,
      sharpness = 0,
      foregroundSharpness = 0,
      foregroundPixels = 0,
      backgroundVariance = 0,
      darkSpeckleRatio = 0,
      backgroundPixels = 0;

  final int width;
  final int height;
  final double sharpness;
  final double foregroundSharpness;
  final int foregroundPixels;
  final double backgroundVariance;
  final double darkSpeckleRatio;
  final int backgroundPixels;

  bool get isAvailable => width > 0 && height > 0;

  Map<String, Object> toJson() => {
    'width': width,
    'height': height,
    'sharpness': sharpness,
    'foregroundSharpness': foregroundSharpness,
    'foregroundPixels': foregroundPixels,
    'backgroundVariance': backgroundVariance,
    'darkSpeckleRatio': darkSpeckleRatio,
    'backgroundPixels': backgroundPixels,
  };
}
