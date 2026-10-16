import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy/analysis.dart';
import 'package:astrosophy/catalog.dart';
import 'package:astrosophy/deepsky.dart';
import 'package:astrosophy/models.dart';

/// 从仓库里的 assets 直接读星表。
///
/// 绕开 Flutter 的 asset bundle 是刻意的：`flutter test` 的工作目录就是包
/// 根目录，用 dart:io 读既简单，又不用先初始化 widget binding。
///
/// [withGaia] 给 false 时不读 Gaia 补充层，得到的就是只有 Hipparcos 的那张
/// 主星表——解算器分三层用星表，对照测试两边都得能造出来。
StarCatalog loadTestCatalog({bool withGaia = true}) {
  // 分层的界线跟着资产走，和 `StarCatalog.load` 读的是同一个字段：测试里
  // 写死一个数，资产换了深度就测不出真东西了。
  final meta = jsonDecode(
    File('assets/catalog/catalog_meta.json').readAsStringSync(),
  ) as Map<String, Object?>;
  return StarCatalog.parse(
    starsJson: File('assets/catalog/stars.json').readAsStringSync(),
    namesJson: File('assets/catalog/names.json').readAsStringSync(),
    constellationsJson:
        File('assets/catalog/constellations.json').readAsStringSync(),
    constellationGrid:
        File('assets/catalog/constellation_grid.bin').readAsBytesSync(),
    gaiaBytes:
        withGaia ? File('assets/catalog/gaia.bin').readAsBytesSync() : null,
    gaiaMidMagLimit: (meta['gaia_mid_mag_limit'] as num?)?.toDouble() ?? 9.0,
  );
}

/// 同样绕开 asset bundle，直接读仓库里的深空目录。
DeepSkyCatalog loadTestDeepSky() =>
    DeepSkyCatalog.parse(File('assets/catalog/deepsky.json').readAsStringSync());

/// 造一张「理想星图」：把某片天区里的目录星按给定 WCS 投影成像素位置。
///
/// 这只造检出结果，不渲染真实图像——解算器要验证的是三角形匹配和坐标
/// 变换的数学，直接用精确的星点位置当输入，断言才能收到亚像素级。
/// 检测算法本身由 analysis_test.dart 负责。
///
/// [positionJitter] 是给每颗星加的位置抖动（像素，均匀分布半宽），用来
/// 模拟真实检测里半像素量级的质心误差；给 0 就完全理想。
SkyAnalysis synthesiseField({
  required StarCatalog catalog,
  required double centerRa,
  required double centerDec,
  required double degreesPerPixel,
  int width = 1024,
  int height = 768,
  double rotationRadians = 0,
  double magnitudeLimit = 99,
  bool mirrored = false,
  double positionJitter = 0.25,
  int? randomSeed,
}) {
  final wcs = Wcs.fromPixels(
    width: width,
    height: height,
    centerRa: centerRa,
    centerDec: centerDec,
    degreesPerPixel: degreesPerPixel,
    rotationRadians: rotationRadians,
  );
  // 取外接圆半径，保证四角的天区也覆盖到。
  final radius = math.sqrt(
        math.pow(width / 2, 2) + math.pow(height / 2, 2),
      ) *
      degreesPerPixel;
  final random = math.Random(randomSeed ?? 20261014);
  final stars = <DetectedStar>[];
  for (final star in catalog.starsNear(
    centerRa,
    centerDec,
    radius,
    magnitudeLimit: magnitudeLimit,
  )) {
    final (projectedX, projectedY) = wcs.worldToPixel(star.ra, star.dec);
    if (!projectedX.isFinite || !projectedY.isFinite) continue;
    // 左右翻转：模拟加了天顶镜、或者用户把照片镜像过的光路。
    final x = mirrored ? width - 1 - projectedX : projectedX;
    final y = projectedY;
    if (x < 3 || y < 3 || x > width - 4 || y > height - 4) continue;
    final flux = math.pow(10, -0.4 * star.vMagnitude).toDouble() * 1000;
    stars.add(
      DetectedStar(
        x + (random.nextDouble() - 0.5) * 2 * positionJitter,
        y + (random.nextDouble() - 0.5) * 2 * positionJitter,
        flux,
        // 仪器星等直接取真实 V 星等，测光零点就应该是 0，方便断言。
        star.vMagnitude,
        0.9,
        1.0,
        fwhm: 3,
        fluxError: flux * 0.02,
      ),
    );
  }
  return SkyAnalysis(
    width: width,
    height: height,
    stars: stars,
    quality: '测试',
    background: 0,
    noise: 0,
    backgroundIndex: 0,
    saturatedFraction: 0,
    diagnostics: const [],
    preview: Uint8List(0),
    processedPreview: Uint8List(0),
    fwhm: 3,
    nonStarFraction: 0,
    maskRegions: const [],
    isLikelyStarfield: true,
    starfieldConfidence: 1,
    brightFlatFraction: 0,
  );
}

/// 检查解出来的 WCS 是否真的把每个检出星点都还原到了目录星上。
///
/// 这是比「中心坐标接近」更强的断言：中心对了但尺度和旋转错了的 WCS
/// 照样能通过中心检查，却会把整幅图的天体标注到错误的位置上。
///
/// 返回落在容差内的比例。
double wcsAgreement(
  SkyAnalysis analysis,
  Wcs wcs,
  StarCatalog catalog, {
  double tolerancePixels = 2.0,
}) {
  if (analysis.stars.isEmpty) return 0;
  final toleranceDegrees =
      math.max(tolerancePixels * wcs.arcsecPerPixel, 6.0) / 3600;
  var matched = 0;
  for (final detection in analysis.stars) {
    final (ra, dec) = wcs.pixelToWorld(detection.x, detection.y);
    if (!ra.isFinite || !dec.isFinite) continue;
    final nearby = catalog.starsNear(ra, dec, toleranceDegrees);
    if (nearby.isEmpty) continue;
    matched++;
  }
  return matched / analysis.stars.length;
}
