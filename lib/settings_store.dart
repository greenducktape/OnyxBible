import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// User preferences that persist across launches. File-based JSON, consistent
/// with the app's other stores (DrawingStore) — no extra plugin dependency.
class Settings {
  final String lastBook;
  final int lastChapter;
  final int widthIndex; // index into the reader's stroke-width list
  final String translation; // translation id (see scripture.dart registry)

  const Settings({
    this.lastBook = 'John',
    this.lastChapter = 1,
    this.widthIndex = 1,
    this.translation = 'kjv',
  });

  Settings copyWith({
    String? lastBook,
    int? lastChapter,
    int? widthIndex,
    String? translation,
  }) =>
      Settings(
        lastBook: lastBook ?? this.lastBook,
        lastChapter: lastChapter ?? this.lastChapter,
        widthIndex: widthIndex ?? this.widthIndex,
        translation: translation ?? this.translation,
      );

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'lastBook': lastBook,
        'lastChapter': lastChapter,
        'widthIndex': widthIndex,
        'translation': translation,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        lastBook: j['lastBook'] as String? ?? 'John',
        lastChapter: (j['lastChapter'] as num?)?.toInt() ?? 1,
        widthIndex: (j['widthIndex'] as num?)?.toInt() ?? 1,
        translation: j['translation'] as String? ?? 'kjv',
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
      final f = await _file();
      if (await f.exists()) {
        final s = await f.readAsString();
        if (s.isNotEmpty) {
          _value = Settings.fromJson(json.decode(s) as Map<String, dynamic>);
        }
      }
    } catch (e) {
      debugPrint('Error loading settings: $e');
    }
    _loaded = true;
  }

  static void update(Settings next) {
    _value = next;
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final f = await _file();
        await f.writeAsString(json.encode(_value.toJson()));
      } catch (e) {
        debugPrint('Error saving settings: $e');
      }
    });
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/settings_v1.json');
  }
}
