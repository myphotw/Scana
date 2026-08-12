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
    if (page.hasUserAdjustedCorners && page.documentCorners != null) {
      return QuickCornerInitialSelection(
        corners: page.documentCorners!,
        source: QuickCornerInitialSource.manual,
      );
    }
    final ai = page.aiSegmentationResult;
    if (ai?.hasUsableRefinedBoundary == true) {
      return QuickCornerInitialSelection(
        corners: ai!.refinedCorners!,
        source: QuickCornerInitialSource.aiRefined,
      );
    }
    if (ai?.hasUsableBoundary == true) {
      return QuickCornerInitialSelection(
        corners: ai!.corners!,
        source: QuickCornerInitialSource.aiRaw,
      );
    }
    final boundary = page.pageBoundary;
    if (boundary != null && boundary.isValid) {
      return QuickCornerInitialSelection(
        corners: boundary.toDocumentCorners(),
        source: QuickCornerInitialSource.openCvBoundary,
      );
    }
    if (page.documentCorners != null) {
      return QuickCornerInitialSelection(
        corners: page.documentCorners!,
        source: QuickCornerInitialSource.finalCrop,
      );
    }
    if (page.captureGuideCorners != null) {
      return QuickCornerInitialSelection(
        corners: page.captureGuideCorners!,
        source: QuickCornerInitialSource.guideFallback,
      );
    }
    return null;
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
