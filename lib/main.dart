import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'package:path_provider/path_provider.dart';

import 'books.dart';
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
  await DrawingStore.init();
  runApp(const BooxBibleApp());
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
// Built once, not per build/paint. Pagination MUST measure with the same body
// style the verse renders, otherwise pages overflow or leave gaps.

final TextStyle kVerseStyle =
    GoogleFonts.crimsonPro(fontSize: 22, height: 1.55, color: kInk);
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

  Stroke({
    required this.points,
    this.width = 2.5,
    this.color = Colors.black,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => p.toJson()).toList(),
        'width': width,
        'color': color.toARGB32(),
      };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List;
    return Stroke(
      points: rawPoints
          .map((p) => StrokePoint.fromJson(p as Map<String, dynamic>))
          .toList(),
      width: (json['width'] as num?)?.toDouble() ?? 2.5,
      color: Color(json['color'] as int? ?? Colors.black.toARGB32()),
    );
  }

  /// True if any point on this stroke is within [radius] of [p]. Used by the
  /// stroke-level eraser so erasing removes the touched mark, not the verse.
  bool isNear(Offset p, double radius) {
    final r2 = radius * radius;
    for (final pt in points) {
      final dx = pt.x - p.dx;
      final dy = pt.y - p.dy;
      if (dx * dx + dy * dy <= r2) return true;
    }
    return false;
  }
}

// --- Persistence: handwritten notes ---------------------------------------

class DrawingStore {
  static final Map<String, List<Stroke>> _notes = {};
  static Timer? _saveDebouncer;
  static bool _loaded = false;

  static Future<void> init() async {
    if (_loaded) return;
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final Map<String, dynamic> data = json.decode(content);
          _notes
            ..clear()
            ..addAll(data.map((key, value) => MapEntry(
                key,
                (value as List)
                    .map((s) => Stroke.fromJson(s as Map<String, dynamic>))
                    .toList())));
        }
      }
    } catch (e) {
      debugPrint('Error loading notes: $e');
    }
    _loaded = true;
  }

  /// Returns the persisted strokes for a verse. Callers own a copy.
  static List<Stroke> strokesFor(String verseId) =>
      List<Stroke>.of(_notes[verseId] ?? const []);

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
    _saveDebouncer = Timer(const Duration(milliseconds: 800), () async {
      try {
        final file = await _getFile();
        final data = _notes.map(
            (key, value) => MapEntry(key, value.map((s) => s.toJson()).toList()));
        await file.writeAsString(json.encode(data));
      } catch (e) {
        debugPrint('Error saving notes: $e');
      }
    });
  }

  static Future<File> _getFile() async {
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
    final result = await Navigator.of(context).push<(String, int)>(
      MaterialPageRoute(
        builder: (_) =>
            BookPickerScreen(currentBook: _book, currentChapter: _chapter),
      ),
    );
    if (result != null) _goToChapter(result.$1, result.$2);
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

  List<List<Verse>> _paginate(
      List<Verse> verses, double textWidth, double availableHeight) {
    if (verses.isEmpty) return const [];

    final key = '${_source.translationId}_${_book}_${_chapter}_'
        '${textWidth.round()}x${availableHeight.round()}';
    final cached = PageCache.get(key);
    if (cached != null) return cached;

    final List<List<Verse>> result = [];
    List<Verse> current = [];
    double h = 0;

    final painter = TextPainter(textDirection: TextDirection.ltr);
    for (final v in verses) {
      painter.text = TextSpan(text: v.text, style: kVerseStyle);
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

        final pages = _paginate(_verses, textWidth, availableHeight);
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
  final double penWidth;
  final bool isEraser;

  const VerseBlock({
    super.key,
    required this.verse,
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

  static const double _eraseRadius = 16.0;

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

  bool _erasing(PointerEvent e) =>
      widget.isEraser || e.kind == PointerDeviceKind.invertedStylus;

  void _onDown(PointerDownEvent e) {
    if (!_isStylus(e)) return;
    if (_erasing(e)) {
      _eraseAt(e.localPosition);
      return;
    }
    _active = Stroke(
      points: [StrokePoint(e.localPosition.dx, e.localPosition.dy, e.pressure)],
      width: widget.penWidth,
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
    final removed = _strokes.where((s) => s.isNear(p, _eraseRadius)).toList();
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
                Expanded(child: Text(widget.verse.text, style: kVerseStyle)),
              ],
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: StrokePainter(
                    committed: _strokes,
                    active: () => _active,
                    repaint: _repaint,
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

  StrokePainter({
    required this.committed,
    required this.active,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in committed) {
      _drawStroke(canvas, s);
    }
    final a = active();
    if (a != null) _drawStroke(canvas, a);
  }

  void _drawStroke(Canvas canvas, Stroke stroke) {
    final pts = stroke.points;
    if (pts.isEmpty) return;

    final paint = Paint()
      ..color = stroke.color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    if (pts.length == 1) {
      paint.strokeWidth = stroke.width;
      canvas.drawPoints(PointMode.points, [pts.first.toOffset()], paint);
      return;
    }

    // Per-segment width modulation gives a light fountain-pen feel without the
    // per-point object churn of building many sub-paths.
    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i];
      final p1 = pts[i + 1];
      paint.strokeWidth = stroke.width * (0.5 + p0.pressure * 0.9);
      canvas.drawLine(p0.toOffset(), p1.toOffset(), paint);
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
          onTap: () => Navigator.of(context).pop((book.name, n)),
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
