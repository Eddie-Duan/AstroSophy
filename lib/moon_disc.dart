import 'dart:math' as math;
import 'dart:typed_data';

/// 从一张照片里量出来的月面。
class MoonDisc {
  const MoonDisc({
    required this.centerX,
    required this.centerY,
    required this.radiusPixels,
    required this.litPixels,
    required this.frameArea,
  });

  /// 月盘圆心（图像像素坐标）。
  final double centerX;
  final double centerY;

  /// 月盘半径（像素）。
  final double radiusPixels;

  /// 被照亮的像素数。
  final int litPixels;

  final int frameArea;

  /// 亮面占比 k：亮面像素数除以整个月盘的面积。
  ///
  /// 这不是「亮的地方占画面的比例」，也不是对球面的近似——月面是球，投影到
  /// 画面上是个正圆，明暗界线投影成半个椭圆，亮面那块面积占整个圆的比**恰好
  /// 等于** k（即 `(1 + cos i)/2` 那个 k）。所以直接数像素就是准确的，不需要
  /// 先知道相位角。
  double get illuminatedFraction {
    final discArea = math.pi * radiusPixels * radiusPixels;
    if (discArea <= 0) return 0;
    return (litPixels / discArea).clamp(0.0, 1.0);
  }

  /// 月盘占画面的面积比例。用来判断「是不是一张以月亮为主的照片」。
  double get discAreaFraction {
    final frame = frameArea.toDouble();
    if (frame <= 0) return 0;
    return math.pi * radiusPixels * radiusPixels / frame;
  }

  Map<String, Object?> toJson() => {
        'center_x': centerX,
        'center_y': centerY,
        'radius_pixels': radiusPixels,
        'lit_pixels': litPixels,
        'frame_area': frameArea,
      };

  static MoonDisc fromJson(Map<String, Object?> json) => MoonDisc(
        centerX: _asDouble(json['center_x']),
        centerY: _asDouble(json['center_y']),
        radiusPixels: _asDouble(json['radius_pixels']),
        litPixels: (json['lit_pixels'] as num?)?.toInt() ?? 0,
        frameArea: (json['frame_area'] as num?)?.toInt() ?? 1,
      );
}

double _asDouble(Object? value) => value is num ? value.toDouble() : 0;

/// 量得出月面的最低门槛：亮面至少占画面这么多。
///
/// 低于它的多半是路灯、窗玻璃、被照亮的墙面——一个亮团，但不是月亮。
const double _minimumLitFraction = 0.0008;

/// 月面外缘至少要在最小外接圆的圆周上盖住这么多角度。
///
/// 月盘的外缘永远是一段完整的圆弧——月牙最细的时候也还有大半圈。所以「被照亮
/// 的那块，边缘有一大段正好贴在同一个圆的圆周上」才是月面区别于其它亮团的
/// 特征：路灯、窗玻璃、反光板也是个亮团，但它们的边缘不贴着一条圆弧；细长的
/// 东西则是外接圆比它自己大得多，圆周上基本什么都盖不到。
///
/// 不用「凸包面积 / 圆的面积」来判圆整：月牙的两个尖角比一个像素还细，栅格化
/// 之后那一截就没了，凸包因此比理论的半圆小一截（实测 k≈0.15 时是 0.42 而不是
/// 0.5）——那是个测量伪影，不该拿来当判据。
const double _minimumArcCoverage = 0.25;

/// 外缘在圆周上盖住了多少比例的角度（0–1）。
double _arcCoverage(List<(double, double)> boundary, _Circle disc) {
  const bins = 72;
  final covered = List<bool>.filled(bins, false);
  // 半径到这个倍数以上的边界点才算「贴在圆周上」；再松一点就会把圆内部
  // 那些噪声边界也算进来。
  final outer = disc.radius * 0.9;
  for (final point in boundary) {
    final dx = point.$1 - disc.x;
    final dy = point.$2 - disc.y;
    if (dx * dx + dy * dy < outer * outer) continue;
    var bin = ((math.atan2(dy, dx) + math.pi) / (2 * math.pi) * bins).floor();
    if (bin < 0) bin = 0;
    if (bin >= bins) bin = bins - 1;
    covered[bin] = true;
  }
  return covered.where((bin) => bin).length / bins;
}

/// 从灰度帧里量月面。量不出来返回 null。
///
/// ## 怎么量
///
/// 1. 取背景与峰值的中点作阈值，分出「被照亮的那部分」；
/// 2. 取最大的一块连通区域；
/// 3. 用它外缘的**最小外接圆**当作整个月盘。这一步是关键：月面无论盈亏，
///    外缘永远是月盘那个圆的一段弧，而两端（月牙的尖角）正好是一条直径的
///    两个端点，所以最小外接圆就是月盘本身——月牙、上下弦、凸月都成立；
/// 4. `亮面像素数 / 圆的面积` 就是亮面占比。
///
/// ## 误差在哪
///
/// 阈值把「刚好看得出比天空亮」当作界线，而真实的明暗界线是几何界线：界线附近
/// 有地形的起伏，曝光和溢出也会把亮面往外抹一点。所以这个数是**量出来的**，和
/// 从拍摄时刻算出来的那个（`lib/moon.dart`）互相校验，两个差得远时就说明其中
/// 有一个站不住，界面要把两个数都摆出来。
MoonDisc? measureMoonDisc({
  required Uint8List gray,
  required int width,
  required int height,
}) {
  if (width <= 0 || height <= 0 || gray.length < width * height) return null;
  final frameArea = width * height;

  // 分两遍走，因为「哪里是天空」和「哪里是亮面」互为前提：要定阈值得先知道
  // 天空有多亮，要知道天空在哪又得先把月盘大致圈出来。
  //
  // 第一遍：用一个够稳的粗阈值圈出月盘。月盘的外缘很亮，粗阈值一定落在它
  // 上面，所以这一步圈出来的圆是可靠的——这一遍定的是**圆**。
  final coarseLevel = _coarseLevel(gray);
  if (coarseLevel <= 0) return null;
  final disc = _fitDisc(gray, width, height, coarseLevel, frameArea);
  if (disc == null) return null;

  // 第二遍：用圆外的天空估出背景与噪声，把阈值定在「刚好看得出比天空亮」，
  // 再数一遍圆里有多少像素在它之上——这一遍定的是**亮面占比**。
  //
  // 这一遍刻意**不重新拟合圆**。低阈值会把月面周围那圈光晕也收进亮面里，
  // 亮斑和月盘连成一片，形状就不再是个干净的圆盘，最小外接圆会跟着膨胀
  // （实测直接退化成「认不出这是个月面」）。圆交给第一遍定，这一遍只负责数
  // 像素，两件事各用各的阈值，互不干扰。
  final level = _litLevel(gray, width, height, disc);
  if (level <= 0) return null;
  final lit = _litPixelsInside(gray, width, height, disc, level);

  return MoonDisc(
    centerX: disc.x,
    centerY: disc.y,
    radiusPixels: disc.radius,
    litPixels: lit,
    frameArea: frameArea,
  );
}

/// 圆内有这么多像素在阈值之上。
int _litPixelsInside(
  Uint8List gray,
  int width,
  int height,
  _Circle disc,
  double level,
) {
  final discSq = disc.radius * disc.radius;
  var lit = 0;
  for (var y = 0; y < height; y++) {
    final dy = y - disc.y;
    for (var x = 0; x < width; x++) {
      final dx = x - disc.x;
      if (dx * dx + dy * dy > discSq) continue;
      if (gray[y * width + x] >= level) lit++;
    }
  }
  return lit;
}

/// 阈值 → 亮面掩码 → 最大连通块（外扩一圈合并碎块）→ 凸包 → 最小外接圆。
///
/// 返回 null 表示这个阈值下画面里没有一块像个圆盘的亮面。
_Circle? _fitDisc(
  Uint8List gray,
  int width,
  int height,
  double level,
  int frameArea,
) {
  final mask = Uint8List(width * height);
  var lit = 0;
  for (var i = 0; i < mask.length; i++) {
    // gray 是 0–255 的灰度。
    if (gray[i] >= level) {
      mask[i] = 1;
      lit++;
    }
  }
  if (lit < frameArea * _minimumLitFraction) return null;

  final regions = _regions(mask, width, height)
    ..sort((a, b) => b.length.compareTo(a.length));
  _Circle? best;
  var bestScore = 0.0;
  for (final largest in regions.take(24)) {
    if (largest.length < frameArea * _minimumLitFraction) continue;

    // 月牙的两个尖角比一个像素还细，栅格化之后会断成孤立的小块。只取最大那
    // 一块，等于把钉住圆心的两个尖角扔掉了：实测 k=0.15 时圆心会偏出 13 像素，
    // 画出来的圈就落在月亮旁边。所以把候选块外扩一圈，连同这些碎块一起收进来
    // （外扩的那点范围里若有孤立的星点，面积小到可以忽略）。
    final region = _regionWithin(largest, mask, width, height, _regionMargin);
    if (region.length < frameArea * _minimumLitFraction) continue;

    final boundary = _boundaryOf(mask, width, height, region);
    final hull = _convexHull(boundary);
    if (hull.length < 3) continue;

    final disc = _minEnclosingCircle(hull);
    if (disc.radius <= 0) continue;

    final arc = _arcCoverage(boundary, disc);
    if (arc < _minimumArcCoverage) continue;
    final fill = largest.length / (math.pi * disc.radius * disc.radius);
    if (fill < 0.12 || fill > 1.25) continue;
    // 圆形亮面优先；细长的栏杆灯带、连成一片的桥灯会被圆弧覆盖率和填充率压下去。
    final score = arc * 0.7 + fill.clamp(0.0, 1.0) * 0.3;
    if (score > bestScore) {
      bestScore = score;
      best = disc;
    }
  }
  return best;
}

/// 所有 8 邻域连通块。
List<List<int>> _regions(Uint8List mask, int width, int height) {
  final visited = Uint8List(mask.length);
  final stack = <int>[];
  final regions = <List<int>>[];
  for (var start = 0; start < mask.length; start++) {
    if (mask[start] == 0 || visited[start] == 1) continue;
    final region = <int>[];
    stack
      ..clear()
      ..add(start);
    visited[start] = 1;
    while (stack.isNotEmpty) {
      final index = stack.removeLast();
      region.add(index);
      final x = index % width;
      final y = index ~/ width;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
          final next = ny * width + nx;
          if (mask[next] == 0 || visited[next] == 1) continue;
          visited[next] = 1;
          stack.add(next);
        }
      }
    }
    regions.add(region);
  }
  return regions;
}

/// 粗阈值取「背景与峰值的中点」。只用来圈个大概，精度无所谓。
///
/// 背景取**第 10 百分位**而不是中位数：满月占满画面时，中位数本身就落在月面
/// 上，参照会算成「月面与月面的中点」而失去意义。取低百分位则只要还有一成
/// 天空可见，参照就还在。
double _coarseLevel(Uint8List gray) {
  final histogram = List<int>.filled(256, 0);
  for (final value in gray) {
    histogram[value]++;
  }
  final target = gray.length ~/ 10;
  var background = 0;
  var seen = 0;
  for (var value = 0; value < 256; value++) {
    seen += histogram[value];
    if (seen >= target) {
      background = value;
      break;
    }
  }
  var peak = 255;
  for (var value = 255; value >= 0; value--) {
    if (histogram[value] > 0) {
      peak = value;
      break;
    }
  }
  // 整幅都是亮的（月面占满画面、没有天空作参照）：没有背景可比，量不出亮面
  // 占比。返回 0 让调用方收手，而不是硬编一个阈值出来。
  if (peak - background < 20) return 0;
  return background + (peak - background) * 0.5;
}

/// 天空的统计量：月盘外那一圈像素的均值与标准差，外加月盘内最亮值。
class _Sky {
  const _Sky(this.mean, this.sigma, this.peak);

  final double mean;
  final double sigma;
  final double peak;
}

/// 月盘外至少要留出这么多像素才算估得出天空。
const int _minimumSkyPixels = 64;

/// 天空这一圈留在月盘外的多远：半径的这么多倍再加几个像素。
const double _skyMargin = 1.15;

/// 估天空。返回 null 表示月盘外几乎没有像素（满月占满画面），估不出来。
_Sky? _skyAround(
  Uint8List gray,
  int width,
  int height,
  _Circle disc,
) {
  final outer = disc.radius * _skyMargin + 4;
  final outerSq = outer * outer;
  final discSq = disc.radius * disc.radius;
  var sum = 0.0;
  var sumSq = 0.0;
  var peak = 0.0;
  var count = 0;
  for (var y = 0; y < height; y++) {
    final dy = y - disc.y;
    for (var x = 0; x < width; x++) {
      final dx = x - disc.x;
      final d2 = dx * dx + dy * dy;
      final value = gray[y * width + x].toDouble();
      if (d2 > outerSq) {
        sum += value;
        sumSq += value * value;
        count++;
      } else if (d2 <= discSq && value > peak) {
        // 峰值只在月盘里找：画面别处的一颗亮星不该抬高下面的下限。
        peak = value;
      }
    }
  }
  if (count < _minimumSkyPixels) return null;
  final mean = sum / count;
  final variance = sumSq / count - mean * mean;
  return _Sky(mean, variance > 0 ? math.sqrt(variance) : 0, peak);
}

/// 亮面判定要高出天空多少个标准差。
const double _sigmaAboveSky = 2.0;

/// 判阈值的下限：至少要高过背景这么多比例的动态范围。
///
/// 合成图那种天空完全无噪声（σ=0）的情形全靠它兜底，否则阈值会退化成
/// 「背景本身」，整幅画面都算亮面。
const double _minimumLevelFraction = 0.02;

/// 亮面的判定阈值：天空均值加 [_sigmaAboveSky] 个标准差。
///
/// 定在「刚好看得出比天空亮」，不是「亮度减半」。明暗界线是光照趋近于零的
/// 地方，月面在界线附近是掠射照明，亮度天然很低，但确实被照亮着——拿峰值的
/// 一半当门槛，会把整条界线过渡带判成暗面。
///
/// 这个结论是实测逼出来的：一张 2026-06-25 的月球照，用一半峰值量出 60.8%，
/// 而同一时刻的星历（Meeus 48.4）说 82.6%。把阈值扫一遍看清楚了（这张图上
/// 天空实测 均值 40.3、σ 1.07，盘内峰值 204，月盘半径 45.3 px）：
///
/// | 阈值 | 量出的亮面占比 |
/// |---|---|
/// | 天空 + 1σ | 86.7% |
/// | 天空 + 2σ | 86.4% |
/// | 天空 + 3σ | 86.1% |
/// | 天空 + 4σ | 85.8% |
/// | 峰值 5%   | 85.1% |
/// | 峰值 10%  | 82.9% |
/// | 峰值 25%  | 76.3% |
/// | 峰值 50%  | 60.8% |
///
/// 用 σ 说话的好处有两条。一是结果落在 1σ–4σ 这么宽的一段平台上（86.7% →
/// 85.8%，一共才动 0.9 个百分点），说明这个数不敏感于阈值取哪个具体值；而按
/// 峰值比例走，阈值从 10% 挪到 50% 结果就跟着掉 22 个百分点，那等于把结论
/// 建立在一个随手挑的数字上。二是它**自校准**：亮一些、暗一些、增益不一样
/// 的相机，天空的噪声水平跟着变，阈值自己会跟上，不必按每张图为它调参数。
///
/// 下限 [_minimumLevelFraction] 是给合成图那种天空完全无噪声（σ = 0）的情形
/// 兜底的，否则阈值会退化成「天空本身」，整幅画面都算亮面。
double _litLevel(Uint8List gray, int width, int height, _Circle disc) {
  final sky = _skyAround(gray, width, height, disc);
  if (sky == null) return 0;
  final floor = (sky.peak - sky.mean) * _minimumLevelFraction;
  final margin = math.max(_sigmaAboveSky * sky.sigma, floor);
  if (margin <= 0) return 0;
  return sky.mean + margin;
}

/// 最大块往外扩多少像素去找那些碎块。
///
/// 尖角那一带的亮面每往上一行就横移好几个像素，所以外扩得比 1 大一点才够得着；
/// 8 像素既足以把尖角收回来，又不至于把画面里别的亮东西卷进来。
const int _regionMargin = 8;

/// 最大块，外加它外扩 [_regionMargin] 像素范围里所有被照亮的像素。
List<int> _regionWithin(
  List<int> largest,
  Uint8List mask,
  int width,
  int height,
  int margin,
) {
  var minX = width;
  var maxX = -1;
  var minY = height;
  var maxY = -1;
  for (final index in largest) {
    final x = index % width;
    final y = index ~/ width;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  minX = math.max(0, minX - margin);
  minY = math.max(0, minY - margin);
  maxX = math.min(width - 1, maxX + margin);
  maxY = math.min(height - 1, maxY + margin);

  final region = <int>[];
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      final index = y * width + x;
      if (mask[index] == 1) region.add(index);
    }
  }
  return region;
}

/// 区域的边缘像素坐标（四周有一个像素不属于区域就算边缘）。
List<(double, double)> _boundaryOf(
  Uint8List mask,
  int width,
  int height,
  List<int> region,
) {
  final inRegion = Uint8List(mask.length);
  for (final index in region) {
    inRegion[index] = 1;
  }
  final points = <(double, double)>[];
  for (final index in region) {
    final x = index % width;
    final y = index ~/ width;
    var edge = false;
    for (var dy = -1; dy <= 1 && !edge; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
        if (inRegion[ny * width + nx] == 0) {
          edge = true;
          break;
        }
      }
    }
    if (edge) points.add((x.toDouble(), y.toDouble()));
  }
  return points;
}

/// 凸包（Andrew 单调链）。
List<(double, double)> _convexHull(List<(double, double)> points) {
  if (points.length < 3) return points;
  final sorted = [...points]
    ..sort((a, b) => a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
  double cross((double, double) o, (double, double) a, (double, double) b) =>
      (a.$1 - o.$1) * (b.$2 - o.$2) - (a.$2 - o.$2) * (b.$1 - o.$1);

  final lower = <(double, double)>[];
  for (final point in sorted) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <(double, double)>[];
  for (final point in sorted.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

class _Circle {
  const _Circle(this.x, this.y, this.radius);

  final double x;
  final double y;
  final double radius;
}

/// 最小外接圆（Welzl）。
///
/// 先洗牌：这个算法在最坏情况下是三次方，洗过之后期望是线性的。种子写死是
/// 为了让同一张图每次给出同一个圆——测出来的东西必须是可复现的。
_Circle _minEnclosingCircle(List<(double, double)> points) {
  final shuffled = [...points]..shuffle(math.Random(20260918));
  var circle = _Circle(shuffled.first.$1, shuffled.first.$2, 0);
  for (var i = 0; i < shuffled.length; i++) {
    if (_inside(circle, shuffled[i])) continue;
    final p = shuffled[i];
    circle = _Circle(p.$1, p.$2, 0);
    for (var j = 0; j < i; j++) {
      final q = shuffled[j];
      if (_inside(circle, q)) continue;
      circle = _fromTwo(p, q);
      for (var k = 0; k < j; k++) {
        final r = shuffled[k];
        if (_inside(circle, r)) continue;
        circle = _fromThree(p, q, r) ?? _fromTwo(p, q);
      }
    }
  }
  return circle;
}

bool _inside(_Circle circle, (double, double) point) {
  final dx = point.$1 - circle.x;
  final dy = point.$2 - circle.y;
  // 留一点容差：浮点误差会让本该在线上的点判成在外面，多走一圈。
  return dx * dx + dy * dy <= (circle.radius + 1e-9) * (circle.radius + 1e-9);
}

_Circle _fromTwo((double, double) a, (double, double) b) {
  final x = (a.$1 + b.$1) / 2;
  final y = (a.$2 + b.$2) / 2;
  return _Circle(x, y, math.sqrt(math.pow(a.$1 - x, 2) + math.pow(a.$2 - y, 2)));
}

/// 三点定圆。三点共线时返回 null——没有有限半径的圆过它们。
_Circle? _fromThree((double, double) a, (double, double) b, (double, double) c) {
  final d = 2 *
      (a.$1 * (b.$2 - c.$2) + b.$1 * (c.$2 - a.$2) + c.$1 * (a.$2 - b.$2));
  if (d.abs() < 1e-12) return null;
  final a2 = a.$1 * a.$1 + a.$2 * a.$2;
  final b2 = b.$1 * b.$1 + b.$2 * b.$2;
  final c2 = c.$1 * c.$1 + c.$2 * c.$2;
  final x = (a2 * (b.$2 - c.$2) + b2 * (c.$2 - a.$2) + c2 * (a.$2 - b.$2)) / d;
  final y = (a2 * (c.$1 - b.$1) + b2 * (a.$1 - c.$1) + c2 * (b.$1 - a.$1)) / d;
  return _Circle(x, y, math.sqrt(math.pow(a.$1 - x, 2) + math.pow(a.$2 - y, 2)));
}
