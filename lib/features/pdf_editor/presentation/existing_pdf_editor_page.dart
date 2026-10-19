import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:scana/features/scan_result/presentation/pdf_page_review_page.dart';
import 'package:scana/services/pdf_editor/existing_pdf_editor.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/pdf_export/pdf_saf_storage.dart';

class ExistingPdfEditorPage extends StatefulWidget {
  const ExistingPdfEditorPage({
    super.key,
    required this.document,
    this.editorPlatform = const AndroidExistingPdfEditorPlatform(),
    this.destinationStorage = const AndroidSafPdfStorage(),
    this.clock = DateTime.now,
  });

  final ExistingPdfDocument document;
  final ExistingPdfEditorPlatform editorPlatform;
  final PdfDestinationStorage destinationStorage;
  final DateTime Function() clock;

  @override
  State<ExistingPdfEditorPage> createState() => _ExistingPdfEditorPageState();
}

class _ExistingPdfEditorPageState extends State<ExistingPdfEditorPage> {
  late final List<int> _activePages;
  final List<int> _deletedPages = [];
  final Map<int, int> _restorePositions = {};
  final Map<int, Future<String>> _thumbnailFutures = {};
  bool _isDragging = false;
  bool _isSaving = false;
  bool _cleanupRequested = false;

  @override
  void initState() {
    super.initState();
    _activePages = List<int>.generate(
      widget.document.pageCount,
      (index) => index,
    );
  }

  @override
  void dispose() {
    _requestCleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDragging && !_isSaving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.document.displayName),
          actions: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${_activePages.length} 페이지'),
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            Semantics(
              key: const Key('existingPdfPageOrder'),
              value: _activePages.join(','),
              child: CustomScrollView(
                slivers: [
                  const SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    sliver: SliverToBoxAdapter(
                      child: Text('페이지를 길게 눌러 순서를 변경할 수 있습니다.'),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final columns = (constraints.crossAxisExtent / 220)
                            .floor()
                            .clamp(2, 4);
                        return SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                childAspectRatio: .72,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _buildPageTarget(index),
                            childCount: _activePages.length,
                          ),
                        );
                      },
                    ),
                  ),
                  if (_deletedPages.isNotEmpty) ...[
                    const SliverPadding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                      sliver: SliverToBoxAdapter(
                        child: Text(
                          '삭제한 페이지',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                      sliver: SliverList.builder(
                        itemCount: _deletedPages.length,
                        itemBuilder: (context, index) {
                          final page = _deletedPages[index];
                          return Card(
                            child: ListTile(
                              leading: const Icon(Icons.delete_outline),
                              title: Text('원본 ${page + 1}페이지'),
                              trailing: TextButton.icon(
                                key: ValueKey('restorePdfPage-$page'),
                                onPressed: _isSaving
                                    ? null
                                    : () => _restore(page),
                                icon: const Icon(Icons.restore),
                                label: const Text('복원'),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ] else
                    const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                minimum: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('saveExistingPdfButton'),
                    onPressed: _isSaving || _isDragging ? null : _save,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('PDF 저장'),
                  ),
                ),
              ),
            ),
            if (_isSaving)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageTarget(int targetIndex) {
    final page = _activePages[targetIndex];
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) {
        final sourceIndex = _activePages.indexOf(details.data);
        if (sourceIndex < 0 || sourceIndex == targetIndex) return false;
        setState(() {
          final moved = _activePages.removeAt(sourceIndex);
          final insertion = sourceIndex < targetIndex
              ? targetIndex - 1
              : targetIndex;
          _activePages.insert(insertion.clamp(0, _activePages.length), moved);
        });
        return true;
      },
      builder: (context, candidates, rejected) => LongPressDraggable<int>(
        data: page,
        maxSimultaneousDrags: _isSaving ? 0 : 1,
        onDragStarted: () => setState(() => _isDragging = true),
        onDragEnd: (_) {
          if (mounted) setState(() => _isDragging = false);
        },
        feedback: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 180, height: 250, child: _pageCard(page)),
        ),
        childWhenDragging: Opacity(opacity: .35, child: _pageCard(page)),
        child: _pageCard(page),
      ),
    );
  }

  Widget _pageCard(int page) {
    return Card(
      key: ValueKey('existingPdfPage-$page'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: FutureBuilder<String>(
              future: _thumbnailFutures.putIfAbsent(
                page,
                () => widget.editorPlatform.renderThumbnail(
                  sessionId: widget.document.sessionId,
                  pageIndex: page,
                ),
              ),
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return Image.file(
                    File(snapshot.requireData),
                    width: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  );
                }
                if (snapshot.hasError) {
                  return const Center(child: Icon(Icons.broken_image_outlined));
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
          ListTile(
            dense: true,
            title: Text('${_activePages.indexOf(page) + 1}'),
            subtitle: Text('원본 ${page + 1}페이지'),
            trailing: IconButton(
              key: ValueKey('deletePdfPage-$page'),
              tooltip: '삭제',
              onPressed: _isSaving ? null : () => _delete(page),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        ],
      ),
    );
  }

  void _delete(int page) {
    if (_activePages.length == 1) {
      _showMessage('모든 페이지를 삭제할 수 없습니다.');
      return;
    }
    setState(() {
      final index = _activePages.indexOf(page);
      _restorePositions[page] = index;
      _activePages.removeAt(index);
      _deletedPages.add(page);
      _deletedPages.sort();
    });
  }

  void _restore(int page) {
    setState(() {
      _deletedPages.remove(page);
      final index = (_restorePositions.remove(page) ?? _activePages.length)
          .clamp(0, _activePages.length);
      _activePages.insert(index, page);
    });
  }

  Future<void> _save() async {
    if (_activePages.isEmpty || _isSaving || _isDragging) return;
    final requestedName = await showDialog<String>(
      context: context,
      builder: (context) =>
          PdfFileNameDialog(initialFileName: _defaultEditedName()),
    );
    if (!mounted || requestedName == null) return;
    final directory = await _chooseDirectory();
    if (!mounted || directory == null) return;
    setState(() => _isSaving = true);
    ExistingPdfExport? edited;
    try {
      edited = await widget.editorPlatform.exportPdf(
        sessionId: widget.document.sessionId,
        pageOrder: List<int>.unmodifiable(_activePages),
      );
      final saved = await widget.destinationStorage.save(
        temporaryPdfPath: edited.outputPath,
        directory: directory,
        fileName: requestedName,
      );
      if (!mounted) return;
      _cleanupRequested = true;
      await widget.editorPlatform.cleanup(widget.document.sessionId);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('PDF 저장 완료'),
          content: Text('${saved.displayName}\n${edited!.pageCount}페이지'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (edited != null) {
        await widget.editorPlatform.discardOutput(
          sessionId: widget.document.sessionId,
          outputPath: edited.outputPath,
        );
      }
      if (mounted) _showMessage('PDF 저장에 실패했습니다. 원본 PDF는 변경되지 않았습니다.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<PdfDirectoryLocation?> _chooseDirectory() async {
    try {
      final recent = await widget.destinationStorage.recentDirectory();
      if (!mounted) return null;
      if (recent == null) return widget.destinationStorage.chooseDirectory();
      final useRecent = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장 위치'),
          content: Text('최근 위치: ${recent.label}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('다른 위치'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('최근 위치 사용'),
            ),
          ],
        ),
      );
      if (!mounted || useRecent == null) return null;
      return useRecent ? recent : widget.destinationStorage.chooseDirectory();
    } on Object {
      if (mounted) _showMessage('저장 위치를 사용할 수 없습니다.');
      return null;
    }
  }

  String _defaultEditedName() {
    final original = widget.document.displayName;
    final base = original.toLowerCase().endsWith('.pdf')
        ? original.substring(0, original.length - 4)
        : original;
    return '${PdfFileNamePolicy.sanitizeBaseName(base)}_편집본';
  }

  void _requestCleanup() {
    if (_cleanupRequested) return;
    _cleanupRequested = true;
    unawaited(widget.editorPlatform.cleanup(widget.document.sessionId));
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
