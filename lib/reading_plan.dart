// Reading-plan models and a cross-reference-driven generator.
//
// Kept free of Flutter imports (like books.dart) so the plan-building logic can
// be unit-tested cheaply. The chapter cross-reference graph is supplied as an
// already-decoded map; loading the bundled asset lives in the data layer.

import 'dart:math' as math;

import 'books.dart';
import 'reference.dart';

/// Chapter-level cross-reference affinity graph, built at load time from
/// assets/data/xref_chapters.json (see tool/build_xref.py). Keys are
/// "Book Chapter" (e.g. "Isaiah 53"); values are the strongest neighbours,
/// each with a summed-vote weight, already sorted strongest-first.
class XrefGraph {
  final Map<String, List<(String, int)>> _adj;

  const XrefGraph(this._adj);

  factory XrefGraph.fromJson(Map<String, dynamic> json) {
    final adj = <String, List<(String, int)>>{};
    json.forEach((key, value) {
      adj[key] = [
        for (final e in value as List)
          ((e as List)[0] as String, (e[1] as num).toInt()),
      ];
    });
    return XrefGraph(adj);
  }

  static String keyOf(BibleRef r) => '${r.book} ${r.chapter}';

  static BibleRef refOf(String key) {
    final i = key.lastIndexOf(' ');
    return BibleRef(key.substring(0, i), int.parse(key.substring(i + 1)));
  }

  /// Summed cross-reference weight between two chapters (0 if none).
  int affinity(BibleRef a, BibleRef b) {
    final list = _adj[keyOf(a)];
    if (list == null) return 0;
    final target = keyOf(b);
    for (final (name, w) in list) {
      if (name == target) return w;
    }
    return 0;
  }

  /// Neighbours of [r], strongest first, as (chapter, weight) pairs.
  List<(BibleRef, int)> neighbors(BibleRef r) {
    final list = _adj[keyOf(r)];
    if (list == null) return const [];
    return [for (final (name, w) in list) (refOf(name), w)];
  }
}

/// Verse-range New Testament "echoes" of each Old Testament chapter, built at
/// load time from assets/data/ot_nt_echoes.json (see tool/build_xref.py).
/// Each OT chapter maps to a list of candidate NT passages, strongest-first,
/// each carrying a contiguous verse range (a snippet, not the whole chapter)
/// and the summed cross-reference vote weight that linked it.
class OtNtEchoes {
  final Map<String, List<BibleRef>> _byOtChapter;
  final Map<String, List<int>> _votes;

  const OtNtEchoes(this._byOtChapter, this._votes);

  factory OtNtEchoes.fromJson(Map<String, dynamic> json) {
    final refs = <String, List<BibleRef>>{};
    final votes = <String, List<int>>{};
    json.forEach((key, value) {
      final list = (value as List).cast<Map>();
      refs[key] = [
        for (final e in list)
          BibleRef(
              e['book'] as String,
              (e['chapter'] as num).toInt(),
              (e['from'] as num).toInt(),
              (e['to'] as num).toInt()),
      ];
      votes[key] = [for (final e in list) (e['votes'] as num).toInt()];
    });
    return OtNtEchoes(refs, votes);
  }

  /// NT echo candidates for an OT chapter, strongest-first. Empty if unknown.
  List<BibleRef> candidatesFor(BibleRef otChapter) =>
      _byOtChapter[XrefGraph.keyOf(otChapter)] ?? const [];

  /// Vote weight of [candidate] when it appears as an echo of [otChapter], or 0.
  int votesFor(BibleRef otChapter, BibleRef candidate) {
    final key = XrefGraph.keyOf(otChapter);
    final cands = _byOtChapter[key];
    if (cands == null) return 0;
    for (var i = 0; i < cands.length; i++) {
      if (cands[i] == candidate) return _votes[key]![i];
    }
    return 0;
  }
}

/// One day of reading: a few chapters, plus the strength of the OT<->NT
/// cross-reference pairing chosen for the day (0 when no strong link existed).
class PlanDay {
  final List<BibleRef> passages;
  final int pairingVotes;

  const PlanDay(this.passages, {this.pairingVotes = 0});

  bool get isCrossReferenced => pairingVotes > 0;
}

class ReadingPlan {
  final String id;
  final String title;
  final String subtitle;
  final List<PlanDay> days;

  const ReadingPlan({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.days,
  });

  int get length => days.length;
}

/// A live "reading the plan" session held by the reader: which day, and how far
/// through that day's passages. Lets the reader follow the plan's order
/// (Genesis 1 → Matthew 1 → next day) instead of the next Bible chapter, and
/// auto-complete a day when its last passage is finished.
class PlanSession {
  final ReadingPlan plan;
  final int dayIndex;
  final int cursor; // index into the day's passages

  const PlanSession(this.plan, this.dayIndex, [this.cursor = 0]);

  List<BibleRef> get dayPassages => plan.days[dayIndex].passages;
  BibleRef get current => dayPassages[cursor];
  bool get atDayEnd => cursor >= dayPassages.length - 1;
  bool get atDayStart => cursor <= 0;
  bool get isLastDay => dayIndex >= plan.length - 1;
  int get passageCount => dayPassages.length;

  PlanSession withCursor(int c) => PlanSession(plan, dayIndex, c);
  PlanSession nextDay() => PlanSession(plan, dayIndex + 1, 0);
  PlanSession prevDay() =>
      PlanSession(plan, dayIndex - 1, plan.days[dayIndex - 1].passages.length - 1);
}

/// Every chapter of one testament, in canonical order.
List<BibleRef> chaptersOfTestament({required bool oldTestament}) {
  final out = <BibleRef>[];
  for (final b in kBibleBooks) {
    if (b.isOldTestament != oldTestament) continue;
    for (var c = 1; c <= b.chapters; c++) {
      out.add(BibleRef(b.name, c));
    }
  }
  return out;
}

bool _isOldTestament(BibleRef r) => bookByName(r.book).isOldTestament;

/// The natural length of the companion plan: one entry per New Testament
/// chapter (260). Shorter plans group several pairs per reading-day.
const int companionMaxDays = 260;

/// Evenly regroup a base sequence of single entries into [n] entries, merging
/// their passages. Used to stretch/compress a plan to a requested length.
List<PlanDay> _regroup(List<PlanDay> base, int n) {
  if (n >= base.length) return base;
  final out = <PlanDay>[];
  for (var i = 0; i < n; i++) {
    final start = (i * base.length) ~/ n;
    final end = ((i + 1) * base.length) ~/ n;
    final passages = <BibleRef>[];
    var votes = 0;
    for (var k = start; k < end; k++) {
      passages.addAll(base[k].passages);
      votes += base[k].pairingVotes;
    }
    out.add(PlanDay(passages, pairingVotes: votes));
  }
  return out;
}

/// "Cross-Reference Companion": walks the New Testament and pairs each chapter
/// with the Old Testament chapter it is most strongly cross-linked to — Isaiah
/// 53 beside 1 Peter 2, Psalm 22 beside the crucifixion, and so on. Prefers an
/// OT chapter not yet used so pairings stay varied; falls back to the strongest
/// link, then to canonical order when the graph is silent. The 260 natural
/// pairs are then regrouped into [days] reading-days (clamped to 1..260).
ReadingPlan companionPlan(XrefGraph graph, {int days = companionMaxDays}) {
  final nt = chaptersOfTestament(oldTestament: false);
  final usedOt = <BibleRef>{};
  final otFallback = chaptersOfTestament(oldTestament: true);
  var fallbackIdx = 0;
  final pairs = <PlanDay>[];

  for (final ntCh in nt) {
    BibleRef? pick;
    var votes = 0;
    for (final (ref, w) in graph.neighbors(ntCh)) {
      if (!_isOldTestament(ref)) continue;
      if (usedOt.contains(ref)) {
        pick ??= ref; // remember a strong-but-used link as a backup
        votes = votes == 0 ? w : votes;
        continue;
      }
      pick = ref;
      votes = w;
      break;
    }
    // Nothing in the graph: advance through the OT in canonical order.
    while (pick == null && fallbackIdx < otFallback.length) {
      final cand = otFallback[fallbackIdx++];
      if (!usedOt.contains(cand)) pick = cand;
    }
    if (pick != null) usedOt.add(pick);
    pairs.add(PlanDay([ntCh, if (pick != null) pick], pairingVotes: votes));
  }

  return ReadingPlan(
    id: 'companion',
    title: 'Cross-Reference Companion',
    subtitle: 'New Testament paired with its Old Testament roots',
    days: _regroup(pairs, days.clamp(1, pairs.length).toInt()),
  );
}

/// Whole-Bible plan that finishes in [totalDays]. The Old Testament is read in
/// canonical order, evenly spread; each day's New Testament chapter is chosen
/// from a near-canonical window to maximise cross-reference affinity with that
/// day's OT reading, so OT and NT stay genuinely interleaved by meaning rather
/// than by coincidence. Falls back to canonical NT order when no link is strong.
ReadingPlan wholeBiblePlan(
  XrefGraph graph, {
  required String id,
  required String title,
  required String subtitle,
  required int totalDays,
}) {
  final ot = chaptersOfTestament(oldTestament: true);
  final nt = chaptersOfTestament(oldTestament: false);
  final ntPool = List<BibleRef>.of(nt);
  const window = 24;
  final days = <PlanDay>[];

  for (var d = 0; d < totalDays; d++) {
    final otStart = (d * ot.length) ~/ totalDays;
    final otEnd = ((d + 1) * ot.length) ~/ totalDays;
    final dayOt = ot.sublist(otStart, otEnd);

    final ntCount =
        ((d + 1) * nt.length) ~/ totalDays - (d * nt.length) ~/ totalDays;
    final dayNt = <BibleRef>[];
    var votes = 0;
    for (var k = 0; k < ntCount && ntPool.isNotEmpty; k++) {
      final lim = math.min(window, ntPool.length);
      var best = 0;
      var bestW = -1;
      for (var j = 0; j < lim; j++) {
        var w = 0;
        for (final o in dayOt) {
          w += graph.affinity(o, ntPool[j]);
        }
        if (w > bestW) {
          bestW = w;
          best = j;
        }
      }
      if (bestW > 0) votes += bestW;
      dayNt.add(ntPool.removeAt(best));
    }
    days.add(PlanDay([...dayOt, ...dayNt], pairingVotes: votes));
  }
  return ReadingPlan(
      id: id, title: title, subtitle: subtitle, days: days);
}

/// Total chapters in the canon — the longest a whole-Bible plan can run.
const int wholeBibleChapters = 1189;

// --- Configurable plan generator ------------------------------------------
//
// Instead of a fixed catalogue of plan "kinds", the reader composes a plan from
// a handful of choices. The generator turns those choices into a concrete list
// of reading-days, deterministically, so a plan can be re-derived from its
// config alone (the store persists the config, not the day list).

/// How the Old Testament main track is ordered.
enum PlanOrdering {
  /// Printed order: Genesis → Malachi.
  canonical,

  /// A best-effort historical order (whole books reordered; e.g. Job after
  /// Genesis, the prophets among Kings/Chronicles).
  chronological,
}

/// The choices that define a reading plan.
class PlanConfig {
  /// Chapters of the main track read each day (1..20).
  final int chaptersPerDay;

  /// Pair each day's reading with a cross-referenced New Testament passage
  /// (Old + New every day). When false, the whole Bible is read straight
  /// through, back to back.
  final bool crossReferenced;

  /// Add one Psalm to every day (cycling Psalms 1..150). When on, Psalms are
  /// pulled out of the main track so they aren't read twice.
  final bool dailyPsalm;

  /// Read only the New Testament.
  final bool newTestamentOnly;

  /// Old Testament ordering (ignored when [newTestamentOnly]).
  final PlanOrdering ordering;

  /// Optional starting point in the reading track. Empty [startBook] = begin at
  /// the natural start (Genesis / Matthew). When set, the track is offset to
  /// begin at this book/chapter.
  final String startBook;
  final int startChapter;

  /// How a partway start covers the rest: when true, read to the end then wrap
  /// back to the beginning so the whole track is still covered; when false, stop
  /// at the end of the track (a shorter plan that skips what came before).
  final bool wrapAround;

  const PlanConfig({
    this.chaptersPerDay = 3,
    this.crossReferenced = true,
    this.dailyPsalm = false,
    this.newTestamentOnly = false,
    this.ordering = PlanOrdering.canonical,
    this.startBook = '',
    this.startChapter = 1,
    this.wrapAround = true,
  });

  PlanConfig copyWith({
    int? chaptersPerDay,
    bool? crossReferenced,
    bool? dailyPsalm,
    bool? newTestamentOnly,
    PlanOrdering? ordering,
    String? startBook,
    int? startChapter,
    bool? wrapAround,
  }) =>
      PlanConfig(
        chaptersPerDay: chaptersPerDay ?? this.chaptersPerDay,
        crossReferenced: crossReferenced ?? this.crossReferenced,
        dailyPsalm: dailyPsalm ?? this.dailyPsalm,
        newTestamentOnly: newTestamentOnly ?? this.newTestamentOnly,
        ordering: ordering ?? this.ordering,
        startBook: startBook ?? this.startBook,
        startChapter: startChapter ?? this.startChapter,
        wrapAround: wrapAround ?? this.wrapAround,
      );

  Map<String, dynamic> toJson() => {
        'chaptersPerDay': chaptersPerDay,
        'crossReferenced': crossReferenced,
        'dailyPsalm': dailyPsalm,
        'newTestamentOnly': newTestamentOnly,
        'ordering': ordering.name,
        'startBook': startBook,
        'startChapter': startChapter,
        'wrapAround': wrapAround,
      };

  factory PlanConfig.fromJson(Map<String, dynamic> j) => PlanConfig(
        chaptersPerDay: (j['chaptersPerDay'] as num?)?.toInt() ?? 3,
        crossReferenced: j['crossReferenced'] as bool? ?? true,
        dailyPsalm: j['dailyPsalm'] as bool? ?? false,
        newTestamentOnly: j['newTestamentOnly'] as bool? ?? false,
        ordering: PlanOrdering.values.firstWhere(
          (o) => o.name == j['ordering'],
          orElse: () => PlanOrdering.canonical,
        ),
        startBook: j['startBook'] as String? ?? '',
        startChapter: (j['startChapter'] as num?)?.toInt() ?? 1,
        wrapAround: j['wrapAround'] as bool? ?? true,
      );

  /// True when the plan begins somewhere other than the natural start.
  bool get hasCustomStart => startBook.isNotEmpty;

  /// A short, human title summarising the choices.
  String get title {
    if (newTestamentOnly) {
      return dailyPsalm ? 'New Testament + a daily Psalm' : 'New Testament';
    }
    if (crossReferenced) return 'Whole Bible · cross-referenced';
    return 'Whole Bible · straight through';
  }
}

/// A reasonable chronological order of the Old Testament, book by book. Not a
/// scholarly reconstruction — a familiar reading order (Job amid the patriarchs,
/// the writing prophets among the kings). Any OT book missing here is appended
/// in canonical order so every chapter is always covered exactly once.
const List<String> _kChronologicalOtBooks = [
  'Genesis', 'Job', 'Exodus', 'Leviticus', 'Numbers', 'Deuteronomy',
  'Joshua', 'Judges', 'Ruth', '1 Samuel', '2 Samuel', '1 Chronicles',
  'Psalms', 'Song of Solomon', 'Proverbs', 'Ecclesiastes', '1 Kings',
  '2 Chronicles', 'Obadiah', 'Joel', 'Jonah', 'Amos', 'Hosea', 'Isaiah',
  'Micah', 'Nahum', 'Zephaniah', 'Habakkuk', 'Jeremiah', 'Lamentations',
  '2 Kings', 'Ezekiel', 'Daniel', 'Haggai', 'Zechariah', 'Ezra',
  'Nehemiah', 'Esther', 'Malachi',
];

List<BibleRef> _otChaptersChronological() {
  final byName = <String, BibleBook>{
    for (final b in kBibleBooks)
      if (b.isOldTestament) b.name: b,
  };
  final out = <BibleRef>[];
  final used = <String>{};
  void emit(BibleBook b) {
    used.add(b.name);
    for (var c = 1; c <= b.chapters; c++) {
      out.add(BibleRef(b.name, c));
    }
  }

  for (final name in _kChronologicalOtBooks) {
    final b = byName[name];
    if (b != null && !used.contains(name)) emit(b);
  }
  // Defensive: anything not in the curated list, in canonical order.
  for (final b in kBibleBooks) {
    if (b.isOldTestament && !used.contains(b.name)) emit(b);
  }
  return out;
}

List<BibleRef> _otChapters(PlanOrdering o) => o == PlanOrdering.chronological
    ? _otChaptersChronological()
    : chaptersOfTestament(oldTestament: true);

List<BibleRef> _withoutPsalms(List<BibleRef> xs) =>
    [for (final r in xs) if (r.book != 'Psalms') r];

/// The main reading track (before the daily Psalm / cross-ref NT are added).
List<BibleRef> _mainTrack(PlanConfig c) {
  List<BibleRef> main;
  if (c.newTestamentOnly) {
    main = chaptersOfTestament(oldTestament: false);
  } else if (c.crossReferenced) {
    main = _otChapters(c.ordering); // NT is added per-day by cross-reference
  } else {
    main = [..._otChapters(c.ordering), ...chaptersOfTestament(oldTestament: false)];
  }
  if (c.dailyPsalm) main = _withoutPsalms(main);
  return _applyStart(main, c);
}

/// Offsets [track] to begin at the config's chosen start. Finds the first
/// chapter at-or-after (startBook, startChapter); when wrapAround the tail is
/// moved to the front (whole track still covered), otherwise the earlier part
/// is dropped (a shorter plan). Unknown/absent start = unchanged.
List<BibleRef> _applyStart(List<BibleRef> track, PlanConfig c) {
  if (!c.hasCustomStart || track.isEmpty) return track;
  var i = track.indexWhere(
      (r) => r.book == c.startBook && r.chapter >= c.startChapter);
  if (i < 0) i = track.indexWhere((r) => r.book == c.startBook);
  if (i <= 0) return track; // not found, or already at the front
  return c.wrapAround
      ? [...track.sublist(i), ...track.sublist(0, i)]
      : track.sublist(i);
}

/// How many reading-days [config] produces — computable without the graph, so
/// the builder UI can show a duration before the plan is generated.
int planLength(PlanConfig config) {
  final cpd = config.chaptersPerDay.clamp(1, 20).toInt();
  final main = _mainTrack(config);
  return (main.length / cpd).ceil();
}

/// Build the concrete plan for [config]. [id] becomes the plan's id (so a live
/// session can be matched back to its saved-plan progress). Deterministic.
///
/// For cross-referenced plans the day's OT chapter(s) come from the main track
/// in order; the NT pairing is the passage whose cross-references most strongly
/// echo that day's OT.
///
/// When [echoes] is provided (the bundled ot_nt_echoes.json), each NT pairing is
/// a short verse range — a snippet like "Hebrews 11:1-3" — chosen because
/// scripture itself most densely links that range to the day's OT. NT passages
/// may repeat across the plan: the NT is the lens on the OT, not a parallel
/// track to cover. A recent-use penalty stops any one snippet from running
/// many days in a row when a runner-up is close.
///
/// Without [echoes] the picker falls back to whole-NT-chapter affinity from
/// [graph] (same recent-use diversification) — still better than the old
/// front-window pool, but at chapter granularity.
ReadingPlan generatePlan(XrefGraph graph, PlanConfig config,
    {String id = 'custom', OtNtEchoes? echoes}) {
  final cpd = config.chaptersPerDay.clamp(1, 20).toInt();
  final main = _mainTrack(config);
  final totalDays = main.isEmpty ? 0 : (main.length / cpd).ceil();

  final pairing = config.crossReferenced && !config.newTestamentOnly;
  final ntAll = chaptersOfTestament(oldTestament: false);
  // Days back at which a recent NT echo's score is halved (then quartered, etc.).
  // 14 felt long; 8 is enough to break a streak yet still let a strong link win.
  const recentPenaltyWindow = 8;
  final lastUsedDay = <BibleRef, int>{};

  final days = <PlanDay>[];
  for (var d = 0; d < totalDays; d++) {
    final start = d * cpd;
    final end = math.min(start + cpd, main.length);
    final dayMain = main.sublist(start, end);
    final passages = <BibleRef>[...dayMain];
    var votes = 0;

    if (pairing) {
      // Build a candidate set: when verse-range echoes are available, use them
      // (snippet feel); otherwise fall back to whole-NT-chapter affinity.
      // In both cases a recent-use penalty halves the score the closer it was
      // used, so the same favourite can't dominate the first week.
      final candidates = <BibleRef>[];
      final rawVotes = <int>[];
      if (echoes != null) {
        for (final o in dayMain) {
          for (final c in echoes.candidatesFor(o)) {
            candidates.add(c);
            rawVotes.add(echoes.votesFor(o, c));
          }
        }
      }
      if (candidates.isEmpty) {
        for (final n in ntAll) {
          var w = 0;
          for (final o in dayMain) {
            w += graph.affinity(o, n);
          }
          if (w > 0) {
            candidates.add(n);
            rawVotes.add(w);
          }
        }
      }

      BibleRef? bestRef;
      double bestScore = -1;
      var bestRawVotes = 0;
      for (var i = 0; i < candidates.length; i++) {
        final ref = candidates[i];
        var score = rawVotes[i].toDouble();
        // Diversification: key the recent-use map by chapter so two ranges in
        // the same chapter still count as one repeat (avoids Hebrews 11:1-3
        // immediately followed by Hebrews 11:4-9).
        final chapterKey = BibleRef(ref.book, ref.chapter);
        final last = lastUsedDay[chapterKey];
        if (last != null) {
          final gap = d - last;
          if (gap < recentPenaltyWindow) {
            score *= math.pow(0.5, recentPenaltyWindow - gap).toDouble();
          }
        }
        if (score > bestScore) {
          bestScore = score;
          bestRef = ref;
          bestRawVotes = rawVotes[i];
        }
      }
      if (bestRef == null) {
        // No links at all anywhere — fall back to canonical NT (cycles).
        bestRef = ntAll[d % ntAll.length];
        bestRawVotes = 0;
      }
      lastUsedDay[BibleRef(bestRef.book, bestRef.chapter)] = d;
      votes = bestRawVotes;
      passages.add(bestRef);
    }

    if (config.dailyPsalm) {
      passages.add(BibleRef('Psalms', (d % 150) + 1));
    }

    days.add(PlanDay(passages, pairingVotes: votes));
  }

  return ReadingPlan(
    id: id,
    title: config.title,
    subtitle: _subtitleFor(config),
    days: days,
  );
}

String _subtitleFor(PlanConfig c) {
  if (c.newTestamentOnly) {
    return c.dailyPsalm
        ? 'The New Testament with a Psalm each day'
        : 'Straight through the New Testament';
  }
  if (c.crossReferenced) {
    return 'Old & New Testament linked by cross-reference each day';
  }
  return 'Genesis to Revelation, in order';
}

/// A friendly duration like "12 days", "about 7 months", "about 1 year 8 months".
String durationLabel(int days) {
  if (days <= 0) return '—';
  if (days < 45) return '$days days';
  final months = (days / 30.4).round();
  if (months < 12) return 'about $months months';
  final years = days ~/ 365;
  final remMonths = ((days - years * 365) / 30.4).round();
  final y = '$years year${years == 1 ? '' : 's'}';
  if (remMonths <= 0) return 'about $y';
  return 'about $y $remMonths month${remMonths == 1 ? '' : 's'}';
}

/// A rich, narrative description of what [config] will feel like to read,
/// mirroring the way printed reading plans introduce themselves.
String narrativeFor(PlanConfig config) {
  final days = planLength(config);
  final dur = durationLabel(days);
  final cpd = config.chaptersPerDay;
  final psalm = config.dailyPsalm;

  if (config.newTestamentOnly) {
    final b = StringBuffer(
        'This plan reads straight through the New Testament in $dur, '
        '$cpd chapter${cpd == 1 ? '' : 's'} a day');
    b.write(psalm
        ? ', with a Psalm every day to carry the prayers of Israel alongside '
            'the life of the church.'
        : '.');
    return b.toString() + _startSuffix(config);
  }

  if (!config.crossReferenced) {
    final b = StringBuffer(
        'This plan reads the whole Bible from Genesis to Revelation in $dur, '
        '$cpd chapter${cpd == 1 ? '' : 's'} a day, in order');
    b.write(psalm ? ', with a Psalm every day.' : '.');
    return b.toString() + _startSuffix(config);
  }

  // The flagship: cross-referenced whole-Bible plan.
  final orderWord = config.ordering == PlanOrdering.chronological
      ? 'in roughly chronological order'
      : 'in order';
  final b = StringBuffer(
      'This plan journeys through the entire Bible in $dur, with both an Old '
      'and a New Testament reading every day. You follow the Old Testament '
      '$orderWord');
  if (psalm) {
    b.write(', with the Psalms and prophets intermingled as a Psalm joins '
        'each day');
  }
  b.write('. Every day also includes a short New Testament passage chosen '
      "because Scripture itself echoes the day's Old Testament reading — so "
      'you keep seeing how the Bible is one story pointing to Jesus.');
  return b.toString() + _startSuffix(config);
}

/// Trailing sentence describing a non-default starting point, or '' for none.
String _startSuffix(PlanConfig c) {
  if (!c.hasCustomStart) return '';
  final where =
      '${bookLabel(c.startBook, CanonLanguage.code)} ${c.startChapter}';
  return c.wrapAround
      ? ' It starts at $where and wraps back around, so you still cover '
          'everything before it.'
      : ' It starts at $where and runs to the end.';
}
