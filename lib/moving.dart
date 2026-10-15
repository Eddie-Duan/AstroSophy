import 'dart:math' as math;

import 'analysis.dart';
import 'models.dart';

/// 运动天体：行星、彗星、小行星。它们在照片上的位置随拍摄时刻变化，所以判据
/// 和恒星完全不同——恒星靠「星表里有这么一颗星」，运动天体靠「星表里**没有**
/// 这么一颗星，而星历说它正好在这儿」。
///
/// 本文件只做后半句：拿到一组预测位置，去图上找有没有对得上的、星表又解释不了
/// 的亮点。星历本身（那些轨道根数）在 `ephemeris.dart` 里，两边分开是为了让这条
/// 判据能脱离星历单独测——抄错一个根数和写错一个匹配半径是两种故障，混在一起
/// 会表现成同一种。

/// 星历预测的一个天体位置。
class PredictedBody {
  const PredictedBody({
    required this.name,
    required this.ra,
    required this.dec,
    this.distanceAu,
    this.discDiameterArcsec,
  });

  /// 中文名，直接给用户看（「木星」）。
  final String name;

  final double ra;
  final double dec;

  /// 地心距离，天文单位。报告里写「离地球 4.3 个天文单位」用。
  final double? distanceAu;

  /// 视直径，角秒。
  ///
  /// 目前恒为 null：算它需要各行星的赤道半径，那是另一份数据，同样不能凭记忆
  /// 写。判据也不该用它——星历误差和视直径是同一个量级，把它掺进判据只会让
  /// 结论同时依赖两个都在抖的量。留在字段里是给以后补上来源时用的。
  final double? discDiameterArcsec;
}

/// 星历位置和检出点之间允许多大的偏差。
///
/// 这个数不是「星历有多准」，是「星历有多不准」。出处那张近似根数表在
/// 1800–2050 区间内，内行星的位置误差可以到角分量级；再叠加解算本身带来的
/// 零点几角分的像素尺度误差，两角分是个留了余量又不至于把无关的星圈进来的数。
///
/// 放宽它的代价不对称：放宽只会让「亮点对上了」更容易成立，而判据的另一半
/// （这一带星表里没有星）拦住了绝大多数误报——一颗恒星要是正好在预测位置上，
/// 它自己就会被星表解释掉。所以这里宁可宽一点。
const double ephemerisToleranceArcmin = 2.0;

/// 检出至少要有多少置信度才够格被当成行星。
///
/// 和分析层里「值得展示」的门槛是同一个数：低于它的多半是噪声峰，拿噪声去
/// 宣称拍到了行星，比漏报难看得多。
const double _minimumConfidence = 0.25;

/// 容差换算成像素之后的下限。
///
/// 广角拼图上每像素十几个角分，两角分连一个像素都不到；那时容差就成了零，
/// 而检出位置的质心误差本身就有大半个像素。给个下限，让「对得上」这件事
/// 在粗尺度上仍然可能成立。
const double _minimumTolerancePixels = 3.0;

/// 在图上找出「星历说在这儿、星表又解释不了」的亮点。
///
/// [hasCatalogStarNear] 由调用方给：星表只在解算那一侧，这里不该知道它的形状。
/// 它的语义是「以 (ra, dec) 为中心、半径 [ephemerisToleranceArcmin] 角分内，
/// 星表里有没有一颗星」——有，就说明那颗亮点是恒星，不是行星。
///
/// 两个条件缺一不可，这是刻意的：只看「星表没星」会把噪声、坏点、被拉长的
/// 杂讯都算成行星；只看「位置对得上」会在满场恒星的密集天区里胡说八道。
List<MovingBodySuspicion> matchMovingBodies({
  required SkyAnalysis analysis,
  required Wcs wcs,
  required List<PredictedBody> predictions,
  required bool Function(double ra, double dec, double radiusArcmin)
      hasCatalogStarNear,
  double? magnitudeZeroPoint,
}) {
  if (predictions.isEmpty) return const [];
  final scale = wcs.arcsecPerPixel;
  if (!scale.isFinite || scale <= 0) return const [];

  // 只取一次 `compactSources`：它每读一次都要按轴比过滤一遍全部检出。
  final detections = [
    for (final star in analysis.compactSources)
      if (!star.isRejected && star.confidence >= _minimumConfidence) star,
  ];
  if (detections.isEmpty) return const [];

  final tolerancePixels = math.max(
    _minimumTolerancePixels,
    ephemerisToleranceArcmin * 60 / scale,
  );

  final findings = <MovingBodySuspicion>[];
  for (final body in predictions) {
    final (x, y) = wcs.worldToPixel(body.ra, body.dec);
    if (!x.isFinite || !y.isFinite) continue;
    // 画面外一个容差以外的天体看不见，无从判断。
    if (x < -tolerancePixels ||
        y < -tolerancePixels ||
        x > analysis.width + tolerancePixels ||
        y > analysis.height + tolerancePixels) {
      continue;
    }
    // 前一半判据：星表在这一带得有「没有星」这个结论。有星就收手。
    if (hasCatalogStarNear(body.ra, body.dec, ephemerisToleranceArcmin)) {
      continue;
    }

    DetectedStar? nearest;
    var nearestSquared = double.infinity;
    for (final star in detections) {
      final dx = star.x - x;
      final dy = star.y - y;
      final squared = dx * dx + dy * dy;
      if (squared < nearestSquared) {
        nearestSquared = squared;
        nearest = star;
      }
    }
    if (nearest == null) continue;
    final separationPixels = math.sqrt(nearestSquared);
    if (separationPixels > tolerancePixels) continue;

    findings.add(
      MovingBodySuspicion(
        name: body.name,
        ra: body.ra,
        dec: body.dec,
        x: nearest.x,
        y: nearest.y,
        separationArcsec: separationPixels * scale,
        // 没有星等零点就报 null，而不是报仪器星等：仪器星等是个没有绝对
        // 含义的数，用户拿它和「这颗比天狼星暗」之类的常识对不上。
        magnitude: magnitudeZeroPoint == null
            ? null
            : nearest.instrumentalMagnitude + magnitudeZeroPoint,
        distanceAu: body.distanceAu,
        discDiameterArcsec: body.discDiameterArcsec,
      ),
    );
  }
  return findings;
}
