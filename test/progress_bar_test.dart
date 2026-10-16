import 'package:astrosophy/theme.dart';
import 'package:astrosophy/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度条上那两件事：用到最深那层星表时换成蓝色调，并在左端挂一句
/// 「本地深度思考」。
///
/// 单独测它是因为这条信息只能靠配色和一句短语传出去：这一步要等的时间比
/// 前面几层高一个量级，用户得先知道「还在算、而且这次算得久」，才不会以为
/// 程序卡死了。
void main() {
  Future<void> pump(WidgetTester tester, Widget bar) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: SizedBox(child: bar)))),
      );

  /// 填充段那层渐变。树里还有别的 [DecoratedBox]（比如左边的标记），所以按
  /// 「谁带渐变」来认，而不是按下标。
  LinearGradient fillGradient(WidgetTester tester) {
    for (final box
        in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox))) {
      final decoration = box.decoration;
      if (decoration is BoxDecoration && decoration.gradient is LinearGradient) {
        return decoration.gradient! as LinearGradient;
      }
    }
    fail('进度条没有画出填充渐变');
  }

  testWidgets('最深层：蓝色调，左端挂「本地深度思考」', (tester) async {
    await pump(tester, const SkyProgressBar(value: 0.4, deep: true));

    expect(find.text('本地深度思考'), findsOneWidget);
    final colours = fillGradient(tester).colors;
    // 蓝色调：中段那颗要明显偏蓝——只看「不是薄荷绿」不够，薄荷绿换成灰
    // 也能通过，得钉住蓝色本身。
    final middle = colours[1];
    expect(middle.b, greaterThan(middle.r));
    expect(middle.b, greaterThan(middle.g));
    expect(middle.g, greaterThan(middle.r));
    // 和本机那几步的薄荷绿（绿最亮）确实不是一套。
    expect(middle.g > middle.b, isFalse);
  });

  testWidgets('本机那几步仍然是薄荷绿，没有多余的标记', (tester) async {
    await pump(tester, const SkyProgressBar(value: 0.4));

    expect(find.text('本地深度思考'), findsNothing);
    expect(fillGradient(tester).colors[1], kMint);
  });

  testWidgets('本机解算成功之后，红色盖过蓝色', (tester) async {
    // 解算成功的那个红是**结论**：照片没出过设备。它排在最后，也是这一格
    // 里唯一该被看到的颜色——就算这次用的是最深那层，成功之后也不该继续
    // 停留在「还在算」的蓝色上。
    await pump(
      tester,
      const SkyProgressBar(value: 1, deep: true, solvedLocally: true),
    );
    expect(fillGradient(tester).colors[1], const Color(0xFFFF6B6B));
  });

  testWidgets('换上在线解算之后，琥珀色盖过蓝色', (tester) async {
    await pump(
      tester,
      const SkyProgressBar(value: 0.6, deep: true, online: true),
    );
    expect(fillGradient(tester).colors[1], const Color(0xFFFFDE77));
  });

  testWidgets('月亮标记和「本地深度思考」可以同时挂着', (tester) async {
    // 两者不打架：月亮说的是「这可能是另一回事」，深度思考说的是「这次算得久」。
    // 位置都在左端，各自占一格。
    await pump(
      tester,
      const SkyProgressBar(value: 0.2, moon: true, deep: true),
    );
    expect(find.text('本地深度思考'), findsOneWidget);
    expect(find.byType(Tooltip), findsOneWidget);
  });
}
