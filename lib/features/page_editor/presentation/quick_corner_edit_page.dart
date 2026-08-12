import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  final TransformationController _transformationController =
      TransformationController();
  final GlobalKey _viewportKey = GlobalKey();
  late final QuickCornerInitialSelection? _initialSelection;
  late final QuickCornerViewportTransform? _coordinateTransform;
  DocumentCorners? _corners;
  Offset? _dragPosition;
  Offset? _lastDragGlobal;
  int? _draggingCorner;
  bool _initialTransformScheduled = false;
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
  void dispose() {
    _transformationController.dispose();
    super.dispose();
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
                          _scheduleInitialTransform(
                            constraints.biggest,
                            transform.sceneSize,
                          );
                          return Stack(
                            key: _viewportKey,
                            clipBehavior: Clip.none,
                            children: [
                              Positioned.fill(
                                child: InteractiveViewer(
                                  key: const ValueKey(
                                    'quick-corner-interactive-viewer',
                                  ),
                                  transformationController:
                                      _transformationController,
                                  panEnabled: _draggingCorner == null,
                                  scaleEnabled: _draggingCorner == null,
                                  constrained: false,
                                  minScale: 0.15,
                                  maxScale: 8,
                                  boundaryMargin: EdgeInsets.all(
                                    math.max(
                                      transform.sceneSize.width,
                                      transform.sceneSize.height,
                                    ),
                                  ),
                                  child: SizedBox.fromSize(
                                    size: transform.sceneSize,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Positioned.fill(
                                          child: Image.file(
                                            File(page.rawImagePath),
                                            fit: BoxFit.fill,
                                            filterQuality: FilterQuality.high,
                                            errorBuilder:
                                                (
                                                  context,
                                                  error,
                                                  stackTrace,
                                                ) => const Center(
                                                  child: Icon(
                                                    Icons
                                                        .image_not_supported_outlined,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CustomPaint(
                                              painter: _QuickCornersPainter(
                                                corners.ordered
                                                    .map(
                                                      transform.sourceToScene,
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
                                            transform.sourceToScene(
                                              corners.ordered[index],
                                            ),
                                            transform,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (_dragPosition case final position?)
                                _CornerMagnifier(
                                  position: position,
                                  viewportSize: constraints.biggest,
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
                          '초기 영역: ${_sourceLabel(_initialSelection!.source)} · 확대 후 모서리를 미세 조정하세요.',
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
    QuickCornerViewportTransform transform,
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
          _dragPosition = _globalToViewport(event.position);
        }),
        onPointerMove: (event) {
          if (_draggingCorner != index) return;
          final corners = _corners;
          if (corners == null) return;
          final last = _lastDragGlobal ?? event.position;
          final moved = transform.moveSourcePoint(
            point: corners.ordered[index],
            screenDelta: event.position - last,
            viewportScale: _transformationController.value.getMaxScaleOnAxis(),
          );
          setState(() {
            _corners = corners.replaceAt(index, moved);
            _lastDragGlobal = event.position;
            _dragPosition = _globalToViewport(event.position);
          });
        },
        onPointerUp: (_) => _finishCornerDrag(),
        onPointerCancel: (_) => _finishCornerDrag(),
        child: const SizedBox.square(
          dimension: size,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                  BorderSide(color: Colors.lightGreenAccent, width: 3),
                ),
              ),
              child: SizedBox.square(dimension: 22),
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
      _dragPosition = null;
    });
  }

  Offset _globalToViewport(Offset global) {
    final renderObject = _viewportKey.currentContext?.findRenderObject();
    return renderObject is RenderBox
        ? renderObject.globalToLocal(global)
        : global;
  }

  void _scheduleInitialTransform(Size viewport, Size scene) {
    if (_initialTransformScheduled || viewport.isEmpty || scene.isEmpty) return;
    _initialTransformScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final fit =
          math.min(
            viewport.width / scene.width,
            viewport.height / scene.height,
          ) *
          0.92;
      final left = (viewport.width - scene.width * fit) / 2;
      final top = (viewport.height - scene.height * fit) / 2;
      _transformationController.value = Matrix4.identity()
        ..setEntry(0, 0, fit)
        ..setEntry(1, 1, fit)
        ..setEntry(0, 3, left)
        ..setEntry(1, 3, top);
    });
  }

  Future<void> _apply() async {
    final corners = _corners;
    if (corners == null || _applying) return;
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

  static String _sourceLabel(QuickCornerInitialSource source) =>
      switch (source) {
        QuickCornerInitialSource.manual => '사용자 수정',
        QuickCornerInitialSource.aiRefined => 'AI Refined',
        QuickCornerInitialSource.aiRaw => 'AI Raw',
        QuickCornerInitialSource.openCvBoundary => 'OpenCV',
        QuickCornerInitialSource.finalCrop => '현재 Crop',
        QuickCornerInitialSource.guideFallback => '촬영 가이드',
      };
}

class _CornerMagnifier extends StatelessWidget {
  const _CornerMagnifier({required this.position, required this.viewportSize});

  final Offset position;
  final Size viewportSize;

  @override
  Widget build(BuildContext context) {
    const size = 120.0;
    final left = (position.dx - size / 2).clamp(
      8.0,
      viewportSize.width - size - 8,
    );
    final top = (position.dy - size - 42).clamp(
      8.0,
      viewportSize.height - size - 8,
    );
    return Positioned(
      key: const ValueKey('quick-corner-magnifier'),
      left: left,
      top: top,
      child: IgnorePointer(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RawMagnifier(
                size: const Size.square(size),
                magnificationScale: 2.4,
                focalPointOffset:
                    position - Offset(left + size / 2, top + size / 2),
                decoration: const MagnifierDecoration(
                  shape: CircleBorder(
                    side: BorderSide(color: Colors.white, width: 3),
                  ),
                  shadows: [BoxShadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
              const CustomPaint(painter: _CrosshairPainter()),
            ],
          ),
        ),
      ),
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

class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..color = Colors.lightGreenAccent
      ..strokeWidth = 1.5;
    canvas.drawLine(
      center - const Offset(12, 0),
      center + const Offset(12, 0),
      paint,
    );
    canvas.drawLine(
      center - const Offset(0, 12),
      center + const Offset(0, 12),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
