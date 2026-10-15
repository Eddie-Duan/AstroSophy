import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/moon_disc.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合成一张月面，亮面占比精确已知。
///
/// 遮挡关系直接照搬球面几何：观察者在 +z，太阳与观察方向的夹角是相位角 i，
/// 于是 `c = cos i = 2k − 1`，而投影到画面上的亮面就是
/// `x ≥ −c·√(1 − y²)` 那一块。这样"标准答案"不是另一个实现给的，是几何给的。
Uint8List renderMoon({
  required int size,
  required double radius,
  required double k,
  double centerX = 0,
  double centerY = 0,
  int skyLevel = 8,
  int litLevel = 245,
}) {
  final cx = centerX == 0 ? (size - 1) / 2 : centerX;
  final cy = centerY == 0 ? (size - 1) / 2 : centerY;
  final c = 2 * k - 1;
  final gray = Uint8List(size * size)..fillRange(0, size * size, skyLevel);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = (x - cx) / radius;
      final dy = (y - cy) / radius;
      if (dx * dx + dy * dy > 1) continue;
      // 明暗界线：半椭圆，半短轴 |c|·R。
      final terminator = -c * math.sqrt(math.max(0.0, 1 - dy * dy));
      gray[y * size + x] = dx >= terminator ? litLevel : skyLevel;
    }
  }
  return gray;
}

void main() {
  const size = 220;

  double measured(Uint8List gray) {
    final disc = measureMoonDisc(gray: gray, width: size, height: size);
    expect(disc, isNotNull, reason: '这张图该量得出来');
    return disc!.illuminatedFraction;
  }

  group('月面测量', () {
    test('满月：亮面占比接近 1', () {
      final disc = measureMoonDisc(
        gray: renderMoon(size: size, radius: 80, k: 1.0),
        width: size,
        height: size,
      )!;
      expect(disc.illuminatedFraction, closeTo(1.0, 0.01));
      expect(disc.centerX, closeTo((size - 1) / 2, 1.5));
      expect(disc.centerY, closeTo((size - 1) / 2, 1.5));
      expect(disc.radiusPixels, closeTo(80, 1.5));
    });

    test('各个相位量出来的占比都对得上几何给出的那个数', () {
      // 0.5 是上下弦、0.25 是月牙、0.75 是凸月。逐个比，容差来自像素离散化
      // （边缘一圈像素的归属）和最小外接圆的半个像素误差。
      for (final k in [0.15, 0.25, 0.35, 0.5, 0.65, 0.75, 0.9]) {
        expect(
          measured(renderMoon(size: size, radius: 80, k: k)),
          closeTo(k, 0.02),
          reason: 'k = $k',
        );
      }
    });

    test('月牙再细也要靠外缘把整个月盘认出来', () {
      // 这条是这套测量的关键：月牙只有一小弯，但它的两个尖角是一条直径的
      // 两端，所以最小外接圆仍然是整个月盘。认错的话半径会缩，占比会虚高。
      final disc = measureMoonDisc(
        gray: renderMoon(size: size, radius: 80, k: 0.12),
        width: size,
        height: size,
      )!;
      expect(disc.radiusPixels, closeTo(80, 2));
      expect(disc.illuminatedFraction, closeTo(0.12, 0.02));
    });

    test('月亮不在画面正中时照样量得准', () {
      final disc = measureMoonDisc(
        gray: renderMoon(size: size, radius: 60, k: 0.6, centerX: 70, centerY: 150),
        width: size,
        height: size,
      )!;
      expect(disc.centerX, closeTo(70, 1.5));
      expect(disc.centerY, closeTo(150, 1.5));
      expect(disc.radiusPixels, closeTo(60, 1.5));
      expect(disc.illuminatedFraction, closeTo(0.6, 0.02));
    });

    test('月盘占画面的比例也算得出来', () {
      final disc = measureMoonDisc(
        gray: renderMoon(size: size, radius: 80, k: 0.5),
        width: size,
        height: size,
      )!;
      // π·80² / 220² = 0.415
      expect(disc.discAreaFraction, closeTo(0.415, 0.02));
    });
  });

  group('不是月亮的不认', () {
    test('一片星空：没有够大的亮面', () {
      final gray = Uint8List(size * size);
      final random = math.Random(7);
      for (var i = 0; i < 400; i++) {
        gray[random.nextInt(gray.length)] = 200;
      }
      expect(measureMoonDisc(gray: gray, width: size, height: size), isNull);
    });

    test('细长的亮条不算——那是路灯、窗框、水印', () {
      final gray = Uint8List(size * size);
      for (var y = 100; y < 120; y++) {
        for (var x = 0; x < size; x++) {
          gray[y * size + x] = 240;
        }
      }
      expect(measureMoonDisc(gray: gray, width: size, height: size), isNull);
    });

    test('纯黑帧不炸', () {
      expect(
        measureMoonDisc(
          gray: Uint8List(size * size),
          width: size,
          height: size,
        ),
        isNull,
      );
    });

    test('尺寸对不上的缓冲不越界', () {
      expect(
        measureMoonDisc(gray: Uint8List(10), width: size, height: size),
        isNull,
      );
    });
  });
}
