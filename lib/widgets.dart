import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'analysis.dart';
import 'models.dart';
import 'report.dart';
import 'theme.dart';

/// 各页面共用的展示组件与自绘图表。
///
/// 图表全部用 CustomPainter 自绘，不引第三方图表库：这里要画的东西
/// 都很简单，而多一个依赖就多一份体积和一份长期维护成本。
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, this.icon, {super.key});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: kMint, size: 20),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ],
      );
}

class MetricChip extends StatelessWidget {
  const MetricChip(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF18263A),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$label  $value', style: const TextStyle(fontSize: 12)),
      );
}

class OrbitPainter extends CustomPainter {
  const OrbitPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.75, size.height * 0.46);
    final random = math.Random(42);
    for (var i = 0; i < 46; i++) {
      final point = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = random.nextDouble() * 1.2 + 0.35;
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = Colors.white.withValues(alpha: random.nextDouble() * 0.38 + 0.08),
      );
    }
    final haloRect = Rect.fromCircle(center: center, radius: 74);
    canvas.drawCircle(
      center,
      75,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF8EF4DC).withValues(alpha: 0.28),
            const Color(0xFF3BAA9C).withValues(alpha: 0.12),
            Colors.transparent,
          ],
        ).createShader(haloRect),
    );
    canvas.drawCircle(
      center,
      43,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFB6F7E5), Color(0xFF49B8AA), Color(0xFF285D78)],
        ).createShader(haloRect),
    );
    final orbit = Paint()
      ..color = const Color(0x8892E8D5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.67,
        height: size.height * 0.44,
      ),
      orbit,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.84,
        height: size.height * 0.68,
      ),
      orbit..color = const Color(0x446C92BB),
    );
    final satellite = Offset(center.dx - size.width * 0.28, center.dy - 29);
    canvas.drawCircle(
      satellite,
      4,
      Paint()..color = const Color(0xFFFFDE77),
    );
    canvas.drawCircle(
      Offset(center.dx + 60, center.dy + 40),
      2.5,
      Paint()..color = const Color(0xFFEC99B3),
    );
    canvas.drawLine(
      Offset(size.width * 0.52, size.height * 0.28),
      Offset(size.width * 0.85, size.height * 0.14),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.48)
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class StarfieldPainter extends CustomPainter {
  const StarfieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(31);
    for (var index = 0; index < 84; index++) {
      final point = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = random.nextDouble() * 0.85 + 0.2;
      canvas.drawCircle(
        point,
        radius,
        Paint()..color = const Color(0xFFB8D6E8).withValues(alpha: random.nextDouble() * 0.2 + 0.025),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class DetectedStarsPainter extends CustomPainter {
  const DetectedStarsPainter({
    required this.analysis,
    required this.namedStars,
    required this.objects,
  });

  final SkyAnalysis analysis;
  final List<SkyObject> namedStars;
  final List<SkyObject> objects;

  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(analysis.width.toDouble(), analysis.height.toDouble()),
      size,
    );
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final scaleX = destination.width / analysis.width;
    final scaleY = destination.height / analysis.height;
    final starPaint = Paint()
      ..color = kMint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final labelStyle = const TextStyle(
      color: Color(0xFFFFDE77),
      fontSize: 10,
      fontWeight: FontWeight.w600,
      shadows: [Shadow(color: Colors.black, blurRadius: 5)],
    );

    for (final star in analysis.stars.take(80)) {
      final point = Offset(
        destination.left + star.x * scaleX,
        destination.top + star.y * scaleY,
      );
      canvas.drawCircle(point, 3.5, starPaint);
      for (final named in namedStars) {
        if ((named.x - star.x).abs() < 0.01 &&
            (named.y - star.y).abs() < 0.01) {
          final label = TextPainter(
            text: TextSpan(text: named.name, style: labelStyle),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: destination.width * 0.55);
          label.paint(canvas, point + const Offset(5, -13));
        }
      }
    }

    final objectPaint = Paint()
      ..color = const Color(0xFFFF7B8C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final object in objects) {
      final point = Offset(
        destination.left + object.x * scaleX,
        destination.top + object.y * scaleY,
      );
      canvas.drawCircle(point, 9, objectPaint);
      final label = TextPainter(
        text: TextSpan(text: object.name, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width * 0.55);
      label.paint(canvas, point + const Offset(10, -7));
    }
  }

  @override
  bool shouldRepaint(covariant DetectedStarsPainter oldDelegate) =>
      !identical(analysis, oldDelegate.analysis) ||
      !identical(namedStars, oldDelegate.namedStars) ||
      !identical(objects, oldDelegate.objects);
}

/// 一键解析的进度条。
///
/// 没有直接用 [LinearProgressIndicator]：进度条在已填充的那一段里撒了一片
/// 星点，进度往前走，星星一点点亮起来。解算动辄要等一两分钟，进度条是这
/// 段时间里屏幕上唯一在动的东西，做得像「星空正在显影」比一根灰条好。
class SkyProgressBar extends StatelessWidget {
  const SkyProgressBar({super.key, required this.value, this.height = 10});

  /// 0–1。
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        // 进度是跳着报上来的（阶段之间会跳一大格），补间让它滑过去而不是
        // 生硬地弹一下。
        tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, animated, _) => SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) => ClipRRect(
              borderRadius: BorderRadius.circular(height),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xFF1B2739)),
                  ),
                  SizedBox(
                    width: constraints.maxWidth * animated,
                    height: height,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0xFF2E8C7A), kMint, Color(0xFFCFF6EA)],
                        ),
                      ),
                      child: CustomPaint(painter: _StarRushPainter()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 进度条填充段里的星点。位置写死（用下标换算），这样每帧都一样，
/// 不会出现星星乱抖的噪声感。
class _StarRushPainter extends CustomPainter {
  const _StarRushPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 2 || size.height <= 2) return;
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.75);
    final faint = Paint()..color = Colors.white.withValues(alpha: 0.35);
    for (var i = 0; i < 7; i++) {
      // 黄金比取模，得到一组足够散、又完全确定的横向位置。
      final x = ((i * 0.618 + 0.11) % 1.0) * size.width;
      final y = ((i * 0.377 + 0.29) % 1.0) * size.height;
      final radius = i.isEven ? 1.4 : 1.0;
      canvas.drawCircle(Offset(x, y), radius, i.isEven ? paint : faint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarRushPainter oldDelegate) => false;
}

/// 星等分布直方图。
///
/// 横轴是星等（往右越暗），纵轴是星数。爱好者看这张图是想知道一件事：
/// 「我这套装备在当天的天空下能拍到多暗」。所以横轴按星等数值从小到大，
/// 右边那几根柱子才是重点——它们代表最暗的那批星，也就是这套设备这次
/// 拍摄的极限。
class MagnitudeHistogram extends StatelessWidget {
  const MagnitudeHistogram({
    super.key,
    required this.bins,
    this.height = 150,
    this.calibrated = false,
  });

  final List<MagnitudeBin> bins;
  final double height;

  /// 是否已经用星等零点标定过。没标定时横轴只是相对亮度，
  /// 图注必须说清楚，否则用户会把它当成真实星等。
  final bool calibrated;

  @override
  Widget build(BuildContext context) {
    if (bins.isEmpty) {
      return const Text(
        '没有可用于星等统计的点源。',
        style: TextStyle(color: Color(0xFF8192A8), fontSize: 12),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _MagnitudeHistogramPainter(bins)),
        ),
        const SizedBox(height: 6),
        Text(
          calibrated
              ? '横轴：标定星等（数值越大越暗）　纵轴：星数'
              : '横轴：图内相对星等（未标定，只能比较亮度，不是真实星等）　纵轴：星数',
          style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
        ),
      ],
    );
  }
}

class _MagnitudeHistogramPainter extends CustomPainter {
  const _MagnitudeHistogramPainter(this.bins);

  final List<MagnitudeBin> bins;

  /// 留给柱顶数字和横轴刻度的高度。
  static const _topPad = 16.0;
  static const _bottomPad = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty || size.width <= 8) return;
    final plotHeight = size.height - _topPad - _bottomPad;
    if (plotHeight <= 4) return;

    var peak = 1;
    for (final bin in bins) {
      if (bin.count > peak) peak = bin.count;
    }

    final slot = size.width / bins.length;
    // 柱子之间留缝，缝宽取格宽的三成、上限 6 像素：箱子少的时候缝不至于
    // 把柱子挤没，箱子多的时候柱子也不会粘成一片。
    final gap = math.min(slot * 0.3, 6.0);
    final barWidth = math.max(slot - gap, 1.0);
    final baseline = _topPad + plotHeight;

    final barPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0xFF2E8C7A), kMint],
      ).createShader(Rect.fromLTWH(0, _topPad, size.width, plotHeight));
    final zeroPaint = Paint()..color = const Color(0xFF2A3B52);
    final axisPaint = Paint()
      ..color = const Color(0xFF33455F)
      ..strokeWidth = 1;

    canvas.drawLine(
      Offset(0, baseline + 0.5),
      Offset(size.width, baseline + 0.5),
      axisPaint,
    );

    for (var index = 0; index < bins.length; index++) {
      final bin = bins[index];
      final left = index * slot + gap / 2;
      final barHeight = bin.count == 0 ? 2.0 : plotHeight * bin.count / peak;
      final rect = Rect.fromLTWH(
        left,
        baseline - barHeight,
        barWidth,
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        bin.count == 0 ? zeroPaint : barPaint,
      );
      _text(
        canvas,
        '${bin.count}',
        Offset(left + barWidth / 2, baseline - barHeight - 13),
        const TextStyle(color: Color(0xFFA6B5C8), fontSize: 10),
      );
    }

    // 横轴只标首尾两个星等值，中间不标——箱子多的时候刻度会挤成一团黑。
    _text(
      canvas,
      bins.first.lower.toStringAsFixed(1),
      Offset(4, baseline + 4),
      const TextStyle(color: Color(0xFF8192A8), fontSize: 10),
      alignLeft: true,
    );
    _text(
      canvas,
      bins.last.upper.toStringAsFixed(1),
      Offset(size.width - 4, baseline + 4),
      const TextStyle(color: Color(0xFF8192A8), fontSize: 10),
      alignRight: true,
    );
  }

  /// 以 [center] 为水平中心画一行小字。图表里的数字都要居中在柱子上，
  /// 用 TextPainter 手动定位比套一层 Widget 便宜。
  void _text(
    Canvas canvas,
    String value,
    Offset center,
    TextStyle style, {
    bool alignLeft = false,
    bool alignRight = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignLeft
        ? center.dx
        : alignRight
            ? center.dx - painter.width
            : center.dx - painter.width / 2;
    painter.paint(canvas, Offset(dx, center.dy));
  }

  @override
  bool shouldRepaint(covariant _MagnitudeHistogramPainter oldDelegate) =>
      !identical(oldDelegate.bins, bins);
}
