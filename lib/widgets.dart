import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'analysis.dart';
import 'deepsky_names.dart';
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

/// 图片读不到时的占位。
///
/// 历史记录里的图有可能被系统清理或被用户手动删掉，而同一份档案里的坐标、
/// 星表和测光结果都还在——这时候要让用户看见「图没了，别的还在」，而不是
/// 一串英文异常。
class MissingImage extends StatelessWidget {
  const MissingImage({super.key, this.compact = false});

  /// 紧凑模式只画一个图标，给缩略图那种小格子用。
  final bool compact;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFF101A2A),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: compact ? 26 : 38,
                color: const Color(0xFF46556B),
              ),
              if (!compact) ...[
                const SizedBox(height: 10),
                const Text(
                  '这张图已经不在手机上了',
                  style: TextStyle(color: Color(0xFF8192A8), fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      );
}

class DetectedStarsPainter extends CustomPainter {
  const DetectedStarsPainter({
    required this.analysis,
    required this.namedStars,
    required this.objects,
    this.figures = const [],
    this.bodies = const [],
    this.wcs,
    this.hidden = const {},
    this.selected,
    this.selectedObjectName,
    this.numbers = true,
    this.arcsecPerPixel = 0,
  });

  final SkyAnalysis analysis;
  final List<SkyObject> namedStars;
  final List<SkyObject> objects;

  /// 疑似的运动天体（行星、太阳）。
  ///
  /// [MovingBodySuspicion.x]、[.y] 是检出到的那颗亮点在图上的位置，星历自己
  /// 算出的位置只有赤经赤纬，要靠 [wcs] 现推——两者都要画，因为它们的间距
  /// 就是这个结论的不确定度。
  final List<MovingBodySuspicion> bodies;

  /// 解算出来的坐标映射。只有画运动天体时要用：深空天体的像素位置在解算
  /// 那一侧就算好了，而星历给的是赤经赤纬。
  final Wcs? wcs;

  /// 图像比例尺（角秒/像素），只用来把深空天体的角尺寸换成图上的圆。
  /// 0 表示还没解算——那就退回到一个固定大小的标记。
  final double arcsecPerPixel;

  /// 星座连线，像素坐标已经由解算侧算好（见 `ConstellationFigure`）。
  final List<ConstellationFigure> figures;

  /// 图上不画的编号（`numberedTargets` 的下标）。
  ///
  /// 用户在列表里按组把圆圈隐去了。隐去就是**什么都不画**：不画圈、不画编号。
  /// 画淡一点或者打个叉都不行——那仍然是画面上一块要费神忽略的东西，而用户
  /// 要的是画面干净。这只是不画：这些点一个都没少，测量和报告照旧。
  final Set<int> hidden;

  /// 当前在下方列表里选中的那一项（`numberedTargets` 的下标）。图上会把它
  /// 单独框出来——点列表第 10 项和图上的 ⑩ 必须是同一颗星，否则这套编号
  /// 就白做了。
  final int? selected;

  /// 选中的深空天体名称；深空天体不属于星点编号序列。
  final String? selectedObjectName;

  /// 是否在圈旁边标编号。
  final bool numbers;

  /// 图上最多标多少个编号。视场里动辄上百个点源，全标上就成了一片数字，
  /// 反而认不出哪颗是哪颗。
  static const _numberLimit = 40;

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
    final scale = (scaleX + scaleY) / 2;

    Offset toCanvas(double x, double y) => Offset(
          destination.left + x * scaleX,
          destination.top + y * scaleY,
        );

    final labelStyle = const TextStyle(
      color: Color(0xFFFFDE77),
      fontSize: 10,
      fontWeight: FontWeight.w600,
      shadows: [Shadow(color: Colors.black, blurRadius: 5)],
    );

    // 所有标注都排完位置再统一画。
    //
    // 原来是「画到谁就顺手把它的字画上去」，于是同一块地方有两颗星、两条
    // 深空天体、再加一个星座名，四段文字就会压成一团——那种图不是信息多，
    // 是信息没了。改成先收集、再统一排版，冲突时挪位置。
    final placer = LabelPlacer(destination);
    final pending = <_PendingLabel>[];

    void queue(
      TextPainter painter,
      Offset anchor, {
      required int priority,
      required Offset preferred,
      bool force = false,
    }) {
      pending.add(
        _PendingLabel(
          painter: painter,
          anchor: anchor,
          priority: priority,
          preferred: preferred,
          force: force,
        ),
      );
    }

    // 月面圈。
    //
    // 月球照走的是另一条链路，画面上一个编号都不会有——这个圈就是唯一能告诉
    // 用户「照片我认出来了，月亮在这里、量到了多大」的东西。没有它，界面上
    // 会是一片什么都没标的原图，看着像没分析。
    final moon = analysis.moonDisc;
    if (moon != null) {
      final center = toCanvas(moon.centerX, moon.centerY);
      final moonRadius = moon.radiusPixels * scale;
      canvas.drawCircle(
        center,
        moonRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = kMint.withValues(alpha: 0.9),
      );
      final caption = TextPainter(
        text: TextSpan(
          text: '月面 · 亮 ${(moon.illuminatedFraction * 100).toStringAsFixed(1)}%',
          style: const TextStyle(
            color: kMint,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(color: Colors.black, blurRadius: 5)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      queue(
        caption,
        center,
        priority: 1,
        preferred: Offset(-caption.width / 2, moonRadius + 4),
        // 月面照片上只有这一个标，没有别的东西和它抢位置。真排不下时宁可
        // 压上去也要画出来——把唯一的结论藏掉，比叠一行字糟糕得多。
        force: true,
      );
    }

    // 星座连线先画，压在最底下。它是背景参考，不能盖住用户真正要看的
    // 星点和编号——那两样才是这个面板要回答的问题。
    final figurePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = const Color(0x66FFDE77);
    final figureLabelStyle = TextStyle(
      color: const Color(0xFFFFDE77).withValues(alpha: 0.62),
      fontSize: 11,
      fontWeight: FontWeight.w600,
      shadows: const [Shadow(color: Colors.black, blurRadius: 5)],
    );
    for (final figure in figures) {
      for (final segment in figure.segments) {
        if (segment.length != 4) continue;
        canvas.drawLine(
          toCanvas(segment[0], segment[1]),
          toCanvas(segment[2], segment[3]),
          figurePaint,
        );
      }
      final label = TextPainter(
        text: TextSpan(text: figure.name, style: figureLabelStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width * 0.6);
      final anchor = toCanvas(figure.labelX, figure.labelY);
      queue(
        label,
        anchor,
        // 星座名排在最后：它是个背景参照，而编号和天体名才是这张图要回答
        // 的问题。位置不够时该让路的是它。
        priority: 6,
        preferred: Offset(-label.width / 2, -label.height / 2),
      );
    }

    final targets = analysis.numberedTargets;
    for (var index = 0; index < targets.length; index++) {
      if (hidden.contains(index)) continue;
      final star = targets[index];
      final point = toCanvas(star.x, star.y);
      final isSelected = index == selected;

      // 拉长候选画成椭圆，长轴按检出到的方向。圆点看不出「这是条线还是一
      // 颗星」，而这两种东西在图上的意义完全不同——一条线可能是飞机或
      // 卫星，判断该不该留就得看它的方向和长度。
      //
      // 被判为非天体的飞线照样画，只是颜色压暗：用户要能一眼看出自己判过
      // 哪一条、在哪儿判的，否则改主意时无从下手。
      final rejected = star.isRejected;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rejected ? 1.0 : (isSelected ? 2.0 : 1.2)
        ..color = rejected
            ? const Color(0xFF8A5A66)
            : star.isElongated
                ? const Color(0xFFFF7B8C)
                : kMint;

      if (star.isElongated) {
        final semiMajor = math.max(star.fwhm * star.axisRatio, 8) / 2 * scale;
        final semiMinor = math.max(star.fwhm, 4) / 2 * scale;
        canvas.save();
        canvas.translate(point.dx, point.dy);
        // 图像坐标 y 轴向下，椭圆参数里的角度也是顺时针为正，两者一致，
        // 所以这里可以直接用检出到的方向角。
        canvas.rotate(star.orientation);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: semiMajor * 2,
            height: semiMinor * 2,
          ),
          paint,
        );
        canvas.restore();
      } else {
        canvas.drawCircle(point, isSelected ? 8 : 3.5, paint);
      }

      if (isSelected) {
        canvas.drawCircle(
          point,
          star.isElongated ? 12 : 10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = Colors.white.withValues(alpha: 0.9),
        );
      }

      if (numbers && index < _numberLimit) {
        final label = TextPainter(
          text: TextSpan(
            text: '${index + 1}',
            // 编号照留，只是压暗：编号是把列表和图上对上的唯一凭据，摘掉它
            // 就等于把这条飞线从两边的对应关系里剔了出去。
            style: rejected
                ? labelStyle.copyWith(color: const Color(0xFF8A5A66))
                : labelStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        queue(label, point, priority: 5, preferred: const Offset(5, -12));
      }
    }

    for (final named in namedStars) {
      final point = toCanvas(named.x, named.y);
      final label = TextPainter(
        text: TextSpan(text: named.name, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width * 0.55);
      // 星名排在编号前面：编号只说「第 10 号」，星名说的是「这是参宿四」。
      // 位置不够时，宁可少一个编号——编号在下面的列表里查得到，名字不在。
      queue(label, point, priority: 3, preferred: const Offset(6, 4));
    }

    // 深空天体和星点分开画：星点是个位置，深空天体是**一块面积**。所以这里的
    // 标记大小跟着天体自身的角尺寸走——M31 用一个小圆圈住核心，会让人以为
    // 那就是它的全部，其实整个星系比那个圈大十几倍。
    final objectPaint = Paint()
      ..color = const Color(0xFFFF7B8C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final object in objects) {
      final point = toCanvas(object.x, object.y);
      final size = object.angularSizeArcmin;
      final selected = object.name == selectedObjectName;
      final paint = selected
          ? (Paint()
            ..color = const Color(0xFFFFDE77)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.8)
          : objectPaint;
      if (size == null || size <= 0 || arcsecPerPixel <= 0) {
        canvas.drawCircle(point, 9, paint);
      } else {
        // 角尺寸换成图像像素要经过实际比例尺；画到画布上再乘一次缩放。
        final radius = size * 60 / arcsecPerPixel / 2 * scale;
        canvas.drawCircle(point, radius.clamp(6.0, 400.0), paint);
      }
      final label = TextPainter(
        text: TextSpan(
          text: deepSkyCaption(object.name, object.category),
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width * 0.55);
      queue(label, point, priority: 4, preferred: const Offset(10, -7));
    }

    // 疑似运动天体最后画，压在最上面：它是这张图上最稀有、也最该被先看到的
    // 结论，被别的圈盖住就白判了。
    //
    // 图上总共四套记号，两两都能一眼分开：
    //
    //   * 亮星与检出点源：**实线细圆**，薄荷绿（`kMint`）。拉长的那种改画椭圆，
    //     因为「这是条线还是颗星」在图上意义完全不同。
    //   * 深空天体：**实线圆**，粉色，圆的**大小跟着天体自身的角尺寸走**——
    //     M31 用一个小圈住核心会让人以为那就是它的全部。
    //   * 行星与矮行星：**虚线圆 ＋ 十字**，琥珀色。视面在手机照片上分辨不出来，
    //     所以圈只表示「它在这儿」；十字是星历算出的位置，两个记号错开的那点距离
    //     就是这个结论的不确定度。
    //   * 彗星与小行星：**四角取景框 ＋ 十字**，浅蓝色。换形状而不是只换颜色，
    //     是因为这两类的来路不一样——那一套位置来自构建时抓的小天体目录，而不是
    //     行星那张近似根数表，精度和时效都不同；只靠深浅区分，色弱的人分不出来。
    //   * 「星历算得出位置、图上没认出来」的那一类：**点线圆**，不画十字，颜色仍
    //     按家族走（行星矮行星琥珀、小行星彗星浅蓝）。点线是这里最弱的一个记号，
    //     说的也是最弱的一个结论：位置是算出来的，亮点压根没找到。
    //
    // 用虚线是有意的：图上的虚线记号一律表示「按表算，它在这儿」，不是「我看见了」。
    final bodyPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFFFFAB40);
    final smallBodyPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFF7FD8FF);
    final predictedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFFFAB40).withValues(alpha: 0.75);
    final smallBodyPredictedPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF7FD8FF).withValues(alpha: 0.75);
    final bodyLabelStyle = const TextStyle(
      color: Color(0xFFFFAB40),
      fontSize: 10,
      fontWeight: FontWeight.w700,
      shadows: [Shadow(color: Colors.black, blurRadius: 5)],
    );
    final smallBodyLabelStyle = bodyLabelStyle.copyWith(
      color: const Color(0xFF7FD8FF),
    );
    for (final body in bodies) {
      final found = toCanvas(body.x, body.y);
      final major = body.kind.isMajorPlanet;
      // 「位置算得出来、这张图上没认出来」的那一类画**点线圆**。
      //
      // 这一类以前什么都不画，理由是「画了就等于宣称看见了」。点线比虚线再退
      // 一步，说的正是「这里只有一个算出来的位置，图上没有对应的亮点」，所以
      // 那条理由照样成立。反过来不画才是更糟的选择：用户在列表里读到「它今天
      // 在这张照片的这个位置上」，回到图上却找不到任何痕迹，只会以为是自己
      // 看漏了——而这类条目的整个存在意义就是「不静默省略」。
      if (!body.detected) {
        _dottedCircle(
          canvas,
          found,
          11,
          major ? predictedPaint : smallBodyPredictedPaint,
        );
        final missed = TextPainter(
          text: TextSpan(
            text: '${body.name} · 图上没有对上',
            style: major ? bodyLabelStyle : smallBodyLabelStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: destination.width * 0.55);
        queue(
          missed,
          found,
          priority: 0,
          preferred: const Offset(14, -20),
          force: true,
        );
        continue;
      }
      final paint = major ? bodyPaint : smallBodyPaint;
      if (major) {
        _dashedCircle(canvas, found, 11, paint);
      } else {
        _bracketFrame(canvas, found, 13, paint);
      }

      final predicted = _predictedPoint(body, toCanvas, destination, scale);
      if (predicted != null) {
        // 十字，臂长 5 像素。画成小号是有意的：它是「星历说的位置」，一个
        // 参考点，不该和那个表示检出的圈抢注意力。
        final crossPaint = major ? predictedPaint : smallBodyPredictedPaint;
        canvas.drawLine(
          predicted - const Offset(5, 0),
          predicted + const Offset(5, 0),
          crossPaint,
        );
        canvas.drawLine(
          predicted - const Offset(0, 5),
          predicted + const Offset(0, 5),
          crossPaint,
        );
      }

      final separation = body.separationArcsec;
      final label = TextPainter(
        text: TextSpan(
          text: separation < movingBodyCoincidenceArcsec
              ? '${body.name} · 位置重合'
              : '${body.name} · 差 ${separation.round()}″',
          style: major ? bodyLabelStyle : smallBodyLabelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width * 0.55);
      // 最高优先级：「疑似行星」是这张图上最稀有的结论，别的标注给它让路。
      queue(
        label,
        found,
        priority: 0,
        preferred: const Offset(14, -20),
        force: true,
      );
    }

    // 排位置，然后按排好的位置画。
    //
    // 顺序就是优先级：先排的占好位置，后来的绕开。同一段文字永远落在同一个
    // 位置（没有随机数），所以同一张图前后两次画出来的标注完全一样。
    for (final label in pending..sort((a, b) => a.priority.compareTo(b.priority))) {
      final slot = placer.place(
        label.anchor,
        Size(label.painter.width, label.painter.height),
        preferred: label.preferred,
        force: label.force,
      );
      if (slot == null) continue;
      if (slot.displaced) {
        // 挪过位置的标注拉一条细线回到它的标记点。
        //
        // 没有这条线，一个被挪开的星名就只是「飘在那儿的一段字」，用户没法
        // 判断它指的是哪颗星——那还不如让它压着别人。
        canvas.drawLine(
          label.anchor,
          _edgePoint(slot.rect, label.anchor),
          _leaderPaint,
        );
      }
      label.painter.paint(canvas, slot.rect.topLeft);
    }
  }

  /// 从矩形边界上离 [target] 最近的那个点。引线画到边界为止，不穿过文字。
  static Offset _edgePoint(Rect rect, Offset target) {
    final halfWidth = math.max(rect.width / 2, 0.001);
    final halfHeight = math.max(rect.height / 2, 0.001);
    final dx = (target.dx - rect.center.dx).abs() / halfWidth;
    final dy = (target.dy - rect.center.dy).abs() / halfHeight;
    if (dx > dy) {
      return Offset(
        target.dx < rect.center.dx ? rect.left : rect.right,
        rect.center.dy,
      );
    }
    return Offset(
      rect.center.dx,
      target.dy < rect.center.dy ? rect.top : rect.bottom,
    );
  }

  /// 星历位置画到画布上的点。没有坐标映射、或者投影算不出有限值时返回 null。
  ///
  /// 算不出来就不画这个十字，而不是退回画在圈心上：画在圈心上等于宣称
  /// 「星历位置就是这里」，而这时我们其实不知道它在哪——一个假的十字比
  /// 没有十字更坏。
  Offset? _predictedPoint(
    MovingBodySuspicion body,
    Offset Function(double, double) toCanvas,
    Rect destination,
    double scale,
  ) {
    final wcs = this.wcs;
    if (wcs == null) return null;
    final (x, y) = wcs.worldToPixel(body.ra, body.dec);
    if (!x.isFinite || !y.isFinite) return null;
    final point = toCanvas(x, y);
    // 投影出来的点跑到画布外面很远的地方时就别画了：十字会被裁掉，而连过去
    // 的空白反倒像是「差了很远」。
    if (!destination.inflate(40 * scale).contains(point)) return null;
    return point;
  }

  /// 画一个虚线圆。
  ///
  /// Canvas 没有现成的虚线，得自己把圆周按弧长切开逐段画。
  void _dashedCircle(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
    for (final metric in path.computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = math.min(start + 4, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start = end + 3;
      }
    }
  }

  /// 画一个点线圆。
  ///
  /// 给「星历算得出位置、图上却没认出来」的系内天体用。和另外两套形状都不撞：
  /// 行星那条是**虚线**圆（位置算出来、亮点也找到了），小行星彗星那条是**四角
  /// 框**；点线再退一步，表达的是「连亮点都没找到，只剩一个算出来的位置」。
  ///
  /// 点距按弧长切：点短（1.4）、间隔长（4.6），这样即使缩到很小的半径，看上去
  /// 也是点而不是虚线的短划。
  void _dottedCircle(Canvas canvas, Offset center, double radius, Paint paint) {
    final path = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
    for (final metric in path.computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = math.min(start + 1.4, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start = end + 4.6;
      }
    }
  }

  /// 画一个四角取景框——四个角上的直角，中间留空。
  ///
  /// 用小行星和彗星。形状和圆差别够大：在密密麻麻的星点里，「方框角」和「圆」
  /// 不会看混，而只换一种颜色（哪怕换得很远）在暗底小图上仍然像同一类东西。
  void _bracketFrame(Canvas canvas, Offset center, double half, Paint paint) {
    final arm = half * 0.55;
    for (final (dx, dy) in const [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]) {
      final corner = Offset(center.dx + dx * half, center.dy + dy * half);
      canvas.drawLine(corner, Offset(corner.dx - dx * arm, corner.dy), paint);
      canvas.drawLine(corner, Offset(corner.dx, corner.dy - dy * arm), paint);
    }
  }

  @override
  bool shouldRepaint(covariant DetectedStarsPainter oldDelegate) =>
      !identical(analysis, oldDelegate.analysis) ||
      !identical(namedStars, oldDelegate.namedStars) ||
      !identical(objects, oldDelegate.objects) ||
      !identical(figures, oldDelegate.figures) ||
      !identical(bodies, oldDelegate.bodies) ||
      !identical(wcs, oldDelegate.wcs) ||
      // 数目一样、又没有对方缺的元素，两个集合就是同一个。不引 foundation
      // 的 setEquals，是为了让这个文件只依赖 material 一层。
      hidden.length != oldDelegate.hidden.length ||
      !hidden.containsAll(oldDelegate.hidden) ||
      oldDelegate.selected != selected ||
      oldDelegate.selectedObjectName != selectedObjectName ||
      oldDelegate.numbers != numbers ||
      oldDelegate.arcsecPerPixel != arcsecPerPixel;
}

/// 引线。压得很淡：它是「这段字指的是那颗星」的补充说明，不该比标注本身
/// 显眼。
final _leaderPaint = Paint()
  ..strokeWidth = 0.9
  ..color = const Color(0x59A6B5C8);

/// 一个等着排位置的标注。
class _PendingLabel {
  _PendingLabel({
    required this.painter,
    required this.anchor,
    required this.priority,
    required this.preferred,
    this.force = false,
  });

  /// 已经 layout 好的文字。
  final TextPainter painter;

  /// 它指的是图上那一点（画布坐标）。
  final Offset anchor;

  /// 小的先排、先占位置。
  final int priority;

  /// 不和别人冲突时用的偏移（相对 [anchor]）——就是改版前的老位置。
  final Offset preferred;

  /// 排不下时是否仍然要画出来。
  ///
  /// 只有「这张图上唯一的那个结论」配得上这个待遇：月面圈和疑似行星。它们
  /// 被挤掉就等于这次分析白做了。编号、深空天体这种少一个不影响大局——
  /// 下面列表里都在。
  final bool force;
}

/// 排好位置的标注：该占的矩形，以及它是不是被挪开过（挪过就要拉引线）。
typedef LabelSlot = ({Rect rect, bool displaced});

/// 给图上的文字标注排位置，让它们不互相压住。
///
/// 做法是「先来后到 ＋ 就近挪位」：按优先级依次给每个标注找空位，首选原来
/// 那个偏移（所以没有冲突时画面和改版前完全一样），被占了就按左、上、下、
/// 四个斜角的顺序试。都不行就不给位置。
///
/// 不给位置是刻意的：两段压在彼此身上的文字哪一段都读不出来，少一段至少
/// 还能读另一段。而且每个标注在下面的列表里都有一行，图上没标出来不等于
/// 丢了这个对象，只说明这一处太挤。
///
/// 全程没有随机数，所以同一张图前后两次排出来的位置完全一致——这一点很
/// 重要，否则用户每滚一次屏，图上的字就会跳一次。
///
/// 公开出来是为了能单独测排版结果，不必为了断言「这两段字压住了没有」去
/// 搭一棵 widget 树再截图。
class LabelPlacer {
  LabelPlacer(this.bounds);

  /// 文字要落在这个范围里。出了边界会被卡片裁掉，等于没画。
  final Rect bounds;

  final List<Rect> _taken = [];

  /// 两个标注之间至少留的空隙。
  static const _gap = 1.5;

  /// 排一个标注；实在没地方并且 [force] 为假时返回 null。
  LabelSlot? place(
    Offset anchor,
    Size size, {
    Offset preferred = Offset.zero,
    bool force = false,
  }) {
    for (final offset in _candidates(preferred, size)) {
      final rect = _clamp(_shift(anchor, offset, size));
      if (_overlapsAnything(rect)) continue;
      _taken.add(rect);
      return (rect: rect, displaced: offset != preferred);
    }
    if (!force) return null;
    final rect = _clamp(_shift(anchor, preferred, size));
    _taken.add(rect);
    return (rect: rect, displaced: false);
  }

  Rect _shift(Offset anchor, Offset offset, Size size) => Rect.fromLTWH(
        anchor.dx + offset.dx,
        anchor.dy + offset.dy,
        size.width,
        size.height,
      );

  bool _overlapsAnything(Rect rect) {
    final padded = rect.inflate(_gap);
    for (final taken in _taken) {
      if (taken.overlaps(padded)) return true;
    }
    return false;
  }

  /// 候选位置，按尝试顺序。第一个是原来的偏移，所以不挤的时候画面不变。
  List<Offset> _candidates(Offset preferred, Size size) {
    const gap = 5.0;
    return [
      preferred,
      Offset(-size.width - gap, preferred.dy), // 左
      Offset(preferred.dx, -size.height - gap), // 上
      Offset(preferred.dx, size.height + gap), // 下
      Offset(-size.width - gap, -size.height - gap), // 左上
      Offset(gap, -size.height - gap), // 右上
      Offset(-size.width - gap, gap), // 左下
      const Offset(gap, gap), // 右下
    ];
  }

  /// 把矩形挪回画面里。贴着边的时候只能挪回来——被裁掉的文字比压着的文字
  /// 更没用。
  Rect _clamp(Rect rect) {
    final maxLeft = math.max(bounds.left, bounds.right - rect.width);
    final maxTop = math.max(bounds.top, bounds.bottom - rect.height);
    return Rect.fromLTWH(
      rect.left.clamp(bounds.left, maxLeft).toDouble(),
      rect.top.clamp(bounds.top, maxTop).toDouble(),
      rect.width,
      rect.height,
    );
  }
}

/// 一键解析的进度条。
///
/// 没有直接用 [LinearProgressIndicator]：进度条在已填充的那一段里撒了一片
/// 星点，进度往前走，星星一点点亮起来。解算动辄要等一两分钟，进度条是这
/// 段时间里屏幕上唯一在动的东西，做得像「星空正在显影」比一根灰条好。
class SkyProgressBar extends StatelessWidget {
  const SkyProgressBar({
    super.key,
    required this.value,
    this.height = 10,
    this.online = false,
    this.moon = false,
    this.moonOnly = false,
    this.solvedLocally = false,
    this.deep = false,
  });

  /// 0–1。
  final double value;
  final double height;

  /// 这一段是不是在跑在线解算。
  ///
  /// 配色跟着换：前面几步是「手机上在算」，照片没出过门；这一段是「照片已经
  /// 传上去了」，等的东西和等的心态都不一样。用户瞥一眼进度条就知道现在到
  /// 哪一段，不必去读那行小字。
  final bool online;

  /// 画面上已经认出月面。
  ///
  /// 真的时候在进度条**左侧**挂一个标记。位置是有讲究的：进度条本身说的是
  /// 「还要等多久」，而这句话说的是「等一下，这可能是另一回事」——它必须
  /// 出现在用户视线起点的左边，而不是混进右边的百分比里当又一个数字。
  ///
  /// 注意它和 [moonOnly] 是两件事：[moon] 说的是「认出来了，正等他拿主意」，
  /// [moonOnly] 说的是「他拿了主意，这次就报月亮」。
  final bool moon;

  /// 用户已经选了「直接分析月球」，这一次只报月亮。
  ///
  /// 换成银白底加蓝斑点。和其余四套配色都不一样，因为它说的是这四种都不是的
  /// 一件事：**这条链路已经不在找天体了**。薄荷绿、蓝、琥珀、红都在说「星图
  /// 解算走到哪一步」，而这一次压根没有解算——月亮上没有星表对得上的点源，
  /// 星场那一整套（星点检测、星表匹配、测光）全都跳过去了。银白是月色，蓝点
  /// 是夜里剩下的那点星光；用一套没有出现在别处的配色，用户就不用去分辨
  /// 「这次的红为什么和上次的不一样」。
  final bool moonOnly;

  /// 本机解算已经成功。
  ///
  /// 换成红色调。这是一个**结论**，不是一种进度：到这一步为止，这张照片的
  /// 天区是手机上算出来的，它一次都没离开过设备。前面几步同一条进度条可能
  /// 是薄荷绿（本机在算）或琥珀色（照片已经传上去了），而红色说的是
  /// 「不用再等了，结果已经出来了」。
  final bool solvedLocally;

  /// 本机解算已经动用最深那层星表（整张表，G < 11）。
  ///
  /// 换成蓝色调，并在进度条左端挂一句「本地深度思考」。这一层的等待和前面
  /// 两层完全不是一个量级——百万颗星的三角形索引要现建，几十秒起步——所以它
  /// 需要一个不会让人以为「卡死了」的说明。用蓝色而不是琥珀或红：这一步仍然
  /// 在手机上算，照片没出过设备，只是算得比前面几层狠。
  final bool deep;

  /// 本机那几步的填充色：薄荷绿，和全应用的主强调色一致。
  static const _localColours = <Color>[
    Color(0xFF2E8C7A),
    kMint,
    Color(0xFFCFF6EA),
  ];

  /// 最深那层星表的填充色：蓝。
  ///
  /// 星空本来的颜色，也是这几档里最快意的一种——它说的是「还在本机，只是
  /// 这次要算得久一点」。
  static const _deepColours = <Color>[
    Color(0xFF1D3F73),
    Color(0xFF4C8DFF),
    Color(0xFFC7DBFF),
  ];

  /// 在线那一段的填充色：琥珀。和「低可信 / 需要留意」用的是同一族颜色，
  /// 提醒的是「这一步依赖外部服务」，而不是「出错了」。
  static const _onlineColours = <Color>[
    Color(0xFF8A6520),
    kOnlineAmber,
    Color(0xFFFFF3C4),
  ];

  /// 本机解算成功之后的填充色：红。
  ///
  /// 红在别处通常表示出错，这里刻意反过来用：整条链路上最要紧的一件事就是
  /// 「照片有没有出过手机」，而这个红色是**只在照片确实没出去**的时候才出现
  /// 的那种红。用户看一次就会记住它，因为这不需要读任何字。
  static const _solvedColours = <Color>[
    Color(0xFF8C2A2E),
    Color(0xFFFF6B6B),
    Color(0xFFFFC9C9),
  ];

  /// 「只报月亮」那一次的填充色：银白。
  ///
  /// 三档都压得很淡，右端几乎是白——月色底下不要有太重的东西。蓝斑点由
  /// [_MoonDustPainter] 点上去：底色已经够亮，斑点要比底色**深**才看得见，
  /// 这和别的几档（深底浅点）正好相反，所以它单独一个 painter。
  static const _moonColours = <Color>[
    Color(0xFF9FB0C4),
    Color(0xFFE8EEF5),
    Color(0xFFFBFDFF),
  ];

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 月亮标记摆在进度条左边。它比进度条本身更该被先看到：进度条说
          // 的是「还要等多久」，这个标记说的是「等一下，这可能是另一回事」。
          if (moon) ...[
            const _MoonBadge(),
            const SizedBox(width: 8),
          ],
          // 「本地深度思考」也挂在左边，理由和月亮标记一样：它是这一步最
          // 需要先被看到的那句话——这次要算得久一点。
          if (deep) ...[
            const _DeepBadge(),
            const SizedBox(width: 8),
          ],
          Expanded(child: _bar()),
        ],
      );

  Widget _bar() => TweenAnimationBuilder<double>(
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
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          // 顺序有意义：只报月亮是「这条链路不在找天体」，
                          // 它压过其余四种状态——真到那一刻，剩下的几种
                          // 说的都不是这次发生的事。
                          colors: moonOnly
                              ? _moonColours
                              : solvedLocally
                                  ? _solvedColours
                                  : online
                                      ? _onlineColours
                                      : deep
                                          ? _deepColours
                                          : _localColours,
                        ),
                      ),
                      child: CustomPaint(
                        painter: moonOnly
                            ? const _MoonDustPainter()
                            : const _StarRushPainter(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 进度条上的蓝斑点，只在「只报月亮」那一次用。
///
/// 和 [_StarRushPainter] 的区别不只是颜色：那边是深底子上的白点，这边是**亮
/// 底子上的深点**。同一个白点画在银白底上等于没画——这也是它单独一个类、而
/// 不是给原来那个加个颜色参数的原因。
class _MoonDustPainter extends CustomPainter {
  const _MoonDustPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 2 || size.height <= 2) return;
    final paint = Paint()..color = const Color(0xFF2F6BD8).withValues(alpha: 0.85);
    final faint = Paint()..color = const Color(0xFF5B8FE0).withValues(alpha: 0.55);
    for (var i = 0; i < 7; i++) {
      // 和原来的星点同一套位置（黄金比取模，完全确定，没有随机数），
      // 所以同一张图上前后两次画出来的斑点位置一致。
      final x = ((i * 0.618 + 0.11) % 1.0) * size.width;
      final y = ((i * 0.377 + 0.29) % 1.0) * size.height;
      final radius = i.isEven ? 1.4 : 1.0;
      canvas.drawCircle(Offset(x, y), radius, i.isEven ? paint : faint);
    }
  }

  @override
  bool shouldRepaint(covariant _MoonDustPainter oldDelegate) => false;
}

/// 进度条左边那句「本地深度思考」。
///
/// 只在动用最深那层星表时出现。和月亮标记同一个位置、同一种做法：先给一句
/// 短语和一种颜色，再让进度条本身去说「还要等多久」。
///
/// 用文字而不是一个图标：这一步和其他步骤的区别不是「哪一类事情」，而是
/// 「这次要算得久一点」——这是一句得读的话。
class _DeepBadge extends StatelessWidget {
  const _DeepBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1D3F73),
          borderRadius: BorderRadius.circular(9),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            '本地深度思考',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFFC7DBFF),
              height: 1.1,
            ),
          ),
        ),
      );
}

/// 进度条左边那个「这是个月亮」的标记。
///
/// 画一个缺了一角的圆（凸月的样子），而不是放一个通用的图标：这个标记只
/// 在认出月面时出现，形状就是它要说的事，用户不必去读旁边的字。
class _MoonBadge extends StatelessWidget {
  const _MoonBadge();

  @override
  Widget build(BuildContext context) => Tooltip(
        message: '认出月面',
        child: SizedBox(
          width: 18,
          height: 18,
          child: CustomPaint(painter: _MoonBadgePainter()),
        ),
      );
}

class _MoonBadgePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xFFFFDE77),
    );
    // 缺的那一块用背景色盖掉，露出一个月牙。位移取半径的 0.55 倍：再少就
    // 看不出缺角，再多就不像月亮了。
    canvas.drawCircle(
      center.translate(radius * 0.55, -radius * 0.18),
      radius * 1.02,
      Paint()..color = const Color(0xFF1B2739),
    );
  }

  @override
  bool shouldRepaint(covariant _MoonBadgePainter oldDelegate) => false;
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

/// 把 [BoxFit.contain] 布局里的一次点击换算成图像像素坐标。
///
/// 点在图外的留白上返回 null——留白不是「图像的边缘」，把边缘的星点吸过去
/// 会让用户以为点中了什么。
Offset? containPointToImage({
  required Offset local,
  required Size widgetSize,
  required Size imageSize,
}) {
  if (imageSize.width <= 0 || imageSize.height <= 0) return null;
  final fitted = applyBoxFit(BoxFit.contain, imageSize, widgetSize);
  final destination = Alignment.center.inscribe(
    fitted.destination,
    Offset.zero & widgetSize,
  );
  if (!destination.contains(local)) return null;
  return Offset(
    (local.dx - destination.left) * imageSize.width / destination.width,
    (local.dy - destination.top) * imageSize.height / destination.height,
  );
}

/// 全天星图（finder chart）。
///
/// 回答的是「这张照片拍的是天上哪一块」。光有 RA/Dec 两个数字，除了老手没人
/// 能立刻在脑子里定位；一张全天图上的一个十字，比一串坐标有用得多。
///
/// 投影用等距圆柱：横轴赤经、纵轴赤纬，度和像素成正比。严格说这东西在极区
/// 变形得厉害，但它的用途是「一眼看出大概在哪儿」，不是测量——真要看细节
/// 有上面那张标注图。用等距圆柱是因为它简单到不会出错，而且星空爱好者熟悉
/// 的星图（星图软件里的全天视图）基本都长这样。
///
/// 赤经向左增大：天球上东在左，星图里把赤经反过来摆，看到的图案才是「抬头
/// 望天」的样子，而不是镜像的。这是星图的老规矩。
class AllSkyFinder extends StatelessWidget {
  const AllSkyFinder({
    super.key,
    required this.centerRa,
    required this.centerDec,
    this.fieldOfViewDegrees = 0,
    this.height = 176,
  });

  /// 视场中心赤经（度）。
  final double centerRa;

  /// 视场中心赤纬（度）。
  final double centerDec;

  /// 视场对角线尺度（度）；为 0 时不画视场圈。
  final double fieldOfViewDegrees;

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CustomPaint(
            painter: _AllSkyFinderPainter(
              centerRa: centerRa,
              centerDec: centerDec,
              fieldOfViewDegrees: fieldOfViewDegrees,
            ),
          ),
        ),
      );
}

class _AllSkyFinderPainter extends CustomPainter {
  const _AllSkyFinderPainter({
    required this.centerRa,
    required this.centerDec,
    required this.fieldOfViewDegrees,
  });

  final double centerRa;
  final double centerDec;
  final double fieldOfViewDegrees;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 60 || size.height < 40) return;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF0A1421),
    );

    // 赤经向左增大：0h 在最右，12h 在正中。
    double toX(double ra) {
      final wrapped = ra % 360;
      return size.width *
          (1 - (wrapped < 0 ? wrapped + 360 : wrapped) / 360);
    }

    double toY(double dec) =>
        size.height * (90 - dec.clamp(-90.0, 90.0)) / 180;

    final grid = Paint()
      ..color = const Color(0xFF22334A)
      ..strokeWidth = 0.8;
    final equator = Paint()
      ..color = const Color(0xFF2E8C7A)
      ..strokeWidth = 1.2;

    for (var dec = -60; dec <= 60; dec += 30) {
      final y = toY(dec.toDouble());
      canvas.drawLine(Offset(0, y), Offset(size.width, y),
          dec == 0 ? equator : grid);
    }
    for (var hour = 0; hour < 24; hour += 2) {
      final x = toX(hour * 15.0);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    final labelStyle = const TextStyle(
      color: Color(0xFF8192A8),
      fontSize: 9,
    );
    for (var hour = 0; hour < 24; hour += 6) {
      // 0h 正好落在右边缘上，居中画会有一半跑到框外，所以往回收一点。
      final x = toX(hour * 15.0).clamp(12.0, size.width - 12);
      _label(canvas, '${hour}h', Offset(x, size.height - 12), labelStyle);
    }
    // 赤纬刻度钉在左边缘，那是图上唯一一条不随视场变化的竖直参考线。
    for (final dec in const [-60, -30, 0, 30, 60]) {
      _label(
        canvas,
        dec > 0 ? '+$dec°' : '$dec°',
        Offset(4, toY(dec.toDouble()) - 11),
        labelStyle,
        alignLeft: true,
      );
    }

    final x = toX(centerRa);
    final y = toY(centerDec);

    // 视场圈。窄视场算出来不到一个像素，给个下限让用户至少看得见「在这儿」；
    // 具体多大上面那行字写着，这里只是示意。
    if (fieldOfViewDegrees > 0) {
      final half = fieldOfViewDegrees / 2;
      final radiusY = math.max(half * size.height / 180, 3.0);
      // 同样的张角，在赤经方向上要摊开更多「赤经度」，越靠近天极越明显。
      final shrink = math.max(math.cos(centerDec * math.pi / 180).abs(), 0.08);
      final radiusX =
          math.min(math.max(half * size.width / 360 / shrink, 3.0), size.width / 2);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y), width: radiusX * 2, height: radiusY * 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0x99FFDE77),
      );
    }

    final marker = Paint()..color = kMint;
    final markerLine = Paint()
      ..color = kMint
      ..strokeWidth = 1.4;
    canvas.drawLine(Offset(x - 7, y), Offset(x + 7, y), markerLine);
    canvas.drawLine(Offset(x, y - 7), Offset(x, y + 7), markerLine);
    canvas.drawCircle(Offset(x, y), 2.8, marker);
    canvas.drawCircle(
      Offset(x, y),
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = kMint.withValues(alpha: 0.55),
    );
  }

  void _label(
    Canvas canvas,
    String text,
    Offset anchor,
    TextStyle style, {
    bool alignLeft = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        alignLeft ? anchor.dx : anchor.dx - painter.width / 2,
        anchor.dy,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _AllSkyFinderPainter oldDelegate) =>
      oldDelegate.centerRa != centerRa ||
      oldDelegate.centerDec != centerDec ||
      oldDelegate.fieldOfViewDegrees != fieldOfViewDegrees;
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
              ? '横轴：标定星等（数值越大越暗）\n 纵轴：星数'
              : '横轴：图内相对星等（未标定，不是真实星等）\n 纵轴：星数',
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
