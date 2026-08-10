import 'package:flutter_test/flutter_test.dart';

import 'package:scana/app.dart';
import 'package:scana/features/scan_session/application/scan_session_manager.dart';
import 'package:scana/models/scan_page.dart';
import 'package:scana/models/scan_session.dart';
import 'package:scana/services/storage/scan_session_storage.dart';

void main() {
  testWidgets('creates the Scana camera entry screen', (tester) async {
    await tester.pumpWidget(const ScanaApp());

    expect(find.byType(ScanaApp), findsOneWidget);
    expect(find.text('카메라를 준비하는 중입니다.'), findsOneWidget);
  });

  testWidgets('shows and resumes a recovered session', (tester) async {
    final session = ScanSession(
      id: 'recovered-session',
      createdTime: DateTime.utc(2026, 8, 10, 1, 2),
    );
    session.addPage(
      ScanPage(
        pageNo: 1,
        rawImagePath: '/scan_sessions/raw_001.jpg',
        createdTime: DateTime.utc(2026, 8, 10, 1, 2),
      ),
    );
    final manager = ScanSessionManager(storage: _TestSessionStorage());

    await tester.pumpWidget(
      ScanaApp(sessionManager: manager, recoverySession: session),
    );
    await tester.pumpAndSettle();

    expect(find.text('이전 스캔 작업이 있습니다.'), findsOneWidget);
    expect(find.textContaining('페이지 수: 1'), findsOneWidget);
    expect(find.text('이어하기'), findsOneWidget);

    await tester.tap(find.text('이어하기'));
    await tester.pumpAndSettle();

    expect(manager.currentSession?.id, 'recovered-session');
  });
}

class _TestSessionStorage implements ScanSessionStorage {
  @override
  Future<void> createSession(String sessionId) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> deletePageFile(String rawImagePath) async {}

  @override
  Future<List<ScanSession>> findRecoverableSessions() async => [];

  @override
  Future<void> saveSession(ScanSession session) async {}

  @override
  Future<String> storeRawPage({
    required String sessionId,
    required int pageNo,
    required String capturedImagePath,
  }) {
    throw UnimplementedError();
  }
}
