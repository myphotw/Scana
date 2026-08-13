import 'package:path/path.dart' as path;

import 'package:scana/models/document_geometry.dart';

class AiDocumentSegmentationResult {
  const AiDocumentSegmentationResult({
    required this.success,
    required this.modelVersion,
    required this.modelLoadMs,
    required this.preprocessMs,
    required this.inferenceTimeMs,
    required this.postprocessMs,
    required this.totalMs,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.maskWidth,
    required this.maskHeight,
    required this.maskCoverage,
    required this.pageSide,
    this.confidence,
    this.maskContinuity,
    this.corners,
    this.refinementAttempted = false,
    this.refinementAccepted = false,
    this.refinedCorners,
    this.paperContour = const [],
    this.finalCorners,
    this.finalSource,
    this.edgeVisibilities = const {},
    this.refinementFailureReason,
    this.maskToSearchRoiMs = 0,
    this.paperCandidateMs = 0,
    this.edgeRefineMs = 0,
    this.cornerEstimateMs = 0,
    this.totalRefineMs = 0,
    this.rawAreaRatio = 0,
    this.refinedAreaRatio = 0,
    this.aiContainmentRatio = 0,
    this.areaExpansionRatio = 1,
    this.paperTransitionScore = 0,
    this.mainPageOwnershipScore = 0,
    this.outerEnvelopeConsistency = 0,
    this.edgeContinuity = 0,
    this.adjacentPagePenalty = 0,
    this.occlusionPenalty = 0,
    this.refinedConfidence = 0,
    this.refinedStatus = AiRefinedBoundaryStatus.rawFallback,
    this.searchRoi,
    this.failureReason,
    this.inputShape = const [],
    this.outputShape = const [],
    this.debugRawFile,
    this.debugMaskFile,
    this.debugAiOverlayFile,
    this.debugAiRawOverlayFile,
    this.debugAiRefinedOverlayFile,
    this.debugAiFinalOverlayFile,
    this.debugSearchRoiFile,
    this.debugEnvelopeOverlayFile,
    this.debugOpenCvOverlayFile,
  });

  final bool success;
  final String modelVersion;
  final int modelLoadMs;
  final int preprocessMs;
  final int inferenceTimeMs;
  final int postprocessMs;
  final int totalMs;
  final int sourceWidth;
  final int sourceHeight;
  final int maskWidth;
  final int maskHeight;
  final double? confidence;
  final double maskCoverage;
  final double? maskContinuity;
  final String pageSide;
  final DocumentCorners? corners;
  final bool refinementAttempted;
  final bool refinementAccepted;
  final DocumentCorners? refinedCorners;

  /// Existing AI refinement paper envelope samples in source-image pixels.
  /// They are diagnostic geometry and never replace the final crop polygon.
  final List<DocumentPoint> paperContour;
  final DocumentCorners? finalCorners;
  final AiFinalBoundarySource? finalSource;
  final Map<AiBoundaryEdgeName, AiEdgeVisibility> edgeVisibilities;
  final String? refinementFailureReason;
  final int maskToSearchRoiMs;
  final int paperCandidateMs;
  final int edgeRefineMs;
  final int cornerEstimateMs;
  final int totalRefineMs;
  final double rawAreaRatio;
  final double refinedAreaRatio;
  final double aiContainmentRatio;
  final double areaExpansionRatio;
  final double paperTransitionScore;
  final double mainPageOwnershipScore;
  final double outerEnvelopeConsistency;
  final double edgeContinuity;
  final double adjacentPagePenalty;
  final double occlusionPenalty;
  final double refinedConfidence;
  final AiRefinedBoundaryStatus refinedStatus;
  final AiSearchRoi? searchRoi;
  final String? failureReason;
  final List<int> inputShape;
  final List<int> outputShape;

  /// Session-directory-relative DEBUG artifacts. They are never absolute in
  /// session.json and are absent in release builds.
  final String? debugRawFile;
  final String? debugMaskFile;
  final String? debugAiOverlayFile;
  final String? debugAiRawOverlayFile;
  final String? debugAiRefinedOverlayFile;
  final String? debugAiFinalOverlayFile;
  final String? debugSearchRoiFile;
  final String? debugEnvelopeOverlayFile;
  final String? debugOpenCvOverlayFile;

  Iterable<String> get debugArtifactFiles => [
    debugRawFile,
    debugMaskFile,
    debugAiOverlayFile,
    debugAiRawOverlayFile,
    debugAiRefinedOverlayFile,
    debugAiFinalOverlayFile,
    debugSearchRoiFile,
    debugEnvelopeOverlayFile,
    debugOpenCvOverlayFile,
  ].nonNulls;

  bool get hasUsableBoundary => success && corners != null;
  bool get hasUsableRefinedBoundary =>
      success && refinementAccepted && refinedCorners != null;
  bool get hasUsableFinalBoundary =>
      success && finalCorners != null && finalSource != null;

  String? resolveDebugArtifact(String sessionDirectory, String? relative) {
    final canonical = _canonicalRelativePath(relative);
    if (canonical == null) return null;
    return path.joinAll([sessionDirectory, ...canonical.split('/')]);
  }

  Map<String, Object> toJson() => {
    'success': success,
    'modelVersion': modelVersion,
    'modelLoadMs': modelLoadMs,
    'preprocessMs': preprocessMs,
    'inferenceTimeMs': inferenceTimeMs,
    'postprocessMs': postprocessMs,
    'totalMs': totalMs,
    'sourceWidth': sourceWidth,
    'sourceHeight': sourceHeight,
    'maskWidth': maskWidth,
    'maskHeight': maskHeight,
    'confidence': ?confidence,
    'maskCoverage': maskCoverage,
    'maskContinuity': ?maskContinuity,
    'pageSide': pageSide,
    'corners': ?corners?.toJson(),
    'refinementAttempted': refinementAttempted,
    'refinementAccepted': refinementAccepted,
    'refinedCorners': ?refinedCorners?.toJson(),
    if (paperContour.isNotEmpty)
      'paperContour': paperContour.map((point) => point.toJson()).toList(),
    'finalCorners': ?finalCorners?.toJson(),
    'finalSource': ?finalSource?.serializedName,
    if (edgeVisibilities.isNotEmpty)
      'edgeVisibilities': edgeVisibilities.values
          .map((edge) => edge.toJson())
          .toList(),
    'refinementFailureReason': ?refinementFailureReason,
    'maskToSearchRoiMs': maskToSearchRoiMs,
    'paperCandidateMs': paperCandidateMs,
    'edgeRefineMs': edgeRefineMs,
    'cornerEstimateMs': cornerEstimateMs,
    'totalRefineMs': totalRefineMs,
    'rawAreaRatio': rawAreaRatio,
    'refinedAreaRatio': refinedAreaRatio,
    'aiContainmentRatio': aiContainmentRatio,
    'areaExpansionRatio': areaExpansionRatio,
    'paperTransitionScore': paperTransitionScore,
    'mainPageOwnershipScore': mainPageOwnershipScore,
    'outerEnvelopeConsistency': outerEnvelopeConsistency,
    'edgeContinuity': edgeContinuity,
    'adjacentPagePenalty': adjacentPagePenalty,
    'occlusionPenalty': occlusionPenalty,
    'refinedConfidence': refinedConfidence,
    'refinedStatus': refinedStatus.serializedName,
    'searchRoi': ?searchRoi?.toJson(),
    'failureReason': ?failureReason,
    if (inputShape.isNotEmpty) 'inputShape': inputShape,
    if (outputShape.isNotEmpty) 'outputShape': outputShape,
    if (_isSafeRelativePath(debugRawFile)) 'debugRawFile': debugRawFile!,
    if (_isSafeRelativePath(debugMaskFile)) 'debugMaskFile': debugMaskFile!,
    if (_isSafeRelativePath(debugAiOverlayFile))
      'debugAiOverlayFile': debugAiOverlayFile!,
    if (_isSafeRelativePath(debugAiRawOverlayFile))
      'debugAiRawOverlayFile': debugAiRawOverlayFile!,
    if (_isSafeRelativePath(debugAiRefinedOverlayFile))
      'debugAiRefinedOverlayFile': debugAiRefinedOverlayFile!,
    if (_isSafeRelativePath(debugAiFinalOverlayFile))
      'debugAiFinalOverlayFile': debugAiFinalOverlayFile!,
    if (_isSafeRelativePath(debugSearchRoiFile))
      'debugSearchRoiFile': debugSearchRoiFile!,
    if (_isSafeRelativePath(debugEnvelopeOverlayFile))
      'debugEnvelopeOverlayFile': debugEnvelopeOverlayFile!,
    if (_isSafeRelativePath(debugOpenCvOverlayFile))
      'debugOpenCvOverlayFile': debugOpenCvOverlayFile!,
  };

  static AiDocumentSegmentationResult? fromJson(Object? value) {
    if (value is! Map) return null;
    int integer(String key) => (value[key] as num?)?.toInt() ?? 0;
    double decimal(String key) => (value[key] as num?)?.toDouble() ?? 0;
    List<int> shape(String key) => switch (value[key]) {
      final List values =>
        values.whereType<num>().map((item) => item.toInt()).toList(),
      _ => const [],
    };
    List<DocumentPoint> points(String key) => switch (value[key]) {
      final List values =>
        values
            .map(DocumentPoint.fromJson)
            .whereType<DocumentPoint>()
            .toList(growable: false),
      _ => const [],
    };
    String? artifact(String key) {
      final candidate = value[key] as String?;
      return _canonicalRelativePath(candidate);
    }

    final edgeVisibilities = <AiBoundaryEdgeName, AiEdgeVisibility>{};
    final serializedEdges = value['edgeVisibilities'];
    if (serializedEdges is List) {
      for (final item in serializedEdges) {
        final parsed = AiEdgeVisibility.fromJson(item);
        if (parsed != null) edgeVisibilities[parsed.edge] = parsed;
      }
    }

    final success = value['success'];
    if (success is! bool) return null;
    return AiDocumentSegmentationResult(
      success: success,
      modelVersion: value['modelVersion'] as String? ?? 'unknown',
      modelLoadMs: integer('modelLoadMs'),
      preprocessMs: integer('preprocessMs'),
      inferenceTimeMs: integer('inferenceTimeMs'),
      postprocessMs: integer('postprocessMs'),
      totalMs: integer('totalMs'),
      sourceWidth: integer('sourceWidth'),
      sourceHeight: integer('sourceHeight'),
      maskWidth: integer('maskWidth'),
      maskHeight: integer('maskHeight'),
      confidence: (value['confidence'] as num?)?.toDouble(),
      maskCoverage: decimal('maskCoverage'),
      maskContinuity: (value['maskContinuity'] as num?)?.toDouble(),
      pageSide: value['pageSide'] as String? ?? 'single',
      corners: DocumentCorners.fromJson(value['corners']),
      refinementAttempted: value['refinementAttempted'] as bool? ?? false,
      refinementAccepted: value['refinementAccepted'] as bool? ?? false,
      refinedCorners: DocumentCorners.fromJson(value['refinedCorners']),
      paperContour: points('paperContour'),
      finalCorners: DocumentCorners.fromJson(value['finalCorners']),
      finalSource: AiFinalBoundarySource.fromSerialized(
        value['finalSource'] as String?,
      ),
      edgeVisibilities: edgeVisibilities,
      refinementFailureReason: value['refinementFailureReason'] as String?,
      maskToSearchRoiMs: integer('maskToSearchRoiMs'),
      paperCandidateMs: integer('paperCandidateMs'),
      edgeRefineMs: integer('edgeRefineMs'),
      cornerEstimateMs: integer('cornerEstimateMs'),
      totalRefineMs: integer('totalRefineMs'),
      rawAreaRatio: decimal('rawAreaRatio'),
      refinedAreaRatio: decimal('refinedAreaRatio'),
      aiContainmentRatio: decimal('aiContainmentRatio'),
      areaExpansionRatio: value.containsKey('areaExpansionRatio')
          ? decimal('areaExpansionRatio')
          : 1,
      paperTransitionScore: decimal('paperTransitionScore'),
      mainPageOwnershipScore: decimal('mainPageOwnershipScore'),
      outerEnvelopeConsistency: decimal('outerEnvelopeConsistency'),
      edgeContinuity: decimal('edgeContinuity'),
      adjacentPagePenalty: decimal('adjacentPagePenalty'),
      occlusionPenalty: decimal('occlusionPenalty'),
      refinedConfidence: decimal('refinedConfidence'),
      refinedStatus: AiRefinedBoundaryStatus.fromSerialized(
        value['refinedStatus'] as String?,
        accepted: value['refinementAccepted'] as bool? ?? false,
      ),
      searchRoi: AiSearchRoi.fromJson(value['searchRoi']),
      failureReason: value['failureReason'] as String?,
      inputShape: shape('inputShape'),
      outputShape: shape('outputShape'),
      debugRawFile: artifact('debugRawFile'),
      debugMaskFile: artifact('debugMaskFile'),
      debugAiOverlayFile: artifact('debugAiOverlayFile'),
      debugAiRawOverlayFile: artifact('debugAiRawOverlayFile'),
      debugAiRefinedOverlayFile: artifact('debugAiRefinedOverlayFile'),
      debugAiFinalOverlayFile: artifact('debugAiFinalOverlayFile'),
      debugSearchRoiFile: artifact('debugSearchRoiFile'),
      debugEnvelopeOverlayFile: artifact('debugEnvelopeOverlayFile'),
      debugOpenCvOverlayFile: artifact('debugOpenCvOverlayFile'),
    );
  }

  static bool _isSafeRelativePath(String? value) {
    return _canonicalRelativePath(value) != null;
  }

  static String? _canonicalRelativePath(String? value) {
    if (value == null || value.isEmpty || path.isAbsolute(value)) return null;
    final canonical = value.replaceAll('\\', '/');
    final normalized = path.posix.normalize(canonical);
    if (normalized == '..' ||
        normalized.startsWith('../') ||
        normalized.startsWith('/') ||
        normalized != canonical) {
      return null;
    }
    return canonical;
  }
}

enum AiRefinedBoundaryStatus {
  accepted('accepted'),
  acceptedConservative('accepted_conservative'),
  acceptedOcclusionRecovered('accepted_occlusion_recovered'),
  rejectedPartialRaw('rejected_partial_raw'),
  rejectedAdjacentPage('rejected_adjacent_page'),
  rejectedOcclusion('rejected_occlusion'),
  rejectedExpansion('rejected_expansion'),
  rejectedShrink('rejected_shrink'),
  rejectedForegroundClipped('rejected_foreground_clipped'),
  rejectedGeometry('rejected_geometry'),
  rawFallback('raw_fallback');

  const AiRefinedBoundaryStatus(this.serializedName);

  final String serializedName;

  bool get isAccepted =>
      this == AiRefinedBoundaryStatus.accepted ||
      this == AiRefinedBoundaryStatus.acceptedConservative ||
      this == AiRefinedBoundaryStatus.acceptedOcclusionRecovered;

  static AiRefinedBoundaryStatus fromSerialized(
    String? value, {
    required bool accepted,
  }) {
    final legacy = switch (value) {
      'refined_rejected_adjacent_page' => rejectedAdjacentPage,
      'refined_rejected_occlusion' => rejectedOcclusion,
      'refined_rejected_expansion' => rejectedExpansion,
      'refined_rejected_shrink' => rejectedShrink,
      'refined_rejected_geometry' => rejectedGeometry,
      _ => null,
    };
    if (legacy != null) return legacy;
    return AiRefinedBoundaryStatus.values.firstWhere(
      (status) => status.serializedName == value,
      orElse: () => accepted
          ? AiRefinedBoundaryStatus.accepted
          : AiRefinedBoundaryStatus.rawFallback,
    );
  }
}

enum AiFinalBoundarySource {
  refined('ai_refined'),
  hybrid('ai_hybrid'),
  rawFallback('ai_raw_fallback');

  const AiFinalBoundarySource(this.serializedName);

  final String serializedName;

  static AiFinalBoundarySource? fromSerialized(String? value) =>
      AiFinalBoundarySource.values
          .where((source) => source.serializedName == value)
          .firstOrNull;
}

enum AiBoundaryEdgeName {
  top,
  right,
  bottom,
  left;

  static AiBoundaryEdgeName? fromSerialized(String? value) =>
      AiBoundaryEdgeName.values.where((edge) => edge.name == value).firstOrNull;
}

enum AiEdgeVisibilityStatus {
  confirmed,
  weak,
  occluded,
  outOfFrame,
  unknown;

  String get serializedName => this == outOfFrame ? 'out_of_frame' : name;

  static AiEdgeVisibilityStatus fromSerialized(String? value) =>
      switch (value) {
        'confirmed' => confirmed,
        'weak' => weak,
        'occluded' => occluded,
        'out_of_frame' => outOfFrame,
        _ => unknown,
      };
}

class AiEdgeVisibility {
  const AiEdgeVisibility({
    required this.edge,
    required this.transitionScore,
    required this.supportingSampleRatio,
    required this.borderDistance,
    required this.occlusionPenalty,
    required this.confidence,
    required this.status,
    this.foregroundBeyond = false,
    this.paperContinuesBeyond = false,
  });

  final AiBoundaryEdgeName edge;
  final double transitionScore;
  final double supportingSampleRatio;
  final double borderDistance;
  final double occlusionPenalty;
  final double confidence;
  final AiEdgeVisibilityStatus status;
  final bool foregroundBeyond;
  final bool paperContinuesBeyond;

  Map<String, Object> toJson() => {
    'edge': edge.name,
    'transitionScore': transitionScore,
    'supportingSampleRatio': supportingSampleRatio,
    'borderDistance': borderDistance,
    'occlusionPenalty': occlusionPenalty,
    'confidence': confidence,
    'status': status.serializedName,
    if (foregroundBeyond) 'foregroundBeyond': true,
    if (paperContinuesBeyond) 'paperContinuesBeyond': true,
  };

  static AiEdgeVisibility? fromJson(Object? value) {
    if (value is! Map) return null;
    final edge = AiBoundaryEdgeName.fromSerialized(value['edge'] as String?);
    if (edge == null) return null;
    double metric(String key) =>
        ((value[key] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
    return AiEdgeVisibility(
      edge: edge,
      transitionScore: metric('transitionScore'),
      supportingSampleRatio: metric('supportingSampleRatio'),
      borderDistance: metric('borderDistance'),
      occlusionPenalty: metric('occlusionPenalty'),
      confidence: metric('confidence'),
      status: AiEdgeVisibilityStatus.fromSerialized(value['status'] as String?),
      foregroundBeyond: value['foregroundBeyond'] as bool? ?? false,
      paperContinuesBeyond: value['paperContinuesBeyond'] as bool? ?? false,
    );
  }
}

class AiSearchRoi {
  const AiSearchRoi({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  Map<String, double> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  static AiSearchRoi? fromJson(Object? value) {
    if (value is! Map) return null;
    double? coordinate(String key) => (value[key] as num?)?.toDouble();
    final left = coordinate('left');
    final top = coordinate('top');
    final right = coordinate('right');
    final bottom = coordinate('bottom');
    if (left == null ||
        top == null ||
        right == null ||
        bottom == null ||
        right <= left ||
        bottom <= top) {
      return null;
    }
    return AiSearchRoi(left: left, top: top, right: right, bottom: bottom);
  }
}

class AiDocumentModelInfo {
  const AiDocumentModelInfo({
    required this.modelVersion,
    required this.modelLoadMs,
    required this.inputShape,
    required this.outputShape,
    required this.inputType,
    required this.outputType,
    required this.threads,
  });

  final String modelVersion;
  final int modelLoadMs;
  final List<int> inputShape;
  final List<int> outputShape;
  final String inputType;
  final String outputType;
  final int threads;

  bool get isSupported =>
      inputShape.length == 4 &&
      inputShape.first == 1 &&
      inputShape.last == 3 &&
      outputShape.length == 4 &&
      outputShape.first == 1 &&
      outputShape.last == 1 &&
      inputType == 'FLOAT32' &&
      outputType == 'FLOAT32';
}
