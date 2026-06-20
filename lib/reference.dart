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
  String toString() {
    if (verse == null) return '$book $chapter';
    if (endVerse == null || endVerse == verse) return '$book $chapter:$verse';
    return '$book $chapter:$verse-$endVerse';
  }
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

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

final Map<String, String> _lookup = {
  for (final b in kBibleBooks) _norm(b.name): b.name,
  ..._abbrev,
};

/// Parses a reference string, or returns null if it isn't one. The chapter is
/// clamped to the book; an out-of-range chapter returns null.
BibleRef? parseReference(String input) {
  final m = RegExp(
          r'^\s*([0-9]?\s*[A-Za-z][A-Za-z ]*?)\s*([0-9]+)?\s*(?:[:.]\s*([0-9]+))?\s*$')
      .firstMatch(input);
  if (m == null) return null;

  final canonical = _lookup[_norm(m.group(1)!)];
  if (canonical == null) return null;

  final chapter = m.group(2) != null ? int.parse(m.group(2)!) : 1;
  if (chapter < 1 || chapter > chapterCount(canonical)) return null;

  final verse = m.group(3) != null ? int.parse(m.group(3)!) : null;
  return BibleRef(canonical, chapter, verse);
}
