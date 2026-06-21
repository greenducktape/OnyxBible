import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';
import 'settings_store.dart';

/// A single "printed" Bible — a fixed artifact. The layout choices are made once
/// (at setup) and then locked; only the reading position changes afterwards.
/// Each Bible owns its handwritten notes (file `notes_<id>.json`).
class BibleConfig {
  final String id;
  final String name; // optional dedication / display name
  final String translationId;
  final String fontFamily;
  final double fontSizePt;
  final int marginIndex; // index into the reader's margin options
  final int lineSpacingIndex; // index into the reader's line-spacing options
  final bool showVerseNumbers;
  final bool showHeadings;
  final int createdAt; // epoch ms
  final String lastBook; // reading position (mutable post-print)
  final int lastChapter;

  const BibleConfig({
    required this.id,
    this.name = '',
    this.translationId = 'kjv',
    this.fontFamily = 'Crimson Pro',
    this.fontSizePt = 22,
    this.marginIndex = 1,
    this.lineSpacingIndex = 1,
    this.showVerseNumbers = true,
    this.showHeadings = true,
    this.createdAt = 0,
    this.lastBook = 'John',
    this.lastChapter = 1,
  });

  BibleConfig copyWith({
    String? name,
    String? lastBook,
    int? lastChapter,
  }) =>
      BibleConfig(
        id: id,
        name: name ?? this.name,
        translationId: translationId,
        fontFamily: fontFamily,
        fontSizePt: fontSizePt,
        marginIndex: marginIndex,
        lineSpacingIndex: lineSpacingIndex,
        showVerseNumbers: showVerseNumbers,
        showHeadings: showHeadings,
        createdAt: createdAt,
        lastBook: lastBook ?? this.lastBook,
        lastChapter: lastChapter ?? this.lastChapter,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'translationId': translationId,
        'fontFamily': fontFamily,
        'fontSizePt': fontSizePt,
        'marginIndex': marginIndex,
        'lineSpacingIndex': lineSpacingIndex,
        'showVerseNumbers': showVerseNumbers,
        'showHeadings': showHeadings,
        'createdAt': createdAt,
        'lastBook': lastBook,
        'lastChapter': lastChapter,
      };

  factory BibleConfig.fromJson(Map<String, dynamic> j) => BibleConfig(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        translationId: j['translationId'] as String? ?? 'kjv',
        fontFamily: j['fontFamily'] as String? ?? 'Crimson Pro',
        fontSizePt: (j['fontSizePt'] as num?)?.toDouble() ?? 22,
        marginIndex: (j['marginIndex'] as num?)?.toInt() ?? 1,
        lineSpacingIndex: (j['lineSpacingIndex'] as num?)?.toInt() ?? 1,
        showVerseNumbers: j['showVerseNumbers'] as bool? ?? true,
        showHeadings: j['showHeadings'] as bool? ?? true,
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        lastBook: j['lastBook'] as String? ?? 'John',
        lastChapter: (j['lastChapter'] as num?)?.toInt() ?? 1,
      );

  /// The legacy text-size steps, so a migrated Bible keeps its old size.
  static const List<double> _legacySizes = [18, 22, 26, 31, 37];

  /// Builds the one migrated Bible from the pre-library [Settings].
  factory BibleConfig.fromLegacySettings(String id, Settings s) => BibleConfig(
        id: id,
        translationId: s.translation,
        fontSizePt: _legacySizes[s.textScaleIndex.clamp(0, 4).toInt()],
        createdAt: DateTime.now().millisecondsSinceEpoch,
        lastBook: s.lastBook,
        lastChapter: s.lastChapter,
      );
}

/// The library of printed Bibles, plus which one is open. File-based JSON, like
/// the app's other stores.
class LibraryStore {
  static List<BibleConfig> _bibles = [];
  static String? _activeId;
  static bool _loaded = false;

  static List<BibleConfig> get bibles => List.unmodifiable(_bibles);
  static bool get isEmpty => _bibles.isEmpty;
  static String? get activeId => _activeId;

  static BibleConfig get active {
    for (final b in _bibles) {
      if (b.id == _activeId) return b;
    }
    return _bibles.first; // callers guard isEmpty before reading
  }

  static Future<void> init() async {
    if (_loaded) return;
    try {
      final r = await readJsonResilient(await _file());
      if (r.data is Map<String, dynamic>) {
        final j = r.data as Map<String, dynamic>;
        _bibles = [
          for (final e in (j['bibles'] as List? ?? const []))
            BibleConfig.fromJson(e as Map<String, dynamic>)
        ];
        _activeId = j['activeId'] as String?;
      }
    } catch (e) {
      debugPrint('Error loading library: $e');
    }
    _loaded = true;
  }

  /// Add a Bible and open it.
  static Future<void> add(BibleConfig config) async {
    _bibles.add(config);
    _activeId = config.id;
    await _flush();
  }

  static Future<void> setActive(String id) async {
    if (_bibles.any((b) => b.id == id)) {
      _activeId = id;
      await _flush();
    }
  }

  static Future<void> rename(String id, String name) async {
    _replace(id, (b) => b.copyWith(name: name));
    await _flush();
  }

  static Future<void> remove(String id) async {
    _bibles.removeWhere((b) => b.id == id);
    if (_activeId == id) _activeId = _bibles.isEmpty ? null : _bibles.first.id;
    await _flush();
  }

  /// Persist the active Bible's reading position (called as the reader moves).
  static void rememberPosition(String book, int chapter) {
    final id = _activeId;
    if (id == null) return;
    _replace(id, (b) => b.copyWith(lastBook: book, lastChapter: chapter));
    unawaited(_flush());
  }

  static void _replace(String id, BibleConfig Function(BibleConfig) f) {
    for (var i = 0; i < _bibles.length; i++) {
      if (_bibles[i].id == id) {
        _bibles[i] = f(_bibles[i]);
        return;
      }
    }
  }

  static Future<void> _flush() async {
    try {
      await writeJsonAtomic(await _file(), {
        'schema': 1,
        'activeId': _activeId,
        'bibles': _bibles.map((b) => b.toJson()).toList(),
      });
    } catch (e) {
      debugPrint('Error saving library: $e');
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/library_v1.json');
  }

  /// A fresh, unique Bible id.
  static String newId() => 'b${DateTime.now().microsecondsSinceEpoch}';

  /// The id used for the single migrated/first Bible (so legacy notes can be
  /// adopted exactly once — see DrawingStore).
  static const String defaultId = 'default';
}
