import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/astrometry.dart';
import 'package:astrosophy/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 在线链路的两处纯函数。
///
/// 整条链路要连 astrometry.net、Gaia、SIMBAD，测试里没法真的跑一遍；但线上
/// 失败的两个直接原因都落在纯函数上——回来的坐标属于另一帧尺寸时被整条丢弃、
/// TAP 返回里的 `#` 元信息被当成数据行。这两条能单独钉住，就先钉住。

SkyAnalysis _analysis(int width, int height) => SkyAnalysis(
      width: width,
      height: height,
      stars: const [],
      quality: '测试',
      background: 0,
      noise: 0,
      backgroundIndex: 0,
      saturatedFraction: 0,
      diagnostics: const [],
      preview: Uint8List(0),
      processedPreview: Uint8List(0),
      fwhm: 0,
      nonStarFraction: 0,
      maskRegions: const [],
      isLikelyStarfield: true,
      starfieldConfidence: 1,
      brightFlatFraction: 0,
    );

/// 造一份 FITS 头：每张卡片 80 字节。
Uint8List _fitsHeader(Map<String, Object> cards) {
  final buffer = StringBuffer();
  cards.forEach((key, value) {
    final text = value is String ? "'$value'" : '$value';
    buffer.write('${key.padRight(8)}= ${text.padRight(70)}'.substring(0, 80));
  });
  buffer.write('END'.padRight(80));
  return Uint8List.fromList(buffer.toString().codeUnits);
}

/// 一张中心在 M31 的像面，`degreesPerPixel` 是无旋转的像素尺度。
Wcs _wcsAtM31({
  required int width,
  required int height,
  required double degreesPerPixel,
}) =>
    Wcs.fromPixels(
      width: width,
      height: height,
      centerRa: 10.6847,
      centerDec: 41.2691,
      degreesPerPixel: degreesPerPixel,
    );

void main() {
  const m31Ra = 10.6847;
  const m31Dec = 41.2691;

  group('Wcs.parseFitsHeader', () {
    test('读出 astrometry.net 返回的尺寸和 CD 矩阵', () {
      final wcs = Wcs.parseFitsHeader(_fitsHeader({
        'NAXIS1': 1024,
        'NAXIS2': 768,
        'CRVAL1': 10.6847,
        'CRVAL2': 41.2691,
        'CRPIX1': 512.5,
        'CRPIX2': 384.5,
        'CD1_1': -0.002,
        'CD1_2': 0.0,
        'CD2_1': 0.0,
        'CD2_2': 0.002,
      }));
      expect(wcs.width, 1024);
      expect(wcs.height, 768);
      expect(wcs.crval1, closeTo(10.6847, 1e-9));
      expect(wcs.arcsecPerPixel, closeTo(7.2, 1e-6));
    });

    test('没有 END 的头按无效处理', () {
      expect(
        () => Wcs.parseFitsHeader(Uint8List.fromList('NAXIS1  = 10'.codeUnits)),
        throwsA(isA<FormatException>()),
      );
    });

    test('nova 那份 minimal header 也读得出来（NAXIS=0，尺寸在 IMAGEW/IMAGEH）', () {
      // 用户实报的：两张照片在 astrometry.net 上明明 Success，APP 这边却什么
      // 都拿不到。取回那份真实的 wcs_file 看过，头是这样的——
      //
      //     NAXIS   = 0
      //     IMAGEW  = 763
      //     IMAGEH  = 1200
      //
      // 压根没有 NAXIS1/NAXIS2，而原实现只认那两个键，于是解析在最后一步抛
      // 「解算结果缺少有效图像尺寸」，把一份已经到手的成功结果扔掉了。
      final wcs = Wcs.parseFitsHeader(_fitsHeader({
        'NAXIS': 0,
        'IMAGEW': 763,
        'IMAGEH': 1200,
        'CTYPE1': 'RA---TAN-SIP',
        'CTYPE2': 'DEC--TAN-SIP',
        'CRVAL1': 327.854390781,
        'CRVAL2': 47.1963689121,
        'CRPIX1': 426.264457703,
        'CRPIX2': 268.328874588,
        // 真实那份的 CD 矩阵，量出来是 3.36″/px、像面转了约 84°。
        'CD1_1': 9.63249696396e-05,
        'CD1_2': 0.000927613154925,
        'CD2_1': -0.000927188662473,
        'CD2_2': 9.63477049217e-05,
      }));
      expect(wcs.width, 763);
      expect(wcs.height, 1200);
      expect(wcs.crval1, closeTo(327.854, 1e-3));
      expect(wcs.crval2, closeTo(47.196, 1e-3));
      expect(wcs.arcsecPerPixel, closeTo(3.36, 0.01));
      // 中心坐标也要能算出来——只读出尺寸还不够，这一层的用途就是把目录星
      // 投到画面上做标注。
      final (ra, dec) = wcs.imageCenter;
      expect(ra, closeTo(328.302, 0.01));
      expect(dec, closeTo(47.269, 0.01));
    });

    test('两个键都在时以 IMAGEW/IMAGEH 为准', () {
      // 真出现分歧时，nova 的自定义键才是它实际写出的那一帧的尺寸。
      final wcs = Wcs.parseFitsHeader(_fitsHeader({
        'NAXIS1': 10,
        'NAXIS2': 20,
        'IMAGEW': 763,
        'IMAGEH': 1200,
        'CRVAL1': 10.0,
        'CRVAL2': 41.0,
        'CRPIX1': 381.5,
        'CRPIX2': 600.5,
        'CD1_1': -0.001,
        'CD1_2': 0.0,
        'CD2_1': 0.0,
        'CD2_2': 0.001,
      }));
      expect(wcs.width, 763);
      expect(wcs.height, 1200);
    });
  });

  group('Wcs.rescaledTo', () {
    test('同一块天区在同一像素上给出同一组坐标', () {
      final small = _wcsAtM31(width: 512, height: 384, degreesPerPixel: 0.004);
      final big = small.rescaledTo(1024, 768);
      expect(big.width, 1024);
      expect(big.height, 768);

      // FITS 的 CRPIX 以像素中心为原点，所以按中心等比放大：索引 x 的中心在
      // x+0.5，放大到 x' 的中心就该在 k·(x+0.5)。
      const k = 2.0;
      for (final point in [(0.0, 0.0), (137.0, 42.0), (511.0, 383.0)]) {
        final (x, y) = small.pixelToWorld(point.$1, point.$2);
        final (x2, y2) = big.worldToPixel(x, y);
        expect(x2, closeTo(k * (point.$1 + 0.5) - 0.5, 0.02));
        expect(y2, closeTo(k * (point.$2 + 0.5) - 0.5, 0.02));
      }
    });

    test('换算后的坐标反解回同一块天区', () {
      final small = _wcsAtM31(width: 600, height: 400, degreesPerPixel: 0.003);
      final big = small.rescaledTo(1800, 1200);
      for (final point in [(300.0, 200.0), (40.0, 360.0)]) {
        final (ra, dec) = small.pixelToWorld(point.$1, point.$2);
        final (x2, y2) = big.worldToPixel(ra, dec);
        final (ra2, dec2) = big.pixelToWorld(x2, y2);
        expect(ra2, closeTo(ra, 1e-6));
        expect(dec2, closeTo(dec, 1e-6));
      }
    });

    test('每像素角尺度随尺寸反向变，视场角不变', () {
      final small = _wcsAtM31(width: 600, height: 400, degreesPerPixel: 0.003);
      final big = small.rescaledTo(1200, 800);
      expect(big.arcsecPerPixel, closeTo(small.arcsecPerPixel / 2, 1e-9));
      expect(
        big.fieldOfViewDegrees,
        closeTo(small.fieldOfViewDegrees, 1e-6),
      );
    });

    test('尺寸相同时原样返回', () {
      final wcs = _wcsAtM31(width: 600, height: 400, degreesPerPixel: 0.003);
      expect(identical(wcs.rescaledTo(600, 400), wcs), isTrue);
    });
  });

  group('AstrometryService.fitToPreview', () {
    test('服务方算在缩小副本上时换算到预览这一帧', () {
      // 上传 1200×800，回来的是它的一半——按比例换算即可，不是错误。
      final returned = _wcsAtM31(
        width: 600,
        height: 400,
        degreesPerPixel: 0.006,
      );
      final fitted = AstrometryService.fitToPreview(
        returned,
        _analysis(1200, 800),
      );
      expect(fitted.width, 1200);
      expect(fitted.height, 800);
      expect(fitted.arcsecPerPixel, closeTo(returned.arcsecPerPixel / 2, 1e-9));
      final (ra, dec) = fitted.imageCenter;
      expect(ra, closeTo(m31Ra, 1e-4));
      expect(dec, closeTo(m31Dec, 1e-4));
    });

    test('尺寸相同就直接用，不做无谓的重建', () {
      final returned = _wcsAtM31(
        width: 1200,
        height: 800,
        degreesPerPixel: 0.003,
      );
      expect(
        identical(
          AstrometryService.fitToPreview(returned, _analysis(1200, 800)),
          returned,
        ),
        isTrue,
      );
    });

    test('形状对不上就停手，不把错的坐标标到图上', () {
      // 竖图和横图：宽高比不同，说明这份坐标描述的不是这张图。
      final returned = _wcsAtM31(
        width: 800,
        height: 1200,
        degreesPerPixel: 0.003,
      );
      expect(
        () => AstrometryService.fitToPreview(returned, _analysis(1200, 800)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('AstrometryService.csvLines', () {
    test('去掉 SIMBAD 表头前那段 # 元信息', () {
      const body = '#table: basic\n'
          '#column: main_id\n'
          '#\n'
          'main_id,ra,dec,otype\n'
          '"M  31",10.6847,41.2691,G\n';
      final lines = AstrometryService.csvLines(body);
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('main_id'));
      // 元信息被当成数据行去解析，读出的坐标全是空的——线上表现就是
      // 「解算回来了，但一个天体名都没有」。
      expect(
        parseCsvRow(lines.first).first,
        'main_id',
        reason: '第一行必须是表头，否则 skip(1) 会吃掉唯一一条真数据',
      );
    });

    test('空行和只有空白的行都不参与', () {
      final lines = AstrometryService.csvLines('a,b\n\n  \nc,d\n');
      expect(lines, ['a,b', 'c,d']);
    });
  });

  group('AstrometryService.withRetry', () {
    // 用户实际遇到的那一条：nova 的反向代理在上传大图之后关掉了 keep-alive
    // 连接，Dart 这边还当它是活的，于是第一次轮询就撞上
    // "Connection closed before full header was received"，整次解算就此中止。
    test('连接被对端掐断时换一条连接重来', () async {
      var calls = 0;
      final result = await AstrometryService.withRetry(
        () async {
          calls++;
          if (calls < 3) {
            throw http.ClientException(
              'Connection closed before full header was received',
              Uri.parse('https://nova.astrometry.net/api/submissions/16262561'),
            );
          }
          return 'ok';
        },
        pause: Duration.zero,
      );
      expect(result, 'ok');
      expect(calls, 3, reason: '前两次断线都要重试，第三次才拿到答复');
    });

    test('服务方答复的错误不重试，原样抛出去', () async {
      var calls = 0;
      await expectLater(
        AstrometryService.withRetry(
          () async {
            calls++;
            throw const HttpException('天文服务返回 HTTP 404。');
          },
          pause: Duration.zero,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(calls, 1, reason: 'HTTP 状态码是真的答复，重试只会把故障盖住');
    });

    test('重试到上限还是断线，就把最后一次的错误抛出去', () async {
      var calls = 0;
      await expectLater(
        AstrometryService.withRetry(
          () async {
            calls++;
            throw http.ClientException(
              'Connection closed before full header was received',
            );
          },
          attempts: 2,
          pause: Duration.zero,
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 2);
    });
  });
}
