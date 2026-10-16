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

  /// 结束引导，并把用户在最后一页选的语言交回去。
  ///
  /// 语言要跟着这个回调走，而不是在页内直接落盘：写存储是调用方的事（它还负责
  /// 写「看过了」那面旗子），两件事写在一处，中途退出才不会留下半个状态。
  final ValueChanged<AppLanguage> onDone;

  /// 重播模式：显示返回键，不再写引导标记。
  final bool isReplay;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  static const _pageCount = 5;
  static const _pageDuration = Duration(milliseconds: 360);

  final _controller = PageController();
  int _index = 0;

  bool get _isLast => _index == _pageCount - 1;

  /// 用户在最后一页选的语言。跟着页面走而不是直接写进全局：滑走了再滑回来
  /// 要看到他刚才选的那个，而不是又跳回默认值。
  late AppLanguage _language = appLanguage.value;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_isLast) {
      widget.onDone(_language);
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
              TextButton(
                onPressed: () => widget.onDone(_language),
                child: Text(t('跳过')),
              ),
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
                        _slide(4, _languageSlide()),
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
                          _isLast ? t('确认并进入') : t('下一步'),
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

  /// 最后一页：选语言。
  ///
  /// 放在最后而不是最前，是因为这一页的按钮就是「确认并进入主页」——用户翻完
  /// 四页知道这是个什么应用了，再决定用什么语言读它，比一进来先面对一个语言
  /// 列表更顺。选中的那一刻整页立刻换成那门语言，这是最直观的确认方式：不用
  /// 描述「切过去会怎样」，直接给他看。
  Widget _languageSlide() => _pageShell([
        _Hero(
          asset: 'assets/brand/astrosophy_onboarding_language.png',
          label: t('一个地球和两个对话气泡'),
        ),
        const SizedBox(height: 18),
        _Headline(t('选一门语言')),
        _Lead(t('随时能在右上角换回来')),
        const SizedBox(height: 18),
        _LanguageChoices(
          value: _language,
          onChanged: (language) {
            setState(() => _language = language);
            // 立刻生效：这一页自己的文案跟着换，用户当场看到效果。
            appLanguage.value = language;
          },
        ),
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

/// 语言选择：两个并排的卡片，各自用**这门语言自己的写法**称呼自己。
///
/// 不用下拉菜单：一共两门（以后也不会多到几十门），两个选项摊开来比藏在菜单里
/// 少一次点击，而且「简体中文 / English」并排摆着，用户扫一眼就知道该点哪个。
class _LanguageChoices extends StatelessWidget {
  const _LanguageChoices({required this.value, required this.onChanged});

  final AppLanguage value;
  final ValueChanged<AppLanguage> onChanged;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (final language in AppLanguage.values) ...[
            Expanded(
              child: _LanguageCard(
                language: language,
                selected: language == value,
                onTap: () => onChanged(language),
              ),
            ),
            if (language != AppLanguage.values.last) const SizedBox(width: 12),
          ],
        ],
      );
}

class _LanguageCard extends StatelessWidget {
  const _LanguageCard({
    required this.language,
    required this.selected,
    required this.onTap,
  });

  final AppLanguage language;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = selected ? kMint : const Color(0xFF33455F);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? kMint.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: border, width: selected ? 2 : 1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: selected ? kMint : const Color(0xFF5C7089),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    language.nativeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: selected ? kMint : const Color(0xFFC3D0E0),
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
