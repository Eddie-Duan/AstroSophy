import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'live_sky.dart';

/// 相机帧里检出的一个亮点，坐标是**传感器帧**归一化后的 0–1。
class LiveStarDetection {
  const LiveStarDetection(this.x, this.y, this.brightness);

  final double x;
  final double y;
  final double brightness;
}

/// 用画面里的星点修正 IMU 姿态的结果。
class LiveOrientationFix {
  const LiveOrientationFix({
    required this.yawDegrees,
    required this.pitchDegrees,
    required this.rollDegrees,
    required this.matches,
    required this.rotation,
    required this.residual,
    required this.matchedHips,
  });

  final double yawDegrees;
  final double pitchDegrees;
  final double rollDegrees;
  final int matches;

  /// 传感器帧到预览画面的旋转档位（0–3 个 90°）。
  final int rotation;

  /// 匹配点的平均残差（归一化画面宽度）。越小越可信。
  final double residual;

  /// 这一轮真正对上的星表 HIP 编号；锁定后只跟踪这几颗。
  final Set<int> matchedHips;
}

/// 实时星图的视觉辅助：在相机帧里找亮点，和当前姿态投影下来的星表比。
///
/// 它不追求“盲解”——IMU 已经给出一个不错的初值，这里只做小角度修正。
/// 因此可以用很轻的检测和匹配，在手机上每 200–300 ms 跑一次。
class LiveStarTracker {
  /// 从 YUV 的 Y 平面里找局部极大值。
  ///
  /// [rowStride] 是每行字节数，可能比 [width] 大（相机常带行尾填充）。
  static List<LiveStarDetection> detect(
    Uint8List yPlane,
    int width,
    int height,
    int rowStride, {
    int maxStars = 80,
  }) {
    if (width < 32 || height < 32 || rowStride < width) return const [];
    final step = math.max(2, width ~/ 320);
    final cols = width ~/ step;
    final rows = height ~/ step;
    if (cols < 8 || rows < 8) return const [];

    final values = Float32List(cols * rows);
    var sum = 0.0;
    var sumSq = 0.0;
    var count = 0;
    for (var row = 0; row < rows; row++) {
      final py = row * step;
      final base = py * rowStride;
      for (var col = 0; col < cols; col++) {
        final value = yPlane[base + col * step] / 255.0;
        values[row * cols + col] = value;
        sum += value;
        sumSq += value * value;
        count++;
      }
    }
    final mean = sum / count;
    final variance = math.max(0.0, sumSq / count - mean * mean);
    final sigma = math.sqrt(variance);
    final threshold = math.max(mean + 4.5 * sigma, 0.10);

    final candidates = <(int, int, double)>[];
    for (var row = 1; row < rows - 1; row++) {
      for (var col = 1; col < cols - 1; col++) {
        final value = values[row * cols + col];
        if (value < threshold) continue;
        if (value < values[(row - 1) * cols + col] ||
            value < values[(row + 1) * cols + col] ||
            value < values[row * cols + col - 1] ||
            value < values[row * cols + col + 1]) {
          continue;
        }
        candidates.add((col, row, value));
      }
    }
    candidates.sort((a, b) => b.$3.compareTo(a.$3));

    final picked = <LiveStarDetection>[];
    for (final candidate in candidates) {
      if (picked.length >= maxStars) break;
      final px = candidate.$1 * step;
      final py = candidate.$2 * step;
      var tooClose = false;
      for (final existing in picked) {
        final dx = existing.x * width - px;
        final dy = existing.y * height - py;
        if (dx * dx + dy * dy < 36) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      // 在 5×5 采样邻域里做亮度加权重心，比直接取极大值像素稳。
      var weight = 0.0;
      var wx = 0.0;
      var wy = 0.0;
      for (var dy = -2; dy <= 2; dy++) {
        final row = candidate.$2 + dy;
        if (row < 0 || row >= rows) continue;
        for (var dx = -2; dx <= 2; dx++) {
          final col = candidate.$1 + dx;
          if (col < 0 || col >= cols) continue;
          final value = values[row * cols + col];
          final v = value - mean;
          if (v <= 0) continue;
          weight += v;
          wx += v * (col * step);
          wy += v * (row * step);
        }
      }
      final x = weight > 0 ? wx / weight / width : px / width;
      final yy = weight > 0 ? wy / weight / height : py / height;
      picked.add(
        LiveStarDetection(
          x.clamp(0.0, 1.0),
          yy.clamp(0.0, 1.0),
          candidate.$3,
        ),
      );
    }
    return picked;
  }

  /// 把检测到的星点和星表投影比对，估计 yaw/pitch/roll 小修正。
  ///
  /// 返回 null 表示匹配不够，宁可继续用 IMU，也不要瞎修。
  static LiveOrientationFix? solve({
    required List<LiveStarDetection> detections,
    required List<LiveEnuObject> stars,
    required LiveCameraBasis basis,
    required double fieldOfViewDegrees,
    required double previewAspect,
    int minimumMatches = 6,
    int? rotation,
    double magnitudeLimit = 6.4,
  }) {
    if (detections.length < 3 || stars.isEmpty) return null;
    final viewport = Size(1, previewAspect);
    final projected = <(Offset, LiveObject)>[];
    for (final star in stars) {
      if (star.object.magnitude > magnitudeLimit) continue;
      final point = basis.project(
        star.enu,
        horizontalFovDegrees: fieldOfViewDegrees,
        viewport: viewport,
        margin: 0,
      );
      if (point == null) continue;
      projected.add((point, star.object));
    }
    if (projected.length < minimumMatches) return null;

    var bestRotation = 0;
    var bestScore = -1.0;
    var bestMatched = 0;
    var bestResidual = 1.0;
    var bestHips = <int>{};
    for (final rotationIndex in rotation == null
        ? const [0, 1, 2, 3]
        : [rotation]) {
      final matched = _match(
        detections,
        projected,
        previewAspect,
        rotationIndex,
      );
      if (matched.score > bestScore) {
        bestScore = matched.score;
        bestRotation = rotationIndex;
        bestMatched = matched.count;
        bestResidual = matched.residual;
        bestHips = matched.hips;
      }
    }
    if (bestMatched < minimumMatches) return null;

    var yaw = 0.0;
    var pitch = 0.0;
    var roll = 0.0;
    var score = bestScore;
    // 坐标下降足够用：三个小角度、每次只试正负一步。比数值 Jacobian 稳，
    // 也不会因为一两个错配把整个姿态带飞。
    for (final step in const [2.0, 0.7, 0.2]) {
      for (final axis in const [0, 1, 2]) {
        for (final sign in const [1.0, -1.0]) {
          final candidateYaw = yaw + (axis == 0 ? sign * step : 0);
          final candidatePitch = pitch + (axis == 1 ? sign * step : 0);
          final candidateRoll = roll + (axis == 2 ? sign * step : 0);
          final candidateBasis = basis.corrected(
            yawDegrees: candidateYaw,
            pitchDegrees: candidatePitch,
            rollDegrees: candidateRoll,
          );
          final candidateProjected = <(Offset, LiveObject)>[];
          for (final star in stars) {
            if (star.object.magnitude > magnitudeLimit) continue;
            final point = candidateBasis.project(
              star.enu,
              horizontalFovDegrees: fieldOfViewDegrees,
              viewport: viewport,
              margin: 0,
            );
            if (point == null) continue;
            candidateProjected.add((point, star.object));
          }
          final matched = _match(
            detections,
            candidateProjected,
            previewAspect,
            bestRotation,
          );
          if (matched.score > score) {
            score = matched.score;
            bestMatched = matched.count;
            bestResidual = matched.residual;
            bestHips = matched.hips;
            yaw = candidateYaw;
            pitch = candidatePitch;
            roll = candidateRoll;
          }
        }
      }
    }
    if (bestMatched < minimumMatches) return null;
    return LiveOrientationFix(
      yawDegrees: yaw,
      pitchDegrees: pitch,
      rollDegrees: roll,
      matches: bestMatched,
      rotation: bestRotation,
      residual: bestResidual,
      matchedHips: bestHips,
    );
  }

  static ({int count, double score, double residual, Set<int> hips}) _match(
    List<LiveStarDetection> detections,
    List<(Offset, LiveObject)> projected,
    double previewAspect,
    int rotation,
  ) {
    final transformed = <Offset>[];
    for (final detection in detections) {
      final u = detection.x;
      final v = detection.y;
      final Offset point;
      switch (rotation) {
        case 0:
          point = Offset(u, v * previewAspect);
        case 1:
          point = Offset(1 - v, u * previewAspect);
        case 2:
          point = Offset(1 - u, (1 - v) * previewAspect);
        default:
          point = Offset(v, (1 - u) * previewAspect);
      }
      transformed.add(point);
    }
    const tolerance = 0.045;
    var count = 0;
    var residual = 0.0;
    final used = <int>{};
    final hips = <int>{};
    for (final detection in transformed) {
      var bestDistance = tolerance;
      var bestIndex = -1;
      for (var index = 0; index < projected.length; index++) {
        if (used.contains(index)) continue;
        final distance = (projected[index].$1 - detection).distance;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = index;
        }
      }
      if (bestIndex >= 0) {
        used.add(bestIndex);
        count++;
        residual += bestDistance;
        final hip = projected[bestIndex].$2.hip;
        if (hip != null) hips.add(hip);
      }
    }
    final mean = count == 0 ? 1.0 : residual / count;
    return (count: count, score: count - mean * 8, residual: mean, hips: hips);
  }
}
