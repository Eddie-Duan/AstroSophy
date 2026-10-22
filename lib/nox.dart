import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'strings.dart';
import 'markdown.dart';
import 'model.dart';
import 'models.dart';
import 'theme.dart';

/// 助手的名字。
///
/// 起个名字不是为了可爱，是为了让「谁在说话」这件事有个具体的指代：报告里
/// 的每一段解读、对话框里的每一句回答都出自它，用户跟它说「帮我把这张改名」
/// 时不必先想「我在跟哪个功能说话」。
const noxName = 'Nox';

/// 旧图标常量：只在没有自定义绘制的兜底处使用。
///
/// 实际显示用 [NoxMoonIcon]：白银色月牙 + 偏黄月面 + 两个褐色环形山。
const noxIcon = Icons.nightlight_round;

/// Nox 的实际图标：一枚有环形山的月亮，而不是系统自带的那弯细月牙。
///
/// 轮廓仍是圆的，白银色月牙占左侧，剩下偏黄的部分在右侧，两个褐色斑点
/// 当环形山。尺寸很小（16–42 px）时也要能看出「这是月亮」。
class NoxMoonIcon extends StatelessWidget {
  const NoxMoonIcon({super.key, this.size = 22, this.active = false});

  final double size;

  /// 关闭时黄色月牙 + 银白月面；开启时反过来。
  final bool active;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _NoxMoonPainter(active: active),
      );
}

class _NoxMoonPainter extends CustomPainter {
  const _NoxMoonPainter({required this.active});

  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.44;
    final disc = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.save();
    canvas.clipPath(disc);

    // 底色是露在外面的月牙：关闭时黄色，开启时银白。
    final face = active ? const Color(0xFFE8EEF5) : const Color(0xFFF2C14E);
    canvas.drawCircle(center, radius, Paint()..color = face);

    // 偏移圆是月面：关闭时银白，开启时黄色。
    final crescent = active ? const Color(0xFFF2C14E) : const Color(0xFFE8EEF5);
    final silverCenter = center.translate(radius * 0.28, -radius * 0.10);
    canvas.drawCircle(
      silverCenter,
      radius * 1.02,
      Paint()..color = crescent,
    );

    // 两个褐色环形山，落在月面上。
    final craterPaint = Paint()..color = const Color(0xFF8A6A45);
    canvas.drawCircle(
      center.translate(radius * 0.62, radius * 0.05),
      radius * 0.09,
      craterPaint,
    );
    canvas.drawCircle(
      center.translate(radius * 0.52, radius * 0.38),
      radius * 0.13,
      craterPaint,
    );
    canvas.restore();

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, radius * 0.08)
        ..color = const Color(0xCC9FB3CE),
    );
  }

  @override
  bool shouldRepaint(covariant _NoxMoonPainter oldDelegate) =>
      oldDelegate.active != active;
}

/// Nox 要「熟悉」的东西：这个应用是什么、会什么、数据在哪儿。
///
/// 这段文字进系统提示，是「熟悉常用操作」这条要求的落点。写在这里而不是
/// 让模型去猜：它猜出来的「本应用支持……」八成是错的，而用户会信。
///
/// 只写事实，而且只写这个应用真的有的功能——把没有的能力写进去，用户问
/// 「帮我叠加一下」时它就会一本正经地解释一个不存在的功能。
String get noxAppBrief =>
    t('这个应用叫 AstroSophy，把手机拍的星空照片在本机分析，算出拍到了哪片天。\n它已经有的能力：本机星点检测，并把文字、表格、大亮斑这类非星空内容剔掉；本机天区解算（内置星表，完全离线，不需要网络）；必要时把预览图上传到 Astrometry.net 在线解算（要先授权，且只有本机解算失败时才会用到）；孔径测光，用 Gaia 反推星等零点；给恒星和深空天体标名字，恒星用中文星官名，深空天体用「编号 ＋ 中文常用名」；星座连线；用「星表里这里没有星 ＋ 星历说这里有行星」推断疑似运动天体；月面的亮面占比与月相（月相需要拍摄时刻，单张照片分不出盈亏）。\n它没有的能力（用户问到就直说没有，不要编）：赤道仪或望远镜控制、多帧叠加与实时叠加、暗场平场等校准、天文摄影计划与天气预报、社区分享。它也做不了科学级测光——输入是手机单张照片。\n数据在哪：测量结果全部在本机算，照片默认不出设备；保存过的观测在本机「观星仓库」里，可以查看、改名、删除；删除只删本机的测量记录和预览图，不动相册里的原图。\n');

/// Nox 干活需要的三样东西。
///
/// 都做成回调，因为 Nox 这个页面本身不该知道设置的存法、历史在哪、当前
/// 有没有图片——它是一个纯界面，把「知道这些」的部分留在外面。
class NoxBackend {
  const NoxBackend({
    required this.loadSettings,
    required this.context,
    required this.executeTool,
  });

  /// 读用户配的模型。
  final Future<ModelSettings> Function() loadSettings;

  /// 当前上下文：应用概况、本机记录摘要、以及当前图片的分析结果（如果有）。
  final Map<String, Object?> Function() context;

  /// 工具的执行入口，由 App 提供。
  final AgentToolExecutor executeTool;
}

/// Nox 的对话界面。
class NoxScreen extends StatefulWidget {
  const NoxScreen({
    super.key,
    required this.backend,
    this.onOpenSettings,
  });

  final NoxBackend backend;

  /// 没配模型时的出路。不给就只显示一行提示。
  final VoidCallback? onOpenSettings;

  @override
  State<NoxScreen> createState() => _NoxScreenState();
}

class _NoxScreenState extends State<NoxScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// 一问一答。只留这两条，不带工具调用的细节——那些细节已经体现在回答
  /// 里了，回放进去只会让上下文迅速膨胀。
  final _turns = <_NoxTurn>[];

  /// 本轮用过哪些工具，显示在输入框上方。
  ///
  /// 要显示出来：Nox 说「我看了一下你的记录」时，用户得能确认它真的看了，
  /// 而不是随口说的。这是这个应用对「说得出依据」的一贯要求，助手也不例外。
  final _activity = <String>[];

  bool _busy = false;
  bool _noModel = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _checkModel() async {
    try {
      final settings = await widget.backend.loadSettings();
      if (!mounted) return;
      setState(() => _noModel = !settings.hasAnyModel);
    } catch (_) {
      // 读不到设置不该让这个页面打不开——没有模型也还能看记录摘要。
      if (mounted) setState(() => _noModel = true);
    }
  }

  Future<void> _send() async {
    final question = _input.text.trim();
    if (question.isEmpty || _busy) return;

    final settings = await widget.backend.loadSettings();
    if (!mounted) return;
    if (!settings.hasAnyModel) {
      setState(() => _noModel = true);
      return;
    }

    final history = [
      for (final turn in _turns)
        {'role': turn.fromUser ? 'user' : 'assistant', 'content': turn.text},
    ];

    setState(() {
      _busy = true;
      _error = null;
      _activity.clear();
      _turns.add(_NoxTurn(question, fromUser: true));
      _input.clear();
    });
    _scrollToEnd();

    try {
      final text = await ModelService.chatWithTools(
        baseUrl: settings.baseUrl,
        lightKey: settings.lightKey,
        lightModel: settings.lightModel,
        strongKey: settings.strongKey,
        strongModel: settings.strongModel,
        report: widget.backend.context(),
        question: question,
        history: history,
        assistantName: noxName,
        appBrief: noxAppBrief,
        contextLabel: t('当前上下文（应用概况 ＋ 本机记录 ＋ 当前图片，如果有）'),
        executeTool: widget.backend.executeTool,
        onToolCall: (name) {
          if (!mounted) return;
          setState(() => _activity.add(noxToolLabel(name)));
        },
      );
      if (!mounted) return;
      setState(() => _turns.add(_NoxTurn(text, fromUser: false)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scrollToEnd();
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              NoxMoonIcon(size: 20),
              SizedBox(width: 8),
              Text(noxName),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _turns.isEmpty && !_busy
                    ? _emptyState()
                    : ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        children: [
                          for (final turn in _turns) _bubble(turn),
                          if (_busy) _thinking(),
                        ],
                      ),
              ),
              if (_activity.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    t('本轮查了：{0}', [_activity.join(t('、'))]),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFFA6B5C8),
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.orangeAccent,
                    ),
                  ),
                ),
              _composer(),
            ],
          ),
        ),
      );

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const NoxMoonIcon(size: 42),
              const SizedBox(height: 14),
              Text(
                t('我是 {0}，这个应用里的助手。', [noxName]),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1.6),
              ),
              const SizedBox(height: 8),
              if (_noModel) ...[
                const SizedBox(height: 18),
                Text(
                  t('还没有配置模型。Nox 需要你自己的 API Key 才能说话——应用的测量功能不受影响，那些都在本机算。'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 10),
                if (widget.onOpenSettings != null)
                  FilledButton.tonal(
                    onPressed: widget.onOpenSettings,
                    child: Text(t('去配置 API')),
                  ),
              ],
            ],
          ),
        ),
      );

  Widget _bubble(_NoxTurn turn) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!turn.fromUser)
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 8),
                child: NoxMoonIcon(size: 16),
              ),
            Expanded(
              child: turn.fromUser
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                        decoration: BoxDecoration(
                          color: kMint.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(turn.text,
                            style: const TextStyle(height: 1.5)),
                      ),
                    )
                  // 回答是 Markdown——标题、列表、粗体都得排版后再显示，
                  // 否则屏幕上就是一串裸露的 `##` 和 `**`。
                  : MarkdownText(turn.text),
            ),
          ],
        ),
      );

  Widget _thinking() => const Padding(
        padding: EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            Padding(
              padding: EdgeInsets.only(right: 8),
              child: NoxMoonIcon(size: 16),
            ),
            Text('……', style: TextStyle(color: Color(0xFFA6B5C8))),
          ],
        ),
      );

  Widget _composer() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                enabled: !_busy,
                decoration: InputDecoration(
                  hintText: t('问 Nox……'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.arrow_upward),
              tooltip: t('发送'),
            ),
          ],
        ),
      );
}

class _NoxTurn {
  const _NoxTurn(this.text, {required this.fromUser});

  final String text;
  final bool fromUser;
}

/// 工具名的中文读法，和结果页那张卡用的是同一套说法。
String noxToolLabel(String name) => switch (name) {
      'get_current_report' => t('读取当前分析报告'),
      'find_catalog_object' => t('查询当前视场天体'),
      'find_small_body' => t('查询太阳系小天体位置'),
      'list_observations' => t('读取本机观测摘要'),
      'get_observation' => t('读取一条观测记录'),
      'save_current_observation' => t('请求保存观测'),
      'rename_observation' => t('请求重命名观测'),
      'delete_observation' => t('请求删除观测'),
      'request_online_solve' => t('请求在线解算'),
      'propose_non_sky_regions' => t('请求视觉遮罩建议'),
      'open_screen' => t('打开页面'),
      _ => t('调用工具：{0}', [name]),
    };
