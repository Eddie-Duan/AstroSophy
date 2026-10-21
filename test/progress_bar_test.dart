import 'package:astrosophy/theme.dart';
import 'package:astrosophy/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度条上那几件事：用到最深那层星表时换成蓝色调并在左端挂一句
/// 「本地深度思考」；用户选了「直接分析月球」之后换成银白底加蓝斑点。
///
/// 单独测它是因为这两条信息只能靠配色和一句短语传出去：前者要等的时间比
/// 前面几层高一个量级，用户得先知道「还在算、而且这次算得久」；后者压根不是
/// 进度，而是「这一次不在找天体」——星点检测、星表匹配、测光全跳过了。
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

  testWidgets('选了「直接分析月球」之后：银白底，蓝斑点', (tester) async {
    await pump(
      tester,
      const SkyProgressBar(value: 0.7, moon: true, moonOnly: true),
    );

    final colours = fillGradient(tester).colors;
    // 银白：三档都很亮，也就是「底色是亮的」——这一点和其余四套（深底浅点）
    // 正相反，蓝斑点正是靠这个才看得见。
    for (final colour in colours) {
      expect(colour.r, greaterThan(0.5));
      expect(colour.g, greaterThan(0.5));
      expect(colour.b, greaterThan(0.5));
    }
    // 右端几乎纯白，中段接近中性（左端带一点灰蓝，那是「银」的那一侧）。
    expect(colours.last.b, greaterThan(0.95));
    expect((colours[1].r - colours[1].b).abs(), lessThan(0.08));
  });

  testWidgets('银白那一套压过其余四种状态', (tester) async {
    // 只报月亮说的是「这条链路不在找天体」，和「走到哪一步」不是同一件事。
    // 真到那一刻，别的几种状态说的都不是这次发生的事，所以让位。
    await pump(
      tester,
      const SkyProgressBar(
        value: 0.7,
        moon: true,
        moonOnly: true,
        online: true,
        deep: true,
        solvedLocally: true,
      ),
    );
    expect(fillGradient(tester).colors[1], const Color(0xFFE8EEF5));
  });

  testWidgets('认出月亮就换成白色调', (tester) async {
    // 用户要求：一认出月面就换成白色调，不必等他决定只报月亮。
    await pump(tester, const SkyProgressBar(value: 0.2, moon: true));
    expect(fillGradient(tester).colors[1], const Color(0xFFE8EEF5));
  });

  testWidgets('在线或本机定位成功都收成红色调', (tester) async {
    await pump(tester, const SkyProgressBar(value: 0.8, solved: true));
    expect(fillGradient(tester).colors[1], const Color(0xFFFF6B6B));
  });
}
