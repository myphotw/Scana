import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';

typedef AppPrivateDirectoryProvider = Future<Directory> Function();

/// Storage operations for raw files in an app-private scan session.
abstract interface class ScanSessionStorage {
  Future<void> createSession(String sessionId);

  Future<List<ScanSession>> findRecoverableSessions();

  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  });

  Future<void> deleteSession(String sessionId);
}

/// Stores sessions in the app support directory, outside OS-managed caches.
class AppPrivateSessionStorage implements ScanSessionStorage {
  factory AppPrivateSessionStorage({
    AppPrivateDirectoryProvider appPrivateDirectoryProvider =
        getApplicationSupportDirectory,
  }) {
    return AppPrivateSessionStorage._(appPrivateDirectoryProvider);
  }

  AppPrivateSessionStorage._(this._appPrivateDirectoryProvider);

  final AppPrivateDirectoryProvider _appPrivateDirectoryProvider;

  @override
  Future<void> createSession(String sessionId) async {
    final directory = await _sessionDirectory(sessionId);
    await directory.create(recursive: true);
  }

  @override
  Future<List<ScanSession>> findRecoverableSessions() async {
    final appPrivateDirectory = await _appPrivateDirectoryProvider();
    final sessionsDirectory = Directory(
      path.join(appPrivateDirectory.path, 'scan_sessions'),
    );
    if (!await sessionsDirectory.exists()) {
      return [];
    }

    final sessions = <ScanSession>[];
    await for (final entity in sessionsDirectory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }

      final pages = <ScanPage>[];
      await for (final fileEntity in entity.list(followLinks: false)) {
        if (fileEntity is! File) {
          continue;
        }

        final match = _rawPageName.firstMatch(path.basename(fileEntity.path));
        final pageNo = match == null ? null : int.tryParse(match.group(1)!);
        if (pageNo == null) {
          continue;
        }

        pages.add(
          ScanPage(
            pageNo: pageNo,
            rawImagePath: fileEntity.path,
            createdTime: (await fileEntity.stat()).modified,
          ),
        );
      }
      pages.sort((first, second) => first.pageNo.compareTo(second.pageNo));
      final createdTime = pages.isEmpty
          ? (await entity.stat()).modified
          : pages
                .map((page) => page.createdTime)
                .reduce(
                  (first, second) => first.isBefore(second) ? first : second,
                );
      final session = ScanSession(
        id: path.basename(entity.path),
        createdTime: createdTime,
      );
      for (final page in pages) {
        session.addPage(page);
      }
      sessions.add(session);
    }

    sessions.sort(
      (first, second) => second.createdTime.compareTo(first.createdTime),
    );
    return sessions;
  }

  @override
  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  }) async {
    final directory = await _sessionDirectory(sessionId);
    await directory.create(recursive: true);

    final fileName = 'raw_${pageNo.toString().padLeft(3, '0')}.jpg';
    final destinationPath = path.join(directory.path, fileName);
    final source = File(capturedImagePath);
    await source.copy(destinationPath);

    if (path.normalize(source.path) != path.normalize(destinationPath)) {
      await source.delete();
    }

    return destinationPath;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    final directory = await _sessionDirectory(sessionId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Directory> _sessionDirectory(String sessionId) async {
    final appPrivateDirectory = await _appPrivateDirectoryProvider();
    return Directory(
      path.join(appPrivateDirectory.path, 'scan_sessions', sessionId),
    );
  }

  static final RegExp _rawPageName = RegExp(r'^raw_(\d+)\.jpg$');
}
