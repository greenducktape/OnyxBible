import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/books.dart';
import 'package:boox_bible/reference.dart';
import 'package:boox_bible/reading_plan.dart';

bool _isOt(BibleRef r) => bookByName(r.book).isOldTestament;

void main() {
  // A tiny hand-built graph: Isaiah 53 <-> 1 Peter 2 is the strong link.
  final graph = XrefGraph.fromJson({
    '1 Peter 2': [
      ['Isaiah 53', 692],
      ['Psalms 118', 80],
    ],
    'Isaiah 53': [
      ['1 Peter 2', 692],
    ],
    'Matthew 27': [
      ['Psalms 22', 237],
    ],
  });

  test('XrefGraph round-trips and looks up affinity both directions', () {
    expect(graph.affinity(const BibleRef('Isaiah', 53), const BibleRef('1 Peter', 2)),
        692);
    expect(graph.affinity(const BibleRef('1 Peter', 2), const BibleRef('Isaiah', 53)),
        692);
    expect(graph.affinity(const BibleRef('John', 1), const BibleRef('Acts', 1)), 0);
  });

  test('keyOf / refOf round-trip multi-word books', () {
    const r = BibleRef('Song of Solomon', 2);
    expect(XrefGraph.refOf(XrefGraph.keyOf(r)), r);
    expect(XrefGraph.refOf(XrefGraph.keyOf(const BibleRef('1 Samuel', 3))),
        const BibleRef('1 Samuel', 3));
  });

  test('chaptersOfTestament counts the canon correctly', () {
    expect(chaptersOfTestament(oldTestament: true).length, 929);
    expect(chaptersOfTestament(oldTestament: false).length, 260);
  });

  group('companion plan', () {
    final plan = companionPlan(graph);

    test('has one day per New Testament chapter', () {
      expect(plan.length, 260);
    });

    test('pairs a cross-referenced NT chapter with its OT root', () {
      // 1 Peter 2 should be paired with Isaiah 53 and flagged cross-referenced.
      final day = plan.days.firstWhere(
          (d) => d.passages.first == const BibleRef('1 Peter', 2));
      expect(day.passages, contains(const BibleRef('Isaiah', 53)));
      expect(day.isCrossReferenced, isTrue);
      expect(day.pairingVotes, 692);
    });

    test('every day leads with a New Testament chapter', () {
      for (final d in plan.days) {
        expect(d.passages, isNotEmpty);
      }
    });

    test('regroups to a shorter length without losing any NT chapter', () {
      final short = companionPlan(graph, days: 90);
      expect(short.length, 90);
      // All 260 NT chapters still appear across the 90 grouped readings.
      final ntCount =
          short.days.expand((d) => d.passages).where((r) => !_isOt(r)).length;
      expect(ntCount, 260);
    });

    test('clamps a too-long request to the natural maximum', () {
      expect(companionPlan(graph, days: 5000).length, 260);
    });
  });

  group('whole-Bible plan', () {
    final plan = wholeBiblePlan(graph,
        id: 'year', title: 'Year', subtitle: '', totalDays: 365);

    test('spans exactly the requested number of days', () {
      expect(plan.length, 365);
    });

    test('covers every OT and NT chapter exactly once', () {
      final seen = <BibleRef>[];
      for (final d in plan.days) {
        seen.addAll(d.passages);
      }
      expect(seen.length, 929 + 260);
      expect(seen.toSet().length, 929 + 260); // no duplicates
    });
  });

  group('config-driven generator', () {
    test('planLength = ceil(mainTrack / chaptersPerDay)', () {
      // Cross-referenced whole Bible: main track is the 929 OT chapters.
      expect(planLength(const PlanConfig(chaptersPerDay: 3)),
          (929 / 3).ceil());
      // New Testament only: 260 chapters.
      expect(
          planLength(
              const PlanConfig(newTestamentOnly: true, chaptersPerDay: 1)),
          260);
      // Straight through: OT + NT = 1189 chapters.
      expect(
          planLength(const PlanConfig(crossReferenced: false, chaptersPerDay: 4)),
          (1189 / 4).ceil());
    });

    test('cross-referenced plan reads OT + a linked NT passage on day 1', () {
      final plan = generatePlan(graph, const PlanConfig(chaptersPerDay: 1));
      final day1 = plan.days.first;
      // Genesis 1 leads; a New Testament chapter is paired alongside it.
      expect(day1.passages.first, const BibleRef('Genesis', 1));
      expect(day1.passages.any((r) => !_isOt(r)), isTrue);
    });

    test('custom start (wrap-around) begins at the chosen book, covers all OT',
        () {
      final plan = generatePlan(graph,
          const PlanConfig(chaptersPerDay: 1, startBook: '2 Kings'));
      expect(plan.days.first.passages.first, const BibleRef('2 Kings', 1));
      // Wrapping back to Genesis means every OT chapter is still read once.
      final ot = plan.days.expand((d) => d.passages).where(_isOt).toList();
      expect(ot.toSet().length, 929);
    });

    test('custom start (no wrap) runs to the end and skips earlier books', () {
      final plan = generatePlan(
          graph,
          const PlanConfig(
              chaptersPerDay: 1, startBook: '2 Kings', wrapAround: false));
      expect(plan.days.first.passages.first, const BibleRef('2 Kings', 1));
      final ot = plan.days.expand((d) => d.passages).where(_isOt).toSet();
      expect(ot.contains(const BibleRef('2 Kings', 1)), isTrue);
      expect(ot.contains(const BibleRef('Genesis', 1)), isFalse); // skipped
    });

    test('planLength shrinks for a no-wrap partway start', () {
      final full = planLength(const PlanConfig(chaptersPerDay: 1));
      final partial = planLength(const PlanConfig(
          chaptersPerDay: 1, startBook: '2 Kings', wrapAround: false));
      expect(partial, lessThan(full));
    });

    test('NT echo dataset, when present, beats raw chapter affinity', () {
      // Synthetic data: Genesis 1's strongest *chapter* link is Matthew 1, but
      // the echoes asset says Hebrews 11:1-3 is the densest verse range. The
      // generator should prefer the echo (a snippet) on day 1.
      final g = XrefGraph.fromJson({
        'Genesis 1': [
          ['Matthew 1', 50],
          ['Hebrews 11', 30],
        ],
        'Matthew 1': [['Genesis 1', 50]],
        'Hebrews 11': [['Genesis 1', 30]],
      });
      final e = OtNtEchoes.fromJson({
        'Genesis 1': [
          {'book': 'Hebrews', 'chapter': 11, 'from': 1, 'to': 3, 'votes': 248},
        ],
      });
      final plan = generatePlan(g, const PlanConfig(chaptersPerDay: 1),
          echoes: e);
      final day1 = plan.days.first;
      expect(day1.passages.first, const BibleRef('Genesis', 1));
      // Verse-range echo present and points at Hebrews 11:1-3, NOT Matthew 1.
      final ntPick = day1.passages.firstWhere((r) => !_isOt(r));
      expect(ntPick.book, 'Hebrews');
      expect(ntPick.chapter, 11);
      expect(ntPick.verse, 1);
      expect(ntPick.endVerse, 3);
    });

    test('NT picks across the plan do not stagnate on one chapter', () {
      // Without echoes, the new picker should still spread the NT pairings
      // when affinity is roughly even — the recent-use penalty kicks in.
      final g = XrefGraph.fromJson({
        for (var c = 1; c <= 5; c++) 'Genesis $c': [
          // Three NT chapters with similar weights — recent-use penalty should
          // rotate them rather than picking the same one every day.
          ['Matthew 1', 100], ['Mark 1', 95], ['Luke 1', 90],
        ],
      });
      final plan = generatePlan(g, const PlanConfig(chaptersPerDay: 1));
      final ntPicks = <String>[];
      for (var i = 0; i < 5; i++) {
        final r = plan.days[i].passages.firstWhere((p) => !_isOt(p));
        ntPicks.add('${r.book} ${r.chapter}');
      }
      // Not all 5 days should be the same NT chapter.
      expect(ntPicks.toSet().length, greaterThan(1));
    });

    test('daily Psalm pulls Psalms out of the main track and adds one a day',
        () {
      final plan = generatePlan(
          graph, const PlanConfig(chaptersPerDay: 3, dailyPsalm: true));
      // Every day ends with a Psalm.
      for (final d in plan.days) {
        expect(d.passages.last.book, 'Psalms');
      }
      // Psalms are not also read as part of the OT main track (no day has a
      // non-final Psalm from the OT track).
      for (final d in plan.days) {
        final nonFinal = d.passages.sublist(0, d.passages.length - 1);
        expect(nonFinal.any((r) => r.book == 'Psalms'), isFalse);
      }
    });

    test('New Testament only stays in the New Testament', () {
      final plan = generatePlan(
          graph, const PlanConfig(newTestamentOnly: true, chaptersPerDay: 2));
      final allOt = plan.days.expand((d) => d.passages).where(_isOt);
      expect(allOt, isEmpty);
    });

    test('chronological ordering still covers every OT chapter once', () {
      final plan = generatePlan(
          graph,
          const PlanConfig(
              chaptersPerDay: 5, ordering: PlanOrdering.chronological));
      final ot = plan.days.expand((d) => d.passages).where(_isOt).toList();
      expect(ot.length, 929);
      expect(ot.toSet().length, 929);
      // Genesis 1 is still where reading begins.
      expect(plan.days.first.passages.first, const BibleRef('Genesis', 1));
    });

    test('narrative + duration read sensibly', () {
      expect(durationLabel(7), '7 days');
      expect(durationLabel(210), startsWith('about 7 months'));
      expect(durationLabel(600), startsWith('about 1 year'));
      expect(narrativeFor(const PlanConfig()), contains('Jesus'));
    });
  });
}
