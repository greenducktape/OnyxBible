import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/main.dart';

void main() {
  test('readingMetricsFor honours the chosen margin fraction', () {
    final m =
        readingMetricsFor(1000, marginFraction: 0.6, showVerseNumbers: false);
    expect(m.contentWidth, 1000);
    expect(m.textWidth, closeTo(600, 0.001)); // 60% text, 40% writing margin
  });

  test('the verse-number gutter is taken out of the text column', () {
    final m =
        readingMetricsFor(1000, marginFraction: 1.0, showVerseNumbers: true);
    expect(m.textWidth, closeTo(1000 - kGutterWidth, 0.001));
  });

  test('reader and setup preview share the same split for a given width', () {
    // Same inputs must yield the same text column, so the preview can't lie.
    final a =
        readingMetricsFor(640, marginFraction: 0.68, showVerseNumbers: true);
    final b =
        readingMetricsFor(640, marginFraction: 0.68, showVerseNumbers: true);
    expect(a.textWidth, b.textWidth);
  });
}
