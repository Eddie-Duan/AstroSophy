import 'package:astrosophy/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 图上的文字标注不该互相压住——这段逻辑现在能单独测了。
///
/// 原来这些位置是写死在画图代码里的（「编号画在标记点右上 5, -12」），只
/// 能靠肉眼截图看压没压住。抽成 [LabelPlacer] 之后可以直接断言矩形。
void main() {
  const label = Size(40, 12);
  const bounds = Rect.fromLTWH(0, 0, 400, 300);

  group('标注排版', () {
    test('不挤的时候用原来的位置', () {
      // 这条最重要：没有冲突时画面必须和改版前一模一样，否则每张图上所有
      // 标注都会悄悄挪一格，用户以为是新 bug。
      final placer = LabelPlacer(bounds);
      const preferred = Offset(6, 4);
      final slot = placer.place(const Offset(100, 100), label, preferred: preferred)!;
      expect(slot.displaced, isFalse);
      expect(slot.rect.topLeft, const Offset(106, 104));
    });

    test('第二个撞上来的时候自己挪开', () {
      final placer = LabelPlacer(bounds);
      const preferred = Offset(6, 4);
      final first = placer.place(const Offset(100, 100), label, preferred: preferred)!;
      // 和第一个几乎同一个点：首选位置必然压住它。
      final second = placer.place(const Offset(102, 101), label, preferred: preferred)!;
      expect(second.rect.overlaps(first.rect), isFalse);
      // 挪开了就得说一声——调用方靠这个标记决定拉不拉引线。
      expect(second.displaced, isTrue);
    });

    test('挤满一圈就不给位置，而不是压上去', () {
      final placer = LabelPlacer(bounds);
      // 同一个点反复排：八个候选位置用完就该收手。
      final placed = <Rect>[];
      for (var i = 0; i < 8; i++) {
        final slot = placer.place(const Offset(100, 100), label);
        if (slot == null) break;
        placed.add(slot.rect);
      }
      for (var i = 0; i < placed.length; i++) {
        for (var j = i + 1; j < placed.length; j++) {
          expect(placed[i].overlaps(placed[j]), isFalse,
              reason: '第 $i 个和第 $j 个压住了');
        }
      }
      expect(placed.length, lessThan(8), reason: '同一个点上不该容得下八个标注');
      expect(placer.place(const Offset(100, 100), label), isNull);
    });

    test('force 的排不下也要给位置', () {
      // 月面圈和疑似行星是「这张图上唯一的那个结论」，被挤掉等于这次分析
      // 白做了。宁可就地压着，也不能没有。
      final placer = LabelPlacer(bounds);
      for (var i = 0; i < 10; i++) {
        placer.place(const Offset(100, 100), label);
      }
      expect(placer.place(const Offset(100, 100), label), isNull);
      final forced = placer.place(const Offset(100, 100), label, force: true);
      expect(forced, isNotNull);
      expect(forced!.displaced, isFalse);
    });

    test('贴着边的标注被挪回画面里，不会被裁掉', () {
      final placer = LabelPlacer(bounds);
      final slot = placer.place(const Offset(2, 2), label, preferred: const Offset(-30, -30))!;
      expect(bounds.contains(slot.rect.topLeft), isTrue);
      expect(slot.rect.right, lessThanOrEqualTo(bounds.right));
      expect(slot.rect.bottom, lessThanOrEqualTo(bounds.bottom));
    });

    test('同样的输入排两次结果一样', () {
      // 不能有随机数：图上的字每重画一次就换地方，用户会以为点一下动了什么。
      List<Rect> layout() {
        final placer = LabelPlacer(bounds);
        return [
          for (final anchor in const [
            Offset(100, 100),
            Offset(104, 102),
            Offset(140, 100),
            Offset(100, 140),
          ])
            placer.place(anchor, label, preferred: const Offset(6, 4))!.rect,
        ];
      }

      expect(layout(), layout());
    });
  });
}
