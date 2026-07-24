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
  final double penWidth; // nib width in logical pixels (continuous)
  final String inkShade; // ink shade id (see kInkShades)
  final String translation; // translation id (see scripture.dart registry)
  final int textScaleIndex; // index into the reader's text-size steps
  final bool ignoreTouch; // palm rejection: ignore finger touches (pen only)
  final int uiSizeIndex; // toolbar/chrome scale: 0 = Auto (see kUiSizeLabels)

  const Settings({
    this.lastBook = 'John',
    this.lastChapter = 1,
    this.penWidth = 1.5,
    this.inkShade = 'black',
    this.translation = 'kjv',
    this.textScaleIndex = 1,
    this.ignoreTouch = false,
    this.uiSizeIndex = 0,
  });

  Settings copyWith({
    String? lastBook,
    int? lastChapter,
    double? penWidth,
    String? inkShade,
    String? translation,
    int? textScaleIndex,
    bool? ignoreTouch,
    int? uiSizeIndex,
  }) =>
      Settings(
        lastBook: lastBook ?? this.lastBook,
        lastChapter: lastChapter ?? this.lastChapter,
        penWidth: penWidth ?? this.penWidth,
        inkShade: inkShade ?? this.inkShade,
        translation: translation ?? this.translation,
        textScaleIndex: textScaleIndex ?? this.textScaleIndex,
        ignoreTouch: ignoreTouch ?? this.ignoreTouch,
        uiSizeIndex: uiSizeIndex ?? this.uiSizeIndex,
      );

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'lastBook': lastBook,
        'lastChapter': lastChapter,
        'penWidth': penWidth,
        'inkShade': inkShade,
        'translation': translation,
        'textScaleIndex': textScaleIndex,
        'ignoreTouch': ignoreTouch,
        'uiSizeIndex': uiSizeIndex,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        lastBook: j['lastBook'] as String? ?? 'John',
        lastChapter: (j['lastChapter'] as num?)?.toInt() ?? 1,
        penWidth: _readPenWidth(j),
        inkShade: j['inkShade'] as String? ?? 'black',
        translation: j['translation'] as String? ?? 'kjv',
        textScaleIndex: (j['textScaleIndex'] as num?)?.toInt() ?? 1,
        ignoreTouch: j['ignoreTouch'] as bool? ?? false,
        uiSizeIndex: (j['uiSizeIndex'] as num?)?.toInt() ?? 0,
      );
}

/// The nib widths the pen used to be limited to. Kept only so a settings file
/// written before the slider existed reopens at the size its owner last chose.
const List<double> _kLegacyWidths = [1.0, 1.5, 2.0, 3.0, 4.5, 6.0];

double _readPenWidth(Map<String, dynamic> j) {
  final w = (j['penWidth'] as num?)?.toDouble();
  if (w != null) return w.clamp(kMinPenWidth, kMaxPenWidth);
  final i = (j['widthIndex'] as num?)?.toInt();
  if (i == null) return 1.5;
  return _kLegacyWidths[i.clamp(0, _kLegacyWidths.length - 1)];
}

/// Nib range, in logical pixels: a hairline through to a broad marker stroke.
const double kMinPenWidth = 0.5;
const double kMaxPenWidth = 12.0;

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
