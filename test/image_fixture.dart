import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as imglib;

/// 合成测试图像的工具。
///
/// 真实照片没法进单元测试——体积大、结论还会随相机和曝光漂移。这里用
/// 受控的合成图，把要检验的性质（通量是否线性、文字会不会被误当成星点）
/// 单独拿出来，断言才收得紧。

/// 一片带噪声的夜空底。
///
/// 噪声不是可有可无的装饰：分析器会统计「近乎平坦的像素占比」，纯色底
/// 会得到 1.0，据此判定这不是一张照片。所以测试底图必须带噪声。
imglib.Image nightSky({
  int width = 400,
  int height = 300,
  int level = 10,
  int noise = 4,
  int seed = 7,
}) {
  final random = math.Random(seed);
  final image = imglib.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final value =
          (level + random.nextInt(noise * 2 + 1) - noise).clamp(0, 255);
      image.setPixelRgb(x, y, value, value, value);
    }
  }
  return image;
}

/// 把 [value] 加到像素上（叠加而不是覆盖，免得后画的星盖掉先画的）。
void addGlow(imglib.Image image, int x, int y, double value) {
  if (x < 0 || y < 0 || x >= image.width || y >= image.height) return;
  final pixel = image.getPixel(x, y);
  final next = (pixel.r + value).round().clamp(0, 255);
  image.setPixelRgb(x, y, next, next, next);
}

/// 画一颗高斯星点。
///
/// [amplitude] 是峰值高出背景的灰度值（0–255），[sigma] 是高斯宽度（像素）。
/// 返回峰值通量，方便测试推算理论亮度比。
void drawStar(
  imglib.Image image,
  double x,
  double y, {
  double sigma = 1.5,
  double amplitude = 180,
}) {
  final reach = (sigma * 3).ceil();
  for (var dy = -reach; dy <= reach; dy++) {
    for (var dx = -reach; dx <= reach; dx++) {
      final value = amplitude * math.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
      addGlow(image, x.round() + dx, y.round() + dy, value);
    }
  }
}

/// 随机撒一片星，位置尽量互不重叠。返回每颗星的振幅，按绘制顺序。
List<double> scatterStars(
  imglib.Image image, {
  int count = 60,
  double sigma = 1.5,
  double faintest = 45,
  double brightest = 230,
  double margin = 14,
  int seed = 11,
}) {
  final random = math.Random(seed);
  final amplitudes = <double>[];
  final placed = <(double, double)>[];
  var attempts = 0;
  while (amplitudes.length < count && attempts < count * 60) {
    attempts++;
    final x = margin + random.nextDouble() * (image.width - 2 * margin);
    final y = margin + random.nextDouble() * (image.height - 2 * margin);
    if (placed.any((p) => (p.$1 - x).abs() < 16 && (p.$2 - y).abs() < 16)) {
      continue;
    }
    placed.add((x, y));
    // 亮度按幂律分布取样，接近真实星场：亮星少、暗星多。
    final amplitude =
        faintest + (brightest - faintest) * math.pow(random.nextDouble(), 2.2);
    amplitudes.add(amplitude);
    drawStar(image, x, y, sigma: sigma, amplitude: amplitude);
  }
  return amplitudes;
}

/// 一行印刷文字：一排等亮度的竖笔画，基线对齐、间距均匀。
///
/// 真实文字的笔画就是这样的形态——细、短、亮度一致、沿基线排开。
/// 返回每个笔画的中心 x 坐标。
List<double> drawTextLine(
  imglib.Image image, {
  required int y,
  required int x0,
  int strokes = 12,
  double spacing = 7,
  double gap = 3,
  int height = 9,
  double amplitude = 200,
}) {
  final centres = <double>[];
  for (var i = 0; i < strokes; i++) {
    final x = x0 + i * spacing;
    centres.add(x);
    for (var dy = -height ~/ 2; dy <= height ~/ 2; dy++) {
      for (var dx = 0; dx < gap; dx++) {
        addGlow(image, x.round() + dx, y + dy, amplitude);
      }
    }
  }
  return centres;
}

/// 一块大面积亮斑：月亮、路灯、被照亮的建筑。
void drawBlob(
  imglib.Image image,
  double cx,
  double cy,
  double radius, {
  double amplitude = 215,
}) {
  final reach = radius.ceil();
  for (var dy = -reach; dy <= reach; dy++) {
    for (var dx = -reach; dx <= reach; dx++) {
      final distance = math.sqrt((dx * dx + dy * dy).toDouble());
      if (distance > radius) continue;
      // 边缘略微羽化，免得成为一块纯色方块。
      final falloff = distance > radius - 1.5 ? (radius - distance) / 1.5 : 1.0;
      addGlow(image, cx.round() + dx, cy.round() + dy, amplitude * falloff);
    }
  }
}

/// 表格边框：几横几竖的细直线。
void drawTable(
  imglib.Image image, {
  required int left,
  required int top,
  required int right,
  required int bottom,
  int columns = 4,
  int rows = 3,
  double amplitude = 190,
}) {
  for (var x = left; x <= right; x++) {
    for (final y in [top, bottom]) {
      addGlow(image, x, y, amplitude);
    }
  }
  for (var i = 0; i <= columns; i++) {
    final x = left + ((right - left) * i / columns).round();
    for (var y = top; y <= bottom; y++) {
      addGlow(image, x, y, amplitude);
    }
  }
  for (var i = 1; i < rows; i++) {
    final y = top + ((bottom - top) * i / rows).round();
    for (var x = left; x <= right; x++) {
      addGlow(image, x, y, amplitude);
    }
  }
}

Uint8List encodePng(imglib.Image image) =>
    Uint8List.fromList(imglib.encodePng(image));
