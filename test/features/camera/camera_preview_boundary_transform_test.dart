import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/models/document_geometry.dart';

void main() {
  test('portrait back camera maps sensor coordinates into preview bounds', () {
    final rotation = CameraPreviewBoundaryTransform.rotationDegrees(
      sensorOrientation: 90,
      deviceOrientation: DeviceOrientation.portraitUp,
      isFrontFacing: false,
    );
    final point = CameraPreviewBoundaryTransform.toPreviewPoint(
      const DocumentPoint(0.2, 0.3),
      const Size(400, 800),
      rotation,
    );
    expect(rotation, 90);
    expect(point, const Offset(280, 160));
  });

  test('landscape spread uses device orientation instead of sensor alone', () {
    final rotation = CameraPreviewBoundaryTransform.rotationDegrees(
      sensorOrientation: 90,
      deviceOrientation: DeviceOrientation.landscapeLeft,
      isFrontFacing: false,
    );
    final point = CameraPreviewBoundaryTransform.toPreviewPoint(
      const DocumentPoint(0.2, 0.3),
      const Size(800, 400),
      rotation,
    );
    expect(rotation, 0);
    expect(point, const Offset(160, 120));
  });
}
