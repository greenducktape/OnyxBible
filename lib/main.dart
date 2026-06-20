import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart' show kSecondaryButton, kTertiaryButton;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'package:path_provider/path_provider.dart';

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OnyxSdkPenArea.init();
  await SettingsStore.init();
  await PlanStore.init();
  await LibraryStore.init();
  await _bootstrapLibrary();
  if (!LibraryStore.isEmpty) {
    await DrawingStore.useBible(LibraryStore.active.id);
  }
  runApp(const BooxBibleApp());
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

// --- E-ink design tokens --------------------------------------------------
//
// E-ink panels can't render subtle greys (they dither into noisy stipple), so
// the palette is essentially pure black on white. A single restrained grey is
// reserved for tiny meta labels; a lighter one marks disabled controls.

const Color kInk = Color(0xFF000000);
const Color kMuted = Color(0xFF5F5F5F);
const Color kDisabled = Color(0xFFB4B4B4);
const Color kPaper = Color(0xFFFFFFFF);

// Reading layout. The measure is capped so lines stay comfortable on large
// (10"+) Boox screens, and the column is centred on whatever space remains.
const double kMaxContentWidth = 640;
const double kHPadding = 24;
const double kGutterWidth = 34; // left margin holding the verse number
const double kVerseSpacing = 12; // gap below each verse
const double kChapterHeaderHeight = 144; // reserved on the first page only
const EdgeInsets kPageVPadding = EdgeInsets.symmetric(vertical: 16);

// --- Shared typography ----------------------------------------------------
//
// The verse body style is size-adjustable. It MUST be built with the active
// size both where pagination measures and where the verse renders, otherwise
// pages overflow or leave gaps. Reader screen builds it once per frame and
// threads it through, so it isn't reconstructed per verse.

// Reading-layout options offered once, in the "Print your Bible" setup. After a
// Bible is printed these are locked — which is exactly what keeps handwritten
// notes aligned forever.
const List<double> kFontSizeOptions = [18, 20, 22, 26, 30, 36];
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

/// Verse body style for a printed Bible's locked layout (family/size/spacing).
TextStyle verseStyleForCfg(BibleConfig c) => GoogleFonts.getFont(
      c.fontFamily,
      fontSize: c.fontSizePt,
      height: kLineSpacings[c.lineSpacingIndex.clamp(0, kLineSpacings.length - 1)],
      color: kInk,
    );

/// Plain size-only serif style — used by setup previews and small chrome.
TextStyle verseStyleOf(double fontSize) =>
    GoogleFonts.crimsonPro(fontSize: fontSize, height: 1.55, color: kInk);

final TextStyle kVerseStyle = verseStyleOf(22);
final TextStyle kVerseNumberStyle = GoogleFonts.crimsonPro(
  fontSize: 13,
  height: 1.2,
  color: kMuted,
  fontWeight: FontWeight.w700,
);

TextStyle kTitleStyle(double size, {FontWeight weight = FontWeight.w600}) =>
    GoogleFonts.crimsonPro(fontSize: size, fontWeight: weight, color: kInk);

// --- Data Models ----------------------------------------------------------

class StrokePoint {
  final double x;
  final double y;
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
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final Map<String, dynamic> data = json.decode(content);
          _notes.addAll(data.map((key, value) => MapEntry(
              key,
              (value as List)
                  .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
                  .toList())));
        }
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

  static Future<void> _save() async {
    final id = _bibleId;
    if (id == null) return;
    try {
      final file = await _noteFile(id);
      final data = _notes.map(
          (key, value) => MapEntry(key, value.map((s) => s.toJson()).toList()));
      await file.writeAsString(json.encode(data));
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
}

// --- Pagination cache -----------------------------------------------------
//
// Caches the layout (verses split into pages) per book/chapter/size/style.
// Verse text itself now comes from ScriptureSource (offline bundle), which
// does its own lightweight caching.

class PageCache {
  static final Map<String, List<List<Verse>>> _pages = {};

  static List<List<Verse>>? get(String key) => _pages[key];
  static void put(String key, List<List<Verse>> pages) => _pages[key] = pages;
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
      theme: base.copyWith(textTheme: GoogleFonts.crimsonProTextTheme(base.textTheme)),
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
    return SetupWizard(onComplete: () async {
      await DrawingStore.useBible(LibraryStore.active.id);
      if (mounted) setState(() => _hasBible = true);
    });
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

/// How a pen renders its committed ink. Width is the nib size modulated by
/// stylus pressure between [lo] (light touch) and [hi] (hard press), giving the
/// Boox-notetaker "weight" feel — press harder for a thicker line. Anti-aliasing
/// is always off when painting (see _paintStroke) so a line keeps the same
/// thickness through the e-ink GC refresh instead of "fattening" a second later.
class PenRecipe {
  final double lo; // width multiplier at zero pressure
  final double hi; // width multiplier at full pressure
  final bool taperEnds; // ramp width down over the first/last few points
  final StrokeCap cap;
  final double opacity; // applied to the stroke colour (marker = translucent)

  const PenRecipe({
    this.lo = 0.85,
    this.hi = 1.1,
    this.taperEnds = false,
    this.cap = StrokeCap.round,
    this.opacity = 1.0,
  });
}

const Map<String, PenRecipe> _kPenRecipes = {
  // Near-uniform — a dependable everyday line.
  'ballpoint': PenRecipe(lo: 0.85, hi: 1.1),
  // Strong pressure response + end taper, like a real nib.
  'fountain': PenRecipe(lo: 0.4, hi: 1.25, taperEnds: true),
  // Widest dynamic range.
  'brush': PenRecipe(lo: 0.3, hi: 1.6, taperEnds: true),
  // Thin and a touch lighter.
  'pencil': PenRecipe(lo: 0.7, hi: 1.0, opacity: 0.9),
  // Highlighter: flat, wide, translucent; pressure-independent.
  'marker': PenRecipe(lo: 1.0, hi: 1.0, cap: StrokeCap.butt, opacity: 0.32),
};

PenRecipe penRecipeFor(String id) =>
    _kPenRecipes[id] ?? _kPenRecipes['ballpoint']!;

/// Paints one stroke with its pen recipe. Anti-aliasing is OFF so the line looks
/// identical under an e-ink partial update and after the full GC refresh (no
/// post-commit "fattening"). Width follows captured pressure for a weight feel.
void _paintStroke(Canvas canvas, Stroke stroke, Size size) {
  final pts = stroke.points;
  if (pts.isEmpty) return;

  // Map capture-time coordinates onto the current canvas (1:1 for unchanged
  // layouts and legacy strokes).
  final (sx, sy) = stroke.scaleTo(size);
  Offset at(StrokePoint p) => Offset(p.x * sx, p.y * sy);

  final recipe = penRecipeFor(stroke.style);
  final base = stroke.width;
  final color = recipe.opacity >= 1.0
      ? stroke.color
      : stroke.color.withValues(alpha: recipe.opacity);

  final paint = Paint()
    ..color = color
    ..isAntiAlias = false
    ..strokeCap = recipe.cap
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;

  double widthAt(int i) {
    final p = pts[i].pressure.clamp(0.0, 1.0);
    var w = base * (recipe.lo + (recipe.hi - recipe.lo) * p);
    if (recipe.taperEnds) {
      final edge = math.min(i, pts.length - 1 - i);
      if (edge < 3) w *= 0.55 + 0.15 * edge; // soften the first/last few points
    }
    return w;
  }

  if (pts.length == 1) {
    paint.strokeWidth = widthAt(0);
    canvas.drawPoints(PointMode.points, [at(pts.first)], paint);
    return;
  }
  for (var i = 0; i < pts.length - 1; i++) {
    paint.strokeWidth = (widthAt(i) + widthAt(i + 1)) / 2;
    canvas.drawLine(at(pts[i]), at(pts[i + 1]), paint);
  }
}

class BibleReaderScreen extends StatefulWidget {
  const BibleReaderScreen({super.key});

  @override
  State<BibleReaderScreen> createState() => _BibleReaderScreenState();
}

class _BibleReaderScreenState extends State<BibleReaderScreen> {
  // Initialized from persisted settings in initState (resume last position).
  late String _book;
  late int _chapter;

  // Scripture comes from the bundled (offline) translation by default; other
  // translations can be swapped in via the registry without touching this code.
  late ScriptureSource _source;

  List<Verse> _verses = [];
  bool _isLoading = true;
  bool _hasError = false;

  // Drawing tools. A wider range of nib sizes; default to a fine line.
  static const List<double> _widths = [1.0, 1.5, 2.0, 3.0, 4.5, 6.0];
  int _widthIndex = 1;
  int _presetIndex = 0; // ballpoint — uniform, matches commit no-fattening
  PenTool _tool = PenTool.pen;

  PenPreset get _preset => kPenPresets[_presetIndex];
  // Effective width: nib size scaled by the preset's bias.
  double get _penWidth => _widths[_widthIndex] * _preset.widthScale;
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

  // Bumping this flips [OnyxSdkPenArea.refreshDelay] by 1ms, which makes the
  // native side run a full e-ink (GC) refresh to clear pen ghosting.
  int _refreshTick = 0;

  // When navigating from search to a specific verse, the page containing it is
  // selected after pagination; consumed (set to null) once applied.
  int? _targetVerse;

  // Non-null while reading inside a plan (drives plan-order navigation + the
  // banner + auto-complete). Cleared by any manual navigation.
  PlanSession? _session;

  @override
  void initState() {
    super.initState();
    _applyActiveBible();
    _widthIndex =
        SettingsStore.value.widthIndex.clamp(0, _widths.length - 1).toInt();
    _loadChapter();
  }

  // Adopt the active printed Bible's locked layout + reading position.
  void _applyActiveBible() {
    _cfg = LibraryStore.active;
    _book = _cfg.lastBook;
    _chapter = _cfg.lastChapter;
    _source = sourceFor(translationById(_cfg.translationId));
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _persist() {
    // Reading position lives on the (otherwise locked) Bible; stroke width is a
    // global tool preference, not part of the printed layout.
    LibraryStore.rememberPosition(_book, _chapter);
    SettingsStore.update(SettingsStore.value.copyWith(widthIndex: _widthIndex));
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
    setState(() {
      _verses = verses;
      _isLoading = false;
      _hasError = false;
      _page = 0;
    });
    // If a search target is pending, the page is chosen during build instead.
    if (_targetVerse == null) _resetToFirstPage();
  }

  void _resetToFirstPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) _pageController.jumpToPage(0);
    });
  }

  void _forceRefresh() => setState(() => _refreshTick++);

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
        builder: (_) =>
            BookPickerScreen(currentBook: _book, currentChapter: _chapter),
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
      MaterialPageRoute(builder: (_) => screen),
    );
    if (ref == null) return;
    _targetVerse = ref.verse;
    _goToChapter(ref.book, ref.chapter);
  }

  Future<void> _openMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in const [
              ('search', Icons.search, 'Search'),
              ('plans', Icons.event_note, 'Reading plans'),
              ('notes', Icons.gesture, 'My notes'),
              ('library', Icons.auto_stories_outlined, 'My Bibles'),
            ])
              ListTile(
                leading: Icon(item.$2, color: kInk),
                title: Text(item.$3, style: kTitleStyle(18)),
                onTap: () => Navigator.of(context).pop(item.$1),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'search':
        await _openScreen(SearchScreen(translationId: _source.translationId));
      case 'plans':
        await _openPlans();
      case 'notes':
        await _openScreen(const NotesBrowserScreen());
      case 'library':
        await _openLibrary();
    }
  }

  // Plans can pop either a PlanSession (start reading the plan) or a BibleRef.
  Future<void> _openPlans() async {
    final result = await Navigator.of(context)
        .push<Object>(MaterialPageRoute(builder: (_) => const PlansScreen()));
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
      MaterialPageRoute(builder: (_) => const LibraryScreen()),
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
      painter.text = TextSpan(text: v.text, style: verseStyle);
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

  // High-contrast strip shown while reading inside a plan. Lives OUTSIDE the
  // pen area, so the pen can't draw on it.
  Widget _buildPlanBanner(PlanSession s) {
    final passages = s.dayPassages.map((r) => '${r.book} ${r.chapter}').join('  →  ');
    return Container(
      color: kInk,
      padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.event_note, size: 16, color: kPaper),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'PLAN · DAY ${s.dayIndex + 1} OF ${s.plan.length} · '
                    '${s.cursor + 1}/${s.passageCount}',
                    style: GoogleFonts.crimsonPro(
                        fontSize: 10,
                        color: kPaper,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5)),
                Text(passages,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.crimsonPro(
                        fontSize: 15,
                        color: kPaper,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Leave plan',
            icon: const Icon(Icons.close, size: 20, color: kPaper),
            onPressed: () => setState(() => _session = null),
          ),
        ],
      ),
    );
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(),
            _buildPenRail(),
            if (_session != null) _buildPlanBanner(_session!),
            // The pen-capture area is ONLY the page, so native ink can't land
            // on the toolbar or the bottom navigation.
            Expanded(
              child: OnyxSdkPenArea(
                // A 1ms flip of refreshDelay triggers a native full e-ink
                // refresh that clears pen ghosting after page/chapter changes.
                refreshDelay: Duration(milliseconds: 1200 + (_refreshTick % 2)),
                // Active pen preset chooses the native style. The default
                // ballpoint is uniform-width, so the committed Flutter stroke
                // matches the live preview (no post-refresh fattening).
                strokeStyle: _preset.nativeStyle,
                strokeColor: _isEraser ? Colors.white : Colors.black,
                strokeWidth: _penWidth,
                child: _buildBody(),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  // A deliberately minimal toolbar — the Bible is the artifact, not an app full
  // of controls. Only reading/writing tools live here; layout is locked.
  Widget _buildTopBar() {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDisabled, width: 1)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Menu',
            icon: const Icon(Icons.menu, color: kInk),
            onPressed: _openMenu,
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openPicker,
              child: Row(
                children: [
                  Flexible(
                    child: Text('$_book $_chapter',
                        overflow: TextOverflow.ellipsis,
                        style: kTitleStyle(20)),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.expand_more, size: 18, color: kMuted),
                ],
              ),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: kUndo.canUndo,
            builder: (context, can, _) => IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo),
              color: kInk,
              disabledColor: kDisabled,
              onPressed: can ? () => kUndo.undo() : null,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: kUndo.canRedo,
            builder: (context, can, _) => IconButton(
              tooltip: 'Redo',
              icon: const Icon(Icons.redo),
              color: kInk,
              disabledColor: kDisabled,
              onPressed: can ? () => kUndo.redo() : null,
            ),
          ),
          IconButton(
            tooltip: 'Refresh screen',
            icon: const Icon(Icons.autorenew, color: kInk),
            onPressed: _forceRefresh,
          ),
        ],
      ),
    );
  }

  // A flat writing rail: every pen is one tap away (no nested menu), with the
  // eraser and a row of nib sizes beside it. Selection is shown by a thin ink
  // underline rather than chips/elevation — closer to a notetaker's tool strip
  // than an app toolbar.
  Widget _buildPenRail() {
    return Container(
      height: 46,
      decoration: const BoxDecoration(
        color: kPaper,
        border: Border(bottom: BorderSide(color: kDisabled, width: 1)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          for (var i = 0; i < kPenPresets.length; i++)
            _railTool(
              icon: kPenPresets[i].icon,
              tooltip: kPenPresets[i].label,
              selected: !_isEraser && _presetIndex == i,
              onTap: () => setState(() {
                _presetIndex = i;
                _tool = PenTool.pen;
              }),
            ),
          _railTool(
            icon: Icons.cleaning_services_outlined,
            tooltip: 'Eraser',
            selected: _isEraser,
            onTap: () => setState(
                () => _tool = _isEraser ? PenTool.pen : PenTool.eraser),
          ),
          const SizedBox(width: 6),
          Container(width: 1, height: 24, color: kDisabled),
          const SizedBox(width: 6),
          for (var i = 0; i < _widths.length; i++) _railNib(i),
          const Spacer(),
        ],
      ),
    );
  }

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
        radius: 26,
        child: Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? kInk : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Icon(icon, size: 23, color: selected ? kInk : kMuted),
        ),
      ),
    );
  }

  // A dot whose size tracks the nib width; the selected one is filled.
  Widget _railNib(int i) {
    final selected = !_isEraser && _widthIndex == i;
    final d = (5 + _widths[i] * 1.5).clamp(6.0, 17.0);
    return Tooltip(
      message: _widths[i].toStringAsFixed(1),
      child: InkResponse(
        onTap: () => setState(() {
          _widthIndex = i;
          _persist();
        }),
        radius: 22,
        child: SizedBox(
          width: 34,
          height: 46,
          child: Center(
            child: Container(
              width: d,
              height: d,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? kInk : Colors.transparent,
                border: Border.all(
                    color: selected ? kInk : kMuted, width: 1.4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: kInk));
    }
    if (_hasError) {
      return Center(
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
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth =
            math.min(constraints.maxWidth - kHPadding * 2, kMaxContentWidth);
        final gutter = _cfg.showVerseNumbers ? kGutterWidth : 0.0;
        final textColumn = contentWidth * _marginFraction; // rest = writing margin
        final textWidth = textColumn - gutter;
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
          onPageChanged: (i) {
            setState(() => _page = i);
            _forceRefresh();
          },
          itemBuilder: (context, i) {
            final pageKey = '${_book}_$_chapter#$i';
            return Stack(
              fit: StackFit.expand,
              children: [
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
                    isEraser: _isEraser,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final canPrevChapter = prevChapterOf(_book, _chapter) != null;
    final canNextChapter = nextChapterOf(_book, _chapter) != null;
    final atStart = _page == 0 && !canPrevChapter;
    final atEnd = _page >= _pageCount - 1 && !canNextChapter;

    return SafeArea(
      top: false,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            _NavButton(
                icon: Icons.first_page,
                tooltip: 'Previous chapter',
                onPressed: canPrevChapter ? _prevChapter : null),
            _NavButton(
                icon: Icons.chevron_left,
                tooltip: 'Previous page',
                onPressed: atStart ? null : _prevPage),
            Expanded(
              child: Center(
                child: Text(
                  _pageCount > 0 ? '${_page + 1} / $_pageCount' : '–',
                  style: GoogleFonts.crimsonPro(
                      fontSize: 15, color: kMuted, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            _NavButton(
                icon: Icons.chevron_right,
                tooltip: 'Next page',
                onPressed: atEnd ? null : _nextPage),
            _NavButton(
                icon: Icons.last_page,
                tooltip: 'Next chapter',
                onPressed: canNextChapter ? _nextChapter : null),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _NavButton(
      {required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 26),
      color: kInk,
      disabledColor: kDisabled,
      onPressed: onPressed,
    );
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
            book.toUpperCase(),
            style: GoogleFonts.crimsonPro(
              fontSize: 13,
              letterSpacing: 4,
              fontWeight: FontWeight.w600,
              color: kMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$chapter',
            style: GoogleFonts.crimsonPro(
                fontSize: 64, fontWeight: FontWeight.w500, color: kInk),
          ),
          const SizedBox(height: 10),
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

  const VerseText({
    super.key,
    required this.verse,
    required this.verseStyle,
    required this.textWidth,
    required this.showNumber,
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
          SizedBox(width: textWidth, child: Text(verse.text, style: verseStyle)),
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
  final bool isEraser;

  const PageInk({
    super.key,
    required this.pageKey,
    required this.penWidth,
    required this.penStyle,
    required this.isEraser,
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
  Size? _canvasSize; // reported by the painter; used for capture box + eraser
  final List<Stroke> _erasedThisGesture = [];

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

  // Erase when the eraser tool is on, the pen is flipped to its eraser end, OR
  // a stylus side/eraser button is held (many e-ink pens report it that way).
  bool _erasing(PointerEvent e) =>
      widget.isEraser ||
      e.kind == PointerDeviceKind.invertedStylus ||
      (e.buttons & (kSecondaryButton | kTertiaryButton)) != 0;

  void _onDown(PointerDownEvent e) {
    if (!_isStylus(e)) return;
    if (_erasing(e)) {
      _eraseAt(e.localPosition);
      return;
    }
    _active = Stroke(
      points: [StrokePoint(e.localPosition.dx, e.localPosition.dy, e.pressure)],
      width: widget.penWidth,
      style: widget.penStyle,
      captureW: _canvasSize?.width ?? 0,
      captureH: _canvasSize?.height ?? 0,
    );
    _activeRepaint.value++;
  }

  void _onMove(PointerMoveEvent e) {
    if (!_isStylus(e)) return;
    if (_erasing(e)) {
      _eraseAt(e.localPosition);
      return;
    }
    if (_active == null) return;
    _active!.points
        .add(StrokePoint(e.localPosition.dx, e.localPosition.dy, e.pressure));
    // Only the active layer repaints — committed strokes are untouched.
    _activeRepaint.value++;
  }

  void _onUp(PointerUpEvent e) {
    if (_active != null) {
      if (_active!.points.length > 1) {
        _strokes.add(_active!);
        DrawingStore.setStrokes(widget.pageKey, _strokes);
        kUndo.recordAdd(widget.pageKey, _active!);
      }
      _active = null;
      // The new stroke now lives in the committed layer; clear the active one.
      _committedRepaint.value++;
      _activeRepaint.value++;
    }
    if (_erasedThisGesture.isNotEmpty) {
      kUndo.recordErase(widget.pageKey, List<Stroke>.of(_erasedThisGesture));
      _erasedThisGesture.clear();
    }
  }

  void _eraseAt(Offset p) {
    final removed = _strokes
        .where((s) => s.isNear(p, _eraseRadius, canvas: _canvasSize))
        .toList();
    if (removed.isEmpty) return;
    _erasedThisGesture.addAll(removed);
    _strokes.removeWhere((s) => removed.contains(s));
    DrawingStore.setStrokes(widget.pageKey, _strokes);
    _committedRepaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Committed ink: its own RepaintBoundary so a move never redraws it.
          RepaintBoundary(
            child: CustomPaint(
              painter: _CommittedPainter(
                strokes: _strokes,
                repaint: _committedRepaint,
                onPaintSize: (s) => _canvasSize = s,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          // In-progress stroke on top — the only thing repainting mid-stroke.
          CustomPaint(
            painter: _ActivePainter(
              active: () => _active,
              repaint: _activeRepaint,
            ),
            child: const SizedBox.expand(),
          ),
        ],
      ),
    );
  }
}

class _CommittedPainter extends CustomPainter {
  final List<Stroke> strokes;

  // Reports the actual canvas size on every paint. The page uses it to stamp
  // capture boxes on new strokes and to hit-test the eraser in canvas space.
  final ValueChanged<Size>? onPaintSize;

  _CommittedPainter({
    required this.strokes,
    required Listenable repaint,
    this.onPaintSize,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    onPaintSize?.call(size);
    for (final s in strokes) {
      _paintStroke(canvas, s, size);
    }
  }

  @override
  bool shouldRepaint(covariant _CommittedPainter old) => old.strokes != strokes;
}

class _ActivePainter extends CustomPainter {
  final Stroke? Function() active;

  _ActivePainter({required this.active, required Listenable repaint})
      : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final a = active();
    if (a != null) _paintStroke(canvas, a, size);
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
          book == null ? 'Contents' : book.name,
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
        _sectionHeader('Old Testament'),
        ...ot.map(_bookTile),
        _sectionHeader('New Testament'),
        ...nt.map(_bookTile),
      ],
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
        child: Text(
          label.toUpperCase(),
          style: GoogleFonts.crimsonPro(
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
                b.name,
                style: kTitleStyle(19,
                    weight: isCurrent ? FontWeight.w700 : FontWeight.w400),
              ),
            ),
            Text('${b.chapters}',
                style: GoogleFonts.crimsonPro(color: kMuted, fontSize: 14)),
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
              style: GoogleFonts.crimsonPro(
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
                                '${e.ref.book} ${e.ref.chapter}',
                                style: kTitleStyle(18, weight: FontWeight.w700),
                              ),
                            ),
                            const Icon(Icons.gesture, size: 16, color: kMuted),
                            const SizedBox(width: 5),
                            Text(marks,
                                style: GoogleFonts.crimsonPro(
                                    color: kMuted, fontSize: 13)),
                          ],
                        ),
                        if (e.preview != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            e.preview!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.crimsonPro(
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
      MaterialPageRoute(builder: (_) => const PlanBuilderScreen()),
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
      d.passages.map((r) => '${r.book} ${r.chapter}').join('  ·  ');

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
          ? const Center(child: CircularProgressIndicator(color: kInk))
          : (detail == null ? _libraryView() : _detailView(detail)),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
        child: Text(text,
            style: GoogleFonts.crimsonPro(
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
              style: GoogleFonts.crimsonPro(
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
                      style: GoogleFonts.crimsonPro(
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
            style: GoogleFonts.crimsonPro(fontSize: 15, color: kInk)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:
                Text('Keep', style: GoogleFonts.crimsonPro(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete',
                style: GoogleFonts.crimsonPro(
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
              style: GoogleFonts.crimsonPro(fontSize: 16, color: kMuted)),
        ),
      );
    }
    return _progressView(sp, generatePlan(g, sp.config, id: sp.id));
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
                        GoogleFonts.crimsonPro(fontSize: 14, color: kMuted)),
                if (s.streak > 0) ...[
                  Text('   ·   ',
                      style: GoogleFonts.crimsonPro(color: kMuted)),
                  Text('${s.streak}-day streak',
                      style: GoogleFonts.crimsonPro(
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
                style: GoogleFonts.crimsonPro(
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
                style: GoogleFonts.crimsonPro(
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
                        child: Text(
                            '${day.passages[pi].book} ${day.passages[pi].chapter}',
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
                        style: GoogleFonts.crimsonPro(
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
                      style: GoogleFonts.crimsonPro(
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
                style: GoogleFonts.crimsonPro(
                    fontSize: 15, color: kMuted, height: 1.4)),
            if (sp.completedCount > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _undo,
                  child: Text('Reopen last reading',
                      style: GoogleFonts.crimsonPro(
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
                        style: GoogleFonts.crimsonPro(
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
              GoogleFonts.crimsonPro(fontSize: 13, color: kMuted, height: 1.4),
        ),
      );

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
    if (mounted) setState(() {});
  }

  void _set(PlanConfig next) => setState(() => _c = next);

  // Day-1 passages for the preview. Needs the graph for the NT pairing.
  PlanDay? get _firstDay {
    final g = _graph;
    if (g == null) return null;
    final days = generatePlan(g, _c, id: 'preview').days;
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
                        GoogleFonts.crimsonPro(fontSize: 14, color: kInk)),
                const SizedBox(height: 12),
                Text(narrativeFor(_c),
                    style: GoogleFonts.crimsonPro(
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
              style: GoogleFonts.crimsonPro(
                  fontSize: 11,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w600,
                  color: kMuted)),
          const SizedBox(height: 6),
          Text(
            day.passages.map((r) => '${r.book} ${r.chapter}').join('   ·   '),
            style: kTitleStyle(18, weight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _builderLabel(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 10),
        child: Text(t,
            style: GoogleFonts.crimsonPro(
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
          style: GoogleFonts.crimsonPro(
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
              style: GoogleFonts.crimsonPro(
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
        await searchBundledTranslation(widget.translationId, q, limit: 200);
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
            title: Text('Go to ${_ref!}', style: kTitleStyle(18)),
            onTap: () => Navigator.of(context).pop(_ref),
          ),
        if (_ref != null) const Divider(height: 1, color: Colors.black12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator(color: kInk)),
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
                style: GoogleFonts.crimsonPro(fontSize: 13, color: kMuted)),
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
          style: GoogleFonts.crimsonPro(fontSize: 13, color: kMuted)),
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
      MaterialPageRoute(builder: (_) => const SetupWizard()),
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
            style: GoogleFonts.crimsonPro(fontSize: 15, color: kInk)),
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
  final TextEditingController _name = TextEditingController();
  bool _printing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  TextStyle _sampleStyle() => GoogleFonts.getFont(_family,
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
                      style: GoogleFonts.crimsonPro(
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
                  GoogleFonts.crimsonPro(fontSize: 15, color: kMuted, height: 1.4)),
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
                          style: GoogleFonts.crimsonPro(
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
          final textColumn = c.maxWidth * kMarginFractions[_margin];
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
                width: textColumn - (_verseNumbers ? kGutterWidth : 0),
                child: Text(
                    'In the beginning was the Word, and the Word was with '
                    'God, and the Word was God.',
                    style: _sampleStyle()),
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
          for (final t in kTranslations.where((t) => t.bundled))
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
              style: GoogleFonts.crimsonPro(
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
              style: GoogleFonts.crimsonPro(
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
              style: GoogleFonts.crimsonPro(
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
                  style: GoogleFonts.crimsonPro(fontSize: 15, color: kMuted)),
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
              style: GoogleFonts.crimsonPro(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: selected ? kPaper : kInk)),
        ),
      );
}
