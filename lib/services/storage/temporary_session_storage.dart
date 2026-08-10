import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

typedef TemporaryDirectoryProvider = Future<Directory> Function();

/// Storage operations for raw files that live only for a scan session.
abstract interface class TemporarySessionStorage {
  Future<void> createSession(String sessionId);

  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  });

  Future<void> deleteSession(String sessionId);
}

/// Stores scan sessions below the platform-provided temporary directory.
class AppTemporarySessionStorage implements TemporarySessionStorage {
  factory AppTemporarySessionStorage({
    TemporaryDirectoryProvider temporaryDirectoryProvider =
        getTemporaryDirectory,
  }) {
    return AppTemporarySessionStorage._(temporaryDirectoryProvider);
  }

  AppTemporarySessionStorage._(this._temporaryDirectoryProvider);

  final TemporaryDirectoryProvider _temporaryDirectoryProvider;

  @override
  Future<void> createSession(String sessionId) async {
    final directory = await _sessionDirectory(sessionId);
    await directory.create(recursive: true);
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
    final temporaryDirectory = await _temporaryDirectoryProvider();
    return Directory(path.join(temporaryDirectory.path, 'temp', sessionId));
  }
}
