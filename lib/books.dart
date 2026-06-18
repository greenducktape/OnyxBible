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
