import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;

void main() {
  group('SkyAnalysis', () {
    test('detects a synthetic field of compact bright sources', () async {
      final image = imglib.Image(width: 160, height: 120);
      imglib.fill(image, color: imglib.ColorRgb8(9, 12, 18));
      for (final (x, y) in [
        (20, 18),
        (56, 22),
        (98, 28),
        (137, 32),
        (29, 69),
        (76, 78),
        (126, 88),
        (45, 105),
      ]) {
        imglib.fillCircle(image, x: x, y: y, radius: 2, color: imglib.ColorRgb8(245, 238, 226));
      }

      final result = SkyAnalysis.analyze(
        Uint8List.fromList(imglib.encodePng(image)),
      );

      expect(result.stars.length, greaterThanOrEqualTo(8));
      expect(result.backgroundIndex, inInclusiveRange(0, 100));
      expect(result.width, 160);
      expect(result.height, 120);
    });

    test('flags elongated sources instead of treating them as stars', () async {
      final image = imglib.Image(width: 120, height: 90);
      imglib.fill(image, color: imglib.ColorRgb8(9, 12, 18));
      for (var y = 44; y <= 45; y++) {
        for (var x = 46; x <= 60; x++) {
          image.setPixelRgb(x, y, 245, 238, 226);
        }
      }

      final result = SkyAnalysis.analyze(
        Uint8List.fromList(imglib.encodePng(image)),
      );

      expect(result.streakCandidates, isNotEmpty);
      expect(result.compactSources, isEmpty);
      expect(
        result.diagnostics.any((message) => message.contains('单张照片不能据此确认')),
        isTrue,
      );
    });

    test('a dragged star stays out of the display list but enters solving',
        () async {
      // 拖尾的恒星：有明确核心（中心亮、边上暗），但形态是拉长的。展示上它
      // 仍然算拉线候选——用户要能看见、能剔；解算上它必须算一颗参考星，
      // 否则窄视场里白扔一颗。
      // 高斯核沿 x 拉长到约 2.4 倍：中心还是一个集中的核，两侧挂着尾巴，
      // 和真实拖尾的形态一致。
      final image = imglib.Image(width: 160, height: 120);
      imglib.fill(image, color: imglib.ColorRgb8(9, 12, 18));
      const sigmaX = 2.4;
      const sigmaY = 1.0;
      for (var y = 50; y <= 68; y++) {
        for (var x = 54; x <= 78; x++) {
          final dx = (x - 66) / sigmaX;
          final dy = (y - 59) / sigmaY;
          final level = (9 + 236 * math.exp(-0.5 * (dx * dx + dy * dy)))
              .round()
              .clamp(0, 255);
          image.setPixelRgb(x, y, level, level, level);
        }
      }

      final result = SkyAnalysis.analyze(
        Uint8List.fromList(imglib.encodePng(image)),
      );

      expect(result.compactSources, isEmpty);
      expect(result.solverExtras, isNotEmpty,
          reason: '有核心的拖尾星应该进解算候选');
      expect(result.solveCandidates.length, result.solverExtras.length);
    });

    test('reports a uniform dark frame as weak without stars', () async {
      final image = imglib.Image(width: 64, height: 48);
      imglib.fill(image, color: imglib.ColorRgb8(0, 0, 0));

      final result = SkyAnalysis.analyze(
        Uint8List.fromList(imglib.encodePng(image)),
      );

      expect(result.stars, isEmpty);
      expect(result.quality, '较弱');
      expect(result.diagnostics, isNotEmpty);
    });

    test('rejects undecodable source image with an actionable error', () async {
      // 分析是同步的：坏字节当场抛错，调用方直接在 try/catch 里接住。
      expect(
        () => SkyAnalysis.analyze(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('formats right ascension as sexagesimal hours', () {
    expect(formatRa(101.287), '06h 45m 8.9s');
  });
}
