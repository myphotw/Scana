import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;

import 'package:scana/features/page_editor/presentation/mlkit_crop_editor_page.dart';
import 'package:scana/features/page_editor/presentation/mlkit_split_line_editor_page.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/mlkit_page_edit_metadata.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/services/orientation/screen_orientation_controller.dart';

class MlKitPageEditPage extends StatefulWidget {
  const MlKitPageEditPage({
    super.key,
    required this.sessionManager,
    required this.pageIndex,
    this.orientationController = const SystemScreenOrientationController(),
  });

  final ScanSessionManager sessionManager;
  final int pageIndex;
  final ScreenOrientationController orientationController;

  @override
  State<MlKitPageEditPage> createState() => _MlKitPageEditPageState();
}

class _MlKitPageEditPageState extends State<MlKitPageEditPage> {
  bool _busy = false;

  ScanPage? get _page {
    final pages = widget.sessionManager.currentSession?.pages ?? const [];
    return widget.pageIndex >= 0 && widget.pageIndex < pages.length
        ? pages[widget.pageIndex]
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page == null || !page.isMlKitPage) {
      return const Scaffold(body: Center(child: Text('편집할 페이지를 찾을 수 없습니다.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('페이지 편집')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: Colors.black,
                alignment: Alignment.center,
                child: RotatedBox(
                  quarterTurns: page.rotation ~/ 90,
                  child: Image.file(
                    File(page.displayImagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white,
                      size: 64,
                    ),
                  ),
                ),
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    key: const Key('editMlKitCropButton'),
                    onPressed: _busy ? null : () => _crop(page),
                    icon: const Icon(Icons.crop),
                    label: const Text('자르기'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('editMlKitRotateButton'),
                    onPressed: _busy ? null : _rotate,
                    icon: const Icon(Icons.rotate_right),
                    label: const Text('90° 회전'),
                  ),
                  if (!page.isMlKitSpreadChild)
                    FilledButton.tonalIcon(
                      key: const Key('convertMlKitToSpreadButton'),
                      onPressed: _busy ? null : () => _split(page),
                      icon: const Icon(Icons.vertical_split_outlined),
                      label: const Text('2면으로 분리'),
                    ),
                  if (page.isMlKitSpreadChild) ...[
                    FilledButton.tonalIcon(
                      key: const Key('adjustMlKitSplitButton'),
                      onPressed: _busy ? null : () => _adjustSplit(page),
                      icon: const Icon(Icons.view_week_outlined),
                      label: const Text('분할 위치 수정'),
                    ),
                    TextButton.icon(
                      key: const Key('restoreMlKitSingleButton'),
                      onPressed: _busy ? null : _restoreSingle,
                      icon: const Icon(Icons.article_outlined),
                      label: const Text('1면으로 복원'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _crop(ScanPage page) async {
    final crop = await Navigator.of(context).push<MlKitCropRect>(
      MaterialPageRoute<MlKitCropRect>(
        builder: (context) => MlKitCropEditorPage(
          imagePath: page.displayImagePath,
          imageWidth: page.documentSourceWidth ?? 1,
          imageHeight: page.documentSourceHeight ?? 1,
          rotation: page.rotation,
        ),
      ),
    );
    if (!mounted || crop == null) return;
    await _complete(
      () => widget.sessionManager.cropMlKitPageAt(widget.pageIndex, crop),
    );
  }

  Future<void> _rotate() => _complete(
    () => widget.sessionManager.rotateMlKitPageAt(widget.pageIndex),
  );

  Future<void> _split(ScanPage page) async {
    setState(() => _busy = true);
    try {
      final analysis = await widget.sessionManager.analyzeMlKitPageAt(
        widget.pageIndex,
      );
      final size = await _sourceSize(page.editableSourcePath);
      if (!mounted) return;
      final splitX = await Navigator.of(context).push<int>(
        MaterialPageRoute<int>(
          builder: (context) => MlKitSplitLineEditorPage(
            sourceImagePath: page.editableSourcePath,
            sourceWidth: size.$1,
            sourceHeight: size.$2,
            initialSplitX: analysis.splitX,
          ),
        ),
      );
      if (!mounted || splitX == null) return;
      final mutation = await widget.sessionManager.splitMlKitPageAt(
        widget.pageIndex,
        splitX: splitX,
        confidence: analysis.confidence,
        fallbackUsed: analysis.fallbackUsed,
      );
      if (mounted) Navigator.of(context).pop(mutation);
    } on Object {
      if (mounted) _showError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adjustSplit(ScanPage page) async {
    final size = await _sourceSize(page.editableSourcePath);
    if (!mounted) return;
    final splitX = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (context) => MlKitSplitLineEditorPage(
          sourceImagePath: page.editableSourcePath,
          sourceWidth: size.$1,
          sourceHeight: size.$2,
          initialSplitX: page.splitX ?? size.$1 ~/ 2,
        ),
      ),
    );
    if (!mounted || splitX == null) return;
    await _complete(
      () => widget.sessionManager.adjustMlKitSpreadAt(widget.pageIndex, splitX),
    );
  }

  Future<void> _restoreSingle() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('1면으로 복원'),
        content: const Text('좌우 페이지를 원본 ML Kit 이미지 한 장으로 복원합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('복원'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _complete(
      () => widget.sessionManager.restoreMlKitSpreadAt(widget.pageIndex),
    );
  }

  Future<void> _complete(Future<MlKitPageMutation> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final mutation = await operation();
      if (mounted) Navigator.of(context).pop(mutation);
    } on Object {
      if (mounted) _showError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(int, int)> _sourceSize(String filePath) async {
    final decoded = image.decodeImage(await File(filePath).readAsBytes());
    if (decoded == null) throw const FormatException('Image decode failed.');
    return (decoded.width, decoded.height);
  }

  void _showError() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('페이지 편집을 적용할 수 없습니다.')));
  }
}
