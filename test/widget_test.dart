import 'package:flutter_test/flutter_test.dart';

import 'package:scana/app.dart';

void main() {
  testWidgets('creates the Scana app shell', (tester) async {
    await tester.pumpWidget(const ScanaApp());

    expect(find.byType(ScanaApp), findsOneWidget);
  });
}
