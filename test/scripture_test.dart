import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/scripture.dart';

void main() {
  // rootBundle asset access needs the test binding initialized.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('verseId keeps the legacy "Book_Chapter_Verse" shape', () {
    expect(verseId('John', 3, 16), 'John_3_16');
    expect(verseId('1 Samuel', 1, 1), '1 Samuel_1_1');
  });

  test('parseVerseId inverts verseId, including multi-word books', () {
    expect(parseVerseId(verseId('John', 3, 16)), ('John', 3, 16));
    expect(parseVerseId(verseId('1 Samuel', 1, 1)), ('1 Samuel', 1, 1));
    expect(parseVerseId(verseId('Song of Solomon', 2, 4)),
        ('Song of Solomon', 2, 4));
    expect(parseVerseId('not-a-verse-id'), isNull);
    expect(parseVerseId('John_3'), isNull);
  });

  test('KJV is registered as a bundled translation', () {
    final kjv = translationById('kjv');
    expect(kjv.bundled, isTrue);
    expect(kjv.language, 'English');
  });

  group('bundled KJV assets', () {
    final src = BundledScriptureSource('kjv');

    test('loads John 1 from the bundle', () async {
      final verses = await src.chapter('John', 1);
      expect(verses.length, greaterThan(40));
      expect(verses.first.number, 1);
      expect(verses.first.id, 'John_1_1');
      expect(verses.first.text.toLowerCase(), contains('beginning'));
    });

    test('loads a multi-word book (1 Samuel 1) via slugged asset path',
        () async {
      final verses = await src.chapter('1 Samuel', 1);
      expect(verses, isNotEmpty);
      expect(verses.first.id, '1 Samuel_1_1');
    });

    test('throws ScriptureUnavailable for a non-existent chapter', () async {
      expect(src.chapter('John', 999), throwsA(isA<ScriptureUnavailable>()));
    });
  });
}
