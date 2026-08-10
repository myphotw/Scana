import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/storage/temporary_session_storage.dart';

typedef SessionIdGenerator = String Function();
typedef Clock = DateTime Function();

/// Cleanup contract shared by cancel and the future successful-export flow.
abstract interface class ScanSessionCleanup {
  Future<void> cancelSession();

  Future<void> deleteAfterSuccessfulExport();
}

/// Creates a session on the first capture and owns its ordered raw pages.
class ScanSessionManager extends ChangeNotifier implements ScanSessionCleanup {
  factory ScanSessionManager({
    required TemporarySessionStorage storage,
    SessionIdGenerator sessionIdGenerator = _newUuid,
    Clock clock = DateTime.now,
  }) {
    return ScanSessionManager._(
      storage: storage,
      sessionIdGenerator: sessionIdGenerator,
      clock: clock,
    );
  }

  ScanSessionManager._({
    required this._storage,
    required this._sessionIdGenerator,
    required this._clock,
  });

  final TemporarySessionStorage _storage;
  final SessionIdGenerator _sessionIdGenerator;
  final Clock _clock;

  ScanSession? _currentSession;
  bool _isClosed = false;

  ScanSession? get currentSession => _currentSession;
  int get pageCount => _currentSession?.pages.length ?? 0;

  Future<ScanPage> addRawCapture(String capturedImagePath) async {
    _ensureOpen();
    final session = await _ensureSession();
    final pageNo = session.pages.length + 1;
    final rawImagePath = await _storage.storeRawPage(
      sessionId: session.id,
      pageNo: pageNo,
      capturedImagePath: capturedImagePath,
    );
    final page = ScanPage(
      pageNo: pageNo,
      rawImagePath: rawImagePath,
      createdTime: _clock(),
    );
    session.addPage(page);
    notifyListeners();
    return page;
  }

  @override
  Future<void> cancelSession() async {
    final session = _currentSession;
    if (session == null) {
      return;
    }

    await _storage.deleteSession(session.id);
    _currentSession = null;
    if (!_isClosed) {
      notifyListeners();
    }
  }

  @override
  Future<void> deleteAfterSuccessfulExport() => cancelSession();

  /// Releases in-memory listeners without deleting the persisted session.
  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    dispose();
  }

  Future<ScanSession> _ensureSession() async {
    final activeSession = _currentSession;
    if (activeSession != null) {
      return activeSession;
    }

    final session = ScanSession(
      id: _sessionIdGenerator(),
      createdTime: _clock(),
    );
    await _storage.createSession(session.id);
    _currentSession = session;
    return session;
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('The scan session manager is closed.');
    }
  }

  static String _newUuid() => const Uuid().v4();
}
