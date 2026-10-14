import 'dart:typed_data';
import 'dart:ui';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

SkyAnalysis analysisOf(List<DetectedStar> stars, {int width = 800, int height = 600}) =>
    SkyAnalysis(
      width: width,
      height: height,
      stars: stars,
      quality: '良好',
      background: 0.09,
      noise: 0.02,
      backgroundIndex: 9,
      saturatedFraction: 0.001,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 3.2,
      nonStarFraction: 0.01,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 0.93,
      brightFlatFraction: 0.02,
    );

DetectedStar starAt(
  double x,
  double y, {
  double magnitude = 5,
  double axisRatio = 1.1,
}) =>
    DetectedStar(x, y, 4000, magnitude, 0.8, axisRatio, fwhm: 3.2);

void main() {
  group('点击定位：屏幕坐标换算回图像坐标', () {
    // 800×600 的图放进 400×400 的方框：按 contain 缩放后是 400×300，上下各
    // 留 50 像素的黑边。
    const widgetSize = Size(400, 400);
    const imageSize = Size(800, 600);

    test('图正中央的点击落在图像正中央', () {
      final point = containPointToImage(
        local: const Offset(200, 200),
        widgetSize: widgetSize,
        imageSize: imageSize,
      );
      expect(point, isNotNull);
      expect(point!.dx, closeTo(400, 1e-9));
      expect(point.dy, closeTo(300, 1e-9));
    });

    test('图的左上角对应像素 (0, 0)', () {
      final point = containPointToImage(
        local: const Offset(0, 50),
        widgetSize: widgetSize,
        imageSize: imageSize,
      )!;
      expect(point.dx, closeTo(0, 1e-9));
      expect(point.dy, closeTo(0, 1e-9));
    });

    test('点在上下黑边上不算数，返回 null', () {
      // 黑边是布局留白，不是「图像的边缘」。把边缘的星吸过去，用户会以为
      // 自己点中了什么，而实际上他点的是空处。
      expect(
        containPointToImage(
          local: const Offset(200, 10),
          widgetSize: widgetSize,
          imageSize: imageSize,
        ),
        isNull,
      );
      expect(
        containPointToImage(
          local: const Offset(200, 395),
          widgetSize: widgetSize,
          imageSize: imageSize,
        ),
        isNull,
      );
    });

    test('横向留白同样返回 null', () {
      // 竖图放进横框。1279×2072 的演示图就是这个情形。
      final point = containPointToImage(
        local: const Offset(5, 200),
        widgetSize: const Size(400, 400),
        imageSize: const Size(500, 1000),
      );
      expect(point, isNull);
    });

    test('尺寸非法时不抛异常，直接返回 null', () {
      expect(
        containPointToImage(
          local: Offset.zero,
          widgetSize: const Size(400, 400),
          imageSize: Size.zero,
        ),
        isNull,
      );
    });
  });

  group('编号与剔除', () {
    test('编号顺序按亮度，剔掉一项也不重排', () {
      final analysis = analysisOf([
        starAt(10, 10, magnitude: 8),
        starAt(20, 20, magnitude: 3),
        starAt(30, 30, magnitude: 6),
      ]);
      // 亮到暗：3 等 → 6 等 → 8 等，跟列表里的坐标对不上也没关系，用户看的是
      // 「第几号」，编号一变就全乱了。
      expect(
        analysis.numberedTargets.map((star) => star.x).toList(),
        [20, 30, 10],
      );

      final rejected = analysis.withRejection(analysis.numberedTargets.first, true);
      // 被剔除的那一项仍然占着 1 号位——列表里它还在（划掉显示），图上也要
      // 画着它，否则用户没法反悔。
      expect(
        rejected.numberedTargets.map((star) => star.x).toList(),
        [20, 30, 10],
      );
      expect(rejected.numberedTargets.first.isRejected, isTrue);
      expect(rejected.numberedTargets.length, 3);
    });

    test('剔除后不再参与测光，但仍在完整列表里', () {
      final analysis = analysisOf([
        starAt(10, 10, magnitude: 5),
        starAt(20, 20, magnitude: 3),
      ]);
      final rejected = analysis.withRejection(analysis.stars.first, true);

      expect(rejected.compactSources.length, 1);
      expect(rejected.compactSources.single.x, 20);
      expect(rejected.allCompactSources.length, 2);
      expect(rejected.rankedCompactSources.length, 2);
    });

    test('再点一次能恢复', () {
      final analysis = analysisOf([starAt(10, 10)]);
      final rejected = analysis.withRejection(analysis.stars.first, true);
      final restored = rejected.withRejection(rejected.stars.first, false);
      expect(restored.compactSources.length, 1);
      expect(restored.stars.single.isRejected, isFalse);
    });

    test('拉长的候选排在紧凑点源后面，编号不交叉', () {
      final analysis = analysisOf([
        starAt(10, 10, magnitude: 7),
        starAt(20, 20, magnitude: 2, axisRatio: 3.4),
        starAt(30, 30, magnitude: 5),
      ]);
      final targets = analysis.numberedTargets;
      // 尽管拉长的那颗最亮，它仍排在最后：宽视场里飞机线常有几十条，混在
      // 点源中间会把前几十个编号全挤乱。
      expect(targets.last.isElongated, isTrue);
      expect(targets.last.x, 20);
      expect(targets.take(2).every((star) => !star.isElongated), isTrue);
    });

    test('解算结果里被剔除的那颗星不再出现在命名星表中', () {
      final analysis = analysisOf([starAt(10, 10), starAt(200, 200)]);
      const solve = SolveResult(
        centerRa: 83.8,
        centerDec: -1.5,
        arcsecPerPixel: 12.5,
        namedStars: [SkyObject('参宿四', 88.79, 7.41, '红超巨星', x: 10, y: 10)],
        deepSkyObjects: [],
        matchedStars: [],
        magnitudeZeroPoint: 14.2,
        magnitudeScatter: 0.18,
        catalogWarning: null,
        source: SolveSource.local,
      );
      expect(solve.withoutRejected(analysis.stars).namedStars, hasLength(1));

      final rejected = analysis.withRejection(analysis.stars.first, true);
      expect(rejected.stars.first.x, 10);
      expect(solve.withoutRejected(rejected.stars).namedStars, isEmpty);
    });

    test('没有剔除项时原样返回，不做多余的对象拷贝', () {
      const solve = SolveResult(
        centerRa: 0,
        centerDec: 0,
        arcsecPerPixel: 1,
        namedStars: [SkyObject('织女星', 279, 38.8, '主序星')],
        deepSkyObjects: [],
        matchedStars: [],
        magnitudeZeroPoint: null,
        magnitudeScatter: null,
        catalogWarning: null,
      );
      expect(identical(solve.withoutRejected(const []), solve), isTrue);
    });
  });
}
