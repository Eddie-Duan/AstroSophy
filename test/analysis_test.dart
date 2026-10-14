import 'dart:typed_data';

import 'package:astrosophy/main.dart';
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

      final result = await SkyAnalysis.analyze(
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

      final result = await SkyAnalysis.analyze(
        Uint8List.fromList(imglib.encodePng(image)),
      );

      expect(result.streakCandidates, isNotEmpty);
      expect(result.compactSources, isEmpty);
      expect(
        result.diagnostics.any((message) => message.contains('不能据此确认卫星或飞机')),
        isTrue,
      );
    });

    test('reports a uniform dark frame as weak without stars', () async {
      final image = imglib.Image(width: 64, height: 48);
      imglib.fill(image, color: imglib.ColorRgb8(0, 0, 0));

      final result = await SkyAnalysis.analyze(
        Uint8List.fromList(imglib.encodePng(image)),
      );

      expect(result.stars, isEmpty);
      expect(result.quality, '较弱');
      expect(result.diagnostics, isNotEmpty);
    });

    test('rejects undecodable source image with an actionable error', () async {
      await expectLater(
        SkyAnalysis.analyze(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('formats right ascension as sexagesimal hours', () {
    expect(formatRa(101.287), '06h 45m 8.9s');
  });
}
