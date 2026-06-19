import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/main.dart';

void main() {
  testWidgets('Fresh launch shows the "Print your Bible" setup wizard',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BooxBibleApp());

    // With no printed Bible yet (empty library in tests), the app opens the
    // one-time setup wizard rather than the reader.
    expect(find.text('Print your Bible'), findsOneWidget);
    expect(find.text('Choose a translation'), findsOneWidget);
  });
}
