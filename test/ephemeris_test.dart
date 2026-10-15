import 'dart:math' as math;

import 'package:astrosophy/ephemeris.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/orbit.dart';
import 'package:flutter_test/flutter_test.dart';

/// 根数表和由它算出来的位置。
///
/// 这里的用例刻意**不拿「我印象里的行星星历」当参照物**——那样只是拿一份可能
/// 也记错了的记忆去对另一份。用的是三样不依赖任何表的东西：
///
///   * **开普勒第三定律**：T² ∝ a³。它同时约束半长轴和平黄经变率两列，而这两列
///     正是最容易抄串的；错了任何一列，行星之间的周期比立刻对不上。
///   * **分点和至点**：春分那天太阳赤纬是 0，夏至那天是黄赤交角。这是黄赤交角、
///     地球平黄经、季节对齐三件事一次过。
///   * **物理范围**：偏心率、倾角、轨道的形状，串了列的数会掉到范围外面去。

/// 从平黄经的变率反推公转周期（天）。
///
/// 平黄经每儒略世纪走 [OrbitalElements.meanLongitudeRate] 度，走满 360° 就是
/// 一个周期。这一列抄错了，周期会离谱到一眼看出来。
double _periodDays(OrbitalElements elements) =>
    360 / (elements.meanLongitudeRate / 36525);

OrbitalElements _elementsOf(String name) =>
    solarSystemBodies.firstWhere((body) => body.name == name).elements;

void main() {
  group('表本身', () {
    test('七行都在，顺序与页面一致', () {
      expect(
        solarSystemBodies.map((body) => body.name).toList(),
        ['水星', '金星', '火星', '木星', '土星', '天王星', '海王星'],
      );
    });

    test('地月质心单独放，没有混进天体列表', () {
      // 混进去的话，地心坐标会算出「地球相对地球」这个零向量，然后
      // 在报告里报出一颗位于观测者脚下的行星。
      expect(
        solarSystemBodies.map((body) => body.name),
        isNot(contains('地球')),
      );
      expect(earthMoonBarycentre.semiMajorAxis, closeTo(1.0, 0.001));
    });

    test('半长轴落在各行星该在的范围里', () {
      // 串了列的数多半会掉出这些区间：比如把倾角当半长轴，木星就成了 1.3 au，
      // 比火星还近。
      const expected = {
        '水星': (0.30, 0.47),
        '金星': (0.71, 0.74),
        '火星': (1.38, 1.67),
        '木星': (4.90, 5.50),
        '土星': (9.00, 10.10),
        '天王星': (18.20, 20.10),
        '海王星': (29.70, 30.40),
      };
      expected.forEach((name, range) {
        final a = _elementsOf(name).semiMajorAxis;
        expect(a, inInclusiveRange(range.$1, range.$2), reason: name);
      });
    });

    test('偏心率都小，且水星最大', () {
      final byName = {
        for (final body in solarSystemBodies)
          body.name: body.elements.eccentricity,
      };
      for (final entry in byName.entries) {
        // 行星都是近圆轨道；0.25 以上只有冥王星和彗星才有。
        expect(entry.value, inInclusiveRange(0.0, 0.25), reason: entry.key);
      }
      expect(
        byName['水星']!,
        byName.values.reduce(math.max),
        reason: '水星是行星里偏心率最大的那颗',
      );
    });

    test('倾角都在黄道面附近，且不超过 7.1 度', () {
      for (final body in solarSystemBodies) {
        // 黄道面是这些行星的共同平面，最大的是水星的 7.0°。倾角要是不小心
        // 抄成了平黄经（一两百度），这一条立刻炸。
        expect(
          body.elements.inclination.abs(),
          inInclusiveRange(0.0, 7.1),
          reason: body.name,
        );
      }
    });

    test('开普勒第三定律：周期比等于半长轴比的 1.5 次方', () {
      // 这一条不靠任何记忆里的数值，只用物理。它同时钉住 a 列和平黄经变率列
      // ——哪一列抄串了，比值的偏差都在百分之一以上。
      final earth = earthMoonBarycentre;
      final earthPeriod = _periodDays(earth);
      for (final body in solarSystemBodies) {
        final ratio =
            _periodDays(body.elements) / earthPeriod;
        final expected = math.pow(
          body.elements.semiMajorAxis / earth.semiMajorAxis,
          1.5,
        );
        expect(
          ratio,
          closeTo(expected.toDouble(), expected * 0.005),
          reason: '${body.name} 的周期比与半长轴比对不上',
        );
      }
    });
  });

  group('算出来的位置', () {
    test('太阳在 1 个天文单位附近', () {
      // 地心到太阳的距离在 0.983–1.017 au 之间抖动（地球轨道的偏心率）。
      for (final month in [1, 4, 7, 10]) {
        final sun = sunPosition(DateTime.utc(2026, month, 15));
        expect(sun.distanceAu, inInclusiveRange(0.980, 1.020),
            reason: '$month 月的日地距离');
      }
    });

    test('春分那天太阳赤纬是 0，夏至那天是黄赤交角', () {
      // 分点和至点是定义，不是数据：春分就是太阳赤纬由负转正的那一刻。
      final march = sunPosition(DateTime.utc(2026, 3, 20, 12));
      expect(march.dec.abs(), lessThan(0.5), reason: '3 月 20 日春分');

      final june = sunPosition(DateTime.utc(2026, 6, 20, 12));
      expect(june.dec, closeTo(23.4392911, 0.5), reason: '6 月 20 日接近夏至');

      final september = sunPosition(DateTime.utc(2026, 9, 23));
      expect(september.dec.abs(), lessThan(0.5), reason: '9 月 23 日秋分');
    });

    test('春分那天太阳赤经也接近 0', () {
      // 赤纬对不上的话，上面那条能抓到；赤经对不上只有这条能抓到——它另外
      // 钉住的是「平黄经减近日点黄经」那一步和升交点那一步。
      final march = sunPosition(DateTime.utc(2026, 3, 20, 12));
      final offBy = march.ra > 180 ? 360 - march.ra : march.ra;
      expect(offBy, lessThan(1.0), reason: '赤经应当落在春分点附近');
    });

    test('行星的地心距离都在合理区间里', () {
      final moment = DateTime.utc(2026, 10, 15);
      final distances = {
        for (final body in predictedBodies(moment)) body.name: body.distanceAu!,
      };
      // 内行星不会跑到 0.25 au 以内，也不会远过 2 au；外行星的下限由它的
      // 半长轴减 1 定。
      expect(distances['水星'], inInclusiveRange(0.5, 1.5));
      expect(distances['金星'], inInclusiveRange(0.25, 1.75));
      expect(distances['火星'], inInclusiveRange(0.35, 2.7));
      expect(distances['木星'], inInclusiveRange(3.9, 6.5));
      expect(distances['土星'], inInclusiveRange(7.9, 11.2));
      expect(distances['海王星'], inInclusiveRange(28.5, 31.5));
    });

    test('越远的行星离得越远，顺序不会乱', () {
      final distances = {
        for (final body in predictedBodies(DateTime.utc(2026, 10, 15)))
          body.name: body.distanceAu!,
      };
      expect(distances['木星']!, greaterThan(distances['火星']!));
      expect(distances['土星']!, greaterThan(distances['木星']!));
      expect(distances['天王星']!, greaterThan(distances['土星']!));
      expect(distances['海王星']!, greaterThan(distances['天王星']!));
    });

    test('赤经赤纬都在合法范围内', () {
      for (final body in predictedBodies(DateTime.utc(2026, 10, 15))) {
        expect(body.ra, inInclusiveRange(0, 360), reason: body.name);
        expect(body.dec, inInclusiveRange(-90, 90), reason: body.name);
      }
    });

    test('位置随日期真的会挪——变率那一行生效了', () {
      // 少了变率那一行，行星位置就钉死在 J2000 上，2026 年的照片会用 2000 年
      // 的位置去对，偏出几十度。木星 26.8 年走 2.26 圈，落在离 2000 年出发点
      // 90° 上下的地方——所以这里断的是「挪了一大截」，不是「挪了一点点」。
      final atEpoch = predictedBodies(DateTime.utc(2000, 1, 1, 12))
          .firstWhere((body) => body.name == '木星');
      final later = predictedBodies(DateTime.utc(2026, 10, 15))
          .firstWhere((body) => body.name == '木星');
      expect(
        angularSeparationDegrees(
          atEpoch.ra,
          atEpoch.dec,
          later.ra,
          later.dec,
        ),
        greaterThan(45),
      );
    });
  });
}
