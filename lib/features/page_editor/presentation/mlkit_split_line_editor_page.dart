import 'dart:io';

import 'package:flutter/material.dart';

class MlKitSplitLineEditorPage extends StatefulWidget {
  const MlKitSplitLineEditorPage({
    super.key,
    required this.sourceImagePath,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.initialSplitX,
  });

  final String sourceImagePath;
  final int sourceWidth;
  final int sourceHeight;
  final int initialSplitX;

  @override
  State<MlKitSplitLineEditorPage> createState() =>
      _MlKitSplitLineEditorPageState();
}

class _MlKitSplitLineEditorPageState extends State<MlKitSplitLineEditorPage> {
  late double _splitFraction;

  @override
  void initState() {
    super.initState();
    _splitFraction = (widget.initialSplitX / widget.sourceWidth).clamp(
      0.25,
      0.75,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('분할 위치')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final imageRect = _containedRect(
                      Size(constraints.maxWidth, constraints.maxHeight),
                      Size(
                        widget.sourceWidth.toDouble(),
                        widget.sourceHeight.toDouble(),
                      ),
                    );
                    final splitPosition =
                        imageRect.left + imageRect.width * _splitFraction;
                    final overlapWidth = imageRect.width * 0.015;
                    return Stack(
                      key: const Key('mlKitSplitLineEditor'),
                      children: [
                        Positioned.fromRect(
                          rect: imageRect,
                          child: Image.file(
                            File(widget.sourceImagePath),
                            fit: BoxFit.fill,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Positioned(
                          left: splitPosition - overlapWidth,
                          top: imageRect.top,
                          width: overlapWidth * 2,
                          height: imageRect.height,
                          child: IgnorePointer(
                            child: ColoredBox(
                              color: Colors.amber.withValues(alpha: 0.18),
                            ),
                          ),
                        ),
                        Positioned(
                          left: splitPosition - 24,
                          top: imageRect.top,
                          width: 48,
                          height: imageRect.height,
                          child: GestureDetector(
                            key: const Key('mlKitSplitDragHandle'),
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (details) {
                              if (imageRect.width <= 0) return;
                              setState(() {
                                _splitFraction =
                                    (_splitFraction +
                                            details.delta.dx / imageRect.width)
                                        .clamp(0.25, 0.75);
                              });
                            },
                            child: Center(
                              child: Container(
                                width: 3,
                                color: Colors.amberAccent,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: imageRect.left + 12,
                          top: imageRect.top + 12,
                          child: const _SideLabel('왼쪽'),
                        ),
                        Positioned(
                          right: constraints.maxWidth - imageRect.right + 12,
                          top: imageRect.top + 12,
                          child: const _SideLabel('오른쪽'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '분할 위치 ${(_splitFraction * 100).toStringAsFixed(1)}% · overlap 1.5%',
                    ),
                  ),
                  FilledButton.icon(
                    key: const Key('applyMlKitSplitButton'),
                    onPressed: () => Navigator.of(
                      context,
                    ).pop((widget.sourceWidth * _splitFraction).round()),
                    icon: const Icon(Icons.vertical_split_outlined),
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

class _SideLabel extends StatelessWidget {
  const _SideLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(label, style: const TextStyle(color: Colors.white)),
    ),
  );
}
