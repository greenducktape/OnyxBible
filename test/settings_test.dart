import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/settings_store.dart';

void main() {
  test('Settings round-trips through JSON', () {
    const s = Settings(
        lastBook: 'Romans',
        lastChapter: 8,
        penWidth: 2.75,
        inkShade: 'grey',
        translation: 'kjv',
        textScaleIndex: 3,
        ignoreTouch: true,
        uiSizeIndex: 2);
    final r = Settings.fromJson(s.toJson());
    expect(r.lastBook, 'Romans');
    expect(r.lastChapter, 8);
    expect(r.penWidth, 2.75);
    expect(r.inkShade, 'grey');
    expect(r.translation, 'kjv');
    expect(r.textScaleIndex, 3);
    expect(r.ignoreTouch, isTrue);
    expect(r.uiSizeIndex, 2);
  });

  test('Settings.fromJson fills sensible defaults', () {
    final d = Settings.fromJson({});
    expect(d.lastBook, 'John');
    expect(d.lastChapter, 1);
    expect(d.penWidth, 1.5);
    expect(d.inkShade, 'black');
    expect(d.translation, 'kjv');
    expect(d.textScaleIndex, 1);
    expect(d.ignoreTouch, isFalse);
    expect(d.uiSizeIndex, 0);
  });

  test('a settings file from before the slider keeps its chosen nib', () {
    // widthIndex was an index into [1.0, 1.5, 2.0, 3.0, 4.5, 6.0].
    expect(Settings.fromJson({'widthIndex': 0}).penWidth, 1.0);
    expect(Settings.fromJson({'widthIndex': 3}).penWidth, 3.0);
    expect(Settings.fromJson({'widthIndex': 5}).penWidth, 6.0);
    // Out of range, and the new key winning over the old one.
    expect(Settings.fromJson({'widthIndex': 99}).penWidth, 6.0);
    expect(
        Settings.fromJson({'widthIndex': 0, 'penWidth': 4.0}).penWidth, 4.0);
  });

  test('penWidth is held inside the nib range', () {
    expect(Settings.fromJson({'penWidth': 99.0}).penWidth, kMaxPenWidth);
    expect(Settings.fromJson({'penWidth': 0.0}).penWidth, kMinPenWidth);
  });

  test('copyWith changes only the given fields', () {
    const s = Settings();
    final c = s.copyWith(lastBook: 'Acts', lastChapter: 2, ignoreTouch: true);
    expect(c.lastBook, 'Acts');
    expect(c.lastChapter, 2);
    expect(c.penWidth, s.penWidth);
    expect(c.inkShade, s.inkShade);
    expect(c.translation, s.translation);
    expect(c.textScaleIndex, s.textScaleIndex);
    expect(c.ignoreTouch, isTrue);
  });
}
