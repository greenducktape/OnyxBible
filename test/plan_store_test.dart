import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/plan_store.dart';
import 'package:boox_bible/reading_plan.dart';

void main() {
  test('SavedPlan round-trips through JSON', () {
    const s = SavedPlan(
      id: 'p1',
      title: 'Whole Bible · cross-referenced',
      config: PlanConfig(chaptersPerDay: 3, dailyPsalm: true),
      totalDays: 310,
      completedCount: 12,
      startEpochDay: 20000,
      lastActiveEpochDay: 20011,
      streak: 4,
    );
    final r = SavedPlan.fromJson(s.toJson());
    expect(r.id, 'p1');
    expect(r.title, s.title);
    expect(r.totalDays, 310);
    expect(r.completedCount, 12);
    expect(r.lastActiveEpochDay, 20011);
    expect(r.streak, 4);
    expect(r.config.chaptersPerDay, 3);
    expect(r.config.dailyPsalm, isTrue);
  });

  test('currentIndex points at the next unread reading and clamps when done',
      () {
    const a = SavedPlan(
        id: 'p', title: 't', config: PlanConfig(), totalDays: 10,
        completedCount: 3);
    expect(a.currentIndex, 3);
    expect(a.isFinished, isFalse);

    const b = SavedPlan(
        id: 'p', title: 't', config: PlanConfig(), totalDays: 10,
        completedCount: 10);
    expect(b.isFinished, isTrue);
    expect(b.currentIndex, 9); // clamped to last
  });

  test('copyWith advances the pointer without touching the config', () {
    const a = SavedPlan(
        id: 'p', title: 't', config: PlanConfig(chaptersPerDay: 4),
        totalDays: 10, completedCount: 3);
    final b = a.copyWith(completedCount: 4, streak: 2);
    expect(b.completedCount, 4);
    expect(b.streak, 2);
    expect(b.config.chaptersPerDay, 4); // preserved
    expect(b.id, 'p');
  });

  test('epochDayOf advances by one per calendar day', () {
    final a = PlanStore.epochDayOf(DateTime(2026, 1, 1));
    final b = PlanStore.epochDayOf(DateTime(2026, 1, 2));
    expect(b - a, 1);
  });
}
