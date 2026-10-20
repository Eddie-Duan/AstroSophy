import 'dart:math' as math;

import 'analysis.dart';

/// 星轨的粗略几何统计：轨迹数量、长度分布，以及所有轨迹延长线交汇的极心。
class StarTrailStats {
  const StarTrailStats({
    required this.centerX,
    required this.centerY,
    required this.count,
    required this.medianLength,
    required this.maxLength,
  });

  final double centerX;
  final double centerY;
  final int count;
  final double medianLength;
  final double maxLength;
}

/// 从已检出的拉长候选估计星轨中心。
///
/// 每条轨迹的长轴切线方向近似垂直于“轨迹到极心”的连线；把所有轨迹的
/// 法线做最小二乘交点，就是极心。轨迹太短、方向噪声大时误差会明显，
/// 所以只用较长的一批并做一次残差剔除。
StarTrailStats? analyzeStarTrails(SkyAnalysis analysis) {
  final trails = [
    for (final star in analysis.streakCandidates)
      if (!star.isRejected && star.axisRatio >= 2.2)
        (
          x: star.x,
          y: star.y,
          angle: star.orientation,
          length: math.max(1.0, star.fwhm * star.axisRatio),
        ),
  ];
  if (trails.length < 3) return null;
  trails.sort((a, b) => b.length.compareTo(a.length));
  final used = trails.take(math.min(120, trails.length)).toList();
  var center = _fitCenter(used);
  if (center == null) return null;

  // 第一次拟合后剔除法线距离最大的 25%，再拟合一次。
  final residuals = [
    for (final trail in used)
      (trail, _residual(trail, center)),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  final keep = residuals
      .take(math.max(3, (residuals.length * 0.75).round()))
      .map((item) => item.$1)
      .toList();
  center = _fitCenter(keep) ?? center;

  final lengths = [for (final trail in trails) trail.length]..sort();
  return StarTrailStats(
    centerX: center.$1,
    centerY: center.$2,
    count: trails.length,
    medianLength: lengths[lengths.length ~/ 2],
    maxLength: lengths.last,
  );
}

(double, double)? _fitCenter(
  List<({double x, double y, double angle, double length})> trails,
) {
  var a11 = 0.0;
  var a12 = 0.0;
  var a22 = 0.0;
  var b1 = 0.0;
  var b2 = 0.0;
  for (final trail in trails) {
    // 轨迹长轴是切线；从轨迹指向极心的连线垂直于切线，所以这里用切线
    // 方向作为“过极心那条直线”的法线。
    final nx = math.cos(trail.angle);
    final ny = math.sin(trail.angle);
    final weight = math.sqrt(trail.length);
    a11 += weight * nx * nx;
    a12 += weight * nx * ny;
    a22 += weight * ny * ny;
    b1 += weight * nx * (nx * trail.x + ny * trail.y);
    b2 += weight * ny * (nx * trail.x + ny * trail.y);
  }
  final det = a11 * a22 - a12 * a12;
  if (det.abs() < 1e-9) return null;
  final x = (b1 * a22 - b2 * a12) / det;
  final y = (a11 * b2 - a12 * b1) / det;
  if (!x.isFinite || !y.isFinite) return null;
  return (x, y);
}

double _residual(
  ({double x, double y, double angle, double length}) trail,
  (double, double) center,
) {
  final nx = math.cos(trail.angle);
  final ny = math.sin(trail.angle);
  return (nx * (center.$1 - trail.x) + ny * (center.$2 - trail.y)).abs();
}
