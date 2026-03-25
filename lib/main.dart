import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:onyxsdk_pen/onyxsdk_pen.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OnyxSdkPenArea.init();
  runApp(const BooxBibleApp());
}

// --- Data Models ---

class StrokePoint {
  final double x;
  final double y;
  final double pressure;

  StrokePoint(this.x, this.y, [this.pressure = 1.0]);

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'p': pressure};

  factory StrokePoint.fromJson(Map<String, dynamic> json) {
    return StrokePoint(
      (json['x'] as num).toDouble(),
      (json['y'] as num).toDouble(),
      (json['p'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Offset toOffset() => Offset(x, y);
}

class Stroke {
  final List<StrokePoint> points;
  final double width;
  final Color color;

  Stroke({
    required this.points,
    this.width = 2.0,
    this.color = Colors.black,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => p.toJson()).toList(),
        'width': width,
        'color': color.value,
      };

  factory Stroke.fromJson(Map<String, dynamic> json) {
    var rawPoints = json['points'] as List;
    return Stroke(
      points: rawPoints.map((p) => StrokePoint.fromJson(p)).toList(),
      width: (json['width'] as num?)?.toDouble() ?? 2.0,
      color: Color(json['color'] as int? ?? Colors.black.value),
    );
  }
}

class Verse {
  final String id;
  final int number;
  final String text;

  Verse({required this.id, required this.number, required this.text});
}

// --- Persistence ---

class DrawingStore {
  static final ValueNotifier<Map<String, List<Stroke>>> notesNotifier = ValueNotifier({});
  static Timer? _saveDebouncer;

  static Future<void> init() async {
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isEmpty) return;
        final Map<String, dynamic> data = json.decode(content);
        notesNotifier.value = data.map((key, value) => MapEntry(
            key, (value as List).map((s) => Stroke.fromJson(s)).toList()));
      }
    } catch (e) {
      debugPrint("Error loading notes: $e");
    }
  }

  static void _triggerSave() {
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(seconds: 1), () async {
      try {
        final file = await _getFile();
        final data = notesNotifier.value.map(
            (key, value) => MapEntry(key, value.map((s) => s.toJson()).toList()));
        await file.writeAsString(json.encode(data));
      } catch (e) {
        debugPrint("Error saving notes: $e");
      }
    });
  }

  static void addStroke(String verseId, Stroke stroke) {
    final current = Map<String, List<Stroke>>.from(notesNotifier.value);
    current.putIfAbsent(verseId, () => []).add(stroke);
    notesNotifier.value = current;
    _triggerSave();
  }

  static void clearNotes(String verseId) {
    final current = Map<String, List<Stroke>>.from(notesNotifier.value);
    current.remove(verseId);
    notesNotifier.value = current;
    _triggerSave();
  }

  static Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/bible_notes_v4.json');
  }
}

// --- Caching ---

class BibleCache {
  static final Map<String, List<Verse>> _chapters = {};
  static final Map<String, List<List<Verse>>> _pages = {};

  static List<Verse>? getChapter(String book, int chapter) => _chapters['${book}_$chapter'];
  static void setChapter(String book, int chapter, List<Verse> verses) => _chapters['${book}_$chapter'] = verses;

  static List<List<Verse>>? getPages(String key) => _pages[key];
  static void setPages(String key, List<List<Verse>> pages) => _pages[key] = pages;
}

// --- Main App ---

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
        textTheme: GoogleFonts.crimsonProTextTheme(),
      ),
      home: const BibleReaderScreen(),
    );
  }
}

class BibleReaderScreen extends StatefulWidget {
  const BibleReaderScreen({super.key});

  @override
  State<BibleReaderScreen> createState() => _BibleReaderScreenState();
}

class _BibleReaderScreenState extends State<BibleReaderScreen> {
  String _currentBook = "John";
  int _currentChapter = 1;
  List<Verse> _verses = [];
  List<List<Verse>> _pages = [];
  bool _isLoading = true;
  
  double _penWidth = 2.0;
  bool _isEraser = false;
  
  // To trigger refresh, we can "poke" the OnyxSdkPenArea by changing a dummy parameter
  int _refreshCounter = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await DrawingStore.init();
    await _loadChapter();
  }

  Future<void> _loadChapter() async {
    final cached = BibleCache.getChapter(_currentBook, _currentChapter);
    if (cached != null) {
      setState(() {
        _verses = cached;
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('https://bible-api.com/$_currentBook+$_currentChapter'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final newVerses = (data['verses'] as List).map((v) => Verse(
          id: '${v['book_name']}_${v['chapter']}_${v['verse']}',
          number: v['verse'],
          text: v['text'].toString().trim(),
        )).toList();
        
        BibleCache.setChapter(_currentBook, _currentChapter, newVerses);
        setState(() {
          _verses = newVerses;
          _isLoading = false;
        });
        _prefetchNext();
      }
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _prefetchNext() async {
    int next = _currentChapter + 1;
    if (BibleCache.getChapter(_currentBook, next) == null) {
      try {
        final response = await http.get(Uri.parse('https://bible-api.com/$_currentBook+$next'));
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final verses = (data['verses'] as List).map((v) => Verse(
            id: '${v['book_name']}_${v['chapter']}_${v['verse']}',
            number: v['verse'],
            text: v['text'].toString().trim(),
          )).toList();
          BibleCache.setChapter(_currentBook, next, verses);
        }
      } catch (_) {}
    }
  }

  void _triggerFullRefresh() {
    setState(() {
      _refreshCounter++;
    });
  }

  List<List<Verse>> _paginate(List<Verse> verses, Size size) {
    if (verses.isEmpty) return [];
    
    // Check cache
    final key = '${_currentBook}_${_currentChapter}_${size.width}_${size.height}';
    final cached = BibleCache.getPages(key);
    if (cached != null) return cached;

    final List<List<Verse>> result = [];
    List<Verse> current = [];
    double h = 0;
    
    final painter = TextPainter(textDirection: TextDirection.ltr);
    final textStyle = GoogleFonts.crimsonPro(fontSize: 22, height: 1.3, color: Colors.black);
    final numStyle = GoogleFonts.lato(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black45);

    for (var v in verses) {
      painter.text = TextSpan(children: [
        TextSpan(text: '${v.number} ', style: numStyle),
        TextSpan(text: v.text, style: textStyle),
      ]);
      painter.layout(maxWidth: size.width);
      final vh = painter.height + 8; // verse spacing

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
    
    BibleCache.setPages(key, result);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        title: GestureDetector(
          onTap: () {}, // TODO: Book Picker
          child: Column(
            children: [
              Text(_currentBook.toUpperCase(), style: const TextStyle(fontSize: 12, letterSpacing: 2, fontWeight: FontWeight.bold)),
              Text("CHAPTER $_currentChapter", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(_isEraser ? Icons.cleaning_services : Icons.edit, color: _isEraser ? Colors.red : Colors.black),
            onPressed: () => setState(() => _isEraser = !_isEraser),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _triggerFullRefresh,
          ),
        ],
      ),
      body: OnyxSdkPenArea(
        // The dummy refreshCounter triggers didUpdateWidget in native, which calls EpdController.invalidate(GC)
        refreshDelay: Duration(milliseconds: 2000 + (_refreshCounter % 2)), 
        strokeColor: _isEraser ? Colors.white : Colors.black,
        strokeWidth: _penWidth,
        child: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : LayoutBuilder(
              builder: (context, constraints) {
                final pages = _paginate(_verses, Size(constraints.maxWidth - 40, constraints.maxHeight - 40));
                return PageView.builder(
                  itemCount: pages.length,
                  onPageChanged: (_) => _triggerFullRefresh(), // Clean ghosting on page turn
                  itemBuilder: (context, i) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: pages[i].map((v) => VerseWidget(
                          key: ValueKey(v.id),
                          verse: v,
                          penWidth: _penWidth,
                          isEraser: _isEraser,
                        )).toList(),
                      ),
                    );
                  },
                );
              },
            ),
      ),
      bottomNavigationBar: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(icon: const Icon(Icons.arrow_back_ios), onPressed: _currentChapter > 1 ? () {
              setState(() => _currentChapter--);
              _loadChapter();
            } : null),
            IconButton(icon: const Icon(Icons.arrow_forward_ios), onPressed: () {
              setState(() => _currentChapter++);
              _loadChapter();
            }),
          ],
        ),
      ),
    );
  }
}

class VerseWidget extends StatefulWidget {
  final Verse verse;
  final double penWidth;
  final bool isEraser;
  const VerseWidget({super.key, required this.verse, required this.penWidth, required this.isEraser});

  @override
  State<VerseWidget> createState() => _VerseWidgetState();
}

class _VerseWidgetState extends State<VerseWidget> with AutomaticKeepAliveClientMixin {
  Stroke? _current;
  
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ValueListenableBuilder<Map<String, List<Stroke>>>(
      valueListenable: DrawingStore.notesNotifier,
      builder: (context, all, _) {
        final strokes = all[widget.verse.id] ?? [];
        return Listener(
          onPointerDown: (e) {
            if (e.kind != PointerDeviceKind.stylus && e.kind != PointerDeviceKind.invertedStylus) return;
            if (widget.isEraser || e.kind == PointerDeviceKind.invertedStylus) {
              DrawingStore.clearNotes(widget.verse.id);
              return;
            }
            setState(() => _current = Stroke(points: [StrokePoint(e.localPosition.dx, e.localPosition.dy, e.pressure)], width: widget.penWidth));
          },
          onPointerMove: (e) {
            if (_current == null) return;
            setState(() => _current!.points.add(StrokePoint(e.localPosition.dx, e.localPosition.dy, e.pressure)));
          },
          onPointerUp: (e) {
            if (_current != null) {
              DrawingStore.addStroke(widget.verse.id, _current!);
              setState(() => _current = null);
            }
          },
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text.rich(TextSpan(
                  children: [
                    WidgetSpan(child: Transform.translate(offset: const Offset(0, -8), child: Text('${widget.verse.number} ', style: GoogleFonts.lato(fontSize: 10, color: Colors.black45)))),
                    TextSpan(text: widget.verse.text, style: GoogleFonts.crimsonPro(fontSize: 22, height: 1.3)),
                  ],
                )),
              ),
              Positioned.fill(child: CustomPaint(painter: BetterStrokePainter(strokes: strokes))),
              if (_current != null) Positioned.fill(child: CustomPaint(painter: BetterStrokePainter(strokes: [_current!]))),
            ],
          ),
        );
      },
    );
  }
}

class BetterStrokePainter extends CustomPainter {
  final List<Stroke> strokes;
  BetterStrokePainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    for (var stroke in strokes) {
      if (stroke.points.length < 2) continue;
      for (int i = 0; i < stroke.points.length - 1; i++) {
        final p0 = stroke.points[i];
        final p1 = stroke.points[i + 1];
        // Fountain pen effect: use pressure to modulate width
        paint.strokeWidth = stroke.width * (0.4 + p0.pressure * 1.2);
        canvas.drawLine(p0.toOffset(), p1.toOffset(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BetterStrokePainter old) => true;
}
