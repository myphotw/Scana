import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/scan_page.dart';

/// Lets a user arrange and annotate raw scan pages before later processing.
class PageEditorPage extends StatefulWidget {
  const PageEditorPage({super.key, required this.sessionManager});

  final ScanSessionManager sessionManager;

  @override
  State<PageEditorPage> createState() => _PageEditorPageState();
}

class _PageEditorPageState extends State<PageEditorPage> {
  int? _selectedPageIndex;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('페이지 편집')),
      body: AnimatedBuilder(
        animation: widget.sessionManager,
        builder: (context, child) {
          final pages = widget.sessionManager.currentSession?.pages ?? const [];
          if (pages.isEmpty) {
            return const Center(child: Text('촬영된 페이지가 없습니다.'));
          }

          final selectedIndex = _selectedPageIndex;
          final selectedPage =
              selectedIndex != null && selectedIndex < pages.length
              ? pages[selectedIndex]
              : null;
          return Column(
            children: [
              if (selectedPage != null)
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.42,
                  child: _DocumentCornerEditor(
                    key: ValueKey(selectedPage.rawImagePath),
                    page: selectedPage,
                    onSave: (corners) => widget.sessionManager
                        .updateDocumentCornersAt(selectedIndex!, corners),
                  ),
                ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: pages.length,
                  onReorderItem: (oldIndex, newIndex) async {
                    setState(() => _selectedPageIndex = null);
                    await widget.sessionManager.reorderPages(
                      oldIndex,
                      newIndex,
                    );
                  },
                  itemBuilder: (context, index) {
                    final page = pages[index];
                    return _PageEditorTile(
                      key: ValueKey(page.rawImagePath),
                      page: page,
                      selected: selectedIndex == index,
                      onSelect: () async {
                        setState(() => _selectedPageIndex = index);
                        if (page.documentSourceWidth == null ||
                            page.documentSourceHeight == null) {
                          await widget.sessionManager.detectPageAt(index);
                        }
                      },
                      onDelete: () async {
                        setState(() => _selectedPageIndex = null);
                        await widget.sessionManager.deletePageAt(index);
                      },
                      onRotate: () => widget.sessionManager.rotatePageAt(index),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DocumentCornerEditor extends StatefulWidget {
  const _DocumentCornerEditor({
    super.key,
    required this.page,
    required this.onSave,
  });

  final ScanPage page;
  final Future<void> Function(DocumentCorners corners) onSave;

  @override
  State<_DocumentCornerEditor> createState() => _DocumentCornerEditorState();
}

class _DocumentCornerEditorState extends State<_DocumentCornerEditor> {
  DocumentCorners? _corners;

  @override
  void initState() {
    super.initState();
    _corners = _initialCorners(widget.page);
  }

  @override
  void didUpdateWidget(covariant _DocumentCornerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      _corners = _initialCorners(widget.page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sourceWidth = widget.page.documentSourceWidth;
    final sourceHeight = widget.page.documentSourceHeight;
    final corners = _corners;
    if (sourceWidth == null ||
        sourceHeight == null ||
        sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        corners == null) {
      return const Center(child: Text('문서 영역을 준비하는 중입니다.'));
    }

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final layout = _ContainedImageLayout.calculate(
            constraints.biggest,
            Size(sourceWidth.toDouble(), sourceHeight.toDouble()),
          );
          final displayPoints = corners.ordered
              .map(layout.toDisplayPoint)
              .toList();
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(widget.page.rawImagePath),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(Icons.image_not_supported_outlined);
                },
              ),
              CustomPaint(painter: _DocumentCornersPainter(displayPoints)),
              for (var index = 0; index < displayPoints.length; index++)
                Positioned(
                  left: displayPoints[index].dx - 18,
                  top: displayPoints[index].dy - 18,
                  child: GestureDetector(
                    onPanUpdate: (details) {
                      final current = _corners!.ordered[index];
                      final moved = DocumentPoint(
                        (current.x + details.delta.dx / layout.scale)
                            .clamp(0.0, sourceWidth.toDouble())
                            .toDouble(),
                        (current.y + details.delta.dy / layout.scale)
                            .clamp(0.0, sourceHeight.toDouble())
                            .toDouble(),
                      );
                      setState(() {
                        _corners = _corners!.replaceAt(index, moved);
                      });
                    },
                    child: const SizedBox.square(
                      dimension: 36,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.indigo, width: 3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 12,
                bottom: 12,
                child: FilledButton.icon(
                  onPressed: () => widget.onSave(_corners!),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('모서리 저장'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static DocumentCorners? _initialCorners(ScanPage page) {
    if (page.documentCorners != null) {
      return page.documentCorners;
    }
    final width = page.documentSourceWidth;
    final height = page.documentSourceHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return DocumentCorners(
      topLeft: DocumentPoint(width * 0.08, height * 0.08),
      topRight: DocumentPoint(width * 0.92, height * 0.08),
      bottomRight: DocumentPoint(width * 0.92, height * 0.92),
      bottomLeft: DocumentPoint(width * 0.08, height * 0.92),
    );
  }
}

class _DocumentCornersPainter extends CustomPainter {
  const _DocumentCornersPainter(this.points);

  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length != 4) {
      return;
    }
    final outline = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      outline.lineTo(point.dx, point.dy);
    }
    outline.close();
    canvas.drawPath(
      outline,
      Paint()
        ..color = Colors.indigoAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _DocumentCornersPainter oldDelegate) {
    return oldDelegate.points != points;
  }
}

class _ContainedImageLayout {
  const _ContainedImageLayout({required this.offset, required this.scale});

  final Offset offset;
  final double scale;

  Offset toDisplayPoint(DocumentPoint point) {
    return offset + Offset(point.x * scale, point.y * scale);
  }

  static _ContainedImageLayout calculate(Size available, Size source) {
    final scale = math.min(
      available.width / source.width,
      available.height / source.height,
    );
    final displayed = Size(source.width * scale, source.height * scale);
    return _ContainedImageLayout(
      offset: Offset(
        (available.width - displayed.width) / 2,
        (available.height - displayed.height) / 2,
      ),
      scale: scale,
    );
  }
}

class _PageEditorTile extends StatelessWidget {
  const _PageEditorTile({
    super.key,
    required this.page,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
    required this.onRotate,
  });

  final ScanPage page;
  final bool selected;
  final VoidCallback onSelect;
  final Future<void> Function() onDelete;
  final Future<void> Function() onRotate;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      selected: selected,
      onTap: onSelect,
      leading: _PageThumbnail(page: page, size: 64),
      title: Text('페이지 ${page.pageNo}'),
      subtitle: Text('회전 ${page.rotation}°'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '오른쪽으로 회전',
            onPressed: onRotate,
            icon: const Icon(Icons.rotate_right),
          ),
          IconButton(
            tooltip: '페이지 삭제',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _PageThumbnail extends StatelessWidget {
  const _PageThumbnail({required this.page, required this.size});

  final ScanPage page;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: Colors.black12,
        child: SizedBox.square(
          dimension: size,
          child: Transform.rotate(
            angle: page.rotation * math.pi / 180,
            child: Image.file(
              File(page.rawImagePath),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(Icons.image_not_supported_outlined);
              },
            ),
          ),
        ),
      ),
    );
  }
}
