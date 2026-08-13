import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/models/page_enhancement.dart';
import 'package:scana/services/image_processing/page_enhancer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/page_enhancer');
  final messenger = TestDefaultBinaryMessengerBinding.instance;

  tearDown(() {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('passes paths and enhancement mode to the native processor', () async {
    MethodCall? receivedCall;
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      receivedCall = call;
      return <String, Object>{
        'outputWidth': 3024,
        'outputHeight': 4032,
        'processingMilliseconds': 187,
        'backgroundAnalysisMilliseconds': 31,
        'backgroundNormalizationMilliseconds': 22,
        'backgroundWhiteningMilliseconds': 39,
        'foregroundEnhancementMilliseconds': 34,
        'sharpeningMilliseconds': 42,
        'totalEnhancementMilliseconds': 168,
        'outputFormat': 'png',
        'sourceWidth': 3024,
        'sourceHeight': 4032,
        'sourceSharpness': 128.5,
        'sourceForegroundSharpness': 180.25,
        'sourceForegroundPixels': 12000,
        'sourceBackgroundVariance': 6.25,
        'sourceDarkSpeckleRatio': 0.018,
        'sourceBackgroundPixels': 780000,
        'outputSharpness': 132.0,
        'outputForegroundSharpness': 184.0,
        'outputForegroundPixels': 11980,
        'outputBackgroundVariance': 4.75,
        'outputDarkSpeckleRatio': 0.012,
        'outputBackgroundPixels': 782000,
        'sharpeningAmount': 0.17,
        'foregroundDarkeningAmount': 0.20,
        'sourceLuminanceBlend': 0.07,
      };
    });
    const enhancer = OpenCvPageEnhancer(channel: channel);

    final result = await enhancer.enhance(
      sourceImagePath: '/session/corrected_001.jpg',
      outputImagePath: '/session/.enhanced_001.jpg.pending.jpg',
      mode: EnhancementMode.scanColor,
    );

    expect(receivedCall?.method, 'enhancePage');
    expect(receivedCall?.arguments, {
      'sourceImagePath': '/session/corrected_001.jpg',
      'outputImagePath': '/session/.enhanced_001.jpg.pending.jpg',
      'enhancementMode': 'scanColor',
    });
    expect(result.outputWidth, 3024);
    expect(result.outputHeight, 4032);
    expect(result.processingMilliseconds, 187);
    expect(result.outputFormat, 'png');
    expect(result.sourceQuality.foregroundSharpness, 180.25);
    expect(result.outputQuality.foregroundSharpness, 184.0);
    expect(result.sourceQuality.darkSpeckleRatio, 0.018);
    expect(result.outputQuality.backgroundVariance, 4.75);
    expect(result.sharpeningAmount, 0.17);
    expect(result.foregroundDarkeningAmount, 0.20);
    expect(result.sourceLuminanceBlend, 0.07);
    expect(result.stageTimings, {
      'backgroundAnalysisMilliseconds': 31,
      'backgroundNormalizationMilliseconds': 22,
      'backgroundWhiteningMilliseconds': 39,
      'foregroundEnhancementMilliseconds': 34,
      'sharpeningMilliseconds': 42,
      'totalEnhancementMilliseconds': 168,
    });
  });

  test('rejects malformed native output metadata', () async {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{
        'outputWidth': 0,
        'outputHeight': 4032,
        'processingMilliseconds': -1,
      },
    );
    const enhancer = OpenCvPageEnhancer(channel: channel);

    expect(
      enhancer.enhance(
        sourceImagePath: '/session/corrected_001.jpg',
        outputImagePath: '/session/.enhanced_001.jpg.pending.jpg',
        mode: EnhancementMode.grayscale,
      ),
      throwsFormatException,
    );
  });

  test('rejects malformed Scan Color stage timing metadata', () async {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{
        'outputWidth': 3024,
        'outputHeight': 4032,
        'processingMilliseconds': 187,
        'backgroundWhiteningMilliseconds': -1,
      },
    );
    const enhancer = OpenCvPageEnhancer(channel: channel);

    expect(
      enhancer.enhance(
        sourceImagePath: '/session/corrected_001.jpg',
        outputImagePath: '/session/.enhanced_001.jpg.pending.jpg',
        mode: EnhancementMode.scanColor,
      ),
      throwsFormatException,
    );
  });

  test('rejects malformed Scan Color tuning metadata', () async {
    messenger.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => <String, Object>{
        'outputWidth': 3024,
        'outputHeight': 4032,
        'processingMilliseconds': 187,
        'sharpeningAmount': 1.1,
      },
    );
    const enhancer = OpenCvPageEnhancer(channel: channel);

    expect(
      enhancer.enhance(
        sourceImagePath: '/session/corrected_001.png',
        outputImagePath: '/session/.enhanced_001.png.pending.png',
        mode: EnhancementMode.scanColor,
      ),
      throwsFormatException,
    );
  });

  for (final mode in EnhancementMode.values) {
    test('forwards ${mode.name} without changing the native API', () async {
      String? receivedMode;
      messenger.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        receivedMode =
            (call.arguments as Map<Object?, Object?>)['enhancementMode']
                as String?;
        return <String, Object>{
          'outputWidth': 1600,
          'outputHeight': 2200,
          'processingMilliseconds': 90,
        };
      });
      const enhancer = OpenCvPageEnhancer(channel: channel);

      final result = await enhancer.enhance(
        sourceImagePath: '/session/corrected.jpg',
        outputImagePath: '/session/output.jpg',
        mode: mode,
      );

      expect(receivedMode, mode.name);
      expect(result.outputWidth, 1600);
      expect(result.outputHeight, 2200);
    });
  }
}
