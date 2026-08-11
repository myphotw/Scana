import 'dart:math' as math;

import 'package:scana/models/document_geometry.dart';

/// A clockwise page outline. Edge directions are top L→R, right T→B,
/// bottom R→L, and left B→T.
class PageBoundary {
  PageBoundary({
    required List<DocumentPoint> top,
    required List<DocumentPoint> right,
    required List<DocumentPoint> bottom,
    required List<DocumentPoint> left,
    required this.confidence,
    required this.stability,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.timestamp,
    this.spineSide,
    this.clippingEvidence = 0,
  }) : top = List.unmodifiable(top),
       right = List.unmodifiable(right),
       bottom = List.unmodifiable(bottom),
       left = List.unmodifiable(left);

  final List<DocumentPoint> top;
  final List<DocumentPoint> right;
  final List<DocumentPoint> bottom;
  final List<DocumentPoint> left;
  final double confidence;
  final double stability;
  final int sourceWidth;
  final int sourceHeight;
  final DateTime timestamp;
  final PageBoundarySide? spineSide;

  /// Native evidence that the page contour is cut by a frame edge (0...1).
  ///
  /// This is intentionally distinct from simple edge proximity: a fully
  /// visible large page may sit close to the preview edge without being cut.
  final double clippingEvidence;

  bool get isValid {
    if (sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        top.length < 2 ||
        right.length < 2 ||
        bottom.length < 2 ||
        left.length < 2 ||
        !closedPolygon.every((point) => point.x.isFinite && point.y.isFinite)) {
      return false;
    }
    final corners = toDocumentCorners().ordered;
    return _cornerArea(corners) > 0.000001 &&
        !_segmentsIntersect(corners[0], corners[1], corners[2], corners[3]) &&
        !_segmentsIntersect(corners[1], corners[2], corners[3], corners[0]);
  }

  List<DocumentPoint> get closedPolygon => [
    ...top,
    ...right.skip(1),
    ...bottom.skip(1),
    ...left.skip(1),
  ];

  DocumentCorners toDocumentCorners() => DocumentCorners(
    topLeft: _nearestMidpoint(top, left),
    topRight: _nearestMidpoint(top, right),
    bottomRight: _nearestMidpoint(bottom, right),
    bottomLeft: _nearestMidpoint(bottom, left),
  );

  PageBoundary normalized() => mapPoints(
    (point) => DocumentPoint(point.x / sourceWidth, point.y / sourceHeight),
    sourceWidth: 1,
    sourceHeight: 1,
  );

  PageBoundary scaleTo(int width, int height) => mapPoints(
    (point) => DocumentPoint(
      point.x / sourceWidth * width,
      point.y / sourceHeight * height,
    ),
    sourceWidth: width,
    sourceHeight: height,
  );

  PageBoundary mapPoints(
    DocumentPoint Function(DocumentPoint) transform, {
    required int sourceWidth,
    required int sourceHeight,
    double? confidence,
    double? stability,
    DateTime? timestamp,
    PageBoundarySide? spineSide,
    double? clippingEvidence,
  }) => PageBoundary(
    top: top.map(transform).toList(),
    right: right.map(transform).toList(),
    bottom: bottom.map(transform).toList(),
    left: left.map(transform).toList(),
    confidence: confidence ?? this.confidence,
    stability: stability ?? this.stability,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    timestamp: timestamp ?? this.timestamp,
    spineSide: spineSide ?? this.spineSide,
    clippingEvidence: clippingEvidence ?? this.clippingEvidence,
  );

  PageBoundary copyWith({
    List<DocumentPoint>? top,
    List<DocumentPoint>? right,
    List<DocumentPoint>? bottom,
    List<DocumentPoint>? left,
    double? confidence,
    double? stability,
    int? sourceWidth,
    int? sourceHeight,
    DateTime? timestamp,
    PageBoundarySide? spineSide,
    double? clippingEvidence,
  }) => PageBoundary(
    top: top ?? this.top,
    right: right ?? this.right,
    bottom: bottom ?? this.bottom,
    left: left ?? this.left,
    confidence: confidence ?? this.confidence,
    stability: stability ?? this.stability,
    sourceWidth: sourceWidth ?? this.sourceWidth,
    sourceHeight: sourceHeight ?? this.sourceHeight,
    timestamp: timestamp ?? this.timestamp,
    spineSide: spineSide ?? this.spineSide,
    clippingEvidence: clippingEvidence ?? this.clippingEvidence,
  );

  PageBoundary withRepresentativeCorners(DocumentCorners corners) => copyWith(
    top: _replaceEndpoints(top, corners.topLeft, corners.topRight),
    right: _replaceEndpoints(right, corners.topRight, corners.bottomRight),
    bottom: _replaceEndpoints(bottom, corners.bottomRight, corners.bottomLeft),
    left: _replaceEndpoints(left, corners.bottomLeft, corners.topLeft),
  );

  Map<String, Object> toJson() => {
    'top': top.map((point) => point.toJson()).toList(),
    'right': right.map((point) => point.toJson()).toList(),
    'bottom': bottom.map((point) => point.toJson()).toList(),
    'left': left.map((point) => point.toJson()).toList(),
    'confidence': confidence,
    'stability': stability,
    'sourceWidth': sourceWidth,
    'sourceHeight': sourceHeight,
    'timestamp': timestamp.toIso8601String(),
    if (spineSide != null) 'spineSide': spineSide!.name,
    if (clippingEvidence > 0) 'clippingEvidence': clippingEvidence,
  };

  static PageBoundary? fromJson(Object? value) {
    if (value is! Map) return null;
    final top = _pointsFromJson(value['top']);
    final right = _pointsFromJson(value['right']);
    final bottom = _pointsFromJson(value['bottom']);
    final left = _pointsFromJson(value['left']);
    final confidence = value['confidence'];
    final stability = value['stability'];
    final width = value['sourceWidth'];
    final height = value['sourceHeight'];
    final timestampValue = value['timestamp'];
    final clippingEvidence = value['clippingEvidence'];
    final timestamp = timestampValue is int
        ? DateTime.fromMillisecondsSinceEpoch(timestampValue)
        : DateTime.tryParse(timestampValue?.toString() ?? '');
    if (top == null ||
        right == null ||
        bottom == null ||
        left == null ||
        confidence is! num ||
        stability is! num ||
        width is! int ||
        height is! int ||
        timestamp == null) {
      return null;
    }
    final boundary = PageBoundary(
      top: top,
      right: right,
      bottom: bottom,
      left: left,
      confidence: confidence.toDouble().clamp(0, 1),
      stability: stability.toDouble().clamp(0, 1),
      sourceWidth: width,
      sourceHeight: height,
      timestamp: timestamp,
      spineSide: PageBoundarySide.values
          .where((side) => side.name == value['spineSide'])
          .firstOrNull,
      clippingEvidence: clippingEvidence is num
          ? clippingEvidence.toDouble().clamp(0, 1)
          : 0,
    );
    return boundary.isValid ? boundary : null;
  }

  static PageBoundary fromCorners(
    DocumentCorners corners, {
    required int sourceWidth,
    required int sourceHeight,
    required double confidence,
    double stability = 0,
    required DateTime timestamp,
    double clippingEvidence = 0,
  }) => PageBoundary(
    top: [corners.topLeft, corners.topRight],
    right: [corners.topRight, corners.bottomRight],
    bottom: [corners.bottomRight, corners.bottomLeft],
    left: [corners.bottomLeft, corners.topLeft],
    confidence: confidence,
    stability: stability,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    timestamp: timestamp,
    clippingEvidence: clippingEvidence,
  );

  static List<DocumentPoint>? _pointsFromJson(Object? value) {
    if (value is! List) return null;
    final points = value.map(DocumentPoint.fromJson).toList();
    if (points.length < 2 || points.any((point) => point == null)) return null;
    return points.cast<DocumentPoint>();
  }

  static List<DocumentPoint> _replaceEndpoints(
    List<DocumentPoint> points,
    DocumentPoint start,
    DocumentPoint end,
  ) => [start, ...points.skip(1).take(points.length - 2), end];

  static DocumentPoint _nearestMidpoint(
    List<DocumentPoint> first,
    List<DocumentPoint> second,
  ) {
    var bestDistance = double.infinity;
    var bestFirst = first.first;
    var bestSecond = second.first;
    for (final a in first) {
      for (final b in second) {
        final dx = a.x - b.x;
        final dy = a.y - b.y;
        final distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestFirst = a;
          bestSecond = b;
        }
      }
    }
    return DocumentPoint(
      (bestFirst.x + bestSecond.x) / 2,
      (bestFirst.y + bestSecond.y) / 2,
    );
  }

  static double _cornerArea(List<DocumentPoint> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      sum += points[index].x * next.y - next.x * points[index].y;
    }
    return sum.abs() / 2;
  }

  static bool _segmentsIntersect(
    DocumentPoint a,
    DocumentPoint b,
    DocumentPoint c,
    DocumentPoint d,
  ) {
    double cross(DocumentPoint p, DocumentPoint q, DocumentPoint r) =>
        (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
    return cross(a, b, c) * cross(a, b, d) < 0 &&
        cross(c, d, a) * cross(c, d, b) < 0;
  }
}

enum PageBoundarySide { left, right }

enum BoundaryGuidance {
  notDetected,
  tooClose,
  tooFar,
  clipped,
  unstable,
  ready,
}

class BoundaryQualityAssessment {
  const BoundaryQualityAssessment(this.guidance);

  final BoundaryGuidance guidance;

  String get message => switch (guidance) {
    BoundaryGuidance.notDetected => '문서를 화면 안에 맞춰주세요',
    BoundaryGuidance.tooClose => '조금 더 멀리서 촬영해주세요',
    BoundaryGuidance.tooFar => '문서에 조금 더 가까이 이동해주세요',
    BoundaryGuidance.clipped => '문서 전체가 화면에 보이게 해주세요',
    BoundaryGuidance.unstable => '카메라를 잠시 고정해주세요',
    BoundaryGuidance.ready => '문서를 인식했습니다',
  };

  static BoundaryQualityAssessment evaluate(PageBoundary? boundary) {
    if (boundary == null || !boundary.isValid) {
      return const BoundaryQualityAssessment(BoundaryGuidance.notDetected);
    }
    final normalized = boundary.sourceWidth == 1 && boundary.sourceHeight == 1
        ? boundary
        : boundary.normalized();
    final points = normalized.closedPolygon;
    final minX = points.map((point) => point.x).reduce(math.min);
    final maxX = points.map((point) => point.x).reduce(math.max);
    final minY = points.map((point) => point.y).reduce(math.min);
    final maxY = points.map((point) => point.y).reduce(math.max);
    final stable = boundary.stability >= 0.99;
    final hasConfirmedClipping = stable && boundary.clippingEvidence >= 0.45;
    if (hasConfirmedClipping) {
      return const BoundaryQualityAssessment(BoundaryGuidance.clipped);
    }
    final area = _polygonArea(points);
    final isExtremelyCloseToFrame =
        minX < 0.008 || minY < 0.008 || maxX > 0.992 || maxY > 0.992;
    if (stable &&
        area >= 0.88 &&
        (boundary.clippingEvidence >= 0.2 || isExtremelyCloseToFrame)) {
      return const BoundaryQualityAssessment(BoundaryGuidance.tooClose);
    }
    if (area <= 0.12 || (area <= 0.20 && boundary.confidence < 0.70)) {
      return const BoundaryQualityAssessment(BoundaryGuidance.tooFar);
    }
    if (boundary.confidence < 0.45 || boundary.stability < 0.99) {
      return const BoundaryQualityAssessment(BoundaryGuidance.unstable);
    }
    return const BoundaryQualityAssessment(BoundaryGuidance.ready);
  }

  static double _polygonArea(List<DocumentPoint> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final current = points[index];
      final next = points[(index + 1) % points.length];
      sum += current.x * next.y - next.x * current.y;
    }
    return sum.abs() / 2;
  }
}
