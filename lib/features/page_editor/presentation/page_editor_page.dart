import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:scana/features/scan_session/application/scan_session_manager.dart';
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

          return ReorderableListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemCount: pages.length,
            onReorderItem: (oldIndex, newIndex) async {
              await widget.sessionManager.reorderPages(oldIndex, newIndex);
            },
            itemBuilder: (context, index) {
              final page = pages[index];
              return _PageEditorTile(
                key: ValueKey(page.rawImagePath),
                page: page,
                selected: _selectedPageIndex == index,
                onSelect: () => setState(() => _selectedPageIndex = index),
                onDelete: () => widget.sessionManager.deletePageAt(index),
                onRotate: () => widget.sessionManager.rotatePageAt(index),
              );
            },
          );
        },
      ),
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
