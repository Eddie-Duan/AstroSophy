import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一张 400×300 的假分析结果，上面三个点源。
///
/// 不用 [SkyAnalysis.analyze] 真跑一遍：这里要断言的是「画不画」，笔的位置
/// 和形状都不重要，合成一张图比让检测算法牵着一堆参数走稳定得多。
SkyAnalysis analysisOf(List<DetectedStar> stars) => SkyAnalysis(
      width: 400,
      height: 300,
      stars: stars,
      quality: '良好',
      background: 0.1,
      noise: 0.02,
      backgroundIndex: 9,
      saturatedFraction: 0.001,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 3,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 0.9,
      brightFlatFraction: 0.02,
    );

DetectedStar starAt(double x, double y, {double axisRatio = 1.1}) => DetectedStar(
      x,
      y,
      4000,
      5,
      0.8,
      axisRatio,
      fwhm: 3,
      fluxError: 30,
    );

/// 把 painter 画到一张离屏图上，数一数有多少像素被涂过。
///
/// 比对着 canvas 的调用记录断言可靠：这里要验证的是「屏幕上确实什么都没有」，
/// 而画布调用序列只能证明「没有调用 drawCircle」，证明不了没有别的东西落在
/// 那个位置上。
Future<int> paintedPixels(DetectedStarsPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();
  if (data == null) return 0;
  var painted = 0;
  for (var offset = 3; offset < data.lengthInBytes; offset += 4) {
    // 画布起始是全透明的，凡是有不透明度的像素都是画上去的。
    if (data.getUint8(offset) > 8) painted++;
  }
  return painted;
}

void main() {
  const size = Size(400, 300);

  DetectedStarsPainter painterOf(
    SkyAnalysis analysis, {
    Set<int> hidden = const {},
    bool numbers = true,
    List<SkyObject> objects = const [],
    String? selectedObjectName,
  }) =>
      DetectedStarsPainter(
        analysis: analysis,
        namedStars: const [],
        objects: objects,
        hidden: hidden,
        selectedObjectName: selectedObjectName,
        numbers: numbers,
      );

  group('圆圈的隐去', () {
    test('隐去的编号连圈带号一起消失，不是画淡一点', () async {
      final analysis = analysisOf([
        starAt(60, 50),
        starAt(200, 150),
        starAt(340, 250),
      ]);
      final visible = await paintedPixels(painterOf(analysis), size);
      expect(visible, greaterThan(0));

      final hidden = await paintedPixels(painterOf(analysis, hidden: {1}), size);
      // 少的必须不只是「一点点」——半透明或者换个颜色都会留下大量像素，那正
      // 是用户抱怨过的画法。
      expect(hidden, lessThan(visible));
      expect(hidden, greaterThan(0));

      final all = await paintedPixels(
        painterOf(analysis, hidden: {0, 1, 2}),
        size,
      );
      // 三个都隐去，画布上应当一片空白，连编号都不剩。
      expect(all, 0);
    });

    test('隐去只影响画不画，编号一个都没少', () async {
      final analysis = analysisOf([
        starAt(60, 50),
        starAt(200, 150),
        starAt(340, 250),
      ]);
      final painter = painterOf(analysis, hidden: {1});
      // 这里传的是「不画哪几个下标」，analysis 本身原样带进去。一旦哪天改成
      // 传一份筛过的列表，被隐去的点就不再占编号，图上剩下的编号会和列表整体
      // 错开一位——那正是这套编号最不能出的错。
      expect(identical(painter.analysis, analysis), isTrue);
      expect(painter.analysis.numberedTargets.length, 3);
    });
  });

  group('重绘判定', () {
    test('隐去的那一组变了就要重画', () {
      final analysis = analysisOf([starAt(60, 50)]);
      expect(
        painterOf(analysis, hidden: {0}).shouldRepaint(painterOf(analysis)),
        isTrue,
      );
      expect(
        painterOf(analysis, hidden: {0}).shouldRepaint(
          painterOf(analysis, hidden: {0}),
        ),
        isFalse,
      );
    });

    test('选中的深空天体变化时重画', () {
      final analysis = analysisOf([starAt(60, 50)]);
      final objects = [
        const SkyObject('M 31', 10, 20, '星系', x: 120, y: 80),
      ];
      final unselected = painterOf(analysis, objects: objects);
      final selected =
          painterOf(analysis, objects: objects, selectedObjectName: 'M 31');

      expect(selected.shouldRepaint(unselected), isTrue);
      expect(
        painterOf(analysis, objects: objects, selectedObjectName: 'M 31')
            .shouldRepaint(selected),
        isFalse,
      );
    });
  });

  group('放大', () {
    // 这里复现的是看图区的接法：GestureDetector 套在 InteractiveViewer 里面。
    // 有两处不显然、接错了也不会报错的地方——点按会不会被缩放识别器吃掉，
    // 以及放大之后 localPosition 报的到底是什么坐标。后者尤其坑：以为它是
    // 视图坐标、再手动 toScene 一次，结果就是点哪儿都偏，而且安安静静。
    testWidgets('放大之后点按报的仍然是图上的坐标', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      Offset? local;

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 200,
              child: InteractiveViewer(
                transformationController: controller,
                minScale: 1,
                maxScale: 8,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => local = details.localPosition,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tapAt(const Offset(50, 50));
      expect(local, isNotNull, reason: '点按没有传到图上的 GestureDetector');
      expect(local!.dx, closeTo(50, 0.01));
      expect(local!.dy, closeTo(50, 0.01));

      // 放到两倍：图上的 (50, 50) 现在画在视图的 (100, 100) 上。
      controller.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.pump();
      local = null;
      await tester.tapAt(const Offset(100, 100));
      // 报回来的必须是图上那一点 (50, 50)，不是手指落下的 (100, 100)。
      expect(local!.dx, closeTo(50, 0.01));
      expect(local!.dy, closeTo(50, 0.01));
    });
  });
}
