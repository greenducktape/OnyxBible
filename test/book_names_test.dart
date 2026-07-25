import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/books.dart';
import 'package:boox_bible/reference.dart';
import 'package:boox_bible/scripture.dart';

void main() {
  test('every language names all 66 books', () {
    for (final entry in kBookNamesByLanguage.entries) {
      final table = entry.value;
      expect(table.length, kBibleBooks.length,
          reason: '${entry.key} has ${table.length} names');
      for (final b in kBibleBooks) {
        expect(table.containsKey(b.name), isTrue,
            reason: '${entry.key} is missing ${b.name}');
      }
      // A name repeated across two books would make the contents list
      // ambiguous and break reference lookup.
      expect(table.values.toSet().length, table.length,
          reason: '${entry.key} has duplicate names');
    }
  });

  test('bookLabel translates, and falls back to the canonical name', () {
    expect(bookLabel('Genesis', 'es'), 'Génesis');
    expect(bookLabel('Genesis', 'de'), '1. Mose');
    expect(bookLabel('Genesis', 'en'), 'Genesis');
    expect(bookLabel('Genesis', 'fr'), 'Genesis'); // no table yet
    expect(bookLabel('Song of Solomon', 'es'), 'Cantares');
    expect(bookLabel('Revelation', 'de'), 'Offenbarung');
  });

  test('bundled translations carry a language code', () {
    expect(translationById('kjv').languageCode, 'en');
    expect(translationById('rv1909').languageCode, 'es');
    expect(translationById('luther1912').languageCode, 'de');
  });

  test('a private manifest infers its language code from the label', () {
    expect(TranslationInfo.codeForLanguage('Español'), 'es');
    expect(TranslationInfo.codeForLanguage('Spanish'), 'es');
    expect(TranslationInfo.codeForLanguage('Deutsch'), 'de');
    expect(TranslationInfo.codeForLanguage('German'), 'de');
    expect(TranslationInfo.codeForLanguage('English'), 'en');
    expect(TranslationInfo.codeForLanguage(''), 'en');
    expect(
      TranslationInfo.fromManifest({'id': 'x', 'language': 'Español'})
          .languageCode,
      'es',
    );
    // An explicit code in the manifest wins over the guess.
    expect(
      TranslationInfo.fromManifest(
          {'id': 'x', 'language': 'Español', 'languageCode': 'en'}).languageCode,
      'en',
    );
  });

  test('BibleRef.label renders in the Bible language, toString stays English',
      () {
    const ref = BibleRef('Genesis', 1, 1);
    expect(ref.label('es'), 'Génesis 1:1');
    expect(ref.label('de'), '1. Mose 1:1');
    expect(ref.label('en'), 'Genesis 1:1');
    expect(ref.toString(), 'Genesis 1:1');
    expect(const BibleRef('Psalms', 23).label('es'), 'Salmos 23');
    expect(const BibleRef('Hebrews', 11, 1, 3).label('de'), 'Hebräer 11:1-3');
  });

  test('localised names and abbreviations parse back to canonical books', () {
    expect(parseReference('Génesis 1:1'), const BibleRef('Genesis', 1, 1));
    expect(parseReference('Genesis 1:1'), const BibleRef('Genesis', 1, 1));
    // Accents are optional — nobody should have to type "é" to search.
    expect(parseReference('Exodo 3'), const BibleRef('Exodus', 3));
    expect(parseReference('Salmos 23'), const BibleRef('Psalms', 23));
    expect(parseReference('Sal 23'), const BibleRef('Psalms', 23));
    expect(parseReference('Juan 3:16'), const BibleRef('John', 3, 16));
    expect(parseReference('Apocalipsis 22'), const BibleRef('Revelation', 22));
    expect(parseReference('1. Mose 1'), const BibleRef('Genesis', 1));
    expect(parseReference('1 Mose 1'), const BibleRef('Genesis', 1));
    expect(parseReference('Johannes 3,16'), const BibleRef('John', 3, 16));
    expect(parseReference('Psalmen 23'), const BibleRef('Psalms', 23));
    expect(parseReference('Offb 22'), const BibleRef('Revelation', 22));
    expect(parseReference('Sprüche 3'), const BibleRef('Proverbs', 3));
  });

  test('the contents list has its own words per language', () {
    expect(canonLabels('es').oldTestament, 'Antiguo Testamento');
    expect(canonLabels('de').newTestament, 'Neues Testament');
    expect(canonLabels('en').contents, 'Contents');
    expect(canonLabels('fr').contents, 'Contents'); // fallback
  });
}
