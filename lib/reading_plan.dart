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

/// "Cross-Reference Companion": walks the New Testament one chapter per day and
/// pairs each with the Old Testament chapter it is most strongly cross-linked
/// to — Isaiah 53 beside 1 Peter 2, Psalm 22 beside the crucifixion, and so on.
/// Prefers an OT chapter not yet used so the pairings stay varied; falls back to
/// the strongest link, then to canonical order when the graph is silent.
ReadingPlan companionPlan(XrefGraph graph) {
  final nt = chaptersOfTestament(oldTestament: false);
  final usedOt = <BibleRef>{};
  final otFallback = chaptersOfTestament(oldTestament: true);
  var fallbackIdx = 0;
  final days = <PlanDay>[];

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
    days.add(PlanDay(
      [ntCh, if (pick != null) pick],
      pairingVotes: votes,
    ));
  }
  return ReadingPlan(
    id: 'companion',
    title: 'Cross-Reference Companion',
    subtitle: 'The New Testament, each chapter paired with its Old '
        'Testament roots',
    days: days,
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

/// A selectable plan in the UI, with a builder that needs the loaded graph.
class PlanInfo {
  final String id;
  final String title;
  final String subtitle;
  final ReadingPlan Function(XrefGraph) build;

  const PlanInfo({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.build,
  });
}

const List<PlanInfo> kPlans = [
  PlanInfo(
    id: 'companion',
    title: 'Cross-Reference Companion',
    subtitle: 'New Testament + its OT roots · 260 days',
    build: companionPlan,
  ),
  PlanInfo(
    id: 'year',
    title: 'Whole Bible in a Year',
    subtitle: 'OT & NT interleaved by cross-reference · 365 days',
    build: _yearPlan,
  ),
  PlanInfo(
    id: 'twoYear',
    title: 'Whole Bible in Two Years',
    subtitle: 'A gentler pace, same cross-reference pairing · 730 days',
    build: _twoYearPlan,
  ),
];

ReadingPlan _yearPlan(XrefGraph g) => wholeBiblePlan(g,
    id: 'year',
    title: 'Whole Bible in a Year',
    subtitle: 'OT & NT interleaved by cross-reference',
    totalDays: 365);

ReadingPlan _twoYearPlan(XrefGraph g) => wholeBiblePlan(g,
    id: 'twoYear',
    title: 'Whole Bible in Two Years',
    subtitle: 'OT & NT interleaved by cross-reference',
    totalDays: 730);

PlanInfo planInfoById(String id) =>
    kPlans.firstWhere((p) => p.id == id, orElse: () => kPlans.first);
