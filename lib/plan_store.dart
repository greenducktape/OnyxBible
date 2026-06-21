import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'atomic_file.dart';
import 'reading_plan.dart';

/// One saved reading plan and its self-paced progress. The plan's days are NOT
/// stored — they are re-derived deterministically from [config] (see
/// reading_plan.dart generatePlan), so the file stays tiny and a plan can never
/// drift out of sync with the generator.
///
/// Progress is a pointer ([completedCount]) into that day list and is NOT tied
/// to the calendar: skipping days never piles up a backlog. The "current"
/// reading is simply the next unread one, whenever you next sit down.
class SavedPlan {
  final String id;
  final String title;
  final PlanConfig config;
  final int totalDays; // generatePlan(config).length, cached for display
  final int completedCount; // readings finished, in order (the pointer)
  final int startEpochDay; // when the plan was started (display only)
  final int lastActiveEpochDay; // last day a reading was completed (streak)
  final int streak; // consecutive calendar days with ≥1 completion

  const SavedPlan({
    required this.id,
    required this.title,
    required this.config,
    required this.totalDays,
    this.completedCount = 0,
    this.startEpochDay = 0,
    this.lastActiveEpochDay = 0,
    this.streak = 0,
  });

  bool get isFinished => completedCount >= totalDays;

  /// Index of the reading to do next (clamped to the last when finished).
  int get currentIndex =>
      completedCount >= totalDays ? totalDays - 1 : completedCount;

  SavedPlan copyWith({
    String? title,
    PlanConfig? config,
    int? totalDays,
    int? completedCount,
    int? startEpochDay,
    int? lastActiveEpochDay,
    int? streak,
  }) =>
      SavedPlan(
        id: id,
        title: title ?? this.title,
        config: config ?? this.config,
        totalDays: totalDays ?? this.totalDays,
        completedCount: completedCount ?? this.completedCount,
        startEpochDay: startEpochDay ?? this.startEpochDay,
        lastActiveEpochDay: lastActiveEpochDay ?? this.lastActiveEpochDay,
        streak: streak ?? this.streak,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'config': config.toJson(),
        'totalDays': totalDays,
        'completedCount': completedCount,
        'startEpochDay': startEpochDay,
        'lastActiveEpochDay': lastActiveEpochDay,
        'streak': streak,
      };

  factory SavedPlan.fromJson(Map<String, dynamic> j) => SavedPlan(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Reading plan',
        config:
            PlanConfig.fromJson((j['config'] as Map).cast<String, dynamic>()),
        totalDays: (j['totalDays'] as num?)?.toInt() ?? 0,
        completedCount: (j['completedCount'] as num?)?.toInt() ?? 0,
        startEpochDay: (j['startEpochDay'] as num?)?.toInt() ?? 0,
        lastActiveEpochDay: (j['lastActiveEpochDay'] as num?)?.toInt() ?? 0,
        streak: (j['streak'] as num?)?.toInt() ?? 0,
      );
}

/// A library of saved reading plans. Starting a new plan ADDS to the library and
/// makes it active; it never deletes the plan you were on, so every plan keeps
/// its own progress. File-based JSON, written immediately on every change.
class PlanStore {
  static List<SavedPlan> _plans = [];
  static String? _activeId;
  static bool _loaded = false;

  static List<SavedPlan> get plans => List.unmodifiable(_plans);
  static String? get activeId => _activeId;

  static SavedPlan? get active {
    for (final p in _plans) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

  /// Local-midnight day number (days since the Unix epoch).
  static int epochDayNow() => epochDayOf(DateTime.now());

  static int epochDayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

  static Future<void> init() async {
    if (_loaded) return;
    try {
      final f = await _file();
      final r = await readJsonResilient(f);
      if (r.data is Map<String, dynamic>) {
        final j = r.data as Map<String, dynamic>;
        _plans = [
          for (final e in (j['plans'] as List? ?? const []))
            SavedPlan.fromJson((e as Map).cast<String, dynamic>()),
        ];
        _activeId = j['activeId'] as String?;
      } else if (!await f.exists()) {
        await _migrateLegacy();
      }
    } catch (e) {
      debugPrint('Error loading plans: $e');
    }
    _loaded = true;
  }

  /// Create a new saved plan from [config] and make it active. Returns it.
  static SavedPlan create(PlanConfig config, int totalDays) {
    final id = 'p${DateTime.now().millisecondsSinceEpoch}';
    final plan = SavedPlan(
      id: id,
      title: config.title,
      config: config,
      totalDays: totalDays,
      startEpochDay: epochDayNow(),
    );
    _plans = [..._plans, plan];
    _activeId = id;
    _write();
    return plan;
  }

  static void setActive(String id) {
    _activeId = id;
    _write();
  }

  static void delete(String id) {
    _plans = [for (final p in _plans) if (p.id != id) p];
    if (_activeId == id) _activeId = _plans.isEmpty ? null : _plans.last.id;
    _write();
  }

  /// Finish the current reading of the active plan and advance the pointer,
  /// updating the gentle activity streak (consecutive calendar days with at
  /// least one completion — never punitive).
  static void completeCurrent() {
    final p = active;
    if (p == null || p.completedCount >= p.totalDays) return;
    final today = epochDayNow();
    final int nextStreak;
    if (p.lastActiveEpochDay == today) {
      nextStreak = p.streak == 0 ? 1 : p.streak; // already read today
    } else if (p.lastActiveEpochDay == today - 1) {
      nextStreak = p.streak + 1;
    } else {
      nextStreak = 1;
    }
    _replaceActive(p.copyWith(
      completedCount: p.completedCount + 1,
      lastActiveEpochDay: today,
      streak: nextStreak,
    ));
  }

  /// Step the active plan's pointer back one (undo a mistaken completion).
  static void uncompleteLast() {
    final p = active;
    if (p == null || p.completedCount <= 0) return;
    _replaceActive(p.copyWith(completedCount: p.completedCount - 1));
  }

  static void _replaceActive(SavedPlan next) {
    _plans = [for (final p in _plans) if (p.id == next.id) next else p];
    _write();
  }

  // Plan changes are infrequent (a deliberate tap), so write immediately rather
  // than debounce — completing a reading must never feel like it didn't save.
  static void _write() => unawaited(_flush());

  static Future<void> _flush() async {
    try {
      await writeJsonAtomic(await _file(), {
        'schema': 1,
        'activeId': _activeId,
        'plans': [for (final p in _plans) p.toJson()],
      });
    } catch (e) {
      debugPrint('Error saving plans: $e');
    }
  }

  // Carry a single v3 plan (plan_state_v1.json) into the new library so existing
  // progress isn't lost. The old state stored a plan *kind* + length, not a
  // config, so we approximate a cross-referenced whole-Bible config and keep the
  // pointer/streak. Best-effort — exact day boundaries may shift slightly.
  static Future<void> _migrateLegacy() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final legacy = File('${dir.path}/plan_state_v1.json');
      if (!await legacy.exists()) return;
      final s = await legacy.readAsString();
      if (s.isEmpty) return;
      final j = json.decode(s) as Map<String, dynamic>;
      final planId = j['planId'] as String?;
      if (planId == null) return;
      final config = planId == 'companion'
          ? const PlanConfig(chaptersPerDay: 2, dailyPsalm: false)
          : const PlanConfig();
      final total = planLength(config);
      final done = (j['completedCount'] as num?)?.toInt() ??
          (j['completed'] as List?)?.length ??
          0;
      final id = 'p${DateTime.now().millisecondsSinceEpoch}';
      _plans = [
        SavedPlan(
          id: id,
          title: config.title,
          config: config,
          totalDays: total,
          completedCount: done.clamp(0, total).toInt(),
          startEpochDay: (j['startEpochDay'] as num?)?.toInt() ?? 0,
          lastActiveEpochDay: (j['lastActiveEpochDay'] as num?)?.toInt() ?? 0,
          streak: (j['streak'] as num?)?.toInt() ?? 0,
        ),
      ];
      _activeId = id;
      await _flush();
    } catch (e) {
      debugPrint('Plan migration skipped: $e');
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/plans_v2.json');
  }
}
