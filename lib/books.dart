// Static data for the 66-book Protestant canon plus small navigation helpers.
//
// Kept free of Flutter imports so it can be reused and unit-tested cheaply.

class BibleBook {
  final String name;
  final int chapters;
  final bool isOldTestament;

  const BibleBook(this.name, this.chapters, {required this.isOldTestament});
}

const List<BibleBook> kBibleBooks = [
  // Old Testament
  BibleBook('Genesis', 50, isOldTestament: true),
  BibleBook('Exodus', 40, isOldTestament: true),
  BibleBook('Leviticus', 27, isOldTestament: true),
  BibleBook('Numbers', 36, isOldTestament: true),
  BibleBook('Deuteronomy', 34, isOldTestament: true),
  BibleBook('Joshua', 24, isOldTestament: true),
  BibleBook('Judges', 21, isOldTestament: true),
  BibleBook('Ruth', 4, isOldTestament: true),
  BibleBook('1 Samuel', 31, isOldTestament: true),
  BibleBook('2 Samuel', 24, isOldTestament: true),
  BibleBook('1 Kings', 22, isOldTestament: true),
  BibleBook('2 Kings', 25, isOldTestament: true),
  BibleBook('1 Chronicles', 29, isOldTestament: true),
  BibleBook('2 Chronicles', 36, isOldTestament: true),
  BibleBook('Ezra', 10, isOldTestament: true),
  BibleBook('Nehemiah', 13, isOldTestament: true),
  BibleBook('Esther', 10, isOldTestament: true),
  BibleBook('Job', 42, isOldTestament: true),
  BibleBook('Psalms', 150, isOldTestament: true),
  BibleBook('Proverbs', 31, isOldTestament: true),
  BibleBook('Ecclesiastes', 12, isOldTestament: true),
  BibleBook('Song of Solomon', 8, isOldTestament: true),
  BibleBook('Isaiah', 66, isOldTestament: true),
  BibleBook('Jeremiah', 52, isOldTestament: true),
  BibleBook('Lamentations', 5, isOldTestament: true),
  BibleBook('Ezekiel', 48, isOldTestament: true),
  BibleBook('Daniel', 12, isOldTestament: true),
  BibleBook('Hosea', 14, isOldTestament: true),
  BibleBook('Joel', 3, isOldTestament: true),
  BibleBook('Amos', 9, isOldTestament: true),
  BibleBook('Obadiah', 1, isOldTestament: true),
  BibleBook('Jonah', 4, isOldTestament: true),
  BibleBook('Micah', 7, isOldTestament: true),
  BibleBook('Nahum', 3, isOldTestament: true),
  BibleBook('Habakkuk', 3, isOldTestament: true),
  BibleBook('Zephaniah', 3, isOldTestament: true),
  BibleBook('Haggai', 2, isOldTestament: true),
  BibleBook('Zechariah', 14, isOldTestament: true),
  BibleBook('Malachi', 4, isOldTestament: true),
  // New Testament
  BibleBook('Matthew', 28, isOldTestament: false),
  BibleBook('Mark', 16, isOldTestament: false),
  BibleBook('Luke', 24, isOldTestament: false),
  BibleBook('John', 21, isOldTestament: false),
  BibleBook('Acts', 28, isOldTestament: false),
  BibleBook('Romans', 16, isOldTestament: false),
  BibleBook('1 Corinthians', 16, isOldTestament: false),
  BibleBook('2 Corinthians', 13, isOldTestament: false),
  BibleBook('Galatians', 6, isOldTestament: false),
  BibleBook('Ephesians', 6, isOldTestament: false),
  BibleBook('Philippians', 4, isOldTestament: false),
  BibleBook('Colossians', 4, isOldTestament: false),
  BibleBook('1 Thessalonians', 5, isOldTestament: false),
  BibleBook('2 Thessalonians', 3, isOldTestament: false),
  BibleBook('1 Timothy', 6, isOldTestament: false),
  BibleBook('2 Timothy', 4, isOldTestament: false),
  BibleBook('Titus', 3, isOldTestament: false),
  BibleBook('Philemon', 1, isOldTestament: false),
  BibleBook('Hebrews', 13, isOldTestament: false),
  BibleBook('James', 5, isOldTestament: false),
  BibleBook('1 Peter', 5, isOldTestament: false),
  BibleBook('2 Peter', 3, isOldTestament: false),
  BibleBook('1 John', 5, isOldTestament: false),
  BibleBook('2 John', 1, isOldTestament: false),
  BibleBook('3 John', 1, isOldTestament: false),
  BibleBook('Jude', 1, isOldTestament: false),
  BibleBook('Revelation', 22, isOldTestament: false),
];

// --- Book names in the reader's own language ------------------------------
//
// The English name above is the book's IDENTITY: notes, reading positions,
// plans and cross-references are all keyed by it, and that must never shift
// with the translation on screen. These tables only supply the LABEL, so a
// Spanish Bible reads "Génesis 1" and a German one "1. Mose 1" while the same
// note stays attached to the same chapter.

const Map<String, String> _kBookNamesEs = {
  'Genesis': 'Génesis',
  'Exodus': 'Éxodo',
  'Leviticus': 'Levítico',
  'Numbers': 'Números',
  'Deuteronomy': 'Deuteronomio',
  'Joshua': 'Josué',
  'Judges': 'Jueces',
  'Ruth': 'Rut',
  '1 Samuel': '1 Samuel',
  '2 Samuel': '2 Samuel',
  '1 Kings': '1 Reyes',
  '2 Kings': '2 Reyes',
  '1 Chronicles': '1 Crónicas',
  '2 Chronicles': '2 Crónicas',
  'Ezra': 'Esdras',
  'Nehemiah': 'Nehemías',
  'Esther': 'Ester',
  'Job': 'Job',
  'Psalms': 'Salmos',
  'Proverbs': 'Proverbios',
  'Ecclesiastes': 'Eclesiastés',
  'Song of Solomon': 'Cantares',
  'Isaiah': 'Isaías',
  'Jeremiah': 'Jeremías',
  'Lamentations': 'Lamentaciones',
  'Ezekiel': 'Ezequiel',
  'Daniel': 'Daniel',
  'Hosea': 'Oseas',
  'Joel': 'Joel',
  'Amos': 'Amós',
  'Obadiah': 'Abdías',
  'Jonah': 'Jonás',
  'Micah': 'Miqueas',
  'Nahum': 'Nahúm',
  'Habakkuk': 'Habacuc',
  'Zephaniah': 'Sofonías',
  'Haggai': 'Hageo',
  'Zechariah': 'Zacarías',
  'Malachi': 'Malaquías',
  'Matthew': 'Mateo',
  'Mark': 'Marcos',
  'Luke': 'Lucas',
  'John': 'Juan',
  'Acts': 'Hechos',
  'Romans': 'Romanos',
  '1 Corinthians': '1 Corintios',
  '2 Corinthians': '2 Corintios',
  'Galatians': 'Gálatas',
  'Ephesians': 'Efesios',
  'Philippians': 'Filipenses',
  'Colossians': 'Colosenses',
  '1 Thessalonians': '1 Tesalonicenses',
  '2 Thessalonians': '2 Tesalonicenses',
  '1 Timothy': '1 Timoteo',
  '2 Timothy': '2 Timoteo',
  'Titus': 'Tito',
  'Philemon': 'Filemón',
  'Hebrews': 'Hebreos',
  'James': 'Santiago',
  '1 Peter': '1 Pedro',
  '2 Peter': '2 Pedro',
  '1 John': '1 Juan',
  '2 John': '2 Juan',
  '3 John': '3 Juan',
  'Jude': 'Judas',
  'Revelation': 'Apocalipsis',
};

// Luther naming, to match the bundled Luther 1912 (so the Pentateuch is
// "1.–5. Mose" rather than the ecumenical Genesis/Exodus/…).
const Map<String, String> _kBookNamesDe = {
  'Genesis': '1. Mose',
  'Exodus': '2. Mose',
  'Leviticus': '3. Mose',
  'Numbers': '4. Mose',
  'Deuteronomy': '5. Mose',
  'Joshua': 'Josua',
  'Judges': 'Richter',
  'Ruth': 'Rut',
  '1 Samuel': '1. Samuel',
  '2 Samuel': '2. Samuel',
  '1 Kings': '1. Könige',
  '2 Kings': '2. Könige',
  '1 Chronicles': '1. Chronik',
  '2 Chronicles': '2. Chronik',
  'Ezra': 'Esra',
  'Nehemiah': 'Nehemia',
  'Esther': 'Ester',
  'Job': 'Hiob',
  'Psalms': 'Psalmen',
  'Proverbs': 'Sprüche',
  'Ecclesiastes': 'Prediger',
  'Song of Solomon': 'Hoheslied',
  'Isaiah': 'Jesaja',
  'Jeremiah': 'Jeremia',
  'Lamentations': 'Klagelieder',
  'Ezekiel': 'Hesekiel',
  'Daniel': 'Daniel',
  'Hosea': 'Hosea',
  'Joel': 'Joel',
  'Amos': 'Amos',
  'Obadiah': 'Obadja',
  'Jonah': 'Jona',
  'Micah': 'Micha',
  'Nahum': 'Nahum',
  'Habakkuk': 'Habakuk',
  'Zephaniah': 'Zefanja',
  'Haggai': 'Haggai',
  'Zechariah': 'Sacharja',
  'Malachi': 'Maleachi',
  'Matthew': 'Matthäus',
  'Mark': 'Markus',
  'Luke': 'Lukas',
  'John': 'Johannes',
  'Acts': 'Apostelgeschichte',
  'Romans': 'Römer',
  '1 Corinthians': '1. Korinther',
  '2 Corinthians': '2. Korinther',
  'Galatians': 'Galater',
  'Ephesians': 'Epheser',
  'Philippians': 'Philipper',
  'Colossians': 'Kolosser',
  '1 Thessalonians': '1. Thessalonicher',
  '2 Thessalonians': '2. Thessalonicher',
  '1 Timothy': '1. Timotheus',
  '2 Timothy': '2. Timotheus',
  'Titus': 'Titus',
  'Philemon': 'Philemon',
  'Hebrews': 'Hebräer',
  'James': 'Jakobus',
  '1 Peter': '1. Petrus',
  '2 Peter': '2. Petrus',
  '1 John': '1. Johannes',
  '2 John': '2. Johannes',
  '3 John': '3. Johannes',
  'Jude': 'Judas',
  'Revelation': 'Offenbarung',
};

const Map<String, Map<String, String>> kBookNamesByLanguage = {
  'es': _kBookNamesEs,
  'de': _kBookNamesDe,
};

/// [book] as a reader of a [lang] Bible expects to see it. English, and any
/// language without a table, keep the canonical name.
String bookLabel(String book, String lang) =>
    kBookNamesByLanguage[lang]?[book] ?? book;

/// The language the canon is currently named in. It follows the Bible being
/// read rather than the app's own English, so a Spanish Bible says "Génesis"
/// everywhere a book is shown. Nothing stored depends on it — notes, plans and
/// reading positions all stay keyed by the canonical English name.
/// Set it via followCanonLanguage() in scripture.dart.
class CanonLanguage {
  static String code = 'en';
}

/// The handful of words the contents list sets beside the book names. Kept
/// here so they travel with the canon rather than with the app's own chrome.
class CanonLabels {
  final String contents;
  final String oldTestament;
  final String newTestament;

  const CanonLabels(this.contents, this.oldTestament, this.newTestament);
}

const Map<String, CanonLabels> _kCanonLabels = {
  'en': CanonLabels('Contents', 'Old Testament', 'New Testament'),
  'es': CanonLabels('Contenido', 'Antiguo Testamento', 'Nuevo Testamento'),
  'de': CanonLabels('Inhalt', 'Altes Testament', 'Neues Testament'),
};

CanonLabels canonLabels(String lang) =>
    _kCanonLabels[lang] ?? _kCanonLabels['en']!;

BibleBook bookByName(String name) {
  for (final b in kBibleBooks) {
    if (b.name == name) return b;
  }
  return kBibleBooks.firstWhere((b) => b.name == 'John');
}

int chapterCount(String book) => bookByName(book).chapters;

/// The chapter after [book] [chapter], rolling into the next book.
/// Returns null at the very end of Revelation.
(String, int)? nextChapterOf(String book, int chapter) {
  final b = bookByName(book);
  if (chapter < b.chapters) return (book, chapter + 1);
  final idx = kBibleBooks.indexWhere((x) => x.name == b.name);
  if (idx >= 0 && idx < kBibleBooks.length - 1) {
    return (kBibleBooks[idx + 1].name, 1);
  }
  return null;
}

/// The chapter before [book] [chapter], rolling into the previous book.
/// Returns null at Genesis 1.
(String, int)? prevChapterOf(String book, int chapter) {
  if (chapter > 1) return (book, chapter - 1);
  final b = bookByName(book);
  final idx = kBibleBooks.indexWhere((x) => x.name == b.name);
  if (idx > 0) {
    final prev = kBibleBooks[idx - 1];
    return (prev.name, prev.chapters);
  }
  return null;
}
