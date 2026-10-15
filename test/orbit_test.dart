import 'dart:math' as math;

import 'package:astrosophy/orbit.dart';
import 'package:flutter_test/flutter_test.dart';

/// 开普勒轨道那一段数学。
///
/// 这些用例刻意**不碰任何真实行星的根数**：本文件验的是「给定一组根数，算得
/// 对不对」，而根数本身对不对是 `ephemeris.dart` 的事。混在一起的话，抄错一个
/// 数字和算错一个矩阵会表现成同一种失败，谁也说不清是哪边坏了。
///
/// 所以这里的根数都是手编的、能笔算出答案的：偏心率为零的圆、倾角正好 90°、
/// 升交点正好 90°。每个预期值都是先拿纸推出来再写进断言的。

/// 编一组根数，变率默认全零——静态轨道足以验证几何。
OrbitalElements _elements({
  double a = 1,
  double e = 0,
  double i = 0,
  double l = 0,
  double perihelion = 0,
  double node = 0,
  double aRate = 0,
  double eRate = 0,
}) =>
    OrbitalElements(
      semiMajorAxis: a,
      semiMajorAxisRate: aRate,
      eccentricity: e,
      eccentricityRate: eRate,
      inclination: i,
      inclinationRate: 0,
      meanLongitude: l,
      meanLongitudeRate: 0,
      perihelionLongitude: perihelion,
      perihelionLongitudeRate: 0,
      nodeLongitude: node,
      nodeLongitudeRate: 0,
    );

/// 独立实现的开普勒方程解法，用**二分法**，和被测代码的牛顿迭代不是一回事。
///
/// 拿它当参照物才叫验证：如果测试里也用牛顿法，两边会一起错、一起过。
double _eccentricAnomalyByBisection(double meanAnomaly, double eccentricity) {
  // E − e·sin E 在 E 上单调（导数 1 − e·cos E > 0），所以二分一定收敛。
  var low = meanAnomaly - 1.5;
  var high = meanAnomaly + 1.5;
  for (var iteration = 0; iteration < 200; iteration++) {
    final middle = (low + high) / 2;
    final value =
        middle - eccentricity * math.sin(middle) - meanAnomaly;
    if (value > 0) {
      high = middle;
    } else {
      low = middle;
    }
  }
  return (low + high) / 2;
}

void main() {
  group('儒略日', () {
    test('J2000.0 历元落在 2451545.0', () {
      // 表里的根数就是这个时刻的，差一天就是差 0.01 角分的平黄经。
      expect(julianDay(DateTime.utc(2000, 1, 1, 12)), closeTo(2451545.0, 1e-9));
      expect(julianCenturies(2451545.0), 0);
    });

    test('Unix 历元落在 2440587.5', () {
      expect(
        julianDay(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
        closeTo(2440587.5, 1e-9),
      );
    });

    test('传进来的时刻按 UTC 解释，本地时间不会算歪', () {
      // 同一个瞬间的两种写法必须给出同一个儒略日。少了 toUtc()，一台在东八区的
      // 手机上这张照片的行星位置就会差 8 小时的量。
      final utc = DateTime.utc(2026, 10, 15, 13, 34, 7);
      final local = utc.toLocal();
      expect(julianDay(local), closeTo(julianDay(utc), 1e-12));
    });

    test('2050 年初是 0.5 个儒略世纪', () {
      expect(julianCenturies(julianDay(DateTime.utc(2050, 1, 1, 12))),
          closeTo(0.5, 1e-4));
    });
  });

  group('日光心位置', () {
    test('圆轨道在轨道的四个方向上都落对', () {
      // e = 0 时 E = M，位置就是 a·(cos M, sin M, 0) 转到黄道系。
      final zero = heliocentricPosition(_elements(a: 2, l: 0), 0);
      expect(zero.x, closeTo(2, 1e-12));
      expect(zero.y, closeTo(0, 1e-12));
      expect(zero.z, closeTo(0, 1e-12));

      final quarter = heliocentricPosition(_elements(a: 2, l: 90), 0);
      expect(quarter.x, closeTo(0, 1e-12));
      expect(quarter.y, closeTo(2, 1e-12));

      final half = heliocentricPosition(_elements(a: 2, l: 180), 0);
      expect(half.x, closeTo(-2, 1e-12));
      expect(half.y, closeTo(0, 1e-12));
    });

    test('平黄经要减掉近日点黄经才是平近点角', () {
      // L = 0°、ϖ = 90° ⇒ M = −90°，近点角取的是负的直角，位置在 (a, 0, 0)。
      // 要是漏掉这个减法（把 L 直接当 M），M 就成了 0、位置落到 (0, a, 0)——
      // 差了整整一个直角。这一条就是冲着那个减法去的。
      final position =
          heliocentricPosition(_elements(a: 1, l: 0, perihelion: 90), 0);
      expect(position.x, closeTo(1, 1e-12));
      expect(position.y, closeTo(0, 1e-12));
      expect(position.z, closeTo(0, 1e-12));
    });

    test('轨道倾角 90° 时位置被抬到黄极方向', () {
      final polar =
          heliocentricPosition(_elements(a: 3, i: 90, l: 90), 0);
      expect(polar.x, closeTo(0, 1e-12));
      expect(polar.y, closeTo(0, 1e-12));
      expect(polar.z, closeTo(3, 1e-12));
    });

    test('升交点黄经把整个轨道绕黄极转过去', () {
      final rotated = heliocentricPosition(
        _elements(a: 1, l: 90, perihelion: 90, node: 90),
        0,
      );
      // 原本指向 +x 的单位向量绕 z 转 90° 后指向 +y。
      expect(rotated.x, closeTo(0, 1e-12));
      expect(rotated.y, closeTo(1, 1e-12));
    });

    test('近日点距离是 a(1−e)，远日点是 a(1+e)', () {
      for (final e in [0.05, 0.2, 0.5, 0.9]) {
        // 高偏心率也要过：水星 0.206 只是下限，同一段代码以后要给彗星用。
        const a = 2.0;
        final perihelion =
            heliocentricPosition(_elements(a: a, e: e, l: 0), 0);
        expect(perihelion.distance, closeTo(a * (1 - e), 1e-9),
            reason: 'e = $e 的近日点');

        final aphelion =
            heliocentricPosition(_elements(a: a, e: e, l: 180), 0);
        expect(aphelion.distance, closeTo(a * (1 + e), 1e-9),
            reason: 'e = $e 的远日点');
      }
    });

    test('偏心率大的时候开普勒方程仍然解对', () {
      // 二分法当参照物：牛顿迭代在 e 大、M 小的时候最容易冲过头，而这一片
      // 恰恰是近日点附近。半径由 E 唯一决定（r = a(1 − e·cos E)），所以用
      // 半径来比，不用比两个不同实现给出的 E。
      for (final e in [0.206, 0.5, 0.8, 0.95]) {
        for (final meanAnomaly in [0.5, 20.0, 90.0, 175.0]) {
          final expectedE = _eccentricAnomalyByBisection(
            meanAnomaly * math.pi / 180,
            e,
          );
          final expected = 2 * (1 - e * math.cos(expectedE));

          final actual = heliocentricPosition(
            _elements(a: 2, e: e, l: meanAnomaly),
            0,
          );
          expect(actual.distance, closeTo(expected, 1e-9),
              reason: 'e = $e，平近点角 $meanAnomaly°');
        }
      }
    });

    test('变率按儒略世纪线性叠加', () {
      // 一个世纪之后半长轴正好是表里的值和变率之和。
      final after = heliocentricPosition(_elements(a: 1, aRate: 0.5, l: 0), 1);
      expect(after.distance, closeTo(1.5, 1e-12));
    });

    test('走满一圈回到原处', () {
      const a = 1.5;
      final start = heliocentricPosition(_elements(a: a, l: 0), 0);
      // 平黄经每世纪走 360°，所以 T = 1 就是一个周期。
      final wrap = heliocentricPosition(_elements(a: a, l: 360), 0);
      expect(wrap.x, closeTo(start.x, 1e-12));
      expect(wrap.y, closeTo(start.y, 1e-12));
    });
  });

  group('地心赤道坐标', () {
    test('天体和地球同处一点时不会算出 NaN', () {
      final same = _elements(a: 1, l: 30);
      final position =
          geocentricPosition(same, same, DateTime.utc(2026, 10, 15));
      expect(position.distanceAu, 0);
      expect(position.ra.isNaN, isFalse);
      expect(position.dec.isNaN, isFalse);
    });

    test('黄道转赤道这一步手推得出的位置对得上', () {
      // 手推：地球 a=1、L=0 → 黄道坐标 (1,0,0)；天体 a=2、L=90 → (0,2,0)。
      // 相对位置就是 (−1, 2, 0)，长度 √5。
      // 绕 x 轴转黄赤交角 ε（cos ε = 0.91748206，sin ε = 0.39777716）后
      // 是 (−1, 2cos ε, 2sin ε) = (−1, 1.83496412, 0.79555431)。
      //
      // 赤经不要用 tan 表插值去反推——tan 在这一段弯得厉害，插出来的角度能差
      // 千分之几度，正好落在容差里外。走黄经那条路是稳的：
      //   λ = atan2(2, −1) = 116.565051°，β = 0
      //   RA = atan2(sin λ · cos ε, cos λ) = atan2(0.82062163, −0.44721360)
      //      = 180° − atan(1.83496412) = 180° − 61.4110° = 118.5890°
      // 赤纬 = asin(sin λ · sin ε) = asin(0.3557827) = 20.8413°。
      final position = geocentricPosition(
        _elements(a: 2, l: 90),
        _elements(a: 1, l: 0),
        DateTime.utc(2000, 1, 1, 12),
      );
      expect(position.ra, closeTo(118.5890, 0.001));
      expect(position.dec, closeTo(20.8413, 0.001));
      expect(position.distanceAu, closeTo(math.sqrt(5), 1e-9));
    });

    test('黄道转赤道的旋转保持长度不变', () {
      // 转动不该改变距离。这一条抓的是矩阵写错成非正交的情形——那种错在
      // 赤经赤纬上看不出来，因为反正都会被归一化掉，只有距离会跟着缩水。
      final position = geocentricPosition(
        _elements(a: 5, i: 30, l: 120),
        _elements(a: 1, l: 45),
        DateTime.utc(2026, 10, 15),
      );
      final body = heliocentricPosition(_elements(a: 5, i: 30, l: 120),
          julianCenturies(julianDay(DateTime.utc(2026, 10, 15))));
      final earth = heliocentricPosition(_elements(a: 1, l: 45),
          julianCenturies(julianDay(DateTime.utc(2026, 10, 15))));
      expect(position.distanceAu, closeTo((body - earth).distance, 1e-12));
    });

    test('赤经赤纬落在合法范围内', () {
      final position = geocentricPosition(
        _elements(a: 1.5, l: 300),
        _elements(a: 1, l: 0),
        DateTime.utc(2026, 10, 15),
      );
      expect(position.ra, inInclusiveRange(0, 360));
      expect(position.dec, inInclusiveRange(-90, 90));
    });

    test('外行星比内行星远', () {
      final moment = DateTime.utc(2026, 10, 15);
      final inner = geocentricPosition(
        _elements(a: 1.5, l: 10),
        _elements(a: 1, l: 0),
        moment,
      );
      final outer = geocentricPosition(
        _elements(a: 5.2, l: 10),
        _elements(a: 1, l: 0),
        moment,
      );
      expect(outer.distanceAu, greaterThan(inner.distanceAu));
    });
  });
}
