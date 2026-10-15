import 'package:astrosophy/onboarding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按真实用法把引导push进导航栈，而不是直接当 `home`。
///
/// 差别在返回键上：`automaticallyImplyLeading` 只在「有得上游可退」时才画
/// 返回键，当 home 用永远退不回去，测出来的行为就不是用户看到的那样。
Future<void> pumpOnboarding(
  WidgetTester tester, {
  required VoidCallback onDone,
  bool isReplay = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      OnboardingPage(onDone: onDone, isReplay: isReplay),
                ),
              ),
              child: const Text('打开引导'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开引导'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('第一页讲清楚这是什么，按钮是「下一步」', (tester) async {
    await pumpOnboarding(tester, onDone: () {});
    expect(find.text('AstroSophy'), findsOneWidget);
    expect(find.text('拍下星空，剩下交给它'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('开始探索'), findsNothing);
  });

  testWidgets('翻到最后一页，按钮变成「开始探索」并回调一次', (tester) async {
    var done = 0;
    await pumpOnboarding(tester, onDone: () => done++);

    for (var page = 0; page < 3; page++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    expect(find.text('开始探索'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);

    await tester.tap(find.text('开始探索'));
    await tester.pumpAndSettle();
    expect(done, 1);
  });

  testWidgets('四页内容都能翻出来，中间不会空页', (tester) async {
    await pumpOnboarding(tester, onDone: () {});
    // 每页的标题，翻了就该出现。
    const titles = [
      'AstroSophy',
      '照片不出手机',
      '点一下，认出是哪颗',
      '存下来，随时翻',
    ];
    for (var page = 0; page < titles.length; page++) {
      expect(find.text(titles[page]), findsOneWidget, reason: '第 ${page + 1} 页');
      if (page < titles.length - 1) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('圆点能直接跳页', (tester) async {
    await pumpOnboarding(tester, onDone: () {});
    // 第三个圆点的语义标签就是「第 3 页，共 4 页」，点它应该跳到结果那一页。
    await tester.tap(find.bySemanticsLabel('第 3 页，共 4 页'));
    await tester.pumpAndSettle();
    expect(find.text('点一下，认出是哪颗'), findsOneWidget);
  });

  testWidgets('首次启动只给「跳过」，不给返回键', (tester) async {
    await pumpOnboarding(tester, onDone: () {});
    expect(find.text('跳过'), findsOneWidget);
    // 首次启动看到的是整屏引导，不该能退回到一个空界面上去。
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('重播时能返回，也不再显示「跳过」', (tester) async {
    await pumpOnboarding(tester, onDone: () {}, isReplay: true);
    expect(find.text('跳过'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('引导文案里不再出现「查看指标说明」这类指路', (tester) async {
    // 用户明确要求删掉这句话：引导页应该把事讲完，而不是让用户自己去别处找。
    await pumpOnboarding(tester, onDone: () {});
    for (var page = 0; page < 4; page++) {
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data ?? '', isNot(contains('指标说明')));
        expect(text.data ?? '', isNot(contains('点“？”')));
      }
      if (page < 3) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('吉祥物是从资源里读的，缺图会在测试里暴露', (tester) async {
    await pumpOnboarding(tester, onDone: () {});
    final images = tester
        .widgetList<Image>(find.byType(Image))
        .where((image) => image.image is AssetImage)
        .toList();
    expect(images, isNotEmpty);
    expect(
      (images.first.image as AssetImage).assetName,
      'assets/brand/astrosophy_mascot.png',
    );
  });

  testWidgets('四页各配一张自己的插画，不是同一张重复四遍', (tester) async {
    // 这条盯的是「四页共用一张吉祥物」那个旧做法：图片换成一张不难，难的是别
    // 在下次改版时又退回去。
    await pumpOnboarding(tester, onDone: () {});
    final assets = <String>[];
    for (var page = 0; page < 4; page++) {
      final names = tester
          .widgetList<Image>(find.byType(Image))
          .where((image) => image.image is AssetImage)
          .map((image) => (image.image as AssetImage).assetName)
          .toList();
      expect(names, hasLength(1), reason: '第 ${page + 1} 页只该有一张插画');
      assets.addAll(names);
      if (page < 3) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
    }
    expect(assets, hasLength(4));
    expect(assets.toSet(), hasLength(4), reason: '四页必须是四张不同的图');
  });
}
