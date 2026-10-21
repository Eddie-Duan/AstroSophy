import 'dart:typed_data';

import 'package:astrosophy/live_star_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('路灯那种宽亮斑不会被当成星点', () {
    const width = 160;
    const height = 120;
    final y = Uint8List(width * height)..fillRange(0, width * height, 10);
    // 一颗尖星。
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        y[(60 + dy) * width + 80 + dx] = 250;
      }
    }
    // 一大块路灯光斑。
    for (var py = 35; py < 75; py++) {
      for (var px = 25; px < 65; px++) {
        y[py * width + px] = 245;
      }
    }
    final detections = LiveStarTracker.detect(y, width, height, width);
    expect(detections.any((d) => (d.x - 0.5).abs() < 0.05), isTrue);
    expect(
      detections.any((d) => (d.x - 0.28).abs() < 0.08 && (d.y - 0.46).abs() < 0.12),
      isFalse,
    );
  });
}
