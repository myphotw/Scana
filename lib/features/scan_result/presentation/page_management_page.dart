import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/pdf_export/pdf_saf_storage.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';

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
    this.clock = DateTime.now,
  });

  final ScanSessionManager sessionManager;
  final CameraStartup? cameraStartup;
  final PdfExportWorkflow? pdfExportWorkflow;
  final DateTime Function() clock;

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
          clock: widget.clock,
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
        ),
      ),
    );
    if (!mounted) return;
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
    required this.onDelete,
  });

  final List<ScanPage> pages;
  final Set<String> selectedPaths;
  final ValueChanged<ScanPage> onToggle;
  final ValueChanged<ScanPage> onOpen;
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
          childAspectRatio: 0.72,
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
            onDelete: () => onDelete(page),
          );
        },
      ),
    );
  }
}

class _GalleryPageCard extends StatelessWidget {
  const _GalleryPageCard({
    super.key,
    required this.page,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onPreview,
    required this.onDelete,
  });

  final ScanPage page;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPreview;
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
      child: InkWell(
        key: ValueKey('pdfGalleryCard-${page.rawImagePath}'),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 42),
                child: _PageImage(page: page),
              ),
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
              left: 8,
              right: 4,
              bottom: 2,
              child: Row(
                children: [
                  Expanded(child: Text('페이지 ${page.pageNo}')),
                  IconButton(
                    tooltip: '크게 보기',
                    onPressed: onPreview,
                    icon: const Icon(Icons.zoom_out_map, size: 20),
                  ),
                  IconButton(
                    tooltip: '페이지 삭제',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ],
              ),
            ),
          ],
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
        File(page.correctedImagePath ?? page.rawImagePath),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            const Center(child: Icon(Icons.image_not_supported_outlined)),
      ),
    );
  }
}
