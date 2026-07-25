import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/scripture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('finds "Jesus wept" at John 11:35', () async {
    final hits = await searchBundledTranslation('kjv', 'Jesus wept');
    expect(hits, isNotEmpty);
    final jw = hits.firstWhere(
        (h) => h.book == 'John' && h.chapter == 11 && h.verse == 35);
    expect(jw.text.toLowerCase(), contains('jesus wept'));
  });

  test('respects the result limit', () async {
    final hits = await searchBundledTranslation('kjv', 'the', limit: 10);
    expect(hits.length, 10);
  });

  test('empty query returns nothing', () async {
    expect(await searchBundledTranslation('kjv', ''), isEmpty);
  });
}
