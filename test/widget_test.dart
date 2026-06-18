import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/main.dart';

void main() {
  testWidgets('Bible reader builds and shows the default reference',
      (WidgetTester tester) async {
    await tester.pumpWidget(const BooxBibleApp());

    // First frame: the chapter is still loading (no network in tests), but the
    // app bar should already show the default book/chapter and a spinner.
    expect(find.text('John 1'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
