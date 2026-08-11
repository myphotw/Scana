import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_boundary.dart';
import 'package:scana/services/image_processing/document_detector.dart';

class PreviewLuminanceFrame {
  const PreviewLuminanceFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rowStride,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int rowStride;
}

class PreviewCornerMapper {
  const PreviewCornerMapper._();

  /// Maps sensor-normalized preview points into the upright still-image space.
  static DocumentCorners toUpright(
    DocumentCorners corners,
    int sensorOrientation,
  ) {
    DocumentPoint rotate(DocumentPoint point) => switch (sensorOrientation) {
      90 => DocumentPoint(1 - point.y, point.x),
      180 => DocumentPoint(1 - point.x, 1 - point.y),
      270 => DocumentPoint(point.y, 1 - point.x),
      _ => point,
    };
    final points = corners.ordered.map(rotate).toList();
    final top = [...points]..sort((a, b) => a.y.compareTo(b.y));
    final topPair = top.take(2).toList()..sort((a, b) => a.x.compareTo(b.x));
    final bottomPair = top.skip(2).toList()..sort((a, b) => a.x.compareTo(b.x));
    return DocumentCorners(
      topLeft: topPair[0],
      topRight: topPair[1],
      bottomRight: bottomPair[1],
      bottomLeft: bottomPair[0],
    );
  }

  static PageBoundary boundaryToUpright(
    PageBoundary boundary,
    int sensorOrientation,
  ) {
    DocumentPoint rotate(DocumentPoint point) => switch (sensorOrientation) {
      90 => DocumentPoint(1 - point.y, point.x),
      180 => DocumentPoint(1 - point.x, 1 - point.y),
      270 => DocumentPoint(point.y, 1 - point.x),
      _ => point,
    };
    final transformed = switch (sensorOrientation) {
      90 => (boundary.left, boundary.top, boundary.right, boundary.bottom),
      180 => (boundary.bottom, boundary.left, boundary.top, boundary.right),
      270 => (boundary.right, boundary.bottom, boundary.left, boundary.top),
      _ => (boundary.top, boundary.right, boundary.bottom, boundary.left),
    };
    return PageBoundary(
      top: transformed.$1.map(rotate).toList(),
      right: transformed.$2.map(rotate).toList(),
      bottom: transformed.$3.map(rotate).toList(),
      left: transformed.$4.map(rotate).toList(),
      confidence: boundary.confidence,
      stability: boundary.stability,
      sourceWidth: 1,
      sourceHeight: 1,
      timestamp: boundary.timestamp,
      spineSide: switch (sensorOrientation) {
        180 =>
          boundary.spineSide == PageBoundarySide.left
              ? PageBoundarySide.right
              : boundary.spineSide == PageBoundarySide.right
              ? PageBoundarySide.left
              : null,
        90 || 270 => null,
        _ => boundary.spineSide,
      },
    );
  }
}

abstract interface class PreviewDocumentDetector {
  Future<DocumentDetectionResult> detect(PreviewLuminanceFrame frame);
}

class OpenCvPreviewDocumentDetector implements PreviewDocumentDetector {
  const OpenCvPreviewDocumentDetector({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.myphotw.scana/document_detector');

  final MethodChannel _channel;

  @override
  Future<DocumentDetectionResult> detect(PreviewLuminanceFrame frame) async {
    final value = await _channel
        .invokeMapMethod<String, dynamic>('detectPreviewFrame', {
          'bytes': frame.bytes,
          'width': frame.width,
          'height': frame.height,
          'rowStride': frame.rowStride,
        });
    if (value == null) {
      throw const FormatException('Preview detector returned no result.');
    }
    return documentDetectionResultFromNative(value);
  }
}

/// Makes a noisy per-frame detector safe to present and safe to use at capture.
class DocumentCornerStabilizer {
  DocumentCornerStabilizer({
    this.minimumConfidence = 0.45,
    this.requiredMatches = 3,
    this.similarDistance = 0.055,
    this.suddenMoveDistance = 0.16,
    this.smoothingFactor = 0.28,
    this.retention = const Duration(milliseconds: 750),
  });

  final double minimumConfidence;
  final int requiredMatches;
  final double similarDistance;
  final double suddenMoveDistance;
  final double smoothingFactor;
  final Duration retention;

  DocumentCorners? _candidate;
  int _candidateMatches = 0;
  DocumentCorners? _stable;
  DateTime? _lastStableSeen;
  double _confidence = 0;

  DocumentCorners? get stableNormalizedCorners => _stable;
  double get confidence => _confidence;
  bool get isStable => _stable != null;

  DocumentCorners? update(DocumentDetectionResult result, DateTime now) {
    final corners = result.corners;
    if (!result.detected ||
        corners == null ||
        result.sourceWidth <= 0 ||
        result.sourceHeight <= 0 ||
        result.confidence < minimumConfidence) {
      return miss(now);
    }
    final normalized = _normalize(
      corners,
      result.sourceWidth.toDouble(),
      result.sourceHeight.toDouble(),
    );

    final stable = _stable;
    if (stable != null) {
      final distance = _meanDistance(stable, normalized);
      if (distance <= similarDistance) {
        _stable = _lerp(stable, normalized, smoothingFactor);
        _lastStableSeen = now;
        _confidence = result.confidence;
      } else if (distance > suddenMoveDistance) {
        _trackCandidate(normalized);
        _expireIfNeeded(now);
      } else {
        _trackCandidate(normalized);
        if (_candidateMatches >= requiredMatches) {
          _stable = _lerp(stable, _candidate!, smoothingFactor);
          _lastStableSeen = now;
          _confidence = result.confidence;
          _resetCandidate();
        }
      }
      return _stable;
    }

    _trackCandidate(normalized);
    if (_candidateMatches >= requiredMatches) {
      _stable = _candidate;
      _lastStableSeen = now;
      _confidence = result.confidence;
      _resetCandidate();
    }
    return _stable;
  }

  DocumentCorners? miss(DateTime now) {
    _expireIfNeeded(now);
    return _stable;
  }

  void reset() {
    _stable = null;
    _lastStableSeen = null;
    _confidence = 0;
    _resetCandidate();
  }

  void _trackCandidate(DocumentCorners value) {
    final candidate = _candidate;
    if (candidate != null &&
        _meanDistance(candidate, value) <= similarDistance) {
      _candidate = _lerp(candidate, value, smoothingFactor);
      _candidateMatches++;
    } else {
      _candidate = value;
      _candidateMatches = 1;
    }
  }

  void _expireIfNeeded(DateTime now) {
    final lastSeen = _lastStableSeen;
    if (lastSeen != null && now.difference(lastSeen) > retention) {
      _stable = null;
      _lastStableSeen = null;
      _confidence = 0;
    }
  }

  void _resetCandidate() {
    _candidate = null;
    _candidateMatches = 0;
  }

  static DocumentCorners _normalize(
    DocumentCorners corners,
    double width,
    double height,
  ) => _map(
    corners,
    (point) => DocumentPoint(point.x / width, point.y / height),
  );

  static DocumentCorners _lerp(
    DocumentCorners first,
    DocumentCorners second,
    double amount,
  ) => _mapIndexed(first, second, (a, b) {
    return DocumentPoint(
      a.x + (b.x - a.x) * amount,
      a.y + (b.y - a.y) * amount,
    );
  });

  static double _meanDistance(DocumentCorners a, DocumentCorners b) {
    var total = 0.0;
    for (var index = 0; index < 4; index++) {
      final dx = a.ordered[index].x - b.ordered[index].x;
      final dy = a.ordered[index].y - b.ordered[index].y;
      total += math.sqrt(dx * dx + dy * dy);
    }
    return total / 4;
  }

  static DocumentCorners _map(
    DocumentCorners source,
    DocumentPoint Function(DocumentPoint) transform,
  ) => DocumentCorners(
    topLeft: transform(source.topLeft),
    topRight: transform(source.topRight),
    bottomRight: transform(source.bottomRight),
    bottomLeft: transform(source.bottomLeft),
  );

  static DocumentCorners _mapIndexed(
    DocumentCorners first,
    DocumentCorners second,
    DocumentPoint Function(DocumentPoint, DocumentPoint) transform,
  ) => DocumentCorners(
    topLeft: transform(first.topLeft, second.topLeft),
    topRight: transform(first.topRight, second.topRight),
    bottomRight: transform(first.bottomRight, second.bottomRight),
    bottomLeft: transform(first.bottomLeft, second.bottomLeft),
  );
}

class PageBoundaryStabilizer {
  PageBoundaryStabilizer({
    this.minimumConfidence = 0.45,
    this.requiredMatches = 3,
    this.similarDistance = 0.055,
    this.suddenMoveDistance = 0.16,
    this.smoothingFactor = 0.28,
    this.retention = const Duration(milliseconds: 750),
    this.samplesPerEdge = 24,
    this.maximumSuddenShrink = 0.28,
    this.shrinkConfirmationMatches = 5,
  });

  final double minimumConfidence;
  final int requiredMatches;
  final double similarDistance;
  final double suddenMoveDistance;
  final double smoothingFactor;
  final Duration retention;
  final int samplesPerEdge;
  final double maximumSuddenShrink;
  final int shrinkConfirmationMatches;

  PageBoundary? _candidate;
  int _candidateMatches = 0;
  PageBoundary? _stable;
  DateTime? _lastStableSeen;

  PageBoundary? get stableNormalizedBoundary => _stable;
  PageBoundary? get visibleNormalizedBoundary => _stable ?? _candidate;
  bool get isStable => _stable != null;

  PageBoundary? update(DocumentDetectionResult result, DateTime now) {
    final source =
        result.boundary ??
        (result.corners == null ||
                result.sourceWidth <= 0 ||
                result.sourceHeight <= 0
            ? null
            : PageBoundary.fromCorners(
                result.corners!,
                sourceWidth: result.sourceWidth,
                sourceHeight: result.sourceHeight,
                confidence: result.confidence,
                timestamp: now,
              ));
    if (!result.detected ||
        source == null ||
        !source.isValid ||
        result.confidence < minimumConfidence) {
      return miss(now);
    }
    final normalized = _resample(source.normalized());
    final stable = _stable;
    if (stable != null) {
      if (_isAbruptShrink(stable, normalized)) {
        _trackCandidate(normalized, now);
        if (_candidateMatches >= shrinkConfirmationMatches) {
          _stable = _candidate!.copyWith(
            stability: 1,
            confidence: result.confidence,
            timestamp: now,
          );
          _lastStableSeen = now;
          _resetCandidate();
        } else {
          _expireIfNeeded(now);
        }
        return _stable;
      }
      final distance = _meanDistance(stable, normalized);
      if (distance <= similarDistance) {
        _stable = _lerp(
          stable,
          normalized,
          smoothingFactor,
        ).copyWith(stability: 1, confidence: result.confidence, timestamp: now);
        _lastStableSeen = now;
      } else if (distance > suddenMoveDistance) {
        _trackCandidate(normalized, now);
        _expireIfNeeded(now);
      } else {
        _trackCandidate(normalized, now);
        if (_candidateMatches >= requiredMatches) {
          _stable = _lerp(stable, _candidate!, smoothingFactor).copyWith(
            stability: 1,
            confidence: result.confidence,
            timestamp: now,
          );
          _lastStableSeen = now;
          _resetCandidate();
        }
      }
      return _stable;
    }
    _trackCandidate(normalized, now);
    if (_candidateMatches >= requiredMatches) {
      _stable = _candidate!.copyWith(stability: 1, timestamp: now);
      _lastStableSeen = now;
      _resetCandidate();
    }
    return _stable;
  }

  PageBoundary? miss(DateTime now) {
    _expireIfNeeded(now);
    final candidate = _candidate;
    if (_stable == null &&
        candidate != null &&
        now.difference(candidate.timestamp) > retention) {
      _resetCandidate();
    }
    return _stable;
  }

  void reset() {
    _stable = null;
    _lastStableSeen = null;
    _resetCandidate();
  }

  void _trackCandidate(PageBoundary boundary, DateTime now) {
    final candidate = _candidate;
    if (candidate != null &&
        _meanDistance(candidate, boundary) <= similarDistance) {
      _candidate = _lerp(candidate, boundary, smoothingFactor);
      _candidateMatches++;
    } else {
      _candidate = boundary;
      _candidateMatches = 1;
    }
    _candidate = _candidate!.copyWith(
      stability: (_candidateMatches / requiredMatches).clamp(0, 1),
      timestamp: now,
    );
  }

  void _expireIfNeeded(DateTime now) {
    final lastSeen = _lastStableSeen;
    if (lastSeen != null && now.difference(lastSeen) > retention) {
      _stable = null;
      _lastStableSeen = null;
    }
  }

  void _resetCandidate() {
    _candidate = null;
    _candidateMatches = 0;
  }

  PageBoundary _resample(PageBoundary boundary) => boundary.copyWith(
    top: _resampleEdge(boundary.top, samplesPerEdge),
    right: _resampleEdge(boundary.right, samplesPerEdge),
    bottom: _resampleEdge(boundary.bottom, samplesPerEdge),
    left: _resampleEdge(boundary.left, samplesPerEdge),
  );

  static List<DocumentPoint> _resampleEdge(
    List<DocumentPoint> points,
    int count,
  ) {
    if (points.length == count) return points;
    final lengths = List<double>.filled(points.length, 0);
    for (var index = 1; index < points.length; index++) {
      final dx = points[index].x - points[index - 1].x;
      final dy = points[index].y - points[index - 1].y;
      lengths[index] = lengths[index - 1] + math.sqrt(dx * dx + dy * dy);
    }
    final total = lengths.last;
    if (total == 0) return List.filled(count, points.first);
    var segment = 1;
    return List.generate(count, (index) {
      final target = total * index / (count - 1);
      while (segment < lengths.length - 1 && lengths[segment] < target) {
        segment++;
      }
      final before = segment - 1;
      final span = lengths[segment] - lengths[before];
      final ratio = span == 0 ? 0.0 : (target - lengths[before]) / span;
      return DocumentPoint(
        points[before].x + (points[segment].x - points[before].x) * ratio,
        points[before].y + (points[segment].y - points[before].y) * ratio,
      );
    });
  }

  static PageBoundary _lerp(PageBoundary a, PageBoundary b, double amount) {
    List<DocumentPoint> edge(
      List<DocumentPoint> first,
      List<DocumentPoint> second,
    ) => List.generate(first.length, (index) {
      return DocumentPoint(
        first[index].x + (second[index].x - first[index].x) * amount,
        first[index].y + (second[index].y - first[index].y) * amount,
      );
    });
    return b.copyWith(
      top: edge(a.top, b.top),
      right: edge(a.right, b.right),
      bottom: edge(a.bottom, b.bottom),
      left: edge(a.left, b.left),
    );
  }

  static double _meanDistance(PageBoundary a, PageBoundary b) {
    final first = a.closedPolygon;
    final second = b.closedPolygon;
    var total = 0.0;
    for (var index = 0; index < first.length; index++) {
      final dx = first[index].x - second[index].x;
      final dy = first[index].y - second[index].y;
      total += math.sqrt(dx * dx + dy * dy);
    }
    return total / first.length;
  }

  bool _isAbruptShrink(PageBoundary stable, PageBoundary next) {
    final stableArea = _polygonArea(stable.closedPolygon);
    final nextArea = _polygonArea(next.closedPolygon);
    final stableHeight = _verticalExtent(stable.closedPolygon);
    final nextHeight = _verticalExtent(next.closedPolygon);
    final retainedArea = stableArea <= 0 ? 1.0 : nextArea / stableArea;
    final retainedHeight = stableHeight <= 0 ? 1.0 : nextHeight / stableHeight;
    final minimumRetained = 1 - maximumSuddenShrink;
    return retainedArea < minimumRetained || retainedHeight < minimumRetained;
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

  static double _verticalExtent(List<DocumentPoint> points) {
    final ys = points.map((point) => point.y);
    return ys.reduce(math.max) - ys.reduce(math.min);
  }
}

/// Throttles preview analysis and guarantees at most one native request.
class LiveDocumentDetectionController extends ChangeNotifier {
  LiveDocumentDetectionController({
    required this.detector,
    PageBoundaryStabilizer? boundaryStabilizer,
    this.clock = DateTime.now,
    this.analysisInterval = const Duration(milliseconds: 250),
  }) : _boundaryStabilizer = boundaryStabilizer ?? PageBoundaryStabilizer();

  final PreviewDocumentDetector detector;
  final PageBoundaryStabilizer _boundaryStabilizer;
  final DateTime Function() clock;
  final Duration analysisInterval;
  bool _isAnalyzing = false;
  DateTime? _lastAnalysisStarted;

  bool get isAnalyzing => _isAnalyzing;
  bool get canAccept {
    final last = _lastAnalysisStarted;
    return !_isAnalyzing &&
        (last == null || clock().difference(last) >= analysisInterval);
  }

  bool get hasStableDocument => _boundaryStabilizer.isStable;
  PageBoundary? get stableNormalizedBoundary =>
      _boundaryStabilizer.stableNormalizedBoundary;
  PageBoundary? get visibleNormalizedBoundary =>
      _boundaryStabilizer.visibleNormalizedBoundary;
  DocumentCorners? get stableNormalizedCorners =>
      stableNormalizedBoundary?.toDocumentCorners();

  Future<bool> submit(PreviewLuminanceFrame frame) async {
    final now = clock();
    if (_isAnalyzing ||
        (_lastAnalysisStarted != null &&
            now.difference(_lastAnalysisStarted!) < analysisInterval)) {
      return false;
    }
    _isAnalyzing = true;
    _lastAnalysisStarted = now;
    try {
      final result = await detector.detect(frame);
      _boundaryStabilizer.update(result, clock());
      notifyListeners();
    } on Object {
      _boundaryStabilizer.miss(clock());
      notifyListeners();
    } finally {
      _isAnalyzing = false;
    }
    return true;
  }

  void reset() {
    _boundaryStabilizer.reset();
    notifyListeners();
  }
}
