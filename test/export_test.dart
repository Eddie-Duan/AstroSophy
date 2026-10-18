import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;

import 'image_fixture.dart';

/// 导出带标注的 PNG。
///
/// 这一条验的是「导出的图是不是真的一张能打开的图、尺寸对不对、和屏幕上
/// 那块是不是同一套标注」——像素级的观感没法断言，但尺寸和内容差异可以。
void main() {
  group('导出标注图', () {
    test('尺寸按长边 2400 高清输出，保持原图比例', () async {
      final image = nightSky(width: 800, height: 600);
      scatterStars(image, count: 40);
      final bytes = encodePng(image);
      final analysis = SkyAnalysis.analyze(bytes);

      final png = await renderAnnotatedPng(
        analysis: analysis,
        baseImage: analysis.preview,
        namedStars: const [],
        objects: const [],
      );

      final decoded = imglib.decodePng(png);
      expect(decoded, isNotNull, reason: '导出的应该是一张能解码的 PNG');
      // 导出的不再是「分析尺寸」那张小图：长边拉到 2400，字号按屏幕上的
      // 相对大小同步放大，保存到相册后不会又小又糊。
      expect(decoded!.width, 2400);
      expect(decoded.height, 1800);
      expect(
        decoded.width / decoded.height,
        closeTo(analysis.width / analysis.height, 0.01),
      );
    });

    test('画上标注之后像素确实变了', () async {
      // 只比尺寸的话，「导出的其实是原图、一个标注都没画」这种情况照样通过。
      final image = nightSky(width: 400, height: 300);
      scatterStars(image, count: 30);
      final bytes = encodePng(image);
      final analysis = SkyAnalysis.analyze(bytes);

      final plain = await renderAnnotatedPng(
        analysis: analysis,
        baseImage: analysis.preview,
        namedStars: const [],
        objects: const [],
        numbers: false,
      );
      final annotated = await renderAnnotatedPng(
        analysis: analysis,
        baseImage: analysis.preview,
        namedStars: const [],
        objects: const [],
      );

      expect(_differingPixels(plain, annotated), greaterThan(0),
          reason: '标了编号的版本和没标的版本应该有像素差异');
    });

    test('圈画多了之后的图更大，说明标注确实按当前勾选画', () async {
      // 「下载包括已经勾选的圆圈」——隐去的组不该出现在导出图里。这里用
      // 编号数量代替勾选状态：画 0 个编号和画满编号，图必须不一样。
      final image = nightSky(width: 400, height: 300);
      scatterStars(image, count: 30);
      final bytes = encodePng(image);
      final analysis = SkyAnalysis.analyze(bytes);

      final all = await renderAnnotatedPng(
        analysis: analysis,
        baseImage: analysis.preview,
        namedStars: const [],
        objects: const [],
      );
      final allHidden = await renderAnnotatedPng(
        analysis: analysis,
        baseImage: analysis.preview,
        namedStars: const [],
        objects: const [],
        hidden: {for (var i = 0; i < analysis.numberedTargets.length; i++) i},
      );

      expect(_differingPixels(all, allHidden), greaterThan(0));
    });
  });
}

/// 两张同尺寸 PNG 之间有多少个像素不一样。
int _differingPixels(Uint8List a, Uint8List b) {
  final first = imglib.decodePng(a)!;
  final second = imglib.decodePng(b)!;
  if (first.width != second.width || first.height != second.height) {
    throw StateError('尺寸不同，没法比：${first.width}x${first.height} '
        'vs ${second.width}x${second.height}');
  }
  var differing = 0;
  for (var y = 0; y < first.height; y++) {
    for (var x = 0; x < first.width; x++) {
      final p = first.getPixel(x, y);
      final q = second.getPixel(x, y);
      if (p.r != q.r || p.g != q.g || p.b != q.b) differing++;
    }
  }
  return differing;
}
