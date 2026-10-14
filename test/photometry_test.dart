import 'dart:math' as math;

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'image_fixture.dart';

/// 离 (x, y) 最近的那个检出对象。
DetectedStar _nearest(SkyAnalysis analysis, double x, double y) =>
    analysis.stars.reduce((a, b) => _distance(a, x, y) < _distance(b, x, y) ? a : b);

double _distance(DetectedStar star, double x, double y) =>
    math.sqrt(math.pow(star.x - x, 2) + math.pow(star.y - y, 2));

void main() {
  group('圆孔径测光', () {
    test('通量随亮度线性变化，不随阈值面积膨胀', () {
      final image = nightSky(width: 360, height: 220);
      // 三颗形状完全相同、峰值亮度按二倍递减的星。
      drawStar(image, 80, 110, amplitude: 200);
      drawStar(image, 180, 110, amplitude: 100);
      drawStar(image, 280, 110, amplitude: 50);

      final result = SkyAnalysis.analyze(encodePng(image));
      final bright = _nearest(result, 80, 110);
      final middle = _nearest(result, 180, 110);
      final faint = _nearest(result, 280, 110);

      // 先确认找到的确实是画上去的那三颗。
      expect(_distance(bright, 80, 110), lessThan(1.5));
      expect(_distance(middle, 180, 110), lessThan(1.5));
      expect(_distance(faint, 280, 110), lessThan(1.5));

      // 用阈值连通域的通量算，这里的比值会是三倍以上：阈值是绝对的，
      // 亮星的连通域比暗星大一圈，通量因此被系统性地放大。圆孔径测光
      // 的量出的才是真正的二倍。
      expect(bright.flux / middle.flux, closeTo(2.0, 0.12));
      expect(middle.flux / faint.flux, closeTo(2.0, 0.12));
      // 星等是反着走的：亮的那颗数值更小。100 比 50 亮两倍，差 2.5·lg2 等。
      expect(
        faint.instrumentalMagnitude - middle.instrumentalMagnitude,
        closeTo(2.5 * math.log(2) / math.ln10, 0.07),
      );
    });

    test('每颗星都带一个可用的星等误差', () {
      final image = nightSky(width: 360, height: 220);
      drawStar(image, 120, 100, amplitude: 220);
      drawStar(image, 240, 100, amplitude: 60);

      final result = SkyAnalysis.analyze(encodePng(image));
      final bright = _nearest(result, 120, 100);
      final faint = _nearest(result, 240, 100);

      expect(bright.magnitudeError, isNotNull);
      expect(faint.magnitudeError, isNotNull);
      // 亮星的信噪比更高，误差必须更小——否则这个误差棒没有意义。
      expect(bright.magnitudeError!, lessThan(faint.magnitudeError!));
      expect(bright.magnitudeError!, lessThan(0.1));
    });

    test('点扩散函数半高全宽回得出注入时的宽度', () {
      final image = nightSky(width: 300, height: 220);
      for (var i = 0; i < 8; i++) {
        drawStar(image, 40.0 + i * 30, 110, sigma: 2.0, amplitude: 200);
      }

      final result = SkyAnalysis.analyze(encodePng(image));
      // 注入的 σ = 2.0 → FWHM = 2.355σ ≈ 4.7。
      expect(result.fwhm, greaterThan(3.0));
      expect(result.fwhm, lessThan(6.5));
    });

    test('曝光更暗的照片里同一颗星的星等被整体平移，相对星等不变', () {
      final bright = nightSky(width: 300, height: 200);
      final dim = nightSky(width: 300, height: 200, level: 30);
      for (final image in [bright, dim]) {
        drawStar(image, 100, 100, amplitude: 160);
        drawStar(image, 200, 100, amplitude: 80);
      }

      double difference(SkyAnalysis analysis) =>
          _nearest(analysis, 200, 100).instrumentalMagnitude -
          _nearest(analysis, 100, 100).instrumentalMagnitude;

      final first = SkyAnalysis.analyze(encodePng(bright));
      final second = SkyAnalysis.analyze(encodePng(dim));
      // 天光更亮时，星等零点会整体移动，但同一个视场里两颗星的星等差
      // 是照片自身的性质，不该跟着背景跑。
      expect(difference(first), closeTo(difference(second), 0.12));
    });
  });

  group('非星空内容', () {
    test('大面积亮斑被划成非星空区域，里面不会长出星点', () {
      final image = nightSky(width: 400, height: 300);
      scatterStars(image, count: 50);
      // 一轮月亮/一盏路灯。左上角留空，星点都撒在外围。
      drawBlob(image, 200, 150, 45);

      final result = SkyAnalysis.analyze(encodePng(image));
      expect(
        result.maskRegions.any((region) => region.kind == MaskKind.blob),
        isTrue,
        reason: '半径 45 像素的亮斑必须被认出来',
      );
      // 关键的一条：亮斑内部不能冒出成片的假星。亮斑边缘的噪声最容易
      // 被阈值切出一堆碎块，那正是「误检」的来源。
      final inside = result.compactSources.where(
        (star) => math.sqrt(math.pow(star.x - 200, 2) + math.pow(star.y - 150, 2)) < 42,
      );
      expect(inside.length, lessThanOrEqualTo(1));
    });

    test('一行印刷文字不会被当成星点，也不会被当成拖线', () {
      final image = nightSky(width: 420, height: 300);
      final centres = drawTextLine(image, y: 220, x0: 90, strokes: 14, spacing: 7);

      final result = SkyAnalysis.analyze(encodePng(image));
      final left = centres.first - 6;
      final right = centres.last + 12;
      final onTheLine = result.stars.where(
        (star) => star.x > left && star.x < right && (star.y - 220).abs() < 12,
      );
      expect(onTheLine, isEmpty, reason: '笔画被当成了 ${onTheLine.length} 个天体');
      expect(
        result.diagnostics.any((message) => message.contains('疑似文字或图标')),
        isTrue,
      );
      // 处理图里也要把它们抹掉，否则「只看星空」的图会留下文字残影。
      expect(result.nonStarFraction, greaterThan(0));
    });

    test('降噪过的夜空依然算星空，白纸文档不算', () {
      // 堆栈、降噪之后的照片，天空背景被压得完全平坦。这不该被当成
      // 「截图」——平坦的夜空是暗的，平坦的白纸才是亮的。
      final stacked = nightSky(width: 360, height: 260, noise: 0);
      scatterStars(stacked, count: 45);

      final night = SkyAnalysis.analyze(encodePng(stacked));
      expect(night.isLikelyStarfield, isTrue);
      expect(night.brightFlatFraction, lessThan(0.15));

      // 一张白纸上印了几行黑字：明亮的平坦区域占了大半。
      final page = nightSky(width: 360, height: 260, level: 235, noise: 0);
      for (var i = 0; i < 4; i++) {
        drawTextLine(page, y: 60 + i * 40, x0: 40, strokes: 12, amplitude: -200);
      }

      final document = SkyAnalysis.analyze(encodePng(page));
      expect(document.brightFlatFraction, greaterThan(0.5));
      expect(document.isLikelyStarfield, isFalse);
    });

    test('表格边框被划成非星空区域，也不会凭空长出星点', () {
      // 两张一模一样的星场（同一个随机种子），只差一张画了表格。
      // 要检验的正是「画上表格」这一个动作带来的差别。
      final plain = nightSky(width: 420, height: 320);
      final gridded = nightSky(width: 420, height: 320);
      scatterStars(plain, count: 40);
      scatterStars(gridded, count: 40);
      drawTable(gridded, left: 60, top: 60, right: 360, bottom: 240);

      bool insideGrid(DetectedStar star) =>
          star.x > 60 && star.x < 360 && star.y > 60 && star.y < 240;

      final without = SkyAnalysis.analyze(encodePng(plain));
      final withGrid = SkyAnalysis.analyze(encodePng(gridded));

      expect(
        withGrid.maskRegions.where(
          (region) =>
              region.kind == MaskKind.line || region.kind == MaskKind.text,
        ),
        isNotEmpty,
        reason: '表格的横竖线必须落在掩膜里，而不是变成星点或拖线',
      );

      // 关键的一条：格子里的「天体」不该因为画了几条线就变多。格子里面
      // 本来就有散落的真星，所以只能跟没画表格的那张比，不能卡绝对数。
      final before = without.compactSources.where(insideGrid).length;
      final after = withGrid.compactSources.where(insideGrid).length;
      expect(
        after,
        lessThanOrEqualTo(before + 2),
        reason: '画上表格后格子里多出了 ${after - before} 个天体',
      );
    });
  });
}
