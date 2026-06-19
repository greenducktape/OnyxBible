import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/library_store.dart';
import 'package:boox_bible/settings_store.dart';

void main() {
  test('BibleConfig round-trips through JSON', () {
    const c = BibleConfig(
      id: 'b1',
      name: 'My Bible',
      translationId: 'rv1909',
      fontFamily: 'Lora',
      fontSizePt: 26,
      marginIndex: 2,
      lineSpacingIndex: 0,
      showVerseNumbers: false,
      showHeadings: true,
      createdAt: 123,
      lastBook: 'Romans',
      lastChapter: 8,
    );
    final r = BibleConfig.fromJson(c.toJson());
    expect(r.id, 'b1');
    expect(r.name, 'My Bible');
    expect(r.translationId, 'rv1909');
    expect(r.fontFamily, 'Lora');
    expect(r.fontSizePt, 26);
    expect(r.marginIndex, 2);
    expect(r.lineSpacingIndex, 0);
    expect(r.showVerseNumbers, isFalse);
    expect(r.lastBook, 'Romans');
    expect(r.lastChapter, 8);
  });

  test('copyWith changes only name and reading position', () {
    const c = BibleConfig(id: 'b1', createdAt: 0);
    final r = c.copyWith(lastBook: 'Acts', lastChapter: 2, name: 'Study');
    expect(r.lastBook, 'Acts');
    expect(r.lastChapter, 2);
    expect(r.name, 'Study');
    expect(r.translationId, c.translationId); // layout unchanged
    expect(r.id, 'b1');
  });

  test('migrates legacy settings into a printed Bible', () {
    const s = Settings(
        lastBook: 'John',
        lastChapter: 3,
        translation: 'luther1912',
        textScaleIndex: 3);
    final c = BibleConfig.fromLegacySettings('default', s);
    expect(c.id, 'default');
    expect(c.translationId, 'luther1912');
    expect(c.fontSizePt, 31); // [18,22,26,31,37][3]
    expect(c.lastBook, 'John');
    expect(c.lastChapter, 3);
  });
}
