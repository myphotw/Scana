import 'dart:ui';

/// A point in the original image's pixel coordinate space.
class DocumentPoint {
  const DocumentPoint(this.x, this.y);

  final double x;
  final double y;

  Offset toOffset() => Offset(x, y);

  Map<String, double> toJson() => {'x': x, 'y': y};

  static DocumentPoint? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final x = value['x'];
    final y = value['y'];
    if (x is! num || y is! num) {
      return null;
    }
    return DocumentPoint(x.toDouble(), y.toDouble());
  }
}

/// Corners are always ordered clockwise from the top-left.
class DocumentCorners {
  const DocumentCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  final DocumentPoint topLeft;
  final DocumentPoint topRight;
  final DocumentPoint bottomRight;
  final DocumentPoint bottomLeft;

  List<DocumentPoint> get ordered => [
    topLeft,
    topRight,
    bottomRight,
    bottomLeft,
  ];

  DocumentCorners replaceAt(int index, DocumentPoint point) {
    final points = ordered;
    points[index] = point;
    return DocumentCorners(
      topLeft: points[0],
      topRight: points[1],
      bottomRight: points[2],
      bottomLeft: points[3],
    );
  }

  Map<String, Object> toJson() => {
    'topLeft': topLeft.toJson(),
    'topRight': topRight.toJson(),
    'bottomRight': bottomRight.toJson(),
    'bottomLeft': bottomLeft.toJson(),
  };

  static DocumentCorners? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final topLeft = DocumentPoint.fromJson(value['topLeft']);
    final topRight = DocumentPoint.fromJson(value['topRight']);
    final bottomRight = DocumentPoint.fromJson(value['bottomRight']);
    final bottomLeft = DocumentPoint.fromJson(value['bottomLeft']);
    if (topLeft == null ||
        topRight == null ||
        bottomRight == null ||
        bottomLeft == null) {
      return null;
    }
    return DocumentCorners(
      topLeft: topLeft,
      topRight: topRight,
      bottomRight: bottomRight,
      bottomLeft: bottomLeft,
    );
  }
}

/// Result returned by a detector independently of camera or editor UI.
class DocumentDetectionResult {
  const DocumentDetectionResult({
    required this.detected,
    required this.confidence,
    required this.sourceWidth,
    required this.sourceHeight,
    this.corners,
  });

  final bool detected;
  final DocumentCorners? corners;
  final double confidence;
  final int sourceWidth;
  final int sourceHeight;
}
