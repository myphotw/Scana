import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'package:scana/models/document_geometry.dart';
import 'package:scana/models/scan_page.dart';

enum QuickCornerInitialSource {
  manual,
  aiRefined,
  aiRaw,
  openCvBoundary,
  finalCrop,
  guideFallback,
}

class QuickCornerInitialSelection {
  const QuickCornerInitialSelection({
    required this.corners,
    required this.source,
  });

  final DocumentCorners corners;
  final QuickCornerInitialSource source;
}

/// Keeps the lightweight editor's initial-value policy independent from UI.
class QuickCornerInitialPolicy {
  const QuickCornerInitialPolicy._();

  static QuickCornerInitialSelection? resolve(ScanPage page) {
    final finalCorners = page.documentCorners;
    if (finalCorners != null) {
      return QuickCornerInitialSelection(
        corners: finalCorners,
        source: page.hasUserAdjustedCorners
            ? QuickCornerInitialSource.manual
            : QuickCornerInitialSource.finalCrop,
      );
    }
    // Recovery compatibility only: pages created before final crop metadata
    // existed may still have guide corners. AI/OpenCV candidates are never
    // recomputed here because the editor must be WYSIWYG with the applied crop.
    if (page.captureGuideCorners != null) {
      return QuickCornerInitialSelection(
        corners: page.captureGuideCorners!,
        source: QuickCornerInitialSource.guideFallback,
      );
    }
    return null;
  }
}

class QuickCornerValidationPolicy {
  const QuickCornerValidationPolicy._();

  static bool isValid(
    DocumentCorners corners, {
    required Size sourceSize,
    double minimumAreaRatio = 0.01,
  }) {
    if (sourceSize.isEmpty) return false;
    final points = corners.ordered;
    if (points.any(
      (point) =>
          !point.x.isFinite ||
          !point.y.isFinite ||
          point.x < 0 ||
          point.y < 0 ||
          point.x > sourceSize.width ||
          point.y > sourceSize.height,
    )) {
      return false;
    }
    final crosses = <double>[];
    for (var index = 0; index < points.length; index++) {
      final previous = points[index];
      final current = points[(index + 1) % 4];
      final next = points[(index + 2) % 4];
      crosses.add(
        (current.x - previous.x) * (next.y - current.y) -
            (current.y - previous.y) * (next.x - current.x),
      );
    }
    if (crosses.any((value) => value.abs() < 1e-6) ||
        !(crosses.every((value) => value > 0) ||
            crosses.every((value) => value < 0))) {
      return false;
    }
    var doubledArea = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % 4];
      doubledArea += points[index].x * next.y - next.x * points[index].y;
    }
    final areaRatio =
        doubledArea.abs() / 2 / (sourceSize.width * sourceSize.height);
    return areaRatio >= minimumAreaRatio;
  }
}

/// Coordinate conversion shared by the editor and regression tests.
class QuickCornerViewportTransform {
  const QuickCornerViewportTransform({
    required this.sourceSize,
    required this.sceneScale,
  });

  factory QuickCornerViewportTransform.forSource(
    Size sourceSize, {
    double maximumSceneEdge = 1200,
  }) {
    final longest = math.max(sourceSize.width, sourceSize.height);
    final scale = longest <= maximumSceneEdge
        ? 1.0
        : maximumSceneEdge / longest;
    return QuickCornerViewportTransform(
      sourceSize: sourceSize,
      sceneScale: scale,
    );
  }

  final Size sourceSize;
  final double sceneScale;

  Size get sceneSize =>
      Size(sourceSize.width * sceneScale, sourceSize.height * sceneScale);

  Offset sourceToScene(DocumentPoint point) =>
      Offset(point.x * sceneScale, point.y * sceneScale);

  DocumentPoint sceneToSource(Offset point) => DocumentPoint(
    (point.dx / sceneScale).clamp(0.0, sourceSize.width).toDouble(),
    (point.dy / sceneScale).clamp(0.0, sourceSize.height).toDouble(),
  );

  DocumentPoint moveSourcePoint({
    required DocumentPoint point,
    required Offset screenDelta,
    required double viewportScale,
  }) {
    final effectiveScale = (sceneScale * viewportScale).clamp(
      0.0001,
      double.infinity,
    );
    return DocumentPoint(
      (point.x + screenDelta.dx / effectiveScale)
          .clamp(0.0, sourceSize.width)
          .toDouble(),
      (point.y + screenDelta.dy / effectiveScale)
          .clamp(0.0, sourceSize.height)
          .toDouble(),
    );
  }
}

/// Immutable BoxFit.contain mapping used by the fixed-image corner editor.
class QuickCornerFixedDisplayTransform {
  const QuickCornerFixedDisplayTransform({
    required this.sourceSize,
    required this.viewportSize,
    required this.displayRect,
  });

  factory QuickCornerFixedDisplayTransform.contain({
    required Size sourceSize,
    required Size viewportSize,
    double margin = 12,
  }) {
    if (sourceSize.isEmpty || viewportSize.isEmpty) {
      return QuickCornerFixedDisplayTransform(
        sourceSize: sourceSize,
        viewportSize: viewportSize,
        displayRect: Rect.zero,
      );
    }
    final available = Size(
      math.max(1, viewportSize.width - margin * 2),
      math.max(1, viewportSize.height - margin * 2),
    );
    final scale = math.min(
      available.width / sourceSize.width,
      available.height / sourceSize.height,
    );
    final fittedSize = Size(
      sourceSize.width * scale,
      sourceSize.height * scale,
    );
    return QuickCornerFixedDisplayTransform(
      sourceSize: sourceSize,
      viewportSize: viewportSize,
      displayRect: Rect.fromCenter(
        center: viewportSize.center(Offset.zero),
        width: fittedSize.width,
        height: fittedSize.height,
      ),
    );
  }

  final Size sourceSize;
  final Size viewportSize;
  final Rect displayRect;

  double get scale =>
      displayRect.isEmpty ? 1 : displayRect.width / sourceSize.width;

  Offset sourceToViewport(DocumentPoint point) => Offset(
    displayRect.left + point.x * scale,
    displayRect.top + point.y * scale,
  );

  DocumentPoint viewportToSource(Offset point) => DocumentPoint(
    ((point.dx - displayRect.left) / scale)
        .clamp(0.0, sourceSize.width)
        .toDouble(),
    ((point.dy - displayRect.top) / scale)
        .clamp(0.0, sourceSize.height)
        .toDouble(),
  );

  DocumentPoint moveSourcePoint({
    required DocumentPoint point,
    required Offset screenDelta,
  }) => DocumentPoint(
    (point.x + screenDelta.dx / scale).clamp(0.0, sourceSize.width).toDouble(),
    (point.y + screenDelta.dy / scale).clamp(0.0, sourceSize.height).toDouble(),
  );
}
