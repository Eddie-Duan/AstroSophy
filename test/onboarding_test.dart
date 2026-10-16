import 'package:astrosophy/onboarding.dart';
import 'package:astrosophy/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按真实用法把引导push进导航栈，而不是直接当 `home`。
///
/// 差别在返回键上：`automaticallyImplyLeading` 只在「有得上游可退」时才画
/// 返回键，当 home 用永远退不回去，测出来的行为就不是用户看到的那样。
Future<void> pumpOnboarding(
  WidgetTester tester, {
  required ValueChanged<AppLanguage> onDone,
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
    await pumpOnboarding(tester, onDone: (_) {});
    expect(find.text('AstroSophy'), findsOneWidget);
    expect(find.text('拍下星空，剩下交给它'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('确认并进入'), findsNothing);
  });

  testWidgets('翻到最后一页，按钮变成「确认并进入」并带回选中的语言', (tester) async {
    AppLanguage? chosen;
    await pumpOnboarding(tester, onDone: (language) => chosen = language);

    for (var page = 0; page < 4; page++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    expect(find.text('确认并进入'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);

    // 换成英文再确认：回调要带回英文，而不是默认的中文。这一页选完立刻生效，
    // 所以连按钮上的字都跟着换成英文了——要按的是英文那一个。
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm and enter'), findsOneWidget);
    await tester.tap(find.text('Confirm and enter'));
    await tester.pumpAndSettle();
    expect(chosen, AppLanguage.en);

    // 这一页选完立刻生效，是为了让用户当场看到效果——所以这里收尾时要把全局
    // 语言放回中文，否则后面几条用例会拿到一门被上一条改过的语言。
    appLanguage.value = AppLanguage.zh;
  });

  testWidgets('五页内容都能翻出来，中间不会空页', (tester) async {
    await pumpOnboarding(tester, onDone: (_) {});
    // 每页的标题，翻了就该出现。
    const titles = [
      'AstroSophy',
      '照片不出手机',
      '点一下，认出是哪颗',
      '存下来，随时翻',
      '选一门语言',
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
    await pumpOnboarding(tester, onDone: (_) {});
    // 第三个圆点的语义标签就是「第 3 页，共 5 页」，点它应该跳到结果那一页。
    await tester.tap(find.bySemanticsLabel('第 3 页，共 5 页'));
    await tester.pumpAndSettle();
    expect(find.text('点一下，认出是哪颗'), findsOneWidget);
  });

  testWidgets('首次启动只给「跳过」，不给返回键', (tester) async {
    await pumpOnboarding(tester, onDone: (_) {});
    expect(find.text('跳过'), findsOneWidget);
    // 首次启动看到的是整屏引导，不该能退回到一个空界面上去。
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('重播时能返回，也不再显示「跳过」', (tester) async {
    await pumpOnboarding(tester, onDone: (_) {}, isReplay: true);
    expect(find.text('跳过'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('引导文案里不再出现「查看指标说明」这类指路', (tester) async {
    // 用户明确要求删掉这句话：引导页应该把事讲完，而不是让用户自己去别处找。
    await pumpOnboarding(tester, onDone: (_) {});
    for (var page = 0; page < 5; page++) {
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data ?? '', isNot(contains('指标说明')));
        expect(text.data ?? '', isNot(contains('点“？”')));
      }
      if (page < 4) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('吉祥物是从资源里读的，缺图会在测试里暴露', (tester) async {
    await pumpOnboarding(tester, onDone: (_) {});
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

  testWidgets('五页各配一张自己的插画，不是同一张重复五遍', (tester) async {
    // 这条盯的是「四页共用一张吉祥物」那个旧做法：图片换成一张不难，难的是别
    // 在下次改版时又退回去。
    await pumpOnboarding(tester, onDone: (_) {});
    final assets = <String>[];
    for (var page = 0; page < 5; page++) {
      final names = tester
          .widgetList<Image>(find.byType(Image))
          .where((image) => image.image is AssetImage)
          .map((image) => (image.image as AssetImage).assetName)
          .toList();
      expect(names, hasLength(1), reason: '第 ${page + 1} 页只该有一张插画');
      assets.addAll(names);
      if (page < 4) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
    }
    expect(assets, hasLength(5));
    expect(assets.toSet(), hasLength(5), reason: '五页必须是五张不同的图');
  });
}
