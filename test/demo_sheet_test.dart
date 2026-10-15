import 'package:astrosophy/demo.dart';
import 'package:astrosophy/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「试一张演示星图」那张卡片不许溢出。
///
/// 这是一个真实报过的 bug：条目从四张加到五张之后，一摞固定高度的 ListTile
/// 就超出了底部卡片的高度，屏幕上出现一条黄黑斜纹的溢出条。肉眼很难注意到，
/// 因为只有在屏幕矮、条目多的时候才复现——所以这里把一个矮框单独搭出来，
/// 只在真的装不下时才会失败。
void main() {
  group('演示图选择卡片', () {
    testWidgets('屏幕矮、条目多的时候能滚，不溢出', (tester) async {
      // 这个高度是按「五张演示图 + 两行标题」算的：刚好装不下。
      const sheetHeight = 400.0;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: sheetHeight,
                child: DemoPickerSheet(),
              ),
            ),
          ),
        ),
      );

      // 溢出是 FlutterError，会被测试框架记下来。断言「没有异常」就是在断言
      // 「没有溢出」。
      expect(tester.takeException(), isNull);

      // 而且列表得真的能滚：装不下的条目要够得着，不能只是「不报错」。
      expect(find.byType(ListView), findsOneWidget);
      final listView = tester.widget<ListView>(find.byType(ListView));
      expect(listView.shrinkWrap, isTrue);
    });

    testWidgets('五张演示图都列出来了，一张不少', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: DemoPickerSheet()),
        ),
      );
      // 数量对不上就说明列表被截断了——那种情况下用户看到的「没有 M45」比
      // 一条溢出条更难查。
      for (final image in demoImages) {
        expect(find.text(image.title), findsOneWidget, reason: image.title);
      }
      expect(demoImages.length, 5);
    });
  });
}
