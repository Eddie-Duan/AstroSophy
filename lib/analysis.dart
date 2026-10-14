import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;

import 'models.dart';

/// 图像分析层：解码、星点检测、非星空掩膜、孔径测光和处理图生成。
///
/// 这一层不依赖 Flutter UI，整个 [SkyAnalysis.analyze] 可以在独立 isolate 里跑。
/// 算法刻意做成“先分类、再测量”，因为面向的是随手拍的手机照片：画面里经常有
/// 文字、表格、地面景物和路灯，直接按阈值取亮点会大面积误检。

/// 判定为非星空的区域类型，UI 上用来区分提示措辞。
enum MaskKind {
  /// 面积远超星点的大亮斑：月亮、路灯、被照亮的建筑。
  blob,

  /// 密集且亮度高度一致的小结构：屏幕或照片上的文字。
  text,

  /// 细长的非直线感结构：表格边框、电缆、栏杆。
  line,
}

/// 一块被判为非星空的矩形区域（图像像素坐标）。
class MaskRegion {
  const MaskRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.kind,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final MaskKind kind;

  double get area => width * height;

  Map<String, Object?> toJson() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'kind': kind.name,
      };

  static MaskRegion fromJson(Map<String, Object?> json) => MaskRegion(
        x: _asDouble(json['x']),
        y: _asDouble(json['y']),
        width: _asDouble(json['width']),
        height: _asDouble(json['height']),
        kind: MaskKind.values.firstWhere(
          (value) => value.name == json['kind'],
          orElse: () => MaskKind.blob,
        ),
      );
}

/// 一次本地分析的完整结果。
class SkyAnalysis {
  const SkyAnalysis({
    required this.width,
    required this.height,
    required this.stars,
    required this.quality,
    required this.background,
    required this.noise,
    required this.backgroundIndex,
    required this.saturatedFraction,
    required this.diagnostics,
    required this.preview,
    required this.processedPreview,
    required this.fwhm,
    required this.nonStarFraction,
    required this.maskRegions,
    required this.isLikelyStarfield,
    required this.starfieldConfidence,
    required this.flatAreaFraction,
  });

  final int width;
  final int height;

  /// 全部检出对象，包含紧凑点源、拉长候选和用户已剔除的项。
  final List<DetectedStar> stars;

  final String quality;
  final double background;
  final double noise;
  final double backgroundIndex;
  final double saturatedFraction;
  final List<String> diagnostics;

  /// 供上传和显示用的预览图（缩放后的原图）。
  final Uint8List preview;

  /// 处理图：扣除天空背景、按反双曲正弦拉伸、并抹掉非星空区域，只留下星场。
  final Uint8List processedPreview;

  /// 全帧统计出的点扩散函数半高全宽（像素），用来判断对焦、给测光定孔径。
  final double fwhm;

  /// 被判为非星空的像素占比。
  final double nonStarFraction;

  /// 非星空区域清单，UI 用来画掩膜和解释原因。
  final List<MaskRegion> maskRegions;

  /// 这张图整体看起来是不是星空照片。
  final bool isLikelyStarfield;

  /// 星空判定的置信度（0–1），低的时候 UI 要明确提示“可能不是星空照片”。
  final double starfieldConfidence;

  /// 近乎平坦（没有噪声起伏）的像素占比。截图、纯色背景会非常高。
  final double flatAreaFraction;

  /// 参与星表匹配和测光的紧凑点源（排除拉长候选和用户剔除项）。
  List<DetectedStar> get compactSources => stars
      .where((star) => !star.isElongated && !star.isRejected)
      .toList(growable: false);

  /// 全部紧凑点源，含被用户剔除的，供列表完整展示。
  List<DetectedStar> get allCompactSources =>
      stars.where((star) => !star.isElongated).toList(growable: false);

  /// 拉长候选：可能是拖线、卫星/飞机轨迹、失焦或伪影。
  List<DetectedStar> get streakCandidates =>
      stars.where((star) => star.isElongated).toList(growable: false);

  /// 按亮度排序的紧凑点源，序号从 1 开始，与 UI 列表和图上编号一一对应。
  List<DetectedStar> get rankedCompactSources => _rank(allCompactSources);

  List<DetectedStar> get rankedStreakCandidates => _rank(streakCandidates);

  /// 图上所有会显示编号的对象，编号顺序与 [numberedTargets] 完全一致。
  List<DetectedStar> get numberedTargets => [
        ...rankedCompactSources,
        ...rankedStreakCandidates,
      ];

  List<DetectedStar> _rank(List<DetectedStar> source) =>
      source.toList(growable: false)
        ..sort((a, b) => a.instrumentalMagnitude.compareTo(b.instrumentalMagnitude));

  /// 标记/取消标记某个拉长候选，返回新结果（列表本身不可变）。
  SkyAnalysis withRejection(DetectedStar target, bool rejected) => copyWith(
        stars: stars
            .map(
              (star) => _sameSource(star, target)
                  ? star.copyWith(isRejected: rejected)
                  : star,
            )
            .toList(growable: false),
      );

  SkyAnalysis copyWith({List<DetectedStar>? stars}) => SkyAnalysis(
        width: width,
        height: height,
        stars: stars ?? this.stars,
        quality: quality,
        background: background,
        noise: noise,
        backgroundIndex: backgroundIndex,
        saturatedFraction: saturatedFraction,
        diagnostics: diagnostics,
        preview: preview,
        processedPreview: processedPreview,
        fwhm: fwhm,
        nonStarFraction: nonStarFraction,
        maskRegions: maskRegions,
        isLikelyStarfield: isLikelyStarfield,
        starfieldConfidence: starfieldConfidence,
        flatAreaFraction: flatAreaFraction,
      );

  static bool _sameSource(DetectedStar a, DetectedStar b) =>
      (a.x - b.x).abs() < 0.01 && (a.y - b.y).abs() < 0.01;

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'stars': stars.map((star) => star.toJson()).toList(),
        'quality': quality,
        'background': background,
        'noise': noise,
        'background_index': backgroundIndex,
        'saturated_fraction': saturatedFraction,
        'diagnostics': diagnostics,
        'fwhm': fwhm,
        'non_star_fraction': nonStarFraction,
        'mask_regions': maskRegions.map((region) => region.toJson()).toList(),
        'is_likely_starfield': isLikelyStarfield,
        'starfield_confidence': starfieldConfidence,
        'flat_area_fraction': flatAreaFraction,
      };

  /// 历史记录里只存索引信息，图片从磁盘重新读，不在 JSON 里塞 base64。
  static SkyAnalysis fromJson(
    Map<String, Object?> json, {
    required Uint8List preview,
    required Uint8List processedPreview,
  }) =>
      SkyAnalysis(
        width: _asDouble(json['width']).round(),
        height: _asDouble(json['height']).round(),
        stars: ((json['stars'] as List<Object?>?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((item) => DetectedStar.fromJson(Map<String, Object?>.from(item)))
            .toList(growable: false),
        quality: json['quality'] as String? ?? '未知',
        background: _asDouble(json['background']),
        noise: _asDouble(json['noise']),
        backgroundIndex: _asDouble(json['background_index']),
        saturatedFraction: _asDouble(json['saturated_fraction']),
        diagnostics: ((json['diagnostics'] as List<Object?>?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        preview: preview,
        processedPreview: processedPreview,
        fwhm: _asDouble(json['fwhm']),
        nonStarFraction: _asDouble(json['non_star_fraction']),
        maskRegions: ((json['mask_regions'] as List<Object?>?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((item) => MaskRegion.fromJson(Map<String, Object?>.from(item)))
            .toList(growable: false),
        isLikelyStarfield: json['is_likely_starfield'] != false,
        starfieldConfidence: _asDouble(json['starfield_confidence']),
        flatAreaFraction: _asDouble(json['flat_area_fraction']),
      );

  /// 对外唯一入口：给一份图片字节，返回分析结果。
  static SkyAnalysis analyze(Uint8List bytes) {
    final decoded = decodeImageOrRawPreview(bytes);
    if (decoded == null) {
      throw const FormatException(
        '无法解码此图片或 RAW 内嵌预览。请在相机应用中导出 JPG/PNG 后重试。',
      );
    }
    final image = _downscale(decoded);
    final width = image.width;
    final height = image.height;

    final gray = _toGrayscale(image);
    var saturated = 0;
    for (var i = 0; i < gray.length; i++) {
      if (gray[i] >= 250 / 255) saturated++;
    }
    final saturatedFraction = saturated / gray.length;

    final grid = _BackgroundGrid(gray, width, height);
    final threshold = _ThresholdMap(gray, width, height, grid);

    var classified = _classify(
      _findComponents(gray, width, height, threshold.primary, grid),
      grid,
    );
    // 标准阈值下点源太少时，降低阈值再试一次：手机夜景常见的欠曝照片能多救回一些星。
    var usedRelaxedThreshold = false;
    if (classified.stars.length < 8) {
      final relaxed = _classify(
        _findComponents(gray, width, height, threshold.relaxed, grid),
        grid,
      );
      if (relaxed.stars.length > classified.stars.length) {
        classified = relaxed;
        usedRelaxedThreshold = true;
      }
    }

    final suppressed = _suppressTextClusters(classified.stars);
    final stars = [...classified.stars, ...classified.trails]
        .where((star) => !suppressed.contains(star))
        .toList(growable: false)
      ..sort((a, b) => a.instrumentalMagnitude.compareTo(b.instrumentalMagnitude));

    final flatAreaFraction = _flatAreaFraction(gray, width, height);
    final starfield = _judgeStarfield(
      stars: stars,
      maskRegions: classified.regions,
      flatAreaFraction: flatAreaFraction,
      width: width,
      height: height,
    );
    final fwhm = _estimateFwhm(stars);

    // 被文字抑制掉的点也要从画面里抹掉，否则处理图上会留下文字残影。
    final mask = Uint8List(width * height);
    for (final region in classified.regions) {
      _fillMask(mask, width, height, region.x, region.y, region.width, region.height);
    }
    for (final star in suppressed) {
      _fillMask(mask, width, height, star.x - 4, star.y - 4, 8, 8);
    }
    var maskedPixels = 0;
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] != 0) maskedPixels++;
    }

    return SkyAnalysis(
      width: width,
      height: height,
      stars: stars,
      quality: _qualityLabel(
        stars: stars,
        noise: grid.globalNoise,
        saturatedFraction: saturatedFraction,
        starfieldConfidence: starfield.confidence,
      ),
      background: grid.globalBackground,
      noise: grid.globalNoise,
      backgroundIndex: grid.globalBackground * 100,
      saturatedFraction: saturatedFraction,
      diagnostics: _buildDiagnostics(
        stars: stars,
        regions: classified.regions,
        starfield: starfield,
        background: grid.globalBackground,
        noise: grid.globalNoise,
        saturatedFraction: saturatedFraction,
        fwhm: fwhm,
        usedRelaxedThreshold: usedRelaxedThreshold,
      ),
      preview: Uint8List.fromList(imglib.encodeJpg(image, quality: 92)),
      processedPreview: _renderProcessedPreview(gray, width, height, grid, mask),
      fwhm: fwhm,
      nonStarFraction: maskedPixels / mask.length,
      maskRegions: classified.regions,
      isLikelyStarfield: starfield.isStarfield,
      starfieldConfidence: starfield.confidence,
      flatAreaFraction: flatAreaFraction,
    );
  }
}

void _fillMask(
  Uint8List mask,
  int width,
  int height,
  double x,
  double y,
  double regionWidth,
  double regionHeight,
) {
  final x0 = x.floor().clamp(0, width);
  final y0 = y.floor().clamp(0, height);
  final x1 = (x + regionWidth).ceil().clamp(0, width);
  final y1 = (y + regionHeight).ceil().clamp(0, height);
  for (var py = y0; py < y1; py++) {
    for (var px = x0; px < x1; px++) {
      mask[py * width + px] = 1;
    }
  }
}

/// 在 isolate 里跑分析用的入口，参数和返回值都必须是可跨 isolate 传递的类型。
Future<SkyAnalysis> analyzeImageBytes(Uint8List bytes) async =>
    SkyAnalysis.analyze(bytes);

// ---------------------------------------------------------------------------
// 解码
// ---------------------------------------------------------------------------

/// 解码普通图片；失败时退回在相机 RAW 容器里找最大的内嵌 JPEG 预览。
imglib.Image? decodeImageOrRawPreview(Uint8List bytes) {
  try {
    final decoded = imglib.decodeImage(bytes);
    if (decoded != null) return decoded;
  } on Exception {
    // 相机 RAW 容器里可能内嵌了可用的 JPEG 预览，下面继续找。
  }

  imglib.Image? largestPreview;
  var start = 0;
  var inspected = 0;
  while (start + 3 < bytes.length && inspected < 32) {
    while (start + 1 < bytes.length &&
        !(bytes[start] == 0xFF && bytes[start + 1] == 0xD8)) {
      start++;
    }
    if (start + 1 >= bytes.length) break;
    final jpegStart = start;
    var end = jpegStart + 2;
    while (end + 1 < bytes.length &&
        !(bytes[end] == 0xFF && bytes[end + 1] == 0xD9)) {
      end++;
    }
    if (end + 1 >= bytes.length) break;
    try {
      final preview = imglib.decodeImage(bytes.sublist(jpegStart, end + 2));
      if (preview != null &&
          (largestPreview == null ||
              preview.width * preview.height >
                  largestPreview.width * largestPreview.height)) {
        largestPreview = preview;
      }
    } on Exception {
      // 继续找下一段完整的 JPEG 缩略图。
    }
    inspected++;
    start = end + 2;
  }
  return largestPreview;
}

imglib.Image _downscale(imglib.Image decoded) {
  const limit = 1200;
  if (decoded.width <= limit && decoded.height <= limit) return decoded;
  return decoded.width >= decoded.height
      ? imglib.copyResize(decoded,
          width: limit, interpolation: imglib.Interpolation.linear)
      : imglib.copyResize(decoded,
          height: limit, interpolation: imglib.Interpolation.linear);
}

/// 亮度用 Rec.709 权重；存成 Float32 省内存，后续计算都在这个缓冲上做。
Float32List _toGrayscale(imglib.Image image) {
  final gray = Float32List(image.width * image.height);
  var index = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final pixel = image.getPixel(x, y);
      gray[index++] =
          (0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0;
    }
  }
  return gray;
}

// ---------------------------------------------------------------------------
// 背景与噪声
// ---------------------------------------------------------------------------

/// 分块背景模型。整幅图用一个全局中位数，在城市光污染的渐变天空上会翻车；
/// 按 32×32 分块各估一个中位数，再双线性插值，得到平滑的背景面。
/// 噪声用 MAD 换算标准差，对星点和热噪点都不敏感。
class _BackgroundGrid {
  _BackgroundGrid(Float32List gray, int width, int height) {
    cols = (width / tileSize).ceil();
    rows = (height / tileSize).ceil();
    background = Float32List(cols * rows);
    noise = Float32List(cols * rows);

    final buffer = Float32List(tileSize * tileSize);
    final deviations = Float32List(tileSize * tileSize);
    for (var ty = 0; ty < rows; ty++) {
      for (var tx = 0; tx < cols; tx++) {
        final x0 = tx * tileSize;
        final y0 = ty * tileSize;
        final x1 = math.min(width, x0 + tileSize);
        final y1 = math.min(height, y0 + tileSize);
        var count = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            buffer[count++] = gray[y * width + x];
          }
        }
        final view = Float32List.sublistView(buffer, 0, count)..sort();
        final median = _medianSorted(view);
        background[ty * cols + tx] = median;
        for (var i = 0; i < count; i++) {
          deviations[i] = (view[i] - median).abs();
        }
        final deviationView = Float32List.sublistView(deviations, 0, count)..sort();
        noise[ty * cols + tx] =
            math.max(1.4826 * _medianSorted(deviationView), 1 / 255);
      }
    }

    globalBackground = background[(rows ~/ 2) * cols + cols ~/ 2];
    var sum = 0.0;
    for (final value in noise) {
      sum += value;
    }
    globalNoise = sum / noise.length;
  }

  static const tileSize = 32;

  late final int cols;
  late final int rows;
  late final Float32List background;
  late final Float32List noise;
  late final double globalBackground;
  late final double globalNoise;

  /// 背景面在任意像素上的双线性插值取值。
  double backgroundAt(double x, double y) {
    final gridX = (x / tileSize - 0.5).clamp(0.0, (cols - 1).toDouble());
    final gridY = (y / tileSize - 0.5).clamp(0.0, (rows - 1).toDouble());
    final x0 = gridX.floor();
    final y0 = gridY.floor();
    final x1 = math.min(x0 + 1, cols - 1);
    final y1 = math.min(y0 + 1, rows - 1);
    final fx = gridX - x0;
    final fy = gridY - y0;
    final top =
        background[y0 * cols + x0] * (1 - fx) + background[y0 * cols + x1] * fx;
    final bottom =
        background[y1 * cols + x0] * (1 - fx) + background[y1 * cols + x1] * fx;
    return top * (1 - fy) + bottom * fy;
  }

  double noiseAt(double x, double y) {
    final gridX = (x / tileSize - 0.5).clamp(0.0, (cols - 1).toDouble());
    final gridY = (y / tileSize - 0.5).clamp(0.0, (rows - 1).toDouble());
    return math.max(noise[gridY.round() * cols + gridX.round()], 1 / 255);
  }
}

/// 每个像素的判断阈值 = 局部背景 + kσ 局部噪声。
/// 局部化以后，光污染梯度强的区域不会因为全局阈值过高而漏检暗星。
class _ThresholdMap {
  _ThresholdMap(Float32List gray, int width, int height, _BackgroundGrid grid) {
    primary = Float32List(gray.length);
    relaxed = Float32List(gray.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = y * width + x;
        final background = grid.backgroundAt(x.toDouble(), y.toDouble());
        final sigma = grid.noiseAt(x.toDouble(), y.toDouble());
        primary[index] = math.max(background + 5 * sigma, background + 4 / 255);
        relaxed[index] = math.max(background + 3.2 * sigma, background + 3 / 255);
      }
    }
  }

  late final Float32List primary;
  late final Float32List relaxed;
}

// ---------------------------------------------------------------------------
// 连通域检测与分类
// ---------------------------------------------------------------------------

/// 一个阈值以上连通域的形态与测光统计。
class _Component {
  _Component(this.minX, this.minY);

  int minX;
  int minY;
  // 起始像素就是第一个成员，所以 max 从 0 出发用“取更大值”累计是对的。
  int maxX = 0;
  int maxY = 0;
  double flux = 0;
  double weightedX = 0;
  double weightedY = 0;
  double peakSignal = 0;
  double centroidX = 0;
  double centroidY = 0;
  double varianceX = 0;
  double varianceY = 0;
  double covariance = 0;
  double concentration = 0;
  double minorSigma = 0;
  final List<int> pixels = <int>[];

  int get area => pixels.length;
  int get boxWidth => maxX - minX + 1;
  int get boxHeight => maxY - minY + 1;
  int get boxArea => boxWidth * boxHeight;
  double get fillRatio => boxArea == 0 ? 0 : area / boxArea;
  double get spread => math.max(boxWidth, boxHeight).toDouble();
  double get thinness => math.min(boxWidth, boxHeight).toDouble();

  /// 峰值相对平均信号的比例。真星点有明显核心（>1.4），
  /// 文字笔画和实心色块几乎是常数（≈1）。
  double get peakRatio {
    if (flux <= 0 || area == 0) return 1;
    final mean = flux / area;
    return mean <= 0 ? 1 : peakSignal / mean;
  }

  /// 长短轴比，由亮度加权的二阶矩算出。
  double get axisRatio {
    if (flux <= 0) return 1;
    final vx = varianceX / flux;
    final vy = varianceY / flux;
    final vxy = covariance / flux;
    final halfTrace = (vx + vy) / 2;
    final offset = math.sqrt((vx - vy) * (vx - vy) / 4 + vxy * vxy);
    return math.sqrt(
      math.max(0.0, halfTrace + offset) / math.max(0.05, halfTrace - offset),
    );
  }

  /// 长轴方向（弧度）。
  double get orientation {
    if (flux <= 0) return 0;
    final vx = varianceX / flux;
    final vy = varianceY / flux;
    final vxy = covariance / flux;
    return 0.5 * math.atan2(2 * vxy, vx - vy);
  }
}

/// 在阈值掩膜上做 8 连通标记，同时累计形态统计。
/// 每个像素只归属一个连通域，统计结果不会有跨域污染。
List<_Component> _findComponents(
  Float32List gray,
  int width,
  int height,
  Float32List threshold,
  _BackgroundGrid grid,
) {
  final visited = Uint8List(width * height);
  final components = <_Component>[];
  final stack = <int>[];

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final start = y * width + x;
      if (visited[start] != 0 || gray[start] < threshold[start]) continue;

      final component = _Component(x, y);
      stack.add(start);
      visited[start] = 1;
      while (stack.isNotEmpty) {
        final index = stack.removeLast();
        final px = index % width;
        final py = index ~/ width;
        final signal =
            gray[index] - grid.backgroundAt(px.toDouble(), py.toDouble());

        component.pixels.add(index);
        component.flux += signal;
        component.weightedX += signal * px;
        component.weightedY += signal * py;
        if (signal > component.peakSignal) component.peakSignal = signal;
        if (px < component.minX) component.minX = px;
        if (py < component.minY) component.minY = py;
        if (px > component.maxX) component.maxX = px;
        if (py > component.maxY) component.maxY = py;

        for (var dy = -1; dy <= 1; dy++) {
          final ny = py + dy;
          if (ny < 0 || ny >= height) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = px + dx;
            if (nx < 0 || nx >= width) continue;
            final neighbour = ny * width + nx;
            if (visited[neighbour] != 0) continue;
            if (gray[neighbour] < threshold[neighbour]) continue;
            visited[neighbour] = 1;
            stack.add(neighbour);
          }
        }
      }

      if (component.flux > 0) {
        component.centroidX = component.weightedX / component.flux;
        component.centroidY = component.weightedY / component.flux;
      } else {
        component.centroidX = (component.minX + component.maxX) / 2;
        component.centroidY = (component.minY + component.maxY) / 2;
      }
      _computeMoments(component, gray, width, grid);
      components.add(component);
    }
  }
  return components;
}

/// 用通量加权的二阶矩算长短轴、方向和 3×3 集中度。
void _computeMoments(
  _Component component,
  Float32List gray,
  int width,
  _BackgroundGrid grid,
) {
  var vx = 0.0;
  var vy = 0.0;
  var vxy = 0.0;
  var central = 0.0;
  for (final index in component.pixels) {
    final x = index % width;
    final y = index ~/ width;
    final signal = gray[index] - grid.backgroundAt(x.toDouble(), y.toDouble());
    if (signal <= 0) continue;
    final dx = x - component.centroidX;
    final dy = y - component.centroidY;
    vx += signal * dx * dx;
    vy += signal * dy * dy;
    vxy += signal * dx * dy;
    if (dx.abs() <= 1 && dy.abs() <= 1) central += signal;
  }
  component.varianceX = vx;
  component.varianceY = vy;
  component.covariance = vxy;
  component.concentration = component.flux <= 0 ? 0 : central / component.flux;

  // 短轴 σ：星点的短轴方向宽度，用来估 FWHM。
  if (component.flux > 0) {
    final mx = vx / component.flux;
    final my = vy / component.flux;
    final mxy = vxy / component.flux;
    final halfTrace = (mx + my) / 2;
    final offset = math.sqrt((mx - my) * (mx - my) / 4 + mxy * mxy);
    component.minorSigma = math.sqrt(math.max(halfTrace - offset, 0.05));
  }
}

class _ClassifiedField {
  _ClassifiedField(this.stars, this.trails, this.regions);

  final List<DetectedStar> stars;
  final List<DetectedStar> trails;
  final List<MaskRegion> regions;
}

/// 形态分类：紧凑点源 → 星点；规则细长 → 拉线候选；其余大块/不规则 → 非星空区域。
_ClassifiedField _classify(List<_Component> components, _BackgroundGrid grid) {
  final stars = <DetectedStar>[];
  final trails = <DetectedStar>[];
  final regions = <MaskRegion>[];

  for (final component in components) {
    if (component.area < 3 || component.flux <= 0) continue;

    final spread = component.spread;
    final fill = component.fillRatio;
    final axisRatio = component.axisRatio;

    // 面积或尺度远超星点：月亮、路灯、被照亮的建筑、整行文字糊在一起。
    if (component.area > 400 || spread > 64) {
      regions.add(_regionOf(component, MaskKind.blob));
      continue;
    }

    if (spread <= 8) {
      // 填充率太低说明是一圈细笔画（文字轮廓、图标），不是星点。
      if (fill < 0.30) {
        regions.add(_regionOf(component, MaskKind.text));
        continue;
      }
      // 中心集中度低、峰均比接近 1 的均匀亮块（实心单元格、纯色标签）不算星点。
      if (component.concentration < 0.30 && component.peakRatio < 1.35) {
        regions.add(_regionOf(component, MaskKind.text));
        continue;
      }
      stars.add(_toStar(component, grid));
      continue;
    }

    // 细长结构：又直又均匀的是拉线（拖线/卫星/飞机），
    // 填充率低或宽度不均的是表格边框、电缆这类伪影。
    if (axisRatio >= 2.2 && fill >= 0.5 && component.thinness <= 6) {
      trails.add(_toStar(component, grid));
    } else {
      regions.add(
        _regionOf(component, fill < 0.5 ? MaskKind.text : MaskKind.line),
      );
    }
  }
  return _ClassifiedField(stars, trails, regions);
}

MaskRegion _regionOf(_Component component, MaskKind kind) => MaskRegion(
      x: component.minX.toDouble(),
      y: component.minY.toDouble(),
      width: component.boxWidth.toDouble(),
      height: component.boxHeight.toDouble(),
      kind: kind,
    );

DetectedStar _toStar(_Component component, _BackgroundGrid grid) {
  final flux = component.flux;
  final magnitude = flux <= 0 ? 30.0 : -2.5 * math.log(flux) / math.ln10;
  final sigma = grid.noiseAt(component.centroidX, component.centroidY);

  // 信噪比按“总通量 / 孔径内噪声”估，比原来的经验式更接近真实测光。
  final noiseFlux = sigma * math.sqrt(component.area.toDouble());
  final snr = noiseFlux <= 0 ? 0.0 : flux / noiseFlux;

  // 天体像素按增益 1（相对单位）估光子噪声；这里只用于给星等配误差棒，
  // 不代表真实电子数，文档里已说明是相对不确定度。
  final fluxError = math.sqrt(math.max(flux, 0.0) + component.area * sigma * sigma);
  final axisRatio = component.axisRatio;
  final shapePenalty = math.sqrt(math.min(1.0, 2 / math.max(axisRatio, 1.0)));
  final concentrated = component.concentration.clamp(0.0, 1.0);
  final confidence =
      ((snr / (snr + 6)) * (0.4 + 0.6 * concentrated) * shapePenalty)
          .clamp(0.0, 1.0)
          .toDouble();

  return DetectedStar(
    component.centroidX,
    component.centroidY,
    flux,
    magnitude,
    confidence,
    axisRatio,
    fwhm: 2.355 * component.minorSigma,
    fluxError: fluxError,
    orientation: component.orientation,
  );
}

/// 文字/表格抑制：文字笔画亮度几乎一致，而且沿基线排成一行。
/// 真星空里的恒星亮度按幂律分布，也不会整齐共线。
/// 两个条件同时成立才判定为文字，避免把疏散星团误伤。
Set<DetectedStar> _suppressTextClusters(List<DetectedStar> stars) {
  final suppressed = <DetectedStar>{};
  if (stars.length < 6) return suppressed;

  const radius = 14.0;
  for (final star in stars) {
    final group = <DetectedStar>[
      star,
      ...stars.where(
        (other) =>
            !identical(other, star) &&
            (other.x - star.x).abs() <= radius &&
            (other.y - star.y).abs() <= radius,
      ),
    ];
    if (group.length < 6) continue;

    final fluxValues = group.map((item) => item.flux).toList();
    final mean = fluxValues.reduce((a, b) => a + b) / fluxValues.length;
    if (mean <= 0) continue;
    final variance = fluxValues
            .map((value) => (value - mean) * (value - mean))
            .reduce((a, b) => a + b) /
        fluxValues.length;
    // 亮度几乎一致的密集点簇：文字。恒星簇的相对标准差通常远大于 0.25。
    if (math.sqrt(variance) / mean > 0.18) continue;
    if (!_isCollinear(group)) continue;
    suppressed.addAll(group);
  }
  return suppressed;
}

/// 判断一簇点是否共线（拟合直线的横向残差很小、沿主轴铺得够长）。
bool _isCollinear(List<DetectedStar> group) {
  if (group.length < 6) return false;
  var meanX = 0.0;
  var meanY = 0.0;
  for (final star in group) {
    meanX += star.x;
    meanY += star.y;
  }
  meanX /= group.length;
  meanY /= group.length;

  var sxx = 0.0;
  var syy = 0.0;
  var sxy = 0.0;
  for (final star in group) {
    final dx = star.x - meanX;
    final dy = star.y - meanY;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  final trace = sxx + syy;
  final offset = math.sqrt((sxx - syy) * (sxx - syy) / 4 + sxy * sxy);
  final major = trace / 2 + offset;
  if (major <= 0) return false;
  final minor = math.max(trace / 2 - offset, 0.0);
  final ratio = math.sqrt(minor / major);
  final length = math.sqrt(major / group.length) * 2;
  return ratio < 0.22 && length >= 12;
}

/// 近乎平坦的像素占比：截图、纯色块会非常高，真实夜空因为噪声不会。
double _flatAreaFraction(Float32List gray, int width, int height) {
  const tile = 8;
  var flat = 0;
  var total = 0;
  for (var ty = 0; ty < height; ty += tile) {
    for (var tx = 0; tx < width; tx += tile) {
      final x1 = math.min(width, tx + tile);
      final y1 = math.min(height, ty + tile);
      var min = double.infinity;
      var max = -double.infinity;
      for (var y = ty; y < y1; y++) {
        for (var x = tx; x < x1; x++) {
          final value = gray[y * width + x];
          if (value < min) min = value;
          if (value > max) max = value;
        }
      }
      total++;
      if (max - min < 1.5 / 255) flat++;
    }
  }
  return total == 0 ? 0 : flat / total;
}

class _StarfieldVerdict {
  const _StarfieldVerdict(this.isStarfield, this.confidence);

  final bool isStarfield;
  final double confidence;
}

/// 综合判断“这到底是不是一张星空照片”。
_StarfieldVerdict _judgeStarfield({
  required List<DetectedStar> stars,
  required List<MaskRegion> maskRegions,
  required double flatAreaFraction,
  required int width,
  required int height,
}) {
  final pixels = width * height;
  var maskedArea = 0.0;
  for (final region in maskRegions) {
    maskedArea += region.area;
  }
  final maskedFraction = pixels == 0 ? 0.0 : maskedArea / pixels;
  final compact = stars.where((star) => !star.isElongated).length;

  var score = 0.0;
  // 星空照片最硬的指标：紧凑点源数量。
  if (compact >= 25) {
    score += 0.45;
  } else if (compact >= 8) {
    score += 0.3;
  } else if (compact >= 3) {
    score += 0.12;
  }
  // 密集文字/表格占比高 → 强烈倾向“不是星空”。
  if (maskedFraction < 0.05) {
    score += 0.25;
  } else if (maskedFraction < 0.2) {
    score += 0.1;
  } else {
    score -= 0.25;
  }
  // 大片平坦区域是截图/文档的典型特征。
  if (flatAreaFraction < 0.15) {
    score += 0.25;
  } else if (flatAreaFraction > 0.5) {
    score -= 0.35;
  }
  final clamped = score.clamp(0.0, 1.0).toDouble();
  return _StarfieldVerdict(clamped >= 0.45, clamped);
}

/// 用较亮紧凑星点的短轴散布估计点扩散函数半高全宽。
double _estimateFwhm(List<DetectedStar> stars) {
  final compact = stars.where((star) => !star.isElongated).toList()
    ..sort((a, b) => a.instrumentalMagnitude.compareTo(b.instrumentalMagnitude));
  if (compact.isEmpty) return 0;
  final values = compact
      .take(20)
      .map((star) => star.fwhm)
      .where((value) => value > 0.2 && value < 40)
      .toList()
    ..sort();
  if (values.isEmpty) return 0;
  final middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}

List<String> _buildDiagnostics({
  required List<DetectedStar> stars,
  required List<MaskRegion> regions,
  required _StarfieldVerdict starfield,
  required double background,
  required double noise,
  required double saturatedFraction,
  required double fwhm,
  required bool usedRelaxedThreshold,
}) {
  final diagnostics = <String>[];
  final compact = stars.where((star) => !star.isElongated).toList();
  final trails = stars.where((star) => star.isElongated).toList();

  if (!starfield.isStarfield) {
    diagnostics.add(
      '这张图看起来不是纯粹的星空照片：检出的密集亮点更像文字、表格或界面元素。'
      '请换一张以星场为主的照片，或先在相册里裁掉文字区域。',
    );
  }
  if (usedRelaxedThreshold) {
    diagnostics.add('标准阈值检出的点源偏少，已自动降低阈值重试；弱点源中可能混入噪声。');
  }
  final textRegions =
      regions.where((region) => region.kind == MaskKind.text).length;
  final blobRegions =
      regions.where((region) => region.kind == MaskKind.blob).length;
  final lineRegions =
      regions.where((region) => region.kind == MaskKind.line).length;
  if (textRegions > 0) {
    diagnostics.add('已屏蔽 $textRegions 处疑似文字/表格笔画，这些位置不参与星点统计。');
  }
  if (blobRegions > 0) {
    diagnostics.add('已屏蔽 $blobRegions 处大面积亮斑（可能是月亮、路灯或建筑），不做星点处理。');
  }
  if (lineRegions > 0) {
    diagnostics.add('已屏蔽 $lineRegions 处直线结构（可能是表格边框、电缆或栏杆）。');
  }
  if (trails.isNotEmpty) {
    diagnostics.add(
      '检出 ${trails.length} 个拉长的亮点候选，可能是拖线、失焦或飞机/卫星轨迹；'
      '单张照片不能据此确认，请在下方逐个判断是否保留。',
    );
  }
  if (compact.length < 8) {
    diagnostics.add('检出的紧凑亮点较少；可能曝光不足、虚焦或云雾遮挡。');
  }
  if (noise > 0.06) diagnostics.add('背景噪声偏高，弱星检测和相对亮度测量可靠性下降。');
  if (saturatedFraction > 0.01) diagnostics.add('部分像素接近饱和，亮星核心的亮度信息可能丢失。');
  if (background > 0.38) {
    diagnostics.add('图像背景偏亮；受曝光影响，不能直接换算成 SQM 或 Bortle 等级。');
  }
  if (fwhm > 8 && compact.isNotEmpty) {
    diagnostics.add('星点弥散较大（约 ${fwhm.toStringAsFixed(1)} px），可能是轻微失焦或手抖。');
  }
  if (compact.isNotEmpty &&
      compact.take(30).map((star) => star.confidence).reduce((a, b) => a + b) /
              math.min(30, compact.length) <
          0.38) {
    diagnostics.add('点源形态不够集中，可能存在抖动、虚焦或强降噪；测光置信度偏低。');
  }
  if (compact.length < 8) {
    diagnostics.add('拍摄建议：固定设备并重新手动对焦；避开云雾和灯光直射后再试。');
  }
  if (noise > 0.06) {
    diagnostics.add('拍摄建议：优先拍摄多张较短曝光用于后续叠加，避免只提高 ISO。');
  }
  if (saturatedFraction > 0.01) {
    diagnostics.add('拍摄建议：降低曝光或增益，避免亮星核心过曝。');
  }
  if (background > 0.38) {
    diagnostics.add('拍摄建议：若现场天空也明显发亮，可换到更暗地点并缩短单张曝光。');
  }
  if (diagnostics.isEmpty) {
    diagnostics.add('检出紧凑亮点；准确星名仍需可靠的天球坐标解算。');
  }
  return diagnostics;
}

String _qualityLabel({
  required List<DetectedStar> stars,
  required double noise,
  required double saturatedFraction,
  required double starfieldConfidence,
}) {
  final compact = stars.where((star) => !star.isElongated).length;
  if (starfieldConfidence < 0.45) return '较弱';
  if (compact >= 25 && noise < 0.04 && saturatedFraction < 0.01) return '较好';
  if (compact >= 8) return '一般';
  return '较弱';
}

/// 处理图：扣背景 → 反双曲正弦拉伸 → 抹掉非星空区域，只留下星场。
Uint8List _renderProcessedPreview(
  Float32List gray,
  int width,
  int height,
  _BackgroundGrid grid,
  Uint8List mask,
) {
  final output = imglib.Image(width: width, height: height);
  // 拉伸参数：asinh 压缩动态范围，让暗星和亮星的细节能同时看见。
  const gain = 3.0;
  const reference = 40.0;
  final normaliser = math.log(
    gain * reference + math.sqrt(gain * reference * gain * reference + 1),
  );
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      if (mask[index] != 0) {
        output.setPixelRgb(x, y, 0, 0, 0);
        continue;
      }
      final background = grid.backgroundAt(x.toDouble(), y.toDouble());
      final sigma = grid.noiseAt(x.toDouble(), y.toDouble());
      final signal = (gray[index] - background) / sigma * gain;
      final stretched =
          math.log(signal + math.sqrt(signal * signal + 1)) / normaliser;
      final level = (stretched.clamp(0.0, 1.0) * 255).round();
      output.setPixelRgb(x, y, level, level, level);
    }
  }
  return Uint8List.fromList(imglib.encodeJpg(output, quality: 88));
}

double _medianSorted(Float32List sorted) {
  if (sorted.isEmpty) return 0;
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
