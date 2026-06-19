import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persisted state of the reader's active reading plan: which plan, when it was
/// started, and which day indices have been checked off. File-based JSON, in
/// keeping with the app's other stores (no extra plugin dependency).
class PlanState {
  final String? planId;
  final int startEpochDay; // local-midnight day number when the plan began
  final Set<int> completed; // checked-off day indices (0-based)

  const PlanState({
    this.planId,
    this.startEpochDay = 0,
    this.completed = const {},
  });

  bool get hasPlan => planId != null;

  PlanState copyWith({
    String? planId,
    int? startEpochDay,
    Set<int>? completed,
    bool clearPlan = false,
  }) =>
      PlanState(
        planId: clearPlan ? null : (planId ?? this.planId),
        startEpochDay: startEpochDay ?? this.startEpochDay,
        completed: completed ?? this.completed,
      );

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'planId': planId,
        'startEpochDay': startEpochDay,
        'completed': completed.toList()..sort(),
      };

  factory PlanState.fromJson(Map<String, dynamic> j) => PlanState(
        planId: j['planId'] as String?,
        startEpochDay: (j['startEpochDay'] as num?)?.toInt() ?? 0,
        completed: ((j['completed'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toSet(),
      );

  /// Day index the reader is on today (0-based), given the plan length. Clamped
  /// so a long-abandoned plan still opens on its final day rather than past it.
  int dayIndexOn(int epochDay, int planLength) {
    if (planLength <= 0) return 0;
    final raw = epochDay - startEpochDay;
    if (raw < 0) return 0;
    return raw >= planLength ? planLength - 1 : raw;
  }

  /// Consecutive checked-off days ending today (or yesterday, if today isn't
  /// done yet) — the reader's current streak.
  int streakOn(int epochDay, int planLength) {
    var i = dayIndexOn(epochDay, planLength);
    if (!completed.contains(i)) i--; // today not done: count up to yesterday
    var s = 0;
    while (i >= 0 && completed.contains(i)) {
      s++;
      i--;
    }
    return s;
  }
}

class PlanStore {
  static PlanState _value = const PlanState();
  static bool _loaded = false;
  static Timer? _saveDebouncer;

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

  static void update(PlanState next) {
    _value = next;
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 400), () async {
      try {
        final f = await _file();
        await f.writeAsString(json.encode(_value.toJson()));
      } catch (e) {
        debugPrint('Error saving plan state: $e');
      }
    });
  }

  /// Begin (or switch to) a plan today, clearing any previous progress.
  static void start(String planId) => update(PlanState(
        planId: planId,
        startEpochDay: epochDayNow(),
        completed: const {},
      ));

  static void toggleDay(int dayIndex) {
    final next = Set<int>.of(_value.completed);
    if (!next.add(dayIndex)) next.remove(dayIndex);
    update(_value.copyWith(completed: next));
  }

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/plan_state_v1.json');
  }
}
