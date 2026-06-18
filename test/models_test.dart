import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:boox_bible/main.dart';

void main() {
  group('StrokePoint', () {
    test('round-trips through JSON', () {
      const p = StrokePoint(12.5, 34.0, 0.7);
      final restored = StrokePoint.fromJson(p.toJson());
      expect(restored.x, p.x);
      expect(restored.y, p.y);
      expect(restored.pressure, p.pressure);
    });

    test('defaults pressure to 1.0 when missing', () {
      final p = StrokePoint.fromJson({'x': 1.0, 'y': 2.0});
      expect(p.pressure, 1.0);
    });
  });

  group('Stroke', () {
    test('round-trips through JSON', () {
      final s = Stroke(
        points: const [StrokePoint(0, 0), StrokePoint(10, 10, 0.5)],
        width: 3.5,
        color: const Color(0xFF000000),
      );
      final restored = Stroke.fromJson(s.toJson());
      expect(restored.points.length, 2);
      expect(restored.width, 3.5);
      expect(restored.points[1].pressure, 0.5);
    });

    test('isNear detects a point within radius', () {
      final s = Stroke(points: const [StrokePoint(50, 50)]);
      expect(s.isNear(const Offset(55, 50), 10), isTrue);
      expect(s.isNear(const Offset(70, 70), 10), isFalse);
    });
  });

  group('Verse', () {
    test('round-trips through JSON', () {
      const v = Verse(id: 'John_3_16', number: 16, text: 'For God so loved...');
      final restored = Verse.fromJson(v.toJson());
      expect(restored.id, 'John_3_16');
      expect(restored.number, 16);
      expect(restored.text, 'For God so loved...');
    });
  });
}
