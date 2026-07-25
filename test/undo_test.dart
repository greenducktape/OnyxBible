import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/main.dart';

void main() {
  test('undo and redo of an added stroke', () {
    final u = UndoController();
    const id = 'UndoTest_1_1';
    DrawingStore.setStrokes(id, <Stroke>[]);

    final s = Stroke(points: const [StrokePoint(0, 0), StrokePoint(1, 1)]);
    DrawingStore.setStrokes(id, DrawingStore.strokesFor(id)..add(s));
    u.recordAdd(id, s);

    expect(DrawingStore.strokesFor(id).length, 1);
    expect(u.canUndo.value, isTrue);

    u.undo();
    expect(DrawingStore.strokesFor(id), isEmpty);
    expect(u.canRedo.value, isTrue);

    u.redo();
    expect(DrawingStore.strokesFor(id).length, 1);
  });

  test('erase is one undo step that restores all removed strokes', () {
    final u = UndoController();
    const id = 'UndoTest_2_1';
    final a = Stroke(points: const [StrokePoint(0, 0), StrokePoint(1, 1)]);
    final b = Stroke(points: const [StrokePoint(2, 2), StrokePoint(3, 3)]);
    DrawingStore.setStrokes(id, [a, b]);

    // Simulate erasing both in one gesture.
    DrawingStore.setStrokes(id, <Stroke>[]);
    u.recordErase(id, [a, b]);
    expect(DrawingStore.strokesFor(id), isEmpty);

    u.undo();
    expect(DrawingStore.strokesFor(id).length, 2);

    u.redo();
    expect(DrawingStore.strokesFor(id), isEmpty);
  });

  test('clear wipes history', () {
    final u = UndoController();
    const id = 'UndoTest_3_1';
    final s = Stroke(points: const [StrokePoint(0, 0), StrokePoint(1, 1)]);
    DrawingStore.setStrokes(id, [s]);
    u.recordAdd(id, s);

    u.clear();
    expect(u.canUndo.value, isFalse);
    u.undo(); // no-op, must not throw
    expect(u.canUndo.value, isFalse);
  });
}
