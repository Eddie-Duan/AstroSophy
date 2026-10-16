import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/markdown.dart';
import 'package:astrosophy/models.dart';
import 'package:astrosophy/moon_disc.dart';
import 'package:astrosophy/report.dart';
import 'package:astrosophy/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 报告最上面那一段（`buildHeadlineMarkdown`）。
///
/// 这一段是用户在结果页最先看到的东西，所以它必须：先说是什么（星座）、
/// 说清认出了哪些天体、并且**天体名真的有颜色**——这最后一条只有把生成的
/// 文本喂回 Markdown 渲染器才验得出来。

SkyAnalysis analysisOf({MoonDisc? moonDisc}) => SkyAnalysis(
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
      isLikelyStarfield: true,
      starfieldConfidence: 0.95,
      brightFlatFraction: 0,
      moonDisc: moonDisc,
    );

SolveResult solveOf({
  List<SkyObject> namedStars = const [],
  List<SkyObject> deepSkyObjects = const [],
  List<String> constellations = const ['猎户座'],
  int matchedCount = 18,
  double fieldOfViewDegrees = 4.2,
  double arcsecPerPixel = 13.1,
  List<MovingBodySuspicion> movingBodies = const [],
}) =>
    SolveResult(
      centerRa: 83.8,
      centerDec: -1.5,
      arcsecPerPixel: arcsecPerPixel,
      namedStars: namedStars,
      deepSkyObjects: deepSkyObjects,
      matchedStars: const [],
      magnitudeZeroPoint: null,
      magnitudeScatter: null,
      catalogWarning: null,
      source: SolveSource.local,
      fieldOfViewDegrees: fieldOfViewDegrees,
      constellations: constellations,
      matchedCount: matchedCount,
      movingBodies: movingBodies,
    );

SkyObject star(String name, {double? magnitude}) =>
    SkyObject(name, 83.0, -1.0, '恒星 · B8Ia', magnitude: magnitude);

/// 把一行文本真的喂给渲染器，看 [text] 那一段最后是什么颜色。
///
/// 这条断言的价值在于：只检查生成出来的字符串里有没有 `==`，验不出「渲染器
/// 认不认这个记号」——记号不被识别时，屏幕上会出现一对裸露的等号，而字符串
/// 检查照样通过。
Color? colorOf(String line, String text) {
  for (final span in inlineSpans(line, const TextStyle(fontSize: 14))) {
    if (span is TextSpan && span.text == text) return span.style?.color;
  }
  return null;
}

void main() {
  group('报告头条', () {
    test('第一行就是星座', () {
      final markdown = buildHeadlineMarkdown(
        analysisOf(),
        solveOf(constellations: const ['猎户座']),
      );
      expect(markdown.split('\n').first, '## 猎户座');
    });

    test('亮星列出中文名，并且真的有颜色', () {
      final markdown = buildHeadlineMarkdown(
        analysisOf(),
        solveOf(
          namedStars: [
            star('参宿四', magnitude: 0.5),
            star('参宿七', magnitude: 0.18),
            // 在线解算回来的名字是 SIMBAD 的写法，没有中文名——不列出来。
            // 列一个「Gaia DR3 12345」出来，这一行就白占了。
            star('Gaia DR3 12345', magnitude: -1.0),
          ],
        ),
      );
      final line = markdown.split('\n').firstWhere((l) => l.contains('亮星'));
      expect(line, contains('参宿四'));
      expect(line, contains('参宿七'));
      expect(line, isNot(contains('Gaia DR3')));
      // 亮的那颗排前面。
      expect(line.indexOf('参宿七'), lessThan(line.indexOf('参宿四')));

      // 关键的一条：名字要**渲染成有颜色的**，而不是把 == 记号原样留在屏
      // 幕上。所以检查的是渲染出来的片段——原始文本里当然有记号，那是给
      // 渲染器看的。
      expect(colorOf(line, '参宿七'), kMint);
      final rendered = [
        for (final span in inlineSpans(line, const TextStyle(fontSize: 14)))
          if (span is TextSpan) span.text ?? '',
      ].join();
      expect(rendered, isNot(contains('=')), reason: '记号漏到屏幕上了：$rendered');
    });

    test('星团写「编号 中文昵称」', () {
      final markdown = buildHeadlineMarkdown(
        analysisOf(),
        solveOf(
          deepSkyObjects: [
            const SkyObject('M 45', 56.7, 24.1, '疏散星团',
                angularSizeArcmin: 110, x: 300, y: 200),
          ],
        ),
      );
      expect(markdown, contains('M 45 昴星团'));
      expect(colorOf('深空天体 ==M 45 昴星团==', 'M 45 昴星团'), kMint);
    });
    test('没有昵称的深空天体只报编号，不硬译', () {
      final markdown = buildHeadlineMarkdown(
        analysisOf(),
        solveOf(
          deepSkyObjects: [
            const SkyObject('NGC 9999', 56.7, 24.1, '星系',
                angularSizeArcmin: 5),
          ],
        ),
      );
      expect(markdown, contains('==NGC 9999=='));
      expect(markdown, isNot(contains('NGC 9999 ')));
    });

    test('不写废话', () {
      final markdown = buildHeadlineMarkdown(analysisOf(), solveOf());
      for (final fluff in ['解析结果见下方', '将执行', '点图中的亮点', '拍摄建议']) {
        expect(markdown, isNot(contains(fluff)), reason: fluff);
      }
    });

    test('没解出天区时直说没解出，不编星座', () {
      final markdown = buildHeadlineMarkdown(analysisOf(), null);
      expect(markdown.split('\n').first, '## 天区未识别');
      expect(markdown, isNot(contains('座')));
    });

    test('疑似行星排在最前面', () {
      final markdown = buildHeadlineMarkdown(
        analysisOf(),
        solveOf(
          namedStars: [star('参宿四', magnitude: 0.5)],
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
      );
      final lines = markdown.split('\n');
      expect(lines[2], contains('土星'));
      expect(lines.indexWhere((l) => l.contains('亮星')),
          greaterThan(lines.indexWhere((l) => l.contains('土星'))));
    });

    test('月面照片报两个亮面占比，不报星座', () {
      final analysis = analysisOf(
        moonDisc: const MoonDisc(
          centerX: 137,
          centerY: 455,
          radiusPixels: 45.3,
          litPixels: 5600,
          frameArea: 595200,
        ),
      );
      final moon = const MoonFacts(
        measuredFraction: 0.861,
        centerX: 137,
        centerY: 455,
        radiusPixels: 45.3,
        ephemerisFraction: 0.826,
        phaseName: '盈凸月',
        waxing: true,
      );
      final markdown = buildHeadlineMarkdown(analysis, null, moon: moon);
      expect(markdown.split('\n').first, '## 盈凸月');
      expect(markdown, contains('86.1%'));
      expect(markdown, contains('82.6%'));
      // 月亮几分钟就挪出星座边界，「在哪个星座」这件事对它没有意义。
      expect(markdown, isNot(contains('天区未识别')));
    });

    test('忘了传 moon 参数也不能写成「天区未识别」', () {
      // 用户实报的：从观星仓库里打开一条月面记录，标题写成「天区未识别」，
      // 看着像这张图白拍了。走的是另一条渲染路径，那条路上没人传 moon——
      // 而「这张图是不是月亮」明明就写在照片自己的月盘字段里。
      final analysis = analysisOf(
        moonDisc: const MoonDisc(
          centerX: 137,
          centerY: 455,
          radiusPixels: 45.3,
          litPixels: 5600,
          frameArea: 595200,
        ),
      );
      final markdown = buildHeadlineMarkdown(analysis, null);
      expect(markdown.split('\n').first, '## 月亮');
      expect(markdown, contains('亮面占比'));
      expect(markdown, isNot(contains('天区未识别')));
      // 没有拍摄时刻就给不出相名，但图上量出来的那个数照给——它就是月盘
      // 自己的 lit / πr²，和上一条测试里那个手写的 86.1% 不是同一个来源。
      expect(markdown, contains('86.9%'));
    });
  });
}
