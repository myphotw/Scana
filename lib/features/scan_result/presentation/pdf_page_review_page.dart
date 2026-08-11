import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/ocr/ocr_service.dart';
import 'package:scana/services/ocr/pdf_title_suggestion_service.dart';
import 'package:scana/services/pdf_export/pdf_document_opener.dart';
import 'package:scana/services/pdf_export/pdf_export_service.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

class PdfReviewGridLayout {
  const PdfReviewGridLayout._();

  static int columnCount(double width) => (width / 220).floor().clamp(2, 4);
}

/// Owns a snapshot of selected pages and their temporary PDF output order.
/// It never owns or disposes the injected scan manager or export workflow.
class PdfPageReviewPage extends StatefulWidget {
  const PdfPageReviewPage({
    super.key,
    required this.sessionManager,
    required this.selectedPages,
    required this.pdfExportWorkflow,
    this.clock = DateTime.now,
    this.ocrService = const AndroidLocalOcrService(),
    this.pdfDocumentOpener = const AndroidPdfDocumentOpener(),
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final List<ScanPage> selectedPages;
  final PdfExportWorkflow pdfExportWorkflow;
  final DateTime Function() clock;
  final OcrService ocrService;
  final PdfDocumentOpener pdfDocumentOpener;
  final ScreenOrientationController orientationController;

  @override
  State<PdfPageReviewPage> createState() => _PdfPageReviewPageState();
}

class _PdfPageReviewPageState extends State<PdfPageReviewPage>
    with WidgetsBindingObserver {
  late List<ScanPage> _orderedPages;
  String? _draggingPath;
  bool _exportFlowActive = false;
  bool _isExporting = false;
  PdfExportProgress? _exportProgress;
  bool _isAnalyzingTitle = true;
  bool _titleAnalysisFailed = false;
  String? _suggestedTitle;
  PdfExportResult? _completionResult;
  bool _isOpeningDocument = false;

  bool get _isDragging => _draggingPath != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.orientationController.enterContentScreen());
    _orderedPages = List<ScanPage>.of(widget.selectedPages);
    _suggestedTitle = widget.sessionManager.currentSession?.suggestedTitle;
    _isAnalyzingTitle = _suggestedTitle == null;
    DebugDiagnostics.instance.logState(
      'PdfPageReviewPage.initState',
      mounted: mounted,
      exportFlowActive: _exportFlowActive,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _logPdfFlow('review_mounted');
      _logPdfFlow(
        'review_route_current current=${ModalRoute.of(context)?.isCurrent}',
      );
      if (_suggestedTitle == null) _analyzeSuggestedTitle();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DebugDiagnostics.instance.logState(
      'PdfPageReviewPage.dispose',
      mounted: mounted,
      exportFlowActive: _exportFlowActive,
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.orientationController.enterContentScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop:
          !_isDragging &&
          !_exportFlowActive &&
          _completionResult == null &&
          !_isOpeningDocument,
      child: Scaffold(
        appBar: AppBar(title: const Text('PDF 페이지 확인')),
        body: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) => GridView.builder(
                key: const Key('pdfPageReviewGrid'),
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: PdfReviewGridLayout.columnCount(
                    constraints.maxWidth,
                  ),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.72,
                ),
                itemCount: _orderedPages.length,
                itemBuilder: (context, index) => _ReviewDragTarget(
                  key: ValueKey(
                    'pdf-review-target-${_orderedPages[index].rawImagePath}',
                  ),
                  page: _orderedPages[index],
                  pdfIndex: index,
                  isDragging:
                      _draggingPath == _orderedPages[index].rawImagePath,
                  onDragStarted: () {
                    if (!mounted || _exportFlowActive) return;
                    setState(
                      () => _draggingPath = _orderedPages[index].rawImagePath,
                    );
                  },
                  onDragEnded: () {
                    if (!mounted) return;
                    setState(() => _draggingPath = null);
                  },
                  onAccept: (rawPath) => _movePage(rawPath, index),
                  onTap: () => _openViewer(index),
                ),
              ),
            ),
            if (_isExporting)
              Positioned.fill(
                child: _PdfExportOverlay(
                  progress:
                      _exportProgress ??
                      PdfExportProgress(
                        completed: 0,
                        total: _orderedPages.length,
                      ),
                ),
              ),
            if (_completionResult case final completion?)
              Positioned.fill(
                child: _PdfCompletionOverlay(
                  result: completion,
                  openingDocument: _isOpeningDocument,
                  onNewScan: _startNewScan,
                  onOpenFile: _openSavedPdf,
                ),
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _titleStatusText,
                  key: const Key('pdfTitleSuggestionStatus'),
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const Key('createReviewedPdfButton'),
                  onPressed:
                      _isDragging ||
                          _exportFlowActive ||
                          _completionResult != null
                      ? null
                      : _startPdfExport,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text('${_orderedPages.length}페이지 PDF 만들기'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _titleStatusText {
    if (_isAnalyzingTitle) return '제목 분석 중...';
    if (_suggestedTitle case final title?) return '제안 제목: $title';
    if (_titleAnalysisFailed) return '제목을 찾지 못해 날짜 기반 이름을 사용합니다.';
    return '날짜 기반 파일명을 사용합니다.';
  }

  void _movePage(String rawPath, int targetIndex) {
    if (!_isDragging || _exportFlowActive) return;
    final oldIndex = _orderedPages.indexWhere(
      (page) => page.rawImagePath == rawPath,
    );
    if (oldIndex < 0 || oldIndex == targetIndex) return;
    setState(() {
      final page = _orderedPages.removeAt(oldIndex);
      _orderedPages.insert(targetIndex.clamp(0, _orderedPages.length), page);
    });
  }

  Future<void> _openViewer(int index) async {
    if (_isDragging || _exportFlowActive) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => _PdfReviewViewerPage(
          pages: List<ScanPage>.of(_orderedPages),
          initialPageIndex: index,
        ),
      ),
    );
    if (!mounted) return;
  }

  Future<void> _startPdfExport() async {
    if (_isDragging || _exportFlowActive || _orderedPages.isEmpty) return;
    final selection = PdfExportSelection.fromOrderedRawPaths(
      widget.sessionManager.currentSession?.pages ?? const [],
      _orderedPages.map((page) => page.rawImagePath).toList(growable: false),
    );
    if (selection.pages.length != _orderedPages.length) {
      _showPdfError('일부 페이지를 찾을 수 없습니다. Gallery에서 다시 선택해주세요.');
      return;
    }
    setState(() => _exportFlowActive = true);
    var routeCompleted = false;
    try {
      _logPdfFlow('filename_open');
      final requestedFileName = await _askPdfFileName();
      if (!mounted) return;
      _logPdfFlow('filename_closed accepted=${requestedFileName != null}');
      if (requestedFileName == null || !await _yieldToStableFrame()) return;

      PdfDirectoryLocation? directory;
      try {
        directory = await _choosePdfDirectory();
      } on Object catch (error) {
        _logPdfFlow('saf_error error=$error');
        if (mounted) _showPdfError('저장 위치를 사용할 수 없습니다.');
        return;
      }
      if (!mounted) return;
      _logPdfFlow('saf_result_received uri=${directory?.uri ?? 'cancelled'}');
      if (directory == null || !await _yieldToStableFrame()) return;

      setState(() {
        _isExporting = true;
        _exportProgress = PdfExportProgress(
          completed: 0,
          total: selection.pages.length,
        );
      });
      _logPdfFlow('export_start pages=${selection.pages.length}');
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final result = await widget.pdfExportWorkflow.export(
        selection: selection,
        requestedFileName: requestedFileName,
        directory: directory,
        onProgress: (value) {
          if (mounted) setState(() => _exportProgress = value);
        },
      );
      if (!mounted) return;
      if (result.status == PdfExportStatus.cancelled) {
        _logPdfFlow('export_cancelled');
        return;
      }
      _logPdfFlow(
        'export_complete file=${result.savedDocument?.displayName ?? ''}',
      );
      _logPdfFlow('session_deleted');
      setState(() {
        _exportFlowActive = false;
        _isExporting = false;
        _exportProgress = null;
      });
      if (!await _yieldToStableFrame()) return;
      if (!mounted) return;
      routeCompleted = true;
      setState(() => _completionResult = result);
      _logPdfFlow('completion_visible uri=${result.documentUri ?? ''}');
    } on Object catch (error) {
      _logPdfFlow('export_failed error=$error');
      if (mounted) {
        _showPdfError('PDF 저장에 실패했습니다. 페이지와 세션은 유지됩니다.');
      }
    } finally {
      if (mounted && !routeCompleted) {
        setState(() {
          _exportFlowActive = false;
          _isExporting = false;
          _exportProgress = null;
        });
      }
    }
  }

  Future<bool> _yieldToStableFrame() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return false;
    await WidgetsBinding.instance.endOfFrame;
    return mounted && ModalRoute.of(context)?.isCurrent == true;
  }

  void _logPdfFlow(String event) {
    if (!kDebugMode) return;
    final routeCurrent = mounted ? ModalRoute.of(context)?.isCurrent : null;
    DebugDiagnostics.instance.log(
      'PDF_FLOW',
      '$event mounted=$mounted routeCurrent=$routeCurrent '
          'exportFlowActive=$_exportFlowActive isExporting=$_isExporting',
    );
    debugPrint('[PDF_FLOW] $event');
  }

  Future<String?> _askPdfFileName() async {
    return showDialog<String>(
      context: context,
      builder: (context) => PdfFileNameDialog(
        initialFileName:
            _suggestedTitle ??
            PdfFileNamePolicy.defaultBaseName(widget.clock()),
      ),
    );
  }

  Future<PdfDirectoryLocation?> _choosePdfDirectory() async {
    final recent = await widget.pdfExportWorkflow.destinationStorage
        .recentDirectory();
    if (!mounted) return null;
    if (recent == null) {
      _logPdfFlow('saf_request_start');
      return widget.pdfExportWorkflow.destinationStorage.chooseDirectory();
    }
    _logPdfFlow('location_choice_open');
    final choice = await showDialog<_PdfLocationChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PDF 저장 위치'),
        content: Text('최근 위치: ${recent.label}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_PdfLocationChoice.chooseAnother),
            child: const Text('다른 위치 선택'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_PdfLocationChoice.useRecent),
            child: const Text('최근 위치에 저장'),
          ),
        ],
      ),
    );
    if (mounted) {
      _logPdfFlow('location_choice_closed choice=${choice?.name ?? 'cancel'}');
    }
    if (!mounted || choice == null) return null;
    if (choice == _PdfLocationChoice.useRecent) return recent;
    if (!await _yieldToStableFrame()) return null;
    _logPdfFlow('saf_request_start');
    return widget.pdfExportWorkflow.destinationStorage.chooseDirectory();
  }

  void _showPdfError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _analyzeSuggestedTitle() async {
    final suggestionService = PdfTitleSuggestionService(
      ocrService: widget.ocrService,
    );
    final suggestion = await suggestionService.suggest(
      List<ScanPage>.of(_orderedPages),
    );
    if (!mounted || _completionResult != null) return;
    if (suggestion == null) {
      setState(() {
        _isAnalyzingTitle = false;
        _titleAnalysisFailed = true;
      });
      return;
    }
    try {
      await widget.sessionManager.updateSuggestedTitle(
        suggestion.title,
        sourcePageNo: suggestion.sourcePageNo,
      );
    } on Object {
      // The in-memory suggestion is still usable if persistence races export.
    }
    if (!mounted || _completionResult != null) return;
    setState(() {
      _suggestedTitle = suggestion.title;
      _isAnalyzingTitle = false;
      _titleAnalysisFailed = false;
    });
  }

  void _startNewScan() {
    if (_completionResult == null || _isOpeningDocument) return;
    _logPdfFlow('completion_new_scan');
    Navigator.of(context).pop(true);
  }

  Future<void> _openSavedPdf() async {
    final documentUri = _completionResult?.documentUri;
    if (documentUri == null || _isOpeningDocument) return;
    setState(() => _isOpeningDocument = true);
    try {
      final openResult = await widget.pdfDocumentOpener.open(documentUri);
      if (!mounted) return;
      if (openResult == PdfOpenResult.noViewer) {
        _showPdfError('PDF를 열 수 있는 앱이 없습니다.');
      }
    } on Object {
      if (mounted) _showPdfError('PDF를 열 수 있는 앱이 없습니다.');
    } finally {
      if (mounted) setState(() => _isOpeningDocument = false);
    }
  }
}

/// Owns the filename field and releases its controller only when the dialog
/// widget is actually removed after its reverse route transition.
class PdfFileNameDialog extends StatefulWidget {
  const PdfFileNameDialog({super.key, required this.initialFileName});

  final String initialFileName;

  @override
  State<PdfFileNameDialog> createState() => _PdfFileNameDialogState();
}

class _PdfFileNameDialogState extends State<PdfFileNameDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialFileName);
    DebugDiagnostics.instance.log('STATE', 'PdfFileNameController.created');
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.log('STATE', 'PdfFileNameDialog.dispose');
    _controller.dispose();
    DebugDiagnostics.instance.log('STATE', 'PdfFileNameController.dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        DebugDiagnostics.instance.log(
          'PDF_FLOW',
          'filename_dialog_pop accepted=${result is String}',
        );
      },
      child: AlertDialog(
        title: const Text('PDF 파일명'),
        content: TextField(
          key: const Key('pdfFileNameField'),
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            suffixText: '.pdf',
            errorText: _errorText,
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(onPressed: _submit, child: const Text('저장 위치 선택')),
        ],
      ),
    );
  }

  void _submit() {
    try {
      Navigator.of(context).pop(PdfFileNamePolicy.sanitize(_controller.text));
    } on FormatException {
      setState(() => _errorText = '파일명을 입력해주세요.');
    }
  }
}

enum _PdfLocationChoice { useRecent, chooseAnother }

class _ReviewDragTarget extends StatelessWidget {
  const _ReviewDragTarget({
    super.key,
    required this.page,
    required this.pdfIndex,
    required this.isDragging,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onAccept,
    required this.onTap,
  });

  final ScanPage page;
  final int pdfIndex;
  final bool isDragging;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;
  final ValueChanged<String> onAccept;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != page.rawImagePath,
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidates, rejected) {
        final highlighted = candidates.isNotEmpty;
        return LongPressDraggable<String>(
          key: ValueKey('pdf-review-drag-${page.rawImagePath}'),
          data: page.rawImagePath,
          delay: const Duration(milliseconds: 450),
          onDragStarted: onDragStarted,
          onDragEnd: (_) => onDragEnded(),
          feedback: Material(
            color: Colors.transparent,
            elevation: 10,
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 180,
              height: 250,
              child: _ReviewCard(
                page: page,
                pdfIndex: pdfIndex,
                elevated: true,
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: _ReviewCard(page: page, pdfIndex: pdfIndex),
          ),
          child: _ReviewCard(
            key: ValueKey('pdf-review-card-${page.rawImagePath}'),
            page: page,
            pdfIndex: pdfIndex,
            elevated: highlighted || isDragging,
            onTap: onTap,
          ),
        );
      },
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    super.key,
    required this.page,
    required this.pdfIndex,
    this.elevated = false,
    this.onTap,
  });

  final ScanPage page;
  final int pdfIndex;
  final bool elevated;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: elevated ? 8 : 1,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: elevated ? colorScheme.primary : colorScheme.outlineVariant,
          width: elevated ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 36),
              child: _ReviewImage(page: page),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: CircleAvatar(
                key: ValueKey('pdf-review-number-${page.rawImagePath}'),
                radius: 14,
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
                child: Text('${pdfIndex + 1}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewImage extends StatelessWidget {
  const _ReviewImage({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
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

class _PdfReviewViewerPage extends StatefulWidget {
  const _PdfReviewViewerPage({
    required this.pages,
    required this.initialPageIndex,
  });

  final List<ScanPage> pages;
  final int initialPageIndex;

  @override
  State<_PdfReviewViewerPage> createState() => _PdfReviewViewerPageState();
}

class _PdfReviewViewerPageState extends State<_PdfReviewViewerPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialPageIndex.clamp(0, widget.pages.length - 1);
    _controller = PageController(initialPage: _index);
    DebugDiagnostics.instance.log(
      'STATE',
      'PdfReviewViewerPage.initState PageController.created',
    );
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.log(
      'STATE',
      'PdfReviewViewerPage.dispose PageController.dispose',
    );
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${_index + 1} / ${widget.pages.length}')),
      body: PageView.builder(
        key: const Key('pdfReviewViewer'),
        controller: _controller,
        itemCount: widget.pages.length,
        onPageChanged: (index) {
          if (mounted) setState(() => _index = index);
        },
        itemBuilder: (context, index) => ColoredBox(
          color: Colors.black,
          child: Center(child: _ReviewImage(page: widget.pages[index])),
        ),
      ),
    );
  }
}

class _PdfExportOverlay extends StatelessWidget {
  const _PdfExportOverlay({required this.progress});

  final PdfExportProgress progress;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: const Key('pdfExportOverlay'),
      alignment: Alignment.center,
      children: [
        const ModalBarrier(dismissible: false, color: Colors.black45),
        Card(
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('PDF를 만들고 있습니다...'),
                const SizedBox(height: 16),
                const SizedBox(width: 220, child: LinearProgressIndicator()),
                const SizedBox(height: 16),
                Text('${progress.completed} / ${progress.total} 페이지'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PdfCompletionOverlay extends StatelessWidget {
  const _PdfCompletionOverlay({
    required this.result,
    required this.openingDocument,
    required this.onNewScan,
    required this.onOpenFile,
  });

  final PdfExportResult result;
  final bool openingDocument;
  final VoidCallback onNewScan;
  final VoidCallback onOpenFile;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: const Key('pdfCompletionOverlay'),
      alignment: Alignment.center,
      children: [
        const ModalBarrier(dismissible: false, color: Colors.black54),
        Card(
          margin: const EdgeInsets.all(24),
          elevation: 10,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle,
                  size: 52,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'PDF 저장 완료',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  result.displayName ?? '',
                  key: const Key('pdfCompletionDisplayName'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text('${result.pageCount ?? 0}페이지'),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('startNewScanButton'),
                        onPressed: openingDocument ? null : onNewScan,
                        child: const Text('새 스캔'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('openSavedPdfButton'),
                        onPressed: openingDocument ? null : onOpenFile,
                        icon: openingDocument
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.open_in_new),
                        label: const Text('파일 열기'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
