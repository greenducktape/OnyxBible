import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/settings_store.dart';

void main() {
  test('Settings round-trips through JSON', () {
    const s = Settings(
        lastBook: 'Romans',
        lastChapter: 8,
        widthIndex: 2,
        translation: 'kjv',
        textScaleIndex: 3,
        ignoreTouch: true);
    final r = Settings.fromJson(s.toJson());
    expect(r.lastBook, 'Romans');
    expect(r.lastChapter, 8);
    expect(r.widthIndex, 2);
    expect(r.translation, 'kjv');
    expect(r.textScaleIndex, 3);
    expect(r.ignoreTouch, isTrue);
  });

  test('Settings.fromJson fills sensible defaults', () {
    final d = Settings.fromJson({});
    expect(d.lastBook, 'John');
    expect(d.lastChapter, 1);
    expect(d.widthIndex, 1);
    expect(d.translation, 'kjv');
    expect(d.textScaleIndex, 1);
    expect(d.ignoreTouch, isFalse);
  });

  test('copyWith changes only the given fields', () {
    const s = Settings();
    final c = s.copyWith(lastBook: 'Acts', lastChapter: 2, ignoreTouch: true);
    expect(c.lastBook, 'Acts');
    expect(c.lastChapter, 2);
    expect(c.widthIndex, s.widthIndex);
    expect(c.translation, s.translation);
    expect(c.textScaleIndex, s.textScaleIndex);
    expect(c.ignoreTouch, isTrue);
  });
}
