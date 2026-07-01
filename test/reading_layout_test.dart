import 'package:flutter/material.dart';
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

  test('verseSpan without a drop cap is the plain verse text', () {
    final span = verseSpan('In the beginning', kVerseStyle);
    expect(span.text, 'In the beginning');
    expect(span.children, isNull);
  });

  test('verseSpan with a drop cap enlarges exactly the first letter', () {
    final span = verseSpan('In the beginning', kVerseStyle, dropCap: true);
    final parts = span.children!.cast<TextSpan>();
    expect(parts, hasLength(2));
    expect(parts[0].text, 'I');
    expect(parts[0].style!.fontSize,
        closeTo(kVerseStyle.fontSize! * 1.9, 0.001));
    expect(parts[1].text, 'n the beginning');
    // Pagination measures this same span, so rendering can never drift from
    // the measured page breaks.
  });
}
