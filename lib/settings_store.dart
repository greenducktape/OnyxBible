import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';

/// User preferences that persist across launches. File-based JSON, consistent
/// with the app's other stores (DrawingStore) — no extra plugin dependency.
class Settings {
  final String lastBook;
  final int lastChapter;
  final int widthIndex; // index into the reader's stroke-width list
  final String translation; // translation id (see scripture.dart registry)
  final int textScaleIndex; // index into the reader's text-size steps
  final bool ignoreTouch; // palm rejection: ignore finger touches (pen only)

  const Settings({
    this.lastBook = 'John',
    this.lastChapter = 1,
    this.widthIndex = 1,
    this.translation = 'kjv',
    this.textScaleIndex = 1,
    this.ignoreTouch = false,
  });

  Settings copyWith({
    String? lastBook,
    int? lastChapter,
    int? widthIndex,
    String? translation,
    int? textScaleIndex,
    bool? ignoreTouch,
  }) =>
      Settings(
        lastBook: lastBook ?? this.lastBook,
        lastChapter: lastChapter ?? this.lastChapter,
        widthIndex: widthIndex ?? this.widthIndex,
        translation: translation ?? this.translation,
        textScaleIndex: textScaleIndex ?? this.textScaleIndex,
        ignoreTouch: ignoreTouch ?? this.ignoreTouch,
      );

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'lastBook': lastBook,
        'lastChapter': lastChapter,
        'widthIndex': widthIndex,
        'translation': translation,
        'textScaleIndex': textScaleIndex,
        'ignoreTouch': ignoreTouch,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        lastBook: j['lastBook'] as String? ?? 'John',
        lastChapter: (j['lastChapter'] as num?)?.toInt() ?? 1,
        widthIndex: (j['widthIndex'] as num?)?.toInt() ?? 1,
        translation: j['translation'] as String? ?? 'kjv',
        textScaleIndex: (j['textScaleIndex'] as num?)?.toInt() ?? 1,
        ignoreTouch: j['ignoreTouch'] as bool? ?? false,
      );
}

class SettingsStore {
  static Settings _value = const Settings();
  static bool _loaded = false;
  static Timer? _saveDebouncer;

  static Settings get value => _value;

  static Future<void> init() async {
    if (_loaded) return;
    try {
      final r = await readJsonResilient(await _file());
      if (r.data is Map<String, dynamic>) {
        _value = Settings.fromJson(r.data as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
    }
    _loaded = true;
  }

  static void update(Settings next) {
    _value = next;
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 500), _write);
  }

  /// Cancel any pending debounce and write immediately (e.g. on app pause).
  static Future<void> flushNow() async {
    _saveDebouncer?.cancel();
    await _write();
  }

  /// Replace all settings (used when restoring a backup).
  static Future<void> restore(Settings next) async {
    _value = next;
    await flushNow();
  }

  static Future<void> _write() async {
    try {
      await writeJsonAtomic(await _file(), _value.toJson());
    } catch (e) {
      debugPrint('Error saving settings: $e');
    }
  }

  /// Whether a settings file was ever written — i.e. this is an existing user,
  /// used to decide whether to migrate them into the new Bible library.
  static Future<bool> fileExists() async => (await _file()).exists();

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/settings_v1.json');
  }
}
