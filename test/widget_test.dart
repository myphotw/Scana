import 'package:flutter_test/flutter_test.dart';

import 'package:scana/app.dart';

void main() {
  testWidgets('creates the Scana camera entry screen', (tester) async {
    await tester.pumpWidget(const ScanaApp());

    expect(find.byType(ScanaApp), findsOneWidget);
    expect(find.text('카메라를 준비하는 중입니다.'), findsOneWidget);
  });
}
