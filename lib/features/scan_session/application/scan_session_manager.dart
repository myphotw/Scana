import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

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
    required ScanSessionStorage storage,
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

  final ScanSessionStorage _storage;
  final SessionIdGenerator _sessionIdGenerator;
  final Clock _clock;

  ScanSession? _currentSession;
  bool _isClosed = false;

  ScanSession? get currentSession => _currentSession;
  int get pageCount => _currentSession?.pages.length ?? 0;

  Future<List<ScanSession>> findRecoverableSessions() {
    _ensureOpen();
    return _storage.findRecoverableSessions();
  }

  void restoreSession(ScanSession session) {
    _ensureOpen();
    if (_currentSession != null) {
      throw StateError('A scan session is already active.');
    }
    _currentSession = session;
    notifyListeners();
  }

  Future<void> deleteRecoveredSession(ScanSession session) async {
    _ensureOpen();
    if (_currentSession?.id == session.id) {
      await cancelSession();
      return;
    }
    await _storage.deleteSession(session.id);
  }

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
    await _storage.saveSession(session);
    notifyListeners();
    return page;
  }

  Future<void> deletePageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    final page = session.pages[index];
    await _storage.deletePageFile(page.rawImagePath);
    session.removePageAt(index);
    await _storage.saveSession(session);
    notifyListeners();
  }

  Future<void> reorderPages(int oldIndex, int newIndex) async {
    _ensureOpen();
    final session = _requireSession();
    session.reorderPages(oldIndex, newIndex);
    await _storage.saveSession(session);
    notifyListeners();
  }

  Future<void> rotatePageAt(int index) async {
    _ensureOpen();
    final session = _requireSession();
    session.rotatePageAt(index);
    await _storage.saveSession(session);
    notifyListeners();
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
    await _storage.saveSession(session);
    _currentSession = session;
    return session;
  }

  ScanSession _requireSession() {
    final session = _currentSession;
    if (session == null) {
      throw StateError('No active scan session.');
    }
    return session;
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('The scan session manager is closed.');
    }
  }

  static String _newUuid() => const Uuid().v4();
}
