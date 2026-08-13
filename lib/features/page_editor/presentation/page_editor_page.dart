import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/features/page_editor/presentation/quick_corner_edit_page.dart';
import 'package:scana/models/document_detection_result.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

/// Lets a user arrange and annotate raw scan pages before later processing.
class PageEditorPage extends StatefulWidget {
  const PageEditorPage({
    super.key,
    required this.sessionManager,
    this.initialPageIndex,
    this.showPageList = true,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final int? initialPageIndex;
  final bool showPageList;
  final ScreenOrientationController orientationController;

  @override
  State<PageEditorPage> createState() => _PageEditorPageState();
}

/// Keeps development-only UI testable without exposing it in release builds.
class PageEditorDebugUiPolicy {
  const PageEditorDebugUiPolicy._();

  static bool showDeveloperControls({required bool isDebugBuild}) =>
      isDebugBuild;
}

class _PageEditorPageState extends State<PageEditorPage> {
  int? _selectedPageIndex;

  @override
  void initState() {
    super.initState();
    unawaited(widget.orientationController.enterContentScreen());
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
  bool _showDeveloperWorkbench = false;

  @override
  void initState() {
    super.initState();
    _correctionType = widget.page.correctionType;
    _editedCorners = _DocumentCornerEditorState.initialCorners(widget.page);
  }

  @override
  void didUpdateWidget(covariant _SelectedPageWorkbench oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.rawImagePath != widget.page.rawImagePath) {
      _correctionType = widget.page.correctionType;
      _editedCorners = _DocumentCornerEditorState.initialCorners(widget.page);
      _showDeveloperWorkbench = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final isProcessing =
        page.correctionStatus == CorrectionStatus.processing ||
        page.enhancementStatus == EnhancementStatus.processing;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (PageEditorDebugUiPolicy.showDeveloperControls(
                isDebugBuild: kDebugMode,
              ))
                _DeveloperTools(
                  developerWorkbenchVisible: _showDeveloperWorkbench,
                  onToggleWorkbench: () => setState(
                    () => _showDeveloperWorkbench = !_showDeveloperWorkbench,
                  ),
                  onShowAiComparison: page.aiSegmentationResult == null
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (context) =>
                              _AiSegmentationComparisonDialog(page: page),
                        ),
                  onShowCurvatureDiagnostics: () => showDialog<void>(
                    context: context,
                    builder: (context) =>
                        _CurvatureDiagnosticsDialog(page: page),
                  ),
                ),
              if (!_showDeveloperWorkbench)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const ValueKey('page-editor-quick-corner-button'),
                    onPressed: isProcessing ? null : _openQuickCornerEditor,
                    icon: const Icon(Icons.crop_free),
                    label: const Text('모서리 수정'),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _showDeveloperWorkbench
              ? _DocumentCornerEditor(
                  page: page,
                  onChanged: (corners) => _editedCorners = corners,
                )
              : _CorrectedPagePreview(
                  imagePath: page.displayImagePath,
                  rotation: page.rotation,
                ),
        ),
        SafeArea(
          key: const ValueKey('page-editor-action-toolbar'),
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showDeveloperWorkbench && kDebugMode) ...[
                SegmentedButton<CorrectionType>(
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
                          setState(() => _correctionType = selection.single);
                        },
                ),
                const SizedBox(height: 6),
              ],
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<EnhancementMode>(
                  key: const ValueKey('page-enhancement-mode-selector'),
                  showSelectedIcon: false,
                  segments: EnhancementMode.values
                      .map(
                        (mode) =>
                            ButtonSegment(value: mode, label: Text(mode.label)),
                      )
                      .toList(growable: false),
                  selected: {page.enhancementMode},
                  onSelectionChanged: isProcessing
                      ? null
                      : (selection) => widget.sessionManager.enhancePageAt(
                          widget.pageIndex,
                          selection.single,
                        ),
                ),
              ),
              if (_showDeveloperWorkbench && kDebugMode) ...[
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_fix_high),
                        label: const Text('개발용 보정 실행'),
                      ),
                    ),
                  ],
                ),
              ],
              if (isProcessing) ...[
                const SizedBox(height: 6),
                const LinearProgressIndicator(),
              ],
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
      setState(() => _showDeveloperWorkbench = false);
    }
  }

  Future<void> _openQuickCornerEditor() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => QuickCornerEditPage(
          sessionManager: widget.sessionManager,
          pageIndex: widget.pageIndex,
        ),
      ),
    );
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

/// Development-only entry points. The automatic scan result remains the
/// default experience; these controls are never compiled into release UI.
class _DeveloperTools extends StatelessWidget {
  const _DeveloperTools({
    required this.developerWorkbenchVisible,
    required this.onToggleWorkbench,
    required this.onShowAiComparison,
    required this.onShowCurvatureDiagnostics,
  });

  final bool developerWorkbenchVisible;
  final VoidCallback onToggleWorkbench;
  final VoidCallback? onShowAiComparison;
  final VoidCallback onShowCurvatureDiagnostics;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          spacing: 4,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Chip(
              avatar: Icon(Icons.bug_report_outlined, size: 16),
              label: Text('DEBUG'),
              visualDensity: VisualDensity.compact,
            ),
            if (onShowAiComparison != null)
              TextButton.icon(
                key: const ValueKey('ai-detection-comparison-button'),
                onPressed: onShowAiComparison,
                icon: const Icon(Icons.compare_outlined, size: 18),
                label: const Text('AI 검출 비교'),
              ),
            TextButton.icon(
              key: const ValueKey('curvature-diagnostics-button'),
              onPressed: onShowCurvatureDiagnostics,
              icon: const Icon(Icons.analytics_outlined, size: 18),
              label: const Text('곡면보정 진단'),
            ),
            TextButton.icon(
              key: const ValueKey('developer-correction-workbench-button'),
              onPressed: onToggleWorkbench,
              icon: Icon(
                developerWorkbenchVisible
                    ? Icons.visibility_off_outlined
                    : Icons.construction_outlined,
                size: 18,
              ),
              label: Text(developerWorkbenchVisible ? '개발 도구 닫기' : '수동 보정'),
            ),
          ],
        ),
      ),
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
            filterQuality: FilterQuality.medium,
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
                  filterQuality: FilterQuality.medium,
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
        '${_correctionStatusLabel(page.correctionStatus, outcome: page.correctionOutcome)} · '
        '${_enhancementStatusLabel(page.enhancementStatus, page.enhancementMode)}',
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
      '곡면을 안정적으로 검출하지 못해 기존 보정 결과를 유지했습니다.',
    CorrectionStatus.failed when type == CorrectionType.curved =>
      '곡면을 안정적으로 검출하지 못해 기존 보정 결과를 유지했습니다.',
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
              File(page.displayImagePath),
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

class _CurvatureDiagnosticsDialog extends StatefulWidget {
  const _CurvatureDiagnosticsDialog({required this.page});

  final ScanPage page;

  @override
  State<_CurvatureDiagnosticsDialog> createState() =>
      _CurvatureDiagnosticsDialogState();
}

class _CurvatureDiagnosticsDialogState
    extends State<_CurvatureDiagnosticsDialog> {
  late final _CurvatureDiagnosticsSnapshot _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = _CurvatureDiagnosticsSnapshot.load(widget.page);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('곡면보정 진단'),
          leading: IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _snapshot.reportFound
                      ? 'curvature_report.json에서 읽은 최신 진단 정보입니다.'
                      : 'curvature_report.json이 없어 세션 메타데이터를 표시합니다.',
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _snapshot.reportPath,
                  key: const ValueKey('curvature-report-path'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_snapshot.loadError case final error?) ...[
                  const SizedBox(height: 8),
                  Text(
                    '진단 파일을 읽지 못했습니다: $error',
                    key: const ValueKey('curvature-report-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ..._snapshot.entries.map(
                  (entry) => _CurvatureDiagnosticValue(
                    label: entry.key,
                    value: entry.value,
                  ),
                ),
                if (_snapshot.rawReport case final report?) ...[
                  const SizedBox(height: 12),
                  ExpansionTile(
                    key: const ValueKey('curvature-report-raw'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text('curvature_report.json 원문'),
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ').convert(report),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CurvatureDiagnosticValue extends StatelessWidget {
  const _CurvatureDiagnosticValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 168,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: ValueKey('curvature-value-$label'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurvatureDiagnosticsSnapshot {
  const _CurvatureDiagnosticsSnapshot({
    required this.reportPath,
    required this.reportFound,
    required this.entries,
    this.rawReport,
    this.loadError,
  });

  final String reportPath;
  final bool reportFound;
  final List<MapEntry<String, String>> entries;
  final Map<String, Object?>? rawReport;
  final Object? loadError;

  static _CurvatureDiagnosticsSnapshot load(ScanPage page) {
    final rawStem = path.basenameWithoutExtension(page.rawImagePath);
    final reportPath = path.join(
      path.dirname(page.rawImagePath),
      'debug_curvature',
      rawStem,
      'curvature_report.json',
    );
    Map<String, Object?>? report;
    Object? loadError;
    final reportFile = File(reportPath);
    final reportFound = reportFile.existsSync();
    if (reportFound) {
      try {
        final decoded = jsonDecode(reportFile.readAsStringSync());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('JSON root is not an object');
        }
        report = Map<String, Object?>.from(decoded);
      } on Object catch (error) {
        loadError = error;
      }
    }

    Object? value(List<String> keys, [Object? fallback]) {
      for (final key in keys) {
        final candidate = report?[key];
        if (candidate != null) return candidate;
      }
      return fallback;
    }

    final detectMs = value(const ['detectMs']);
    final dewarpMs = value(const ['dewarpMs']);
    final derivedTotalMs = detectMs is num || dewarpMs is num
        ? (detectMs is num ? detectMs : 0) + (dewarpMs is num ? dewarpMs : 0)
        : null;
    final entries = <MapEntry<String, String>>[
      MapEntry(
        'state',
        _stateLabel(value(const ['state'], page.curvatureState.name)),
      ),
      MapEntry(
        'applied',
        _formatValue(value(const ['applied'], page.curvedApplied)),
      ),
      MapEntry(
        'pageContourMagnitude',
        _formatValue(
          value(const ['pageContourMagnitude'], page.curvatureMagnitude),
        ),
      ),
      MapEntry('topCurve', _formatValue(value(const ['topCurve']))),
      MapEntry('bottomCurve', _formatValue(value(const ['bottomCurve']))),
      MapEntry('spineCurve', _formatValue(value(const ['spineCurve']))),
      MapEntry(
        'internalLineMagnitude',
        _formatValue(value(const ['internalLineMagnitude'])),
      ),
      MapEntry(
        'effectiveDeformationMagnitude',
        _formatValue(value(const ['effectiveDeformationMagnitude'])),
      ),
      MapEntry('topRawSign', _formatValue(value(const ['topRawSign']))),
      MapEntry('bottomRawSign', _formatValue(value(const ['bottomRawSign']))),
      MapEntry('spineRawSign', _formatValue(value(const ['spineRawSign']))),
      MapEntry(
        'topNormalizedSign',
        _formatValue(value(const ['topNormalizedSign'])),
      ),
      MapEntry(
        'bottomNormalizedSign',
        _formatValue(value(const ['bottomNormalizedSign'])),
      ),
      MapEntry(
        'spineNormalizedSign',
        _formatValue(value(const ['spineNormalizedSign'])),
      ),
      MapEntry(
        'directionConflictBeforeNormalization',
        _formatValue(value(const ['directionConflictBeforeNormalization'])),
      ),
      MapEntry(
        'directionConflictAfterNormalization',
        _formatValue(value(const ['directionConflictAfterNormalization'])),
      ),
      MapEntry('signConvention', _formatValue(value(const ['signConvention']))),
      MapEntry(
        'horizontalDirectionVotes',
        _formatValue(value(const ['horizontalDirectionVotes'])),
      ),
      MapEntry(
        'spineUsedForDirectionConflict',
        _formatValue(value(const ['spineUsedForDirectionConflict'])),
      ),
      MapEntry('coverage', _formatValue(value(const ['coverage']))),
      MapEntry('evidenceCount', _formatValue(value(const ['evidenceCount']))),
      MapEntry('consistency', _formatValue(value(const ['consistency']))),
      MapEntry(
        'confidence',
        _formatValue(value(const ['confidence'], page.curvedConfidence)),
      ),
      MapEntry(
        'strength',
        _formatValue(value(const ['strength', 'deformationStrength'])),
      ),
      MapEntry(
        'straightnessBefore',
        _formatValue(
          value(const ['straightnessBefore', 'perspectiveStraightness']),
        ),
      ),
      MapEntry(
        'straightnessAfter',
        _formatValue(value(const ['straightnessAfter', 'curvedStraightness'])),
      ),
      MapEntry('geometryBefore', _formatValue(value(const ['geometryBefore']))),
      MapEntry('geometryAfter', _formatValue(value(const ['geometryAfter']))),
      MapEntry(
        'rejectReason',
        _formatValue(
          value(const [
            'rejectReason',
            'rejectionReason',
          ], page.curvedRejectReason ?? 'none'),
        ),
      ),
      MapEntry(
        'totalMs',
        _formatValue(
          value(const ['totalMs', 'totalMilliseconds'], derivedTotalMs),
        ),
      ),
    ];
    return _CurvatureDiagnosticsSnapshot(
      reportPath: reportPath,
      reportFound: reportFound && report != null,
      entries: entries,
      rawReport: report,
      loadError: loadError,
    );
  }

  static String _stateLabel(Object? value) {
    return switch ('$value') {
      'flat' => 'FLAT',
      'mildCurve' => 'MILD_CURVE',
      'strongCurve' => 'STRONG_CURVE',
      'unreliable' => 'UNRELIABLE',
      'none' => 'NONE',
      final other => other.toUpperCase(),
    };
  }

  static String _formatValue(Object? value) {
    if (value == null) return 'n/a';
    if (value is double) {
      final fixed = value.toStringAsFixed(6);
      return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
    }
    return '$value';
  }
}

enum _AiComparisonView { raw, openCv, aiRaw, aiRefined, aiFinal, aiMask }

class _AiSegmentationComparisonDialog extends StatefulWidget {
  const _AiSegmentationComparisonDialog({required this.page});

  final ScanPage page;

  @override
  State<_AiSegmentationComparisonDialog> createState() =>
      _AiSegmentationComparisonDialogState();
}

class _AiSegmentationComparisonDialogState
    extends State<_AiSegmentationComparisonDialog> {
  late _AiComparisonView _view;

  @override
  void initState() {
    super.initState();
    final result = widget.page.aiSegmentationResult!;
    _view = result.debugAiFinalOverlayFile != null
        ? _AiComparisonView.aiFinal
        : result.debugAiRefinedOverlayFile == null
        ? _AiComparisonView.aiRaw
        : _AiComparisonView.aiRefined;
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.page.aiSegmentationResult!;
    final sessionDirectory = path.dirname(widget.page.rawImagePath);
    final files = <_AiComparisonView, String?>{
      _AiComparisonView.raw:
          result.resolveDebugArtifact(sessionDirectory, result.debugRawFile) ??
          widget.page.rawImagePath,
      _AiComparisonView.openCv: result.resolveDebugArtifact(
        sessionDirectory,
        result.debugOpenCvOverlayFile,
      ),
      _AiComparisonView.aiRaw: result.resolveDebugArtifact(
        sessionDirectory,
        result.debugAiRawOverlayFile ?? result.debugAiOverlayFile,
      ),
      _AiComparisonView.aiRefined: result.resolveDebugArtifact(
        sessionDirectory,
        result.debugAiRefinedOverlayFile,
      ),
      _AiComparisonView.aiFinal: result.resolveDebugArtifact(
        sessionDirectory,
        result.debugAiFinalOverlayFile,
      ),
      _AiComparisonView.aiMask: result.resolveDebugArtifact(
        sessionDirectory,
        result.debugMaskFile,
      ),
    };
    final selectedPath = files[_view];
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI 검출 비교'),
          leading: IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _AiComparisonView.values.map((view) {
                    final label = switch (view) {
                      _AiComparisonView.raw => '원본',
                      _AiComparisonView.openCv => 'OpenCV',
                      _AiComparisonView.aiRaw => 'AI Raw',
                      _AiComparisonView.aiRefined => 'AI Refined',
                      _AiComparisonView.aiFinal => 'AI Final',
                      _AiComparisonView.aiMask => 'AI Mask',
                    };
                    return ChoiceChip(
                      key: ValueKey('ai-comparison-${view.name}'),
                      label: Text(label),
                      selected: _view == view,
                      onSelected: files[view] == null
                          ? null
                          : (_) => setState(() => _view = view),
                    );
                  }).toList(),
                ),
              ),
              Expanded(
                child: selectedPath != null && File(selectedPath).existsSync()
                    ? InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 6,
                        child: Center(
                          child: Image.file(
                            File(selectedPath),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const Center(child: Text('비교 이미지를 열 수 없습니다.')),
                          ),
                        ),
                      )
                    : const Center(child: Text('이 결과에는 DEBUG 비교 이미지가 없습니다.')),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                  'AI ${result.success ? "성공" : "실패"} · '
                  'coverage ${(result.maskCoverage * 100).toStringAsFixed(1)}% · '
                  'inference ${result.inferenceTimeMs}ms · '
                  'refine ${result.totalRefineMs}ms · '
                  'total ${result.totalMs}ms\n'
                  'refined ${result.refinementAccepted ? "채택" : "fallback"} · '
                  'containment ${(result.aiContainmentRatio * 100).toStringAsFixed(1)}% · '
                  'expansion ${result.areaExpansionRatio.toStringAsFixed(2)}× · '
                  'transition ${result.paperTransitionScore.toStringAsFixed(2)}\n'
                  'ownership ${result.mainPageOwnershipScore.toStringAsFixed(2)} · '
                  'occlusion ${result.occlusionPenalty.toStringAsFixed(2)} · '
                  'adjacent ${result.adjacentPagePenalty.toStringAsFixed(2)} · '
                  'quality ${result.refinedConfidence.toStringAsFixed(2)} · '
                  '${result.refinedStatus.serializedName}\n'
                  'final ${result.finalSource?.serializedName ?? "OpenCV/Guide fallback"} · '
                  '${result.edgeVisibilities.values.map((edge) => "${edge.edge.name}:${edge.status.serializedName}").join(" · ")}'
                  '${result.refinementAccepted || result.refinementFailureReason == null ? "" : " · ${result.refinementFailureReason}"}'
                  '${result.failureReason == null ? "" : " · ${result.failureReason}"}',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _enhancementStatusLabel(EnhancementStatus status, EnhancementMode mode) {
  return switch (status) {
    EnhancementStatus.none => '검출/스캔 처리 전',
    EnhancementStatus.processing => '${mode.label} 처리 중',
    EnhancementStatus.completed => '${mode.label} 완료',
    EnhancementStatus.failed => '스캔 처리 실패 · 보정본 사용',
  };
}
