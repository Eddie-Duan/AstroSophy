import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as imglib;

import 'theme.dart';
import 'widgets.dart';

/// 一块**归一化**的裁剪区域：四个边都在 0–1 之间。
///
/// 用比例而不是像素存，是因为这块区域要在两个坐标系里用：屏幕上按显示尺寸
/// 画，裁图时按图像原始像素裁。这两个尺寸几乎从不相等（手机屏幕比照片小得
/// 多），存像素就得在两处之间反复换算，而每多一次换算就多一次可以错的地方。
@immutable
class CropRect {
  const CropRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  static const full = CropRect(left: 0, top: 0, right: 1, bottom: 1);

  double get width => right - left;
  double get height => bottom - top;

  /// 是不是整幅——整幅的话裁了等于没裁，可以省一次重编码。
  bool get isFull =>
      left <= 0.0001 && top <= 0.0001 && right >= 0.9999 && bottom >= 0.9999;

  CropRect clamp() => CropRect(
        left: left.clamp(0.0, 1.0),
        top: top.clamp(0.0, 1.0),
        right: right.clamp(0.0, 1.0),
        bottom: bottom.clamp(0.0, 1.0),
      );
}

/// 按 [rect] 裁出图片的一部分，重新编码成 PNG。
///
/// 裁的是**字节**，不是显示：分析、预览、以及可能的上传，从此都只看这一块。
/// 这正是用户要的效果——Seestar 那类设备会在画面下方压一条水印和信息条，
/// 一起送去解算就会被当成星点，裁掉比事后补一个掩膜干净。
///
/// 返回 null 表示这块区域太小或者根本解不出图，调用方该原样保留原来的图。
Uint8List? cropImageBytes(Uint8List bytes, CropRect rect) {
  final region = rect.clamp();
  if (region.isFull || region.width < 0.02 || region.height < 0.02) return null;
  final decoded = imglib.decodeImage(bytes);
  if (decoded == null) return null;

  // 用 floor/ceil 把区域往外取整到整像素：向内取整会把边缘切掉一个像素，
  // 而那一个像素在窄视场的星点里可能就是一颗星。多出来的一点点由 clamp
  // 挡住，不会越界。
  final x = (region.left * decoded.width).floor();
  final y = (region.top * decoded.height).floor();
  final width = (region.width * decoded.width).ceil();
  final height = (region.height * decoded.height).ceil();
  if (width < 8 || height < 8) return null;

  final cropped = imglib.copyCrop(
    decoded,
    x: x,
    y: y,
    width: width.clamp(1, decoded.width - x),
    height: height.clamp(1, decoded.height - y),
  );
  return Uint8List.fromList(imglib.encodePng(cropped));
}

/// 图像上的裁剪框：四角可以拖，框里面可以整体挪。
///
/// 只做这一件事，所以没引裁剪库：需要的能力就是「画一个框、拖它」，而裁剪库
/// 通常会连相册、旋转、比例锁定、动画一起带进来，再顺手把交互做成它自己喜欢
/// 的样子。这里要的恰恰是最朴素的那种。
class CropEditor extends StatefulWidget {
  const CropEditor({
    super.key,
    required this.bytes,
    required this.rect,
    required this.onChanged,
    this.aspectRatio = 0.82,
  });

  final Uint8List bytes;
  final CropRect rect;
  final ValueChanged<CropRect> onChanged;

  /// 显示框的宽高比，和选图卡片上那张预览保持一致。
  final double aspectRatio;

  @override
  State<CropEditor> createState() => _CropEditorState();
}

/// 正被拖的是哪儿。角上按方位记，中间就是整体平移。
enum _Grip { none, topLeft, topRight, bottomLeft, bottomRight, move }

class _CropEditorState extends State<CropEditor> {
  _Grip _grip = _Grip.none;

  /// 手指按住的位置和框左上角的差，用于整体平移——不记这个的话，一按下去
  /// 框就会跳到手指底下。
  Offset _grab = Offset.zero;

  /// 框的显示范围。图按 contain 放进这个盒子，四周可能有留白，所以要算。
  Rect _destination(Size box) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      _imageSize,
      box,
    );
    return Alignment.center.inscribe(fitted.destination, Offset.zero & box);
  }

  Size get _imageSize => _size ?? const Size(1, 1);
  Size? _size;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(covariant CropEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _size = null;
      _measure();
    }
  }

  /// 量出图片的像素尺寸。要它才能把归一化的框换算到屏幕上。
  void _measure() {
    final decoder = imglib.decodeImage(widget.bytes);
    if (decoder == null) return;
    // 同步解码一张手机照片要几十毫秒，放在 build 里每帧做一次是不能接受的，
    // 所以只做一次并记住。
    setState(() => _size = Size(
          decoder.width.toDouble(),
          decoder.height.toDouble(),
        ));
  }

  Offset _toScreen(Size box, double nx, double ny) {
    final rect = _destination(box);
    return Offset(rect.left + nx * rect.width, rect.top + ny * rect.height);
  }

  CropRect _fromDrag(_Grip grip, Offset delta, Size box) {
    final rect = _destination(box);
    final dx = delta.dx / rect.width;
    final dy = delta.dy / rect.height;
    final current = widget.rect;
    switch (grip) {
      case _Grip.topLeft:
        return CropRect(
          left: current.left + dx,
          top: current.top + dy,
          right: current.right,
          bottom: current.bottom,
        ).clamp();
      case _Grip.topRight:
        return CropRect(
          left: current.left,
          top: current.top + dy,
          right: current.right + dx,
          bottom: current.bottom,
        ).clamp();
      case _Grip.bottomLeft:
        return CropRect(
          left: current.left + dx,
          top: current.top,
          right: current.right,
          bottom: current.bottom + dy,
        ).clamp();
      case _Grip.bottomRight:
        return CropRect(
          left: current.left,
          top: current.top,
          right: current.right + dx,
          bottom: current.bottom + dy,
        ).clamp();
      case _Grip.move:
        final width = current.width;
        final height = current.height;
        // 整体平移时先夹住左上角，再把右下角按同样的尺寸放回去——逐边夹会
        // 在贴边时把框挤扁。
        final left = (current.left + dx).clamp(0.0, 1.0 - width);
        final top = (current.top + dy).clamp(0.0, 1.0 - height);
        return CropRect(
          left: left,
          top: top,
          right: left + width,
          bottom: top + height,
        );
      case _Grip.none:
        return current;
    }
  }

  /// 拖动之后把框修回合法尺寸：太窄或者太扁都要撑回来。
  CropRect _enforceMinimum(CropRect rect) {
    const minimum = 0.06;
    var left = rect.left;
    var top = rect.top;
    var right = rect.right;
    var bottom = rect.bottom;
    if (right - left < minimum) right = (left + minimum).clamp(0.0, 1.0);
    if (bottom - top < minimum) bottom = (top + minimum).clamp(0.0, 1.0);
    if (right - left < minimum) left = (right - minimum).clamp(0.0, 1.0);
    if (bottom - top < minimum) top = (bottom - minimum).clamp(0.0, 1.0);
    return CropRect(left: left, top: top, right: right, bottom: bottom);
  }

  _Grip _hitTest(Offset local, Size box) {
    final rect = widget.rect;
    final corners = <(_Grip, Offset)>[
      (_Grip.topLeft, _toScreen(box, rect.left, rect.top)),
      (_Grip.topRight, _toScreen(box, rect.right, rect.top)),
      (_Grip.bottomLeft, _toScreen(box, rect.left, rect.bottom)),
      (_Grip.bottomRight, _toScreen(box, rect.right, rect.bottom)),
    ];
    // 28 像素的判定半径：手指没有像素级精度，角上的把手要能被按住，而这个
    // 半径比半个把手略大，够得着又不至于把「框内拖动」抢走太多。
    for (final (grip, point) in corners) {
      if ((local - point).distance <= 28) return grip;
    }
    final topLeft = _toScreen(box, rect.left, rect.top);
    final bottomRight = _toScreen(box, rect.right, rect.bottom);
    if (Rect.fromPoints(topLeft, bottomRight).contains(local)) return _Grip.move;
    return _Grip.none;
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = constraints.biggest;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) {
                final grip = _hitTest(details.localPosition, box);
                _grip = grip;
                if (grip == _Grip.move) {
                  final topLeft =
                      _toScreen(box, widget.rect.left, widget.rect.top);
                  _grab = details.localPosition - topLeft;
                }
              },
              onPanUpdate: (details) {
                if (_grip == _Grip.none) return;
                // 「整体挪」用按下时的抓取点算，而不是逐帧累加：逐帧累加会把
                // 每帧的手抖都记进去，长按拖动会慢慢漂。
                if (_grip == _Grip.move) {
                  final moved = _fromDrag(
                    _Grip.move,
                    (details.localPosition - _grab) -
                        _toScreen(box, widget.rect.left, widget.rect.top),
                    box,
                  );
                  widget.onChanged(moved);
                  return;
                }
                widget.onChanged(
                  _enforceMinimum(
                    _fromDrag(_grip, details.delta, box),
                  ),
                );
              },
              onPanEnd: (_) => _grip = _Grip.none,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: const Color(0xFF05080F),
                    child: Image.memory(
                      widget.bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const MissingImage(),
                    ),
                  ),
                  CustomPaint(
                    painter: _CropOverlayPainter(
                      rect: widget.rect,
                      destination: _destination(box),
                      imageSize: _imageSize,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
}

class _CropOverlayPainter extends CustomPainter {
  const _CropOverlayPainter({
    required this.rect,
    required this.destination,
    required this.imageSize,
  });

  final CropRect rect;
  final Rect destination;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(
      destination.left + rect.left * destination.width,
      destination.top + rect.top * destination.height,
      destination.left + rect.right * destination.width,
      destination.top + rect.bottom * destination.height,
    );

    // 框外压暗。
    //
    // 用 even-odd 一次铺满，而不是画四块矩形：四块矩形在边界上会因为抗锯齿
    // 露出一条缝，看起来像框外还有一圈亮边。
    final dim = Path()
      ..addRect(Offset.zero & size)
      ..addRect(box)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    canvas.drawRect(
      box,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = kMint,
    );

    // 四个角上的把手。画成实心小方块，位置就是判定圆的中心，用户一眼能看出
    // 该按哪儿。
    final handle = Paint()..color = kMint;
    for (final corner in [
      box.topLeft,
      box.topRight,
      box.bottomLeft,
      box.bottomRight,
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: corner, width: 14, height: 14),
          const Radius.circular(3),
        ),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropOverlayPainter oldDelegate) =>
      oldDelegate.rect != rect ||
      oldDelegate.destination != destination ||
      oldDelegate.imageSize != imageSize;
}
