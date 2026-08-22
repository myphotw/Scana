import 'dart:io';

import 'package:flutter/material.dart';

import 'package:scana/models/mlkit_page_edit_metadata.dart';

class MlKitCropEditorPage extends StatefulWidget {
  const MlKitCropEditorPage({
    super.key,
    required this.imagePath,
    required this.imageWidth,
    required this.imageHeight,
    required this.rotation,
  });

  final String imagePath;
  final int imageWidth;
  final int imageHeight;
  final int rotation;

  @override
  State<MlKitCropEditorPage> createState() => _MlKitCropEditorPageState();
}

class _MlKitCropEditorPageState extends State<MlKitCropEditorPage> {
  MlKitCropRect _crop = MlKitCropRect.full;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('자르기')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final quarterTurn = widget.rotation % 180 != 0;
                    final width = quarterTurn
                        ? widget.imageHeight
                        : widget.imageWidth;
                    final height = quarterTurn
                        ? widget.imageWidth
                        : widget.imageHeight;
                    final imageRect = _containedRect(
                      Size(constraints.maxWidth, constraints.maxHeight),
                      Size(width.toDouble(), height.toDouble()),
                    );
                    return Stack(
                      key: const Key('mlKitCropEditor'),
                      children: [
                        Positioned.fromRect(
                          rect: imageRect,
                          child: RotatedBox(
                            quarterTurns: widget.rotation ~/ 90,
                            child: Image.file(
                              File(widget.imagePath),
                              fit: BoxFit.fill,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Colors.black26,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                        _CropOverlay(
                          imageRect: imageRect,
                          crop: _crop,
                          onChanged: (value) => setState(() => _crop = value),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: () => setState(() => _crop = MlKitCropRect.full),
                    child: const Text('초기화'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    key: const Key('applyMlKitCropButton'),
                    onPressed: () => Navigator.of(context).pop(_crop),
                    icon: const Icon(Icons.crop),
                    label: const Text('적용'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Rect _containedRect(Size area, Size image) {
    if (image.width <= 0 || image.height <= 0) return Offset.zero & area;
    final scale = (area.width / image.width).clamp(
      0.0,
      area.height / image.height,
    );
    final size = Size(image.width * scale, image.height * scale);
    return Rect.fromLTWH(
      (area.width - size.width) / 2,
      (area.height - size.height) / 2,
      size.width,
      size.height,
    );
  }
}

class _CropOverlay extends StatelessWidget {
  const _CropOverlay({
    required this.imageRect,
    required this.crop,
    required this.onChanged,
  });

  final Rect imageRect;
  final MlKitCropRect crop;
  final ValueChanged<MlKitCropRect> onChanged;

  @override
  Widget build(BuildContext context) {
    final rect = Rect.fromLTRB(
      imageRect.left + crop.left * imageRect.width,
      imageRect.top + crop.top * imageRect.height,
      imageRect.left + crop.right * imageRect.width,
      imageRect.top + crop.bottom * imageRect.height,
    );
    return Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.lightBlueAccent, width: 2),
                color: Colors.lightBlueAccent.withValues(alpha: 0.06),
              ),
            ),
          ),
        ),
        _handle(
          key: const Key('cropHandleTopLeft'),
          position: rect.topLeft,
          onDelta: (delta) => _move(left: delta.dx, top: delta.dy),
        ),
        _handle(
          key: const Key('cropHandleTopRight'),
          position: rect.topRight,
          onDelta: (delta) => _move(right: delta.dx, top: delta.dy),
        ),
        _handle(
          key: const Key('cropHandleBottomLeft'),
          position: rect.bottomLeft,
          onDelta: (delta) => _move(left: delta.dx, bottom: delta.dy),
        ),
        _handle(
          key: const Key('cropHandleBottomRight'),
          position: rect.bottomRight,
          onDelta: (delta) => _move(right: delta.dx, bottom: delta.dy),
        ),
      ],
    );
  }

  Widget _handle({
    required Key key,
    required Offset position,
    required ValueChanged<Offset> onDelta,
  }) => Positioned(
    key: key,
    left: position.dx - 18,
    top: position.dy - 18,
    width: 36,
    height: 36,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => onDelta(details.delta),
      child: const Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.lightBlueAccent,
            shape: BoxShape.circle,
          ),
          child: SizedBox(width: 16, height: 16),
        ),
      ),
    ),
  );

  void _move({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) {
    const minimum = 0.05;
    final dxLeft = imageRect.width == 0 ? 0 : left / imageRect.width;
    final dxRight = imageRect.width == 0 ? 0 : right / imageRect.width;
    final dyTop = imageRect.height == 0 ? 0 : top / imageRect.height;
    final dyBottom = imageRect.height == 0 ? 0 : bottom / imageRect.height;
    onChanged(
      MlKitCropRect(
        left: (crop.left + dxLeft).clamp(0.0, crop.right - minimum),
        top: (crop.top + dyTop).clamp(0.0, crop.bottom - minimum),
        right: (crop.right + dxRight).clamp(crop.left + minimum, 1.0),
        bottom: (crop.bottom + dyBottom).clamp(crop.top + minimum, 1.0),
      ),
    );
  }
}
