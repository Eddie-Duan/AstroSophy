import 'dart:async';

import 'package:astrosophy/main.dart';
import 'package:astrosophy/onboarding.dart';
import 'package:astrosophy/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首页右上角那一排入口。
///
/// 这几处出错都是「一进就坏」或「点不动」，只有把整屏真的建起来才看得见——单元
/// 测试里看不到。这里盯三件事：中文下整屏能不能建起来（框架自带的
/// `MaterialLocalizations` 缺了会让 AppBar 和弹窗直接抛异常）、一排入口在窄屏上
/// 是否都还在屏幕里、以及每个入口点下去是否真的打开了它该打开的界面。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    // 存储没有平台实现，给个空实现：这几条用例验的是界面，不是存储。
    //
    // 例外是「看过了引导」那面旗子：不把它当已看过，首次启动的引导会被自动推到
    // 首页上面，测到的就不是首页了。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method != 'read') return null;
      final arguments = call.arguments;
      final key =
          arguments is Map ? arguments['key'] as String? : null;
      return key == 'onboardingComplete' ? 'true' : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    appLanguage.value = AppLanguage.zh;
  });

  /// 建起首页。固定宽度是为了复现窄屏：一排五个入口在 320dp 上最容易放不下。
  ///
  /// 不用 `pumpAndSettle`：首页背景那一层是持续重绘的，等它「稳定」等于等到超时。
  Future<void> pumpHome(WidgetTester tester, {double width = 411}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const AstroSophyApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  final actions = <String, Finder>{
    'Nox': find.byTooltip('Nox 助手'),
    '使用引导': find.byTooltip('使用引导'),
    '观星仓库': find.byTooltip('观星仓库'),
    '界面语言': find.byTooltip('界面语言：简体中文'),
    'API': find.text('API'),
  };

  testWidgets('中文下整屏建得起来，框架自带的文案也在', (tester) async {
    await pumpHome(tester);
    expect(tester.takeException(), isNull);
    // 缺了它，AppBar 的返回键提示和弹窗的遮罩标签都会在构建时炸掉。
    final context = tester.element(find.byType(AnalysisScreen));
    expect(
      Localizations.of<MaterialLocalizations>(context, MaterialLocalizations),
      isNotNull,
    );
  });

  for (final width in <double>[320, 360, 411]) {
    testWidgets('${width.toInt()}dp 上五个入口都在屏幕里', (tester) async {
      await pumpHome(tester, width: width);
      for (final entry in actions.entries) {
        final finder = entry.value;
        expect(finder, findsOneWidget, reason: entry.key);
        final rect = tester.getRect(finder);
        expect(
          rect.left >= 0 && rect.right <= width,
          isTrue,
          reason: '${entry.key} 落在 ${rect.toString()}，屏幕宽 $width',
        );
      }
      // 放不下时 Flutter 会报 RenderFlex 溢出，这条会以异常的形式出现。
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('点语言图标弹出语言选择', (tester) async {
    await pumpHome(tester);
    await tester.tap(actions['界面语言']!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('English'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    // 选回中文就关掉了，全局语言不变，后面的用例不受影响。
    await tester.tap(find.text('简体中文'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(appLanguage.value, AppLanguage.zh);
  });

  testWidgets('点 API 胶囊打开设置面板', (tester) async {
    await pumpHome(tester);
    await tester.tap(actions['API']!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SettingsForm), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点问号进得去引导页，而且是重播的那四页', (tester) async {
    await pumpHome(tester);
    await tester.tap(actions['使用引导']!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(OnboardingPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 重播不给语言那一页：用户已经选过语言了。
    expect(find.text('拍下星空，剩下交给它'), findsOneWidget);
    expect(find.text('选一门语言'), findsNothing);
  });

  testWidgets('点「？」能弹出说明', (tester) async {
    await pumpHome(tester);
    // 首页那行格式说明旁边的问号。报告里那一排问号走的是同一个控件，
    // 所以这里点得开就说明那一排也点得开。
    await tester.tap(find.byTooltip('了解更多').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('能不能读 RAW'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本框建得起来（缺框架文案时它会整块变空白）', (tester) async {
    await pumpHome(tester);
    // 「问 Agent」那一块就是一个文本框。它构建时要取 MaterialLocalizations，
    // 取不到就在 release 下抛出异常、渲染成一大片空白——这条盯的就是那件事。
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: TextField()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('两种语言下框架自带的文案都在', (tester) async {
    for (final language in AppLanguage.values) {
      appLanguage.value = language;
      await pumpHome(tester);
      final context = tester.element(find.byType(AnalysisScreen));
      expect(
        Localizations.of<MaterialLocalizations>(context, MaterialLocalizations),
        isNotNull,
        reason: language.code,
      );
      expect(tester.takeException(), isNull, reason: language.code);
    }
  });
}
