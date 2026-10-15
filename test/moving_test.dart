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

SkyAnalysis _analysis(Wcs wcs, List<DetectedStar> stars) => SkyAnalysis(
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
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 1,
      brightFlatFraction: 0,
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
      // 条件二不成立：亮点离星历位置 40 像素远，容差只有 11 像素上下。
      final far = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 12, -30)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 52, -30)],
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
      // 容差是 2 角分，在这套尺度下是 11.2 像素。偏 8 像素（85″）该收，
      // 偏 14 像素（150″）该放——如果哪次把角分当成了度，容差会变成
      // 674 个像素，这两条就会同时反过来。
      final inside = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 20, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(inside, hasLength(1));

      final outside = matchMovingBodies(
        analysis: _analysis(wcs, [_detection(wcs, 26, 0)]),
        wcs: wcs,
        predictions: [_predictionAt(wcs, 12, 0)],
        hasCatalogStarNear: _noCatalogStar,
      );
      expect(outside, isEmpty);
    });

    test('查星表时收到的半径是角分', () {
      // 单位在两条代码之间来回过手，钉一下：星表那边的接口按度收，换算写在
      // solver 里，这里给出去的必须是角分。
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
      expect(radii, [ephemerisToleranceArcmin]);
      expect(ephemerisToleranceArcmin, closeTo(2.0, 1e-9));
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
