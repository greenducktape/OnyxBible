import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton, kTertiaryButton;
import 'package:flutter/material.dart';
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';
import 'backup.dart';
import 'books.dart';
import 'library_store.dart';
import 'plan_store.dart';
import 'reading_plan.dart';
import 'reference.dart';
import 'scripture.dart';
import 'settings_store.dart';
import 'verse.dart';

// Re-export so existing imports of package:boox_bible/main.dart (and tests)
// continue to see these symbols after the model/data extraction.
export 'verse.dart';
export 'scripture.dart';
export 'settings_store.dart';

void main() {
  // Surface framework + uncaught errors to the log instead of a silent
  // dark screen. No network/telemetry — debugPrint only.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await OnyxSdkPenArea.init();
    gDisplayDpi = await OnyxsdkPen().displayDpi();
    await SettingsStore.init();
    await PlanStore.init();
    await loadPrivateTranslations(); // register any locally-added versions
    await LibraryStore.init();
    await _bootstrapLibrary();
    if (!LibraryStore.isEmpty) {
      await DrawingStore.useBible(LibraryStore.active.id);
    }
    runApp(const BooxBibleApp());
  }, (error, stack) {
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}

/// Migrates existing users (who have a settings file) into a single "default"
/// printed Bible so their notes and translation carry over. Fresh installs are
/// left with an empty library so the setup wizard runs on first launch.
Future<void> _bootstrapLibrary() async {
  if (!LibraryStore.isEmpty) return;
  if (await SettingsStore.fileExists()) {
    await LibraryStore.add(BibleConfig.fromLegacySettings(
        LibraryStore.defaultId, SettingsStore.value));
  }
}

// --- Bundled typefaces ----------------------------------------------------
//
// The reading fonts are bundled as assets (see pubspec `fonts:`) so the app is
// fully offline from the very first launch — no Google Fonts network fetch.
// Crimson Pro / EB Garamond / Lora are variable fonts whose `wght` axis covers
// every weight the UI asks for via [FontWeight]; Atkinson Hyperlegible ships
// regular + bold. These helpers replace the old GoogleFonts.* calls 1:1.

/// A text style in any bundled family.
TextStyle appFont(
  String family, {
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? height,
  double? letterSpacing,
  FontStyle? fontStyle,
}) =>
    TextStyle(
      fontFamily: family,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      fontStyle: fontStyle,
    );

/// Crimson Pro — the default serif used across the chrome and headings.
TextStyle crimson({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? height,
  double? letterSpacing,
  FontStyle? fontStyle,
}) =>
    appFont('Crimson Pro',
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontStyle: fontStyle);

// --- E-ink design tokens --------------------------------------------------
//
// E-ink panels can't render subtle greys (they dither into noisy stipple), so
// the palette is essentially pure black on white. A single restrained grey is
// reserved for tiny meta labels; a lighter one marks disabled controls.

const Color kInk = Color(0xFF000000);
const Color kMuted = Color(0xFF5F5F5F);
const Color kDisabled = Color(0xFFB4B4B4);
const Color kPaper = Color(0xFFFFFFFF);

// Reading layout. The page content fills the available width (minus a fixed
// side padding); the chosen margin fraction — not a hard cap — decides how much
// of that is text vs. blank writing margin, so what you pick at setup is what
// you see. A little more room up top keeps the first line off the toolbar.
const double kHPadding = 24;
const double kGutterWidth = 34; // left margin holding the verse number
const double kVerseSpacing = 12; // gap below each verse
const double kChapterHeaderHeight = 96; // reserved on the first page only
// Top margin hosts the running header; the bottom hosts the folio.
const EdgeInsets kPageVPadding = EdgeInsets.fromLTRB(0, 26, 0, 24);

/// Page geometry shared by the reader and the setup-wizard preview, so the two
/// can never disagree about how wide the text column and writing margin are.
class ReadingMetrics {
  final double contentWidth; // the page content block (centred in the view)
  final double textWidth; // the text column; the rest is blank writing margin
  const ReadingMetrics(this.contentWidth, this.textWidth);
}

ReadingMetrics readingMetricsFor(
  double contentWidth, {
  required double marginFraction,
  required bool showVerseNumbers,
}) {
  final gutter = showVerseNumbers ? kGutterWidth : 0.0;
  final textColumn = contentWidth * marginFraction;
  return ReadingMetrics(contentWidth, math.max(0.0, textColumn - gutter));
}

// --- Shared typography ----------------------------------------------------
//
// The verse body style is size-adjustable. It MUST be built with the active
// size both where pagination measures and where the verse renders, otherwise
// pages overflow or leave gaps. Reader screen builds it once per frame and
// threads it through, so it isn't reconstructed per verse.

// Reading-layout options offered once, in the "Print your Bible" setup. After a
// Bible is printed these are locked — which is exactly what keeps handwritten
// notes aligned forever.
const List<double> kFontSizeOptions = [18, 20, 22, 26, 30, 36, 44, 52];
const List<String> kFontFamilies = [
  'Crimson Pro', // serif, default
  'EB Garamond', // classic serif
  'Lora', // sturdy serif
  'Atkinson Hyperlegible', // humanist sans, high legibility on e-ink
];
// Fraction of the page width the *text column* occupies; the rest is a blank
// margin you can write in. Smaller fraction = wider writing margin.
const List<double> kMarginFractions = [0.96, 0.82, 0.68, 0.55];
const List<String> kMarginLabels = ['Standard', 'Wide', 'Wider', 'Widest'];
const List<double> kLineSpacings = [1.4, 1.55, 1.75, 2.0];
const List<String> kLineSpacingLabels = ['Tight', 'Normal', 'Relaxed', 'Airy'];

// Interface (chrome) scale for large e-ink panels. Many Boox devices report a
// near-1.0 devicePixelRatio with a very high logical resolution, so fixed
// logical sizes render physically tiny on a 13" screen. Index 0 = Auto (derived
// from the screen size); the rest are explicit multipliers the user can pick.
const List<String> kUiSizeLabels = ['Auto', 'Large', 'Larger', 'Largest'];
const List<double> kUiSizeScales = [0.0, 1.3, 1.6, 2.0]; // 0 = auto

/// The chrome scale for [context]: an explicit user choice, or an auto value
/// derived from the shorter screen edge when set to Auto.
double uiScaleFor(BuildContext context) {
  final idx =
      SettingsStore.value.uiSizeIndex.clamp(0, kUiSizeScales.length - 1).toInt();
  if (idx > 0) return kUiSizeScales[idx];
  final shortest = MediaQuery.of(context).size.shortestSide;
  return (shortest / 1100).clamp(1.0, 2.2);
}

/// Wraps a secondary screen (plans, library, notes, setup, …) so its text and
/// icons scale by the same [uiScaleFor] factor the reader chrome uses. The
/// reader itself scales its toolbar manually and keeps the verse area pinned,
/// so it is deliberately NOT wrapped (a global text scaler would desync the
/// reader's TextPainter pagination). These screens do no such measuring, so a
/// MediaQuery textScaler is the simplest way to enlarge everything at once.
class UiScaled extends StatelessWidget {
  final Widget child;
  const UiScaled({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final theme = Theme.of(context);
    final ui = uiScaleFor(context);
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(ui)),
      child: Theme(
        // Grow the AppBar so a scaled-up title isn't clipped by the default
        // 56-dp toolbar, and enlarge default icons to match the text.
        data: theme.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(toolbarHeight: 56 * ui),
          iconTheme: theme.iconTheme.copyWith(size: 24 * ui),
        ),
        child: IconTheme.merge(
          data: IconThemeData(size: 24 * ui),
          child: child,
        ),
      ),
    );
  }
}

/// Verse body style for a printed Bible's locked layout (family/size/spacing).
TextStyle verseStyleForCfg(BibleConfig c) => appFont(
      c.fontFamily,
      fontSize: c.fontSizePt,
      height: kLineSpacings[c.lineSpacingIndex.clamp(0, kLineSpacings.length - 1)],
      color: kInk,
    );

/// The inline span for one verse — shared by pagination measurement and by
/// [VerseText] rendering so the two can never disagree about line breaks.
/// With [dropCap] the first letter renders as a decorated initial (a raised
/// cap, ~1.9x): that grows the first line's box, so measuring the SAME span is
/// what keeps the printed pages exact.
TextSpan verseSpan(String text, TextStyle style, {bool dropCap = false}) {
  if (!dropCap || text.isEmpty) return TextSpan(text: text, style: style);
  return TextSpan(style: style, children: [
    TextSpan(
      text: text[0],
      style: style.copyWith(
        fontSize: (style.fontSize ?? 22) * 1.9,
        height: 1.0,
        fontWeight: FontWeight.w600,
      ),
    ),
    TextSpan(text: text.substring(1)),
  ]);
}

/// Plain size-only serif style — used by setup previews and small chrome.
TextStyle verseStyleOf(double fontSize) =>
    crimson(fontSize: fontSize, height: 1.55, color: kInk);

final TextStyle kVerseStyle = verseStyleOf(22);
final TextStyle kVerseNumberStyle = crimson(
  fontSize: 13,
  height: 1.2,
  color: kMuted,
  fontWeight: FontWeight.w700,
);

TextStyle kTitleStyle(double size, {FontWeight weight = FontWeight.w600}) =>
    crimson(fontSize: size, fontWeight: weight, color: kInk);

/// A static "working…" mark. An animated spinner repaints at 60fps, which
/// smears and burns partial refreshes on e-ink; loads here are near-instant
/// (bundled assets), so a quiet ellipsis is calmer and truer to paper.
class QuietLoader extends StatelessWidget {
  const QuietLoader({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Text('· · ·',
            style: crimson(
                fontSize: 22, color: kMuted, fontWeight: FontWeight.w700)),
      );
}

// --- Data Models ----------------------------------------------------------

class StrokePoint {
  final double x;
  final double y;

  /// Stylus pressure normalised to 0..1, or -1 when the pen reports none — see
  /// _pressureOf. Painting treats -1 as "lay down the plain nib", so a pen
  /// without a sensor draws an even line instead of a guessed one.
  final double pressure;

  const StrokePoint(this.x, this.y, [this.pressure = 1.0]);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'p': pressure};

  factory StrokePoint.fromJson(Map<String, dynamic> json) => StrokePoint(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        (json['p'] as num?)?.toDouble() ?? 1.0,
      );

  Offset toOffset() => Offset(x, y);
}

class Stroke {
  final List<StrokePoint> points;
  final double width;
  final Color color;

  // The size of the verse's ink canvas when this stroke was drawn. Strokes are
  // stored in those capture-time pixel coordinates; at paint time they are
  // rescaled to the *current* canvas, so notes stay anchored when the layout
  // changes (font size, screen rotation, different device width).
  //
  // 0 means "unknown" — legacy strokes saved before capture boxes existed. They
  // are drawn 1:1 (exactly as before), never rescaled, so old notes can't shift.
  final double captureW;
  final double captureH;

  // Pen recipe id (see kPenPresets / penRecipeFor). Drives how the committed
  // stroke is rendered — pressure→width range, caps, alpha — so a stroke keeps
  // the look of the pen it was drawn with. Legacy strokes read as 'ballpoint'.
  final String style;

  Stroke({
    required this.points,
    this.width = 2.5,
    this.color = Colors.black,
    this.captureW = 0,
    this.captureH = 0,
    this.style = 'ballpoint',
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => p.toJson()).toList(),
        'width': width,
        'color': color.toARGB32(),
        if (captureW > 0) 'cw': captureW,
        if (captureH > 0) 'ch': captureH,
        if (style != 'ballpoint') 'st': style,
      };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List;
    return Stroke(
      points: rawPoints
          .map((p) => StrokePoint.fromJson(p as Map<String, dynamic>))
          .toList(),
      width: (json['width'] as num?)?.toDouble() ?? 2.5,
      color: Color(json['color'] as int? ?? Colors.black.toARGB32()),
      captureW: (json['cw'] as num?)?.toDouble() ?? 0,
      captureH: (json['ch'] as num?)?.toDouble() ?? 0,
      style: json['st'] as String? ?? 'ballpoint',
    );
  }

  /// Horizontal/vertical scale that maps this stroke's capture box onto
  /// [canvas]. Unknown capture boxes (or a missing canvas) map 1:1.
  (double, double) scaleTo(Size? canvas) {
    if (canvas == null) return (1, 1);
    final sx = (captureW > 0 && canvas.width > 0) ? canvas.width / captureW : 1.0;
    final sy =
        (captureH > 0 && canvas.height > 0) ? canvas.height / captureH : 1.0;
    return (sx, sy);
  }

  /// True if any point on this stroke is within [radius] of [p]. Used by the
  /// stroke-level eraser so erasing removes the touched mark, not the verse.
  /// [p] is in current-canvas coordinates; pass [canvas] so the stroke's
  /// capture-time points are compared in the same space.
  bool isNear(Offset p, double radius, {Size? canvas}) {
    final (sx, sy) = scaleTo(canvas);
    final r2 = radius * radius;
    for (final pt in points) {
      final dx = pt.x * sx - p.dx;
      final dy = pt.y * sy - p.dy;
      if (dx * dx + dy * dy <= r2) return true;
    }
    return false;
  }
}

// --- Persistence: handwritten notes ---------------------------------------

class DrawingStore {
  static final Map<String, List<Stroke>> _notes = {};
  static Timer? _saveDebouncer;
  static String? _bibleId;

  /// Open a Bible's note set (`notes_<id>.json`), flushing the previous one.
  /// Notes are scoped per printed Bible so each artifact keeps its own marks.
  static Future<void> useBible(String id) async {
    if (_bibleId == id) return;
    _saveDebouncer?.cancel();
    if (_bibleId != null) await _save();
    _bibleId = id;
    _notes.clear();
    await _load();
  }

  static Future<void> _load() async {
    final id = _bibleId;
    if (id == null) return;
    try {
      var file = await _noteFile(id);
      // Adopt the pre-library global notes into the first Bible, exactly once.
      if (id == LibraryStore.defaultId && !await file.exists()) {
        final legacy = await _legacyFile();
        if (await legacy.exists()) file = legacy;
      }
      final r = await readJsonResilient(file);
      if (r.data is Map<String, dynamic>) {
        final data = r.data as Map<String, dynamic>;
        _notes.addAll(data.map((key, value) => MapEntry(
            key,
            (value as List)
                .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
                .toList())));
      }
    } catch (e) {
      debugPrint('Error loading notes: $e');
    }
  }

  /// Returns the persisted strokes for a verse. Callers own a copy.
  static List<Stroke> strokesFor(String verseId) =>
      List<Stroke>.of(_notes[verseId] ?? const []);

  /// Verse ids that currently hold at least one stroke. Used by the notes
  /// browser; order is unspecified (the browser sorts canonically).
  static Iterable<String> annotatedVerseIds() => _notes.keys;

  /// Number of strokes saved on a verse (0 if none).
  static int strokeCount(String verseId) => _notes[verseId]?.length ?? 0;

  static void setStrokes(String verseId, List<Stroke> strokes) {
    if (strokes.isEmpty) {
      _notes.remove(verseId);
    } else {
      _notes[verseId] = List<Stroke>.of(strokes);
    }
    _triggerSave();
  }

  static void _triggerSave() {
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 800), _save);
  }

  /// Cancel any pending debounce and write the notes now. Called when a stroke
  /// is lifted (so committed ink is durable immediately, not 800ms later) and
  /// when the app is backgrounded.
  static Future<void> flushNow() async {
    _saveDebouncer?.cancel();
    await _save();
  }

  static Future<void> _save() async {
    final id = _bibleId;
    if (id == null) return;
    try {
      final file = await _noteFile(id);
      final data = _notes.map(
          (key, value) => MapEntry(key, value.map((s) => s.toJson()).toList()));
      await writeJsonAtomic(file, data);
    } catch (e) {
      debugPrint('Error saving notes: $e');
    }
  }

  static Future<File> _noteFile(String id) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/notes_$id.json');
  }

  static Future<File> _legacyFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/bible_notes_v4.json');
  }

  /// Delete a (non-active) Bible's notes when its artifact is removed.
  static Future<void> discardNotesFor(String id) async {
    try {
      final f = await _noteFile(id);
      if (await f.exists()) await f.delete();
    } catch (_) {/* best effort */}
  }

  /// Raw notes JSON for a Bible (decoded), or null. Used by backup/export.
  static Future<dynamic> rawNotesFor(String id) async {
    final r = await readJsonResilient(await _noteFile(id));
    return r.data;
  }

  /// Overwrite a Bible's notes file from backup data (atomic). Does not touch
  /// the in-memory cache; call [reloadActive] afterwards if [id] is open.
  static Future<void> writeRawNotesFor(String id, Object notesJson) async {
    await writeJsonAtomic(await _noteFile(id), notesJson);
  }

  /// Drop any pending debounced save without writing (used before a restore
  /// replaces the notes files wholesale).
  static void cancelPendingSave() => _saveDebouncer?.cancel();

  /// Open [id] and (re)load its notes from disk even if it is already the
  /// current Bible — used after a restore rewrites the notes files.
  static Future<void> switchAndReload(String id) async {
    _saveDebouncer?.cancel();
    _bibleId = null; // force useBible to actually reload from disk
    _notes.clear();
    await useBible(id);
  }
}

// --- Pagination cache -----------------------------------------------------
//
// Caches the layout (verses split into pages) per book/chapter/size/style.
// Verse text itself now comes from ScriptureSource (offline bundle), which
// does its own lightweight caching.

class PageCache {
  // Insertion-ordered, so the oldest key is first — a simple LRU: touching a key
  // re-inserts it at the end, and we evict from the front past the cap. Bounded
  // so long reading sessions on 2–4 GB Boox devices don't grow without limit.
  static final Map<String, List<List<Verse>>> _pages = {};
  static const int _maxEntries = 64;

  static List<List<Verse>>? get(String key) {
    final v = _pages.remove(key);
    if (v != null) _pages[key] = v; // mark most-recently-used
    return v;
  }

  static void put(String key, List<List<Verse>> pages) {
    _pages.remove(key);
    _pages[key] = pages;
    while (_pages.length > _maxEntries) {
      _pages.remove(_pages.keys.first); // evict least-recently-used
    }
  }
}

// --- Undo / redo ----------------------------------------------------------
//
// Per-verse undo/redo. DrawingStore is the source of truth; operations mutate
// it, then the currently-mounted verse (if any) resyncs via the same canvas-only
// `_repaint` path used for live drawing — so undo never rebuilds widgets or
// relayouts text.

abstract class _StrokeOp {
  void apply(String verseId); // (re)do
  void invert(String verseId); // undo
}

class _AddStrokeOp extends _StrokeOp {
  final Stroke stroke;
  _AddStrokeOp(this.stroke);

  @override
  void apply(String verseId) =>
      DrawingStore.setStrokes(verseId, DrawingStore.strokesFor(verseId)..add(stroke));

  @override
  void invert(String verseId) => DrawingStore.setStrokes(verseId,
      DrawingStore.strokesFor(verseId)..removeWhere((s) => identical(s, stroke)));
}

class _EraseStrokesOp extends _StrokeOp {
  final List<Stroke> removed;
  _EraseStrokesOp(this.removed);

  @override
  void apply(String verseId) => DrawingStore.setStrokes(
      verseId,
      DrawingStore.strokesFor(verseId)
        ..removeWhere((s) => removed.any((r) => identical(r, s))));

  @override
  void invert(String verseId) => DrawingStore.setStrokes(
      verseId, DrawingStore.strokesFor(verseId)..addAll(removed));
}

class UndoController {
  static const int _maxPerVerse = 100;
  final Map<String, List<_StrokeOp>> _undo = {};
  final Map<String, List<_StrokeOp>> _redo = {};
  final Map<String, VoidCallback> _hooks = {}; // mounted verse resync callbacks
  String? _lastVerse;

  final ValueNotifier<bool> canUndo = ValueNotifier(false);
  final ValueNotifier<bool> canRedo = ValueNotifier(false);

  void register(String verseId, VoidCallback resync) =>
      _hooks[verseId] = resync;
  void unregister(String verseId, VoidCallback resync) {
    if (_hooks[verseId] == resync) _hooks.remove(verseId);
  }

  void recordAdd(String verseId, Stroke s) =>
      _record(verseId, _AddStrokeOp(s));
  void recordErase(String verseId, List<Stroke> removed) =>
      _record(verseId, _EraseStrokesOp(removed));

  void _record(String verseId, _StrokeOp op) {
    final stack = _undo.putIfAbsent(verseId, () => []);
    stack.add(op);
    if (stack.length > _maxPerVerse) stack.removeAt(0);
    _redo[verseId]?.clear();
    _lastVerse = verseId;
    _refresh();
  }

  void undo() {
    final id = _lastVerse;
    final stack = id == null ? null : _undo[id];
    if (id == null || stack == null || stack.isEmpty) return;
    final op = stack.removeLast();
    op.invert(id);
    (_redo.putIfAbsent(id, () => [])).add(op);
    _hooks[id]?.call();
    _refresh();
  }

  void redo() {
    final id = _lastVerse;
    final stack = id == null ? null : _redo[id];
    if (id == null || stack == null || stack.isEmpty) return;
    final op = stack.removeLast();
    op.apply(id);
    (_undo.putIfAbsent(id, () => [])).add(op);
    _hooks[id]?.call();
    _refresh();
  }

  /// Cleared on navigation so undo never reaches into a previous chapter.
  void clear() {
    _undo.clear();
    _redo.clear();
    _lastVerse = null;
    _refresh();
  }

  void _refresh() {
    final id = _lastVerse;
    canUndo.value = id != null && (_undo[id]?.isNotEmpty ?? false);
    canRedo.value = id != null && (_redo[id]?.isNotEmpty ?? false);
  }
}

/// App-wide undo controller for handwriting.
final UndoController kUndo = UndoController();

// --- Main App -------------------------------------------------------------

/// Route changes appear instantly. Material's slide/fade transitions smear and
/// ghost on an e-ink panel; a hard cut reads as "the page turned", like paper.
class _InstantPageTransitions extends PageTransitionsBuilder {
  const _InstantPageTransitions();

  @override
  Widget buildTransitions<T>(
          PageRoute<T> route,
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child) =>
      child;
}

class BooxBibleApp extends StatelessWidget {
  const BooxBibleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // A deliberately flat theme: no ink splashes, no surface tints, no
    // elevation shadows — all of which ghost or smudge on e-ink.
    final base = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: kPaper,
      useMaterial3: true,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values) p: const _InstantPageTransitions(),
      }),
      colorScheme: const ColorScheme.light(
        primary: kInk,
        surface: kPaper,
        surfaceTint: Colors.transparent,
      ),
      iconTheme: const IconThemeData(color: kInk),
      appBarTheme: const AppBarTheme(
        backgroundColor: kPaper,
        foregroundColor: kInk,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'Crimson Pro')),
      home: const RootScreen(),
    );
  }
}

/// Decides the first screen: the setup wizard until a Bible has been "printed",
/// then the reader.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  bool _hasBible = !LibraryStore.isEmpty;

  @override
  Widget build(BuildContext context) {
    if (_hasBible) return const BibleReaderScreen();
    return UiScaled(
      child: SetupWizard(onComplete: () async {
        await DrawingStore.useBible(LibraryStore.active.id);
        if (mounted) setState(() => _hasBible = true);
      }),
    );
  }
}

enum PenTool { pen, eraser }

/// A Boox-style pen preset. The native side uses [nativeStyle] to render the
/// live preview; [widthScale] biases each preset's nib (e.g. the brush sits a
/// little wider than the ballpoint).
class PenPreset {
  final String id;
  final String label;
  final IconData icon;
  final OnyxStrokeStyle nativeStyle;
  final double widthScale;

  const PenPreset({
    required this.id,
    required this.label,
    required this.icon,
    required this.nativeStyle,
    this.widthScale = 1.0,
  });
}

const List<PenPreset> kPenPresets = [
  PenPreset(
    id: 'ballpoint',
    label: 'Ballpoint',
    icon: Icons.edit, // pencil-like
    nativeStyle: OnyxStrokeStyle.pen, // uniform: no fattening
  ),
  PenPreset(
    id: 'fountain',
    label: 'Fountain',
    icon: Icons.create,
    nativeStyle: OnyxStrokeStyle.fountainPen,
    widthScale: 1.2,
  ),
  PenPreset(
    id: 'brush',
    label: 'Brush',
    icon: Icons.brush,
    nativeStyle: OnyxStrokeStyle.brush,
    widthScale: 1.5,
  ),
  PenPreset(
    id: 'pencil',
    label: 'Pencil',
    icon: Icons.draw,
    nativeStyle: OnyxStrokeStyle.pencil,
  ),
  PenPreset(
    id: 'marker',
    label: 'Marker',
    icon: Icons.format_paint,
    nativeStyle: OnyxStrokeStyle.marker,
    widthScale: 2.0,
  ),
];

/// The panel's true density in dots per inch, read from the pen plugin at
/// startup, or null where the platform won't say. Flutter's devicePixelRatio is
/// measured against a 160dpi baseline and understates an e-ink panel's real dot
/// pitch badly, so a nib size quoted from it would be fiction.
double? gDisplayDpi;

/// A nib width in millimetres on this panel, or null if the density is unknown
/// (the raw size is shown instead of a made-up measurement).
double? nibMillimetres(double logicalPx, double dpr) {
  final dpi = gDisplayDpi;
  if (dpi == null || dpi <= 1) return null;
  return logicalPx * dpr / dpi * 25.4;
}

/// The shades of ink worth offering. The panel is greyscale, so these are the
/// only distinctions that actually survive to the page — every other colour
/// would come back as one of them anyway.
class InkShade {
  final String id;
  final String label;
  final Color color;

  const InkShade(this.id, this.label, this.color);
}

const List<InkShade> kInkShades = [
  InkShade('black', 'Black', Color(0xFF000000)),
  InkShade('grey', 'Grey', Color(0xFF666666)),
  InkShade('light', 'Light grey', Color(0xFFA5A5A5)),
];

InkShade inkShadeById(String id) =>
    kInkShades.firstWhere((s) => s.id == id, orElse: () => kInkShades.first);

/// How a pen renders its committed ink. Width is the nib size modulated by
/// stylus pressure between [lo] (light touch) and [hi] (hard press), giving the
/// Boox-notetaker "weight" feel.
///
/// [hi] is 1.0 for every pen on purpose: full pressure paints exactly the nib
/// the native overlay was told to draw with, so pressure can only ever thin a
/// line, never fatten it. That is what stops a hairline turning into a fat
/// stroke a second later when the e-ink refresh swaps the native preview for
/// this rendering.
class PenRecipe {
  final double lo; // width multiplier at the light end of the range
  final double hi; // width multiplier at the heavy end (never above 1.0)
  final bool taperEnds; // ramp width down over the first/last few points
  final StrokeCap cap;
  final double opacity; // applied to the stroke colour (marker = translucent)

  /// How much of the width range speed drives, versus pressure (0 = pressure
  /// only, 1 = speed only). A brush is mostly a speed instrument: it fattens
  /// when the hand slows and thins on a quick flick. Relying on pressure alone
  /// makes a stroke dead uniform whenever the stylus reports little of it,
  /// which is exactly what "normalised" looks like.
  final double speed;

  /// Graphite tooth. Above zero the stroke is painted as a faint body with
  /// scattered grain on top rather than as an even film — see [_paintPencil].
  final double grain;

  const PenRecipe({
    this.lo = 0.9,
    this.hi = 1.0,
    this.taperEnds = false,
    this.cap = StrokeCap.round,
    this.opacity = 1.0,
    this.speed = 0.0,
    this.grain = 0.0,
  });
}

const Map<String, PenRecipe> _kPenRecipes = {
  // Near-uniform — a dependable everyday line.
  'ballpoint': PenRecipe(lo: 0.92),
  // A real nib: responds to how hard you press AND how fast you move.
  'fountain': PenRecipe(lo: 0.42, taperEnds: true, speed: 0.4),
  // Widest range, and mostly speed-driven — the loaded brush drags when the
  // hand slows and runs dry on a flick.
  'brush': PenRecipe(lo: 0.22, taperEnds: true, speed: 0.6),
  // Graphite: a modest width range and a lot of tooth.
  'pencil': PenRecipe(lo: 0.62, opacity: 0.95, speed: 0.35, grain: 1.0),
  // Highlighter: flat, wide, translucent; pressure- and speed-independent.
  'marker': PenRecipe(lo: 1.0, cap: StrokeCap.butt, opacity: 0.32),
};

/// Sample spacing (in capture pixels) that counts as a fast stroke. The stylus
/// reports at a steady rate, so how far apart two samples landed is how fast
/// the hand was moving between them — no timestamp needed, which means notes
/// written before any of this get the same treatment when they're redrawn.
const double _kSpeedRef = 9.0;

/// Per-point speed, smoothed. Raw sample spacing is jittery and a nib does not
/// flicker in width; a short moving average turns it into the kind of slow
/// swell a hand actually produces.
List<double> _speedProfile(List<Offset> p) {
  final n = p.length;
  final raw = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    raw[i] = (p[i] - p[i - 1]).distance;
  }
  if (n > 1) raw[0] = raw[1];

  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    var count = 0;
    for (var k = i - 2; k <= i + 2; k++) {
      if (k < 0 || k >= n) continue;
      sum += raw[k];
      count++;
    }
    out[i] = sum / count;
  }
  return out;
}

/// Deterministic value noise in 0..1. Deterministic matters: the grain is
/// hashed from the stroke's own coordinates, so a stroke grains identically on
/// every repaint and after a reload. Random grain would crawl on each refresh.
double _noise(int i, int seed) {
  var h = (i * 374761393 + seed * 668265263) & 0x7fffffff;
  h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff;
  return ((h ^ (h >> 16)) & 0xffff) / 65535.0;
}

PenRecipe penRecipeFor(String id) =>
    _kPenRecipes[id] ?? _kPenRecipes['ballpoint']!;

/// A unit vector along [v] (falls back to +x for a degenerate segment).
Offset _unit(Offset v) {
  final d = v.distance;
  return d < 1e-6 ? const Offset(1, 0) : v / d;
}

/// A smooth path through [p], curving through each point via the midpoints of
/// its segments. A polyline traces the same points but keeps every sampling
/// corner; this reads as a written line instead of a chain of straight bits.
Path _smoothPath(List<Offset> p) {
  final path = Path()..moveTo(p.first.dx, p.first.dy);
  if (p.length == 2) {
    path.lineTo(p[1].dx, p[1].dy);
    return path;
  }
  for (var i = 1; i < p.length - 1; i++) {
    final mid = (p[i] + p[i + 1]) / 2;
    path.quadraticBezierTo(p[i].dx, p[i].dy, mid.dx, mid.dy);
  }
  path.lineTo(p.last.dx, p.last.dy);
  return path;
}

/// The outline of a variable-width stroke: one side out, the other side back.
/// Filling this makes the width change continuously along the line instead of
/// stepping at every sample, which is what a real nib does.
Path _ribbonPath(List<Offset> p, List<double> w) {
  final n = p.length;
  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < n; i++) {
    // Average the incoming and outgoing directions so the outline turns
    // smoothly through corners rather than pinching.
    final Offset d;
    if (i == 0) {
      d = p[1] - p[0];
    } else if (i == n - 1) {
      d = p[n - 1] - p[n - 2];
    } else {
      d = _unit(p[i] - p[i - 1]) + _unit(p[i + 1] - p[i]);
    }
    final u = _unit(d);
    final offset = Offset(-u.dy, u.dx) * (w[i] / 2);
    left.add(p[i] + offset);
    right.add(p[i] - offset);
  }
  final path = _smoothPath(left);
  // extendWithPath joins the two sides with a straight line across the far tip.
  path.extendWithPath(_smoothPath(right.reversed.toList()), Offset.zero);
  path.close();
  return path;
}

/// Graphite on paper: a faint body with tooth scattered over it.
///
/// A pencil lays down no even film — the graphite catches on the paper's grain
/// and skips, and it is that broken texture, not the line itself, that reads as
/// "pencil". Painting it as a solid stroke is what makes a committed pencil
/// mark look like a tracing of the one you drew rather than the thing itself.
///
/// The grain is accumulated into three paths (one per darkness) and filled
/// three times, rather than drawn dot by dot — a long stroke can carry a
/// thousand specks, and a thousand draw calls per stroke per repaint would not
/// survive a page of notes.
void _paintPencil(
    Canvas canvas, List<Offset> p, List<double> w, Color color) {
  var mean = 0.0;
  for (final x in w) {
    mean += x;
  }
  mean /= w.length;

  var length = 0.0;
  for (var i = 1; i < p.length; i++) {
    length += (p[i] - p[i - 1]).distance;
  }

  // Grain spacing scales with the nib, so a broad pencil is not simply the
  // same speckle stretched. Widened if a stroke would otherwise carry more
  // specks than is worth drawing.
  var step = math.max(0.9, mean * 0.42);
  const maxSpecks = 900;
  if (length / step > maxSpecks) step = length / maxSpecks;

  final seed = ((p.first.dx * 7.31 + p.first.dy * 3.17).abs() * 64).round();
  final alpha = color.a;

  // The body carries the line's continuity; the grain carries its weight.
  canvas.drawPath(
    _smoothPath(p),
    Paint()
      ..color = color.withValues(alpha: alpha * 0.34)
      ..style = PaintingStyle.stroke
      ..strokeWidth = mean * 0.82
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true,
  );

  const tiers = [0.28, 0.5, 0.78];
  final paths = [Path(), Path(), Path()];
  var carry = 0.0;
  var speck = 0;

  for (var i = 1; i < p.length; i++) {
    final a = p[i - 1];
    final seg = (p[i] - a).distance;
    if (seg <= 0) continue;
    final dir = (p[i] - a) / seg;
    final normal = Offset(-dir.dy, dir.dx);

    var t = carry;
    while (t < seg) {
      final n1 = _noise(speck, seed);
      final n2 = _noise(speck + 977, seed);
      final n3 = _noise(speck + 5081, seed);
      speck++;
      final at = a + dir * t;
      final width = w[i - 1] + (w[i] - w[i - 1]) * (t / seg);
      t += step * (0.55 + 0.9 * n3);

      // Skipped specks are the point: paper tooth means the graphite misses.
      if (n1 < 0.17) continue;

      final centre = at + normal * ((n2 - 0.5) * width * 0.95);
      final radius = width * (0.15 + 0.22 * n1);
      paths[(n1 * 3).floor().clamp(0, 2)]
          .addOval(Rect.fromCircle(center: centre, radius: radius));
    }
    carry = t - seg;
  }

  for (var k = 0; k < 3; k++) {
    canvas.drawPath(
      paths[k],
      Paint()
        ..color = color.withValues(alpha: (alpha * tiers[k]).clamp(0.0, 1.0))
        ..isAntiAlias = true,
    );
  }
}

/// Paints one stroke as a single continuous shape.
///
/// Two things make committed ink read like the native Boox overlay rather than
/// a redraw of it:
///
///  * **Anti-aliasing is ON.** Boox panels are 16-level greyscale, so a soft
///    edge resolves to genuine intermediate greys — the "ink soaked into the
///    paper" look of the stock Notes app. Hard-edged lines are precisely what
///    reads as pixelated.
///  * **One path, not one call per segment.** Drawing each segment on its own
///    re-rasterises every join (visible lumps, and doubled darkness where a
///    translucent marker overlaps itself). A single smoothed path is
///    rasterised once, end to end.
///
/// [dpr] is the device pixel ratio: no line is ever painted thinner than one
/// physical panel pixel, so a hairline stays a hairline instead of fading out.
void _paintStroke(Canvas canvas, Stroke stroke, Size size, double dpr,
    {bool live = false}) {
  final pts = stroke.points;
  if (pts.isEmpty) return;

  // Map capture-time coordinates onto the current canvas (1:1 for unchanged
  // layouts and legacy strokes).
  final (sx, sy) = stroke.scaleTo(size);

  final recipe = penRecipeFor(stroke.style);
  final base = stroke.width;
  final color = recipe.opacity >= 1.0
      ? stroke.color
      : stroke.color.withValues(alpha: recipe.opacity);
  final minWidth = 1.0 / (dpr > 0 ? dpr : 1.0);

  // Drop coincident samples: a zero-length segment has no direction, so it
  // would put a spike in the outline.
  final p = <Offset>[];
  final pressures = <double>[];
  for (final sp in pts) {
    final o = Offset(sp.x * sx, sp.y * sy);
    if (p.isNotEmpty && (o - p.last).distanceSquared < 0.01) continue;
    p.add(o);
    pressures.add(sp.pressure);
  }

  final n = p.length;
  final speeds = recipe.speed > 0 ? _speedProfile(p) : null;
  final w = List<double>.generate(n, (i) {
    final pr = pressures[i];
    // A negative pressure means the stylus reports none worth using. Treat it
    // as a full press rather than inventing a weight the writer never applied
    // — with speed in the mix the line still breathes.
    final pressed = pr < 0 ? 1.0 : pr.clamp(0.0, 1.0);
    var weight = pressed;
    if (speeds != null) {
      final slow = 1.0 - (speeds[i] / _kSpeedRef).clamp(0.0, 1.0);
      weight = pressed * (1 - recipe.speed) + slow * recipe.speed;
    }
    var f = recipe.lo + (recipe.hi - recipe.lo) * weight;
    if (recipe.taperEnds && n > 8) {
      final edge = math.min(i, n - 1 - i);
      if (edge < 4) f *= 0.6 + 0.1 * edge; // ease the line in and out
    }
    return math.max(minWidth, base * f);
  });

  final paint = Paint()
    ..color = color
    ..isAntiAlias = true;

  if (n == 1) {
    canvas.drawCircle(p.first, w.first / 2, paint..style = PaintingStyle.fill);
    return;
  }

  // Grain is skipped for the stroke still under the nib. Rebuilding a
  // thousand specks on every pointer move would make a long line crawl, and on
  // a Boox the native overlay is drawing the live stroke anyway — this layer
  // is only what the mark settles into.
  if (recipe.grain > 0 && !live) {
    _paintPencil(canvas, p, w, color);
    return;
  }

  var lo = w.first, hi = w.first;
  for (final x in w) {
    lo = math.min(lo, x);
    hi = math.max(hi, x);
  }

  // A near-uniform nib strokes a single path: crisper than a filled outline at
  // hairline widths, and cheaper to raster.
  if (hi - lo < 0.25) {
    canvas.drawPath(
      _smoothPath(p),
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = (lo + hi) / 2
        ..strokeCap = recipe.cap
        ..strokeJoin = StrokeJoin.round,
    );
    return;
  }

  canvas.drawPath(_ribbonPath(p, w), paint..style = PaintingStyle.fill);
  if (recipe.cap != StrokeCap.butt) {
    // Round off the ends. Only opaque pens get here (the translucent marker is
    // butt-capped), so overdrawing the tips can't darken them.
    canvas.drawCircle(p.first, w.first / 2, paint);
    canvas.drawCircle(p.last, w.last / 2, paint);
  }
}

class BibleReaderScreen extends StatefulWidget {
  const BibleReaderScreen({super.key});

  @override
  State<BibleReaderScreen> createState() => _BibleReaderScreenState();
}

class _BibleReaderScreenState extends State<BibleReaderScreen>
    with WidgetsBindingObserver {
  // Initialized from persisted settings in initState (resume last position).
  late String _book;
  late int _chapter;

  // Scripture comes from the bundled (offline) translation by default; other
  // translations can be swapped in via the registry without touching this code.
  late ScriptureSource _source;

  List<Verse> _verses = [];
  bool _isLoading = true;
  bool _hasError = false;

  // Opens the left menu drawer from the burger button.
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Drawing tools. The nib is a continuous size, not a set of steps — a pen is
  // chosen by how thick you want the line, and the sizes worth writing at on a
  // 300dpi panel are far closer together than six buttons can express.
  double _nib = 1.5;
  int _presetIndex = 0; // ballpoint — uniform, matches commit no-fattening
  int _shadeIndex = 0; // black
  PenTool _tool = PenTool.pen;

  PenPreset get _preset => kPenPresets[_presetIndex];
  // Effective width: nib size scaled by the preset's bias.
  double get _penWidth => _nib * _preset.widthScale;
  InkShade get _shade => kInkShades[_shadeIndex];
  bool get _isEraser => _tool == PenTool.eraser;

  // The printed Bible whose locked layout this reader renders.
  late BibleConfig _cfg;
  TextStyle get _verseStyle => verseStyleForCfg(_cfg);
  double get _marginFraction =>
      kMarginFractions[_cfg.marginIndex.clamp(0, kMarginFractions.length - 1)];

  // Paging.
  final PageController _pageController = PageController();
  int _page = 0;
  int _pageCount = 1;

  // Asks the panel for a clean sweep once the new content is on screen. A GC
  // refresh shows whatever is in the framebuffer at the moment it runs, so it
  // has to come after the frame, never before it.
  void _refreshPanelAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(OnyxSdkPenArea.forceRefresh());
    });
  }

  // When navigating from search to a specific verse, the page containing it is
  // selected after pagination; consumed (set to null) once applied.
  int? _targetVerse;

  // Non-null while reading inside a plan (drives plan-order navigation + the
  // banner + auto-complete). Cleared by any manual navigation.
  PlanSession? _session;

  // Whether the pen panel — nib slider, textures, ink shades — is open
  // (toggled by tapping the already-selected pen a second time).
  bool _showPenPanel = false;

  // Palm rejection: when on, finger touches are ignored so a resting hand can't
  // flip the page; the page is turned with the on-bar arrows instead. Persisted.
  bool _ignoreTouch = SettingsStore.value.ignoreTouch;

  // Chrome scale (toolbar/menus), recomputed each build from screen size or the
  // user's Interface-size choice. 1.0 on phones; larger on big e-ink panels.
  double _ui = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyActiveBible();
    _nib = SettingsStore.value.penWidth
        .clamp(kMinPenWidth, kMaxPenWidth)
        .toDouble();
    _shadeIndex = kInkShades
        .indexWhere((s) => s.id == SettingsStore.value.inkShade)
        .clamp(0, kInkShades.length - 1);
    _loadChapter();
    // If any store had to recover from a .bak on load, tell the user once.
    if (gDataRecovered) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        gDataRecovered = false;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Some saved data was restored from a backup copy.'),
          duration: Duration(seconds: 4),
        ));
      });
    }
  }

  // Adopt the active printed Bible's locked layout + reading position.
  void _applyActiveBible() {
    _cfg = LibraryStore.active;
    _book = _cfg.lastBook;
    _chapter = _cfg.lastChapter;
    _source = sourceFor(translationById(_cfg.translationId));
    // Book names follow the Bible in hand: a Spanish Bible reads "Génesis".
    followCanonLanguage(_cfg.translationId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding/closing: make any pending notes + settings durable now.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(DrawingStore.flushNow());
      unawaited(SettingsStore.flushNow());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  void _persist() {
    // Reading position lives on the (otherwise locked) Bible; stroke width and
    // palm rejection are global tool preferences, not part of the printed layout.
    LibraryStore.rememberPosition(_book, _chapter);
    SettingsStore.update(SettingsStore.value.copyWith(
        penWidth: _nib, inkShade: _shade.id, ignoreTouch: _ignoreTouch));
  }

  Future<void> _loadChapter() async {
    // Undo history is scoped to the chapter being read.
    kUndo.clear();
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    // Capture the request so a slow load that's been superseded by a newer
    // navigation doesn't overwrite the screen with stale verses.
    final book = _book;
    final chapter = _chapter;
    try {
      final verses = await _source.chapter(book, chapter);
      if (!mounted || book != _book || chapter != _chapter) return;
      _applyVerses(verses);
    } catch (_) {
      if (!mounted || book != _book || chapter != _chapter) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  void _applyVerses(List<Verse> verses) {
    if (!mounted) return;
    // A chapter change replaces the whole layout — always clear ghosting.
    _turnsSinceGc = 0;
    setState(() {
      _verses = verses;
      _isLoading = false;
      _hasError = false;
      _page = 0;
    });
    _refreshPanelAfterFrame();
    // If a search target is pending, the page is chosen during build instead.
    if (_targetVerse == null) _resetToFirstPage();
  }

  void _resetToFirstPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) _pageController.jumpToPage(0);
    });
  }

  // A full e-ink refresh, on the app's terms. This DOES take any raw ink the
  // SDK is still showing with it, replacing it with the app's own rendering —
  // so it belongs to moments when the page is changing anyway, never to the
  // seconds right after a stroke.
  void _forceRefresh() {
    _turnsSinceGc = 0;
    setState(() {});
    _refreshPanelAfterFrame();
  }

  /// "GENESIS 4:1–26" — the verse span a page carries, as books print it.
  String _runningHeader(List<Verse> page) {
    final first = page.first.number;
    final last = page.last.number;
    final range = first == last ? '$first' : '$first–$last';
    final name = bookLabel(_book, CanonLanguage.code).toUpperCase();
    return '$name $_chapter:$range';
  }

  // E-ink refresh discipline: a full (GC) refresh flashes the panel black,
  // which is the single most annoying thing an e-ink app can do on every page
  // turn. Like a Kindle, we let partial updates carry a handful of turns and
  // only flash periodically to clear accumulated ghosting. Chapter changes and
  // the manual refresh button always flash (the whole layout changed).
  static const int _gcEveryNTurns = 6;
  int _turnsSinceGc = 0;

  void _pageTurned(int i) {
    setState(() => _page = i);
    _turnsSinceGc++;
    if (_turnsSinceGc >= _gcEveryNTurns) _forceRefresh();
  }

  // --- Navigation ---------------------------------------------------------

  // Manual chapter navigation exits any reading-plan session (keepSession only
  // set when the plan itself is advancing).
  void _goToChapter(String book, int chapter, {bool keepSession = false}) {
    if (!keepSession) _session = null;
    setState(() {
      _book = book;
      _chapter = chapter;
    });
    _persist();
    _loadChapter();
  }

  void _nextChapter() {
    final n = nextChapterOf(_book, _chapter);
    if (n != null) _goToChapter(n.$1, n.$2);
  }

  void _prevChapter() {
    final p = prevChapterOf(_book, _chapter);
    if (p != null) _goToChapter(p.$1, p.$2);
  }

  void _nextPage() {
    if (_page < _pageCount - 1) {
      _pageController.jumpToPage(_page + 1);
    } else if (_session != null) {
      _planForward();
    } else {
      _nextChapter();
    }
  }

  void _prevPage() {
    if (_page > 0) {
      _pageController.jumpToPage(_page - 1);
    } else if (_session != null) {
      _planBack();
    } else {
      _prevChapter();
    }
  }

  // --- Reading-plan session -----------------------------------------------

  void _startPlanSession(PlanSession s) {
    setState(() => _session = s);
    _openSessionPassage(s);
  }

  void _openSessionPassage(PlanSession s) {
    final ref = s.current;
    _targetVerse = ref.verse;
    _goToChapter(ref.book, ref.chapter, keepSession: true);
  }

  // Finished the current passage's last page → next passage, or finish the day.
  void _planForward() {
    final s = _session!;
    if (!s.atDayEnd) {
      final next = s.withCursor(s.cursor + 1);
      setState(() => _session = next);
      _openSessionPassage(next);
      return;
    }
    // Day complete → auto-mark and move to the next day.
    final ps = PlanStore.active;
    if (ps != null && ps.id == s.plan.id && s.dayIndex == ps.completedCount) {
      PlanStore.completeCurrent();
    }
    if (!s.isLastDay) {
      final next = s.nextDay();
      setState(() => _session = next);
      _openSessionPassage(next);
    } else {
      setState(() => _session = null); // plan finished
      _forceRefresh();
    }
  }

  void _planBack() {
    final s = _session!;
    if (!s.atDayStart) {
      final prev = s.withCursor(s.cursor - 1);
      setState(() => _session = prev);
      _openSessionPassage(prev);
    } else if (s.dayIndex > 0) {
      final prev = s.prevDay();
      setState(() => _session = prev);
      _openSessionPassage(prev);
    }
  }

  Future<void> _openPicker() async {
    final ref = await Navigator.of(context).push<BibleRef>(
      MaterialPageRoute(
        builder: (_) => UiScaled(
          child: BookPickerScreen(currentBook: _book, currentChapter: _chapter),
        ),
      ),
    );
    if (ref == null) return;
    if (ref.verse != null) _targetVerse = ref.verse; // jump to an annotated verse
    _goToChapter(ref.book, ref.chapter);
  }

  // Pushes a screen that may pop a BibleRef (search/notes/plans); on return,
  // navigates the reader there.
  Future<void> _openScreen(Widget screen) async {
    final ref = await Navigator.of(context).push<BibleRef>(
      MaterialPageRoute(builder: (_) => UiScaled(child: screen)),
    );
    if (ref == null) return;
    _targetVerse = ref.verse;
    _goToChapter(ref.book, ref.chapter);
  }

  // The burger opens a Drawer from the LEFT — where the button is — instead of
  // sliding up from the bottom.
  void _openMenu() => _scaffoldKey.currentState?.openDrawer();

  static const List<(String, IconData, String)> _menuItems = [
    ('search', Icons.search, 'Search'),
    ('plans', Icons.event_note, 'Reading plans'),
    ('notes', Icons.gesture, 'My notes'),
    ('library', Icons.auto_stories_outlined, 'My Bibles'),
    ('uisize', Icons.format_size, 'Interface size'),
    ('about', Icons.info_outline, 'About'),
  ];

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: kPaper,
      width: 304 * _ui, // grow with the chrome scale on big panels
      shape: const RoundedRectangleBorder(), // flat edge, no e-ink-unfriendly radius
      child: SafeArea(
        child: Builder(
          builder: (ctx) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(20 * _ui, 20 * _ui, 20, 12 * _ui),
                child: Text(kAppName,
                    style: kTitleStyle(22 * _ui, weight: FontWeight.w700)),
              ),
              const Divider(height: 1, color: kDisabled),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final item in _menuItems)
                      ListTile(
                        leading: Icon(item.$2, color: kInk, size: 24 * _ui),
                        title: Text(item.$3, style: kTitleStyle(18 * _ui)),
                        onTap: () {
                          Navigator.of(ctx).pop(); // close the drawer first
                          _menuAction(item.$1);
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menuAction(String action) async {
    switch (action) {
      case 'search':
        await _openScreen(SearchScreen(translationId: _source.translationId));
      case 'plans':
        await _openPlans();
      case 'notes':
        await _openScreen(const NotesBrowserScreen());
      case 'library':
        await _openLibrary();
      case 'uisize':
        await _openUiSizePicker();
      case 'about':
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const UiScaled(child: AboutScreen())));
    }
  }

  // Interface size is a centred dialog (spatially neutral), not another bottom
  // sheet — handy on big Boox panels where the device under-reports its density.
  Future<void> _openUiSizePicker() async {
    final current = SettingsStore.value.uiSizeIndex
        .clamp(0, kUiSizeLabels.length - 1)
        .toInt();
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: kPaper,
        title: Text('Interface size', style: kTitleStyle(18 * _ui)),
        children: [
          for (var i = 0; i < kUiSizeLabels.length; i++)
            ListTile(
              leading: Icon(i == current ? Icons.check : Icons.format_size,
                  color: i == current ? kInk : kMuted, size: 24 * _ui),
              title: Text(kUiSizeLabels[i], style: kTitleStyle(18 * _ui)),
              onTap: () => Navigator.of(context).pop(i),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    SettingsStore.update(SettingsStore.value.copyWith(uiSizeIndex: picked));
    setState(() {}); // rebuild so _ui picks up the new choice
  }

  // Plans can pop either a PlanSession (start reading the plan) or a BibleRef.
  Future<void> _openPlans() async {
    final result = await Navigator.of(context)
        .push<Object>(MaterialPageRoute(
            builder: (_) => const UiScaled(child: PlansScreen())));
    if (!mounted || result == null) return;
    if (result is PlanSession) {
      _startPlanSession(result);
    } else if (result is BibleRef) {
      _targetVerse = result.verse;
      _goToChapter(result.book, result.chapter);
    }
  }

  Future<void> _openLibrary() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const UiScaled(child: LibraryScreen())),
    );
    if (changed == true && mounted) await _switchToActiveBible();
  }

  // Re-open the reader on whichever Bible is now active (after a switch or a new
  // print): its notes, translation, layout and reading position all change.
  Future<void> _switchToActiveBible() async {
    await DrawingStore.useBible(LibraryStore.active.id);
    kUndo.clear();
    setState(() {
      _applyActiveBible();
      _page = 0;
    });
    _loadChapter();
  }

  // --- Pagination ---------------------------------------------------------
  //
  // [textWidth] is the width available to the verse *text* (content minus the
  // number gutter). The first page reserves space for the chapter header.

  List<List<Verse>> _paginate(List<Verse> verses, TextStyle verseStyle,
      double textWidth, double availableHeight, double headerReserve) {
    if (verses.isEmpty) return const [];

    final key = '${_cfg.id}_${_book}_${_chapter}_'
        '${textWidth.round()}x${availableHeight.round()}';
    final cached = PageCache.get(key);
    if (cached != null) return cached;

    final List<List<Verse>> result = [];
    List<Verse> current = [];
    double h = 0;

    final painter = TextPainter(textDirection: TextDirection.ltr);
    for (final v in verses) {
      // The SAME span VerseText renders — a drop cap grows the first line, and
      // measuring anything else would drift the page breaks.
      painter.text = verseSpan(v.text, verseStyle,
          dropCap: _cfg.dropCaps && v.number == 1);
      painter.layout(maxWidth: textWidth);
      final vh = painter.height + kVerseSpacing;

      // The first page is shorter when a chapter header sits on top.
      final cap =
          result.isEmpty ? availableHeight - headerReserve : availableHeight;

      if (h + vh > cap && current.isNotEmpty) {
        result.add(current);
        current = [v];
        h = vh;
      } else {
        current.add(v);
        h += vh;
      }
    }
    if (current.isNotEmpty) result.add(current);

    PageCache.put(key, result);
    return result;
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Cap the chrome scale by the available width so the unified bar (whose
    // fixed contents need ~800 logical px at scale 1) can never overflow on a
    // narrow/portrait panel — it shrinks gracefully instead of striping.
    final width = MediaQuery.of(context).size.width;
    _ui = math.min(
        uiScaleFor(context), (width / 800).clamp(0.7, double.infinity));
    return Scaffold(
      key: _scaffoldKey,
      drawerEnableOpenDragGesture: false, // don't fight edge finger page-turns
      drawer: _buildDrawer(),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildUnifiedBar(),
            // The pen-capture area is ONLY the page, so native ink can't land
            // on the toolbar. Canvas takes all remaining height — no bottom bar.
            // The nib row FLOATS over the top of the canvas (a Stack overlay)
            // rather than a Column child, so toggling it never changes the
            // canvas height or reflows the page mid-write.
            Expanded(
              child: Stack(
                children: [
                  OnyxSdkPenArea(
                    // OFF on purpose. The SDK used to wipe the panel ~1.2s
                    // after every stroke so the app could redraw the same mark
                    // itself — and that swap is exactly the "it changed by
                    // itself" that makes writing feel wrong, because the app's
                    // rendering is never quite the SDK's. The ink now stays
                    // where the pen put it; ghosting is cleared on page turns
                    // and by the refresh button instead (_forceRefresh).
                    refreshDelay: Duration.zero,
                    // Active pen preset chooses the native style, so the live
                    // overlay and the committed Flutter stroke are the same nib.
                    strokeStyle: _preset.nativeStyle,
                    strokeColor: _isEraser ? Colors.white : _shade.color,
                    // The SDK measures its nib in panel pixels while nib sizes
                    // here are logical; converting keeps the live preview and
                    // the committed stroke the same physical thickness (a no-op
                    // on the many Boox panels that report a 1.0 ratio).
                    strokeWidth: _penWidth * MediaQuery.devicePixelRatioOf(context),
                    child: _buildBody(),
                  ),
                  if (_showPenPanel)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: _buildPenPanel(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Single unified bar — menu, chapter title, plan day (when active), undo/redo,
  // all 5 pen presets + eraser, refresh. Tapping an already-selected pen a
  // second time reveals the on-demand nib-size row below. No separate pen rail;
  // no bottom navigation bar — the canvas takes all remaining height.
  Widget _buildUnifiedBar() {
    return Container(
      height: 52 * _ui,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDisabled, width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Menu',
            icon: Icon(Icons.menu, color: kInk, size: 24 * _ui),
            onPressed: _openMenu,
          ),
          Flexible(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openPicker,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                        '${bookLabel(_book, CanonLanguage.code)} $_chapter',
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: kTitleStyle(18 * _ui)),
                  ),
                  SizedBox(width: 2 * _ui),
                  Icon(Icons.expand_more, size: 16 * _ui, color: kMuted),
                ],
              ),
            ),
          ),
          if (_session != null) ...[
            SizedBox(width: 6 * _ui),
            // One compact pill with a proper (>=40px) hit area; tapping leaves
            // the plan. A single element, so it can't crowd the title into a
            // tiny × the way two separate glyphs did.
            Tooltip(
              message: 'Leave plan',
              child: InkWell(
                onTap: () => setState(() => _session = null),
                borderRadius: BorderRadius.circular(20 * _ui),
                child: Container(
                  constraints: BoxConstraints(minHeight: 40 * _ui),
                  padding: EdgeInsets.symmetric(horizontal: 10 * _ui),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Day ${_session!.dayIndex + 1}/${_session!.plan.length}',
                        style: crimson(
                            fontSize: 13 * _ui,
                            color: kInk,
                            fontWeight: FontWeight.w600),
                      ),
                      SizedBox(width: 6 * _ui),
                      Icon(Icons.close, size: 15 * _ui, color: kMuted),
                    ],
                  ),
                ),
              ),
            ),
          ],
          // Page arrows are always present (a button alternative to the
          // finger edge-taps), so toggling palm rejection never reflows the bar.
          SizedBox(width: 4 * _ui),
          IconButton(
            tooltip: 'Previous page',
            icon: Icon(Icons.chevron_left, size: 24 * _ui),
            color: kInk,
            onPressed: _prevPage,
          ),
          IconButton(
            tooltip: 'Next page',
            icon: Icon(Icons.chevron_right, size: 24 * _ui),
            color: kInk,
            onPressed: _nextPage,
          ),
          const Spacer(),
          ValueListenableBuilder<bool>(
            valueListenable: kUndo.canUndo,
            builder: (context, can, _) => IconButton(
              tooltip: 'Undo',
              icon: Icon(Icons.undo, size: 22 * _ui),
              color: kInk,
              disabledColor: kDisabled,
              onPressed: can ? () => kUndo.undo() : null,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: kUndo.canRedo,
            builder: (context, can, _) => IconButton(
              tooltip: 'Redo',
              icon: Icon(Icons.redo, size: 22 * _ui),
              color: kInk,
              disabledColor: kDisabled,
              onPressed: can ? () => kUndo.redo() : null,
            ),
          ),
          for (var i = 0; i < kPenPresets.length; i++)
            _railTool(
              icon: kPenPresets[i].icon,
              tooltip: kPenPresets[i].label,
              selected: !_isEraser && _presetIndex == i,
              onTap: () => setState(() {
                if (!_isEraser && _presetIndex == i) {
                  // Second tap on the active pen opens its settings.
                  _showPenPanel = !_showPenPanel;
                } else {
                  _presetIndex = i;
                  _tool = PenTool.pen;
                  _showPenPanel = false;
                }
              }),
            ),
          _railTool(
            icon: Icons.cleaning_services_outlined,
            tooltip: 'Eraser',
            selected: _isEraser,
            onTap: () => setState(() {
              _tool = _isEraser ? PenTool.pen : PenTool.eraser;
              _showPenPanel = false;
            }),
          ),
          // Palm rejection toggle: a crossed-out hand when finger touch is off.
          // Selected (underlined) = touches ignored, only the pen is recognised.
          _railTool(
            icon: _ignoreTouch
                ? Icons.do_not_touch_outlined
                : Icons.back_hand_outlined,
            tooltip: _ignoreTouch ? 'Touch off (pen only)' : 'Ignore touch',
            selected: _ignoreTouch,
            onTap: () => setState(() {
              _ignoreTouch = !_ignoreTouch;
              _showPenPanel = false;
              _persist();
            }),
          ),
          IconButton(
            tooltip: 'Refresh screen',
            icon: Icon(Icons.autorenew, size: 22 * _ui, color: kInk),
            onPressed: _forceRefresh,
          ),
        ],
      ),
    );
  }

  // The pen, all in one sheet: its texture, the nib width on a continuous
  // slider, and the ink shade. Opened by tapping the active pen a second time,
  // and it STAYS open while you adjust — finding the right line means trying a
  // few, and a panel that closed on every touch would make that a chore.
  Widget _buildPenPanel() {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = math.min(
        560.0 * _ui, MediaQuery.of(context).size.width - 16 * _ui);
    return GestureDetector(
      // Swallow taps: the page underneath turns pages on a finger tap.
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        width: width,
        margin: EdgeInsets.symmetric(horizontal: 8 * _ui),
        padding: EdgeInsets.fromLTRB(18 * _ui, 10 * _ui, 10 * _ui, 14 * _ui),
        decoration: BoxDecoration(
          color: kPaper,
          border: Border.all(color: kInk, width: 1.2),
          borderRadius: BorderRadius.circular(10 * _ui),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${_preset.label} ${_nibLabel(dpr)}',
                      style: kTitleStyle(17 * _ui, weight: FontWeight.w600)),
                ),
                InkResponse(
                  onTap: () => setState(() => _showPenPanel = false),
                  radius: 22 * _ui,
                  child: Padding(
                    padding: EdgeInsets.all(6 * _ui),
                    child: Icon(Icons.close, size: 20 * _ui, color: kMuted),
                  ),
                ),
              ],
            ),
            SizedBox(height: 6 * _ui),
            Row(
              children: [
                for (var i = 0; i < kPenPresets.length; i++) _panelPen(i),
              ],
            ),
            _panelDivider(),
            Row(
              children: [
                Text('Line width',
                    style: crimson(fontSize: 15 * _ui, color: kInk)),
                const Spacer(),
                _nibStep(Icons.chevron_left, -_kNibStep),
                SizedBox(
                  width: 78 * _ui,
                  child: Text(_nibLabel(dpr),
                      textAlign: TextAlign.center,
                      style: crimson(fontSize: 15 * _ui, color: kInk)),
                ),
                _nibStep(Icons.chevron_right, _kNibStep),
              ],
            ),
            SizedBox(height: 2 * _ui),
            WedgeSlider(
              value: (_nib - kMinPenWidth) / (kMaxPenWidth - kMinPenWidth),
              scale: _ui,
              onChanged: (t) => _setNib(
                  kMinPenWidth + t * (kMaxPenWidth - kMinPenWidth),
                  persist: false),
              onChangeEnd: _persist,
            ),
            _panelDivider(),
            Row(
              children: [
                Text('Ink', style: crimson(fontSize: 15 * _ui, color: kInk)),
                const Spacer(),
                for (var i = 0; i < kInkShades.length; i++) _panelShade(i),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // How far the < > buttons move the nib. Fine enough to hunt for a size,
  // coarse enough that the line visibly changes with each press.
  static const double _kNibStep = 0.5;

  /// The nib size as the panel states it: in millimetres where the panel has
  /// told us its real density, otherwise the raw size (never a fake mm figure).
  String _nibLabel(double dpr) {
    final mm = nibMillimetres(_nib, dpr);
    return mm == null
        ? _nib.toStringAsFixed(1)
        : '${mm.toStringAsFixed(2)} mm';
  }

  // Dragging the slider reports continuously; writing the setting on every
  // step would put the whole library file through the disk on one gesture.
  void _setNib(double v, {bool persist = true}) {
    // Snapped to a quarter pixel: finer than the eye can tell apart at this
    // dot pitch, and it keeps one slider drag from asking an e-ink panel for
    // several hundred redraws.
    final next =
        (v.clamp(kMinPenWidth, kMaxPenWidth) * 4).roundToDouble() / 4;
    if ((next - _nib).abs() < 0.001) return;
    setState(() => _nib = next);
    if (persist) _persist();
  }

  Widget _nibStep(IconData icon, double delta) => InkResponse(
        onTap: () => _setNib(_nib + delta),
        radius: 20 * _ui,
        child: Container(
          width: 34 * _ui,
          height: 30 * _ui,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: kMuted, width: 1),
            borderRadius: BorderRadius.circular(5 * _ui),
          ),
          child: Icon(icon, size: 18 * _ui, color: kInk),
        ),
      );

  Widget _panelDivider() => Padding(
        padding: EdgeInsets.symmetric(vertical: 10 * _ui),
        child: Container(height: 1, color: kDisabled),
      );

  // A pen texture. The dot beneath marks the active one — an underline would
  // fight the toolbar's own selection mark right above it.
  Widget _panelPen(int i) {
    final p = kPenPresets[i];
    final selected = !_isEraser && _presetIndex == i;
    return Tooltip(
      message: p.label,
      child: InkResponse(
        onTap: () => setState(() {
          _presetIndex = i;
          _tool = PenTool.pen;
          _persist();
        }),
        radius: 24 * _ui,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 9 * _ui, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(p.icon, size: 26 * _ui, color: selected ? kInk : kMuted),
              SizedBox(height: 5 * _ui),
              _selectedDot(selected),
            ],
          ),
        ),
      ),
    );
  }

  // An ink shade. Only black and two greys: the panel is greyscale, so any
  // other colour would arrive as one of these three anyway.
  Widget _panelShade(int i) {
    final shade = kInkShades[i];
    final selected = !_isEraser && _shadeIndex == i;
    return Tooltip(
      message: shade.label,
      child: InkResponse(
        onTap: () => setState(() {
          _shadeIndex = i;
          _tool = PenTool.pen;
          _persist();
        }),
        radius: 24 * _ui,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 7 * _ui, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28 * _ui,
                height: 28 * _ui,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: shade.color,
                  border: Border.all(color: kInk, width: 1),
                ),
              ),
              SizedBox(height: 5 * _ui),
              _selectedDot(selected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectedDot(bool selected) => Container(
        width: 5 * _ui,
        height: 5 * _ui,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? kInk : Colors.transparent,
        ),
      );

  Widget _railTool({
    required IconData icon,
    required String tooltip,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 26 * _ui,
        child: Container(
          width: 46 * _ui,
          height: 46 * _ui,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? kInk : Colors.transparent,
                width: 2.5 * _ui,
              ),
            ),
          ),
          child: Icon(icon, size: 23 * _ui, color: selected ? kInk : kMuted),
        ),
      ),
    );
  }

  // Kindle-style finger-tap page turning. Wraps any body child with a Listener
  // that catches non-stylus pointer-down events in the left/right 25% of the
  // screen and turns the page. HitTestBehavior.translucent lets the underlying
  // PageInk Listener also receive every event — stylus drawing is unaffected.
  Widget _withFingerPageTurn(Widget child) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (_showPenPanel) setState(() => _showPenPanel = false);
        // Stylus events are for drawing; only finger taps navigate.
        if (e.kind == PointerDeviceKind.stylus ||
            e.kind == PointerDeviceKind.invertedStylus) {
          return;
        }
        // Palm rejection on: ignore finger touches so a resting hand can't flip
        // the page. The on-bar arrows are the way to turn pages instead.
        if (_ignoreTouch) return;
        final w = context.size?.width ?? 0;
        if (e.localPosition.dx < w * 0.25) {
          _prevPage();
        } else if (e.localPosition.dx > w * 0.75) {
          _nextPage();
        }
      },
      child: child,
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return _withFingerPageTurn(
          const QuietLoader());
    }
    if (_hasError) {
      return _withFingerPageTurn(Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 44, color: kMuted),
            const SizedBox(height: 14),
            Text("Couldn't load this chapter.",
                style: kTitleStyle(18, weight: FontWeight.w500)
                    .copyWith(color: kMuted)),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: _loadChapter,
              style: OutlinedButton.styleFrom(
                foregroundColor: kInk,
                side: const BorderSide(color: kInk),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
              ),
              child: const Text('Try again'),
            ),
          ],
        ),
      ));
    }

    return _withFingerPageTurn(LayoutBuilder(
      builder: (context, constraints) {
        final content = math.max(0.0, constraints.maxWidth - kHPadding * 2);
        final m = readingMetricsFor(content,
            marginFraction: _marginFraction,
            showVerseNumbers: _cfg.showVerseNumbers);
        final contentWidth = m.contentWidth;
        final textWidth = m.textWidth;
        final availableHeight = constraints.maxHeight - kPageVPadding.vertical;
        final verseStyle = _verseStyle;
        final headerReserve = _cfg.showHeadings ? kChapterHeaderHeight : 0.0;

        final pages = _paginate(
            _verses, verseStyle, textWidth, availableHeight, headerReserve);
        if (pages.length != _pageCount) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _pageCount = pages.length);
          });
        }

        // Jump to the page holding a search target verse, once.
        if (_targetVerse != null) {
          final tv = _targetVerse!;
          _targetVerse = null;
          var target = 0;
          for (var i = 0; i < pages.length; i++) {
            if (pages[i].any((v) => v.number == tv)) {
              target = i;
              break;
            }
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_pageController.hasClients) return;
            _pageController.jumpToPage(target);
            setState(() => _page = target);
            _forceRefresh();
          });
        }

        return PageView.builder(
          controller: _pageController,
          // Disabled so a horizontal pen stroke can't accidentally turn the
          // page; navigation is via the bottom bar.
          physics: const NeverScrollableScrollPhysics(),
          itemCount: pages.length,
          onPageChanged: _pageTurned,
          itemBuilder: (context, i) {
            final pageKey = '${_book}_$_chapter#$i';
            // Chapter-opening pages already announce themselves via the big
            // chapter header, so the running header would be redundant there.
            final showRunningHeader = i > 0 || !_cfg.showHeadings;
            return Stack(
              fit: StackFit.expand,
              children: [
                // Printed-page furniture, set inside the vertical margins: a
                // running header ("GENESIS 4:1–26") up top and a folio (page
                // number) at the foot — orientation the way a book gives it.
                // Both live under the ink layer: you can write over them.
                if (showRunningHeader && pages[i].isNotEmpty)
                  Positioned(
                    top: 7,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        _runningHeader(pages[i]),
                        style: crimson(
                            fontSize: 11,
                            height: 1.0,
                            letterSpacing: 2,
                            color: kMuted),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 5,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text('${i + 1}',
                        style:
                            crimson(fontSize: 11, height: 1.0, color: kMuted)),
                  ),
                ),
                // Text content (centered column of pure text).
                Padding(
                  padding: kPageVPadding,
                  child: Center(
                    child: SizedBox(
                      width: contentWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (i == 0 && _cfg.showHeadings)
                            ChapterHeader(book: _book, chapter: _chapter),
                          for (final v in pages[i])
                            VerseText(
                              verse: v,
                              verseStyle: verseStyle,
                              textWidth: textWidth,
                              showNumber: _cfg.showVerseNumbers,
                              dropCap: _cfg.dropCaps && v.number == 1,
                              justify: _cfg.justify,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // One ink layer spanning the WHOLE page on top — write anywhere.
                Positioned.fill(
                  child: PageInk(
                    key: ValueKey(pageKey),
                    pageKey: pageKey,
                    penWidth: _penWidth,
                    penStyle: _preset.id,
                    penColor: _shade.color,
                    isEraser: _isEraser,
                    eraseScale: _ui,
                  ),
                ),
              ],
            );
          },
        );
      },
    ));
  }

}

/// Small bar that visualises the current stroke width in the toolbar.
/// Pen-type chip in the pen sheet. The numeric thickness sits ABOVE the glyph,
/// matching the standard Boox notetaker bar in the reference image.
/// Printed-book style chapter header shown at the top of the first page.
class ChapterHeader extends StatelessWidget {
  final String book;
  final int chapter;
  const ChapterHeader({super.key, required this.book, required this.chapter});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kChapterHeaderHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            bookLabel(book, CanonLanguage.code).toUpperCase(),
            style: crimson(
              fontSize: 13,
              height: 1.0,
              letterSpacing: 4,
              fontWeight: FontWeight.w600,
              color: kMuted,
            ),
          ),
          const SizedBox(height: 4),
          // height 1.0 keeps the number's line box equal to its font size so
          // the whole header provably fits the kChapterHeaderHeight reserve
          // (13 + 4 + 52 + 8 + 1 = 78 < 96) — no first-page overflow.
          Text(
            '$chapter',
            style: crimson(
                fontSize: 52,
                height: 1.0,
                fontWeight: FontWeight.w500,
                color: kInk),
          ),
          const SizedBox(height: 8),
          Container(width: 44, height: 1, color: kInk),
        ],
      ),
    );
  }
}

// --- Verse text + page-level handwriting ---------------------------------

/// Pure verse text. The ink lives on a separate page-wide layer above it, so a
/// verse never owns its own little canvas.
class VerseText extends StatelessWidget {
  final Verse verse;
  final TextStyle verseStyle;
  final double textWidth; // width of the text column; the rest is writing margin
  final bool showNumber;
  final bool dropCap; // decorated initial (chapter's first verse, print option)
  final bool justify; // justified text, like a printed page

  const VerseText({
    super.key,
    required this.verse,
    required this.verseStyle,
    required this.textWidth,
    required this.showNumber,
    this.dropCap = false,
    this.justify = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: kVerseSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showNumber)
            SizedBox(
              width: kGutterWidth,
              child: Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: Text('${verse.number}',
                    textAlign: TextAlign.right, style: kVerseNumberStyle),
              ),
            ),
          SizedBox(
            width: textWidth,
            child: Text.rich(
              verseSpan(verse.text, verseStyle, dropCap: dropCap),
              textAlign: justify ? TextAlign.justify : TextAlign.start,
              // The layout is "printed": pagination measures unscaled text, so
              // the system font-size setting must not stretch it here either.
              textScaler: TextScaler.noScaling,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// One ink layer covering the WHOLE page: you can write over the text, in the
/// margins, between verses, above the header — anywhere — and it persists.
/// Strokes are stored per page (`<book>_<chapter>#<pageIndex>`); since a printed
/// Bible's layout is locked, page boundaries are stable and notes stay put.
class PageInk extends StatefulWidget {
  final String pageKey;
  final double penWidth;
  final String penStyle; // active pen recipe id (kPenPresets)
  final Color penColor; // ink shade (see kInkShades)
  final bool isEraser;
  final double eraseScale; // chrome scale; widens the erase radius on big panels

  const PageInk({
    super.key,
    required this.pageKey,
    required this.penWidth,
    required this.penStyle,
    required this.penColor,
    required this.isEraser,
    this.eraseScale = 1.0,
  });

  @override
  State<PageInk> createState() => _PageInkState();
}

class _PageInkState extends State<PageInk> {
  late List<Stroke> _strokes;
  Stroke? _active;

  // Two repaint channels keep writing cheap. The committed layer repaints only
  // when the saved strokes change (commit/erase/undo); the active layer repaints
  // on every pointer move. So during a stroke we redraw ONLY the in-progress
  // line — not every committed stroke on the page — which is what made long
  // margin notes lag (the cost grew with how much was already on the page).
  final ValueNotifier<int> _committedRepaint = ValueNotifier<int>(0);
  final ValueNotifier<int> _activeRepaint = ValueNotifier<int>(0);

  static const double _eraseRadius = 18.0;
  // Minimum spacing (logical px) between captured points while drawing. Below
  // this a move is ignored, capping points-per-stroke and per-frame redraw cost.
  // Kept low: the stroke is rasterised as one path now, so extra samples cost
  // little, and dropping them is what turned quick small letters into angular
  // approximations of themselves.
  static const double _minSegment = 0.75;
  Size? _canvasSize; // reported by the painter; used for capture box + eraser
  final List<Stroke> _erasedThisGesture = [];
  Offset? _eraserAt; // eraser-tip position while erasing (drives the ring)

  @override
  void initState() {
    super.initState();
    _strokes = DrawingStore.strokesFor(widget.pageKey);
    kUndo.register(widget.pageKey, _resyncFromStore);
  }

  @override
  void didUpdateWidget(PageInk old) {
    super.didUpdateWidget(old);
    if (old.pageKey != widget.pageKey) {
      kUndo.unregister(old.pageKey, _resyncFromStore);
      _strokes = DrawingStore.strokesFor(widget.pageKey);
      kUndo.register(widget.pageKey, _resyncFromStore);
      _active = null;
      _committedRepaint.value++;
      _activeRepaint.value++;
    }
  }

  @override
  void dispose() {
    kUndo.unregister(widget.pageKey, _resyncFromStore);
    _committedRepaint.dispose();
    _activeRepaint.dispose();
    super.dispose();
  }

  void _resyncFromStore() {
    if (!mounted) return;
    _strokes = DrawingStore.strokesFor(widget.pageKey);
    _committedRepaint.value++;
  }

  bool _isStylus(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  /// Stylus pressure on a 0..1 scale, or -1 when this pen doesn't report any.
  ///
  /// [PointerEvent.pressure] is in the device's own units; without rescaling by
  /// the reported range a pen that maxes out at 4.0 reads as "hardest possible
  /// press" the whole time. Pens with no sensor report a flat range, and -1
  /// tells the painter to lay down the plain nib rather than guess a weight.
  double _pressureOf(PointerEvent e) {
    final span = e.pressureMax - e.pressureMin;
    if (span.abs() < 0.001) return -1.0;
    return ((e.pressure - e.pressureMin) / span).clamp(0.0, 1.0);
  }

  // Erase when the eraser tool is on, the pen is flipped to its eraser end, OR
  // a stylus side/eraser button is held (many e-ink pens report it that way).
  bool _erasing(PointerEvent e) =>
      widget.isEraser ||
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.buttons & (kSecondaryButton | kTertiaryButton)) != 0;

  void _onDown(PointerDownEvent e) {
    if (!_isStylus(e)) return;
    if (_erasing(e)) {
      _eraserAt = e.localPosition; // show the tool's reach
      _eraseAt(e.localPosition);
      _activeRepaint.value++;
      return;
    }
    _active = Stroke(
      points: [
        StrokePoint(e.localPosition.dx, e.localPosition.dy, _pressureOf(e))
      ],
      width: widget.penWidth,
      color: widget.penColor,
      style: widget.penStyle,
      captureW: _canvasSize?.width ?? 0,
      captureH: _canvasSize?.height ?? 0,
    );
    _activeRepaint.value++;
  }

  void _onMove(PointerMoveEvent e) {
    if (!_isStylus(e)) return;
    if (_erasing(e)) {
      _eraserAt = e.localPosition;
      _eraseAt(e.localPosition);
      _activeRepaint.value++;
      return;
    }
    if (_active == null) return;
    // Decimate: drop sub-pixel moves. The stylus reports points far faster than
    // the e-ink panel refreshes, and each kept point is redrawn every frame, so
    // skipping near-duplicate points keeps long strokes (e.g. big margin notes)
    // from getting progressively laggier without any visible loss of fidelity.
    final last = _active!.points.last;
    final dx = e.localPosition.dx - last.x;
    final dy = e.localPosition.dy - last.y;
    if (dx * dx + dy * dy < _minSegment * _minSegment) return;
    _active!.points.add(
        StrokePoint(e.localPosition.dx, e.localPosition.dy, _pressureOf(e)));
    // Only the active layer repaints — committed strokes are untouched.
    _activeRepaint.value++;
  }

  void _onUp(PointerUpEvent e) {
    var changed = false;
    if (_eraserAt != null) {
      _eraserAt = null; // hide the eraser ring
      _activeRepaint.value++;
    }
    if (_active != null) {
      // Commit even a single-point stroke so a deliberate dot still draws now
      // that sub-pixel moves are decimated away.
      if (_active!.points.isNotEmpty) {
        _strokes.add(_active!);
        DrawingStore.setStrokes(widget.pageKey, _strokes);
        kUndo.recordAdd(widget.pageKey, _active!);
        changed = true;
      }
      _active = null;
      // The new stroke now lives in the committed layer; clear the active one.
      _committedRepaint.value++;
      _activeRepaint.value++;
    }
    if (_erasedThisGesture.isNotEmpty) {
      kUndo.recordErase(widget.pageKey, List<Stroke>.of(_erasedThisGesture));
      _erasedThisGesture.clear();
      changed = true;
    }
    // Lifting the pen makes the change durable now (atomic write), so a crash
    // or power loss right after writing can't drop the just-finished mark.
    if (changed) unawaited(DrawingStore.flushNow());
  }

  // The system cancelled the gesture (palm classification, app switch, …):
  // drop the in-progress stroke rather than committing a half-drawn line, but
  // keep the erase undo record — those strokes are already gone from the store.
  void _onCancel(PointerCancelEvent e) {
    _eraserAt = null;
    _active = null;
    _activeRepaint.value++;
    if (_erasedThisGesture.isNotEmpty) {
      kUndo.recordErase(widget.pageKey, List<Stroke>.of(_erasedThisGesture));
      _erasedThisGesture.clear();
      unawaited(DrawingStore.flushNow());
    }
  }

  void _eraseAt(Offset p) {
    final radius = _eraseRadius * widget.eraseScale;
    final removed = _strokes
        .where((s) => s.isNear(p, radius, canvas: _canvasSize))
        .toList();
    if (removed.isEmpty) return;
    _erasedThisGesture.addAll(removed);
    _strokes.removeWhere((s) => removed.contains(s));
    DrawingStore.setStrokes(widget.pageKey, _strokes);
    _committedRepaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    // Ink is measured against the physical panel, not logical pixels, so a
    // one-pixel line stays one pixel wherever it is painted.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Committed ink: its own RepaintBoundary so a move never redraws it.
          RepaintBoundary(
            child: CustomPaint(
              painter: _CommittedPainter(
                strokes: _strokes,
                dpr: dpr,
                repaint: _committedRepaint,
                onPaintSize: (s) => _canvasSize = s,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          // In-progress stroke on top, in its own RepaintBoundary so a move
          // rasters only this layer — never the committed ink beneath it.
          // The same layer shows the eraser's reach as a ring while erasing.
          RepaintBoundary(
            child: CustomPaint(
              painter: _ActivePainter(
                active: () => _active,
                eraser: () => _eraserAt,
                eraseRadius: _eraseRadius * widget.eraseScale,
                dpr: dpr,
                repaint: _activeRepaint,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The nib-width slider: a wedge that thickens to the right, so the control
/// shows the thing it sets rather than describing it.
///
/// Hand-drawn rather than a Material [Slider] because that one animates its
/// thumb and paints a ripple overlay on touch — on e-ink both arrive as smear,
/// and the value lands late. Here the knob is simply where your finger is.
class WedgeSlider extends StatelessWidget {
  final double value; // 0..1
  final ValueChanged<double> onChanged;

  /// Fired when the gesture finishes. Dragging reports continuously, so
  /// anything expensive — writing the setting to disk — belongs here, not in
  /// [onChanged], which fires on every pixel of travel.
  final VoidCallback? onChangeEnd;
  final double scale;

  const WedgeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final radius = 11.0 * scale;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final span = width - 2 * radius;
        void report(Offset p) {
          if (span <= 0) return;
          onChanged(((p.dx - radius) / span).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => report(d.localPosition),
          onTapUp: (_) => onChangeEnd?.call(),
          onHorizontalDragStart: (d) => report(d.localPosition),
          onHorizontalDragUpdate: (d) => report(d.localPosition),
          onHorizontalDragEnd: (_) => onChangeEnd?.call(),
          child: CustomPaint(
            size: Size(width, 42 * scale),
            painter: _WedgePainter(
              value: value.clamp(0.0, 1.0),
              radius: radius,
            ),
          ),
        );
      },
    );
  }
}

class _WedgePainter extends CustomPainter {
  final double value;
  final double radius;

  _WedgePainter({required this.value, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final x0 = radius;
    final x1 = size.width - radius;
    if (x1 <= x0) return;

    final thin = 1.0;
    final thick = size.height * 0.44;
    final ink = Paint()
      ..color = kInk
      ..isAntiAlias = true;

    canvas.drawPath(
      Path()
        ..moveTo(x0, mid - thin / 2)
        ..lineTo(x1, mid - thick / 2)
        ..lineTo(x1, mid + thick / 2)
        ..lineTo(x0, mid + thin / 2)
        ..close(),
      ink,
    );
    // Rounds off the broad end, so the wedge reads as a nib and not an arrow.
    canvas.drawCircle(Offset(x1, mid), thick / 2, ink);

    final cx = x0 + (x1 - x0) * value;
    canvas.drawCircle(Offset(cx, mid), radius, Paint()..color = kPaper);
    canvas.drawCircle(
      Offset(cx, mid),
      radius,
      Paint()
        ..color = kInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(covariant _WedgePainter old) =>
      old.value != value || old.radius != radius;
}

class _CommittedPainter extends CustomPainter {
  final List<Stroke> strokes;
  final double dpr;

  // Reports the actual canvas size on every paint. The page uses it to stamp
  // capture boxes on new strokes and to hit-test the eraser in canvas space.
  final ValueChanged<Size>? onPaintSize;

  _CommittedPainter({
    required this.strokes,
    required this.dpr,
    required Listenable repaint,
    this.onPaintSize,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    onPaintSize?.call(size);
    for (final s in strokes) {
      _paintStroke(canvas, s, size, dpr);
    }
  }

  @override
  bool shouldRepaint(covariant _CommittedPainter old) =>
      old.strokes != strokes || old.dpr != dpr;
}

class _ActivePainter extends CustomPainter {
  final Stroke? Function() active;
  final Offset? Function() eraser;
  final double eraseRadius;
  final double dpr;

  _ActivePainter({
    required this.active,
    required this.eraser,
    required this.eraseRadius,
    required this.dpr,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final a = active();
    if (a != null) _paintStroke(canvas, a, size, dpr, live: true);
    // While erasing, show the tool's reach — a thin ring, like the shadow of a
    // physical eraser held against the page.
    final e = eraser();
    if (e != null) {
      canvas.drawCircle(
        e,
        eraseRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = false
          ..color = kMuted,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ActivePainter old) => true;
}

// --- Book / chapter picker -----------------------------------------------

class BookPickerScreen extends StatefulWidget {
  final String currentBook;
  final int currentChapter;

  const BookPickerScreen({
    super.key,
    required this.currentBook,
    required this.currentChapter,
  });

  @override
  State<BookPickerScreen> createState() => _BookPickerScreenState();
}

class _BookPickerScreenState extends State<BookPickerScreen> {
  BibleBook? _selected;

  @override
  Widget build(BuildContext context) {
    final book = _selected;
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(
        leading: book == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selected = null),
              ),
        title: Text(
          book == null
              ? canonLabels(CanonLanguage.code).contents
              : bookLabel(book.name, CanonLanguage.code),
          style: kTitleStyle(20),
        ),
      ),
      body: book == null ? _buildBookList() : _buildChapterGrid(book),
    );
  }

  Widget _buildBookList() {
    final ot = kBibleBooks.where((b) => b.isOldTestament).toList();
    final nt = kBibleBooks.where((b) => !b.isOldTestament).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _sectionHeader(canonLabels(CanonLanguage.code).oldTestament),
        ...ot.map(_bookTile),
        _sectionHeader(canonLabels(CanonLanguage.code).newTestament),
        ...nt.map(_bookTile),
      ],
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
        child: Text(
          label.toUpperCase(),
          style: crimson(
              fontSize: 12,
              letterSpacing: 3,
              fontWeight: FontWeight.w600,
              color: kMuted),
        ),
      );

  Widget _bookTile(BibleBook b) {
    final isCurrent = b.name == widget.currentBook;
    return InkWell(
      onTap: () => setState(() => _selected = b),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
        child: Row(
          children: [
            if (isCurrent)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 10),
                decoration: const BoxDecoration(
                    color: kInk, shape: BoxShape.circle),
              ),
            Expanded(
              child: Text(
                bookLabel(b.name, CanonLanguage.code),
                style: kTitleStyle(19,
                    weight: isCurrent ? FontWeight.w700 : FontWeight.w400),
              ),
            ),
            Text('${b.chapters}',
                style: crimson(color: kMuted, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildChapterGrid(BibleBook book) {
    return GridView.builder(
      padding: const EdgeInsets.all(18),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 76,
        childAspectRatio: 1,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: book.chapters,
      itemBuilder: (context, i) {
        final n = i + 1;
        final isCurrent =
            book.name == widget.currentBook && n == widget.currentChapter;
        return InkWell(
          onTap: () => Navigator.of(context).pop(BibleRef(book.name, n)),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: kInk, width: isCurrent ? 0 : 1),
              borderRadius: BorderRadius.circular(8),
              color: isCurrent ? kInk : kPaper,
            ),
            alignment: Alignment.center,
            child: Text(
              '$n',
              style: crimson(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: isCurrent ? kPaper : kInk,
              ),
            ),
          ),
        );
      },
    );
  }
}

// --- Notes browser -------------------------------------------------------
//
// Lists every verse that holds handwritten ink, in canonical order, so the
// reader can jump straight to anything they've annotated. Selecting a row pops
// a BibleRef (book, chapter, verse) the reader navigates to.

class _NoteEntry {
  final BibleRef ref;
  final int count;
  String? preview; // verse text, loaded lazily for context
  _NoteEntry(this.ref, this.count);
}

class NotesBrowserScreen extends StatefulWidget {
  const NotesBrowserScreen({super.key});

  @override
  State<NotesBrowserScreen> createState() => _NotesBrowserScreenState();
}

class _NotesBrowserScreenState extends State<NotesBrowserScreen> {
  late final List<_NoteEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _buildEntries();
    _loadPreviews();
  }

  List<_NoteEntry> _buildEntries() {
    int order(String book) {
      final i = kBibleBooks.indexWhere((b) => b.name == book);
      return i < 0 ? 1 << 20 : i;
    }

    // Ink is stored per page ("Book_Chapter#page"); aggregate by chapter.
    final counts = <String, int>{};
    final refs = <String, BibleRef>{};
    for (final id in DrawingStore.annotatedVerseIds()) {
      final base = id.split('#').first; // "Book_Chapter"
      final i = base.lastIndexOf('_');
      if (i <= 0) continue;
      final book = base.substring(0, i);
      final chapter = int.tryParse(base.substring(i + 1));
      if (chapter == null) continue;
      final k = '$book|$chapter';
      counts[k] = (counts[k] ?? 0) + DrawingStore.strokeCount(id);
      refs[k] = BibleRef(book, chapter);
    }
    final entries = [
      for (final k in counts.keys) _NoteEntry(refs[k]!, counts[k]!)
    ];
    entries.sort((a, b) {
      final o = order(a.ref.book).compareTo(order(b.ref.book));
      if (o != 0) return o;
      return a.ref.chapter.compareTo(b.ref.chapter);
    });
    return entries;
  }

  // Shows the chapter's opening verse as a hint of where the notes live.
  Future<void> _loadPreviews() async {
    final src = BundledScriptureSource(kDefaultTranslation);
    for (final e in _entries) {
      try {
        final verses = await src.chapter(e.ref.book, e.ref.chapter);
        if (verses.isNotEmpty) e.preview = verses.first.text;
      } catch (_) {
        // Leave preview null; the reference alone is still actionable.
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(title: Text('My notes', style: kTitleStyle(20))),
      body: _entries.isEmpty
          ? Center(
              child: Text('No notes yet.',
                  style: kTitleStyle(18, weight: FontWeight.w500)
                      .copyWith(color: kMuted)),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final e = _entries[i];
                final marks =
                    '${e.count} ${e.count == 1 ? 'mark' : 'marks'}';
                return InkWell(
                  onTap: () => Navigator.of(context).pop(e.ref),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.ref.label(CanonLanguage.code),
                                style: kTitleStyle(18, weight: FontWeight.w700),
                              ),
                            ),
                            const Icon(Icons.gesture, size: 16, color: kMuted),
                            const SizedBox(width: 5),
                            Text(marks,
                                style: crimson(
                                    color: kMuted, fontSize: 13)),
                          ],
                        ),
                        if (e.preview != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            e.preview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: crimson(
                                fontSize: 16, height: 1.4, color: kMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// --- Reading plans -------------------------------------------------------
//
// Picks/starts a cross-reference-driven plan and surfaces "today's reading"
// with check-off, a Day N/M counter, a streak, and a progress bar. Tapping a
// passage pops a BibleRef the reader navigates to. The plan is built on demand
// from the bundled cross-reference graph; only the active plan is built.

class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key});

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  XrefGraph? _graph;
  OtNtEchoes? _echoes;
  bool _loading = true;
  String? _detailId; // when set, show this saved plan's progress

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _graph = await loadXrefGraph();
    } catch (_) {
      // Leave _graph null; the library still lists plans, just without detail.
    }
    try {
      _echoes = await loadOtNtEchoes();
    } catch (_) {
      // Echoes optional: falls back to chapter-level affinity from _graph.
    }
    if (mounted) setState(() => _loading = false);
  }

  SavedPlan? get _detail {
    final id = _detailId;
    if (id == null) return null;
    for (final p in PlanStore.plans) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> _newPlan() async {
    final config = await Navigator.of(context).push<PlanConfig>(
      MaterialPageRoute(
          builder: (_) => const UiScaled(child: PlanBuilderScreen())),
    );
    if (config == null || !mounted) return;
    final sp = PlanStore.create(config, planLength(config));
    setState(() => _detailId = sp.id);
  }

  void _openDetail(SavedPlan sp) {
    PlanStore.setActive(sp.id);
    setState(() => _detailId = sp.id);
  }

  void _deletePlan(SavedPlan sp) {
    PlanStore.delete(sp.id);
    setState(() {
      if (_detailId == sp.id) _detailId = null;
    });
  }

  void _complete() => setState(PlanStore.completeCurrent);
  void _undo() => setState(PlanStore.uncompleteLast);

  String _summary(PlanDay d) =>
      // toString keeps a snippet echo's verse range ("Hebrews 11:1-3") visible.
      d.passages.map((r) => r.label(CanonLanguage.code)).join('  ·  ');

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(
        title: Text(detail == null ? 'Reading plans' : detail.title,
            style: kTitleStyle(20)),
        leading: detail == null
            ? null
            : BackButton(onPressed: () => setState(() => _detailId = null)),
      ),
      body: _loading
          ? const QuietLoader()
          : (detail == null ? _libraryView() : _detailView(detail)),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
        child: Text(text,
            style: crimson(
                fontSize: 12,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
                color: kMuted)),
      );

  // --- Library: every saved plan keeps its own progress -------------------

  Widget _libraryView() {
    final plans = PlanStore.plans;
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _newPlan,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('New plan'),
              style: FilledButton.styleFrom(
                backgroundColor: kInk,
                foregroundColor: kPaper,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ),
        if (plans.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
            child: Text(
              'No plans yet. Build one and your progress is saved here — you '
              'can start another any time without losing this one.',
              style: crimson(
                  fontSize: 16, color: kMuted, height: 1.4),
            ),
          )
        else ...[
          _sectionLabel('YOUR PLANS'),
          for (final sp in plans) _planCard(sp),
        ],
        const SizedBox(height: 22),
        _attribution(),
      ],
    );
  }

  Widget _planCard(SavedPlan sp) {
    final total = sp.totalDays;
    final done = sp.completedCount.clamp(0, total);
    final fraction = total == 0 ? 0.0 : done / total;
    return InkWell(
      onTap: () => _openDetail(sp),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sp.title,
                      style: kTitleStyle(18, weight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                      sp.isFinished
                          ? 'Finished · $total readings'
                          : 'Reading ${done + 1} of $total',
                      style: crimson(
                          fontSize: 14, color: kMuted)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Container(
                      height: 5,
                      color: kDisabled,
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: fraction == 0 ? 0.001 : fraction,
                        child: Container(color: kInk),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Delete plan',
              icon: const Icon(Icons.delete_outline, color: kMuted),
              onPressed: () => _confirmDelete(sp),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(SavedPlan sp) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kPaper,
        title: Text('Delete this plan?', style: kTitleStyle(18)),
        content: Text('"${sp.title}" and its progress will be removed.',
            style: crimson(fontSize: 15, color: kInk)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:
                Text('Keep', style: crimson(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete',
                style: crimson(
                    color: kInk, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (yes == true) _deletePlan(sp);
  }

  // --- One plan's progress ------------------------------------------------

  Widget _detailView(SavedPlan sp) {
    final g = _graph;
    if (g == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text("Couldn't load cross-references for this plan.",
              style: crimson(fontSize: 16, color: kMuted)),
        ),
      );
    }
    return _progressView(
        sp, generatePlan(g, sp.config, id: sp.id, echoes: _echoes));
  }

  // --- Active plan: self-paced progress -----------------------------------

  Widget _progressView(SavedPlan sp, ReadingPlan plan) {
    final s = sp;
    final total = plan.length;
    final done = s.completedCount.clamp(0, total).toInt();
    final fraction = total == 0 ? 0.0 : done / total;
    final finished = done >= total;
    final current = finished ? null : plan.days[done];
    final upcoming = <int>[
      for (var i = done + 1; i < total && i <= done + 5; i++) i,
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        // Header: plan + progress.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(plan.title, style: kTitleStyle(22, weight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(children: [
                Text(
                    finished
                        ? 'Finished · $total readings'
                        : 'Reading ${done + 1} of $total',
                    style:
                        crimson(fontSize: 14, color: kMuted)),
                if (s.streak > 0) ...[
                  Text('   ·   ',
                      style: crimson(color: kMuted)),
                  Text('${s.streak}-day streak',
                      style: crimson(
                          fontSize: 14,
                          color: kInk,
                          fontWeight: FontWeight.w600)),
                ],
              ]),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Container(
                  height: 6,
                  color: kDisabled,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction == 0 ? 0.001 : fraction,
                    child: Container(color: kInk),
                  ),
                ),
              ),
            ],
          ),
        ),

        // The current (next) reading — the only thing you're asked to do.
        if (current != null)
          _currentCard(done, current, plan)
        else
          _finishedCard(sp),

        // What's coming, so a missed day is never a pile of empty boxes.
        if (upcoming.isNotEmpty) _sectionLabel('COMING UP'),
        for (final i in upcoming)
          _entryRow(
              label: 'Reading ${i + 1}',
              dayIndex: i,
              day: plan.days[i],
              plan: plan),

        if (done > 0) _sectionLabel('ALREADY READ'),
        for (var i = done - 1; i >= 0 && i >= done - 4; i--)
          _entryRow(
              label: 'Reading ${i + 1}',
              dayIndex: i,
              day: plan.days[i],
              plan: plan,
              muted: true),

        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _detailId = null),
            child: Text('Back to my plans',
                style: crimson(
                    fontSize: 15, color: kInk, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 8),
        _attribution(),
      ],
    );
  }

  Widget _currentCard(int index, PlanDay day, ReadingPlan plan) => Container(
        margin: const EdgeInsets.fromLTRB(20, 18, 20, 4),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: kInk, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NEXT READING',
                style: crimson(
                    fontSize: 11,
                    letterSpacing: 2.5,
                    fontWeight: FontWeight.w600,
                    color: kMuted)),
            const SizedBox(height: 6),
            for (var pi = 0; pi < day.passages.length; pi++)
              InkWell(
                onTap: () =>
                    Navigator.of(context).pop(PlanSession(plan, index, pi)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(day.passages[pi].label(CanonLanguage.code),
                            style: kTitleStyle(20, weight: FontWeight.w500)),
                      ),
                      Icon(
                          bookByName(day.passages[pi].book).isOldTestament
                              ? Icons.brightness_2_outlined
                              : Icons.wb_sunny_outlined,
                          size: 15,
                          color: kMuted),
                      const SizedBox(width: 10),
                      const Icon(Icons.chevron_right, size: 20, color: kMuted),
                    ],
                  ),
                ),
              ),
            if (day.isCrossReferenced)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  const Icon(Icons.auto_awesome, size: 14, color: kMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Paired by cross-references',
                        style: crimson(
                            fontSize: 13,
                            color: kMuted,
                            fontStyle: FontStyle.italic)),
                  ),
                ]),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _complete,
                icon: const Icon(Icons.check, size: 20),
                label: const Text('Mark complete'),
                style: FilledButton.styleFrom(
                  backgroundColor: kInk,
                  foregroundColor: kPaper,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            if (index > 0)
              Center(
                child: TextButton(
                  onPressed: _undo,
                  child: Text('Undo last',
                      style: crimson(
                          fontSize: 14, color: kMuted)),
                ),
              ),
          ],
        ),
      );

  Widget _finishedCard(SavedPlan sp) => Container(
        margin: const EdgeInsets.fromLTRB(20, 18, 20, 4),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          border: Border.all(color: kInk, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You finished this plan.',
                style: kTitleStyle(20, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Take a moment — then read on, or start another plan.',
                style: crimson(
                    fontSize: 15, color: kMuted, height: 1.4)),
            if (sp.completedCount > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _undo,
                  child: Text('Reopen last reading',
                      style: crimson(
                          fontSize: 14, color: kMuted)),
                ),
              ),
          ],
        ),
      );

  Widget _entryRow(
          {required String label,
          required int dayIndex,
          required PlanDay day,
          required ReadingPlan plan,
          bool muted = false}) =>
      InkWell(
        onTap: day.passages.isEmpty
            ? null
            : () => Navigator.of(context).pop(PlanSession(plan, dayIndex, 0)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
          child: Row(
            children: [
              if (muted)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(Icons.check, size: 16, color: kMuted),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: crimson(
                            fontSize: 12,
                            letterSpacing: 1.5,
                            color: kMuted)),
                    Text(_summary(day),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kTitleStyle(17,
                            weight: muted ? FontWeight.w400 : FontWeight.w500)
                            .copyWith(color: muted ? kMuted : kInk)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _attribution() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Pairings follow real cross-references from the OpenBible.info '
          'dataset (CC-BY 4.0).',
          style:
              crimson(fontSize: 13, color: kMuted, height: 1.4),
        ),
      );

}

// App identity, kept in sync with pubspec.yaml `version:`. A const avoids a
// platform plugin (package_info_plus) on an otherwise fully-offline app.
const String kAppName = 'Onyx Bible';
const String kAppVersion = '1.0.0';
const String kRepoUrl = 'https://github.com/greenducktape/OnyxBible';

/// About / credits — reachable from the menu so the required attributions are
/// always visible (CC-BY for the cross-references; the bundled texts' and fonts'
/// licenses), alongside the app version, a plain privacy statement, and the full
/// open-source license list.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(title: Text('About', style: kTitleStyle(20))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Text(kAppName, style: kTitleStyle(26)),
          const SizedBox(height: 2),
          Text('Version $kAppVersion',
              style: crimson(fontSize: 14, color: kMuted)),
          const SizedBox(height: 14),
          _body('An offline, ad-free scripture reader and stylus notebook for '
              'Onyx Boox e-ink devices. Print a Bible once, then read and write '
              'in it like a paper book.'),
          _section('Scripture texts'),
          _body('King James Version — Public Domain.\n'
              'Reina-Valera 1909 — Dominio público.\n'
              'Luther 1912 — Gemeinfrei (Public Domain).\n'
              'Each is bundled for fully offline reading.'),
          _section('Cross-references'),
          _body('Reading-plan pairings use the OpenBible.info cross-reference '
              'dataset, used under the Creative Commons Attribution 4.0 license '
              '(CC-BY 4.0).'),
          _section('Typefaces'),
          _body('Crimson Pro, EB Garamond, Lora, and Atkinson Hyperlegible, '
              'each under the SIL Open Font License.'),
          _section('Privacy'),
          _body('Your notes and settings stay on this device. There is no '
              'account, no analytics, and no tracking. The only network use is '
              'optional: fetching a non-bundled translation if you choose one.'),
          _section('Backup'),
          _body('Because nothing is stored in the cloud, export a backup to keep '
              'your Bibles, notes, and plans safe off-device. Restoring replaces '
              'everything currently in the app.'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _export(context),
                  style: _btnStyle(),
                  child: const Text('Export backup'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _restore(context),
                  style: _btnStyle(),
                  child: const Text('Restore'),
                ),
              ),
            ],
          ),
          _section('Source'),
          _body('This app is open-source:\n$kRepoUrl'),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: kAppName,
              applicationVersion: kAppVersion,
            ),
            style: _btnStyle(),
            child: const Text('Open-source licenses'),
          ),
        ],
      ),
    );
  }

  ButtonStyle _btnStyle() => OutlinedButton.styleFrom(
        foregroundColor: kInk,
        side: const BorderSide(color: kInk),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      );

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await BackupService.exportViaShare();
    } catch (e) {
      messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't export the backup.")));
    }
  }

  Future<void> _restore(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kPaper,
        title: Text('Restore from backup?', style: kTitleStyle(18)),
        content: Text(
            'This replaces all Bibles, notes, and plans currently in the app '
            'with the contents of the backup file.',
            style: crimson(fontSize: 15, color: kInk, height: 1.4)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Cancel', style: crimson(color: kMuted))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Restore',
                  style: crimson(color: kInk, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirmed != true) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;

    try {
      await BackupService.restoreFromFile(File(path));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('That file is not a valid Onyx Bible backup.')));
      return;
    }
    // Rebuild the whole app from the restored data so the reader reflects it.
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RootScreen()),
      (route) => false,
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 6),
        child: Text(title.toUpperCase(),
            style: crimson(
                fontSize: 12, letterSpacing: 1.5, color: kMuted)),
      );

  Widget _body(String text) => Text(text,
      style: crimson(fontSize: 16, color: kInk, height: 1.45));
}

/// Build a reading plan by choosing what you want from it — chapters per day,
/// cross-referenced or straight through, a daily Psalm, New Testament only,
/// canonical or chronological order — and read a live narrative + day-1 preview
/// as you adjust. "Generate & start" hands the config back to PlansScreen.
class PlanBuilderScreen extends StatefulWidget {
  const PlanBuilderScreen({super.key});

  @override
  State<PlanBuilderScreen> createState() => _PlanBuilderScreenState();
}

class _PlanBuilderScreenState extends State<PlanBuilderScreen> {
  PlanConfig _c = const PlanConfig();
  XrefGraph? _graph;
  OtNtEchoes? _echoes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _graph = await loadXrefGraph();
    } catch (_) {
      // Preview falls back to no cross-referenced NT passage.
    }
    try {
      _echoes = await loadOtNtEchoes();
    } catch (_) {
      // Echoes optional; chapter-level affinity from _graph is the fallback.
    }
    if (mounted) setState(() {});
  }

  void _set(PlanConfig next) => setState(() => _c = next);

  // Opens the book picker to choose where the plan begins.
  Future<void> _pickStart() async {
    final ref = await Navigator.of(context).push<BibleRef>(
      MaterialPageRoute(
        builder: (_) => UiScaled(
          child: BookPickerScreen(
            currentBook: _c.hasCustomStart ? _c.startBook : 'Genesis',
            currentChapter: _c.hasCustomStart ? _c.startChapter : 1,
          ),
        ),
      ),
    );
    if (ref == null || !mounted) return;
    _set(_c.copyWith(startBook: ref.book, startChapter: ref.chapter));
  }

  // Day-1 passages for the preview. Needs the graph for the NT pairing.
  PlanDay? get _firstDay {
    final g = _graph;
    if (g == null) return null;
    final days =
        generatePlan(g, _c, id: 'preview', echoes: _echoes).days;
    return days.isEmpty ? null : days.first;
  }

  @override
  Widget build(BuildContext context) {
    final days = planLength(_c);
    final ntOnly = _c.newTestamentOnly;
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(title: Text('Design a plan', style: kTitleStyle(20))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 28),
        children: [
          // Narrative + duration.
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_c.title, style: kTitleStyle(22, weight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${durationLabel(days)} · $days readings',
                    style:
                        crimson(fontSize: 14, color: kInk)),
                const SizedBox(height: 12),
                Text(narrativeFor(_c),
                    style: crimson(
                        fontSize: 16, color: kMuted, height: 1.45)),
              ],
            ),
          ),
          _dayOnePreview(),

          _builderLabel('CHAPTERS PER DAY'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                _stepBtn(Icons.remove, () {
                  if (_c.chaptersPerDay > 1) {
                    _set(_c.copyWith(chaptersPerDay: _c.chaptersPerDay - 1));
                  }
                }),
                Expanded(
                  child: Center(
                    child: Text('${_c.chaptersPerDay}',
                        style: kTitleStyle(26, weight: FontWeight.w700)),
                  ),
                ),
                _stepBtn(Icons.add, () {
                  if (_c.chaptersPerDay < 12) {
                    _set(_c.copyWith(chaptersPerDay: _c.chaptersPerDay + 1));
                  }
                }),
              ],
            ),
          ),

          _builderLabel('WHAT TO INCLUDE'),
          _switchTile(
            title: 'Read only the New Testament',
            subtitle: 'Skip the Old Testament entirely',
            value: ntOnly,
            onChanged: (v) => _set(_c.copyWith(newTestamentOnly: v)),
          ),
          _switchTile(
            title: 'A Psalm every day',
            subtitle: 'Adds one Psalm to each day (cycling all 150)',
            value: _c.dailyPsalm,
            onChanged: (v) => _set(_c.copyWith(dailyPsalm: v)),
          ),
          _switchTile(
            title: 'Cross-referenced',
            subtitle: ntOnly
                ? 'Not applicable when reading only the New Testament'
                : 'Pair each day with a linked New Testament passage. Off = '
                    'read straight through, back to back.',
            value: _c.crossReferenced && !ntOnly,
            onChanged:
                ntOnly ? null : (v) => _set(_c.copyWith(crossReferenced: v)),
          ),

          if (!ntOnly) ...[
            _builderLabel('OLD TESTAMENT ORDER'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _orderChip('In order', PlanOrdering.canonical),
                  const SizedBox(width: 10),
                  _orderChip('Chronological', PlanOrdering.chronological),
                ],
              ),
            ),
          ],

          _builderLabel('START FROM'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: InkWell(
              onTap: _pickStart,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: kDisabled),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          _c.hasCustomStart
                              ? '${bookLabel(_c.startBook, CanonLanguage.code)}'
                                  ' ${_c.startChapter}'
                              : 'The beginning',
                          style: kTitleStyle(17, weight: FontWeight.w500)),
                    ),
                    if (_c.hasCustomStart)
                      IconButton(
                        tooltip: 'Clear start point',
                        onPressed: () => _set(
                            _c.copyWith(startBook: '', startChapter: 1)),
                        icon: const Icon(Icons.close, size: 20, color: kMuted),
                        constraints:
                            const BoxConstraints(minWidth: 44, minHeight: 44),
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    const Icon(Icons.menu_book_outlined,
                        size: 20, color: kMuted),
                  ],
                ),
              ),
            ),
          ),
          if (_c.hasCustomStart)
            _switchTile(
              title: 'Cover the whole Bible',
              subtitle: _c.wrapAround
                  ? 'After the end, wrap back to the start so nothing is '
                      'skipped.'
                  : 'Stop at the end — this plan skips what comes before your '
                      'starting point.',
              value: _c.wrapAround,
              onChanged: (v) => _set(_c.copyWith(wrapAround: v)),
            ),

          const SizedBox(height: 26),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_c),
                style: FilledButton.styleFrom(
                  backgroundColor: kInk,
                  foregroundColor: kPaper,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Generate & start'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayOnePreview() {
    final day = _firstDay;
    if (day == null) return const SizedBox(height: 8);
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: kDisabled),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DAY 1',
              style: crimson(
                  fontSize: 11,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w600,
                  color: kMuted)),
          const SizedBox(height: 6),
          Text(
            day.passages
                .map((r) => r.label(CanonLanguage.code))
                .join('   ·   '),
            style: kTitleStyle(18, weight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _builderLabel(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 10),
        child: Text(t,
            style: crimson(
                fontSize: 12,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
                color: kMuted)),
      );

  Widget _switchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final disabled = onChanged == null;
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      activeThumbColor: kInk,
      value: value,
      onChanged: onChanged,
      title: Text(title,
          style: kTitleStyle(17, weight: FontWeight.w500)
              .copyWith(color: disabled ? kMuted : kInk)),
      subtitle: Text(subtitle,
          style: crimson(
              fontSize: 13, color: kMuted, height: 1.3)),
    );
  }

  Widget _orderChip(String label, PlanOrdering order) {
    final selected = _c.ordering == order;
    return Expanded(
      child: InkWell(
        onTap: () => _set(_c.copyWith(ordering: order)),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? kInk : kPaper,
            border: Border.all(color: kInk),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: crimson(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: selected ? kPaper : kInk)),
        ),
      ),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 52,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: kInk),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: kInk),
        ),
      );
}

// --- Search / jump-to-reference ------------------------------------------

class SearchScreen extends StatefulWidget {
  final String translationId;
  const SearchScreen({super.key, required this.translationId});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = false;
  bool _searched = false;
  List<SearchHit> _hits = const [];
  BibleRef? _ref;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _controller.text.trim();
    setState(() {
      _ref = parseReference(q);
      _searched = true;
    });
    if (q.isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    setState(() => _loading = true);
    final hits =
        await searchTranslation(widget.translationId, q, limit: 200);
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _run(),
          style: kTitleStyle(18, weight: FontWeight.w500),
          decoration: const InputDecoration(
            hintText: 'Search text or go to a reference…',
            hintStyle: TextStyle(color: kMuted),
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search, color: kInk),
            onPressed: _run,
          ),
        ],
      ),
      body: _buildResults(),
    );
  }

  Widget _buildResults() {
    return ListView(
      children: [
        if (_ref != null)
          ListTile(
            leading: const Icon(Icons.my_location, color: kInk),
            title: Text('Go to ${_ref!.label(CanonLanguage.code)}',
                style: kTitleStyle(18)),
            onTap: () => Navigator.of(context).pop(_ref),
          ),
        if (_ref != null) const Divider(height: 1, color: Colors.black12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(28),
            child: QuietLoader(),
          ),
        if (!_loading && _searched && _hits.isEmpty && _ref == null)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(
              child: Text('No results', style: TextStyle(color: kMuted)),
            ),
          ),
        if (!_loading)
          for (final h in _hits)
            ListTile(
              title: Text(h.reference,
                  style: kTitleStyle(16, weight: FontWeight.w700)),
              subtitle: Text(h.text, style: kVerseStyle.copyWith(fontSize: 16)),
              onTap: () => Navigator.of(context)
                  .pop(BibleRef(h.book, h.chapter, h.verse)),
            ),
      ],
    );
  }
}

// --- Library: switch between printed Bibles ------------------------------

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final bibles = LibraryStore.bibles;
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(title: Text('My Bibles', style: kTitleStyle(20))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          for (final b in bibles) _bibleTile(b, bibles.length),
          const Divider(height: 1, color: kDisabled),
          ListTile(
            leading: const Icon(Icons.add, color: kInk),
            title: Text('Print a new Bible',
                style: kTitleStyle(18, weight: FontWeight.w600)),
            subtitle: Text('Pick a translation and layout, then lock it in',
                style: crimson(fontSize: 13, color: kMuted)),
            onTap: _printNew,
          ),
        ],
      ),
    );
  }

  Widget _bibleTile(BibleConfig b, int count) {
    final active = b.id == LibraryStore.activeId;
    final t = translationById(b.translationId);
    return ListTile(
      leading:
          Icon(active ? Icons.bookmark : Icons.bookmark_border, color: kInk),
      title: Text(b.name.isEmpty ? t.displayName : b.name,
          style: kTitleStyle(18,
              weight: active ? FontWeight.w700 : FontWeight.w500)),
      subtitle: Text(
          '${t.displayName} · ${b.fontFamily} · ${b.fontSizePt.round()}pt',
          style: crimson(fontSize: 13, color: kMuted)),
      trailing: (!active && count > 1)
          ? IconButton(
              icon: const Icon(Icons.delete_outline, color: kMuted),
              tooltip: 'Delete',
              onPressed: () => _delete(b),
            )
          : null,
      onTap: () async {
        await LibraryStore.setActive(b.id);
        if (mounted) Navigator.of(context).pop(true);
      },
    );
  }

  Future<void> _printNew() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const UiScaled(child: SetupWizard())),
    );
    if (created == true && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete(BibleConfig b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kPaper,
        title: Text('Delete this Bible?', style: kTitleStyle(18)),
        content: Text(
            'Its handwritten notes will be removed too. This cannot be undone.',
            style: crimson(fontSize: 15, color: kInk)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: kInk))),
        ],
      ),
    );
    if (ok == true) {
      await DrawingStore.discardNotesFor(b.id);
      await LibraryStore.remove(b.id);
      if (mounted) setState(() {});
    }
  }
}

// --- Setup wizard: "Print your Bible" ------------------------------------
//
// A one-time, minimal "crafting" flow. Choices are made here and then locked,
// which is what keeps notes aligned forever. No printing-press animation (poor
// on e-ink) — just a short, intentional beat.

class SetupWizard extends StatefulWidget {
  /// Called when there is no route to pop to (first-run, shown as the app root).
  final Future<void> Function()? onComplete;
  const SetupWizard({super.key, this.onComplete});

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  static const int _stepCount = 5;
  int _step = 0;

  String _translation = kDefaultTranslation;
  String _family = kFontFamilies.first;
  double _size = 22;
  int _margin = 1;
  int _spacing = 1;
  bool _verseNumbers = true;
  bool _headings = true;
  bool _dropCaps = true; // decorated chapter initials — on for new prints
  bool _justify = false;
  final TextEditingController _name = TextEditingController();
  bool _printing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  TextStyle _sampleStyle() => appFont(_family,
      fontSize: _size, height: kLineSpacings[_spacing], color: kInk);

  Future<void> _print() async {
    setState(() => _printing = true);
    final id =
        LibraryStore.isEmpty ? LibraryStore.defaultId : LibraryStore.newId();
    await LibraryStore.add(BibleConfig(
      id: id,
      name: _name.text.trim(),
      translationId: _translation,
      fontFamily: _family,
      fontSizePt: _size,
      marginIndex: _margin,
      lineSpacingIndex: _spacing,
      showVerseNumbers: _verseNumbers,
      showHeadings: _headings,
      dropCaps: _dropCaps,
      justify: _justify,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 900)); // a beat
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    } else {
      await widget.onComplete?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_printing) {
      return const Scaffold(
        backgroundColor: kPaper,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book, size: 56, color: kInk),
              SizedBox(height: 16),
              Text('Printing your Bible…',
                  style: TextStyle(fontSize: 18, color: kInk)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text('Print your Bible', style: kTitleStyle(20)),
      ),
      body: Column(
        children: [
          _progressDots(),
          Expanded(
            child: IndexedStack(
              index: _step,
              children: [
                _translationStep(),
                _fontStep(),
                _spaceStep(),
                _showStep(),
                _confirmStep(),
              ],
            ),
          ),
          _navBar(),
        ],
      ),
    );
  }

  Widget _progressDots() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _stepCount; i++)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i <= _step ? kInk : kDisabled,
                ),
              ),
          ],
        ),
      );

  Widget _navBar() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Row(
            children: [
              if (_step > 0)
                TextButton(
                  onPressed: () => setState(() => _step--),
                  child: Text('Back',
                      style: crimson(
                          fontSize: 16, color: kMuted)),
                ),
              const Spacer(),
              FilledButton(
                onPressed: _step < _stepCount - 1
                    ? () => setState(() => _step++)
                    : _print,
                style: FilledButton.styleFrom(
                  backgroundColor: kInk,
                  foregroundColor: kPaper,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(_step < _stepCount - 1 ? 'Continue' : 'Print it'),
              ),
            ],
          ),
        ),
      );

  Widget _stepScaffold(String title, String blurb, List<Widget> children) =>
      ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        children: [
          Text(title, style: kTitleStyle(24, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(blurb,
              style:
                  crimson(fontSize: 15, color: kMuted, height: 1.4)),
          const SizedBox(height: 20),
          ...children,
        ],
      );

  Widget _radioRow(String label, String? sub, bool selected, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: selected ? kInk : kDisabled),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: kTitleStyle(18,
                            weight:
                                selected ? FontWeight.w700 : FontWeight.w400)),
                    if (sub != null)
                      Text(sub,
                          style: crimson(
                              fontSize: 13, color: kMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _preview() => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(16),
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(color: kDisabled),
          borderRadius: BorderRadius.circular(8),
        ),
        child: LayoutBuilder(builder: (context, c) {
          // Same split the reader uses, so the preview matches the printed page.
          final m = readingMetricsFor(c.maxWidth,
              marginFraction: kMarginFractions[_margin],
              showVerseNumbers: _verseNumbers);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_verseNumbers)
                SizedBox(
                  width: kGutterWidth,
                  child: Text('1',
                      textAlign: TextAlign.right, style: kVerseNumberStyle),
                ),
              SizedBox(
                width: m.textWidth,
                child: Text.rich(
                  verseSpan(
                      'In the beginning was the Word, and the Word was with '
                      'God, and the Word was God.',
                      _sampleStyle(),
                      dropCap: _dropCaps),
                  textAlign: _justify ? TextAlign.justify : TextAlign.start,
                  textScaler: TextScaler.noScaling,
                ),
              ),
              const Spacer(),
            ],
          );
        }),
      );

  Widget _translationStep() => _stepScaffold(
        'Choose a translation',
        'This is the text of your Bible. It cannot be changed once printed.',
        [
          // All offline translations: the shipped public-domain ones plus any
          // private versions you added locally (assets/bibles_private).
          for (final t in offlineTranslations)
            _radioRow(t.displayName, '${t.language} · ${t.attribution}',
                _translation == t.id, () => setState(() => _translation = t.id)),
        ],
      );

  Widget _fontStep() => _stepScaffold(
        'How do you like to read?',
        'Pick a typeface and size. This sets the feel of every page.',
        [
          for (final f in kFontFamilies)
            _radioRow(f, null, _family == f, () => setState(() => _family = f)),
          const SizedBox(height: 16),
          Text('SIZE',
              style: crimson(
                  fontSize: 12,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600,
                  color: kMuted)),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final s in kFontSizeOptions)
                _chip('${s.round()}', _size == s,
                    () => setState(() => _size = s)),
            ],
          ),
          _preview(),
        ],
      );

  Widget _spaceStep() => _stepScaffold(
        'How much room to write?',
        'Wider margins leave blank space beside the text for your notes.',
        [
          Text('MARGIN',
              style: crimson(
                  fontSize: 12,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600,
                  color: kMuted)),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < kMarginLabels.length; i++)
                _chip(kMarginLabels[i], _margin == i,
                    () => setState(() => _margin = i)),
            ],
          ),
          const SizedBox(height: 16),
          Text('LINE SPACING',
              style: crimson(
                  fontSize: 12,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w600,
                  color: kMuted)),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < kLineSpacingLabels.length; i++)
                _chip(kLineSpacingLabels[i], _spacing == i,
                    () => setState(() => _spacing = i)),
            ],
          ),
          _preview(),
        ],
      );

  Widget _showStep() => _stepScaffold(
        'What to show',
        'A couple of finishing touches for your pages.',
        [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: kInk,
            title: Text('Verse numbers', style: kTitleStyle(18)),
            value: _verseNumbers,
            onChanged: (v) => setState(() => _verseNumbers = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: kInk,
            title: Text('Chapter headings', style: kTitleStyle(18)),
            value: _headings,
            onChanged: (v) => setState(() => _headings = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: kInk,
            title: Text('Decorated chapter initials', style: kTitleStyle(18)),
            subtitle: Text('A large first letter opens each chapter',
                style: crimson(fontSize: 13, color: kMuted)),
            value: _dropCaps,
            onChanged: (v) => setState(() => _dropCaps = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: kInk,
            title: Text('Justified text', style: kTitleStyle(18)),
            subtitle: Text('Even edges on both sides, like a printed page',
                style: crimson(fontSize: 13, color: kMuted)),
            value: _justify,
            onChanged: (v) => setState(() => _justify = v),
          ),
          _preview(),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            style: kTitleStyle(18, weight: FontWeight.w500),
            decoration: InputDecoration(
              labelText: 'Name or dedication (optional)',
              labelStyle: const TextStyle(color: kMuted),
              hintText: 'This Bible belongs to…',
              enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: kDisabled)),
              focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: kInk)),
            ),
          ),
        ],
      );

  Widget _confirmStep() => _stepScaffold(
        'Ready to print',
        'Once printed, the layout is locked so your notes always line up. You '
            'can print another Bible any time.',
        [
          _summaryRow('Translation', translationById(_translation).displayName),
          _summaryRow('Font', '$_family · ${_size.round()}pt'),
          _summaryRow('Margin', kMarginLabels[_margin]),
          _summaryRow('Line spacing', kLineSpacingLabels[_spacing]),
          _summaryRow('Verse numbers', _verseNumbers ? 'On' : 'Off'),
          _summaryRow('Chapter headings', _headings ? 'On' : 'Off'),
          _summaryRow('Chapter initials', _dropCaps ? 'On' : 'Off'),
          _summaryRow('Justified text', _justify ? 'On' : 'Off'),
          if (_name.text.trim().isNotEmpty)
            _summaryRow('Name', _name.text.trim()),
          const SizedBox(height: 16),
          _preview(),
        ],
      );

  Widget _summaryRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(k,
                  style: crimson(fontSize: 15, color: kMuted)),
            ),
            Expanded(
              child: Text(v, style: kTitleStyle(16, weight: FontWeight.w600)),
            ),
          ],
        ),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? kInk : kPaper,
            border: Border.all(color: kInk),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: crimson(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: selected ? kPaper : kInk)),
        ),
      );
}
