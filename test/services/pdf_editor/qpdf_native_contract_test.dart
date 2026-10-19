import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('qpdf product integration pins sources and all Android ABIs', () {
    final versions = File(
      'android/third_party/qpdf/VERSIONS.md',
    ).readAsStringSync();
    expect(versions, contains('qpdf: `12.4.2`'));
    expect(versions, contains('libjpeg-turbo: `3.2.0`'));
    expect(
      versions,
      contains(
        'FB92435766B8EE31F7BF7123BEC1FC2AF83599ED8B1FEF7F3DAFEF4024A983B5',
      ),
    );
    expect(
      versions,
      contains(
        'E880CAAB26D598BFF3055CD05B942262BAAEA09BD6E3D3362D6FBC92FAA9F744',
      ),
    );

    for (final abi in const ['armeabi-v7a', 'arm64-v8a', 'x86_64']) {
      expect(
        File(
          'android/third_party/qpdf/prebuilt/$abi/libqpdf.so',
        ).existsSync(),
        isTrue,
        reason: 'Missing qpdf native library for $abi',
      );
    }
  });

  test('qpdf JNI remains separate from scan and release shrinking stays off', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/myphotw/scana/pdfeditor/'
      'ExistingPdfEditorPlugin.kt',
    ).readAsStringSync();
    final editor = File(
      'lib/features/pdf_editor/presentation/existing_pdf_editor_page.dart',
    ).readAsStringSync();

    expect(gradle, contains('isMinifyEnabled = false'));
    expect(gradle, contains('isShrinkResources = false'));
    expect(gradle, contains('src/main/cpp/qpdf/CMakeLists.txt'));
    expect(gradle, contains('../third_party/qpdf/prebuilt'));
    expect(plugin, contains('existing_pdf_editor'));
    expect(editor, isNot(contains('deleteAfterSuccessfulExport')));
    expect(editor, isNot(contains('ScanSessionManager')));
  });
}
