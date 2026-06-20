import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/reference.dart';

void main() {
  test('parses full names with chapter and verse', () {
    expect(parseReference('John 3:16'), const BibleRef('John', 3, 16));
    expect(parseReference('John 3'), const BibleRef('John', 3));
    expect(parseReference('John'), const BibleRef('John', 1));
    expect(parseReference('Revelation 22:21'),
        const BibleRef('Revelation', 22, 21));
  });

  test('parses numbered books and abbreviations', () {
    expect(parseReference('1 Corinthians 13'),
        const BibleRef('1 Corinthians', 13));
    expect(parseReference('1cor 13:4'), const BibleRef('1 Corinthians', 13, 4));
    expect(parseReference('Ps 23'), const BibleRef('Psalms', 23));
    expect(parseReference('1 jn 4:8'), const BibleRef('1 John', 4, 8));
    expect(parseReference('song 2'), const BibleRef('Song of Solomon', 2));
  });

  test('accepts dot separator and surrounding whitespace', () {
    expect(parseReference('  gen 1.1 '), const BibleRef('Genesis', 1, 1));
  });

  test('rejects non-references and out-of-range chapters', () {
    expect(parseReference('hello world'), isNull);
    expect(parseReference('John 999'), isNull); // John has 21 chapters
    expect(parseReference(''), isNull);
  });

  test('BibleRef.toString renders chapter / single verse / verse range', () {
    expect(const BibleRef('Genesis', 1).toString(), 'Genesis 1');
    expect(const BibleRef('John', 3, 16).toString(), 'John 3:16');
    expect(const BibleRef('Hebrews', 11, 1, 3).toString(), 'Hebrews 11:1-3');
    // endVerse equal to verse collapses to the single-verse form.
    expect(const BibleRef('John', 3, 16, 16).toString(), 'John 3:16');
  });

  test('BibleRef equality and hashCode include endVerse', () {
    const a = BibleRef('Hebrews', 11, 1, 3);
    const b = BibleRef('Hebrews', 11, 1, 3);
    const c = BibleRef('Hebrews', 11, 1, 4);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });
}
