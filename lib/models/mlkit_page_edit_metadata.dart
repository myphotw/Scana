enum MlKitPageLayout { single, spread, uncertain }

enum MlKitSpreadSide { left, right }

/// A normalized axis-aligned crop in the original editable ML Kit image.
class MlKitCropRect {
  const MlKitCropRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  static const full = MlKitCropRect(left: 0, top: 0, right: 1, bottom: 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  bool get isValid =>
      left >= 0 &&
      top >= 0 &&
      right <= 1 &&
      bottom <= 1 &&
      width > 0 &&
      height > 0;

  MlKitCropRect clamped({double minimumSize = 0.01}) {
    var nextLeft = left.clamp(0.0, 1.0);
    var nextTop = top.clamp(0.0, 1.0);
    var nextRight = right.clamp(0.0, 1.0);
    var nextBottom = bottom.clamp(0.0, 1.0);
    if (nextRight - nextLeft < minimumSize) {
      nextRight = (nextLeft + minimumSize).clamp(0.0, 1.0);
      nextLeft = (nextRight - minimumSize).clamp(0.0, 1.0);
    }
    if (nextBottom - nextTop < minimumSize) {
      nextBottom = (nextTop + minimumSize).clamp(0.0, 1.0);
      nextTop = (nextBottom - minimumSize).clamp(0.0, 1.0);
    }
    return MlKitCropRect(
      left: nextLeft,
      top: nextTop,
      right: nextRight,
      bottom: nextBottom,
    );
  }

  /// Composes a crop expressed inside this rectangle back into original space.
  MlKitCropRect compose(MlKitCropRect inner) {
    final safe = inner.clamped();
    return MlKitCropRect(
      left: left + width * safe.left,
      top: top + height * safe.top,
      right: left + width * safe.right,
      bottom: top + height * safe.bottom,
    ).clamped();
  }

  /// Converts a crop drawn on a rotated preview to the unrotated crop space.
  static MlKitCropRect unrotate(MlKitCropRect value, int rotationDegrees) {
    final crop = value.clamped();
    return switch (rotationDegrees % 360) {
      90 => MlKitCropRect(
        left: crop.top,
        top: 1 - crop.right,
        right: crop.bottom,
        bottom: 1 - crop.left,
      ),
      180 => MlKitCropRect(
        left: 1 - crop.right,
        top: 1 - crop.bottom,
        right: 1 - crop.left,
        bottom: 1 - crop.top,
      ),
      270 => MlKitCropRect(
        left: 1 - crop.bottom,
        top: crop.left,
        right: 1 - crop.top,
        bottom: crop.right,
      ),
      _ => crop,
    }.clamped();
  }

  Map<String, double> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  static MlKitCropRect? fromJson(Object? value) {
    if (value is! Map) return null;
    final left = (value['left'] as num?)?.toDouble();
    final top = (value['top'] as num?)?.toDouble();
    final right = (value['right'] as num?)?.toDouble();
    final bottom = (value['bottom'] as num?)?.toDouble();
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    final result = MlKitCropRect(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
    return result.isValid ? result : null;
  }
}
