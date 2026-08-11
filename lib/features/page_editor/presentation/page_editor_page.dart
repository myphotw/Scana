import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_page.dart';

/// Lets a user arrange and annotate raw scan pages before later processing.
class PageEditorPage extends StatefulWidget {
  const PageEditorPage({
    super.key,
    required this.sessionManager,
    this.initialPageIndex,
    this.showPageList = true,
  });

  final ScanSessionManager sessionManager;
  final int? initialPageIndex;
  final bool showPageList;

  @override
  State<PageEditorPage> createState() => _PageEditorPageState();
}

class _PageEditorPageState extends State<PageEditorPage> {
  int? _selectedPageIndex;

  @override
  void initState() {
    super.initState();
    _selectedPageIndex = widget.initialPageIndex;
  }

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
          if (!widget.showPageList && selectedPage != null) {
            return _SelectedPageWorkbench(
              key: ValueKey(selectedPage.rawImagePath),
              page: selectedPage,
              pageIndex: selectedIndex!,
              sessionManager: widget.sessionManager,
            );
          }
          return Column(
            children: [
              if (selectedPage != null)
                SizedBox(
                  height: (MediaQuery.sizeOf(context).height * 0.55).clamp(
                    390.0,
                    560.0,
                  ),
                  child: _SelectedPageWorkbench(
                    key: ValueKey(selectedPage.rawImagePath),
                    page: selectedPage,
                    pageIndex: selectedIndex!,
                    sessionManager: widget.sessionManager,
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

class _SelectedPageWorkbench extends StatefulWidget {
  const _SelectedPageWorkbench({
    super.key,
    required this.page,
    required this.pageIndex,
    required this.sessionManager,
  });

  final ScanPage page;
  final int pageIndex;
  final ScanSessionManager sessionManager;

  @override
  State<_SelectedPageWorkbench> createState() => _SelectedPageWorkbenchState();
}

class _SelectedPageWorkbenchState extends State<_SelectedPageWorkbench> {
  late CorrectionType _correctionType;
  DocumentCorners? _editedCorners;
  bool _showCorrected = false;

  @override
  void initState() {
    super.initState();
    _correctionType = widget.page.correctionType;
    _editedCorners = _DocumentCornerEditorState.initialCorners(widget.page);
    _showCorrected = widget.page.correctedImagePath != null;
  }

  @override
  void didUpdateWidget(covariant _SelectedPageWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.rawImagePath != widget.page.rawImagePath) {
      _correctionType = widget.page.correctionType;
      _editedCorners = _DocumentCornerEditorState.initialCorners(widget.page);
      _showCorrected = false;
    }
    if (widget.page.correctedImagePath == null) {
      _showCorrected = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final isProcessing = page.correctionStatus == CorrectionStatus.processing;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _showCorrected = !_showCorrected),
              icon: Icon(
                _showCorrected ? Icons.crop_free_outlined : Icons.auto_fix_high,
              ),
              label: Text(_showCorrected ? '모서리 수정' : '스캔본으로 돌아가기'),
            ),
          ),
        ),
        Expanded(
          child: _showCorrected && page.correctedImagePath != null
              ? _CorrectedPagePreview(
                  imagePath: page.correctedImagePath!,
                  rotation: page.rotation,
                )
              : _DocumentCornerEditor(
                  page: page,
                  onChanged: (corners) => _editedCorners = corners,
                ),
        ),
        SafeArea(
          key: const ValueKey('page-editor-action-toolbar'),
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<CorrectionType>(
                      segments: const [
                        ButtonSegment(
                          value: CorrectionType.perspective,
                          label: Text('원근 보정'),
                        ),
                        ButtonSegment(
                          value: CorrectionType.curved,
                          label: Text('책/곡면 문서 보정'),
                        ),
                      ],
                      selected: {_correctionType},
                      onSelectionChanged: isProcessing
                          ? null
                          : (selection) {
                              setState(
                                () => _correctionType = selection.single,
                              );
                            },
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '회전',
                    onPressed: isProcessing
                        ? null
                        : () => widget.sessionManager.rotatePageAt(
                            widget.pageIndex,
                          ),
                    icon: const Icon(Icons.rotate_right),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isProcessing || _editedCorners == null
                          ? null
                          : _saveCorners,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('모서리 저장'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: isProcessing ? null : _correctPage,
                      icon: isProcessing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_fix_high),
                      label: Text(
                        page.correctedImagePath == null ? '보정 실행' : '다시 보정',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _correctionStatusLabel(
                  page.correctionStatus,
                  type: page.correctionType,
                  outcome: page.correctionOutcome,
                ),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _correctPage() async {
    final succeeded = await widget.sessionManager.correctPageAt(
      widget.pageIndex,
      _correctionType,
    );
    if (mounted && succeeded) {
      setState(() => _showCorrected = true);
    }
  }

  Future<void> _saveCorners() async {
    final corners = _editedCorners;
    if (corners == null) {
      return;
    }
    await widget.sessionManager.updateDocumentCornersAt(
      widget.pageIndex,
      corners,
    );
  }
}

class _CorrectedPagePreview extends StatelessWidget {
  const _CorrectedPagePreview({
    required this.imagePath,
    required this.rotation,
  });

  final String imagePath;
  final int rotation;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Transform.rotate(
          key: const ValueKey('editor-corrected-rotation'),
          angle: rotation * math.pi / 180,
          child: Image.file(
            File(imagePath),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image_outlined, color: Colors.white),
                  SizedBox(height: 8),
                  Text(
                    '보정 이미지를 불러올 수 없습니다.',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DocumentCornerEditor extends StatefulWidget {
  const _DocumentCornerEditor({required this.page, required this.onChanged});

  final ScanPage page;
  final ValueChanged<DocumentCorners> onChanged;

  @override
  State<_DocumentCornerEditor> createState() => _DocumentCornerEditorState();
}

class _DocumentCornerEditorState extends State<_DocumentCornerEditor> {
  DocumentCorners? _corners;

  @override
  void initState() {
    super.initState();
    _corners = initialCorners(widget.page);
  }

  @override
  void didUpdateWidget(covariant _DocumentCornerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      _corners = initialCorners(widget.page);
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
      key: const ValueKey('page-editor-image-preview'),
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.all(18),
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
                        widget.onChanged(_corners!);
                      },
                      child: SizedBox.square(
                        key: ValueKey('document-corner-$index'),
                        dimension: 36,
                        child: const DecoratedBox(
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
              ],
            );
          },
        ),
      ),
    );
  }

  static DocumentCorners? initialCorners(ScanPage page) {
    if (page.hasUserAdjustedCorners && page.documentCorners != null) {
      return page.documentCorners;
    }
    return page.documentCorners ?? page.captureGuideCorners;
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
      subtitle: Text(
        '회전 ${page.rotation}° · '
        '${_correctionTypeLabel(page.correctionType)} · '
        '${_correctionStatusLabel(page.correctionStatus, outcome: page.correctionOutcome)}',
      ),
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

String _correctionTypeLabel(CorrectionType type) {
  return switch (type) {
    CorrectionType.perspective => '원근',
    CorrectionType.curved => '곡면',
  };
}

String _correctionStatusLabel(
  CorrectionStatus status, {
  CorrectionType? type,
  CorrectionOutcome outcome = CorrectionOutcome.none,
}) {
  return switch (status) {
    CorrectionStatus.none => '보정 전',
    CorrectionStatus.processing => '보정 중',
    CorrectionStatus.completed => '보정 완료',
    CorrectionStatus.failed when outcome == CorrectionOutcome.nearlyFlat =>
      '곡면이 거의 없어 Perspective 결과를 유지합니다.',
    CorrectionStatus.failed
        when outcome == CorrectionOutcome.unsafeDeformation =>
      '안전하지 않은 변형이라 Perspective 결과를 유지합니다.',
    CorrectionStatus.failed when outcome == CorrectionOutcome.notImproved =>
      '곡면 결과가 개선되지 않아 Perspective 결과를 유지합니다.',
    CorrectionStatus.failed when outcome == CorrectionOutcome.lowConfidence =>
      '곡률 검출 신뢰도가 부족해 Perspective 결과를 유지합니다.',
    CorrectionStatus.failed when type == CorrectionType.curved =>
      '곡률 검출 신뢰도가 부족해 Perspective 결과를 유지합니다.',
    CorrectionStatus.failed => '보정 실패 · 다시 시도할 수 있습니다',
  };
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
