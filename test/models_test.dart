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

    test('round-trips the pen style and defaults to ballpoint', () {
      final s = Stroke(
        points: const [StrokePoint(0, 0)],
        style: 'fountain',
      );
      expect(s.toJson()['st'], 'fountain');
      expect(Stroke.fromJson(s.toJson()).style, 'fountain');

      // Ballpoint is the default and is omitted from JSON.
      final plain = Stroke(points: const [StrokePoint(0, 0)]);
      expect(plain.toJson().containsKey('st'), isFalse);
      expect(Stroke.fromJson(plain.toJson()).style, 'ballpoint');
    });

    test('isNear detects a point within radius', () {
      final s = Stroke(points: const [StrokePoint(50, 50)]);
      expect(s.isNear(const Offset(55, 50), 10), isTrue);
      expect(s.isNear(const Offset(70, 70), 10), isFalse);
    });

    test('round-trips the capture box and omits it when unknown', () {
      final s = Stroke(
        points: const [StrokePoint(0, 0)],
        captureW: 300,
        captureH: 120,
      );
      final json = s.toJson();
      expect(json['cw'], 300);
      expect(json['ch'], 120);
      final restored = Stroke.fromJson(json);
      expect(restored.captureW, 300);
      expect(restored.captureH, 120);

      // Legacy strokes carry no capture box.
      final legacy = Stroke(points: const [StrokePoint(0, 0)]);
      expect(legacy.toJson().containsKey('cw'), isFalse);
      expect(Stroke.fromJson(legacy.toJson()).captureW, 0);
    });

    test('scaleTo maps the capture box onto the current canvas', () {
      final s = Stroke(
          points: const [StrokePoint(0, 0)], captureW: 100, captureH: 200);
      expect(s.scaleTo(const Size(200, 400)), (2.0, 2.0));
      // Unknown capture box or missing canvas is identity.
      expect(s.scaleTo(null), (1.0, 1.0));
      expect(Stroke(points: const [StrokePoint(0, 0)]).scaleTo(const Size(50, 50)),
          (1.0, 1.0));
    });

    test('isNear hit-tests in rescaled canvas space', () {
      // Point at (50,50) in a 100x100 capture box maps to (100,100) on a
      // 200x200 canvas, so the eraser must match there, not at (50,50).
      final s = Stroke(
          points: const [StrokePoint(50, 50)], captureW: 100, captureH: 100);
      expect(s.isNear(const Offset(100, 100), 8, canvas: const Size(200, 200)),
          isTrue);
      expect(s.isNear(const Offset(50, 50), 8, canvas: const Size(200, 200)),
          isFalse);
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
