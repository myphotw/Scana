import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/ai_document_segmentation_result.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/services/image_processing/ai_document_segmenter.dart';
import 'package:scana/services/image_processing/document_detector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.myphotw.scana/ai_document_segmenter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('model asset exists in the Android application', () {
    final model = File(FairScanSegmentationContract.modelAsset);
    expect(model.existsSync(), isTrue);
    expect(model.lengthSync(), 4921040);
  });

  test('model info loads through one reusable platform service', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return _modelInfo;
    });
    const service = PlatformAiDocumentSegmenter(channel: channel);

    final first = await service.getModelInfo();
    final second = await service.getModelInfo();

    expect(first?.modelVersion, 'v1.2.0');
    expect(second?.inputShape, [1, 256, 256, 3]);
    expect(calls.map((call) => call.method), everyElement('getModelInfo'));
  });

  test('supported tensor metadata is accepted', () {
    final info = _infoFromMap(_modelInfo);
    expect(info.isSupported, isTrue);
  });

  test('tensor metadata mismatch is rejected', () {
    final info = _infoFromMap({
      ..._modelInfo,
      'outputShape': [1, 256, 256, 2],
    });
    expect(info.isSupported, isFalse);
  });

  test('preprocessing contract matches FairScan Android implementation', () {
    expect(FairScanSegmentationContract.inputWidth, 256);
    expect(FairScanSegmentationContract.inputHeight, 256);
    expect(FairScanSegmentationContract.inputChannels, 3);
    expect(FairScanSegmentationContract.normalizationMean, 127.5);
    expect(FairScanSegmentationContract.normalizationScale, 127.5);
  });

  test('valid native output is decoded into a usable boundary', () async {
    _returnNativeResult(messenger, channel, _successResult());

    final result = await const PlatformAiDocumentSegmenter(
      channel: channel,
    ).segment('C:/session/raw_001.jpg', debugStem: 'raw_001_single');

    expect(result.success, isTrue);
    expect(result.hasUsableBoundary, isTrue);
    expect(result.corners?.bottomRight.x, 900);
    expect(result.maskCoverage, closeTo(0.73, 0.001));
    expect(result.hasUsableRefinedBoundary, isTrue);
    expect(result.refinedCorners?.topLeft.x, 80);
    expect(result.totalRefineMs, 55);
  });

  test('empty mask is represented as a normal AI-only failure', () async {
    _returnNativeResult(messenger, channel, _failureResult('empty_mask'));

    final result = await const PlatformAiDocumentSegmenter(
      channel: channel,
    ).segment('C:/session/raw_001.jpg', debugStem: 'raw_001_single');

    expect(result.success, isFalse);
    expect(result.failureReason, 'empty_mask');
  });

  test('valid mask retains timing and coverage diagnostics', () async {
    _returnNativeResult(messenger, channel, _successResult());
    final result = await const PlatformAiDocumentSegmenter(
      channel: channel,
    ).segment('C:/session/raw_001.jpg', debugStem: 'raw_001_single');

    expect(result.inferenceTimeMs, 84);
    expect(result.postprocessMs, 12);
    expect(result.totalMs, 115);
    expect(result.maskContinuity, 0.94);
  });

  test('largest plausible connected component wins', () {
    expect(
      AiMaskComponentPolicy.largestPlausibleIndex([
        50,
        1200,
        5800,
        9900,
      ], maskArea: 10000),
      3,
    );
  });

  test('components outside plausible area limits are ignored', () {
    expect(
      AiMaskComponentPolicy.largestPlausibleIndex([10, 9999], maskArea: 10000),
      isNull,
    );
  });

  test('component policy rejects extreme aspect ratios', () {
    expect(AiMaskComponentPolicy.hasReasonableAspect(200, 100), isTrue);
    expect(AiMaskComponentPolicy.hasReasonableAspect(900, 100), isFalse);
    expect(AiMaskComponentPolicy.hasReasonableAspect(0, 100), isFalse);
  });

  test('component policy rewards center coverage at comparable area', () {
    final centered = AiMaskComponentPolicy.candidateScore(
      areaRatio: 0.6,
      centerCoverage: 1,
      aspectRatio: 1.5,
    );
    final offCenter = AiMaskComponentPolicy.candidateScore(
      areaRatio: 0.6,
      centerCoverage: 0.1,
      aspectRatio: 1.5,
    );

    expect(centered, greaterThan(offCenter));
  });

  test(
    'four ordered source corners are extracted from native output',
    () async {
      _returnNativeResult(messenger, channel, _successResult());
      final result = await const PlatformAiDocumentSegmenter(
        channel: channel,
      ).segment('C:/session/raw.jpg', debugStem: 'raw_single');

      expect(result.corners?.ordered.map((point) => point.x), [
        100,
        900,
        900,
        100,
      ]);
    },
  );

  test('invalid corner output is not a usable AI boundary', () async {
    _returnNativeResult(messenger, channel, {
      ..._successResult(),
      'corners': const <Object>[],
    });
    final result = await const PlatformAiDocumentSegmenter(
      channel: channel,
    ).segment('C:/session/raw.jpg', debugStem: 'raw_single');

    expect(result.success, isTrue);
    expect(result.hasUsableBoundary, isFalse);
  });

  test('Single request does not send a Spread side', () async {
    _recordSuccess(messenger, channel, calls);
    await const PlatformAiDocumentSegmenter(
      channel: channel,
    ).segment('C:/session/raw.jpg', debugStem: 'raw_single');

    expect((calls.single.arguments as Map)['pageSide'], isNull);
  });

  test('Spread left request carries the left ROI role', () async {
    _recordSuccess(messenger, channel, calls);
    await const PlatformAiDocumentSegmenter(channel: channel).segment(
      'C:/session/raw_left.jpg',
      pageSide: DocumentPageSide.left,
      debugStem: 'raw_left',
    );

    expect((calls.single.arguments as Map)['pageSide'], 'left');
  });

  test('Spread right request carries the right ROI role', () async {
    _recordSuccess(messenger, channel, calls);
    await const PlatformAiDocumentSegmenter(channel: channel).segment(
      'C:/session/raw_right.jpg',
      pageSide: DocumentPageSide.right,
      debugStem: 'raw_right',
    );

    expect((calls.single.arguments as Map)['pageSide'], 'right');
  });

  test('request carries the common expected guide when supplied', () async {
    _recordSuccess(messenger, channel, calls);
    await const PlatformAiDocumentSegmenter(channel: channel).segment(
      'C:/session/raw.jpg',
      expectedGuideCorners: const DocumentCorners(
        topLeft: DocumentPoint(10, 20),
        topRight: DocumentPoint(990, 20),
        bottomRight: DocumentPoint(990, 1480),
        bottomLeft: DocumentPoint(10, 1480),
      ),
      debugStem: 'raw_guide',
    );

    final guide =
        (calls.single.arguments as Map)['expectedGuideCorners'] as List;
    expect(guide, hasLength(4));
    expect((guide.first as Map)['x'], 10);
  });

  test(
    'platform exception becomes failure without escaping to crop flow',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) => throw PlatformException(code: 'model_load_failed'),
      );
      final result = await const PlatformAiDocumentSegmenter(
        channel: channel,
      ).segment('C:/session/raw.jpg', debugStem: 'raw_single');

      expect(result.success, isFalse);
      expect(result.failureReason, 'model_load_failed');
    },
  );

  test('DEBUG artifact output uses the session-relative debug_ai folder', () {
    expect(
      AiDebugArtifactPolicy.outputDirectory(
        'C:/session',
        debugBuild: true,
      )?.replaceAll('\\', '/'),
      'C:/session/debug_ai',
    );
  });

  test('release builds disable all DEBUG artifact output', () {
    expect(
      AiDebugArtifactPolicy.outputDirectory('C:/session', debugBuild: false),
      isNull,
    );
  });

  test('session serialization stores only relative DEBUG paths', () {
    final result = AiDocumentSegmentationResult.fromJson({
      ..._persistedResult,
      'debugAiOverlayFile': 'debug_ai/raw_001_ai_overlay.jpg',
      'debugMaskFile': '../outside.png',
    })!;

    expect(result.debugAiOverlayFile, 'debug_ai/raw_001_ai_overlay.jpg');
    expect(result.debugMaskFile, isNull);
    expect(result.toJson().toString(), isNot(contains('C:/')));
  });

  test(
    'platform result maps refined DEBUG artifacts to relative paths',
    () async {
      _returnNativeResult(messenger, channel, {
        ..._successResult(),
        'debugAiRawOverlayPath': 'C:/session/debug_ai/raw_ai_raw_overlay.jpg',
        'debugAiRefinedOverlayPath':
            'C:/session/debug_ai/raw_ai_refined_overlay.jpg',
        'debugSearchRoiPath': 'C:/session/debug_ai/raw_ai_search_roi.jpg',
        'debugEnvelopeOverlayPath':
            'C:/session/debug_ai/raw_ai_envelope_overlay.jpg',
      });
      final result = await const PlatformAiDocumentSegmenter(
        channel: channel,
      ).segment('C:/session/raw.jpg', debugStem: 'raw_single');

      expect(
        result.debugAiRefinedOverlayFile,
        'debug_ai/raw_ai_refined_overlay.jpg',
      );
      expect(result.debugSearchRoiFile, 'debug_ai/raw_ai_search_roi.jpg');
      expect(
        result.debugEnvelopeOverlayFile,
        'debug_ai/raw_ai_envelope_overlay.jpg',
      );
    },
  );

  test('older session without AI metadata remains valid', () {
    expect(AiDocumentSegmentationResult.fromJson(null), isNull);
  });

  test('Android manifest adds no INTERNET permission for AI', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, isNot(contains('android.permission.INTERNET')));
  });
}

const _modelInfo = <String, Object>{
  'modelVersion': 'v1.2.0',
  'modelLoadMs': 42,
  'inputShape': [1, 256, 256, 3],
  'outputShape': [1, 256, 256, 1],
  'inputType': 'FLOAT32',
  'outputType': 'FLOAT32',
  'threads': 2,
};

const _persistedResult = <String, Object>{
  'success': true,
  'modelVersion': 'v1.2.0',
  'modelLoadMs': 42,
  'preprocessMs': 19,
  'inferenceTimeMs': 84,
  'postprocessMs': 12,
  'totalMs': 115,
  'sourceWidth': 1000,
  'sourceHeight': 1500,
  'maskWidth': 256,
  'maskHeight': 256,
  'confidence': 0.91,
  'maskCoverage': 0.73,
  'maskContinuity': 0.94,
  'pageSide': 'single',
  'corners': {
    'topLeft': {'x': 100.0, 'y': 100.0},
    'topRight': {'x': 900.0, 'y': 100.0},
    'bottomRight': {'x': 900.0, 'y': 1400.0},
    'bottomLeft': {'x': 100.0, 'y': 1400.0},
  },
};

Map<String, Object> _successResult() => {
  ..._persistedResult,
  'corners': const [
    {'x': 100.0, 'y': 100.0},
    {'x': 900.0, 'y': 100.0},
    {'x': 900.0, 'y': 1400.0},
    {'x': 100.0, 'y': 1400.0},
  ],
  'refinementAttempted': true,
  'refinementAccepted': true,
  'refinedCorners': const [
    {'x': 80.0, 'y': 80.0},
    {'x': 920.0, 'y': 80.0},
    {'x': 920.0, 'y': 1420.0},
    {'x': 80.0, 'y': 1420.0},
  ],
  'maskToSearchRoiMs': 2,
  'paperCandidateMs': 20,
  'edgeRefineMs': 25,
  'cornerEstimateMs': 8,
  'totalRefineMs': 55,
  'rawAreaRatio': 0.69,
  'refinedAreaRatio': 0.75,
  'aiContainmentRatio': 0.98,
  'areaExpansionRatio': 1.09,
  'paperTransitionScore': 0.7,
};

Map<String, Object> _failureResult(String reason) => {
  ..._persistedResult,
  'success': false,
  'failureReason': reason,
  'corners': const <Object>[],
  'maskCoverage': 0.0,
};

void _returnNativeResult(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel,
  Map<String, Object> value,
) {
  messenger.setMockMethodCallHandler(channel, (call) async => value);
}

void _recordSuccess(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel,
  List<MethodCall> calls,
) {
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return _successResult();
  });
}

AiDocumentModelInfo _infoFromMap(Map<String, Object> value) =>
    AiDocumentModelInfo(
      modelVersion: value['modelVersion']! as String,
      modelLoadMs: value['modelLoadMs']! as int,
      inputShape: (value['inputShape']! as List).cast<int>(),
      outputShape: (value['outputShape']! as List).cast<int>(),
      inputType: value['inputType']! as String,
      outputType: value['outputType']! as String,
      threads: value['threads']! as int,
    );
