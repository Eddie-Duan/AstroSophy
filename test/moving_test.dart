import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/moving.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「这个亮点是不是行星」这条判据。
///
/// 星历那半截（根数、开普勒方程）在 `orbit_test.dart` 和 `ephemeris_test.dart`
/// 里验。这里只造位置，不造根数——把两件事分开，抄错一个根数和写错一个匹配
/// 半径才不会表现成同一种失败。

const double _scaleArcsec = 10.68;
const double _centerRa = 10.6847;
const double _centerDec = 41.2691;

Wcs _wcs() => Wcs.fromPixels(
      width: 1200,
      height: 800,
      centerRa: _centerRa,
      centerDec: _centerDec,
      degreesPerPixel: _scaleArcsec / 3600,
    );

/// 造一个「落在中心偏移 (dx, dy) 像素处」的星历预测。
///
/// 走的是 WCS 自己的反投影，和被测代码的正投影互逆——所以下面断言的两点间距
/// 是有意义的：真要是投影两头对不上，间距就不会是那个像素数。
PredictedBody _predictionAt(
  Wcs wcs,
  double dx,
  double dy, {
  String name = '木星',
  double distanceAu = 4.2,
}) {
  final (ra, dec) = wcs.pixelToWorld(wcs.crpix1 + dx, wcs.crpix2 + dy);
  return PredictedBody(
    name: name,
    ra: ra,
    dec: dec,
    distanceAu: distanceAu,
  );
}

/// 中心偏移 (dx, dy) 像素处的一个检出。
///
/// 轴比给 1.1：`compactSources` 会把轴比 ≥ 2.2 的当拉线剔掉，而拉线不进
/// 「是不是行星」的判断——这里要的是紧凑点源。
DetectedStar _detection(
  Wcs wcs,
  double dx,
  double dy, {
  double confidence = 0.9,
  double magnitude = 6.0,
  bool isRejected = false,
  double axisRatio = 1.1,
}) =>
    DetectedStar(
      wcs.crpix1 + dx,
      wcs.crpix2 + dy,
      1000,
      magnitude,
      confidence,
      axisRatio,
      isRejected: isRejected,
    );

SkyAnalysis _analysis(
  Wcs wcs,
  List<DetectedStar> stars, {
  List<MaskRegion> maskRegions = const [],
}) =>
    SkyAnalysis(
      width: wcs.width,
      height: wcs.height,
      stars: stars,
      quality: '测试',
      background: 0,
      noise: 0,
      backgroundIndex: 0,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 2,
      nonStarFraction: 0,
      maskRegions: maskRegions,
      isLikelyStarfield: true,
      starfieldConfidence: 1,
      brightFlatFraction: 0,
    );

/// 中心在中心偏移 (dx, dy) 像素处的一块「大亮斑」遮罩——行星被解析开、
/// 曝到饱和的样子。
MaskRegion _blobAt(Wcs wcs, double dx, double dy, {double size = 30}) =>
    MaskRegion(
      x: wcs.crpix1 + dx - size / 2,
      y: wcs.crpix2 + dy - size / 2,
      width: size,
      height: size,
      kind: MaskKind.blob,
    );

/// 默认「这一带星表里没有星」。
bool _noCatalogStar(double ra, double dec, double radiusArcmin) => false;

void main() {
  final wcs = _wcs();

  group('两个条件都成立才出结论', () {
    test('星历位置上有亮点、星表又解释不了，就报出来', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, -30)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, -30)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, hasLength(1));
      final found = findings.first;
      expect(found.name, '木星');
      expect(found.distanceAu, 4.2);
      // 位置报的是那颗亮点，不是星历位置——用户看到的是图上那个点。
      expect(found.x, closeTo(wcs.crpix1 + 12, 1e-6));
      expect(found.y, closeTo(wcs.crpix2 - 30, 1e-6));
    });

    test('星表在这一带有星，就不报——前一半判据', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, -30)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, -30)],
        hasCatalogStarNear: (ra, dec, radius) => true,
      );
      expect(findings, isEmpty,
          reason: '星表能解释这颗亮点，那它就是恒星，不是行星');
    });

    test('只有一个条件成立不够：位置对但星表有星、星表没星但位置对不上', () {
      // 条件二不成立：亮点离星历位置 80 像素远，容差只有 45 像素上下。
      final far = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, -30)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 92, -30)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(far, isEmpty, reason: '差得太远就不是「对得上」');
    });
  });

  group('位置和不确定度', () {
    test('角秒差是按像素尺度换算出来的', () {
      // 亮点偏 3 个像素，10.68″/px ⇒ 32.0″。
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 15, -30)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, -30)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings.first.separationArcsec, closeTo(3 * _scaleArcsec, 0.05));
    });

    test('容差按角分算，不是按像素算', () {
      // 容差是 8 角分（外行星近似根数的量级，见 `ephemerisToleranceArcmin`），
      // 在这套尺度下是 44.9 像素。偏 30 像素该收，偏 60 像素该放——如果哪次
      // 把角分当成了度，容差会变成 2697 个像素，这两条就会同时反过来。
      expect(
        ephemerisToleranceArcmin * 60 / _scaleArcsec,
        closeTo(44.94, 0.01),
      );

      final inside = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 42, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(inside, hasLength(1));

      final outside = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 72, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(outside, isEmpty);
    });

    test('查星表时收到的半径是角分，而且是那个更小的门禁半径', () {
      // 单位在两条代码之间来回过手，钉一下：星表那边的接口按度收，换算写在
      // solver 里，这里给出去的必须是角分。半径用的是 `catalogGateArcmin`
      // 而不是匹配半径——门禁问的是「这个亮点本身是不是恒星」，半径一大，
      // 一颗离得很远的恒星也能把行星顶掉。
      final radii = <double>[];
      matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: (ra, dec, radiusArcmin) {
          radii.add(radiusArcmin);
          return false;
        },
      );
      expect(radii, [catalogGateArcmin]);
      expect(catalogGateArcmin, closeTo(2.0, 1e-9));
      expect(catalogGateArcmin, lessThan(ephemerisToleranceArcmin));
    });

    test('查星表问的是候选自己的位置，不是星历预测的位置', () {
      // 星历本来就可能偏出几角分。拿预测位置去问星表，问的是另一个地方的事：
      // 那颗行星会被「预报位置附近有颗恒星」这个与它无关的理由顶掉。
      final asked = <(double, double)>[];
      matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 32, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: (ra, dec, radiusArcmin) {
          asked.add((ra, dec));
          return false;
        },
      );
      final expected = wcs.pixelToWorld(wcs.crpix1 + 32, wcs.crpix2);
      expect(asked, hasLength(1));
      expect(asked.first.$1, closeTo(expected.$1, 1e-9));
      expect(asked.first.$2, closeTo(expected.$2, 1e-9));
    });

    test('尺度很粗时容差不会掉到零', () {
      // 广角拼图：每像素 15 角分，2 角分连一个像素都不到。要是没有像素下限，
      // 这张图上永远不会有任何结论。
      final coarse = Wcs.fromPixels(
        width: 1200,
        height: 800,
        centerRa: _centerRa,
        centerDec: _centerDec,
        degreesPerPixel: 15 / 60,
      );
      final findings = matchMovingBodies(
        analysis: _analysis(coarse, [_detection(coarse, 1.5, 0)]),
        wcs: coarse,
        predictions: [_predictionAt(coarse, 0, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, hasLength(1));
    });
  });

  group('什么样的亮点不算数', () {
    test('噪声级别的低置信度检出不算', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0, confidence: 0.1)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, isEmpty);
    });

    test('用户已经剔除的项不算', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0, isRejected: true)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, isEmpty,
          reason: '用户说这不是天体，就不该被当成行星报出来');
    });

    test('拉长的候选不算——那是卫星或者拖线', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0, axisRatio: 3.0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, isEmpty);
    });

    test('画面外的天体不做判断', () {
      // 预测位置在画面外 200 像素——看不见就无从判断，不该去够最近的那颗星。
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, wcs.width + 200, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, isEmpty);
    });
  });

  group('星等', () {
    test('没有星等零点就报 null，不报仪器星等', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0, magnitude: 4.0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings.first.magnitude, isNull);
    });

    test('有零点时把它加回去', () {
      final findings = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, 0, magnitude: 4.0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
        magnitudeZeroPoint: 3.5,
      );
      expect(findings.first.magnitude, closeTo(7.5, 1e-9));
    });
  });

  group('大亮斑：行星被解析开的样子', () {
    test('行星被遮罩成非星空区域时，靠那块亮斑也能认出来', () {
      // 行星的视面加上曝光过度的那圈光晕会被判成「大亮斑」，整块从星点列表
      // 里消失。只看星点，等于行星越大越亮越认不出来。
      final findings = matchMovingBodies(
        analysis: _analysis(
          wcs,
          const [],
          maskRegions: [_blobAt(wcs, 20, -10)],
        ),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 20, -10)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, hasLength(1));
      expect(findings.first.x, closeTo(wcs.crpix1 + 20, 1e-6));
      expect(findings.first.y, closeTo(wcs.crpix2 - 10, 1e-6));
      expect(
        findings.first.magnitude,
        isNull,
        reason: '亮斑已经曝到饱和，测出来的通量没有意义',
      );
    });

    test('亮斑压过更近的噪声点：圈出来的必须是行星本体', () {
      // 实测那张土星照片就是这样：土星本体是一块 31×29 的饱和光斑，而光晕
      // 边缘被检出一串 flux≈0 的假点，其中一个离星历位置（16 px）比土星本体
      // （24.8 px）还近。光晕里全是噪声峰，按距离比，行星永远输给紧贴着它的
      // 噪声。
      final findings = matchMovingBodies(
        analysis: _analysis(
          wcs,
          [_detection(wcs, 16, 0)],
          maskRegions: [_blobAt(wcs, 25, 0)],
        ),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 0, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, hasLength(1));
      expect(
        findings.first.x,
        closeTo(wcs.crpix1 + 25, 1e-6),
        reason: '圈出来的是行星本体那块亮斑，不是光晕里的噪声峰',
      );
    });

    test('占掉画面一大块的团块不算候选——那是月亮', () {
      // 面积上限 4%：被解析开的延展目标（月亮、窗玻璃、路灯）不参与行星判据。
      // 没有这条上限，只要行星恰好预报在月亮附近（冲日、掩星前后很容易），
      // 月球那一大团就会被当成那颗行星报出来。
      final side = math.sqrt(wcs.width * wcs.height * 0.2);
      final findings = matchMovingBodies(
        analysis: _analysis(
          wcs,
          const [],
          maskRegions: [
            MaskRegion(
              x: wcs.crpix1 - side / 2,
              y: wcs.crpix2 - side / 2,
              width: side,
              height: side,
              kind: MaskKind.blob,
            ),
          ],
        ),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 0, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, isEmpty);
    });

    test('文字、线条那两类遮罩不参与', () {
      // 它们不是「一个亮团的形状」，而是水印和边框那一类东西。
      final findings = matchMovingBodies(
        analysis: _analysis(
          wcs,
          const [],
          maskRegions: [
            MaskRegion(
              x: wcs.crpix1 - 15,
              y: wcs.crpix2 - 15,
              width: 30,
              height: 30,
              kind: MaskKind.text,
            ),
          ],
        ),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 0, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(findings, isEmpty);
    });
  });

  group('空输入', () {
    test('没有预测就不查', () {
      expect(
        matchMovingBodies(
          analysis: _analysis(wcs, [_detection(wcs, 12, 0)]),
          wcs: wcs,
          predictions: const [],
          hasCatalogStarNear: _noCatalogStar,
        ),
        isEmpty,
      );
    });

    test('一个检出都没有时不炸', () {
      expect(
        matchMovingBodies(
          analysis: _analysis(wcs, const []),
          wcs: wcs,
          predictions: [_predictionAt(wcs, 0, 0)],
          hasCatalogStarNear: _noCatalogStar,
        ),
        isEmpty,
      );
    });

    test('尺度为零的 WCS 不会除出无穷大', () {
      final broken = Wcs.fromPixels(
        width: 1200,
        height: 800,
        centerRa: _centerRa,
        centerDec: _centerDec,
        degreesPerPixel: 0,
      );
      expect(
        matchMovingBodies(
          analysis: _analysis(broken, [_detection(broken, 12, 0)]),
          wcs: broken,
          predictions: [_predictionAt(broken, 12, 0)],
          hasCatalogStarNear: _noCatalogStar,
        ),
        isEmpty,
      );
    });
  });
}
