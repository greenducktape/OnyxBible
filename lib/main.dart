import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'package:path_provider/path_provider.dart';

import 'books.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OnyxSdkPenArea.init();
  runApp(const BooxBibleApp());
}

// --- Shared typography ----------------------------------------------------
//
// These are built once instead of on every build/paint. Calling GoogleFonts in
// a hot path (paint, pagination, per-pointer rebuild) is expensive, so the
// styles are hoisted here and reused everywhere. Pagination MUST measure with
// the exact same spans the verse renders, so both go through [verseSpan].

final TextStyle kVerseStyle =
    GoogleFonts.crimsonPro(fontSize: 21, height: 1.5, color: Colors.black);
final TextStyle kVerseNumberStyle = GoogleFonts.crimsonPro(
  fontSize: 12,
  height: 1.5,
  color: Colors.black,
  fontWeight: FontWeight.w700,
);
const double kVerseSpacing = 10.0; // vertical gap between verses (top+bottom)
const EdgeInsets kPagePadding =
    EdgeInsets.symmetric(horizontal: 26, vertical: 12);

TextSpan verseSpan(Verse v) => TextSpan(children: [
      TextSpan(text: '${v.number} ', style: kVerseNumberStyle),
      TextSpan(text: v.text, style: kVerseStyle),
    ]);

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
        'color': color.value,
      };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'] as List;
    return Stroke(
      points: rawPoints
          .map((p) => StrokePoint.fromJson(p as Map<String, dynamic>))
          .toList(),
      width: (json['width'] as num?)?.toDouble() ?? 2.5,
      color: Color(json['color'] as int? ?? Colors.black.value),
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

class Verse {
  final String id;
  final int number;
  final String text;

  const Verse({required this.id, required this.number, required this.text});

  Map<String, dynamic> toJson() => {'id': id, 'number': number, 'text': text};

  factory Verse.fromJson(Map<String, dynamic> json) => Verse(
        id: json['id'] as String,
        number: (json['number'] as num).toInt(),
        text: json['text'] as String,
      );
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

// --- Persistence: scripture text (offline cache) --------------------------

class ChapterStore {
  // In-memory cache survives navigation; disk cache survives restarts/offline.
  static final Map<String, List<Verse>> _memory = {};
  static final Map<String, List<List<Verse>>> _pageCache = {};

  static String _key(String book, int chapter) => '${book}_$chapter';

  static List<Verse>? memory(String book, int chapter) =>
      _memory[_key(book, chapter)];

  static void putMemory(String book, int chapter, List<Verse> verses) =>
      _memory[_key(book, chapter)] = verses;

  static List<List<Verse>>? pages(String key) => _pageCache[key];
  static void putPages(String key, List<List<Verse>> pages) =>
      _pageCache[key] = pages;

  static Future<File> _file(String book, int chapter) async {
    final dir = await getApplicationDocumentsDirectory();
    final safe = book.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return File('${dir.path}/ch_${safe}_$chapter.json');
  }

  static Future<List<Verse>?> loadDisk(String book, int chapter) async {
    try {
      final f = await _file(book, chapter);
      if (!await f.exists()) return null;
      final List<dynamic> data = json.decode(await f.readAsString());
      return data
          .map((v) => Verse.fromJson(v as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveDisk(
      String book, int chapter, List<Verse> verses) async {
    try {
      final f = await _file(book, chapter);
      await f.writeAsString(
          json.encode(verses.map((v) => v.toJson()).toList()));
    } catch (_) {}
  }
}

// --- Main App -------------------------------------------------------------

class BooxBibleApp extends StatelessWidget {
  const BooxBibleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          primary: Colors.black,
          surface: Colors.white,
        ),
        textTheme: GoogleFonts.crimsonProTextTheme(),
      ),
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
  String _book = 'John';
  int _chapter = 1;

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await DrawingStore.init();
    await _loadChapter();
  }

  Future<void> _loadChapter() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    // 1) in-memory cache
    final cached = ChapterStore.memory(_book, _chapter);
    if (cached != null) {
      _applyVerses(cached);
      return;
    }

    // 2) on-disk cache (offline support)
    final disk = await ChapterStore.loadDisk(_book, _chapter);
    if (disk != null && disk.isNotEmpty) {
      ChapterStore.putMemory(_book, _chapter, disk);
      _applyVerses(disk);
      _prefetchNext();
      return;
    }

    // 3) network
    final fetched = await _fetch(_book, _chapter);
    if (fetched != null) {
      ChapterStore.putMemory(_book, _chapter, fetched);
      unawaited(ChapterStore.saveDisk(_book, _chapter, fetched));
      _applyVerses(fetched);
      _prefetchNext();
    } else {
      if (!mounted) return;
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
    _resetToFirstPage();
  }

  Future<List<Verse>?> _fetch(String book, int chapter) async {
    try {
      final uri = Uri.parse(
          'https://bible-api.com/${Uri.encodeComponent('$book $chapter')}');
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      final list = data['verses'] as List?;
      if (list == null) return null;
      return list
          .map((v) => Verse(
                id: '${v['book_name']}_${v['chapter']}_${v['verse']}',
                number: (v['verse'] as num).toInt(),
                text: v['text'].toString().trim(),
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _prefetchNext() async {
    final next = nextChapterOf(_book, _chapter);
    if (next == null) return;
    final (nb, nc) = next;
    if (ChapterStore.memory(nb, nc) != null) return;
    if (await ChapterStore.loadDisk(nb, nc) != null) return;
    final fetched = await _fetch(nb, nc);
    if (fetched != null) {
      ChapterStore.putMemory(nb, nc, fetched);
      unawaited(ChapterStore.saveDisk(nb, nc, fetched));
    }
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

  // --- Pagination ---------------------------------------------------------

  List<List<Verse>> _paginate(List<Verse> verses, Size size) {
    if (verses.isEmpty) return const [];

    final key = '${_book}_${_chapter}_${size.width.round()}x${size.height.round()}';
    final cached = ChapterStore.pages(key);
    if (cached != null) return cached;

    final List<List<Verse>> result = [];
    List<Verse> current = [];
    double h = 0;

    final painter = TextPainter(textDirection: TextDirection.ltr);
    for (final v in verses) {
      painter.text = verseSpan(v);
      painter.layout(maxWidth: size.width);
      final vh = painter.height + kVerseSpacing;

      if (h + vh > size.height && current.isNotEmpty) {
        result.add(current);
        current = [v];
        h = vh;
      } else {
        current.add(v);
        h += vh;
      }
    }
    if (current.isNotEmpty) result.add(current);

    ChapterStore.putPages(key, result);
    return result;
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: InkWell(
          onTap: _openPicker,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _book.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                      color: Colors.black54),
                ),
                Text(
                  'Chapter $_chapter',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.black),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Stroke width',
            icon: _WidthGlyph(width: _penWidth, active: !_isEraser),
            onPressed: () => setState(
                () => _widthIndex = (_widthIndex + 1) % _widths.length),
          ),
          IconButton(
            tooltip: _isEraser ? 'Eraser (tap to switch to pen)' : 'Pen (tap to switch to eraser)',
            icon: Icon(
              _isEraser ? Icons.cleaning_services : Icons.edit,
              color: Colors.black,
            ),
            isSelected: _isEraser,
            style: IconButton.styleFrom(
              backgroundColor: _isEraser ? Colors.black12 : null,
            ),
            onPressed: () => setState(
                () => _tool = _isEraser ? PenTool.pen : PenTool.eraser),
          ),
          IconButton(
            tooltip: 'Refresh screen',
            icon: const Icon(Icons.autorenew, color: Colors.black),
            onPressed: _forceRefresh,
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Colors.black12),
        ),
      ),
      body: OnyxSdkPenArea(
        // A 1ms flip of refreshDelay triggers a native full e-ink refresh that
        // clears pen ghosting after page/chapter changes.
        refreshDelay: Duration(milliseconds: 1200 + (_refreshTick % 2)),
        strokeStyle: OnyxStrokeStyle.fountainPen,
        // White "ink" while erasing keeps the native preview invisible.
        strokeColor: _isEraser ? Colors.white : Colors.black,
        strokeWidth: _penWidth,
        child: _buildBody(),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.black));
    }
    if (_hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.black38),
            const SizedBox(height: 12),
            const Text("Couldn't load this chapter.",
                style: TextStyle(fontSize: 16, color: Colors.black54)),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _loadChapter,
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.black,
                  side: const BorderSide(color: Colors.black26)),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth - kPagePadding.horizontal,
          constraints.maxHeight - kPagePadding.vertical,
        );
        final pages = _paginate(_verses, size);
        // Keep the cached page count in sync without rebuilding during layout.
        if (pages.length != _pageCount) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _pageCount = pages.length);
          });
        }
        return PageView.builder(
          controller: _pageController,
          // Disabled so a horizontal pen stroke never accidentally turns the
          // page; navigation is via the bottom bar buttons.
          physics: const NeverScrollableScrollPhysics(),
          itemCount: pages.length,
          onPageChanged: (i) {
            setState(() => _page = i);
            _forceRefresh();
          },
          itemBuilder: (context, i) {
            return Padding(
              padding: kPagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final v in pages[i])
                    VerseWidget(
                      key: ValueKey(v.id),
                      verse: v,
                      penWidth: _penWidth,
                      isEraser: _isEraser,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBottomBar() {
    final atStart = _page == 0 && prevChapterOf(_book, _chapter) == null;
    final atEnd =
        _page >= _pageCount - 1 && nextChapterOf(_book, _chapter) == null;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.black12)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: 'Previous chapter',
                icon: const Icon(Icons.first_page),
                color: Colors.black,
                onPressed:
                    prevChapterOf(_book, _chapter) == null ? null : _prevChapter,
              ),
              IconButton(
                tooltip: 'Previous page',
                icon: const Icon(Icons.chevron_left),
                color: Colors.black,
                onPressed: atStart ? null : _prevPage,
              ),
              Text(
                _pageCount > 0 ? '${_page + 1} / $_pageCount' : '–',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black54),
              ),
              IconButton(
                tooltip: 'Next page',
                icon: const Icon(Icons.chevron_right),
                color: Colors.black,
                onPressed: atEnd ? null : _nextPage,
              ),
              IconButton(
                tooltip: 'Next chapter',
                icon: const Icon(Icons.last_page),
                color: Colors.black,
                onPressed:
                    nextChapterOf(_book, _chapter) == null ? null : _nextChapter,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small visual indicator for the current stroke width in the app bar.
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
            color: active ? Colors.black : Colors.black38,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

// --- Verse + handwriting overlay -----------------------------------------

class VerseWidget extends StatefulWidget {
  final Verse verse;
  final double penWidth;
  final bool isEraser;

  const VerseWidget({
    super.key,
    required this.verse,
    required this.penWidth,
    required this.isEraser,
  });

  @override
  State<VerseWidget> createState() => _VerseWidgetState();
}

class _VerseWidgetState extends State<VerseWidget> {
  late List<Stroke> _strokes;
  Stroke? _active;

  // Drives the stroke CustomPaint directly. Mutating points + bumping this
  // repaints ONLY the canvas — no widget rebuild, no text relayout. This is
  // what keeps writing smooth on e-ink.
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  static const double _eraseRadius = 16.0;

  @override
  void initState() {
    super.initState();
    _strokes = DrawingStore.strokesFor(widget.verse.id);
  }

  @override
  void dispose() {
    _repaint.dispose();
    super.dispose();
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
      }
      _active = null;
      _repaint.value++;
    }
  }

  void _eraseAt(Offset p) {
    final before = _strokes.length;
    _strokes.removeWhere((s) => s.isNear(p, _eraseRadius));
    if (_strokes.length != before) {
      DrawingStore.setStrokes(widget.verse.id, _strokes);
      _repaint.value++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: kVerseSpacing / 2),
            child: Text.rich(verseSpan(widget.verse)),
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
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        foregroundColor: Colors.black,
        leading: book == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selected = null),
              ),
        title: Text(
          book == null ? 'Books' : book.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Colors.black12),
        ),
      ),
      body: book == null ? _buildBookList() : _buildChapterGrid(book),
    );
  }

  Widget _buildBookList() {
    final ot = kBibleBooks.where((b) => b.isOldTestament).toList();
    final nt = kBibleBooks.where((b) => !b.isOldTestament).toList();
    return ListView(
      children: [
        _sectionHeader('Old Testament'),
        ...ot.map(_bookTile),
        _sectionHeader('New Testament'),
        ...nt.map(_bookTile),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Text(
          label.toUpperCase(),
          style: const TextStyle(
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.bold,
              color: Colors.black45),
        ),
      );

  Widget _bookTile(BibleBook b) {
    final isCurrent = b.name == widget.currentBook;
    return ListTile(
      title: Text(
        b.name,
        style: TextStyle(
          fontSize: 17,
          fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w500,
          color: Colors.black,
        ),
      ),
      trailing: Text('${b.chapters}',
          style: const TextStyle(color: Colors.black38, fontSize: 13)),
      onTap: () => setState(() => _selected = b),
    );
  }

  Widget _buildChapterGrid(BibleBook book) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 72,
        childAspectRatio: 1,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
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
              border: Border.all(
                  color: isCurrent ? Colors.black : Colors.black26,
                  width: isCurrent ? 2 : 1),
              borderRadius: BorderRadius.circular(8),
              color: isCurrent ? Colors.black : Colors.white,
            ),
            alignment: Alignment.center,
            child: Text(
              '$n',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: isCurrent ? Colors.white : Colors.black,
              ),
            ),
          ),
        );
      },
    );
  }
}
