import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/report.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个各项指标都能单独调的 [SkyAnalysis]，只提供报告层真正读到的字段。
SkyAnalysis analysisOf({
  required List<DetectedStar> stars,
  String quality = '良好',
  double noise = 0.02,
  double backgroundIndex = 20,
  double saturatedFraction = 0,
  double fwhm = 3.0,
  double nonStarFraction = 0,
  bool isLikelyStarfield = true,
  double starfieldConfidence = 0.95,
}) =>
    SkyAnalysis(
      width: 1024,
      height: 768,
      stars: stars,
      quality: quality,
      background: 0.08,
      noise: noise,
      backgroundIndex: backgroundIndex,
      saturatedFraction: saturatedFraction,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: fwhm,
      nonStarFraction: nonStarFraction,
      maskRegions: const [],
      isLikelyStarfield: isLikelyStarfield,
      starfieldConfidence: starfieldConfidence,
      brightFlatFraction: 0,
    );

DetectedStar starAt(
  double x,
  double y, {
  double magnitude = 5.0,
  double confidence = 0.8,
  double flux = 1000,
}) =>
    DetectedStar(x, y, flux, magnitude, confidence, 1.0, fwhm: 3, fluxError: 10);

SolveResult solveOf({
  List<SkyObject> namedStars = const [],
  List<SkyObject> deepSkyObjects = const [],
  double? zeroPoint,
  double? scatter,
  SolveSource source = SolveSource.local,
  List<String> constellations = const ['猎户座'],
  int matchedCount = 27,
}) =>
    SolveResult(
      centerRa: 83.8,
      centerDec: -1.5,
      arcsecPerPixel: 12.5,
      namedStars: namedStars,
      deepSkyObjects: deepSkyObjects,
      matchedStars: const [],
      magnitudeZeroPoint: zeroPoint,
      magnitudeScatter: scatter,
      catalogWarning: null,
      source: source,
      fieldOfViewDegrees: 9.1,
      constellations: constellations,
      matchedCount: matchedCount,
    );

void main() {
  group('星等分布', () {
    test('按固定 0.5 等分箱，而不是把范围等分', () {
      // 五颗星铺开 1.9 等。按范围等分的话这里会被切成十来个稀稀拉拉的
      // 箱子；固定箱宽才是能读出分布形状的做法。
      final analysis = analysisOf(
        stars: [
          starAt(10, 10, magnitude: 3.0),
          starAt(20, 20, magnitude: 3.4),
          starAt(30, 30, magnitude: 3.6),
          starAt(40, 40, magnitude: 4.2),
          starAt(50, 50, magnitude: 4.9),
        ],
      );
      final bins = magnitudeHistogram(analysis, null);

      expect(bins.length, 4);
      expect(bins.first.lower, closeTo(3.0, 1e-9));
      expect(bins.last.upper, closeTo(5.0, 1e-9));
      expect(bins.map((bin) => bin.count).toList(), [2, 1, 1, 1]);
      // 每颗星都恰好落进一个箱子——分箱写错的话总和会少于星数。
      expect(bins.fold<int>(0, (sum, bin) => sum + bin.count), 5);
    });

    test('压在箱子边界上的星归下一档，不重复计数', () {
      final analysis = analysisOf(
        stars: [
          starAt(10, 10, magnitude: 3.0),
          starAt(20, 20, magnitude: 3.5),
        ],
      );
      final bins = magnitudeHistogram(analysis, null);
      // 分箱是左闭右开的：3.5 属于 [3.5, 4.0)，不能两次计入 [3.0, 3.5)。
      // 起点锚在最亮的那颗星上（向下取整到 0.5 的整数倍），所以第一档
      // 不会空着——否则一张只有三颗星的图会从一堆空箱子开始。
      expect(bins.length, 2);
      expect(bins.map((bin) => bin.count).toList(), [1, 1]);
    });

    test('有星等零点就用标定值，没有就退回相对亮度', () {
      final analysis = analysisOf(
        stars: [starAt(10, 10, magnitude: 3.0)],
      );
      expect(calibratedMagnitudes(analysis, null), [closeTo(3.0, 1e-9)]);
      expect(
        calibratedMagnitudes(analysis, solveOf(zeroPoint: 12.0)),
        [closeTo(15.0, 1e-9)],
      );
    });

    test('低置信度的点源不参与统计', () {
      // 噪声点的仪器星等是随机的，放进来会把暗端撑起一片本不存在的星。
      final analysis = analysisOf(
        stars: [
          starAt(10, 10, magnitude: 3.0, confidence: 0.8),
          starAt(20, 20, magnitude: 9.9, confidence: 0.1),
        ],
      );
      expect(calibratedMagnitudes(analysis, null).length, 1);
    });

    test('一颗星都没有时返回空直方图，不抛异常', () {
      expect(magnitudeHistogram(analysisOf(stars: const []), null), isEmpty);
    });
  });

  group('视场内的恒星表', () {
    test('把目录坐标对回图上的检出点，拿它的置信度', () {
      final analysis = analysisOf(
        stars: [starAt(101, 201, confidence: 0.86)],
      );
      final solve = solveOf(
        namedStars: [
          const SkyObject('参宿四', 88.79, 7.41, '红超巨星', magnitude: 0.45)
              .at(100, 200),
        ],
      );
      final rows = buildStarTable(analysis, solve);

      expect(rows.length, 1);
      expect(rows.first.name, '参宿四');
      expect(rows.first.magnitude, 'G 0.45');
      expect(rows.first.confidence, closeTo(0.86, 1e-9));
      expect(rows.first.confidenceLabel, '较可信');
      // 名字来自内置目录这件事要如实带出来，界面靠它说明「完全离线」。
      expect(rows.first.fromLocalCatalog, isFalse);
    });

    test('图上没检出的星留空，而不是编一个置信度', () {
      final analysis = analysisOf(stars: [starAt(10, 10)]);
      final solve = solveOf(
        namedStars: [
          const SkyObject('看不见的星', 88.0, 7.0, '恒星').at(900, 700),
        ],
      );
      final rows = buildStarTable(analysis, solve);
      expect(rows.first.confidence, isNull);
      expect(rows.first.confidenceLabel, '未检出');
      expect(rows.first.magnitude, '—');
    });

    test('坐标 (0,0) 表示「不在图上」，不能当成真的落在左上角', () {
      final analysis = analysisOf(stars: [starAt(0, 0, confidence: 0.9)]);
      final solve = solveOf(
        namedStars: [const SkyObject('只在天球上的星', 88.0, 7.0, '恒星')],
      );
      expect(buildStarTable(analysis, solve).first.confidence, isNull);
    });

    test('没解算时没有表', () {
      expect(buildStarTable(analysisOf(stars: [starAt(10, 10)]), null), isEmpty);
    });
  });

  group('观星记录', () {
    test('总结里说清楚拍到了哪一片、拍得怎么样', () {
      final analysis = analysisOf(
        stars: [starAt(10, 10, magnitude: 2.0), starAt(20, 20, magnitude: 6.0)],
      );
      final record = buildObservationRecord(analysis, solveOf());

      expect(record.constellation, '猎户座');
      expect(record.summary, contains('猎户座'));
      expect(record.summary, contains('27 颗恒星'));
      expect(record.summary, contains('2 个紧凑点源'));
      expect(record.summary, contains('9.10°'));
      // 83.8° ÷ 15 = 5.5867 h → 5h 35m 12.0s
      expect(record.centerRa, '05h 35m 12.0s');
      expect(record.fieldOfView, '9.10°');
      expect(record.scale, '12.5″ / 像素');
    });

    test('没解算时如实说不知道，不硬填坐标', () {
      final record = buildObservationRecord(analysisOf(stars: const []), null);
      expect(record.constellation, isNull);
      expect(record.centerRa, '未解算');
      expect(record.fieldOfView, '未解算');
      expect(record.summary, contains('还没能认出'));
    });

    test('最亮的天体能对上星名时就报星名和星等', () {
      final analysis = analysisOf(
        stars: [starAt(100, 200, magnitude: 1.2), starAt(400, 400, magnitude: 5.0)],
      );
      final solve = solveOf(
        namedStars: [
          const SkyObject('参宿四', 88.79, 7.41, '红超巨星', magnitude: 0.45)
              .at(101, 201),
        ],
      );
      expect(buildObservationRecord(analysis, solve).brightest,
          '参宿四（G 0.45）');
    });

    test('天区太亮时建议里会提到换地方或加滤镜', () {
      final record = buildObservationRecord(
        analysisOf(stars: [starAt(10, 10)], backgroundIndex: 70),
        solveOf(),
      );
      expect(record.skyBrightness, '很亮');
      expect(record.advice.any((item) => item.contains('光害')), isTrue);
    });

    test('没毛病的照片给一句结论，而不是空列表', () {
      final record = buildObservationRecord(
        analysisOf(stars: [starAt(10, 10)]),
        solveOf(),
      );
      expect(record.advice.length, 1);
      expect(record.advice.single, contains('没有明显问题'));
    });

    test('不是星空照片时先说清楚测量只对星场区域有效', () {
      final record = buildObservationRecord(
        analysisOf(
          stars: [starAt(10, 10)],
          nonStarFraction: 0.62,
          isLikelyStarfield: false,
          starfieldConfidence: 0.3,
        ),
        solveOf(),
      );
      expect(record.advice.first, contains('不完全是星空'));
      expect(record.advice.first, contains('62%'));
    });

    test('背景亮度分成五档，边界不重叠', () {
      expect(describeSkyBrightness(5), '很暗');
      expect(describeSkyBrightness(20), '偏暗');
      expect(describeSkyBrightness(30), '一般');
      expect(describeSkyBrightness(50), '偏亮');
      expect(describeSkyBrightness(80), '很亮');
    });
  });

  group('交给模型的测量摘要', () {
    test('带上直方图、摘要和最亮天体，模型才能判断这张图拍到了什么档次', () {
      final analysis = analysisOf(
        stars: [
          starAt(10, 10, magnitude: 3.0),
          starAt(20, 20, magnitude: 3.6),
          starAt(30, 30, magnitude: 7.4),
        ],
      );
      final report = buildAgentReport(analysis, solveOf(zeroPoint: 12.0));

      expect(report['solved'], isTrue);
      expect(report['magnitude_zero_point'], 12.0);
      expect(report['brightest_object'], isNotNull);
      expect(report['summary'], isA<String>());
      expect(report['advice'], isNotEmpty);
      expect(report['background_description'], '偏暗');

      final histogram = report['magnitude_histogram']! as List<Object?>;
      expect(histogram, isNotEmpty);
      expect((histogram.first! as Map)['from'], 15.0);
      // 直方图的箱子要覆盖全部参与统计的星。
      final total = histogram.fold<int>(
        0,
        (sum, bin) => sum + ((bin! as Map)['count']! as int),
      );
      expect(total, 3);
    });

    test('用户剔除的点源单独计数，不从总数里悄悄消失', () {
      final analysis = analysisOf(
        stars: [
          starAt(10, 10),
          starAt(20, 20).copyWith(isRejected: true),
        ],
      );
      final report = buildAgentReport(analysis, null);
      // 检出的总数要含被剔除的那颗，另外单独给一个剔除计数——否则模型
      // 会以为这张图本来就只有一颗星。
      expect(report['detected_sources'], 2);
      expect(report['compact_sources'], 1);
      expect(report['rejected_by_user'], 1);
    });
  });

  group('浏览星空', () {
    test('链接带着中心坐标、视场对应的缩放和 DR10 图层', () {
      final url = legacySurveyUrl(
        ra: 22.3733,
        dec: -3.1683,
        fieldOfViewDegrees: 4.12,
      );
      expect(url, startsWith('https://www.legacysurvey.org/viewer?'));
      expect(url, contains('ra=22.37330'));
      expect(url, contains('dec=-3.16830'));
      expect(url, contains('layer=ls-dr11'));
      // 4.12° 的视场装进约 700px 宽时缩放约 8 级。
      expect(url, contains('zoom=8'));
    });

    test('视场未知时退回一个足够宽的默认缩放', () {
      final url = legacySurveyUrl(ra: 10, dec: 20, fieldOfViewDegrees: 0);
      expect(url, contains('zoom=9'));
    });
    test('有 WCS 时用 poly 画出照片取景框', () {
      final wcs = Wcs.fromPixels(
        width: 1200,
        height: 800,
        centerRa: 150,
        centerDec: 20,
        degreesPerPixel: 0.002,
      );
      final url = legacySurveyUrl(
        ra: 150,
        dec: 20,
        fieldOfViewDegrees: 2.4,
        wcs: wcs,
      );
      expect(url, contains('&poly='));
      // 四角 + 回到起点，共五组 ra,dec。
      final polygon = Uri.parse(url).queryParameters['poly']!;
      expect(polygon.split(','), hasLength(10));
      expect(url, contains('&mark=150.00000,20.00000'));
    });
  });
}
