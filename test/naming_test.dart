import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/moon_disc.dart';
import 'package:astrosophy/naming.dart';
import 'package:flutter_test/flutter_test.dart';

/// 观测记录的名字：`什么_哪天`，重名加序号。
///
/// 这一组测试同时在钉住一件事：**名字不该交给模型起**。名字的两个部分
/// （拍到了什么、哪天拍的）都是已经算出来的结论，所以下面每条断言都是确定的
/// ——同一份输入永远得到同一个名字。要是哪天有人把这里改成调 API，这些断言
/// 会立刻变得不可靠，那就是提醒。

SkyAnalysis analysisOf({MoonDisc? moonDisc, bool starfield = true}) => SkyAnalysis(
      width: 1024,
      height: 768,
      stars: const [],
      quality: '良好',
      background: 0.08,
      noise: 0.02,
      backgroundIndex: 20,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 3.0,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: starfield,
      starfieldConfidence: 0.9,
      brightFlatFraction: 0,
      moonDisc: moonDisc,
    );

SolveResult solveOf({
  List<SkyObject> deepSkyObjects = const [],
  List<String> constellations = const [],
  List<MovingBodySuspicion> movingBodies = const [],
  double fieldOfViewDegrees = 4.2,
}) =>
    SolveResult(
      centerRa: 83.8,
      centerDec: -1.5,
      arcsecPerPixel: 13.1,
      namedStars: const [],
      deepSkyObjects: deepSkyObjects,
      matchedStars: const [],
      magnitudeZeroPoint: null,
      magnitudeScatter: null,
      catalogWarning: null,
      source: SolveSource.local,
      fieldOfViewDegrees: fieldOfViewDegrees,
      constellations: constellations,
      matchedCount: 18,
      movingBodies: movingBodies,
    );

void main() {
  group('观测记录命名', () {
    test('月亮：月亮_261015', () {
      final name = suggestedObservationName(
        analysis: analysisOf(
          starfield: false,
          moonDisc: const MoonDisc(
            centerX: 137,
            centerY: 455,
            radiusPixels: 45.3,
            litPixels: 5600,
            frameArea: 595200,
          ),
        ),
        solve: null,
        moment: DateTime(2026, 10, 15, 19, 38),
      );
      expect(name, '月亮_261015');
    });

    test('行星用行星的名字：土星_250624', () {
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: solveOf(
          constellations: const ['鲸鱼座'],
          movingBodies: const [
            MovingBodySuspicion(
              name: '土星',
              ra: 13.13,
              dec: 2.95,
              x: 388.5,
              y: 669.5,
              separationArcsec: 260.5,
              magnitude: 0.6,
              distanceAu: 9.5,
            ),
          ],
        ),
        moment: DateTime(2025, 6, 24, 22, 38),
      );
      // 行星优先于星座：这张照片是冲着土星去的，不是冲着鲸鱼座去的。
      expect(name, '土星_250624');
    });

    test('大深空天体用中文常用名', () {
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: solveOf(
          constellations: const ['金牛座'],
          deepSkyObjects: const [
            SkyObject('M 45', 56.7, 24.1, '疏散星团',
                angularSizeArcmin: 110, x: 300, y: 200),
          ],
        ),
        moment: DateTime(2025, 9, 1),
      );
      expect(name, '昴星团_250901');
    });

    test('画面角落的小天体不算主体，用星座名', () {
      // 「仙女座大星系」出现在一张猎户座照片的文件名上，比没有名字更误导。
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: solveOf(
          constellations: const ['猎户座'],
          deepSkyObjects: const [
            // 3′ 的目标放进取景框 4.2°，占不到像场的 1%。
            SkyObject('NGC 7000', 20.0, 44.0, '星云',
                angularSizeArcmin: 3, x: 300, y: 200),
          ],
        ),
        moment: DateTime(2025, 9, 1),
      );
      expect(name, '猎户座_250901');
    });

    test('普通星场用星座名', () {
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: solveOf(constellations: const ['猎户座']),
        moment: DateTime(2025, 9, 1),
      );
      expect(name, '猎户座_250901');
    });

    test('没有拍摄时刻就只留前半截，不拿今天冒充', () {
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: solveOf(constellations: const ['猎户座']),
      );
      expect(name, '猎户座');
    });

    test('什么都没解出来时退回原文件名', () {
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: null,
        originalFilename: '/storage/emulated/0/DCIM/IMG_20250901.jpg',
      );
      expect(name, 'IMG_20250901');
    });

    test('实在没有依据时叫「星空」，不编一个天体名', () {
      expect(
        suggestedObservationName(analysis: analysisOf(), solve: null),
        '星空',
      );
    });

    test('文件名里的歧义字符被去掉', () {
      // 名字有一部分是从外面来的（星座名、用户自己的文件名），不能假设它
      // 干净：斜杠会被当成路径分隔符，问号星号会被当成通配符。
      final name = suggestedObservationName(
        analysis: analysisOf(),
        solve: null,
        originalFilename: r'C:\DCIM\my?photo*1.jpg',
      );
      expect(name, 'myphoto1');
    });
  });

  group('重名加序号', () {
    test('没重名就不动', () {
      expect(uniqueObservationName('月亮_261015', const []), '月亮_261015');
      expect(
        uniqueObservationName('月亮_261015', const ['土星_250624']),
        '月亮_261015',
      );
    });

    test('重名从 (1) 开始往上排', () {
      expect(
        uniqueObservationName('月亮_261015', const ['月亮_261015']),
        '月亮_261015(1)',
      );
      expect(
        uniqueObservationName(
          '月亮_261015',
          const ['月亮_261015', '月亮_261015(1)', '月亮_261015(2)'],
        ),
        '月亮_261015(3)',
      );
    });

    test('序号本身重了也要绕开', () {
      // 「月亮_261015(1)」已经存在时，不能返回同一个名字——那会变成两条
      // 列表里认不出来的记录。
      expect(
        uniqueObservationName('月亮_261015(1)', const ['月亮_261015(1)']),
        '月亮_261015(1)(1)',
      );
    });
  });
}
