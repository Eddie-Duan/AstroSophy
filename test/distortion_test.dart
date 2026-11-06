import 'dart:math' as math;

import 'package:astrosophy/distortion.dart';
import 'package:astrosophy/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一张 80 字节的 FITS 卡片。parseFitsHeader 是按 80 字节切卡的。
String _card(String key, String value) {
  final head = '${key.padRight(8)}= ';
  final body = head + value.padRight(80 - head.length);
  return body.substring(0, 80);
}

List<int> _header(List<String> cards) {
  final buffer = StringBuffer();
  for (final card in cards) {
    buffer.write(card);
  }
  buffer.write(_card('END', ''));
  return buffer.toString().codeUnits;
}

void main() {
  final base = Wcs.fromPixels(
    width: 900,
    height: 1200,
    centerRa: 331.02,
    centerDec: 51.53,
    degreesPerPixel: 0.0676,
  );

  // 一组「像」真实手机广角镜头的二阶曲率（数值量级取自 astrometry.net
  // 对一张 83° 照片的拟合：A_2_0≈-2.6e-5）。
  const trueA = <(int, int), double>{
    (2, 0): -2.6e-5,
    (1, 1): 9.8e-6,
    (0, 2): -7.6e-7,
  };
  const trueB = <(int, int), double>{
    (2, 0): 1.1e-6,
    (1, 1): -2.5e-5,
    (0, 2): 1.1e-5,
  };
  final truth = base.withSip(a: trueA, b: trueB);

  group('SIP 曲率', () {
    test('像素 ↔ 天球可以来回换算', () {
      final random = math.Random(7);
      for (var i = 0; i < 40; i++) {
        final x = random.nextDouble() * 900;
        final y = random.nextDouble() * 1200;
        final (ra, dec) = truth.pixelToWorld(x, y);
        expect(ra.isFinite && dec.isFinite, isTrue);
        final (backX, backY) = truth.worldToPixel(ra, dec);
        expect((backX - x).abs(), lessThan(1e-3), reason: '第 $i 个点 x 回代误差');
        expect((backY - y).abs(), lessThan(1e-3), reason: '第 $i 个点 y 回代误差');
      }
    });

    test('从星点配对里能把曲率拟合回来', () {
      final random = math.Random(11);
      final matches = <SipMatch>[];
      for (var i = 0; i < 120; i++) {
        final x = 20 + random.nextDouble() * 860;
        final y = 20 + random.nextDouble() * 1160;
        final (ra, dec) = truth.pixelToWorld(x, y);
        matches.add(SipMatch(x, y, ra, dec));
      }
      final fitted = fitSipDistortion(base, matches, order: 2);
      expect(fitted, isNotNull);
      expect(fitted!.inliers, greaterThan(110));
      expect(fitted.rms, lessThan(0.05));

      // 用拟合出来的曲率投影一批独立点，和真值比。
      var worst = 0.0;
      for (var i = 0; i < 60; i++) {
        final x = random.nextDouble() * 900;
        final y = random.nextDouble() * 1200;
        final (ra, dec) = truth.pixelToWorld(x, y);
        final (px, py) = fitted.wcs.worldToPixel(ra, dec);
        worst = math.max(worst, math.max((px - x).abs(), (py - y).abs()));
      }
      expect(worst, lessThan(0.2), reason: '拟合曲率后最大投影误差 $worst px');
      expect(fitted.wcs.hasSip, isTrue);
      expect(fitted.wcs.sipA[(2, 0)], closeTo(trueA[(2, 0)]!, 5e-6));
    });

    test('FITS 头里的 SIP 会被读进来，也能序列化回去', () {
      final bytes = _header([
        _card('SIMPLE', 'T'),
        _card('NAXIS', '0'),
        _card('IMAGEW', '900'),
        _card('IMAGEH', '1200'),
        _card('CRVAL1', '331.021666549'),
        _card('CRVAL2', '51.5265389357'),
        _card('CRPIX1', '450.5'),
        _card('CRPIX2', '600.5'),
        _card('CD1_1', '-0.00429700471147'),
        _card('CD1_2', '-0.0378061435476'),
        _card('CD2_1', '0.0377990344631'),
        _card('CD2_2', '-0.00428372628617'),
        _card('A_ORDER', '2'),
        _card('A_2_0', '-2.62792604328E-05'),
        _card('A_1_1', '9.80539299202E-06'),
        _card('A_0_2', '-7.6483545106E-07'),
        _card('B_ORDER', '2'),
        _card('B_2_0', '1.08359275442E-06'),
        _card('B_1_1', '-2.52223771367E-05'),
        _card('B_0_2', '1.0888513567E-05'),
        _card('AP_ORDER', '2'),
        _card('AP_0_0', '0.0485237320933'),
        _card('BP_ORDER', '2'),
        _card('BP_0_0', '-0.0433827969936'),
      ]);
      final wcs = Wcs.parseFitsHeader(bytes);
      expect(wcs.hasSip, isTrue);
      expect(wcs.sipA.length, 3);
      expect(wcs.sipB.length, 3);
      expect(wcs.sipA[(2, 0)], closeTo(-2.62792604328E-05, 1e-12));

      final json = wcs.toJson();
      final restored = Wcs.fromJson(json);
      expect(restored.sipA.length, wcs.sipA.length);
      final (ra, dec) = wcs.pixelToWorld(123, 456);
      final (ra2, dec2) = restored.pixelToWorld(123, 456);
      expect(ra2, closeTo(ra, 1e-12));
      expect(dec2, closeTo(dec, 1e-12));
    });

    test('缩放像面时 SIP 系数按像素尺度换算，天球位置不变', () {
      final half = truth.rescaledTo(450, 600);
      final (ra, dec) = truth.pixelToWorld(300, 400);
      // 像素中心对齐的缩放：x_s = (x+0.5)*k - 0.5，所以 300 → 149.75。
      final (raHalf, decHalf) = half.pixelToWorld(149.75, 199.75);
      expect(raHalf, closeTo(ra, 0.02));
      expect(decHalf, closeTo(dec, 0.02));
    });
  });
}
