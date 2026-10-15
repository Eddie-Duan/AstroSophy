import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/moving.dart';
import 'package:astrosophy/report.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从「图上有个亮点」到「报告里那一行字」的整条链。
///
/// 判据本身在 `moving_test.dart` 里验，星历表在 `ephemeris_test.dart` 里验，
/// 这里补的是两端之间：判出了结论之后，报告正文、给模型的摘要、以及存进历史
/// 再读回来，三处是不是都还带着它。
///
/// 这一段之所以要单独测，是因为它坏掉的时候前面的用例一个都不会红——结论算对
/// 了但报告里没写，判据的测试照样全绿，而用户在屏幕上什么也看不到。

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

SkyAnalysis _analysis(Wcs wcs, List<DetectedStar> stars) => SkyAnalysis(
      width: wcs.width,
      height: wcs.height,
      stars: stars,
      quality: '良好',
      background: 0.08,
      noise: 0.02,
      backgroundIndex: 20,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 3,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 0.95,
      brightFlatFraction: 0,
    );

/// 中心偏移 (dx, dy) 像素处的一个紧凑检出。轴比 1.1：拉长的候选会被
/// `compactSources` 剔掉，而拉线不进「是不是行星」的判断。
DetectedStar _detection(Wcs wcs, double dx, double dy, {double magnitude = 6.0}) =>
    DetectedStar(
      wcs.crpix1 + dx,
      wcs.crpix2 + dy,
      1000,
      magnitude,
      0.9,
      1.1,
    );

/// 落在中心偏移 (dx, dy) 处的星历预测。走 WCS 的反投影，和被测代码的正投影
/// 互逆。
PredictedBody _predictionAt(Wcs wcs, double dx, double dy) {
  final (ra, dec) = wcs.pixelToWorld(wcs.crpix1 + dx, wcs.crpix2 + dy);
  return PredictedBody(name: '木星', ra: ra, dec: dec, distanceAu: 4.2);
}

SolveResult _solve({
  Wcs? wcs,
  List<MovingBodySuspicion> bodies = const [],
  double? zeroPoint,
}) =>
    SolveResult(
      centerRa: _centerRa,
      centerDec: _centerDec,
      arcsecPerPixel: _scaleArcsec,
      namedStars: const [],
      deepSkyObjects: const [],
      matchedStars: const [],
      magnitudeZeroPoint: zeroPoint,
      magnitudeScatter: null,
      catalogWarning: null,
      source: SolveSource.local,
      fieldOfViewDegrees: 3.6,
      constellations: const ['仙女座'],
      wcs: wcs,
      matchedCount: 26,
      movingBodies: bodies,
    );

MovingBodySuspicion _suspicion(
  String name,
  double separationArcsec, {
  double magnitude = 6.4,
}) =>
    MovingBodySuspicion(
      name: name,
      ra: _centerRa,
      dec: _centerDec,
      x: 600,
      y: 400,
      separationArcsec: separationArcsec,
      magnitude: magnitude,
      distanceAu: 4.2,
    );

void main() {
  final wcs = _wcs();

  /// 跑一遍判据，把结论挂到解算结果上——和 `PlateSolver.annotateMovingBodies`
  /// 走的是同一条路，只是这里用不着星表。
  SolveResult annotated(
    List<DetectedStar> stars,
    List<PredictedBody> predictions, {
    bool catalogHasStar = false,
  }) =>
      _solve(wcs: wcs).withMovingBodies(
        matchMovingBodies(
          analysis: _analysis(wcs, stars),
          wcs: wcs,
          predictions: predictions,
          hasCatalogStarNear: (ra, dec, radius) => catalogHasStar,
        ),
      );

  group('判出来的结论要走到报告正文里', () {
    test('星历位置上有个亮点时，报告里就有一行', () {
      final solve = annotated(
        [_detection(wcs, 12, -30)],
        [_predictionAt(wcs, 12, -30)],
      );
      final record = buildObservationRecord(_analysis(wcs, []), solve);

      expect(record.movingBodies, hasLength(1));
      expect(record.movingBodies.first.name, '木星');
      // 角秒差要跟着名字一起给出去：它是这个结论的不确定度。
      expect(record.movingBodies.first.separationLabel, contains('和星历位置'));
      expect(record.movingBodies.first.describe, contains('距地球约 4.20 个天文单位'));
    });

    test('总结里把那句话说出来，并且说了「疑似」', () {
      final solve = annotated(
        [_detection(wcs, 12, -30)],
        [_predictionAt(wcs, 12, -30)],
      );
      final record = buildObservationRecord(_analysis(wcs, []), solve);

      expect(record.summary, contains('木星'));
      expect(record.summary, contains('疑似'));
      // 判断依赖拍摄时刻和星历精度，这件事必须在正文里说清楚，不能只在卡片上。
      expect(record.summary, contains('星历'));
    });

    test('星表在这一带有星就不出结论，报告里也就没有这一行', () {
      final solve = annotated(
        [_detection(wcs, 12, -30)],
        [_predictionAt(wcs, 12, -30)],
        catalogHasStar: true,
      );
      final record = buildObservationRecord(_analysis(wcs, []), solve);

      expect(record.movingBodies, isEmpty);
      // 反着也要断一句：不能只是「列表空着」，总结里也得一个字都不提。
      expect(record.summary, isNot(contains('疑似')));
    });

    test('差得少的排前面', () {
      final solve = _solve(
        wcs: wcs,
        bodies: [_suspicion('土星', 48), _suspicion('木星', 6)],
      );
      final record = buildObservationRecord(_analysis(wcs, []), solve);

      expect(
        record.movingBodies.map((entry) => entry.name).toList(),
        ['木星', '土星'],
      );
    });
  });

  group('给模型的那份摘要', () {
    test('结论、判据、不确定度三样一起给', () {
      final solve = annotated(
        [_detection(wcs, 12, -30)],
        [_predictionAt(wcs, 12, -30)],
      );
      final report = buildAgentReport(_analysis(wcs, []), solve);

      final bodies = report['moving_bodies'] as List<Object?>;
      expect(bodies, hasLength(1));
      final first = bodies.first! as Map<String, Object?>;
      expect(first['name'], '木星');
      expect(first['separation_arcsec'], isA<double>());
      expect(first['distance_au'], isA<double>());
      // 只给名字的话，模型会把「疑似」写成既成事实。
      expect(report['moving_body_caution'], movingBodyCaution);
    });

    test('没有结论时键还在，值是空的', () {
      // 键不能缺：缺了和「查过了，没有」在模型那边是两件事，而这里只可能是
      // 后者——这一节每次都会跑。
      final report = buildAgentReport(_analysis(wcs, []), _solve(wcs: wcs));

      expect(report.containsKey('moving_bodies'), isTrue);
      expect(report['moving_bodies'], isEmpty);
      expect(report['moving_body_caution'], isNull);
    });
  });

  group('和星历位置差多少，怎么说', () {
    test('一弧秒以内的差异不说出角秒数，只说重合', () {
      // 星历近似根数本身的误差就有角分量级，报「差 0.4″」是假精确。
      // 这里量的是报告层那一行字，所以拿 MovingBodyEntry——角秒差从
      // MovingBodySuspicion 走到报告条目上才变成话。
      MovingBodyEntry entry(double separation) => MovingBodyEntry(
            name: '木星',
            separationArcsec: separation,
          );
      expect(entry(0.4).separationLabel, '和星历位置几乎重合');
      // 门槛是 1.0 角秒：刚好压在线上的按「说得出」处理。
      expect(entry(1.0).separationLabel, '和星历位置差 1″');
      expect(entry(42.4).separationLabel, '和星历位置差 42″');
    });
  });

  group('存进历史再读回来', () {
    test('运动天体跟着记录一起存，一起读', () {
      final solve = _solve(wcs: wcs, bodies: [_suspicion('木星', 42.4)]);
      final restored = SolveResult.fromJson(solve.toJson());

      expect(restored.movingBodies, hasLength(1));
      final body = restored.movingBodies.first;
      expect(body.name, '木星');
      expect(body.ra, closeTo(_centerRa, 1e-9));
      expect(body.dec, closeTo(_centerDec, 1e-9));
      expect(body.x, 600);
      expect(body.y, 400);
      expect(body.separationArcsec, closeTo(42.4, 1e-9));
      expect(body.magnitude, closeTo(6.4, 1e-9));
      expect(body.distanceAu, closeTo(4.2, 1e-9));
      // 这一项恒为 null，读回来也必须是 null，不能变成 0。
      expect(body.discDiameterArcsec, isNull);
    });

    test('老记录里没有这个键，读出来是空的', () {
      // 这个键是后加的，历史里那些记录没有它。读的时候不能炸，也不能把
      // 「没存过」当成「存过空的」——两者的下游表现一样，但前者会抛异常。
      final json = _solve(wcs: wcs).toJson()..remove('moving_bodies');
      expect(SolveResult.fromJson(json).movingBodies, isEmpty);
    });

    test('星等没有零点时存的是 null，不是 0', () {
      final solve = _solve(
        wcs: wcs,
        bodies: [
          const MovingBodySuspicion(
            name: '木星',
            ra: 10.6847,
            dec: 41.2691,
            x: 600,
            y: 400,
            separationArcsec: 42.4,
          ),
        ],
      );
      final restored = SolveResult.fromJson(solve.toJson());
      expect(restored.movingBodies.first.magnitude, isNull);
      expect(restored.movingBodies.first.distanceAu, isNull);
    });
  });
}
