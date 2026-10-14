import 'package:flutter/material.dart';

import 'theme.dart';

/// 新用户引导：首次启动时自动展示，之后可从右上角的问号重播。
///
/// 结构沿用自 iGEM Fermenter 的引导页：整屏四页 slide，底部操作条固定不动，
/// 所以无论左右滑还是点按钮，圆点和按钮都不会跳位。四页的顺序按用户第一次
/// 拿到照片的真实顺序排：先导入，再看它在本机跑出了什么，然后是怎么读结果，
/// 最后是保存下来以后还能翻。
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
              TextButton(onPressed: widget.onDone, child: const Text('跳过')),
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
                          _isLast ? '开始探索' : '下一步',
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
        _mascotDialogue('嗨，我是你的观星搭子。'),
        const SizedBox(height: 16),
        const Text(
          'AstroSophy',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        const Text(
          '把随手拍下的星空，变成一张看得懂的观星记录。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14.5,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: kMint,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          '不用赤道仪，也不用先知道自己在拍哪片天。选一张照片，'
          '剩下的交给手机——找出星点、认出天区、把结果讲成你能看懂的话。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.4, color: Color(0xFFA6B5C8)),
        ),
        const SizedBox(height: 18),
        const Center(child: _Pill('内置三张演示星图，没有照片也能先试一遍')),
      ]);

  Widget _localSlide() => _pageShell([
        _mascotDialogue('照片默认不出手机——我在本机把星点找出来。'),
        const SizedBox(height: 16),
        const _SlideTitle('解析在本机进行'),
        const SizedBox(height: 8),
        const Text(
          '本机分析和本机天区解算都在手机上跑，用不着联网，也用不着账号。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, height: 1.4, color: Color(0xFFA6B5C8)),
        ),
        const SizedBox(height: 18),
        const _FeatureRow(
          icon: Icons.memory_rounded,
          title: '本机分析',
          body: '测光、对焦、噪点和光污染都在手机上算，照片不离开设备。',
        ),
        const _FeatureRow(
          icon: Icons.travel_explore_rounded,
          title: '本机天区解算',
          body: '带了一份亮星目录，直接对着星点算坐标，认出你拍的是哪片天。',
        ),
        const _FeatureRow(
          icon: Icons.cloud_off_rounded,
          title: '在线解算和 AI 都是可选的',
          body: '只有本机认不出来时才需要联网，而且要你单独点过同意才会传。',
        ),
      ]);

  Widget _resultSlide() => _pageShell([
        _mascotDialogue('点列表里第 10 项，图上就会圈出第 10 颗。'),
        const SizedBox(height: 16),
        const _SlideTitle('结果能一边看一边点'),
        const SizedBox(height: 8),
        const Text(
          '上半屏是标好的图，下半屏是图里的亮点，两边的编号一一对应。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, height: 1.4, color: Color(0xFFA6B5C8)),
        ),
        const SizedBox(height: 18),
        const _FeatureRow(
          icon: Icons.touch_app_rounded,
          title: '点哪一颗就定位哪一颗',
          body: '点图上的亮点或者点列表，另一边跟着高亮，不用自己数格子。',
        ),
        const _FeatureRow(
          icon: Icons.remove_circle_outline,
          title: '拉长的亮点可以剔除',
          body: '拖着尾巴的多半是卫星、飞机或者手抖。留着还是划掉，你说了算。',
        ),
        const _FeatureRow(
          icon: Icons.compare_rounded,
          title: '原图和处理图随时切换',
          body: '处理图扣掉天空背景、抹掉非星空的部分，星场本身看得更清楚。',
        ),
      ]);

  Widget _keepSlide() => _pageShell([
        _mascotDialogue('解析完记得保存，回头还能翻出来看。'),
        const SizedBox(height: 16),
        const _SlideTitle('存下来，慢慢看'),
        const SizedBox(height: 8),
        const Text(
          '一次拍摄的记录会连同当时的测量结果一起留在手机上。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, height: 1.4, color: Color(0xFFA6B5C8)),
        ),
        const SizedBox(height: 18),
        const _FeatureRow(
          icon: Icons.bookmark_add_outlined,
          title: '保存这一次的结果',
          body: '存档里放的是缩过的预览图，手机相册里的原图不受影响。',
        ),
        const _FeatureRow(
          icon: Icons.collections_bookmark_outlined,
          title: '在「观星记录」里回看',
          body: '右上角的书架图标就是入口，点任意一条能接着看完整结果。',
        ),
        const _FeatureRow(
          icon: Icons.delete_outline,
          title: '不想要了就删掉',
          body: '删除会连图片一起清掉，界面里会写清楚这条占了多少空间。',
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

  Widget _mascotDialogue(String dialogue) => Semantics(
        label: '助手说：$dialogue',
        child: Row(
          children: [
            SizedBox(
              width: 116,
              height: 116,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset(
                  'assets/brand/astrosophy_mascot.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF17263A),
                      border: Border.all(color: const Color(0xFF1D2B40)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      dialogue,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: Color(0xFFD8E4F2),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: const Offset(16, -1),
                    child: const CustomPaint(
                      size: Size(16, 10),
                      painter: _SpeechBubbleTailPainter(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  /// 圆点指示器：可点击跳页。
  Widget _dots() => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var index = 0; index < _pageCount; index++)
            Semantics(
              button: true,
              selected: index == _index,
              label: '第 ${index + 1} 页，共 $_pageCount 页',
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

class _SlideTitle extends StatelessWidget {
  const _SlideTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.bold,
          color: Color(0xFFFFDE77),
        ),
      );
}

/// 「图标 + 一句话标题 + 两行解释」。四页里凡是并列讲几件事的地方都用它，
/// 免得每页各写一套排版。
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: kMint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: kMint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: Color(0xFFA6B5C8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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

class _SpeechBubbleTailPainter extends CustomPainter {
  const _SpeechBubbleTailPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final tail = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(4, size.height)
      ..close();
    canvas.drawPath(tail, Paint()..color = const Color(0xFF17263A));
    canvas.drawPath(
      tail,
      Paint()
        ..color = const Color(0xFF1D2B40)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _SpeechBubbleTailPainter oldDelegate) => false;
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
