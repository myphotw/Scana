import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_geometry.dart';
import 'package:scana/services/image_processing/quick_corner_edit.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

/// A focused four-corner workflow used from Gallery, Viewer, and PDF Review.
class QuickCornerEditPage extends StatefulWidget {
  const QuickCornerEditPage({
    super.key,
    required this.sessionManager,
    required this.pageIndex,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final int pageIndex;
  final ScreenOrientationController orientationController;

  @override
  State<QuickCornerEditPage> createState() => _QuickCornerEditPageState();
}

class _QuickCornerEditPageState extends State<QuickCornerEditPage> {
  late final QuickCornerInitialSelection? _initialSelection;
  late final QuickCornerViewportTransform? _coordinateTransform;
  DocumentCorners? _corners;
  Offset? _lastDragGlobal;
  int? _draggingCorner;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.orientationController.enterContentScreen());
    final pages = widget.sessionManager.currentSession?.pages;
    final page = pages != null && widget.pageIndex < pages.length
        ? pages[widget.pageIndex]
        : null;
    _initialSelection = page == null
        ? null
        : QuickCornerInitialPolicy.resolve(page);
    _corners = _initialSelection?.corners;
    final width =
        page?.documentSourceWidth ??
        page?.aiSegmentationResult?.sourceWidth ??
        0;
    final height =
        page?.documentSourceHeight ??
        page?.aiSegmentationResult?.sourceHeight ??
        0;
    _coordinateTransform = width > 0 && height > 0
        ? QuickCornerViewportTransform.forSource(
            Size(width.toDouble(), height.toDouble()),
          )
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.sessionManager.currentSession?.pages;
    final page = pages != null && widget.pageIndex < pages.length
        ? pages[widget.pageIndex]
        : null;
    final transform = _coordinateTransform;
    final corners = _corners;
    return PopScope(
      canPop: !_applying,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('모서리 수정'),
          leading: IconButton(
            key: const ValueKey('quick-corner-cancel-appbar'),
            onPressed: _applying
                ? null
                : () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.close),
            tooltip: '취소',
          ),
        ),
        body: page == null || transform == null || corners == null
            ? const Center(child: Text('편집할 문서 영역을 찾을 수 없습니다.'))
            : Column(
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: Colors.black,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final display =
                              QuickCornerFixedDisplayTransform.contain(
                                sourceSize: transform.sourceSize,
                                viewportSize: constraints.biggest,
                                margin: 22,
                              );
                          final displayRect = display.displayRect;
                          return Stack(
                            key: const ValueKey('quick-corner-fixed-viewport'),
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fromRect(
                                rect: displayRect,
                                child: Image.file(
                                  File(page.rawImagePath),
                                  key: const ValueKey(
                                    'quick-corner-fixed-image',
                                  ),
                                  fit: BoxFit.fill,
                                  filterQuality: FilterQuality.high,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Center(
                                        child: Icon(
                                          Icons.image_not_supported_outlined,
                                          color: Colors.white,
                                        ),
                                      ),
                                ),
                              ),
                              Positioned.fromRect(
                                rect: displayRect,
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: _QuickCornersPainter(
                                      corners.ordered
                                          .map(
                                            (point) =>
                                                display.sourceToViewport(
                                                  point,
                                                ) -
                                                displayRect.topLeft,
                                          )
                                          .toList(),
                                    ),
                                  ),
                                ),
                              ),
                              for (
                                var index = 0;
                                index < corners.ordered.length;
                                index++
                              )
                                _cornerHandle(
                                  index,
                                  display.sourceToViewport(
                                    corners.ordered[index],
                                  ),
                                  display,
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '자동으로 찾은 모서리를 필요할 때만 미세 조정하세요.',
                          key: const ValueKey('quick-corner-initial-source'),
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey('quick-corner-cancel'),
                                onPressed: _applying
                                    ? null
                                    : () => Navigator.of(context).pop(false),
                                child: const Text('취소'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                key: const ValueKey('quick-corner-apply'),
                                onPressed: _applying ? null : _apply,
                                icon: _applying
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.check),
                                label: Text(_applying ? '적용 중…' : '적용'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _cornerHandle(
    int index,
    Offset position,
    QuickCornerFixedDisplayTransform transform,
  ) {
    const size = 44.0;
    return Positioned(
      left: position.dx - size / 2,
      top: position.dy - size / 2,
      child: Listener(
        key: ValueKey('quick-corner-handle-$index'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => setState(() {
          _draggingCorner = index;
          _lastDragGlobal = event.position;
        }),
        onPointerMove: (event) {
          if (_draggingCorner != index) return;
          final corners = _corners;
          if (corners == null) return;
          final last = _lastDragGlobal ?? event.position;
          final moved = transform.moveSourcePoint(
            point: corners.ordered[index],
            screenDelta: event.position - last,
          );
          setState(() {
            _corners = corners.replaceAt(index, moved);
            _lastDragGlobal = event.position;
          });
        },
        onPointerUp: (_) => _finishCornerDrag(),
        onPointerCancel: (_) => _finishCornerDrag(),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _draggingCorner == index
                    ? Colors.lightGreenAccent
                    : Colors.white,
                shape: BoxShape.circle,
                border: const Border.fromBorderSide(
                  BorderSide(color: Colors.lightGreenAccent, width: 3),
                ),
                boxShadow: _draggingCorner == index
                    ? const [
                        BoxShadow(
                          color: Colors.lightGreenAccent,
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
              child: const SizedBox.square(dimension: 22),
            ),
          ),
        ),
      ),
    );
  }

  void _finishCornerDrag() {
    if (!mounted) return;
    setState(() {
      _draggingCorner = null;
      _lastDragGlobal = null;
    });
  }

  Future<void> _apply() async {
    final corners = _corners;
    if (corners == null || _applying) return;
    final sourceSize = _coordinateTransform?.sourceSize;
    if (sourceSize == null ||
        !QuickCornerValidationPolicy.isValid(corners, sourceSize: sourceSize)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('모서리가 서로 교차하지 않도록 문서 영역을 지정해주세요.')),
      );
      return;
    }
    setState(() => _applying = true);
    final succeeded = await widget.sessionManager.applyManualCornersAt(
      widget.pageIndex,
      corners,
    );
    if (!mounted) return;
    if (succeeded) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _applying = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('보정 결과를 만들지 못했습니다. 기존 스캔본은 유지됩니다.')),
    );
  }
}

class _QuickCornersPainter extends CustomPainter {
  const _QuickCornersPainter(this.points);

  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.lightGreenAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _QuickCornersPainter oldDelegate) =>
      oldDelegate.points != points;
}
