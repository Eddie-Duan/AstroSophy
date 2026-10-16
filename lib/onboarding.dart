import 'package:flutter/material.dart';

import 'strings.dart';
import 'theme.dart';

/// 新用户引导：首次启动时自动展示，之后可从右上角的问号重播。
///
/// 结构沿用自 iGEM Fermenter 的引导页：整屏四页 slide，底部操作条固定不动，
/// 所以无论左右滑还是点按钮，圆点和按钮都不会跳位。四页的顺序按用户第一次
/// 拿到照片的真实顺序排：先导入，再看它在本机跑出了什么，然后是怎么读结果，
/// 最后是保存下来以后还能翻。
///
/// 文案刻意压到「一句主张 + 一句补充 + 三个短语」：引导页是广告位，用户只会扫
/// 一眼，成段的解释放在帮助里更合适。每页配一张自己的插画（见
/// `tools/make_onboarding_art.py`），四页四种风格，翻页才有节奏。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onDone, this.isReplay = false});

  /// 结束引导。首次启动时调用方负责关掉本页并写下「看过了」的标记。
  final VoidCallback onDone;

  /// 重播模式：显示返回键，不再写引导标记。
  final bool isReplay;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  static const _pageCount = 4;
  static const _pageDuration = Duration(milliseconds: 360);

  final _controller = PageController();
  int _index = 0;

  bool get _isLast => _index == _pageCount - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_isLast) {
      widget.onDone();
      return;
    }
    _controller.nextPage(duration: _pageDuration, curve: Curves.easeOutCubic);
  }

  void _goTo(int index) {
    if (index == _index) return;
    _controller.animateToPage(
      index,
      duration: _pageDuration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: widget.isReplay,
          actions: [
            if (!widget.isReplay)
              TextButton(onPressed: widget.onDone, child: Text(t('跳过'))),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                children: [
                  Expanded(
                    child: PageView(
                      controller: _controller,
                      onPageChanged: (index) => setState(() => _index = index),
                      children: [
                        _slide(0, _welcomeSlide()),
                        _slide(1, _localSlide()),
                        _slide(2, _resultSlide()),
                        _slide(3, _keepSlide()),
                      ],
                    ),
                  ),
                  _dots(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
                    child: FilledButton(
                      onPressed: _next,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          _isLast ? t('开始探索') : t('下一步'),
                          key: ValueKey<bool>(_isLast),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _slide(int index, Widget child) =>
      _SlideIn(index: index, controller: _controller, child: child);

  // -- 四页内容 --

  Widget _welcomeSlide() => _pageShell([
        _Hero(
          asset: 'assets/brand/astrosophy_mascot.png',
          label: t('吉祥物 Nox——一颗抱着望远镜的星星'),
        ),
        const SizedBox(height: 18),
        const _Headline('AstroSophy'),
        _Lead(t('拍下星空，剩下交给它')),
        const SizedBox(height: 18),
        _Chips([t('不用赤道仪'), t('不用懂天文'), t('内置演示图')]),
      ]);

  Widget _localSlide() => _pageShell([
        _Hero(
          asset: 'assets/brand/astrosophy_onboarding_local.png',
          label: t('手机屏幕里亮着一张星图'),
        ),
        const SizedBox(height: 18),
        _Headline(t('照片不出手机')),
        _Lead(t('解析全程都在本机跑')),
        const SizedBox(height: 18),
        _Chips([t('不用联网'), t('不用账号'), t('上传先问你')]),
      ]);

  Widget _resultSlide() => _pageShell([
        _Hero(
          asset: 'assets/brand/astrosophy_onboarding_result.png',
          label: t('手指点中画面里的一颗星'),
        ),
        const SizedBox(height: 18),
        _Headline(t('点一下，认出是哪颗')),
        _Lead(t('图上和列表，编号一一对应')),
        const SizedBox(height: 18),
        _Chips([t('边看边点'), t('剔除拖线'), t('原图／处理图')]),
      ]);

  Widget _keepSlide() => _pageShell([
        _Hero(
          asset: 'assets/brand/astrosophy_onboarding_keep.png',
          label: t('夹着星空照片的相册'),
        ),
        const SizedBox(height: 18),
        _Headline(t('存下来，随时翻')),
        _Lead(t('原图不动，只存预览')),
        const SizedBox(height: 18),
        _Chips([t('一键保存'), t('书架回看'), t('随时删除')]),
      ]);

  // -- 组件 --

  /// 每页统一的可滚动外壳：内容少时垂直居中，内容多时（小屏或大字号）滚动，
  /// 不会出现溢出条。
  Widget _pageShell(List<Widget> children) => LayoutBuilder(
        builder: (context, constraints) {
          final minHeight =
              constraints.maxHeight.isFinite ? constraints.maxHeight - 16 : 0.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          );
        },
      );

  /// 圆点指示器：可点击跳页。
  Widget _dots() => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var index = 0; index < _pageCount; index++)
            Semantics(
              button: true,
              selected: index == _index,
              label: t('第 {0} 页，共 {1} 页', [index + 1, _pageCount]),
              onTap: () => _goTo(index),
              child: GestureDetector(
                onTap: () => _goTo(index),
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    width: index == _index ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: index == _index ? kMint : const Color(0xFF33455F),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
}

/// 每页顶上那张插画。
///
/// 四页各用一张不同风格的图（见 `tools/make_onboarding_art.py`），而不是同一
/// 张换个台词——翻到第二页还能看到新东西，用户才有往下翻的理由。图本身是深蓝
/// 底的，压在页面背景上不会出现一块亮斑。
class _Hero extends StatelessWidget {
  const _Hero({required this.asset, required this.label});

  final String asset;

  /// 图在讲什么。这几张图就是内容本身，不写一句的话读屏用户什么都听不到。
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 188, maxHeight: 188),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset(asset, fit: BoxFit.cover, semanticLabel: label),
          ),
        ),
      );
}

/// 每页只有一句主张，这是最大的一行。
class _Headline extends StatelessWidget {
  const _Headline(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 25,
          fontWeight: FontWeight.bold,
          height: 1.2,
        ),
      );
}

/// 标题下面那句补充。一行说完，不铺开解释。
class _Lead extends StatelessWidget {
  const _Lead(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: kMint,
          ),
        ),
      );
}

/// 几个短语，替代原先成段的说明。
class _Chips extends StatelessWidget {
  const _Chips(this.items);

  final List<String> items;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [for (final item in items) _Pill(item)],
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: kMint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: kMint,
          ),
        ),
      );
}

/// 翻页时的淡入 + 轻微上移，让滑动更有层次（跟手滑动本身仍由 PageView 负责）。
class _SlideIn extends StatelessWidget {
  const _SlideIn({
    required this.index,
    required this.controller,
    required this.child,
  });

  final int index;
  final PageController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final page =
              controller.hasClients && controller.position.haveDimensions
                  ? controller.page ?? index.toDouble()
                  : index.toDouble();
          final delta = (page - index).clamp(-1.0, 1.0);
          return Opacity(
            opacity: (1 - delta.abs() * 0.8).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, delta * 32),
              child: child,
            ),
          );
        },
        child: child,
      );
}
