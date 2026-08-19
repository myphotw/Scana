import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/page_editor/presentation/page_editor_page.dart';
import 'package:scana/features/page_editor/presentation/quick_corner_edit_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/camera/camera_session.dart';
import 'package:scana/services/diagnostics/debug_diagnostics.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

/// Default scan-result experience. Raw images are only shown in the editor.
class ScanResultViewerPage extends StatefulWidget {
  const ScanResultViewerPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.initialPageIndex = 0,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final CameraStartup? cameraStartup;
  final int initialPageIndex;
  final ScreenOrientationController orientationController;

  @override
  State<ScanResultViewerPage> createState() => _ScanResultViewerPageState();
}

class _ScanResultViewerPageState extends State<ScanResultViewerPage> {
  late PageController _pageController;
  late int _pageIndex;
  bool _isExitingEmptySession = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.orientationController.enterContentScreen());
    final count = widget.sessionManager.pageCount;
    _pageIndex = count == 0 ? 0 : widget.initialPageIndex.clamp(0, count - 1);
    _pageController = PageController(initialPage: _pageIndex);
    DebugDiagnostics.instance.logState(
      'ScanResultViewerPage.initState PageController.created',
      mounted: mounted,
    );
  }

  @override
  void dispose() {
    DebugDiagnostics.instance.logState(
      'ScanResultViewerPage.dispose PageController.dispose',
      mounted: mounted,
    );
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.sessionManager,
      builder: (context, child) {
        final pages = widget.sessionManager.currentSession?.pages ?? const [];
        if (pages.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                !_isExitingEmptySession &&
                ModalRoute.of(context)?.isCurrent == true) {
              _isExitingEmptySession = true;
              Navigator.of(context).pop(true);
            }
          });
          return const Scaffold(body: SizedBox.shrink());
        }
        final currentIndex = _pageIndex.clamp(0, pages.length - 1);
        return Scaffold(
          appBar: AppBar(
            title: Text('${currentIndex + 1} / ${pages.length}'),
            actions: [
              IconButton(
                key: const ValueKey('viewer-detailed-editor-button'),
                tooltip: '페이지 편집',
                onPressed: () => _openDetailedEditor(currentIndex),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: const ValueKey('viewer-rotate-button'),
                tooltip: '오른쪽으로 회전',
                onPressed: () =>
                    widget.sessionManager.rotatePageAt(currentIndex),
                icon: const Icon(Icons.rotate_right),
              ),
              IconButton(
                tooltip: '페이지 관리',
                onPressed: _openPageManagement,
                icon: const Icon(Icons.view_list_outlined),
              ),
            ],
          ),
          body: PageView.builder(
            key: const ValueKey('scan-result-page-view'),
            controller: _pageController,
            itemCount: pages.length,
            onPageChanged: (index) => setState(() => _pageIndex = index),
            itemBuilder: (context, index) =>
                _ScanResultImage(page: pages[index]),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _ViewerActionButton(
                      key: const ValueKey('viewer-retake-button'),
                      onPressed: () => _retake(currentIndex),
                      icon: Icons.camera_alt_outlined,
                      label: '재촬영',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ViewerActionButton(
                      key: const ValueKey('viewer-quick-corner-button'),
                      onPressed: () => _quickEdit(currentIndex),
                      icon: Icons.crop_free,
                      label: '모서리 수정',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ViewerActionButton(
                      key: const ValueKey('viewer-delete-button'),
                      filled: true,
                      onPressed: () => _delete(currentIndex),
                      icon: Icons.delete_outline,
                      label: '삭제',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPageManagement() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => PageManagementPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
          orientationController: widget.orientationController,
        ),
      ),
    );
    if (!mounted) return;
    if (widget.sessionManager.pageCount == 0 &&
        !_isExitingEmptySession &&
        ModalRoute.of(context)?.isCurrent == true) {
      _isExitingEmptySession = true;
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _retake(int index) async {
    final replaced = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => CameraPreviewPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
          replacementPageIndex: index,
          orientationController: widget.orientationController,
        ),
      ),
    );
    await widget.orientationController.enterContentScreen();
    if (!mounted) return;
    if (mounted && replaced == true) {
      setState(() => _pageIndex = index);
      _pageController.jumpToPage(index);
    }
  }

  Future<void> _openDetailedEditor(int index) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PageEditorPage(
          sessionManager: widget.sessionManager,
          initialPageIndex: index,
          showPageList: false,
          orientationController: widget.orientationController,
        ),
      ),
    );
  }

  Future<void> _quickEdit(int index) async {
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

  Future<void> _delete(int index) async {
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
    final countBeforeDelete = widget.sessionManager.pageCount;
    final target = countBeforeDelete <= 1
        ? 0
        : index.clamp(0, countBeforeDelete - 2);
    if (countBeforeDelete > 1) {
      setState(() => _pageIndex = target);
      if (_pageController.hasClients) {
        _pageController.jumpToPage(target);
      }
    }
    await widget.sessionManager.deletePageAt(index);
    final remaining = widget.sessionManager.pageCount;
    if (!mounted) return;
    if (remaining == 0) {
      if (!_isExitingEmptySession) {
        _isExitingEmptySession = true;
        Navigator.of(context).pop(true);
      }
      return;
    }
    final validIndex = target.clamp(0, remaining - 1);
    setState(() => _pageIndex = validIndex);
    if (_pageController.hasClients) {
      _pageController.jumpToPage(validIndex);
    }
  }
}

class _ViewerActionButton extends StatelessWidget {
  const _ViewerActionButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.filled = false,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
      iconSize: const WidgetStatePropertyAll(20),
      visualDensity: VisualDensity.standard,
    );
    return filled
        ? FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon),
            label: Text(label, textAlign: TextAlign.center),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon),
            label: Text(label, textAlign: TextAlign.center),
          );
  }
}

class _ScanResultImage extends StatelessWidget {
  const _ScanResultImage({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    final imagePath = page.displayImagePath;
    return ColoredBox(
      key: ValueKey('viewer-page-preview-area-${page.pageNo}'),
      color: Colors.black,
      child: SizedBox.expand(
        child: RotatedBox(
          key: ValueKey('viewer-page-rotation-${page.pageNo}'),
          quarterTurns: ScanResultPreviewLayout.quarterTurnsFor(page.rotation),
          child: Image.file(
            File(imagePath),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) => const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image_outlined, color: Colors.white),
                SizedBox(height: 8),
                Text(
                  '스캔 이미지를 불러올 수 없습니다.',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps 90-degree page rotation in Flutter's layout phase. This lets
/// [Image] calculate BoxFit.contain against swapped constraints on tablets.
class ScanResultPreviewLayout {
  const ScanResultPreviewLayout._();

  static int quarterTurnsFor(int rotation) => (rotation ~/ 90) % 4;

  static Size imageLayoutSize(Size availableBody, int rotation) {
    final quarterTurns = quarterTurnsFor(rotation);
    return quarterTurns.isOdd
        ? Size(availableBody.height, availableBody.width)
        : availableBody;
  }

  static Size containedRenderedSize({
    required Size imageSize,
    required Size availableBody,
    required int rotation,
  }) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      imageSize,
      imageLayoutSize(availableBody, rotation),
    ).destination;
    return quarterTurnsFor(rotation).isOdd
        ? Size(fitted.height, fitted.width)
        : fitted;
  }
}
