import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Self-paced reading-plan progress. The plan is a fixed ordered list of
/// readings; you advance a pointer ([completedCount]) by finishing the current
/// reading. Crucially this is NOT tied to the calendar: skipping days never
/// piles up a backlog of missed boxes — the "current" reading is simply the
/// next unread one, whenever you next sit down. File-based JSON like the app's
/// other stores. Written immediately on every change so progress never feels
/// lost.
class PlanState {
  final String? planId; // plan-kind id (see reading_plan.dart kPlans)
  final int totalDays; // number of readings in the generated plan
  final int completedCount; // readings finished, in order (the pointer)
  final int startEpochDay; // when the plan was started (for display only)
  final int lastActiveEpochDay; // last day a reading was completed (streak)
  final int streak; // consecutive calendar days with ≥1 completion

  const PlanState({
    this.planId,
    this.totalDays = 0,
    this.completedCount = 0,
    this.startEpochDay = 0,
    this.lastActiveEpochDay = 0,
    this.streak = 0,
  });

  bool get hasPlan => planId != null && totalDays > 0;
  bool get isFinished => hasPlan && completedCount >= totalDays;

  /// Index of the reading to do next (clamped to the last when finished).
  int get currentIndex =>
      completedCount >= totalDays ? totalDays - 1 : completedCount;

  PlanState copyWith({
    String? planId,
    int? totalDays,
    int? completedCount,
    int? startEpochDay,
    int? lastActiveEpochDay,
    int? streak,
  }) =>
      PlanState(
        planId: planId ?? this.planId,
        totalDays: totalDays ?? this.totalDays,
        completedCount: completedCount ?? this.completedCount,
        startEpochDay: startEpochDay ?? this.startEpochDay,
        lastActiveEpochDay: lastActiveEpochDay ?? this.lastActiveEpochDay,
        streak: streak ?? this.streak,
      );

  Map<String, dynamic> toJson() => {
        'schema': 2,
        'planId': planId,
        'totalDays': totalDays,
        'completedCount': completedCount,
        'startEpochDay': startEpochDay,
        'lastActiveEpochDay': lastActiveEpochDay,
        'streak': streak,
      };

  factory PlanState.fromJson(Map<String, dynamic> j) {
    // v2 (pointer) format.
    if (j.containsKey('completedCount')) {
      return PlanState(
        planId: j['planId'] as String?,
        totalDays: (j['totalDays'] as num?)?.toInt() ?? 0,
        completedCount: (j['completedCount'] as num?)?.toInt() ?? 0,
        startEpochDay: (j['startEpochDay'] as num?)?.toInt() ?? 0,
        lastActiveEpochDay: (j['lastActiveEpochDay'] as num?)?.toInt() ?? 0,
        streak: (j['streak'] as num?)?.toInt() ?? 0,
      );
    }
    // v1 (calendar) format → migrate. Old plan ids: companion/year/twoYear.
    final legacyId = j['planId'] as String?;
    if (legacyId == null) return const PlanState();
    final kind = legacyId == 'companion' ? 'companion' : 'wholeBible';
    final total = switch (legacyId) {
      'companion' => 260,
      'year' => 365,
      'twoYear' => 730,
      _ => 365,
    };
    final doneCount = (j['completed'] as List?)?.length ?? 0;
    return PlanState(
      planId: kind,
      totalDays: total,
      completedCount: doneCount.clamp(0, total).toInt(),
      startEpochDay: (j['startEpochDay'] as num?)?.toInt() ?? 0,
    );
  }
}

class PlanStore {
  static PlanState _value = const PlanState();
  static bool _loaded = false;

  static PlanState get value => _value;

  /// Local-midnight day number (days since the Unix epoch).
  static int epochDayNow() => epochDayOf(DateTime.now());

  static int epochDayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 86400000;

  static Future<void> init() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (await f.exists()) {
        final s = await f.readAsString();
        if (s.isNotEmpty) {
          _value = PlanState.fromJson(json.decode(s) as Map<String, dynamic>);
        }
      }
    } catch (e) {
      debugPrint('Error loading plan state: $e');
    }
    _loaded = true;
  }

  /// Start (or replace) a plan today, resetting progress.
  static void start(String planId, int totalDays) => _write(PlanState(
        planId: planId,
        totalDays: totalDays,
        startEpochDay: epochDayNow(),
      ));

  /// Finish the current reading and advance the pointer, updating the gentle
  /// activity streak (consecutive calendar days with at least one completion).
  static void completeCurrent() {
    final v = _value;
    if (!v.hasPlan || v.completedCount >= v.totalDays) return;
    final today = epochDayNow();
    final int nextStreak;
    if (v.lastActiveEpochDay == today) {
      nextStreak = v.streak == 0 ? 1 : v.streak; // already read today
    } else if (v.lastActiveEpochDay == today - 1) {
      nextStreak = v.streak + 1;
    } else {
      nextStreak = 1;
    }
    _write(v.copyWith(
      completedCount: v.completedCount + 1,
      lastActiveEpochDay: today,
      streak: nextStreak,
    ));
  }

  /// Step the pointer back one (undo a mistaken completion).
  static void uncompleteLast() {
    final v = _value;
    if (!v.hasPlan || v.completedCount <= 0) return;
    _write(v.copyWith(completedCount: v.completedCount - 1));
  }

  static void clearPlan() => _write(const PlanState());

  // Plan changes are infrequent (a deliberate tap), so write immediately rather
  // than debounce — completing a reading must never feel like it didn't save.
  static void _write(PlanState next) {
    _value = next;
    unawaited(_flush());
  }

  static Future<void> _flush() async {
    try {
      final f = await _file();
      await f.writeAsString(json.encode(_value.toJson()));
    } catch (e) {
      debugPrint('Error saving plan state: $e');
    }
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/plan_state_v1.json');
  }
}
