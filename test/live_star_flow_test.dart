import 'dart:typed_data';

import 'package:astrosophy/live_star_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('光流能跟住相邻帧里平移的星点', () {
    const width = 160;
    const height = 120;
    Uint8List frame(int shift) {
      final y = Uint8List(width * height)..fillRange(0, width * height, 8);
      for (final (x, y0) in const [
        (40, 30),
        (80, 60),
        (120, 90),
        (60, 90),
      ]) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            y[(y0 + dy) * width + x + dx + shift] = 240;
          }
        }
      }
      return y;
    }

    final flow = LiveStarFlow();
    final first = frame(0);
    flow.seed(first, width, height, width, const [
      LiveStarDetection(40 / width, 30 / height, 1),
      LiveStarDetection(80 / width, 60 / height, 1),
      LiveStarDetection(120 / width, 90 / height, 1),
      LiveStarDetection(60 / width, 90 / height, 1),
    ]);
    final tracked = flow.track(frame(2), width, height, width);
    expect(tracked, isNotNull);
    expect(tracked!.length, 4);
    expect(tracked.first.x * width, closeTo(42, 1.5));
  });
}
