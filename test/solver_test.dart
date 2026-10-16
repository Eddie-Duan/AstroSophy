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

    test('昴星团的亮成员都有中文星官名', () {
      // 昴星团是全天空最容易认出来的目标之一，用户拍完一张 M 45，屏幕上却
      // 只有一颗星有名字（从前就只收了 η Tau 一颗），比一颗都没有还费解。
      //
      // 编号按传统排法，**不按弗兰斯蒂德编号从小到大**：昴宿三落在 21 Tau、
      // 昴宿四落在 20 Tau。这条「倒着走」是传统排法的原样，照编号顺序顺手
      // "修正"过来，就把两颗星的名字对调了——所以这里逐颗钉死。
      const expected = {
        17499: ('Electra', '昴宿一'),
        17531: ('Taygeta', '昴宿二'),
        17579: ('Asterope', '昴宿三'),
        17573: ('Maia', '昴宿四'),
        17608: ('Merope', '昴宿五'),
        17702: ('Alcyone', '昴宿六'),
        17847: ('Atlas', '昴宿七'),
        17489: ('Celaeno', '昴宿增九'),
        17851: ('Pleione', '昴宿增十二'),
      };
      expected.forEach((hip, want) {
        final star = catalog.byHip[hip];
        expect(star, isNotNull, reason: 'HIP $hip 应该在星表里');
        final name = catalog.nameOf(star!);
        expect(name?.chinese, want.$2, reason: 'HIP $hip 的中文名');
        expect(name?.english, want.$1, reason: 'HIP $hip 的西名');
      });
      // 18 Tau 只有星官名，没有通行的西名。西名留空，不编一个出来。
      final unnamed = catalog.nameOf(catalog.byHip[17527]!);
      expect(unnamed?.chinese, '昴宿增八');
      expect(unnamed?.english, isNull);
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

      // 星座给的是给人看的中文名，不是 IAU 缩写——「你拍到了猎户座」
      // 比「Ori」有用。
      expect(result.constellations, contains('猎户座'));
      expect(result.matchedCount, greaterThanOrEqualTo(15));
    });

    test('解不出来时把过程记下来，好解释差在哪', () {
      // 只用主星表：中间层和最深层的索引建一次要几十秒，这条测的是「记录
      // 有没有填」，不是判据本身。
      final shallowOnly = PlateSolver(loadTestCatalog(withGaia: false));
      // 星点位置打散成噪声：图上根本凑不出正确的三角形，必然解不出来。
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
        positionJitter: 60,
        randomSeed: 20261016,
      );

      expect(shallowOnly.solve(analysis), isNull,
          reason: '位置打散成噪声之后不该还能对上');

      final trace = shallowOnly.lastTrace;
      expect(trace, isNotNull);
      final layer = trace!.layers.single;
      expect(layer.label, '浅层');
      // 星数要如实报——资产读坏了就是靠这个数看出来的。
      expect(layer.starCount, greaterThan(40000));
      expect(layer.rungsTried, greaterThan(0));
      expect(trace.bestRequired, greaterThan(0), reason: '应该真的验证过候选');
      expect(trace.bestInliers, lessThan(trace.bestRequired));
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

    test('窄视场（智能望远镜级）也能本机解算', () {
      // 银河北极：全天星最少的方向之一。1.9° 的对角线视场里，把 G<11 那一层
      // 算上也只有二十几颗目录星，其中亮过 G<9 的只有个位数——浅层和中间层
      // 都锚不住它。但这正是智能望远镜（Seestar S50 对角线 1.45°、S30 2.44°）
      // 的视场，而这些机器拍的照片恰恰最不该被送去在线解算。
      //
      // 这里要的**不是**「凑不出解就返回 null」，而是「凑出来的必须是对的」：
      // 旧版用「视场 ≥ 3°」和「内点 ≥ 10」两条常数把这类图一律挡在门外，
      // 结果是七颗检出星全部都对上了目录星，却照样回退在线。
      //
      // 门槛从 15 放到 30：星表从 G<9 加深到 G<11 之后，同一片天区里的目录星
      // 自然变多（15 → 23）。这个数守的仍然是「这是一片稀天区」，不是某个
      // 具体的数——真正要紧的断言是下面那几条。
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: 192.86,
        centerDec: 27.13,
        degreesPerPixel: 0.0015,
      );
      expect(analysis.stars.length, lessThan(30));
      final result = solver.solve(analysis);
      expect(result, isNotNull, reason: '窄视场里有目录星就该解出来');
      expect(result!.source, SolveSource.local);
      final centreError = angularSeparationDegrees(
        result.centerRa,
        result.centerDec,
        192.86,
        27.13,
      );
      expect(centreError, lessThan(0.01),
          reason: '解出的中心偏离真值 $centreError°——宁可返回 null 也不能给错坐标');
      // 0.0015 度/像素 = 5.4 角秒/像素。
      expect(result.arcsecPerPixel, closeTo(5.4, 0.2));
      final agreement = wcsAgreement(analysis, result.wcs!, catalog);
      expect(agreement, greaterThan(0.9),
          reason: '只有 ${(agreement * 100).toStringAsFixed(0)}% 的星点落回目录星');
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

    test('窄视场里的噪声同样不会被解成星座', () {
      // 窄视场放宽了两条常数：视场下限从 3° 降到 1°，内点门槛也从固定十颗
      // 改成按这张图的概率算（视场稀、像面大时可以降到六颗）。这正是假解
      // 最可能钻进来的缝——所以要单独盯住它。
      //
      // 门槛之所以敢放宽，是因为「图内星点撞上目录星」的概率随像面面积
      // 下降：1.9° 视场里目录星只有十几颗，四千次候选里凑出三个额外内点的
      // 期望不到万分之一。这条用例就是把这个结论钉死。
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: 192.86,
        centerDec: 27.13,
        degreesPerPixel: 0.0015,
      );
      final random = math.Random(90210);
      final garbage = analysis.copyWith(
        stars: List.generate(
          60,
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
      expect(solver.solve(garbage), isNull);
    });
  });

  group('星座连线叠加', () {
    test('本机解算带回的连线全部裁在图像范围内', () {
      final analysis = synthesiseField(
        catalog: catalog,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
      );
      final result = solver.solve(analysis);
      expect(result, isNotNull);

      final figures = result!.constellationFigures;
      expect(figures, isNotEmpty, reason: '猎户座这片天区必须画出连线来');
      expect(
        figures.map((figure) => figure.name),
        contains('猎户座'),
        reason: '指标条上写着猎户座，图上就得能找到猎户座',
      );

      for (final figure in figures) {
        expect(figure.segments, isNotEmpty);
        for (final segment in figure.segments) {
          expect(segment, hasLength(4));
          for (final value in segment) {
            expect(value.isFinite, isTrue, reason: '${figure.name} 的端点不是有限数');
          }
          // 裁剪的容差按浮点给一个极小的余量：算 t 的时候会有一两次
          // 舍入，端点可能落在框外半个 1e-13。
          for (final x in [segment[0], segment[2]]) {
            expect(x, inInclusiveRange(-1e-6, analysis.width + 1e-6),
                reason: '${figure.name} 的线段画到图像外了');
          }
          for (final y in [segment[1], segment[3]]) {
            expect(y, inInclusiveRange(-1e-6, analysis.height + 1e-6),
                reason: '${figure.name} 的线段画到图像外了');
          }
        }
        // 名字是各段中点的均值，各段都在框内，它自然也在。
        expect(figure.labelX, inInclusiveRange(0, analysis.width.toDouble()));
        expect(figure.labelY, inInclusiveRange(0, analysis.height.toDouble()));
      }
    });

    test('在线解算的结果也能补出星座名与连线', () {
      final wcs = Wcs.fromPixels(
        width: 1024,
        height: 768,
        centerRa: _orionRa,
        centerDec: _orionDec,
        degreesPerPixel: 0.008,
      );
      // 在线路径拿回来的东西只有 WCS 和坐标，星座一定是空的——视场窄的
      // 望远镜照片多半解不出来、正好都走这条路。
      final online = SolveResult(
        centerRa: wcs.imageCenter.$1,
        centerDec: wcs.imageCenter.$2,
        arcsecPerPixel: wcs.arcsecPerPixel,
        namedStars: const [],
        deepSkyObjects: const [],
        matchedStars: const [],
        magnitudeZeroPoint: null,
        magnitudeScatter: null,
        catalogWarning: null,
        fieldOfViewDegrees: wcs.fieldOfViewDegrees,
        wcs: wcs,
      );
      expect(online.constellations, isEmpty);
      expect(online.constellationFigures, isEmpty);

      final decorated = solver.decorateSolve(online);
      expect(decorated.constellations, contains('猎户座'));
      expect(decorated.constellationFigures, isNotEmpty);

      // 补的只是星座，解算本身的结果一个字段都不能动。
      expect(decorated.centerRa, online.centerRa);
      expect(decorated.centerDec, online.centerDec);
      expect(decorated.arcsecPerPixel, online.arcsecPerPixel);
      expect(decorated.source, SolveSource.online);
      expect(decorated.fieldOfViewDegrees, online.fieldOfViewDegrees);
      expect(decorated.wcs, same(wcs));
    });

    test('没有 WCS 就无从投影，原样返回', () {
      expect(solver.decorateSolve(SolveResult.empty), same(SolveResult.empty));
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
