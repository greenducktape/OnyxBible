import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/main.dart';

void main() {
  testWidgets('Bible reader smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const BooxBibleApp());

    // Verify that our dummy text is present.
    expect(find.textContaining('Am Anfang schuf Gott Himmel und Erde.'), findsOneWidget);
    expect(find.textContaining('(Genesis 1:1)'), findsOneWidget);
  });
}
