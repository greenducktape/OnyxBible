import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/plan_store.dart';

void main() {
  test('PlanState round-trips through JSON (pointer model)', () {
    const s = PlanState(
      planId: 'companion',
      totalDays: 260,
      completedCount: 12,
      startEpochDay: 20000,
      lastActiveEpochDay: 20011,
      streak: 4,
    );
    final r = PlanState.fromJson(s.toJson());
    expect(r.planId, 'companion');
    expect(r.totalDays, 260);
    expect(r.completedCount, 12);
    expect(r.lastActiveEpochDay, 20011);
    expect(r.streak, 4);
    expect(r.hasPlan, isTrue);
  });

  test('currentIndex points at the next unread reading and clamps when done',
      () {
    const a = PlanState(planId: 'p', totalDays: 10, completedCount: 3);
    expect(a.currentIndex, 3);
    expect(a.isFinished, isFalse);

    const b = PlanState(planId: 'p', totalDays: 10, completedCount: 10);
    expect(b.isFinished, isTrue);
    expect(b.currentIndex, 9); // clamped to last
  });

  test('migrates the legacy calendar format to a pointer', () {
    // Old v1 state: a 'year' plan with three calendar days checked off.
    final migrated = PlanState.fromJson({
      'planId': 'year',
      'startEpochDay': 19000,
      'completed': [0, 1, 2],
    });
    expect(migrated.planId, 'wholeBible'); // year/twoYear → wholeBible kind
    expect(migrated.totalDays, 365);
    expect(migrated.completedCount, 3); // progress preserved
  });

  test('epochDayOf advances by one per calendar day', () {
    final a = PlanStore.epochDayOf(DateTime(2026, 1, 1));
    final b = PlanStore.epochDayOf(DateTime(2026, 1, 2));
    expect(b - a, 1);
  });
}
