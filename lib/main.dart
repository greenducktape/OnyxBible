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
  await DrawingStore.useBible(LibraryStore.active.id);
  runApp(const BooxBibleApp());
}

/// Ensures there is at least one printed Bible. Existing users (who have a
/// settings file) are migrated into a single "default" Bible so their notes and
/// translation carry over; fresh installs get a default Bible for now (the
/// setup wizard will replace this branch).
Future<void> _bootstrapLibrary() async {
  if (!LibraryStore.isEmpty) return;
  const id = LibraryStore.defaultId;
  if (await SettingsStore.fileExists()) {
    await LibraryStore.add(BibleConfig.fromLegacySettings(id, SettingsStore.value));
  } else {
    await LibraryStore.add(
        BibleConfig(id: id, createdAt: DateTime.now().millisecondsSinceEpoch));
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

// Reading text sizes the user can step through. Index 1 (22pt) is the default
// and matches the app's original fixed size.
const List<double> kTextSizes = [18, 22, 26, 31, 37];

TextStyle verseStyleOf(double fontSize) =>
    GoogleFonts.crimsonPro(fontSize: fontSize, height: 1.55, color: kInk);

/// Default verse style (22pt). Kept for code/tests that don't vary the size.
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

  Stroke({
    required this.points,
    this.width = 2.5,
    this.color = Colors.black,
    this.captureW = 0,
    this.captureH = 0,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => p.toJson()).toList(),
        'width': width,
        'color': color.toARGB32(),
        if (captureW > 0) 'cw': captureW,
        if (captureH > 0) 'ch': captureH,
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
      home: const BibleReaderScreen(),
    );
  }
}

enum PenTool { pen, eraser }

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

  // Drawing tools.
  static const List<double> _widths = [2.0, 3.5, 6.0];
  int _widthIndex = 1;
  PenTool _tool = PenTool.pen;

  double get _penWidth => _widths[_widthIndex];
  bool get _isEraser => _tool == PenTool.eraser;

  // Reading text size (index into kTextSizes).
  int _textScaleIndex = 1;
  double get _fontSize => kTextSizes[_textScaleIndex];

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

  @override
  void initState() {
    super.initState();
    final s = SettingsStore.value;
    _book = s.lastBook;
    _chapter = s.lastChapter;
    _widthIndex = s.widthIndex.clamp(0, _widths.length - 1).toInt();
    _textScaleIndex = s.textScaleIndex.clamp(0, kTextSizes.length - 1).toInt();
    _source = sourceFor(translationById(s.translation));
    _loadChapter();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _persist() {
    SettingsStore.update(SettingsStore.value.copyWith(
      lastBook: _book,
      lastChapter: _chapter,
      widthIndex: _widthIndex,
      translation: _source.translationId,
      textScaleIndex: _textScaleIndex,
    ));
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

  void _setTextScale(int index) {
    final next = index.clamp(0, kTextSizes.length - 1);
    if (next == _textScaleIndex) return;
    setState(() {
      _textScaleIndex = next;
      // The page count changes with the size; rebuild from page 0 so we never
      // land past the (now shorter/longer) end of the chapter.
      _page = 0;
    });
    _persist();
    _resetToFirstPage();
    _forceRefresh(); // clear ghosting from the reflow
  }

  void _setTranslation(String id) {
    if (id == _source.translationId) return;
    setState(() {
      _source = sourceFor(translationById(id));
      _page = 0;
    });
    _persist();
    // Notes are keyed by language-independent verse ids, so they carry over to
    // the same verses in the new translation. Pagination is cached per id.
    _loadChapter();
  }

  Future<void> _openTranslationSheet() async {
    final bundled = kTranslations.where((t) => t.bundled).toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text('TRANSLATION',
                  style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                      color: kMuted)),
            ),
            for (final t in bundled)
              InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  _setTranslation(t.id);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 26,
                        child: t.id == _source.translationId
                            ? const Icon(Icons.check, size: 20, color: kInk)
                            : null,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.displayName,
                                style: kTitleStyle(19,
                                    weight: t.id == _source.translationId
                                        ? FontWeight.w700
                                        : FontWeight.w400)),
                            Text('${t.language} · ${t.attribution}',
                                style: GoogleFonts.crimsonPro(
                                    fontSize: 13, color: kMuted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _openTextSizeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kPaper,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void change(int delta) {
            _setTextScale(_textScaleIndex + delta);
            setSheet(() {}); // refresh the sheet's own preview
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TEXT SIZE',
                      style: GoogleFonts.crimsonPro(
                          fontSize: 12,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w600,
                          color: kMuted)),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _SizeStepButton(
                        label: 'A',
                        small: true,
                        onPressed:
                            _textScaleIndex > 0 ? () => change(-1) : null,
                      ),
                      Expanded(
                        child: Center(
                          child: Text('Aa',
                              style: verseStyleOf(_fontSize)
                                  .copyWith(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      _SizeStepButton(
                        label: 'A',
                        small: false,
                        onPressed: _textScaleIndex < kTextSizes.length - 1
                            ? () => change(1)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text('${_textScaleIndex + 1} of ${kTextSizes.length}',
                        style: GoogleFonts.crimsonPro(
                            fontSize: 14, color: kMuted)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- Navigation ---------------------------------------------------------

  void _goToChapter(String book, int chapter) {
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
    } else {
      _nextChapter();
    }
  }

  void _prevPage() {
    if (_page > 0) {
      _pageController.jumpToPage(_page - 1);
    } else {
      _prevChapter();
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

  Future<void> _openSearch() async {
    final ref = await Navigator.of(context).push<BibleRef>(
      MaterialPageRoute(
        builder: (_) => SearchScreen(translationId: _source.translationId),
      ),
    );
    if (ref == null) return;
    _targetVerse = ref.verse;
    _goToChapter(ref.book, ref.chapter);
  }

  // --- Pagination ---------------------------------------------------------
  //
  // [textWidth] is the width available to the verse *text* (content minus the
  // number gutter). The first page reserves space for the chapter header.

  List<List<Verse>> _paginate(List<Verse> verses, TextStyle verseStyle,
      double textWidth, double availableHeight) {
    if (verses.isEmpty) return const [];

    final key = '${_source.translationId}_${_book}_${_chapter}_'
        '${_textScaleIndex}_${textWidth.round()}x${availableHeight.round()}';
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

      // The first page is shorter because the chapter header sits on top.
      final cap =
          result.isEmpty ? availableHeight - kChapterHeaderHeight : availableHeight;

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
    return Scaffold(
      appBar: _buildAppBar(),
      body: OnyxSdkPenArea(
        // A 1ms flip of refreshDelay triggers a native full e-ink refresh that
        // clears pen ghosting after page/chapter changes.
        refreshDelay: Duration(milliseconds: 1200 + (_refreshTick % 2)),
        strokeStyle: OnyxStrokeStyle.fountainPen,
        strokeColor: _isEraser ? Colors.white : Colors.black,
        strokeWidth: _penWidth,
        child: _buildBody(),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      titleSpacing: 0,
      title: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openPicker,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$_book $_chapter', style: kTitleStyle(20)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 18, color: kMuted),
          ],
        ),
      ),
      actions: [
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
          tooltip: 'Search',
          icon: const Icon(Icons.search, color: kInk),
          onPressed: _openSearch,
        ),
        IconButton(
          tooltip: 'Text size',
          icon: const Icon(Icons.format_size, color: kInk),
          onPressed: _openTextSizeSheet,
        ),
        IconButton(
          tooltip: 'Translation',
          icon: const Icon(Icons.translate, color: kInk),
          onPressed: _openTranslationSheet,
        ),
        IconButton(
          tooltip: 'Stroke width',
          icon: _WidthGlyph(width: _penWidth, active: !_isEraser),
          onPressed: () {
            setState(() => _widthIndex = (_widthIndex + 1) % _widths.length);
            _persist();
          },
        ),
        IconButton(
          tooltip: _isEraser ? 'Eraser — tap for pen' : 'Pen — tap for eraser',
          icon: _isEraser
              ? Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: kInk,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.cleaning_services,
                      size: 18, color: kPaper),
                )
              : const Icon(Icons.edit, color: kInk),
          onPressed: () => setState(
              () => _tool = _isEraser ? PenTool.pen : PenTool.eraser),
        ),
        IconButton(
          tooltip: 'Refresh screen',
          icon: const Icon(Icons.autorenew, color: kInk),
          onPressed: _forceRefresh,
        ),
        const SizedBox(width: 4),
      ],
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
        final textWidth = contentWidth - kGutterWidth;
        final availableHeight = constraints.maxHeight - kPageVPadding.vertical;
        final verseStyle = verseStyleOf(_fontSize);

        final pages =
            _paginate(_verses, verseStyle, textWidth, availableHeight);
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
            return Padding(
              padding: kPageVPadding,
              child: Center(
                child: SizedBox(
                  width: contentWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (i == 0)
                        ChapterHeader(book: _book, chapter: _chapter),
                      for (final v in pages[i])
                        VerseBlock(
                          key: ValueKey(v.id),
                          verse: v,
                          verseStyle: verseStyle,
                          penWidth: _penWidth,
                          isEraser: _isEraser,
                        ),
                    ],
                  ),
                ),
              ),
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

/// A− / A+ stepper button used in the text-size sheet. [small] renders the
/// "decrease" affordance at a smaller glyph than the "increase" one.
class _SizeStepButton extends StatelessWidget {
  final String label;
  final bool small;
  final VoidCallback? onPressed;
  const _SizeStepButton(
      {required this.label, required this.small, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 64,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: enabled ? kInk : kDisabled),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: GoogleFonts.crimsonPro(
              fontSize: small ? 18 : 30,
              fontWeight: FontWeight.w600,
              color: enabled ? kInk : kDisabled,
            )),
      ),
    );
  }
}

/// Small bar that visualises the current stroke width in the app bar.
class _WidthGlyph extends StatelessWidget {
  final double width;
  final bool active;
  const _WidthGlyph({required this.width, required this.active});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: Container(
          width: 18,
          height: width.clamp(2.0, 8.0),
          decoration: BoxDecoration(
            color: active ? kInk : kDisabled,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

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

// --- Verse + handwriting overlay -----------------------------------------

class VerseBlock extends StatefulWidget {
  final Verse verse;
  final TextStyle verseStyle;
  final double penWidth;
  final bool isEraser;

  const VerseBlock({
    super.key,
    required this.verse,
    required this.verseStyle,
    required this.penWidth,
    required this.isEraser,
  });

  @override
  State<VerseBlock> createState() => _VerseBlockState();
}

class _VerseBlockState extends State<VerseBlock> {
  late List<Stroke> _strokes;
  Stroke? _active;

  // Drives the stroke CustomPaint directly. Mutating points + bumping this
  // repaints ONLY the canvas — no widget rebuild, no text relayout. This is
  // what keeps writing smooth on e-ink.
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  static const double _eraseRadius = 18.0;

  // Latest ink-canvas size, reported by the painter on each paint. Used to
  // stamp capture boxes on new strokes and to hit-test the eraser. The canvas
  // is always painted before it can receive a pointer, so this is set in time.
  Size? _canvasSize;

  // Strokes removed during the current erase gesture, recorded as one undo step.
  final List<Stroke> _erasedThisGesture = [];

  @override
  void initState() {
    super.initState();
    _strokes = DrawingStore.strokesFor(widget.verse.id);
    kUndo.register(widget.verse.id, _resyncFromStore);
  }

  @override
  void dispose() {
    kUndo.unregister(widget.verse.id, _resyncFromStore);
    _repaint.dispose();
    super.dispose();
  }

  // Called by the undo controller after it mutates the store for this verse.
  void _resyncFromStore() {
    if (!mounted) return;
    _strokes = DrawingStore.strokesFor(widget.verse.id);
    _repaint.value++;
  }

  bool _isStylus(PointerEvent e) =>
      e.kind == PointerDeviceKind.stylus ||
      e.kind == PointerDeviceKind.invertedStylus;

  // Erase when the eraser tool is active, when the pen is flipped to its eraser
  // end (inverted stylus), OR when a stylus side/eraser button is held — many
  // e-ink pens report their eraser button as a secondary/tertiary button.
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
      captureW: _canvasSize?.width ?? 0,
      captureH: _canvasSize?.height ?? 0,
    );
    _repaint.value++;
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
    _repaint.value++; // repaint canvas only
  }

  void _onUp(PointerUpEvent e) {
    if (_active != null) {
      if (_active!.points.length > 1) {
        _strokes.add(_active!);
        DrawingStore.setStrokes(widget.verse.id, _strokes);
        kUndo.recordAdd(widget.verse.id, _active!);
      }
      _active = null;
      _repaint.value++;
    }
    if (_erasedThisGesture.isNotEmpty) {
      kUndo.recordErase(widget.verse.id, List<Stroke>.of(_erasedThisGesture));
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
    DrawingStore.setStrokes(widget.verse.id, _strokes);
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      behavior: HitTestBehavior.translucent,
      child: Container(
        margin: const EdgeInsets.only(bottom: kVerseSpacing),
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: kGutterWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6, right: 8),
                    child: Text(
                      '${widget.verse.number}',
                      textAlign: TextAlign.right,
                      style: kVerseNumberStyle,
                    ),
                  ),
                ),
                Expanded(child: Text(widget.verse.text, style: widget.verseStyle)),
              ],
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: StrokePainter(
                    committed: _strokes,
                    active: () => _active,
                    repaint: _repaint,
                    onPaintSize: (s) => _canvasSize = s,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StrokePainter extends CustomPainter {
  final List<Stroke> committed;
  final Stroke? Function() active;

  // Reports the actual canvas size on every paint. The verse uses it to stamp
  // capture boxes on new strokes and to hit-test the eraser in canvas space.
  final ValueChanged<Size>? onPaintSize;

  StrokePainter({
    required this.committed,
    required this.active,
    required Listenable repaint,
    this.onPaintSize,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    onPaintSize?.call(size);
    for (final s in committed) {
      _drawStroke(canvas, s, size);
    }
    final a = active();
    if (a != null) _drawStroke(canvas, a, size);
  }

  void _drawStroke(Canvas canvas, Stroke stroke, Size size) {
    final pts = stroke.points;
    if (pts.isEmpty) return;

    // Map capture-time coordinates onto the current canvas. For unchanged
    // layouts (and legacy strokes) this is a 1:1 identity, so the common path
    // costs only two divisions and a multiply per point.
    final (sx, sy) = stroke.scaleTo(size);
    Offset at(StrokePoint p) => Offset(p.x * sx, p.y * sy);

    final paint = Paint()
      ..color = stroke.color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Constant width — the committed ink matches the live pen preview exactly,
    // so a stroke no longer "fattens" a moment after the pen lifts. (Pressure
    // is still captured and could drive a subtle taper later if wanted.)
    paint.strokeWidth = stroke.width;

    if (pts.length == 1) {
      canvas.drawPoints(PointMode.points, [at(pts.first)], paint);
      return;
    }
    for (int i = 0; i < pts.length - 1; i++) {
      canvas.drawLine(at(pts[i]), at(pts[i + 1]), paint);
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter old) =>
      old.committed != committed;
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
    final noteCount = DrawingStore.annotatedVerseIds().length;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _hubEntry(
          icon: Icons.event_note,
          label: 'Reading plans',
          trailing: PlanStore.value.hasPlan ? 'In progress' : null,
          open: () => const PlansScreen(),
        ),
        if (noteCount > 0)
          _hubEntry(
            icon: Icons.gesture,
            label: 'My notes',
            trailing: '$noteCount ${noteCount == 1 ? 'verse' : 'verses'}',
            open: () => const NotesBrowserScreen(),
          ),
        _sectionHeader('Old Testament'),
        ...ot.map(_bookTile),
        _sectionHeader('New Testament'),
        ...nt.map(_bookTile),
      ],
    );
  }

  // A navigation-hub row that opens [open]; if that screen pops a BibleRef
  // (a chosen verse/passage), the picker forwards it to the reader.
  Widget _hubEntry({
    required IconData icon,
    required String label,
    required String? trailing,
    required Widget Function() open,
  }) =>
      InkWell(
        onTap: () async {
          final ref = await Navigator.of(context).push<BibleRef>(
            MaterialPageRoute(builder: (_) => open()),
          );
          if (ref != null && mounted) Navigator.of(context).pop(ref);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: kInk),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: kTitleStyle(19, weight: FontWeight.w600)),
              ),
              if (trailing != null)
                Text(trailing,
                    style:
                        GoogleFonts.crimsonPro(color: kMuted, fontSize: 14)),
              const Icon(Icons.chevron_right, size: 20, color: kMuted),
            ],
          ),
        ),
      );

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

    final entries = <_NoteEntry>[];
    for (final id in DrawingStore.annotatedVerseIds()) {
      final parsed = parseVerseId(id);
      if (parsed == null) continue;
      final (book, chapter, verse) = parsed;
      entries.add(_NoteEntry(BibleRef(book, chapter, verse),
          DrawingStore.strokeCount(id)));
    }
    entries.sort((a, b) {
      final o = order(a.ref.book).compareTo(order(b.ref.book));
      if (o != 0) return o;
      final c = a.ref.chapter.compareTo(b.ref.chapter);
      if (c != 0) return c;
      return (a.ref.verse ?? 0).compareTo(b.ref.verse ?? 0);
    });
    return entries;
  }

  // Preview text is read from the default bundled translation (notes share one
  // versification across translations, so the reference resolves either way).
  Future<void> _loadPreviews() async {
    final src = BundledScriptureSource(kDefaultTranslation);
    for (final e in _entries) {
      try {
        final verses = await src.chapter(e.ref.book, e.ref.chapter);
        final match = verses.where((v) => v.number == e.ref.verse);
        if (match.isNotEmpty) e.preview = match.first.text;
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
                                '${e.ref.book} ${e.ref.chapter}:${e.ref.verse}',
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
  ReadingPlan? _active;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final graph = await loadXrefGraph();
      if (!mounted) return;
      _graph = graph;
      _rebuildActive();
    } catch (_) {
      // Leave _graph null; the screen shows the plan chooser without a card.
    }
    if (mounted) setState(() => _loading = false);
  }

  void _rebuildActive() {
    final g = _graph;
    final s = PlanStore.value;
    _active = (g != null && s.hasPlan)
        ? planInfoById(s.planId!).build(g, s.totalDays)
        : null;
  }

  Future<void> _start(PlanInfo info) async {
    final days = await _chooseLength(info);
    if (days == null || _graph == null) return;
    PlanStore.start(info.id, days);
    setState(_rebuildActive);
  }

  // Mark the current reading done (advances the self-paced pointer).
  void _complete() => setState(PlanStore.completeCurrent);
  void _undo() => setState(PlanStore.uncompleteLast);

  String _summary(PlanDay d) =>
      d.passages.map((r) => '${r.book} ${r.chapter}').join('  ·  ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPaper,
      appBar: AppBar(title: Text('Reading plans', style: kTitleStyle(20))),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kInk))
          : (_active == null ? _chooseView() : _progressView(_active!)),
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

  // --- No active plan: choose a kind --------------------------------------

  Widget _chooseView() => ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _sectionLabel('CHOOSE A PLAN'),
          ...kPlans.map(_kindTile),
          const SizedBox(height: 24),
          _attribution(),
        ],
      );

  Widget _kindTile(PlanInfo info) => InkWell(
        onTap: () => _start(info),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(info.title,
                        style: kTitleStyle(18, weight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(info.subtitle,
                        style: GoogleFonts.crimsonPro(
                            fontSize: 14, color: kMuted, height: 1.3)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.chevron_right, size: 22, color: kMuted),
            ],
          ),
        ),
      );

  // --- Active plan: self-paced progress -----------------------------------

  Widget _progressView(ReadingPlan plan) {
    final s = PlanStore.value;
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
        if (current != null) _currentCard(done, current) else _finishedCard(),

        // What's coming, so a missed day is never a pile of empty boxes.
        if (upcoming.isNotEmpty) _sectionLabel('COMING UP'),
        for (final i in upcoming)
          _entryRow(label: 'Reading ${i + 1}', day: plan.days[i]),

        if (done > 0) _sectionLabel('ALREADY READ'),
        for (var i = done - 1; i >= 0 && i >= done - 4; i--)
          _entryRow(
              label: 'Reading ${i + 1}', day: plan.days[i], muted: true),

        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: () => setState(() {
              PlanStore.clearPlan();
              _active = null;
            }),
            child: Text('Choose a different plan',
                style: GoogleFonts.crimsonPro(
                    fontSize: 15, color: kInk, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 8),
        _attribution(),
      ],
    );
  }

  Widget _currentCard(int index, PlanDay day) => Container(
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
            for (final ref in day.passages)
              InkWell(
                onTap: () => Navigator.of(context).pop(ref),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('${ref.book} ${ref.chapter}',
                            style: kTitleStyle(20, weight: FontWeight.w500)),
                      ),
                      Icon(
                          bookByName(ref.book).isOldTestament
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

  Widget _finishedCard() => Container(
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
            if (PlanStore.value.completedCount > 0)
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
          required PlanDay day,
          bool muted = false}) =>
      InkWell(
        onTap: day.passages.isEmpty
            ? null
            : () => Navigator.of(context).pop(day.passages.first),
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

  // --- Length chooser ------------------------------------------------------

  Future<int?> _chooseLength(PlanInfo info) {
    var days = info.defaultDays;
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: kPaper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void setDays(int d) =>
              setSheet(() => days = d.clamp(7, info.maxDays).toInt());
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('HOW MANY DAYS?',
                      style: GoogleFonts.crimsonPro(
                          fontSize: 12,
                          letterSpacing: 3,
                          fontWeight: FontWeight.w600,
                          color: kMuted)),
                  const SizedBox(height: 4),
                  Text('${info.title} · about $days readings',
                      style:
                          GoogleFonts.crimsonPro(fontSize: 14, color: kMuted)),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final p in info.presets)
                        _presetChip('$p', selected: days == p,
                            onTap: () => setDays(p)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _stepButton(Icons.remove, () => setDays(days - 5)),
                      Expanded(
                        child: Center(
                          child: Text('$days days',
                              style: kTitleStyle(24, weight: FontWeight.w600)),
                        ),
                      ),
                      _stepButton(Icons.add, () => setDays(days + 5)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(days),
                      style: FilledButton.styleFrom(
                        backgroundColor: kInk,
                        foregroundColor: kPaper,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Start this plan'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _presetChip(String label,
          {required bool selected, required VoidCallback onTap}) =>
      InkWell(
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

  Widget _stepButton(IconData icon, VoidCallback onTap) => InkWell(
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
