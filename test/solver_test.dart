import 'dart:math' as math;

import 'package:astrosophy/catalog.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// 猎户座腰带附近。选它是因为这片天区亮星密集，是天文摄影最常拍的
/// 目标之一，也是「本地解算到底行不行」最有说服力的考场。
const _orionRa = 83.8;
const _orionDec = -1.5;

void main() {

  // 星表读一次就够，整个文件共用。
  late StarCatalog catalog;
  // 索引构建要一秒上下，多个用例共用同一个解算器，避免每个用例都重建。
  late PlateSolver solver;

  setUpAll(() {
    catalog = loadTestCatalog();
    solver = PlateSolver(catalog);
  });

  group('StarCatalog 数据资产', () {
    test('载入了整张 Hipparcos 亮星表', () {
      expect(catalog.stars.length, greaterThan(40000));
      expect(catalog.magnitudeLimit, closeTo(8.0, 0.1));
      // 星表按星等排好序，解算器直接取前缀当「最亮的 N 颗」。
      for (var i = 1; i < catalog.stars.length; i++) {
        expect(
          catalog.stars[i].vMagnitude,
          greaterThanOrEqualTo(catalog.stars[i - 1].vMagnitude),
        );
      }
    });

    test('几颗著名亮星的星名和星座都对得上', () {
      const expected = {
        32349: ('天狼星', 'CMa'),
        91262: ('织女星', 'Lyr'),
        11767: ('北极星', 'UMi'),
        27989: ('参宿四', 'Ori'),
        24436: ('参宿七', 'Ori'),
        69673: ('大角星', 'Boo'),
        24608: ('五车二', 'Aur'),
        30438: ('老人星', 'Car'),
        97649: ('河鼓二', 'Aql'),
        65474: ('角宿一', 'Vir'),
        21421: ('毕宿五', 'Tau'),
        80763: ('心宿二', 'Sco'),
        113368: ('北落师门', 'PsA'),
        102098: ('天津四', 'Cyg'),
      };
      expected.forEach((hip, want) {
        final star = catalog.byHip[hip];
        expect(star, isNotNull, reason: 'HIP $hip 应该在星表里');
        final name = catalog.nameOf(star!);
        expect(name?.chinese, want.$1, reason: 'HIP $hip 的中文名');
        expect(
          catalog.constellationOf(star)?.abbreviation,
          want.$2,
          reason: 'HIP $hip 的星座',
        );
      });
    });

    test('天区归属能回答「这张照片拍的是哪个星座」', () {
      expect(catalog.constellationAt(_orionRa, _orionDec)?.abbreviation, 'Ori');
      expect(catalog.constellationAt(201.3, -11.2)?.abbreviation, 'Vir');
      expect(catalog.constellationAt(37.95, 89.26)?.abbreviation, 'UMi');
      // 南天极在 Octans（南极座）里，这一格最容易出错：整个南天极天区
      // 都落在同一条赤经分桶里，边界表取错一行就会全错。
      expect(catalog.constellationAt(0, -89.9)?.abbreviation, 'Oct');
      expect(catalog.constellationAt(200, -85)?.abbreviation, 'Oct');
    });

    test('nearestStars 按角距排序，而不是按星等', () {
      final near = catalog.nearestStars(_orionRa, _orionDec, 6);
      expect(near.length, 6);
      // 每颗都必须比前一颗离中心更远——这正是「最亮邻居」做不到的事。
      var previous = 0.0;
      for (final star in near) {
        final distance =
            angularSeparationDegrees(_orionRa, _orionDec, star.ra, star.dec);
        expect(distance, greaterThanOrEqualTo(previous - 1e-9));
        previous = distance;
      }
      // 猎户座腰带周围 3° 内必然不止 6 颗亮星，所以最近邻应该都很近。
      expect(previous, lessThan(2.5));
    });
  });

  group('PlateSolver 本机解算', () {
    test('解出猎户座天区的中心坐标与像素尺度', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
      );
      expect(analysis.stars.length, greaterThan(20),
          reason: '10° 视场里应该有二三十颗以上目录星');

      final result = solver.solve(analysis);
      expect(result, isNotNull, reason: '理想星图必须能解出来');
      expect(result!.source, SolveSource.local);

      final centreError = angularSeparationDegrees(
        result.centerRa,
        result.centerDec,
        _orionRa,
        _orionDec,
      );
      expect(centreError, lessThan(0.05), reason: '解出的中心偏离真值 $centreError°');

      // 0.008 度/像素 = 28.8 角秒/像素。
      expect(result.arcsecPerPixel, closeTo(28.8, 0.6));

      // 比中心更强的一条断言：每个检出星点都要能还原到目录星上。
      final agreement = wcsAgreement(analysis, result.wcs!, catalog);
      expect(agreement, greaterThan(0.9),
          reason: '只有 ${(agreement * 100).toStringAsFixed(0)}% 的星点落回目录星');

      expect(result.constellations, contains('Ori'));
      expect(result.matchedCount, greaterThanOrEqualTo(15));
    });

    test('旋转过的星图同样能解算', () {
      for (final rotation in [0.35, 0.9, -1.4]) {
        final analysis = synthesiseField(
          catalog: catalog,
          centerRa: _orionRa,
          centerDec: _orionDec,
          degreesPerPixel: 0.008,
          rotationRadians: rotation,
        );
        final result = solver.solve(analysis);
        expect(result, isNotNull, reason: '旋转 ${rotation}rad 时解算失败');

        final centreError = angularSeparationDegrees(
          result!.centerRa,
          result.centerDec,
          _orionRa,
          _orionDec,
        );
        expect(centreError, lessThan(0.05));
        expect(wcsAgreement(analysis, result.wcs!, catalog), greaterThan(0.9));
        // 天球北方向相对图像正上方的夹角，应该和构造时给的角度一致。
        // 约定：正角度表示天球北在图像上偏向右侧（照片被逆时针转过）。
        final recovered = _rotationOf(result.wcs!);
        final want = rotation * 180 / math.pi;
        expect(
          _angleDifference(recovered, want),
          lessThan(0.5),
          reason: '旋转角 $recovered° 与真值 $want° 不符',
        );
      }
    });

    test('左右翻转的星图同样能解算', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
        mirrored: true,
      );
      final result = solver.solve(analysis);
      expect(result, isNotNull, reason: '镜像光路应该靠翻转假设兜住');

      final centreError = angularSeparationDegrees(
        result!.centerRa,
        result.centerDec,
        _orionRa,
        _orionDec,
      );
      expect(centreError, lessThan(0.05));
      expect(wcsAgreement(analysis, result.wcs!, catalog), greaterThan(0.9));
      // 镜像的 CD 矩阵行列式为负。
      expect(result.wcs!.determinant, lessThan(0));
    });

    test('换个天区、换个尺度也能解', () {
      for (final field in [
        // 仙后座，北天、赤纬高，分桶在赤经方向被压得很窄。
        (_cassiopeiaRa, _cassiopeiaDec, 0.006),
        // 南十字附近，南天。
        (187.0, -61.0, 0.010),
        // 春季大三角（狮子—牧夫—室女一带），亮星稀疏。
        (190.0, 10.0, 0.007),
      ]) {
        final analysis = synthesiseField(
          catalog: catalog,
          centerRa: field.$1,
          centerDec: field.$2,
          degreesPerPixel: field.$3,
        );
        final result = solver.solve(analysis);
        expect(result, isNotNull,
            reason: '(${field.$1}, ${field.$2}) 这个天区解算失败');
        final centreError = angularSeparationDegrees(
          result!.centerRa,
          result.centerDec,
          field.$1,
          field.$2,
        );
        expect(centreError, lessThan(0.05));
        expect(wcsAgreement(analysis, result.wcs!, catalog), greaterThan(0.85));
      }
    });

    test('排除拉长的检出，不让飞机线带偏解算', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
      );
      // 混进几条「飞机线」：通量很高，但长宽比大到会被判成拉长候选。
      final withStreaks = analysis.copyWith(
        stars: [
          ...analysis.stars,
          ...List.generate(
            6,
            (index) => DetectedStar(
              80.0 + index * 140,
              40.0 + index * 110,
              9e9,
              3.0,
              0.9,
              4.5,
              fwhm: 3,
            ),
          ),
        ],
      );
      final result = solver.solve(withStreaks);
      expect(result, isNotNull);
      final centreError = angularSeparationDegrees(
        result!.centerRa,
        result.centerDec,
        _orionRa,
        _orionDec,
      );
      expect(centreError, lessThan(0.05));
    });

    test('星点不足时直接放弃，交给在线解算', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
      );
      final tooFew = analysis.copyWith(
        stars: analysis.stars.take(3).toList(),
      );
      expect(solver.solve(tooFew), isNull);
    });

    test('视场窄到目录星不够时不硬凑结果', () {
      // 1.5° 视场：目录只到 V=8.0，这片天区里凑不出可以互相验证的三角形。
      // 这里必须老老实实返回 null 让上层回退在线解算，而不是给一个
      // 看起来像模像样、实际上错得离谱的坐标。
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.0015,
      );
      expect(analysis.stars.length, lessThan(15));
      expect(solver.solve(analysis), isNull);
    });

    test('随机噪声点不会被解成星座', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
      );
      final random = math.Random(4242);
      final garbage = analysis.copyWith(
        stars: List.generate(
          120,
          (index) => DetectedStar(
            random.nextDouble() * 1024,
            random.nextDouble() * 768,
            1000 - index.toDouble(),
            5.0,
            0.9,
            1.0,
          ),
        ),
      );
      // 误检一个「解」比解不出来糟糕得多：用户会拿到一张标满错误星名的图。
      expect(solver.solve(garbage), isNull);
    });
  });
}

const _cassiopeiaRa = 12.0;
const _cassiopeiaDec = 60.0;

/// 解出来的 WCS 对应的图像旋转角（度），与 [PlateSolver] 内部口径一致。
double _rotationOf(Wcs wcs) {
  final (northX, northY) = wcs.northDirectionAt(wcs.width / 2, wcs.height / 2);
  return math.atan2(northX, -northY) * 180 / math.pi;
}

/// 两个角度之间的最小差值（度），处理 ±360 的绕圈。
double _angleDifference(double first, double second) {
  var difference = (first - second) % 360;
  if (difference > 180) difference -= 360;
  if (difference < -180) difference += 360;
  return difference.abs();
}
