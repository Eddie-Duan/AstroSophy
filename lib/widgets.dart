import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'analysis.dart';
import 'models.dart';
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
