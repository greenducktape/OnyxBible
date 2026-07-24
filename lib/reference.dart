// Parses free-text scripture references like "John 3:16", "1 Cor 13",
// "ps 23", or "Revelation" into a concrete book/chapter/verse.

import 'books.dart';

class BibleRef {
  final String book; // canonical name from books.dart
  final int chapter;
  final int? verse; // start verse of a passage (null = whole chapter)
  final int? endVerse; // inclusive end verse of a range (null = single verse)

  const BibleRef(this.book, this.chapter, [this.verse, this.endVerse]);

  @override
  bool operator ==(Object other) =>
      other is BibleRef &&
      other.book == book &&
      other.chapter == chapter &&
      other.verse == verse &&
      other.endVerse == endVerse;

  @override
  int get hashCode => Object.hash(book, chapter, verse, endVerse);

  @override
  String toString() => label('en');

  /// The reference as a reader of a [lang] Bible sees it — "Juan 3:16",
  /// "Johannes 3:16" — see [bookLabel]. [toString] stays English because that
  /// is the canonical form used in keys and logs. (A German reader may *type*
  /// "3,16"; [parseReference] accepts that, but the colon is what's shown.)
  String label(String lang) {
    final name = bookLabel(book, lang);
    if (verse == null) return '$name $chapter';
    if (endVerse == null || endVerse == verse) return '$name $chapter:$verse';
    return '$name $chapter:$verse-$endVerse';
  }
}

// Accents are folded before matching, so "Génesis", "Genesis" and "genesis"
// all reach the same book — nobody should have to produce an "é" to search.
const Map<String, String> _foldAccents = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
  'ñ': 'n', 'ç': 'c', 'ß': 'ss',
};

String _norm(String s) {
  final out = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    out.write(_foldAccents[ch] ?? ch);
  }
  return out.toString().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

// Common abbreviations -> canonical book name. Full names are added
// automatically below, so this only needs the short forms.
const Map<String, String> _abbrev = {
  'gen': 'Genesis', 'ge': 'Genesis', 'gn': 'Genesis',
  'ex': 'Exodus', 'exo': 'Exodus', 'exod': 'Exodus',
  'lev': 'Leviticus', 'lv': 'Leviticus',
  'num': 'Numbers', 'nm': 'Numbers', 'nu': 'Numbers',
  'deut': 'Deuteronomy', 'dt': 'Deuteronomy',
  'josh': 'Joshua', 'jos': 'Joshua',
  'judg': 'Judges', 'jdg': 'Judges',
  'ru': 'Ruth', 'rth': 'Ruth',
  '1sam': '1 Samuel', '1sa': '1 Samuel', '2sam': '2 Samuel', '2sa': '2 Samuel',
  '1kgs': '1 Kings', '1ki': '1 Kings', '2kgs': '2 Kings', '2ki': '2 Kings',
  '1chr': '1 Chronicles', '1ch': '1 Chronicles',
  '2chr': '2 Chronicles', '2ch': '2 Chronicles',
  'ezr': 'Ezra', 'neh': 'Nehemiah', 'est': 'Esther',
  'ps': 'Psalms', 'psa': 'Psalms', 'psalm': 'Psalms', 'pss': 'Psalms',
  'prov': 'Proverbs', 'prv': 'Proverbs', 'pr': 'Proverbs',
  'eccl': 'Ecclesiastes', 'ecc': 'Ecclesiastes', 'qoh': 'Ecclesiastes',
  'song': 'Song of Solomon', 'sos': 'Song of Solomon', 'sng': 'Song of Solomon',
  'canticles': 'Song of Solomon',
  'isa': 'Isaiah', 'is': 'Isaiah',
  'jer': 'Jeremiah', 'je': 'Jeremiah',
  'lam': 'Lamentations',
  'ezek': 'Ezekiel', 'eze': 'Ezekiel', 'ezk': 'Ezekiel',
  'dan': 'Daniel', 'dn': 'Daniel',
  'hos': 'Hosea', 'obad': 'Obadiah', 'oba': 'Obadiah',
  'jon': 'Jonah', 'mic': 'Micah', 'nah': 'Nahum', 'hab': 'Habakkuk',
  'zeph': 'Zephaniah', 'zep': 'Zephaniah', 'hag': 'Haggai',
  'zech': 'Zechariah', 'zec': 'Zechariah', 'mal': 'Malachi',
  'matt': 'Matthew', 'mt': 'Matthew',
  'mk': 'Mark', 'mar': 'Mark',
  'lk': 'Luke', 'luk': 'Luke',
  'jn': 'John', 'joh': 'John',
  'act': 'Acts', 'rom': 'Romans', 'ro': 'Romans',
  '1cor': '1 Corinthians', '1co': '1 Corinthians',
  '2cor': '2 Corinthians', '2co': '2 Corinthians',
  'gal': 'Galatians', 'ga': 'Galatians',
  'eph': 'Ephesians',
  'phil': 'Philippians', 'php': 'Philippians',
  'col': 'Colossians',
  '1thess': '1 Thessalonians', '1th': '1 Thessalonians',
  '2thess': '2 Thessalonians', '2th': '2 Thessalonians',
  '1tim': '1 Timothy', '1ti': '1 Timothy',
  '2tim': '2 Timothy', '2ti': '2 Timothy',
  'tit': 'Titus', 'philem': 'Philemon', 'phm': 'Philemon', 'phlm': 'Philemon',
  'heb': 'Hebrews', 'jas': 'James', 'jms': 'James',
  '1pet': '1 Peter', '1pe': '1 Peter', '2pet': '2 Peter', '2pe': '2 Peter',
  '1jn': '1 John', '2jn': '2 John', '3jn': '3 John',
  'jud': 'Jude',
  'rev': 'Revelation', 'rv': 'Revelation', 're': 'Revelation', 'apoc': 'Revelation',
};

// Short forms in the other languages the app reads scripture in, so someone
// reading the Reina-Valera can type "Sal 23" and someone reading the Luther
// "Ps 23" or "1. Mose 1". Full localised names come from books.dart below.
const Map<String, String> _abbrevEs = {
  'gn': 'Genesis', 'ex': 'Exodus', 'lv': 'Leviticus', 'nm': 'Numbers',
  'dt': 'Deuteronomy', 'jos': 'Joshua', 'jue': 'Judges', 'rt': 'Ruth',
  'sal': 'Psalms', 'pr': 'Proverbs', 'ec': 'Ecclesiastes',
  'cnt': 'Song of Solomon', 'cant': 'Song of Solomon',
  'is': 'Isaiah', 'jer': 'Jeremiah', 'lm': 'Lamentations', 'ez': 'Ezekiel',
  'dn': 'Daniel', 'os': 'Hosea', 'jl': 'Joel', 'am': 'Amos',
  'abd': 'Obadiah', 'jon': 'Jonah', 'miq': 'Micah', 'nah': 'Nahum',
  'hab': 'Habakkuk', 'sof': 'Zephaniah', 'hag': 'Haggai', 'zac': 'Zechariah',
  'mal': 'Malachi', 'mt': 'Matthew', 'mr': 'Mark', 'lc': 'Luke',
  'jn': 'John', 'hch': 'Acts', 'ro': 'Romans',
  '1co': '1 Corinthians', '2co': '2 Corinthians',
  'ga': 'Galatians', 'ef': 'Ephesians', 'flp': 'Philippians',
  'col': 'Colossians', '1ts': '1 Thessalonians', '2ts': '2 Thessalonians',
  '1ti': '1 Timothy', '2ti': '2 Timothy', 'tit': 'Titus', 'flm': 'Philemon',
  'heb': 'Hebrews', 'stg': 'James', '1p': '1 Peter', '2p': '2 Peter',
  'jud': 'Jude', 'ap': 'Revelation', 'apoc': 'Revelation',
};

const Map<String, String> _abbrevDe = {
  '1mo': 'Genesis', '2mo': 'Exodus', '3mo': 'Leviticus', '4mo': 'Numbers',
  '5mo': 'Deuteronomy', 'ri': 'Judges', 'rut': 'Ruth',
  '1kon': '1 Kings', '2kon': '2 Kings', 'esr': 'Ezra',
  'hi': 'Job', 'spr': 'Proverbs', 'pred': 'Ecclesiastes',
  'hld': 'Song of Solomon', 'hoh': 'Song of Solomon',
  'jes': 'Isaiah', 'klgl': 'Lamentations', 'hes': 'Ezekiel',
  'obd': 'Obadiah', 'jona': 'Jonah', 'zef': 'Zephaniah', 'sach': 'Zechariah',
  'mk': 'Mark', 'lk': 'Luke', 'apg': 'Acts',
  '1kor': '1 Corinthians', '2kor': '2 Corinthians',
  'kol': 'Colossians', 'hebr': 'Hebrews', 'jak': 'James',
  '1petr': '1 Peter', '2petr': '2 Peter',
  '1joh': '1 John', '2joh': '2 John', '3joh': '3 John',
  'offb': 'Revelation',
};

final Map<String, String> _lookup = {
  for (final b in kBibleBooks) _norm(b.name): b.name,
  // Every localised book name resolves back to its canonical English key.
  for (final table in kBookNamesByLanguage.values)
    for (final e in table.entries) _norm(e.value): e.key,
  ..._abbrev,
  ..._abbrevEs,
  ..._abbrevDe,
};

/// Parses a reference string, or returns null if it isn't one. The chapter is
/// clamped to the book; an out-of-range chapter returns null.
///
/// Accented letters and the German ordinal dot ("1. Mose") are accepted, as is
/// a comma before the verse, which is how German references are written.
BibleRef? parseReference(String input) {
  const letters = 'A-Za-zÁÉÍÓÚÜÑáéíóúüñÄÖÜäöüß';
  final m = RegExp('^\\s*([0-9]?\\s*\\.?\\s*[$letters][$letters .]*?)'
          '\\s*([0-9]+)?\\s*(?:[:.,]\\s*([0-9]+))?\\s*\$')
      .firstMatch(input);
  if (m == null) return null;

  final canonical = _lookup[_norm(m.group(1)!)];
  if (canonical == null) return null;

  final chapter = m.group(2) != null ? int.parse(m.group(2)!) : 1;
  if (chapter < 1 || chapter > chapterCount(canonical)) return null;

  final verse = m.group(3) != null ? int.parse(m.group(3)!) : null;
  return BibleRef(canonical, chapter, verse);
}
