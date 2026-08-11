import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scana/features/scan_result/presentation/scan_result_viewer_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/camera/camera_session.dart';

/// Separate page-order workspace; the result viewer remains swipe-focused.
class PageManagementPage extends StatefulWidget {
  const PageManagementPage({
    super.key,
    required this.sessionManager,
    this.cameraStartup,
  });

  final ScanSessionManager sessionManager;
  final CameraStartup? cameraStartup;

  @override
  State<PageManagementPage> createState() => _PageManagementPageState();
}

class _PageManagementPageState extends State<PageManagementPage> {
  final Set<String> _selectedRawPaths = {};
  bool _isExitingEmptySession = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('스캔 문서 목록'),
        actions: [
          IconButton(
            tooltip: '전체 선택',
            onPressed: () {
              final pages =
                  widget.sessionManager.currentSession?.pages ?? const [];
              setState(() {
                if (_selectedRawPaths.length == pages.length) {
                  _selectedRawPaths.clear();
                } else {
                  _selectedRawPaths
                    ..clear()
                    ..addAll(pages.map((page) => page.rawImagePath));
                }
              });
            },
            icon: const Icon(Icons.select_all),
          ),
        ],
      ),
      body: AnimatedBuilder(
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
            return const SizedBox.shrink();
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: pages.length,
            onReorderItem: (oldIndex, newIndex) =>
                widget.sessionManager.reorderPages(oldIndex, newIndex),
            itemBuilder: (context, index) => _ManagedPageTile(
              key: ValueKey(pages[index].rawImagePath),
              page: pages[index],
              selected: _selectedRawPaths.contains(pages[index].rawImagePath),
              onSelected: (selected) => setState(() {
                if (selected) {
                  _selectedRawPaths.add(pages[index].rawImagePath);
                } else {
                  _selectedRawPaths.remove(pages[index].rawImagePath);
                }
              }),
              onOpen: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (context) => ScanResultViewerPage(
                    sessionManager: widget.sessionManager,
                    cameraStartup: widget.cameraStartup,
                    initialPageIndex: index,
                  ),
                ),
              ),
              onDelete: () => _deletePage(index),
            ),
          );
        },
      ),
    );
  }

  Future<void> _deletePage(int index) async {
    final pages = widget.sessionManager.currentSession?.pages ?? const [];
    if (index < 0 || index >= pages.length) return;
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
    _selectedRawPaths.remove(pages[index].rawImagePath);
    await widget.sessionManager.deletePageAt(index);
    if (!mounted || widget.sessionManager.pageCount != 0) return;
    if (!_isExitingEmptySession) {
      _isExitingEmptySession = true;
      Navigator.of(context).pop(true);
    }
  }
}

class _ManagedPageTile extends StatelessWidget {
  const _ManagedPageTile({
    super.key,
    required this.page,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
    required this.onDelete,
  });

  final ScanPage page;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final imagePath = page.correctedImagePath ?? page.rawImagePath;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 52,
          height: 72,
          child: Transform.rotate(
            key: ValueKey('managed-thumbnail-rotation-${page.pageNo}'),
            angle: page.rotation * math.pi / 180,
            child: Image.file(File(imagePath), fit: BoxFit.cover),
          ),
        ),
      ),
      title: Text('페이지 ${page.pageNo}'),
      subtitle: Text(page.correctedImagePath == null ? '원본 fallback' : '스캔본'),
      onTap: onOpen,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: selected,
            onChanged: (value) => onSelected(value ?? false),
          ),
          IconButton(
            tooltip: '페이지 삭제',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
          const Icon(Icons.drag_handle),
        ],
      ),
    );
  }
}
