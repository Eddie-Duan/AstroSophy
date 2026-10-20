import 'dart:math' as math;
import 'dart:typed_data';

/// 太阳圆盘的几何与黑子统计。
///
/// 太阳和月亮一样，是“整张照片的主体”，不该再进星点/深空那条链路。
class SunDisc {
  const SunDisc({
    required this.centerX,
    required this.centerY,
    required this.radiusPixels,
    required this.frameArea,
    required this.darkSpotCount,
    required this.darkSpotArea,
  });

  final double centerX;
  final double centerY;
  final double radiusPixels;
  final int frameArea;
  final int darkSpotCount;
  final int darkSpotArea;

  double get discAreaFraction =>
      math.pi * radiusPixels * radiusPixels / frameArea;

  double get darkSpotAreaFraction =>
      discAreaFraction <= 0 ? 0 : darkSpotArea / frameArea / discAreaFraction;

  Map<String, Object?> toJson() => {
        'center_x': centerX,
        'center_y': centerY,
        'radius_pixels': radiusPixels,
        'frame_area': frameArea,
        'dark_spot_count': darkSpotCount,
        'dark_spot_area': darkSpotArea,
      };

  static SunDisc fromJson(Map<String, Object?> json) => SunDisc(
        centerX: (json['center_x'] as num?)?.toDouble() ?? 0,
        centerY: (json['center_y'] as num?)?.toDouble() ?? 0,
        radiusPixels: (json['radius_pixels'] as num?)?.toDouble() ?? 0,
        frameArea: (json['frame_area'] as num?)?.toInt() ?? 0,
        darkSpotCount: (json['dark_spot_count'] as num?)?.toInt() ?? 0,
        darkSpotArea: (json['dark_spot_area'] as num?)?.toInt() ?? 0,
      );
}

/// 在一张已经降采样、转灰度的照片里找太阳圆盘。
///
/// 用“亮阈值 + 最大连通域 + 圆度/填充率”而不是月亮那套相位判据：
/// 太阳在白光里几乎是满圆，月面那套“亮面占比”对它没有意义。
SunDisc? measureSunDisc({
  required Uint8List gray,
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0 || gray.length < width * height) return null;
  var maxValue = 0;
  for (final value in gray) {
    if (value > maxValue) maxValue = value;
  }
  if (maxValue < 40) return null;
  // 不能拿全图最大值定阈值：Seestar 这类照片底部有白色文字/UI，最大值是
  // 255，会把橙色日面挡在阈值下面。用 35% 起步，再靠最大连通域和圆度筛选。
  final threshold = math.max(40, (maxValue * 0.22).round());

  final visited = Uint8List(width * height);
  final stack = <int>[];
  var bestArea = 0;
  var bestMinX = 0;
  var bestMaxX = 0;
  var bestMinY = 0;
  var bestMaxY = 0;
  var bestSumX = 0.0;
  var bestSumY = 0.0;

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final start = y * width + x;
      if (visited[start] != 0 || gray[start] < threshold) continue;
      visited[start] = 1;
      stack.add(start);
      var area = 0;
      var minX = x;
      var maxX = x;
      var minY = y;
      var maxY = y;
      var sumX = 0.0;
      var sumY = 0.0;
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        final px = index % width;
        final py = index ~/ width;
        area++;
        sumX += px;
        sumY += py;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (py < minY) minY = py;
        if (py > maxY) maxY = py;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = py + dy;
          if (ny < 0 || ny >= height) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = px + dx;
            if (nx < 0 || nx >= width) continue;
            final next = ny * width + nx;
            if (visited[next] != 0 || gray[next] < threshold) continue;
            visited[next] = 1;
            stack.add(next);
          }
        }
      }
      if (area > bestArea) {
        bestArea = area;
        bestMinX = minX;
        bestMaxX = maxX;
        bestMinY = minY;
        bestMaxY = maxY;
        bestSumX = sumX;
        bestSumY = sumY;
      }
    }
  }

  if (bestArea < width * height * 0.004) return null;
  final boxWidth = bestMaxX - bestMinX + 1;
  final boxHeight = bestMaxY - bestMinY + 1;
  if (boxWidth < 16 || boxHeight < 16) return null;
  final aspect = boxWidth / boxHeight;
  if (aspect < 0.55 || aspect > 1.8) return null;
  final fill = bestArea / (boxWidth * boxHeight);
  if (fill < 0.45) return null;

  final cx = bestSumX / bestArea;
  final cy = bestSumY / bestArea;
  final radius = (boxWidth + boxHeight) / 4;
  if (radius < math.min(width, height) * 0.03) return null;

  // 黑子：盘内亮度明显低于盘中位数的小连通块。先算盘内中位数，避免把临边
  // 昏暗当成黑子。
  final values = <int>[];
  final limit = radius * 0.82;
  final limitSq = limit * limit;
  for (var y = 0; y < height; y++) {
    final dy = y - cy;
    for (var x = 0; x < width; x++) {
      final dx = x - cx;
      if (dx * dx + dy * dy > limitSq) continue;
      values.add(gray[y * width + x]);
    }
  }
  if (values.isEmpty) return null;
  values.sort();
  final median = values[values.length ~/ 2];
  final spotThreshold = (median * 0.78).round().clamp(0, 255);

  final spotSeen = Uint8List(width * height);
  var spotCount = 0;
  var spotArea = 0;
  for (var y = 0; y < height; y++) {
    final dy = y - cy;
    for (var x = 0; x < width; x++) {
      final dx = x - cx;
      if (dx * dx + dy * dy > limitSq) continue;
      final start = y * width + x;
      if (spotSeen[start] != 0 || gray[start] >= spotThreshold) continue;
      spotSeen[start] = 1;
      stack.add(start);
      var area = 0;
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        final px = index % width;
        final py = index ~/ width;
        if ((px - cx) * (px - cx) + (py - cy) * (py - cy) > limitSq) {
          continue;
        }
        area++;
        for (var sy = -1; sy <= 1; sy++) {
          final ny = py + sy;
          if (ny < 0 || ny >= height) continue;
          for (var sx = -1; sx <= 1; sx++) {
            final nx = px + sx;
            if (nx < 0 || nx >= width) continue;
            final next = ny * width + nx;
            if (spotSeen[next] != 0 || gray[next] >= spotThreshold) continue;
            if ((nx - cx) * (nx - cx) + (ny - cy) * (ny - cy) > limitSq) {
              continue;
            }
            spotSeen[next] = 1;
            stack.add(next);
          }
        }
      }
      if (area >= 4) {
        spotCount++;
        spotArea += area;
      }
    }
  }

  return SunDisc(
    centerX: cx,
    centerY: cy,
    radiusPixels: radius,
    frameArea: width * height,
    darkSpotCount: spotCount,
    darkSpotArea: spotArea,
  );
}
