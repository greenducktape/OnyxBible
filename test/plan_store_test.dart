import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/plan_store.dart';

void main() {
  test('PlanState round-trips through JSON', () {
    const s = PlanState(
        planId: 'companion', startEpochDay: 20000, completed: {0, 1, 5});
    final r = PlanState.fromJson(s.toJson());
    expect(r.planId, 'companion');
    expect(r.startEpochDay, 20000);
    expect(r.completed, {0, 1, 5});
    expect(r.hasPlan, isTrue);
  });

  test('dayIndexOn clamps to the plan window', () {
    const s = PlanState(planId: 'p', startEpochDay: 100);
    expect(s.dayIndexOn(100, 365), 0); // day it started
    expect(s.dayIndexOn(105, 365), 5);
    expect(s.dayIndexOn(99, 365), 0); // before start
    expect(s.dayIndexOn(10000, 365), 364); // long after: last day, not past end
  });

  test('streakOn counts consecutive completed days ending today/yesterday', () {
    // Started at day 100; today is day 104 (index 4). Days 2,3,4 done.
    const s = PlanState(
        planId: 'p', startEpochDay: 100, completed: {2, 3, 4});
    expect(s.streakOn(104, 365), 3);

    // Today (index 4) not done, but 2 and 3 are: streak counts to yesterday.
    const s2 =
        PlanState(planId: 'p', startEpochDay: 100, completed: {2, 3});
    expect(s2.streakOn(104, 365), 2);

    // A gap breaks the streak.
    const s3 =
        PlanState(planId: 'p', startEpochDay: 100, completed: {0, 1, 4});
    expect(s3.streakOn(104, 365), 1);
  });

  test('epochDayOf advances by one per calendar day', () {
    final a = PlanStore.epochDayOf(DateTime(2026, 1, 1));
    final b = PlanStore.epochDayOf(DateTime(2026, 1, 2));
    expect(b - a, 1);
  });
}
