import 'dart:io';
import 'dart:math' as math;

import 'package:astrosophy/ephemeris.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/orbit.dart';
import 'package:astrosophy/smallbodies.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内置太阳系小天体目录：内容、位置精度、亮度律、以及「先按亮度筛」这一步。
///
/// 期望值全部来自 **JPL Horizons**，不是从本实现里导出来再喂回去——那样只能
/// 证明代码没变，证明不了它是对的。取的是 2026-01-01T00:00:00Z（儒略日
/// 2461041.5）那一刻的地心赤经赤纬和视星等。
///
/// 容差按实测留了三倍余量：两体近似在这批天体上的真实误差是角秒到 0.3 角分
/// （见 `lib/smallbodies.dart` 的类注释），亮度好于 0.05 等。
void main() {
  late SmallBodyCatalog catalog;

  setUpAll(() {
    catalog = SmallBodyCatalog.parse(
      File('assets/catalog/smallbodies.json').readAsStringSync(),
    );
  });

  final moment = DateTime.utc(2026, 1, 1);

  /// 和 Horizons 的角距，角分。
  double separation(
    EquatorialPosition position,
    double raDegrees,
    double decDegrees,
  ) =>
      angularSeparationDegrees(position.ra, position.dec, raDegrees, decDegrees) *
      60;

  group('目录内容', () {
    test('十六颗亮小行星、十颗矮行星、全部彗星', () {
      expect(
        catalog.components.where((body) => body.kind == BodyKind.asteroid),
        hasLength(16),
      );
      expect(
        catalog.components.where((body) => body.kind == BodyKind.dwarfPlanet),
        hasLength(10),
      );
      expect(catalog.comets, hasLength(939));
      // 构建日期必须跟着数据一起来：内置表会过时，而「表是哪天建的」正是判断
      // 位置还能不能用的唯一依据。
      expect(catalog.built, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('灶神星、共工星这些按中文名、编号和正式全名都查得到', () {
      expect(catalog.find('灶神星')?.designation, startsWith('4 Vesta'));
      expect(catalog.find('Vesta')?.name, '灶神星');
      expect(catalog.find('  共工星 ')?.kind, BodyKind.dwarfPlanet);
      // 冥王星是矮行星，不是小行星——分类错了报告里那句话说反。
      expect(catalog.find('冥王星')?.kind, BodyKind.dwarfPlanet);
      expect(catalog.find('不存在的天体'), isNull);
    });

    test('彗星全收，认得出偏心率大于 1 的那些', () {
      final hyperbolic =
          catalog.comets.where((body) => body.eccentricity! >= 1.0);
      expect(hyperbolic, isNotEmpty, reason: '近抛物线那一支得有样本');
      // e > 1.05 的那一颗（1I/'Oumuamua）需要真双曲解法，构建时就滤掉了。
      expect(
        catalog.comets.where((body) => body.eccentricity! > 1.05),
        isEmpty,
      );
    });
  });

  group('位置和亮度对 JPL Horizons', () {
    // Horizons 的地心赤道坐标与视星等。Ceres 取两个日期是因为它的相位角在
    // 这两天分别是 +23.0° 和 −24.0°——相位函数那一项在这两天各值 1.3 等上下，
    // 少了它两天都会偏一大截；两天都对上，才算证明这一项真的在算。
    final references = <({String designation, DateTime moment, double ra, double dec, double magnitude})>[
      (
        designation: '4 Vesta',
        moment: DateTime.utc(2026, 1, 1),
        ra: 296.074375,
        dec: -22.709722,
        magnitude: 7.830,
      ),
      (
        designation: '1 Ceres',
        moment: DateTime.utc(2026, 1, 1),
        ra: 9.675792,
        dec: -5.499667,
        magnitude: 8.893,
      ),
      (
        designation: '1 Ceres',
        moment: DateTime.utc(2026, 10, 1),
        ra: 107.137583,
        dec: 23.214167,
        magnitude: 8.669,
      ),
      (
        designation: '225088',
        moment: DateTime.utc(2026, 1, 1),
        ra: 337.068708,
        dec: -10.489639,
        magnitude: 21.463,
      ),
    ];

    for (final reference in references) {
      final day = reference.moment.toIso8601String().substring(0, 10);
      test('${reference.designation} 在 $day 的位置和亮度都对得上', () {
        final body = catalog.all.firstWhere(
          (item) => item.designation.startsWith(reference.designation),
        );
        final position = positionOf(body, reference.moment)!;
        expect(
          separation(position, reference.ra, reference.dec),
          lessThan(0.6),
          reason: '${body.name} 的两体位置偏出去了',
        );
        expect(
          magnitudeOf(body, reference.moment)!,
          closeTo(reference.magnitude, 0.2),
          reason: '${body.name} 的 H/G 相位律对不上 Horizons 的总星等',
        );
      });
    }

    test('彗星近抛物线那一支（Barker 方程）也对得上', () {
      // C/2013 A1 的 e = 1.000074，走的是 Barker 而不是开普勒。
      final comet = catalog.comets.firstWhere(
        (body) => body.designation.startsWith('C/2013 A1'),
      );
      expect(comet.eccentricity, greaterThan(1.0));
      final position = positionOf(comet, moment)!;
      expect(separation(position, 147.233333, 33.324778), lessThan(1.0));
    });

    test('地球位置那一行的 L/ϖ 换算没写错', () {
      // 地球位置是所有行星、小行星、彗星位置共同的减数，它错了全场一起错。
      // 星历表给的是平黄经 L 与近日点黄经 ϖ，要换成 M = L − ϖ、ω = ϖ − Ω；
      // 直接当平近点角用，灶神星会偏出几百角分。
      final vesta = catalog.find('灶神星')!;
      final heliocentric = heliocentricPositionOf(vesta, julianDay(moment))!;
      // 灶神星的日心距约 2.3–2.6 AU，地心距 1.4–3.8 AU。换错参考点的话这个
      // 半径会跑到离谱的地方去。
      expect(heliocentric.distance, inInclusiveRange(2.0, 2.7));
      expect(positionOf(vesta, moment)!.distanceAu, inInclusiveRange(1.0, 4.0));
    });
  });

  group('亮度律', () {
    test('喂给 H/G 律的两个距离是日心距和地心距，不是别的', () {
      // 逐字按定义式算一遍，钉住「哪个是 r、哪个是 Δ」：两者互换在数值上
      // 看不出来（都在 1–8 AU 之间），但物理上是错的。
      final ceres = catalog.find('谷神星')!;
      final sunDistance =
          heliocentricPositionOf(ceres, julianDay(moment))!.distance;
      final earthDistance = positionOf(ceres, moment)!.distanceAu;
      final phaseFunction = 0.88 *
              math.exp(-3.33 * math.pow(math.tan(22.98 * math.pi / 360), 0.63)) +
          0.12 * math.exp(-1.87 * math.pow(math.tan(22.98 * math.pi / 360), 1.22));
      // 相位角按 Horizons 给的那一天的实际值 22.98°。
      final expected = ceres.absoluteMagnitude! +
          5 * (math.log(sunDistance * earthDistance) / math.ln10) -
          2.5 * (math.log(phaseFunction) / math.ln10);
      expect(
        magnitudeOf(ceres, moment)!,
        closeTo(expected, 0.15),
        reason: 'r、Δ 或者 G 没接对',
      );
    });

    test('彗星用 M1/k1 律，而不是 H/G', () {
      final comet = catalog.comets.firstWhere(
        (body) => body.designation.startsWith('2P'),
      );
      final t = DateTime.utc(2027, 2, 10);
      final magnitude = magnitudeOf(comet, t)!;
      // 恩克彗星过近日点时 r = q = 0.3386 AU，这是它最亮的时候。
      expect(magnitude, inInclusiveRange(6.0, 12.0));
      // 半年之后退到 3 AU 以外，必然暗下去一大截。
      final later = magnitudeOf(comet, DateTime.utc(2027, 8, 10))!;
      expect(later - magnitude, greaterThan(4.0));
    });

    test('k1 是缺省值的彗星，亮度标成「不可靠」', () {
      final defaulted = catalog.comets.where((body) => body.magnitudeIsDefault);
      // 实测 939 颗里 753 颗的 k1 是 MPC 填的缺省值 4.0。
      expect(defaulted.length, greaterThan(700));
      expect(defaulted.first.magnitudeIsReliable, isFalse);
      expect(catalog.find('灶神星')!.magnitudeIsReliable, isTrue);
    });

    test('拍不到的矮行星，亮度算出来就该是拍不到的数', () {
      // 共工星 21 等。收它进来正是为了说得出「它在这儿但拍不到」。
      expect(
        magnitudeOf(catalog.find('共工星')!, moment)!,
        greaterThan(smallBodyPhotoLimitMagnitude),
      );
      // 反过来，灶神星得在够得着的范围里——内置目录要是只剩拍不到的，
      // 这一整条判据就白做了。
      expect(
        magnitudeOf(catalog.find('灶神星')!, moment)!,
        lessThan(smallBodyPhotoLimitMagnitude),
      );
    });
  });

  group('先按亮度筛，再比位置', () {
    test('筛完之后只剩几十个，不是九百多个', () {
      final visible = catalog.visibleBodies(
        moment,
        sunRa: sunPosition(moment).ra,
        sunDec: sunPosition(moment).dec,
      );
      expect(visible.length, lessThan(200));
      expect(visible.length, greaterThan(5));
      // 8 角分容差下随机吻合的期望个数——这个数就是「要不要先筛」的全部理由。
      final expectedFalseMatches =
          visible.length * math.pi * 64 / 41253;
      expect(expectedFalseMatches, lessThan(1.0));
    });

    test('够暗的一律筛掉', () {
      final visible = catalog.visibleBodies(
        moment,
        sunRa: sunPosition(moment).ra,
        sunDec: sunPosition(moment).dec,
      );
      for (final body in visible) {
        expect(body.magnitude, lessThanOrEqualTo(smallBodyMagnitudeLimit));
        // 行星不从这份目录来（走的是 `ephemeris.dart` 那张近似根数表），
        // 所以这里一个小行星、彗星、矮行星之外的东西都不该有。谷神星既在
        // 目录里、又亮到 9 等，它是唯一一个会以矮行星身份进工作集的。
        expect(body.kind, isNot(BodyKind.planet));
      }
      expect(visible.where((body) => body.name == '谷神星'), hasLength(1));
    });

    test('离太阳太近的筛掉：白天和暮光里的天体照片上拍不到', () {
      // 把「太阳」放在某一颗天体的正上方当参照，它就该被大距那一关挡掉。
      final vesta = catalog.find('灶神星')!;
      final position = positionOf(vesta, moment)!;
      final visible = catalog.visibleBodies(
        moment,
        sunRa: position.ra,
        sunDec: position.dec,
      );
      expect(
        visible.where((body) => body.name == '灶神星'),
        isEmpty,
      );
      // 换成太阳在对面，它就该回来——说明挡掉它的是大距，不是别的。
      final opposite = catalog.visibleBodies(
        moment,
        sunRa: (position.ra + 180) % 360,
        sunDec: -position.dec,
      );
      expect(opposite.where((body) => body.name == '灶神星'), hasLength(1));
    });

    test('小天体带着自己的容差，行星那套 8 角分不套在它头上', () {
      final visible = catalog.visibleBodies(
        moment,
        sunRa: sunPosition(moment).ra,
        sunDec: sunPosition(moment).dec,
      );
      for (final body in visible) {
        expect(
          body.toleranceArcmin,
          body.kind == BodyKind.comet
              ? cometToleranceArcmin
              : smallBodyToleranceArcmin,
        );
      }
    });
  });

  group('抛物线轨道', () {
    test('r·(1 + cos ν) = 2q——抛物线的定义式，Barker 解得满足它', () {
      for (final q in const [0.1, 0.39, 1.5]) {
        for (final days in const [-200.0, -1.0, 0.0, 1.0, 60.0, 365.0]) {
          final state = parabolicState(
            perihelionDistanceAu: q,
            daysFromPerihelion: days,
          );
          final nu = state.trueAnomalyDegrees * math.pi / 180;
          expect(
            state.distanceAu * (1 + math.cos(nu)),
            closeTo(2 * q, 2 * q * 1e-9),
          );
        }
      }
    });

    test('近日点当天 r = q，而且走得比椭圆快', () {
      final atPerihelion = parabolicState(
        perihelionDistanceAu: 0.4,
        daysFromPerihelion: 0,
      );
      expect(atPerihelion.distanceAu, closeTo(0.4, 1e-12));
      expect(atPerihelion.trueAnomalyDegrees, closeTo(0, 1e-9));

      // 同样 0.4 AU 的近日点距离下，抛物线在 t 时刻的真近点角必须大于
      // e = 0.9 的椭圆——抛物线是最「快」的那条临界轨道。
      final parabola = parabolicState(
        perihelionDistanceAu: 0.4,
        daysFromPerihelion: 20,
      );
      final semiMajorAxis = 0.4 / (1 - 0.9);
      final motion = 0.9856076686 / math.pow(semiMajorAxis, 1.5);
      final ellipse = trueAnomalyFromMeanAnomalyDegrees(motion * 20, 0.9);
      expect(
        parabola.trueAnomalyDegrees,
        greaterThan(ellipse),
        reason: '抛物线是 e → 1 的极限，不该比 e = 0.9 的椭圆还慢',
      );
    });
  });
}
