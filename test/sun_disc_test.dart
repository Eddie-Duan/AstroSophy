import 'dart:typed_data';

import 'package:astrosophy/sun_disc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('太阳圆盘：找到圆心、半径和黑子', () {
    const width = 600;
    const height = 600;
    final gray = Uint8List(width * height)..fillRange(0, width * height, 8);
    const cx = 300.0;
    const cy = 300.0;
    const radius = 180.0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x - cx;
        final dy = y - cy;
        if (dx * dx + dy * dy <= radius * radius) {
          gray[y * width + x] = 190;
        }
      }
    }
    // 两个比周围暗的斑。
    for (final spot in [(250, 260, 7), (350, 340, 5)]) {
      for (var y = spot.$2 - spot.$3; y <= spot.$2 + spot.$3; y++) {
        for (var x = spot.$1 - spot.$3; x <= spot.$1 + spot.$3; x++) {
          if ((x - spot.$1) * (x - spot.$1) +
                  (y - spot.$2) * (y - spot.$2) <=
              spot.$3 * spot.$3) {
            gray[y * width + x] = 70;
          }
        }
      }
    }

    final disc = measureSunDisc(gray: gray, width: width, height: height);
    expect(disc, isNotNull);
    expect(disc!.centerX, closeTo(cx, 8));
    expect(disc.centerY, closeTo(cy, 8));
    expect(disc.radiusPixels, closeTo(radius, 12));
    expect(disc.darkSpotCount, greaterThanOrEqualTo(2));
  });
}
