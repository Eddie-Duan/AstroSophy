import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/astrometry.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/report.dart';
import 'package:astrosophy/solver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一个各项指标都能单独调的 [SkyAnalysis]。深空相关的判断只读几个字段，
/// 其余照实填一个「正常星场」的默认值。
SkyAnalysis analysisOf({
  required List<DetectedStar> stars,
  double fwhm = 3.0,
  bool isLikelyStarfield = true,
  int streaks = 0,
}) =>
    SkyAnalysis(
      width: 1024,
      height: 768,
      // 拉长候选是 `stars` 里 axisRatio 过线的那批，不是单独一份列表。
      stars: [
        ...stars,
        for (var index = 0; index < streaks; index++)
          DetectedStar(
            index.toDouble(),
            0,
            1000,
            5,
            0.6,
            3.0,
            fwhm: 3,
            fluxError: 10,
          ),
      ],
      quality: '良好',
      background: 0.08,
      noise: 0.02,
      backgroundIndex: 20,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: fwhm,
      nonStarFraction: isLikelyStarfield ? 0 : 0.6,
      maskRegions: const [],
      isLikelyStarfield: isLikelyStarfield,
      starfieldConfidence: isLikelyStarfield ? 0.95 : 0.2,
      brightFlatFraction: 0,
    );

DetectedStar starAt(double x, double y) =>
    DetectedStar(x, y, 1000, 5.0, 0.8, 1.0, fwhm: 3, fluxError: 10);

List<DetectedStar> starsOf(int count) => [
      for (var index = 0; index < count; index++)
        starAt((index % 32) * 30.0, (index ~/ 32) * 30.0),
    ];

SolveResult solveOf({
  List<SkyObject> deepSkyObjects = const [],
  double fieldOfViewDegrees = 9.1,
}) =>
    SolveResult(
      centerRa: 83.8,
      centerDec: -1.5,
      arcsecPerPixel: 12.5,
      namedStars: const [],
      deepSkyObjects: deepSkyObjects,
      matchedStars: const [],
      magnitudeZeroPoint: null,
      magnitudeScatter: null,
      catalogWarning: null,
      source: SolveSource.local,
      fieldOfViewDegrees: fieldOfViewDegrees,
      constellations: const ['仙女座'],
      matchedCount: 27,
    );

SkyObject deepSky(
  String name,
  String category, {
  double? angularSizeArcmin,
  double ra = 10.68,
  double dec = 41.27,
}) =>
    SkyObject(
      name,
      ra,
      dec,
      category,
      angularSizeArcmin: angularSizeArcmin,
    );

void main() {
  group('解算失败提示', () {
    test('图不是星场时先让人去裁图，而不是去换镜头', () {
      final advice = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200), isLikelyStarfield: false),
        uploadAllowed: false,
        hasApiKey: false,
      );
      expect(advice.first, contains('就不是以星场为主的照片'));
      expect(advice.first, contains('裁掉'));
    });

    test('星点确实太少时才说「重拍/更广焦段」', () {
      final advice = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(3)),
        uploadAllowed: false,
        hasApiKey: false,
      );
      expect(advice.first, contains('只检出 3 个紧凑点源'));
      expect(advice.first, contains('曝光'));
    });

    test('星点足够多时改口说是星表对不上，不再劝人重拍', () {
      // 这是 demo_m31 的真实情况：图上有三千多个点源，解不出来是因为
      // 这些点源和星表对不上——多半是星系本体被检成了「星点」，
      // 跟「拍得不好」没关系。
      final advice = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200)),
        uploadAllowed: false,
        hasApiKey: false,
      );
      expect(advice.first, contains('200 个紧凑点源'));
      expect(advice.first, contains('不是星点太少'));
      expect(advice.first, contains('V=8.0'));
      expect(advice.first, isNot(contains('重拍')));
    });

    test('没授权上传时指向设置页，给了 Key 之后改指在线解算', () {
      final blocked = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200)),
        uploadAllowed: false,
        hasApiKey: false,
      );
      expect(blocked, hasLength(2));
      expect(blocked.last, contains('设置'));

      final noKey = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200)),
        uploadAllowed: true,
        hasApiKey: false,
      );
      expect(noKey.last, contains('API Key'));

      final ready = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200)),
        uploadAllowed: true,
        hasApiKey: true,
      );
      expect(ready.last, contains('在线解算'));
      expect(ready.last, isNot(contains('API Key')));
    });

    test('在线也失败时把失败原因原样带出来', () {
      final advice = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200)),
        uploadAllowed: true,
        hasApiKey: true,
        onlineError: 'HTTP 503',
      );
      expect(advice.last, contains('HTTP 503'));
      expect(advice.last, contains('云'));
    });

    test('脱焦和拖线各补一句，且不重复说第二遍', () {
      final blurred = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200), fwhm: 9.4),
        uploadAllowed: false,
        hasApiKey: false,
      );
      expect(blurred, hasLength(3));
      expect(blurred.last, contains('对焦'));

      final trailed = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200), streaks: 44),
        uploadAllowed: false,
        hasApiKey: false,
      );
      expect(trailed.last, contains('44 条'));
      expect(trailed.last, contains('缩短单张曝光'));
    });
  });

  group('解算失败的取证', () {
    test('把试过的层和差几颗内点写出来', () {
      // 这一行的由来：同一张图、同一份代码，用户在手机上解不出、桌面上却解
      // 得出。两种原因——星表没读全、判据太紧——对用户是同一句「没找到」，
      // 只好把实际试过的写出来让两者分得开。
      final trace = SolveTrace();
      trace.startLayer('浅层', 41394).rungsTried = 4;
      trace.startLayer('中间层', 170212).rungsTried = 4;
      trace.startLayer('最深层', 1205907).rungsTried = 4;
      trace.bestInliers = 7;
      trace.bestRequired = 10;

      expect(
        describeSolveAttempt(trace),
        '本机解算未成功：浅层 41394 颗（试 4 档）、'
        '中间层 170212 颗（试 4 档）、最深层 1205907 颗（试 4 档）；'
        '最多数到 7 颗内点，需要 10 颗。',
      );
    });

    test('连内点都没数到时不说「需要 0 颗」', () {
      final trace = SolveTrace();
      trace.startLayer('浅层', 41394).rungsTried = 4;

      final line = describeSolveAttempt(trace);
      expect(line, contains('一个都没能对上内点'));
      expect(line, isNot(contains('需要 0 颗')));
    });

    test('没跑到任何一层就不添这一行', () {
      // 检出星点本身就太少时，前面那句「点源太少」已经把原因说清了，
      // 再补一行空数字只是噪声。
      expect(describeSolveAttempt(SolveTrace()), isNull);
      expect(describeSolveAttempt(null), isNull);
    });

    test('取证行排在「该做什么」之后，不抢第一句', () {
      final trace = SolveTrace();
      trace.startLayer('浅层', 41394).rungsTried = 4;
      trace.bestInliers = 7;
      trace.bestRequired = 10;

      final advice = buildSolveFailureAdvice(
        analysisOf(stars: starsOf(200)),
        uploadAllowed: false,
        hasApiKey: false,
        attempt: trace,
      );

      expect(advice, hasLength(3));
      expect(advice.first, contains('不是星点太少'));
      expect(advice[1], contains('浅层 41394 颗'));
      expect(advice.last, contains('设置'));
    });
  });

  group('深空天体条目', () {
    test('没解算时给空列表，而不是抛错', () {
      expect(buildDeepSkyEntries(null), isEmpty);
    });

    test('按占像场多大排序，主体排在第一个', () {
      final entries = buildDeepSkyEntries(
        solveOf(
          fieldOfViewDegrees: 9.1,
          deepSkyObjects: [
            deepSky('NGC 6205', '球状星团', angularSizeArcmin: 20),
            deepSky('M 31', '旋涡星系', angularSizeArcmin: 190),
            deepSky('M 110', '椭圆星系', angularSizeArcmin: 21),
          ],
        ),
      );
      expect(
        entries.map((entry) => entry.name),
        ['M 31', 'M 110', 'NGC 6205'],
      );
      // 190′ = 3.17°，占 9.1° 像场的 34.8%。
      expect(entries.first.fieldFraction, closeTo(0.348, 0.001));
    });

    test('目录里没有角尺寸时不编一个出来', () {
      final entry = buildDeepSkyEntries(
        solveOf(deepSkyObjects: [deepSky('M 31', '旋涡星系')]),
      ).single;
      expect(entry.angularSizeArcmin, isNull);
      expect(entry.fieldFraction, isNull);
      expect(entry.sizeLabel, '尺寸未知');
      expect(entry.coverageLabel, isEmpty);
      expect(entry.isLarge, isFalse);
    });

    test('角尺寸按量级换单位', () {
      DeepSkyEntry sized(double arcmin) =>
          DeepSkyEntry(name: 'x', category: '', angularSizeArcmin: arcmin);
      expect(sized(0.8).sizeLabel, '约 48″');
      expect(sized(14).sizeLabel, '约 14.0′');
      expect(sized(190).sizeLabel, '约 3.17°');
    });

    test('占比换成人话，并区分「主体 / 陪衬 / 比像场还大」', () {
      DeepSkyEntry covering(double fraction) => DeepSkyEntry(
            name: 'x',
            category: '',
            angularSizeArcmin: 1,
            fieldFraction: fraction,
          );
      expect(covering(0.42).coverageLabel, contains('是这张照片的主体'));
      // 0.348 恰好卡在 35% 的门槛下面，话也得跟着换——这条边界值来自
      // demo_m31 的真实占比（190′ 占 9.1° 像场的 34.8%）。
      expect(covering(0.348).coverageLabel, isNot(contains('主体')));
      expect(covering(0.02).coverageLabel, contains('偏小'));
      expect(covering(1.4).coverageLabel, contains('比像场对角线还大'));
    });
  });

  group('报告里的深空天体', () {
    test('总结里同时给名字、类型和它占多大', () {
      final record = buildObservationRecord(
        analysisOf(stars: starsOf(12)),
        solveOf(deepSkyObjects: [
          deepSky('M 31', '旋涡星系', angularSizeArcmin: 190),
        ]),
      );
      expect(record.summary, contains('画面里有 1 个深空天体'));
      expect(record.summary, contains('M 31（旋涡星系）'));
      expect(record.summary, contains('约 3.17°'));
      expect(record.deepSky, hasLength(1));
    });

    test('拍的是深空目标时先说清楚「星点少是正常的」', () {
      // 这条是给被「星点怎么这么少」劝退的人看的：M31 这类目标本身就是
      // 一个延展的亮斑，紧凑点源少是目标性质，不是拍坏了。
      final advice = buildAdvice(
        analysisOf(stars: starsOf(12)),
        solveOf(deepSkyObjects: [
          deepSky('M 31', '旋涡星系', angularSizeArcmin: 190),
        ]),
      );
      expect(advice.first, contains('不是拍坏了'));
      expect(advice.first, contains('M 31（旋涡星系）'));
    });

    test('是普通星场就不说这句，免得占掉真正的建议', () {
      final advice = buildAdvice(
        analysisOf(stars: starsOf(200)),
        solveOf(deepSkyObjects: [
          deepSky('M 31', '旋涡星系', angularSizeArcmin: 190),
        ]),
      );
      expect(advice.any((line) => line.contains('不是拍坏了')), isFalse);
    });
  });

  group('在线星表的名字和类型', () {
    test('压掉 SIMBAD 对齐用的连续空格', () {
      expect(tidyCatalogName('  M  31 '), 'M 31');
      expect(tidyCatalogName('NGC  224'), 'NGC 224');
      expect(tidyCatalogName('NGC 224'), 'NGC 224');
    });

    test('长前缀优先，Cl* 不会被 Cl 抢走', () {
      expect(describeObjectType('Cl*'), '星团');
      expect(describeObjectType('ClG'), '星系团');
      expect(describeObjectType('OpC'), '疏散星团');
      expect(describeObjectType('GlC'), '球状星团');
      expect(describeObjectType('SNR'), '超新星遗迹');
      expect(describeObjectType('G'), '星系');
    });

    test('认不出来的代码原样返回，不猜一个中文类型', () {
      expect(describeObjectType('**'), '**');
      expect(describeObjectType('V*'), 'V*');
      expect(describeObjectType(''), '');
    });
  });
}
