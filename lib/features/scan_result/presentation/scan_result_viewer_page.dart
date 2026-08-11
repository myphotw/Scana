import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scana/features/camera/presentation/camera_preview_page.dart';
import 'package:scana/features/page_editor/presentation/page_editor_page.dart';
import 'package:scana/features/scan_result/presentation/page_management_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/camera/camera_session.dart';

/// Default scan-result experience. Raw images are only shown in the editor.
class ScanResultViewerPage extends StatefulWidget {
  const ScanResultViewerPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
    this.initialPageIndex = 0,
  });

  final ScanSessionManager sessionManager;
  final CameraStartup? cameraStartup;
  final int initialPageIndex;

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
    final count = widget.sessionManager.pageCount;
    _pageIndex = count == 0 ? 0 : widget.initialPageIndex.clamp(0, count - 1);
    _pageController = PageController(initialPage: _pageIndex);
  }

  @override
  void dispose() {
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
            if (mounted && !_isExitingEmptySession) {
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
                key: const ValueKey('viewer-rotate-button'),
                tooltip: '오른쪽으로 회전',
                onPressed: () =>
                    widget.sessionManager.rotatePageAt(currentIndex),
                icon: const Icon(Icons.rotate_right),
              ),
              IconButton(
                tooltip: '페이지 관리',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => PageManagementPage(
                      sessionManager: widget.sessionManager,
                      cameraStartup: widget.cameraStartup,
                    ),
                  ),
                ),
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
                    child: OutlinedButton.icon(
                      onPressed: () => _retake(currentIndex),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('재촬영'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _edit(currentIndex),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('편집'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _delete(currentIndex),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('삭제'),
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

  Future<void> _retake(int index) async {
    final replaced = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => CameraPreviewPage(
          sessionManager: widget.sessionManager,
          cameraStartup: widget.cameraStartup,
          replacementPageIndex: index,
        ),
      ),
    );
    if (mounted && replaced == true) {
      setState(() => _pageIndex = index);
      _pageController.jumpToPage(index);
    }
  }

  Future<void> _edit(int index) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PageEditorPage(
          sessionManager: widget.sessionManager,
          initialPageIndex: index,
          showPageList: false,
        ),
      ),
    );
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

class _ScanResultImage extends StatelessWidget {
  const _ScanResultImage({required this.page});

  final ScanPage page;

  @override
  Widget build(BuildContext context) {
    final imagePath = page.correctedImagePath ?? page.rawImagePath;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Transform.rotate(
          key: ValueKey('viewer-page-rotation-${page.pageNo}'),
          angle: page.rotation * math.pi / 180,
          child: Image.file(
            File(imagePath),
            fit: BoxFit.contain,
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
