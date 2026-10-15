import 'package:flutter/material.dart';

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

/// 图标：一个月牙。
///
/// 和进度条上那个认出月面的标记是同一个形状，但那是有意的——它出现在这里
/// 代表的是「夜里的那个助手」，而且月牙是这个 APP 里唯一一个既在天上、
/// 又不属于任何一张照片的符号：它不偏向星场，也不偏向月亮。
const noxIcon = Icons.nightlight_round;

/// Nox 要「熟悉」的东西：这个应用是什么、会什么、数据在哪儿。
///
/// 这段文字进系统提示，是「熟悉常用操作」这条要求的落点。写在这里而不是
/// 让模型去猜：它猜出来的「本应用支持……」八成是错的，而用户会信。
///
/// 只写事实，而且只写这个应用真的有的功能——把没有的能力写进去，用户问
/// 「帮我叠加一下」时它就会一本正经地解释一个不存在的功能。
const noxAppBrief =
    '这个应用叫 AstroSophy，把手机拍的星空照片在本机分析，算出拍到了哪片天。\n'
    '它已经有的能力：本机星点检测，并把文字、表格、大亮斑这类非星空内容剔掉；'
    '本机天区解算（内置星表，完全离线，不需要网络）；必要时把预览图上传到 '
    'Astrometry.net 在线解算（要先授权，且只有本机解算失败时才会用到）；'
    '孔径测光，用 Gaia 反推星等零点；给恒星和深空天体标名字，'
    '恒星用中文星官名，深空天体用「编号 ＋ 中文常用名」；星座连线；'
    '用「星表里这里没有星 ＋ 星历说这里有行星」推断疑似运动天体；'
    '月面的亮面占比与月相（月相需要拍摄时刻，单张照片分不出盈亏）。\n'
    '它没有的能力（用户问到就直说没有，不要编）：赤道仪或望远镜控制、'
    '多帧叠加与实时叠加、暗场平场等校准、天文摄影计划与天气预报、'
    '社区分享。它也做不了科学级测光——输入是手机单张照片。\n'
    '数据在哪：测量结果全部在本机算，照片默认不出设备；'
    '保存过的观测在本机「观星记录」里，可以查看、改名、删除；'
    '删除只删本机的测量记录和预览图，不动相册里的原图。\n';

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
        contextLabel: '当前上下文（应用概况 ＋ 本机记录 ＋ 当前图片，如果有）',
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
              Icon(noxIcon, size: 20, color: kMint),
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
                    '本轮查了：${_activity.join('、')}',
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
              const Icon(noxIcon, size: 42, color: kMint),
              const SizedBox(height: 14),
              const Text(
                '我是 $noxName，这个应用里的助手。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, height: 1.6),
              ),
              const SizedBox(height: 8),
              const Text(
                '可以问我当前这张照片拍到了什么、本机存了哪些观测，'
                '也可以让我保存、改名、删除记录，或者请求在线解算。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  color: Color(0xFFA6B5C8),
                ),
              ),
              if (_noModel) ...[
                const SizedBox(height: 18),
                const Text(
                  '还没有配置模型。Nox 需要你自己的 API Key 才能说话——'
                  '应用的测量功能不受影响，那些都在本机算。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 10),
                if (widget.onOpenSettings != null)
                  FilledButton.tonal(
                    onPressed: widget.onOpenSettings,
                    child: const Text('去配置 API'),
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
                child: Icon(noxIcon, size: 16, color: kMint),
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
              child: Icon(noxIcon, size: 16, color: kMint),
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
                decoration: const InputDecoration(
                  hintText: '问 Nox……',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.arrow_upward),
              tooltip: '发送',
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
      'get_current_report' => '读取当前分析报告',
      'find_catalog_object' => '查询当前视场天体',
      'list_observations' => '读取本机观测摘要',
      'get_observation' => '读取一条观测记录',
      'save_current_observation' => '请求保存观测',
      'rename_observation' => '请求重命名观测',
      'delete_observation' => '请求删除观测',
      'request_online_solve' => '请求在线解算',
      'propose_non_sky_regions' => '请求视觉遮罩建议',
      'open_screen' => '打开页面',
      _ => '调用工具：$name',
    };
