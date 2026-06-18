import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/books.dart';

void main() {
  group('canon data', () {
    test('has all 66 books', () {
      expect(kBibleBooks.length, 66);
    });

    test('39 Old Testament + 27 New Testament', () {
      expect(kBibleBooks.where((b) => b.isOldTestament).length, 39);
      expect(kBibleBooks.where((b) => !b.isOldTestament).length, 27);
    });

    test('bookByName resolves known books and falls back to John', () {
      expect(bookByName('Genesis').chapters, 50);
      expect(bookByName('Psalms').chapters, 150);
      expect(bookByName('1 Corinthians').chapters, 16);
      expect(bookByName('Definitely Not A Book').name, 'John');
    });

    test('chapterCount matches the table', () {
      expect(chapterCount('John'), 21);
      expect(chapterCount('Revelation'), 22);
      expect(chapterCount('Obadiah'), 1);
    });
  });

  group('navigation', () {
    test('nextChapterOf advances within a book', () {
      expect(nextChapterOf('John', 1), ('John', 2));
    });

    test('nextChapterOf rolls into the next book', () {
      expect(nextChapterOf('John', 21), ('Acts', 1));
    });

    test('nextChapterOf returns null at the very end', () {
      expect(nextChapterOf('Revelation', 22), isNull);
    });

    test('prevChapterOf steps back within a book', () {
      expect(prevChapterOf('John', 2), ('John', 1));
    });

    test('prevChapterOf rolls into the previous book at its last chapter', () {
      expect(prevChapterOf('Acts', 1), ('John', 21));
    });

    test('prevChapterOf returns null at the very beginning', () {
      expect(prevChapterOf('Genesis', 1), isNull);
    });

    test('every book is reachable by walking forward from Genesis 1', () {
      var pos = ('Genesis', 1);
      var steps = 0;
      final seenBooks = <String>{pos.$1};
      while (true) {
        final next = nextChapterOf(pos.$1, pos.$2);
        if (next == null) break;
        pos = next;
        seenBooks.add(pos.$1);
        steps++;
        expect(steps, lessThan(2000), reason: 'walk should terminate');
      }
      expect(pos, ('Revelation', 22));
      expect(seenBooks.length, 66);
    });
  });
}
