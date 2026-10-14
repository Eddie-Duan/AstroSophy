import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';

import 'analysis.dart';
import 'demo.dart';
import 'history.dart';
import 'history_screen.dart';
import 'model.dart';
import 'models.dart';
import 'onboarding.dart';
import 'pipeline.dart';
import 'report.dart';
import 'theme.dart';
import 'widgets.dart';

void main() => runApp(const AstroSophyApp());

class AstroSophyApp extends StatelessWidget {
  const AstroSophyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AstroSophy',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBackground,
          colorScheme: const ColorScheme.dark(
            primary: kMint,
            secondary: Color(0xFFFFDE77),
            surface: kPanel,
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(backgroundColor: kBackground),
          cardTheme: CardThemeData(
            color: kPanel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF1D2B40)),
            ),
          ),
        ),
        home: const AnalysisScreen(),
      );
}

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  final _picker = ImagePicker();
  final _storage = const FlutterSecureStorage();
  final _questionController = TextEditingController();
  Uint8List? _bytes;
  String? _filename;
  SkyAnalysis? _analysis;
  SolveResult? _solve;
  String? _explanation;
  String? _error;
  List<String> _warnings = const [];
  bool _running = false;
  bool _explaining = false;

  /// 是否允许把预览图上传到 Astrometry.net。默认不允许，且要用户在设置里
  /// 明确勾选过才为真——上传照片是不可逆的动作，不能靠一次性的弹窗确认。
  bool _uploadAllowed = false;

  /// 模型是不是配好了。没配就不在链路里排「生成解读」这一步，进度条也
  /// 不会为它留格子。
  bool _aiConfigured = false;

  bool _astrometryConfigured = false;

  PipelineProgress? _progress;

  /// 历史记录仓库。第一次用到时才打开——不存不读的会话不必碰磁盘。
  HistoryStore? _history;
  bool _saving = false;

  /// 当前这张图在历史里对应的记录 id；没保存过就是 null。
  String? _savedId;

  /// 下方列表里当前选中的那一项（`numberedTargets` 的下标）。图上的高亮环
  /// 和列表的选中底色都跟着它走，两边同号才是同一颗星。
  int? _selectedTarget;

  /// 看图区显示的是处理图还是原图。默认原图——处理图是加工过的。
  bool _showProcessed = false;

  /// 后台解算 isolate。第一次用到时才起，之后一直留着——索引建一次要一秒
  /// 上下，起一次就够。
  Future<SkyWorker>? _worker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _reloadSettings();
      await _showOnboarding(firstLaunch: true);
    });
  }

  @override
  void dispose() {
    _questionController.dispose();
    _worker?.then((worker) => worker.dispose());
    super.dispose();
  }

  /// 把设置里的开关读进内存。设置表单保存之后也要再读一次。
  Future<void> _reloadSettings() async {
    try {
      final upload = await _storage.read(key: 'allowUpload');
      final astrometry = await _storage.read(key: 'astrometryKey') ?? '';
      final settings = await _readModelSettings();
      if (!mounted) return;
      setState(() {
        _uploadAllowed = upload == 'true';
        _astrometryConfigured = astrometry.trim().isNotEmpty;
        _aiConfigured = settings.hasAnyModel;
      });
    } on Exception catch (error) {
      _showError('无法读取设置：$error');
    }
  }

  Future<SkyWorker> _ensureWorker() => _worker ??= SkyWorker.spawn();

  /// 打开新手引导。
  ///
  /// [firstLaunch] 为真时只在没看过的情况下打开，并且不给返回键——首次启动
  /// 看到的应该是整屏引导，而不是浮在空界面上的一个弹窗。之后的每一次重播都
  /// 是用户主动点的，能进能退。
  Future<void> _showOnboarding({bool firstLaunch = false}) async {
    try {
      if (firstLaunch &&
          await _storage.read(key: 'onboardingComplete') == 'true') {
        return;
      }
      if (!mounted) return;
      final navigator = Navigator.of(context);
      await navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => OnboardingPage(
            isReplay: !firstLaunch,
            onDone: () {
              if (navigator.canPop()) navigator.pop();
              unawaited(_markOnboarded());
            },
          ),
        ),
      );
    } on Exception catch (error) {
      _showError('无法打开新手引导：$error');
    }
  }

  /// 写下「看过了」。写失败最多让用户下次再看一遍引导，不值得为此弹错误框。
  Future<void> _markOnboarded() async {
    try {
      await _storage.write(key: 'onboardingComplete', value: 'true');
    } on Exception {
      return;
    }
  }

  Future<void> _selectImage(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 100,
        requestFullMetadata: false,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      _setImage(bytes, file.name);
    } catch (error) {
      _showError('读取图片失败：$error');
    }
  }

  Future<void> _selectFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg', 'jpeg', 'png', 'webp', 'tif', 'tiff', 'dng', 'cr2',
          'cr3', 'nef', 'arw', 'raf', 'orf', 'rw2',
        ],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) throw StateError('没有读取到图片内容。');
      if (!mounted) return;
      _setImage(bytes, file.name);
    } catch (error) {
      _showError('读取图片失败：$error');
    }
  }

  /// 选中一张新图。三个入口（相册、相机、演示图）共用这一处清理逻辑：
  /// 换图就等于把上一张的解析结果全部作废，漏清一项就会出现「这张图的
  /// 坐标配着那张图的星点」这种最难查的错。
  void _setImage(Uint8List bytes, String name) {
    setState(() {
      _bytes = bytes;
      _filename = name;
      _analysis = null;
      _solve = null;
      _explanation = null;
      _error = null;
      _warnings = const [];
      _savedId = null;
      // 编号只在同一张图里有意义，换图必须把选中项清掉，否则新图会在第 10
      // 号位置高亮一颗跟用户完全无关的星。
      _selectedTarget = null;
      _showProcessed = false;
    });
  }
  Future<void> _pickDemoImage() async {
    final choice = await showModalBottomSheet<DemoImage>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '试一张演示星图',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                '三张都是真实拍摄的星空照片，可以直接走完整的解析流程。',
                style: TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
              ),
            ),
            for (final image in demoImages)
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    image.asset,
                    width: 46,
                    height: 46,
                    fit: BoxFit.cover,
                  ),
                ),
                title: Text(image.title),
                subtitle: Text(
                  image.subtitle,
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.of(context).pop(image),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      final bytes = await loadDemoImage(choice);
      if (!mounted) return;
      _setImage(bytes, '${choice.title}.jpg');
    } catch (error) {
      _showError('读取演示图片失败：$error');
    }
  }

  /// 一键解析：本地分析 → 本机解算 →（失败且已授权）在线解算 → AI 解读。
  ///
  /// 这条链路是「一键」的：用户只需要点一次。跑哪几步由已配置的 API 决定，
  /// 没配的部分自动跳过，不需要用户先想清楚自己配了什么。
  Future<void> _run() async {
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() {
      _running = true;
      _error = null;
      _warnings = const [];
      _solve = null;
      _explanation = null;
      // 重新解析出来的是新的一份结果，和之前存过的那条记录不再是一回事，
      // 要能再存一次。
      _savedId = null;
      _selectedTarget = null;
      _progress = const PipelineProgress(0.01, '正在准备');
    });
    try {
      final worker = await _ensureWorker();
      final settings = await _readModelSettings();
      final key = (await _storage.read(key: 'astrometryKey') ?? '').trim();
      final outcome = await SkyPipeline(
        worker: worker,
        astrometryKey: key,
        allowUpload: _uploadAllowed,
        modelSettings: settings,
      ).run(
        bytes,
        question: _questionController.text,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _analysis = outcome.analysis;
        _solve = outcome.solve;
        _explanation = outcome.explanation;
        _warnings = outcome.warnings;
      });
    } catch (error) {
      _showError('解析失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _progress = null;
        });
      }
    }
  }

  /// 只重跑解读。坐标、测光都是现成的，没必要为了换一句问法重算一遍。
  Future<void> _explain() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final settings = await _readModelSettings();
    if (!settings.hasAnyModel) {
      _showError('请先在设置中配置至少一个兼容 OpenAI 接口的模型 API Key。');
      return;
    }
    setState(() {
      _explaining = true;
      _error = null;
    });
    try {
      final text = await ModelService.explain(
        baseUrl: settings.baseUrl,
        lightKey: settings.lightKey,
        lightModel: settings.lightModel,
        strongKey: settings.strongKey,
        strongModel: settings.strongModel,
        report: buildAgentReport(analysis, _solve),
        question: _questionController.text,
      );
      if (mounted) setState(() => _explanation = text);
    } catch (error) {
      _showError('模型解读失败：$error');
    } finally {
      if (mounted) setState(() => _explaining = false);
    }
  }

  Future<ModelSettings> _readModelSettings() async => ModelSettings(
        baseUrl:
            (await _storage.read(key: 'modelBaseUrl')) ?? 'https://api.deepseek.com/v1',
        lightKey: (await _storage.read(key: 'lightKey')) ?? '',
        lightModel:
            (await _storage.read(key: 'lightModel')) ?? 'deepseek-chat',
        strongKey: (await _storage.read(key: 'strongKey')) ?? '',
        strongModel:
            (await _storage.read(key: 'strongModel')) ?? 'deepseek-reasoner',
      );

  Future<void> _settings() async {
    final current = await _readModelSettings();
    final astrometryKey = await _storage.read(key: 'astrometryKey') ?? '';
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPanel,
      builder: (_) => SettingsForm(
        current: current,
        astrometryKey: astrometryKey,
        allowUpload: _uploadAllowed,
        storage: _storage,
      ),
    );
    await _reloadSettings();
  }

  /// 上传授权放在设置里，不是每张图都问一遍。
  ///
  /// 每次解析前再弹一次勾选框，用户会条件反射地点「同意」——那种同意没有
  /// 意义。放进设置里、默认关闭、并且把「会上传预览图」写进按钮下面那行
  /// 提示，用户才有机会真的看清楚自己授权了什么。
  Widget _runButton() {
    final progress = _progress;
    if (_running && progress != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      progress.stage,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${(progress.fraction * 100).round()}%',
                    style: const TextStyle(
                      color: kMint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SkyProgressBar(value: progress.fraction),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.auto_awesome),
            label: Text(_analysis == null ? '一键解析' : '重新解析'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _runHint,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
        ),
        const SizedBox(height: 12),
        _actionRow(analysis: _analysis),
      ],
    );
  }

  /// 「保存」和「退出」。
  ///
  /// 这两件事原来没有出口：解析完一张图之后，想换一张只能从相册再选一张，
  /// 想要的东西也没法留档。保存只在有解析结果时才可用——光有一张图没什么
  /// 可存的，存下来也只是占地方。
  Widget _actionRow({required SkyAnalysis? analysis}) => Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              // 已经存过的这一份不能再存：每保存一次就是一条新记录，连点
              // 两下会得到两条一模一样的档案。重新解析之后才重新可用。
              onPressed:
                  analysis == null || _saving || _savedId != null ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_savedId == null
                      ? Icons.bookmark_add_outlined
                      : Icons.bookmark_added),
              label: Text(
                _saving
                    ? '正在保存…'
                    : _savedId == null
                        ? '保存'
                        : '已保存',
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _running ? null : _exit,
              icon: const Icon(Icons.close_fullscreen_rounded),
              label: const Text('退出'),
            ),
          ),
        ],
      );

  Future<HistoryStore> _ensureHistory() async =>
      _history ??= await HistoryStore.open();

  /// 保存当前这一次的解析结果。
  Future<void> _save() async {
    final analysis = _analysis;
    if (analysis == null || _saving) return;
    setState(() => _saving = true);
    try {
      final store = await _ensureHistory();
      final saved = await store.save(
        name: _filename ?? '未命名',
        analysis: analysis,
        // 存的是剔除后的解算结果，和屏幕上看到的一致。剔除项本身跟着
        // `analysis.stars` 的 `isRejected` 一起存，重开还能改回来。
        solve: _solve?.withoutRejected(analysis.stars),
        explanation: _explanation,
      );
      _savedId = saved.id;
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存到观星记录')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showError('保存失败：$error');
    }
  }

  /// 退出：把当前这张图和它的解析结果清掉，回到刚打开 APP 的样子。
  ///
  /// 已经保存过的记录不受影响——「退出」清的是工作台，不是档案柜。
  void _exit() {
    setState(() {
      _bytes = null;
      _filename = null;
      _analysis = null;
      _solve = null;
      _explanation = null;
      _error = null;
      _warnings = const [];
      _progress = null;
      _savedId = null;
      _selectedTarget = null;
      _showProcessed = false;
    });
  }

  Future<void> _openHistory() async {
    try {
      final store = await _ensureHistory();
      if (!mounted) return;
      final entry = await Navigator.of(context).push<SavedAnalysis>(
        MaterialPageRoute(builder: (_) => HistoryScreen(store: store)),
      );
      if (entry == null || !mounted) return;
      final analysis = await entry.readAnalysis();
      if (!mounted) return;
      setState(() {
        // 打开历史记录用的是存下来的预览图，不是原图——存的时候就没存原图
        // （用户相册里本来就有）。所以从历史里再点「重新解析」，跑的是这张
        // 缩小过的图。星点位置不受影响，能测到的最暗星等会差一点。
        _bytes = analysis.preview;
        _filename = entry.name;
        _analysis = analysis;
        _solve = entry.solve;
        _explanation = entry.explanation;
        _error = null;
        _warnings = const [];
        _progress = null;
        _savedId = entry.id;
        _selectedTarget = null;
        _showProcessed = false;
      });
    } catch (error) {
      _showError('打开历史记录失败：$error');
    }
  }

  /// 按钮下面那行小字：这一次点下去到底会跑哪几步。
  ///
  /// 「配了几个 Key、分别管什么用」是这个 APP 里最容易搞混的事。与其让用户
  /// 自己回忆，不如每次都写清楚，尤其是哪一步会把照片发出去。
  String get _runHint {
    final sharesUpload = _astrometryConfigured && _uploadAllowed;
    final steps = <String>[
      '本机分析',
      '本机解算天区',
      if (sharesUpload) '必要时在线解算',
      if (_aiConfigured) 'AI 解读',
    ];
    final tail = sharesUpload
        ? '；只有本机解算不出来时才会把预览图上传到 Astrometry.net'
        : '；全程不上传图片';
    return '将执行：${steps.join(' → ')}$tail。';
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    // 用户剔除掉的亮点不进报告：星表、测光、摘要和交给模型的读法都以过滤后
    // 的这一份为准。图上仍然画着它们（划掉），所以剔除随时可以反悔。
    final solve = _solve?.withoutRejected(analysis?.stars ?? const []);
    return Scaffold(
      appBar: AppBar(
        title: const Text('✦  星鉴'),
        actions: [
          IconButton(
            onPressed: () => _showOnboarding(),
            tooltip: '使用引导',
            icon: const Icon(Icons.help_outline_rounded),
          ),
          IconButton(
            onPressed: _openHistory,
            tooltip: '观星记录',
            icon: const Icon(Icons.collections_bookmark_outlined),
          ),
          IconButton(
            onPressed: _settings,
            tooltip: 'API 设置',
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: StarfieldPainter())),
            ListView(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 32),
              children: [
                Text(
                  'AstroSophy',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                ),
                const Text(
                  '把随手拍下的星空，变成一张看得懂的观星记录。',
                  style: TextStyle(color: Color(0xFFA6B5C8)),
                ),
                const SizedBox(height: 20),
                if (_bytes == null) _emptyPicker() else _imagePreview(),
                const SizedBox(height: 14),
                if (_bytes != null) _runButton(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                  ),
                ],
                if (_warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  for (final warning in _warnings) _warningCard(warning),
                ],
                if (analysis != null) ...[
                  const SizedBox(height: 18),
                  // 上半屏看图、下半屏点星点，两块必须同时在视野里：点第 10
                  // 号亮点却看不到图上的 ⑩，这套编号就没有意义了。所以这块
                  // 是固定高度的，不随页面滚动拆开。下面那些卡片才需要滚。
                  SizedBox(
                    height: math.max(
                      MediaQuery.sizeOf(context).height * 0.88,
                      560,
                    ),
                    child: _interactivePanel(analysis, solve),
                  ),
                  const SizedBox(height: 14),
                  // 顺序按「用户此刻想知道什么」排：这张拍到了什么 →
                  // 拍得怎么样 → 具体是哪些星 → 装备能拍到多暗。
                  _observationCard(analysis, solve),
                  const SizedBox(height: 12),
                  _magnitudeCard(analysis, solve),
                  if (solve != null && solve.namedStars.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _starTableCard(analysis, solve),
                  ],
                  const SizedBox(height: 12),
                  _diagnosticsCard(analysis),
                  const SizedBox(height: 12),
                  _solveCard(solve),
                  const SizedBox(height: 12),
                  _photometryCard(analysis, solve),
                  if (solve != null && solve.deepSkyObjects.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _deepSkyCard(solve),
                  ],
                  const SizedBox(height: 12),
                  _agentCard(),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyPicker() => Column(
        children: [
          Container(
            height: 246,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF182A42), Color(0xFF0D1828), Color(0xFF101A2A)],
              ),
              border: Border.all(color: const Color(0xFF263A55)),
              boxShadow: const [
                BoxShadow(color: Color(0x331BD6B0), blurRadius: 30, spreadRadius: -15),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                const Positioned.fill(child: CustomPaint(painter: OrbitPainter())),
                Positioned(
                  left: 20,
                  top: 22,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x3364D9BD),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0x5564D9BD)),
                    ),
                    child: const Text(
                      'PERSONAL SKY OBSERVATORY',
                      style: TextStyle(
                        color: kMint,
                        fontSize: 9,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  left: 22,
                  bottom: 25,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '今夜，抬头见星。',
                        style: TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 7),
                      Text(
                        '上传一张星空照片，开始探索它的故事。',
                        style: TextStyle(color: Color(0xFFB2C0D2), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _selectFile,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('从相册选择'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: () => _selectImage(ImageSource.camera),
                tooltip: '拍摄照片',
                icon: const Icon(Icons.camera_alt_outlined),
                style: IconButton.styleFrom(
                  minimumSize: const Size(50, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(width: 8),
              // 比旁边两个小一号：演示图是「先随便试一张」的入口，
              // 不是主要路径，但它必须自己说出用途——第一次打开的人
              // 手里通常没有星空照片，看不到这个入口就只会对着一张空页。
              TextButton.icon(
                onPressed: _pickDemoImage,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('演示图', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'JPG / PNG / TIFF · 支持尝试读取相机 RAW 内嵌预览 · 没有照片就点「演示图」',
            style: TextStyle(color: Color(0xFF8192A8), fontSize: 11),
          ),
        ],
      );

  /// 选好图但还没解析时的那张预览卡。
  ///
  /// 解析完之后这里只剩一条文件名——标注图挪到了下面的联动面板里，那份更大
  /// 还能点。同一张图在一屏里画两遍，用户会以为有两张，也白占半屏高度。
  Widget _imagePreview() {
    if (_analysis != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.image_outlined, color: kMint),
          title: Text(
            _filename ?? '已选图片',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('解析结果见下方', style: TextStyle(fontSize: 11)),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 0.82,
            child: _isRawName(_filename ?? '')
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.raw_on, size: 42, color: kMint),
                        SizedBox(height: 10),
                        Text('相机 RAW · 将尝试读取内嵌预览'),
                      ],
                    ),
                  )
                : Image.memory(
                    _bytes!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, error, __) => Center(
                      child: Text(
                        '暂不支持此图片格式：$error',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Text(
              _filename ?? '已选图片',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _diagnosticsCard(SkyAnalysis analysis) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SectionTitle('图像诊断', Icons.monitor_heart_outlined),
                  _HelpButton(
                    title: '图像指标说明',
                    message:
                        '视觉背景指数会受曝光、ISO、白平衡和后期处理影响，不是 SQM 光度或 Bortle 等级。'
                        '线状候选可能来自拖线、失焦或处理伪影，单张图片不能确认卫星或飞机。',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MetricChip('质量', analysis.quality),
                  MetricChip('紧凑点源', '${analysis.compactSources.length}'),
                  if (analysis.streakCandidates.isNotEmpty)
                    MetricChip('线状候选', '${analysis.streakCandidates.length}'),
                  MetricChip('背景噪声', '${(analysis.noise * 100).toStringAsFixed(1)}%'),
                  MetricChip('视觉背景', '${analysis.backgroundIndex.toStringAsFixed(0)} / 100'),
                ],
              ),
              ...analysis.diagnostics.take(2).map(
                (item) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '• $item',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  // -------------------------------------------------------------------------
  // 图像与星点的联动面板
  // -------------------------------------------------------------------------

  /// 上半屏看图、下半屏点星点。
  ///
  /// 两块共享一屏是刻意的：用户要做的判断是「列表里第 10 项，在图上到底是
  /// 哪一颗」，这个问题只有在两边同时可见时才能回答。所以不折叠、不翻页，
  /// 5:6 分屏——图上留白多，列表还要放两行字。
  Widget _interactivePanel(SkyAnalysis analysis, SolveResult? solve) => Column(
        children: [
          Expanded(flex: 5, child: _imagePanel(analysis, solve)),
          const SizedBox(height: 10),
          Expanded(flex: 6, child: _highlightsCard(analysis, solve)),
        ],
      );

  Widget _imagePanel(SkyAnalysis analysis, SolveResult? solve) {
    final bytes = _showProcessed ? analysis.processedPreview : analysis.preview;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF05080F)),
          LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _selectNearest(
                details.localPosition,
                constraints.biggest,
                analysis,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, error, __) => Center(
                      child: Text('$error', textAlign: TextAlign.center),
                    ),
                  ),
                  CustomPaint(
                    painter: DetectedStarsPainter(
                      analysis: analysis,
                      namedStars: solve?.namedStars ?? const [],
                      objects: solve?.deepSkyObjects ?? const [],
                      selected: _selectedTarget,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(left: 8, top: 8, child: _imageModeToggle()),
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _selectionHint(analysis, solve),
          ),
        ],
      ),
    );
  }

  /// 原图 / 处理图切换。
  ///
  /// 处理图扣掉了天空背景、抹掉了非星场区域，星场本身反而看得更清楚；但它
  /// 是加工过的，不能拿来判断「我到底拍到了什么」。所以两张都留着，默认给
  /// 用户看没动过的原图。
  Widget _imageModeToggle() => SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('原图')),
          ButtonSegment(value: true, label: Text('处理图')),
        ],
        selected: {_showProcessed},
        showSelectedIcon: false,
        onSelectionChanged: (values) =>
            setState(() => _showProcessed = values.first),
        style: const ButtonStyle(
          visualDensity: VisualDensity(horizontal: -3, vertical: -3),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
        ),
      );

  /// 图下方那一小块说明：现在选中的是第几号，或者提示这套编号怎么用。
  Widget _selectionHint(SkyAnalysis analysis, SolveResult? solve) {
    final targets = analysis.numberedTargets;
    final index = _selectedTarget;
    final String text;
    if (index == null || index >= targets.length) {
      text = '点图中的亮点，或点下方列表——两边编号一一对应';
    } else {
      final star = targets[index];
      final position =
          '像素 (${star.x.toStringAsFixed(0)}, ${star.y.toStringAsFixed(0)})';
      if (star.isRejected) {
        text = '第 ${index + 1} 号 · $position · 已剔除，不计入报告';
      } else {
        final name = _nearestNamed(star, solve?.namedStars ?? const []);
        final what =
            name?.name ?? (star.isElongated ? '拉长的亮点' : '图内亮点');
        text = '第 ${index + 1} 号 · $what · $position · ${star.confidenceLabel}';
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }

  /// 点图上的某个位置，选中离它最近的那一项。
  ///
  /// 判定半径按**图像**像素给（22 像素），不是屏幕像素：图被缩到原来一半都
  /// 不到，按屏幕像素判会让用户明明点在 A 星上、却选中二十几像素外的 B 星。
  /// 22 像素比典型 FWHM（三四个像素）宽得多，是为了让手指能点得中；真点偏
  /// 了，用户还能从下方列表里纠正回来。
  void _selectNearest(Offset local, Size widgetSize, SkyAnalysis analysis) {
    final point = containPointToImage(
      local: local,
      widgetSize: widgetSize,
      imageSize: Size(analysis.width.toDouble(), analysis.height.toDouble()),
    );
    if (point == null) return;
    final targets = analysis.numberedTargets;
    var best = -1;
    var bestDistance = 22.0;
    for (var index = 0; index < targets.length; index++) {
      final star = targets[index];
      final distance = math.sqrt(
        math.pow(star.x - point.dx, 2) + math.pow(star.y - point.dy, 2),
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    // 点在空处就什么都不选——硬吸到最近的一颗会让用户以为自己点中了。
    if (best < 0) return;
    setState(() => _selectedTarget = best);
  }

  Widget _highlightsCard(SkyAnalysis analysis, SolveResult? solve) {
    final targets = analysis.numberedTargets;
    final rejected = targets.where((star) => star.isRejected).length;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: SectionTitle('图内亮点', Icons.blur_on_rounded),
                ),
                if (rejected > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: MetricChip('已剔除', '$rejected'),
                  ),
                const _HelpButton(
                  title: '图内亮点',
                  message:
                      '编号与上图里的编号一一对应，点一行就能在图上定位到那一颗。'
                      '拉长的亮点可能是卫星、飞机或赤道仪抖动，也可能是被拖了尾的恒星——'
                      '单张照片无法确认是哪一种。剔除只是把它排除在测光和报告之外，'
                      '并不表示它一定不是天体，随时可以恢复。',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: targets.isEmpty
                ? const Center(
                    child: Text(
                      '没有检出可信的亮点。',
                      style: TextStyle(color: Color(0xFF8192A8)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 10),
                    itemCount: targets.length,
                    itemBuilder: (context, index) =>
                        _highlightRow(targets, index, solve),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _highlightRow(
    List<DetectedStar> targets,
    int index,
    SolveResult? solve,
  ) {
    final star = targets[index];
    final name = _nearestNamed(star, solve?.namedStars ?? const []);
    final zeroPoint = solve?.magnitudeZeroPoint;
    // 标定过就给真实星等，没标定就退回星表星等或图内相对亮度——三者不能混
    // 着看，所以每行只在末尾写一个数，且用不同的记号区分来源。
    final magnitude = zeroPoint != null && star.confidence >= 0.25
        ? 'G ${(star.instrumentalMagnitude + zeroPoint).toStringAsFixed(2)}'
        : name?.magnitude != null
            ? '${name!.magnitudeBand} ${name.magnitude!.toStringAsFixed(2)}'
            : 'Δm ${_relativeMagnitude(star, targets.first).toStringAsFixed(2)}';

    return ListTile(
      dense: true,
      selected: index == _selectedTarget,
      selectedTileColor: kMint.withValues(alpha: 0.10),
      onTap: () => setState(() => _selectedTarget = index),
      leading: CircleAvatar(
        radius: 15,
        backgroundColor: star.isRejected
            ? const Color(0x33FF7B8C)
            : kMint.withValues(alpha: 0.16),
        child: Text(
          star.isRejected ? '✕' : '${index + 1}',
          style: TextStyle(
            color: star.isRejected ? const Color(0xFFFF7B8C) : kMint,
            fontSize: 12,
          ),
        ),
      ),
      title: Text(
        name?.name ?? (star.isElongated ? '拉长的亮点' : '图内亮点'),
        style: TextStyle(
          decoration: star.isRejected ? TextDecoration.lineThrough : null,
          color: star.isRejected ? const Color(0xFF8192A8) : null,
        ),
      ),
      subtitle: Text(
        _highlightSubtitle(star, name),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(magnitude, style: const TextStyle(fontSize: 12)),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: star.isRejected ? '恢复这一项' : '剔除这一项',
            onPressed: () => _toggleRejection(star),
            icon: Icon(
              star.isRejected
                  ? Icons.add_circle_outline
                  : Icons.do_not_disturb_on_outlined,
              size: 19,
              color: star.isRejected ? kMint : const Color(0xFF8192A8),
            ),
          ),
        ],
      ),
    );
  }

  String _highlightSubtitle(DetectedStar star, SkyObject? name) {
    final position =
        '像素 (${star.x.toStringAsFixed(0)}, ${star.y.toStringAsFixed(0)})';
    if (star.isElongated) {
      return '长宽比 ${star.axisRatio.toStringAsFixed(1)}:1 · '
          '可能是卫星、飞机或抖动 · $position';
    }
    final category =
        name?.category.isNotEmpty == true ? '${name!.category} · ' : '';
    return '$category$position · '
        '${star.confidenceLabel} ${(star.confidence * 100).toStringAsFixed(0)}%';
  }

  /// 剔除 / 恢复一项。
  ///
  /// 剔除不是删除：`withRejection` 只是把这一项标成「不算数」，它仍在图上和
  /// 列表里（划掉显示），用户随时能反悔。测光、报告和交给模型的摘要只认没被
  /// 标的那批——所以剔除一改，重新生成的解读也跟着变。
  void _toggleRejection(DetectedStar target) {
    final analysis = _analysis;
    if (analysis == null) return;
    setState(() {
      _analysis = analysis.withRejection(target, !target.isRejected);
    });
  }

  /// 亮星与测光。默认折叠——这一张是给想深究的人看的，第一眼看结果的人不
  /// 需要它。
  Widget _photometryCard(SkyAnalysis analysis, SolveResult? solve) {
    final zeroPoint = solve?.magnitudeZeroPoint;
    final stars = [...analysis.compactSources]
      ..sort((first, second) =>
          first.instrumentalMagnitude.compareTo(second.instrumentalMagnitude));
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.straighten_rounded, color: kMint),
        title: const Text(
          '亮星与测光',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          zeroPoint == null
              ? '尚未标定星等零点，只能比较图内相对亮度'
              : 'Gaia G 近似标定 · 零点 ${zeroPoint.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MetricChip('可测光点源', '${stars.length}'),
              MetricChip('点源 FWHM', '${analysis.fwhm.toStringAsFixed(1)} px'),
              if (solve?.magnitudeScatter != null)
                MetricChip(
                  '标定散布',
                  '±${solve!.magnitudeScatter!.toStringAsFixed(2)} 等',
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (stars.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('没有可用于恒星测光的紧凑点源。'),
            )
          else
            ...stars.take(8).map((star) {
              final name = _nearestNamed(star, solve?.namedStars ?? const []);
              final error = star.magnitudeError;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(name?.name ?? '图内亮点'),
                subtitle: Text(
                  '孔径通量 ${star.flux.toStringAsFixed(0)}'
                  '${error == null ? '' : ' · 星等误差 ±${error.toStringAsFixed(2)}'}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: Text(
                  zeroPoint != null && star.confidence >= 0.25
                      ? 'G ${(star.instrumentalMagnitude + zeroPoint).toStringAsFixed(2)}'
                      : 'Δm ${_relativeMagnitude(star, stars.first).toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 12),
                ),
              );
            }),
          const SizedBox(height: 6),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Gaia G 是近似标定，不含相机光谱响应、白平衡、饱和与后期处理'
                  '带来的系统误差，只适合与同一台设备的其他照片比较。',
                  style: TextStyle(color: Color(0xFF8192A8), fontSize: 11),
                ),
              ),
              _HelpButton(
                title: '测光误差',
                message:
                    '星等误差只算了光子噪声和天空背景估计的误差，不包含相机光谱响应、'
                    '白平衡、饱和、镜头暗角和图像处理造成的系统误差。结果仅供参考。',
              ),
            ],
          ),
        ],
      ),
    );
  }

  SkyObject? _nearestNamed(DetectedStar star, List<SkyObject> objects) {
    if (star.isElongated) return null;
    SkyObject? nearest;
    var distance = 10.0;
    for (final object in objects) {
      final current = math.sqrt(math.pow(star.x - object.x, 2) + math.pow(star.y - object.y, 2));
      if (current < distance) {
        distance = current;
        nearest = object;
      }
    }
    return nearest;
  }

  double _relativeMagnitude(DetectedStar star, DetectedStar brightest) =>
      star.instrumentalMagnitude - brightest.instrumentalMagnitude;

  Widget _solveCard(SolveResult? solve) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SectionTitle('天区识别', Icons.public_rounded),
                  _HelpButton(
                    title: '天区识别与隐私',
                    message:
                        '优先在手机本机解算，不上传任何图片。本机解算不出来时，'
                        '如果已在设置里授权，才会把分析预览图上传到 Astrometry.net。'
                        '不解算也能查看本机星点与画质分析。',
                  ),
                ],
              ),
              if (solve == null)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    '还没有解开这片天区。点上面的「一键解析」；'
                    '如果本机星点太少或视场太窄，需要在设置里填写 '
                    'Astrometry.net API Key 并授权上传，交给在线解算。',
                  ),
                )
              else ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    MetricChip(
                      '解算方式',
                      solve.source == SolveSource.local ? '本机离线' : 'Astrometry.net',
                    ),
                    if (solve.constellations.isNotEmpty)
                      MetricChip('星座', solve.constellations.first),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '中心 RA ${formatRa(solve.centerRa)}  ·  Dec ${solve.centerDec.toStringAsFixed(4)}°',
                ),
                const SizedBox(height: 6),
                Text(
                  '像素比例 ${solve.arcsecPerPixel.toStringAsFixed(2)}″/px'
                  '   ·   视场对角 ${solve.fieldOfViewDegrees.toStringAsFixed(2)}°',
                ),
                const SizedBox(height: 6),
                Text(
                  '匹配 ${solve.matchedCount == 0 ? solve.matchedStars.length : solve.matchedCount} 颗星'
                  '${solve.rotationDegrees == 0 ? '' : '   ·   画面旋转 ${solve.rotationDegrees.toStringAsFixed(1)}°'}',
                ),
              ],
            ],
          ),
        ),
      );

  Widget _warningCard(String message) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 18, color: Color(0xFFFFDE77)),
              const SizedBox(width: 10),
              Expanded(child: Text(message, style: const TextStyle(fontSize: 13))),
            ],
          ),
        ),
      );

  /// 观星记录：一张照片的「成交报告」。
  ///
  /// 用户拍完一张星空，最想知道的是「我拍到了什么、拍得怎么样、下次怎么
  /// 更好」。这三件事分别对应这里的一段话、一排数字、一份建议清单。下面
  /// 那些卡都是过程性的细节，只有这张是结论。
  Widget _observationCard(SkyAnalysis analysis, SolveResult? solve) {
    final record = buildObservationRecord(analysis, solve);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionTitle('观星记录', Icons.nights_stay_rounded),
                _HelpButton(
                  title: '观星记录怎么来的',
                  message:
                      '所有数字都是从这张照片本身量出来的——包括天空背景、点源大小和星等。'
                      '它们会随曝光、ISO、光圈和后期处理变化，换个晚上、换台机器就不一样，'
                      '适合和「你自己过去拍的」比，不适合和别人的照片比。',
                ),
              ],
            ),
            const SizedBox(height: 10),
            SelectableText(
              record.summary,
              style: const TextStyle(height: 1.5),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (record.constellation != null)
                  MetricChip('拍到', record.constellation!),
                MetricChip('画质', record.quality),
                MetricChip('天空背景', record.skyBrightness),
                MetricChip('点源 FWHM',
                    '${analysis.fwhm.toStringAsFixed(1)} px'),
                if (solve != null) ...[
                  MetricChip('星表匹配', '${record.matchedStars} 颗'),
                  MetricChip('视场对角', record.fieldOfView),
                  MetricChip('像素比例', record.scale),
                ],
              ],
            ),
            if (record.brightest != null) ...[
              const SizedBox(height: 10),
              Text('画面最亮：${record.brightest}',
                  style: const TextStyle(fontSize: 13)),
            ],
            const Divider(height: 26),
            const Text('拍摄建议', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final item in record.advice)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6, right: 8),
                      child: Icon(Icons.circle, size: 5, color: kMint),
                    ),
                    Expanded(
                      child: Text(item, style: const TextStyle(height: 1.45, fontSize: 13)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 视场内的恒星表：爱好者熟悉的「一张星表」的样子。
  ///
  /// 用 DataTable 而不是 ListTile：列表适合「挑一条点进去」，表格适合
  /// 「横着比较」。这里要做的事情是后者——哪颗最亮、哪颗离中心最近、
  /// 哪几颗是同一星座的，都需要一眼扫过整列。
  Widget _starTableCard(SkyAnalysis analysis, SolveResult solve) {
    final rows = buildStarTable(analysis, solve);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('视场内的恒星', Icons.table_chart_outlined),
            const SizedBox(height: 6),
            Text(
              solve.source == SolveSource.local
                  ? '名称来自 APP 内置的 Hipparcos 亮星目录，解算过程完全离线。'
                  : '星名来自在线星表（Gaia DR3 / SIMBAD）。',
              style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 18,
                horizontalMargin: 0,
                headingTextStyle: const TextStyle(
                  color: kMint,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                dataTextStyle: const TextStyle(fontSize: 12),
                columns: const [
                  DataColumn(label: Text('星名')),
                  DataColumn(label: Text('类型')),
                  DataColumn(label: Text('星等')),
                  DataColumn(label: Text('赤经')),
                  DataColumn(label: Text('赤纬')),
                  DataColumn(label: Text('图上置信度')),
                ],
                rows: [
                  for (final row in rows.take(20))
                    DataRow(
                      cells: [
                        DataCell(Text(row.name)),
                        DataCell(Text(row.category)),
                        DataCell(Text(row.magnitude)),
                        DataCell(Text(formatRa(row.ra))),
                        DataCell(Text(formatDec(row.dec))),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                row.confidence == null
                                    ? Icons.remove
                                    : row.confidence! >= 0.7
                                        ? Icons.check_circle_outline
                                        : Icons.help_outline,
                                size: 14,
                                color: row.confidence == null
                                    ? const Color(0xFF8192A8)
                                    : row.confidence! >= 0.7
                                        ? kMint
                                        : const Color(0xFFFFDE77),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                row.confidence == null
                                    ? '未检出'
                                    : '${row.confidenceLabel} '
                                        '${(row.confidence! * 100).toStringAsFixed(0)}%',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (rows.length > 20)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '共 ${rows.length} 颗，此处显示最亮的 20 颗。',
                  style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
                ),
              ),
            if (solve.catalogWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '名称目录暂不可用：${solve.catalogWarning}',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 星等分布图。
  Widget _magnitudeCard(SkyAnalysis analysis, SolveResult? solve) {
    final bins = magnitudeHistogram(analysis, solve);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionTitle('星等分布', Icons.bar_chart_rounded),
                _HelpButton(
                  title: '星等分布怎么看',
                  message:
                      '横轴是星等，往右越暗；纵轴是落在这个亮度区间的星数。'
                      '右边最后几根柱子就是你这次的探测极限——再暗一等的星就淹在背景噪声里了。'
                      '如果分布在最暗那端突然掉到零，说明是设备极限；'
                      '如果整条分布都在很亮的几档里堆着，多半是曝光不足或天空太亮。',
                ),
              ],
            ),
            const SizedBox(height: 12),
            MagnitudeHistogram(
              bins: bins,
              calibrated: solve?.magnitudeZeroPoint != null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _deepSkyCard(SolveResult solve) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('视场中的深空天体', Icons.scatter_plot),
              const SizedBox(height: 8),
              ...solve.deepSkyObjects.map(
                (object) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(object.name),
                  subtitle: Text(object.category),
                  trailing:
                      const Icon(Icons.auto_awesome, color: Color(0xFFFF7B8C)),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _agentCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('Agent 解读', Icons.chat_bubble_outline_rounded),
              const SizedBox(height: 10),
              TextField(
                controller: _questionController,
                decoration: const InputDecoration(
                  hintText: '例如：哪些测量结果可靠？',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: _explaining ? null : _explain,
                  child: Text(_explaining ? '正在生成解读…' : '基于测量结果生成解读'),
                ),
              ),
              if (_explanation != null) ...[
                const SizedBox(height: 12),
                SelectableText(_explanation!),
              ],
            ],
          ),
        ),
      );
}

class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '了解更多',
        visualDensity: VisualDensity.compact,
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        ),
        icon: const Icon(Icons.help_outline_rounded, size: 20),
      );
}

class SettingsForm extends StatefulWidget {
  const SettingsForm({
    super.key,
    required this.current,
    required this.astrometryKey,
    required this.allowUpload,
    required this.storage,
  });

  final ModelSettings current;
  final String astrometryKey;
  final bool allowUpload;
  final FlutterSecureStorage storage;

  @override
  State<SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<SettingsForm> {
  late final _baseUrl = TextEditingController(text: widget.current.baseUrl);
  late final _lightKey = TextEditingController(text: widget.current.lightKey);
  late final _lightModel = TextEditingController(text: widget.current.lightModel);
  late final _strongKey = TextEditingController(text: widget.current.strongKey);
  late final _strongModel = TextEditingController(text: widget.current.strongModel);
  late final _astrometryKey = TextEditingController(text: widget.astrometryKey);
  bool _obscureLight = true;
  bool _obscureStrong = true;
  bool _obscureAstrometry = true;
  late bool _allowUpload = widget.allowUpload;

  static const _apiTemplates = <_AgentApiTemplate>[
    _AgentApiTemplate(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      lightModel: 'deepseek-chat',
      strongModel: 'deepseek-reasoner',
    ),
    _AgentApiTemplate(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      lightModel: 'gpt-4.1-mini',
      strongModel: 'gpt-4.1',
    ),
    _AgentApiTemplate(
      name: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      lightModel: 'deepseek/deepseek-chat',
      strongModel: 'deepseek/deepseek-r1',
    ),
    _AgentApiTemplate(
      name: '硅基流动',
      baseUrl: 'https://api.siliconflow.cn/v1',
      lightModel: 'deepseek-ai/DeepSeek-V3',
      strongModel: 'deepseek-ai/DeepSeek-R1',
    ),
  ];

  void _applyTemplate(_AgentApiTemplate template) {
    setState(() {
      _baseUrl.text = template.baseUrl;
      _lightModel.text = template.lightModel;
      _strongModel.text = template.strongModel;
    });
  }

  Future<void> _save() async {
    final uri = Uri.tryParse(_baseUrl.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写有效的模型 Base URL。')),
      );
      return;
    }
    final values = {
      // 授权是个开关不是密钥，空值也照样写进去。
      'allowUpload': _allowUpload ? 'true' : 'false',
      'modelBaseUrl': _baseUrl.text.trim(),
      'lightKey': _lightKey.text.trim(),
      'lightModel': _lightModel.text.trim(),
      'strongKey': _strongKey.text.trim(),
      'strongModel': _strongModel.text.trim(),
      'astrometryKey': _astrometryKey.text.trim(),
    };
    try {
      for (final entry in values.entries) {
        if (entry.key == 'allowUpload') {
          await widget.storage.write(key: entry.key, value: entry.value);
        } else if (entry.value.isEmpty) {
          await widget.storage.delete(key: entry.key);
        } else {
          await widget.storage.write(key: entry.key, value: entry.value);
        }
      }
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('安全存储设置失败：$error')),
        );
      }
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  Widget _field(String label, TextEditingController controller,
      {bool secret = false, bool obscure = true, VoidCallback? toggle}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        obscureText: secret && obscure,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: secret
              ? IconButton(
                  onPressed: toggle,
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                )
              : null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final controller in [
      _baseUrl,
      _lightKey,
      _lightModel,
      _strongKey,
      _strongModel,
      _astrometryKey,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.viewInsetsOf(context).bottom + 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('本机 API 设置', Icons.lock_outline),
              const SizedBox(height: 14),
              const Text(
                '快速模板（仅填写接口地址和模型名，不含 API Key）',
                style: TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
              ),
              const Align(
                alignment: Alignment.centerRight,
                child: _HelpButton(
                  title: '模型 API 模板',
                  message:
                      '模板仅预填兼容接口的 Base URL 和模型名，不包含 API Key。'
                      '请在服务商处自行申请 Key，核对模型是否仍可用。'
                      '填写的密钥保存在本机安全存储，并发送至你配置的模型服务。',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final template in _apiTemplates)
                    ActionChip(
                      label: Text(template.name),
                      onPressed: () => _applyTemplate(template),
                    ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '模板值可编辑；请按服务商控制台确认当前可用的模型名称及兼容接口地址。'
                  '填入你自己的 Key 后保存即可启用 Agent。',
                  style: TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
                ),
              ),
              _field('模型 API Base URL', _baseUrl),
              _field('轻量模型名称', _lightModel),
              _field(
                '轻量模型 API Key',
                _lightKey,
                secret: true,
                obscure: _obscureLight,
                toggle: () => setState(() => _obscureLight = !_obscureLight),
              ),
              _field('强推理模型名称', _strongModel),
              _field(
                '强推理模型 API Key',
                _strongKey,
                secret: true,
                obscure: _obscureStrong,
                toggle: () => setState(() => _obscureStrong = !_obscureStrong),
              ),
              _field(
                'Astrometry.net API Key',
                _astrometryKey,
                secret: true,
                obscure: _obscureAstrometry,
                toggle: () => setState(() => _obscureAstrometry = !_obscureAstrometry),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _allowUpload,
                onChanged: (value) => setState(() => _allowUpload = value ?? false),
                title: const Text('允许在必要时把分析预览图上传至 Astrometry.net'),
                subtitle: const Text(
                  '默认关闭。手机本机解算失败、且这张图确实需要天区坐标时才会用到；'
                  '不上传就只用本机星表。',
                  style: TextStyle(fontSize: 12, color: Color(0xFFA6B5C8)),
                ),
              ),
              const Text(
                '密钥保存在本机安全存储。模型只接收测量摘要。',
                style: TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
              ),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('保存设置'))),
            ],
          ),
        ),
      );
}

class _AgentApiTemplate {
  const _AgentApiTemplate({
    required this.name,
    required this.baseUrl,
    required this.lightModel,
    required this.strongModel,
  });

  final String name;
  final String baseUrl;
  final String lightModel;
  final String strongModel;
}

bool _isRawName(String filename) => const {
      'dng',
      'cr2',
      'cr3',
      'nef',
      'arw',
      'raf',
      'orf',
      'rw2',
    }.contains(filename.toLowerCase().split('.').last);
