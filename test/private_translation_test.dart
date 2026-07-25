import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/scripture.dart';

void main() {
  test('a manifest record becomes a private, offline translation', () {
    final t = TranslationInfo.fromManifest({
      'id': 'demo',
      'displayName': 'Demo Version',
      'language': 'Español',
      'attribution': 'Private / local use',
    });
    expect(t.id, 'demo');
    expect(t.private, isTrue);
    expect(t.bundled, isFalse);
    expect(t.offline, isTrue); // shows up in the setup wizard
  });

  test('registered private translations join the registry and resolve by id',
      () {
    registerPrivateTranslations([
      const TranslationInfo(
        id: 'demo',
        displayName: 'Demo Version',
        language: 'Español',
        bundled: false,
        private: true,
        attribution: 'Private / local use',
      ),
    ]);
    expect(offlineTranslations.any((t) => t.id == 'demo'), isTrue);
    expect(translationById('demo').displayName, 'Demo Version');
    // Bundled ones are still present.
    expect(translationById('kjv').bundled, isTrue);
    registerPrivateTranslations(const []); // reset for other tests
    expect(offlineTranslations.any((t) => t.id == 'demo'), isFalse);
  });

  test('unknown id falls back to a bundled translation (public build safety)',
      () {
    // A Bible printed with a private version that is absent from this build
    // resolves to a shipped translation instead of crashing.
    expect(translationById('not-here').bundled, isTrue);
  });

  test('parsePrivateChapter reads verses from the books map', () {
    final books = <String, dynamic>{
      'Genesis': {
        '1': [
          {'v': 1, 't': '  alpha  '},
          {'v': 2, 't': 'beta'},
        ],
      },
    };
    final verses = parsePrivateChapter(books, 'Genesis', 1);
    expect(verses.length, 2);
    expect(verses.first.number, 1);
    expect(verses.first.text, 'alpha'); // trimmed
    expect(verses.first.id, 'Genesis_1_1'); // language-independent verse id
  });

  test('parsePrivateChapter throws for a missing book or chapter', () {
    expect(() => parsePrivateChapter(const {}, 'Genesis', 1),
        throwsA(isA<ScriptureUnavailable>()));
  });
}
