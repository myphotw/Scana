import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/page_editor/presentation/quick_corner_edit_page.dart';
import 'package:scana/features/page_editor/presentation/mlkit_page_edit_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/page_correction.dart';
import 'package:scana/models/page_enhancement.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/pdf_export/pdf_saf_storage.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/mlkit_document_scanner/mlkit_page_mutation_policy.dart';
import 'package:scana/services/pdf_export/pdf_document_opener.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

class PdfSelectionGalleryLayout {
  const PdfSelectionGalleryLayout._();

  static int columnCount(double width) => (width / 220).floor().clamp(2, 4);
}

/// Selects which session pages are included in the PDF. Ordering is owned by
/// [PdfPageReviewPage], not by this route or the scan session.
class PageManagementPage extends StatefulWidget {
  const PageManagementPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.pdfExportWorkflow,
    this.ocrService,
    this.pdfDocumentOpener,
    this.clock = DateTime.now,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final CameraStartup? cameraStartup;
  final PdfExportWorkflow? pdfExportWorkflow;
  final OcrService? ocrService;
  final PdfDocumentOpener? pdfDocumentOpener;
  final DateTime Function() clock;
  final ScreenOrientationController orientationController;

  @override
  State<PageManagementPage> createState() => _PageManagementPageState();
}

class _PageManagementPageState extends State<PageManagementPage> {
  final Set<String> _selectedPaths = {};
  bool _isExitingEmptySession = false;
  bool _isOpeningReview = false;
  late final PdfExportWorkflow _pdfExportWorkflow;

  @override
  void initState() {
    super.initState();
    unawaited(widget.orientationController.enterContentScreen());
    DebugDiagnostics.instance.logState(
      'PageManagementPage.initState',
      mounted: mounted,
    );
    _pdfExportWorkflow =
        widget.pdfExportWorkflow ??
        PdfExportWorkflow(
          destinationStorage: const AndroidSafPdfStorage(),
          deleteAfterSuccessfulExport:
              widget.sessionManager.deleteAfterSuccessfulExport,
        );
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.logState(
      'PageManagementPage.dispose',
      mounted: mounted,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.sessionManager,
      builder: (context, child) {
        final pages = widget.sessionManager.currentSession?.pages ?? const [];
        _selectedPaths.removeWhere(
          (path) => !pages.any((page) => page.rawImagePath == path),
        );
        if (pages.isEmpty && !_isOpeningReview) {
          _returnToPreviousRouteWhenCurrent();
        }
        final processing = widget.sessionManager.processingPageCount;
        return Scaffold(
          appBar: AppBar(
            title: const Text('PDF 페이지 선택'),
            actions: [
              IconButton(
                key: const Key('toggleSelectAllButton'),
                tooltip: _selectedPaths.length == pages.length
                    ? '전체 해제'
                    : '전체 선택',
                onPressed: pages.isEmpty ? null : () => _toggleSelectAll(pages),
                icon: Icon(
                  _selectedPaths.length == pages.length
                      ? Icons.deselect
                      : Icons.select_all,
                ),
              ),
            ],
          ),
          body: pages.isEmpty
              ? const SizedBox.shrink()
              : _PdfSelectionGallery(
                  pages: pages,
                  selectedPaths: _selectedPaths,
                  onToggle: _toggleSelection,
                  onOpen: (page) => _openViewer(pages, page),
                  onEditPage: _editMlKitPage,
                  onEditCorners: _quickEditCorners,
                  onDelete: (page) => _deletePage(pages.indexOf(page)),
                ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      processing > 0
                          ? '${_selectedPaths.length}페이지 선택됨 · $processing개 처리 중'
                          : '${_selectedPaths.length}페이지 선택됨',
                      key: const Key('pdfSelectionCount'),
                    ),
                  ),
                  FilledButton.icon(
                    key: const Key('reviewSelectedPagesButton'),
                    onPressed:
                        _selectedPaths.isEmpty ||
                            processing > 0 ||
                            _isOpeningReview
                        ? null
                        : () => _openReview(pages),
                    icon: const Icon(Icons.check),
                    label: const Text('완료'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _returnToPreviousRouteWhenCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isExitingEmptySession) return;
      final route = ModalRoute.of(context);
      if (route?.isCurrent != true) return;
      _isExitingEmptySession = true;
      Navigator.of(context).pop(true);
    });
  }

  void _toggleSelectAll(List<ScanPage> pages) {
    setState(() {
      if (_selectedPaths.length == pages.length) {
        _selectedPaths.clear();
      } else {
        _selectedPaths
          ..clear()
          ..addAll(pages.map((page) => page.rawImagePath));
      }
    });
  }

  void _toggleSelection(ScanPage page) {
    setState(() {
      if (!_selectedPaths.add(page.rawImagePath)) {
        _selectedPaths.remove(page.rawImagePath);
      }
    });
  }

  Future<void> _openReview(List<ScanPage> pages) async {
    if (_isOpeningReview) return;
    final selectedPages = pages
        .where((page) => _selectedPaths.contains(page.rawImagePath))
        .toList(growable: false);
    if (selectedPages.isEmpty) return;
    setState(() => _isOpeningReview = true);
    final exported = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => PdfPageReviewPage(
          sessionManager: widget.sessionManager,
          selectedPages: selectedPages,
          pdfExportWorkflow: _pdfExportWorkflow,
          ocrService: widget.ocrService ?? const AndroidLocalOcrService(),
          pdfDocumentOpener:
              widget.pdfDocumentOpener ?? const AndroidPdfDocumentOpener(),
          clock: widget.clock,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _isOpeningReview = false);
    if (exported == true && ModalRoute.of(context)?.isCurrent == true) {
      _isExitingEmptySession = true;
      if (kDebugMode) debugPrint('[PDF_FLOW] gallery_pop');
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _openViewer(List<ScanPage> pages, ScanPage page) async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (context) => ScanResultViewerPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
          initialPageIndex: pages.indexOf(page).clamp(0, pages.length - 1),
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted) return;
  }

  Future<void> _quickEditCorners(ScanPage page) async {
    final pages = widget.sessionManager.currentSession?.pages ?? const [];
    final index = pages.indexWhere(
      (candidate) => candidate.rawImagePath == page.rawImagePath,
    );
    if (index < 0) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => QuickCornerEditPage(
          sessionManager: widget.sessionManager,
          pageIndex: index,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted) return;
  }

  Future<void> _editMlKitPage(ScanPage page) async {
    final pages = widget.sessionManager.currentSession?.pages ?? const [];
    final index = pages.indexWhere(
      (candidate) => candidate.rawImagePath == page.rawImagePath,
    );
    if (index < 0) return;
    final selectedBefore = Set<String>.of(_selectedPaths);
    final mutation = await Navigator.of(context).push<MlKitPageMutation>(
      MaterialPageRoute<MlKitPageMutation>(
        builder: (context) => MlKitPageEditPage(
          sessionManager: widget.sessionManager,
          pageIndex: index,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted || mutation == null) return;
    setState(() {
      final updated = MlKitPageMutationPolicy.preserveSelection(
        selectedBefore,
        mutation,
      );
      _selectedPaths
        ..clear()
        ..addAll(updated);
    });
  }

  Future<void> _deletePage(int index) async {
    final pages = widget.sessionManager.currentSession?.pages ?? const [];
    if (index < 0 || index >= pages.length) return;
    final rawPath = pages[index].rawImagePath;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('페이지 삭제'),
        content: const Text('현재 페이지와 관련 원본·보정 파일을 삭제합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _selectedPaths.remove(rawPath);
    await widget.sessionManager.deletePageAt(index);
    if (!mounted) return;
    if (widget.sessionManager.pageCount == 0) {
      _returnToPreviousRouteWhenCurrent();
    }
  }
}

class _PdfSelectionGallery extends StatelessWidget {
  const _PdfSelectionGallery({
    required this.pages,
    required this.selectedPaths,
    required this.onToggle,
    required this.onOpen,
    required this.onEditPage,
    required this.onEditCorners,
    required this.onDelete,
  });

  final List<ScanPage> pages;
  final Set<String> selectedPaths;
  final ValueChanged<ScanPage> onToggle;
  final ValueChanged<ScanPage> onOpen;
  final ValueChanged<ScanPage> onEditPage;
  final ValueChanged<ScanPage> onEditCorners;
  final ValueChanged<ScanPage> onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
        key: const Key('pdfSelectionGallery'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: PdfSelectionGalleryLayout.columnCount(
            constraints.maxWidth,
          ),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.66,
        ),
        itemCount: pages.length,
        itemBuilder: (context, index) {
          final page = pages[index];
          return _GalleryPageCard(
            key: ValueKey('pdf-gallery-page-${page.rawImagePath}'),
            page: page,
            selected: selectedPaths.contains(page.rawImagePath),
            onTap: () => onToggle(page),
            onLongPress: () => onOpen(page),
            onPreview: () => onOpen(page),
            onEditPage: () => onEditPage(page),
            onEditCorners: () => onEditCorners(page),
            onDelete: () => onDelete(page),
          );
        },
      ),
    );
  }
}

/// Gallery card with controls in a dedicated row outside the image viewport.
class _GalleryPageCard extends StatelessWidget {
  const _GalleryPageCard({
    super.key,
    required this.page,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onPreview,
    required this.onEditPage,
    required this.onEditCorners,
    required this.onDelete,
  });

  final ScanPage page;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPreview;
  final VoidCallback onEditPage;
  final VoidCallback onEditCorners;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          width: selected ? 3 : 1,
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: InkWell(
              key: ValueKey('pdfGalleryCard-${page.rawImagePath}'),
              onTap: onTap,
              onLongPress: onLongPress,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: colorScheme.surfaceContainerHighest,
                    child: _PageImage(page: page),
                  ),
                  if (selected)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: CircleAvatar(
                        key: ValueKey('pdfSelected-${page.rawImagePath}'),
                        radius: 15,
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        child: const Icon(Icons.check, size: 19),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _PageProcessingBadge(page: page),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            key: ValueKey('gallery-action-row-${page.rawImagePath}'),
            height: 44,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 150;
                return Row(
                  children: [
                    SizedBox(width: compact ? 2 : 8),
                    if (!compact)
                      Expanded(
                        child: Text(
                          '페이지 ${page.pageNo}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else
                      const Spacer(),
                    _GalleryActionButton(
                      tooltip: '크게 보기',
                      onPressed: onPreview,
                      icon: Icons.zoom_out_map,
                      compact: compact,
                    ),
                    if (page.usesCustomImagePipeline)
                      _GalleryActionButton(
                        key: ValueKey(
                          'gallery-quick-corner-${page.rawImagePath}',
                        ),
                        tooltip: '모서리 수정',
                        onPressed: onEditCorners,
                        icon: Icons.crop_free,
                        compact: compact,
                      ),
                    if (page.isMlKitPage)
                      _GalleryActionButton(
                        key: ValueKey(
                          'gallery-mlkit-edit-${page.rawImagePath}',
                        ),
                        tooltip: '페이지 편집',
                        onPressed: onEditPage,
                        icon: Icons.edit_outlined,
                        compact: compact,
                      ),
                    _GalleryActionButton(
                      tooltip: '페이지 삭제',
                      onPressed: onDelete,
                      icon: Icons.delete_outline,
                      compact: compact,
                    ),
                    const SizedBox(width: 2),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryActionButton extends StatelessWidget {
  const _GalleryActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.compact = false,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 19),
      padding: const EdgeInsets.all(6),
      constraints: BoxConstraints.tightFor(
        width: compact ? 32 : 36,
        height: 36,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _PageProcessingBadge extends StatelessWidget {
  const _PageProcessingBadge({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    if (!page.usesCustomImagePipeline) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            'ML Kit',
            key: ValueKey('page-processing-${page.rawImagePath}'),
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      );
    }
    final (label, color) = switch ((
      page.correctionStatus,
      page.enhancementStatus,
    )) {
      (CorrectionStatus.processing, _) => ('보정 중', Colors.orange),
      (_, EnhancementStatus.processing) => ('스캔 처리 중', Colors.orange),
      (CorrectionStatus.failed, _) => ('보정 실패', Colors.red),
      (_, EnhancementStatus.failed) => ('처리 실패', Colors.red),
      (_, EnhancementStatus.completed) => ('완료', Colors.green),
      _ => ('검출 중', Colors.blueGrey),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          label,
          key: ValueKey('page-processing-${page.rawImagePath}'),
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
      ),
    );
  }
}

class _PageImage extends StatelessWidget {
  const _PageImage({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      key: ValueKey('managed-thumbnail-rotation-${page.pageNo}'),
      angle: page.rotation * math.pi / 180,
      child: Image.file(
        File(page.displayImagePath),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            const Center(child: Icon(Icons.image_not_supported_outlined)),
      ),
    );
  }
}
