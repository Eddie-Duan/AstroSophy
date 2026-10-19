import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as imglib;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'strings.dart';
import 'agent_tools.dart';
import 'analysis.dart';
import 'astrometry.dart';
import 'crop.dart';
import 'deepsky_names.dart';
import 'demo.dart';
import 'exif.dart';
import 'export.dart';
import 'history.dart';
import 'history_screen.dart';
import 'jobs.dart';
import 'live_sky_screen.dart';
import 'markdown.dart';
import 'model.dart';
import 'models.dart';
import 'naming.dart';
import 'nox.dart';
import 'onboarding.dart';
import 'pipeline.dart';
import 'report.dart';
import 'smallbodies.dart';
import 'solver.dart';
import 'theme.dart';
import 'widgets.dart';

void main() => runApp(const AstroSophyApp());

/// 星点列表里的三组，顺序就是显示顺序。
const groupIds = <String>['named', 'unnamed', 'streaks'];

/// 一进结果页就既收起、又隐去圆圈的那两组。
///
/// 亮星是「我到底拍到了什么」的答案，一进结果页就该看见。另外两组动辄几十
/// 项，一上来全画上、全展开，真正重要的那几颗立刻淹在里面。想看也容易：各自
/// 的 + 就在组标题右边。
const secondaryTargetGroups = <String>{'unnamed', 'streaks'};

/// 一进结果页时哪几组收起。
///
/// 画面里有深空天体或系内天体时只展开这两组：那些才是按下快门的目标，而星点动辄
/// 几十项，全展开就把主角淹了。
///
/// 画面里**都没有**时反过来，展开亮星组：这时候列表里只剩星点，按上面
/// 那套全收起来，用户打开面板看到的是一片空白加三个折叠条，像是什么都没算
/// 出来。两种情况的默认值必须分开算，不能用一个常数。
Set<String> initialCollapsedGroups({
  required int deepSkyObjectCount,
  int movingBodyCount = 0,
}) =>
    deepSkyObjectCount == 0 && movingBodyCount == 0
        ? {...secondaryTargetGroups}
        : {'named', ...secondaryTargetGroups};

class AstroSophyApp extends StatelessWidget {
  const AstroSophyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 换语言要把整棵树重建一遍：文字是查表查出来的，表换了之后已经建好的 widget
    // 不会自己重算。挂在最外层，`ValueNotifier` 一变整屏就跟着换。
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: appLanguage,
      builder: (context, language, _) => MaterialApp(
        title: 'AstroSophy',
        debugShowCheckedModeBanner: false,
        // 让 Material 自带的文字（返回键 tooltip、弹窗遮罩的无障碍标签、日期
        // 控件之类）跟着走。
        //
        // 下面这几个 delegate 不是可选项：默认的 `DefaultMaterialLocalizations`
        // 只承认 en，而 `locale` 一设成 zh、`supportedLocales` 一列出 zh，框架
        // 就找不到任何支持 zh 的 delegate，`MaterialLocalizations` 于是**整个
        // 缺席**。凡是真正用到它的地方（AppBar 的返回键 tooltip、`showDialog`
        // 和 `showModalBottomSheet` 的遮罩标签）都会在构建时抛异常——表现是
        // 页面一进去就「坏了」、按钮点了没反应。界面文案本身走我们自己的
        // `strings_map.dart`，与这里无关；这里补的是框架那部分。
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          // Cupertino 那一份也要给：M3 里不少控件（下拉刷新、长按选择之类）
          // 会从这里取字，缺了它框架同样会认定「这个 locale 没有全部支持」。
          GlobalCupertinoLocalizations.delegate,
        ],
        locale: Locale(language.code),
        supportedLocales: [
          for (final item in AppLanguage.values) Locale(item.code),
        ],
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
      ),
    );
  }
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
  List<String> _agentActivity = const [];
  String? _error;
  List<String> _warnings = const [];
  /// 当前界面正看着的那次解析。null 表示这一屏没有在跑的解析。
  SkyJob? _job;

  /// 界面在不在跑的判断，统一从任务那边取——两处各自记一份迟早会对不上，
  /// 而对不上的表现是「按钮忽然点不动了」。
  bool get _running => _job?.running ?? false;

  /// 这次解析是「只报告月亮」——用户自己选的那条路。
  ///
  /// 只在**刚跑完的那一次**有意义，所以要设 [_isMoonReport] 之外另立一个：
  /// 「这张图是月亮」和「用户当时选了直接报告月亮」是两件事，而屏幕上那句话
  /// 得看是哪一种。
  bool _moonOnly = false;

  /// 这一屏报的是不是「一张月亮照，而且没解算天区」。
  ///
  /// 判据用的是**照片本身**（有月盘）＋ 没有解算结果，不是那个会话里的
  /// [_moonOnly]：从观星仓库里重新打开一条月面记录时，那个开关早就没了（或者
  /// 正好留着上一次运行的值），而「这张图是不是月亮」一直都在 `moonDisc` 里。
  ///
  /// 不这样的话，重新打开一条月面记录会走到下面那个 `solve == null` 的分支，
  /// 屏幕上写着「还没解开这片天区，点上面的『一键解析』」——用户刚看过一张
  /// 算得好好的月亮，却被告知什么都没识别出来。
  bool get _isMoonReport => _analysis?.moonDisc != null && _solve == null;

  /// 正在裁剪选中的那张图。
  bool _cropping = false;

  /// 裁剪框（归一化）。null 表示还没动过，等同于整幅。
  CropRect? _crop;
  bool _explaining = false;
  int _imageGeneration = 0;

  /// 是否允许把预览图上传到 Astrometry.net。默认不允许，且要用户在设置里
  /// 明确勾选过才为真——上传照片是不可逆的动作，不能靠一次性的弹窗确认。
  bool _uploadAllowed = false;

  /// astrometry.net 的 Key 配好了没有。
  ///
  /// 月亮那个岔路口要用它：说清「继续寻找」这一步到底会不会真的把照片传出去。
  /// 把「会上传」和「其实是白等」两种后果分开讲，用户才能真的选。
  bool _astrometryKeyPresent = false;

  /// 这次解析用哪种分析方式。默认「本机优先」，和旧版本行为一致。
  SkyAnalysisMode _analysisMode = SkyAnalysisMode.localFirst;

  /// 拍摄场景，用来收窄解算的视场范围。默认不限制。
  ShootingScene _shootingScene = ShootingScene.auto;

  /// 是否在解析结束后自动让 Agent 写一份解读。默认关闭。
  bool _generateAgentReport = false;

  /// 现在的设置能不能跑需要联网的分析方式。
  bool get _onlineReady => _uploadAllowed && _astrometryKeyPresent;

  PipelineProgress? _progress;

  /// 正等着用户拍板的那一次月面提问。
  ///
  /// 非 null 时解析**停在**这里等答案——这是整条链路上唯一一个必须人来定的
  /// 岔路口：往下走要么白等一趟在线解算，要么直接不做解算，两条路的结果对
  /// 用户不一样，替他选哪一条都是错的。
  _MoonQuestion? _moonQuestion;

  /// 历史记录仓库。第一次用到时才打开——不存不读的会话不必碰磁盘。
  HistoryStore? _history;
  bool _saving = false;

  /// 当前这张图在历史里对应的记录 id；没保存过就是 null。
  String? _savedId;

  /// 下方列表里当前选中的那一项（`numberedTargets` 的下标）。图上的高亮环
  /// 和列表的选中底色都跟着它走，两边同号才是同一颗星。
  int? _selectedTarget;
  String? _selectedDeepSkyName;

  /// 看图区显示的是处理图还是原图。默认原图——处理图是加工过的。
  bool _showProcessed = false;

  /// 是否在图上叠加星座连线。默认开——这是「我到底拍到了什么」最直观的
  /// 一层答案；但连线和用户关心的星点编号画在同一张图上，有时候需要关掉
  /// 让画面干净一点。
  bool _showConstellations = true;

  /// 这张照片的拍摄时刻。
  ///
  /// 选图时从 EXIF 读；读不到就是 null，界面上让用户自己填。行星、彗星、
  /// 小行星的位置随日期变，没有时间就没法判断画面上多出来的那个亮点是什么，
  /// 所以这条信息是「运动天体」那一节的前提，缺了只能不做判断。
  CaptureMoment? _moment;

  /// 上一次解算用掉的墙钟时间，和它完成的那一刻。
  ///
  /// 只用于结果页那张参数表；从观星记录里翻出来的条目没有这两个值，表里
  /// 就不显示这两行——不编一个数出来。
  Duration? _solveDuration;
  DateTime? _solvedAt;

  /// 喂给星历的那个瞬间（UTC）。
  ///
  /// 时区从 EXIF 里读到了就用读到的；没读到就按本机时区算——这是界面上
  /// 承诺过的那句话。这里取的偏移是**那个时刻**的本机偏移而不是此刻的偏移，
  /// 夏令时切换前后拍的照片因此不会差一小时。
  DateTime? _instantOf(CaptureMoment? moment) =>
      moment?.utcAt(moment.local.timeZoneOffset);

  /// 图上不画圆圈的分组。只是不画——测量、星表匹配和报告都不受它影响。
  final _hiddenGroups = <String>{...secondaryTargetGroups};

  /// 单独隐去、单独显示的那些编号。
  ///
  /// 分组给的是「一进来先看什么」的默认值，而用户真正经常要做的事是
  /// 「就这一颗挡着我看别的，把它收起来」。所以分组之外还得能一颗一颗来：
  /// [_hiddenTargets] 按下某个编号，[_restoredTargets] 把它从所属分组的
  /// 隐去里捞出来。两者都为空时，一颗星画不画完全由它所在的分组决定。
  ///
  /// 分组的 − / + 一按，这一组的逐项设定就作废：按钮的字面意思是「这一组
  /// 全部」，按下去之后组里每一项就该是同一个状态，再留着上一轮的个别设定
  /// 会和它打架。
  final _hiddenTargets = <int>{};
  final _restoredTargets = <int>{};

  /// 深空天体没有星点编号，显隐按目录名称单独管理。
  final _hiddenDeepSkyObjects = <String>{};

  /// 系内天体（行星、矮行星、小行星、彗星）同理：没有星点编号，按名字单独管理。
  ///
  /// 默认**空集**，也就是初始状态图上就画着标注——这一组每一项都是「这一刻
  /// 只有这一个位置」的结论，正是用户按下快门时想拍的东西，藏起来才是反常。
  final _hiddenMovingBodies = <String>{};

  /// 当前选中的系内天体名。
  String? _selectedMovingBodyName;

  /// 哪几组是收起的。**一进结果页的默认值由 [initialCollapsedGroups] 给**，
  /// 之后跟着用户点。
  final _collapsedGroups = <String>{...secondaryTargetGroups};

  /// 一进结果页时哪几组收起。判据见 [initialCollapsedGroups]。
  Set<String> _initialCollapsedGroups() => initialCollapsedGroups(
        deepSkyObjectCount: _sortedDeepSkyObjects(_solve).length,
        // 只数真的画在图上的：全是「没对上」的那些时不展开这一组，展开一个
        // 空组等于把亮星也一起收起来。
        movingBodyCount: _visibleMovingBodies(_solve).length,
      );

  /// 看图区的缩放/平移状态。
  final _viewer = TransformationController();

  /// 现在是不是放大过。只用来决定要不要显示「回到整幅」那个按钮——为一个
  /// 按钮的显隐重建整个结果页太贵，所以只在跨过 1 倍时 setState 一次。
  bool _isZoomed = false;

  /// 后台解算 isolate。第一次用到时才起，之后一直留着——索引建一次要一秒
  /// 上下，起一次就够。
  Future<SkyWorker>? _worker;

  /// 后台解析的总管。任务放在它这里，所以界面走了任务还在跑。
  late final JobCenter _jobCenter = JobCenter(
    runPipeline: (job, onProgress, onMoon) async {
      final worker = await _ensureWorker();
      final settings = await _readModelSettings();
      final key = (await _storage.read(key: 'astrometryKey') ?? '').trim();
      return SkyPipeline(
        worker: worker,
        astrometryKey: key,
        allowUpload: _uploadAllowed,
        modelSettings: settings,
        mode: job.mode,
        generateAgentReport: job.generateAgentReport,
        hint: job.scene.hint,
      ).run(
        job.bytes,
        question: job.question,
        moment: _instantOf(job.moment),
        onProgress: onProgress,
        onMoonDetected: onMoon,
      );
    },
    archive: _archiveJob,
  );

  @override
  void initState() {
    super.initState();
    _viewer.addListener(_onViewChanged);
    _jobCenter.addListener(_onJobsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _reloadSettings();
      await _showOnboarding(firstLaunch: true);
    });
  }

  @override
  void dispose() {
    _questionController.dispose();
    _viewer.removeListener(_onViewChanged);
    _viewer.dispose();
    _jobCenter.removeListener(_onJobsChanged);
    _jobCenter.dispose();
    _worker?.then((worker) => worker.dispose());
    super.dispose();
  }

  /// 后台跑完的那次解析自动存进观星记录。
  ///
  /// 名字和手动保存时用的是同一套规则，所以用户从首页横幅点进去，在记录里
  /// 看到的和当场保存时一模一样。
  Future<String?> _archiveJob(SkyJob job, PipelineOutcome outcome) async {
    final store = await _ensureHistory();
    final existing = await store.list();
    final name = uniqueObservationName(
      suggestedObservationName(
        analysis: outcome.analysis,
        solve: outcome.solve,
        moment: job.moment?.local,
        originalFilename: job.filename,
      ),
      existing.map((entry) => entry.name),
    );
    final saved = await store.save(
      name: name,
      analysis: outcome.analysis,
      solve: outcome.solve,
      explanation: outcome.explanation,
      capture: job.moment?.toMetadata(),
    );
    await _refreshHistorySnapshot();
    return saved.name;
  }

  void _onViewChanged() {
    final zoomed = _viewer.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isZoomed && mounted) setState(() => _isZoomed = zoomed);
  }

  /// 换图时把看图区和列表的临时状态清干净。
  ///
  /// 这些记的都是「这一张图上的」选择：缩放比例、哪几组圈画着、哪几颗单独
  /// 收起来了、哪几组折起来、选中了第几号。留到下一张图上，用户会以为程序
  /// 记住了他上回的动作。
  ///
  /// 调用点都在 `setState` 回调里，所以这里只管改值、不再自己 setState。
  void _resetPanelState() {
    // 先落 `_isZoomed` 再动控制器：控制器会通知 [_onViewChanged]，顺序反了
    // 就要多弹一次 setState。
    _isZoomed = false;
    _viewer.value = Matrix4.identity();
    _hiddenGroups
      ..clear()
      ..addAll(secondaryTargetGroups);
    _collapsedGroups
      ..clear()
      ..addAll(_initialCollapsedGroups());
    // 逐项设定记的是编号，而编号是「这张图上的第几号」。换一张图之后同一
    // 个编号指的是另一颗星，留着就会莫名其妙地少画几个圈。
    _hiddenTargets.clear();
    _restoredTargets.clear();
    _hiddenDeepSkyObjects.clear();
    _hiddenMovingBodies.clear();
    _selectedDeepSkyName = null;
    _selectedMovingBodyName = null;
  }

  /// 把设置里的开关读进内存。设置表单保存之后也要再读一次。
  Future<void> _reloadSettings() async {
    try {
      final upload = await _storage.read(key: 'allowUpload');
      final astrometry = await _storage.read(key: 'astrometryKey') ?? '';
      final language = await _storage.read(key: 'language');
      final mode = await _storage.read(key: 'analysisMode');
      final agentReport = await _storage.read(key: 'agentReport');
      final scene = await _storage.read(key: 'shootingScene');
      if (!mounted) return;
      // 语言那根线是全局的，赋值本身就够——`AstroSophyApp` 挂在它上面，一变
      // 整棵树就重建。没有存过就保持默认的中文。
      appLanguage.value = AppLanguage.fromCode(language);
      final ready = upload == 'true' && astrometry.trim().isNotEmpty;
      var selectedMode = SkyAnalysisMode.fromStorage(mode);
      // 不能联网时不要把用户卡在一个「选了云端、但跑不了」的状态里；退回
      // 本机优先，至少这张图还能算。
      if (selectedMode.requiresOnline && !ready) {
        selectedMode = SkyAnalysisMode.localFirst;
      }
      setState(() {
        _uploadAllowed = upload == 'true';
        _astrometryKeyPresent = astrometry.trim().isNotEmpty;
        _analysisMode = selectedMode;
        _generateAgentReport = agentReport == 'true';
        _shootingScene = ShootingScene.fromStorage(scene);
      });
    } on Exception catch (error) {
      _showError(t('无法读取设置：{0}', [error]));
    }
  }

  /// 换分析方式。写进设置，下次打开还按这个来。
  Future<void> _setAnalysisMode(SkyAnalysisMode mode) async {
    if (mode == _analysisMode) return;
    setState(() => _analysisMode = mode);
    try {
      await _storage.write(key: 'analysisMode', value: mode.storageKey);
    } on Exception catch (error) {
      _showError(t('无法保存设置：{0}', [error]));
    }
  }

  /// 「生成 Agent 分析报告」开关。默认关闭，只影响解析完成后的自动解读。
  Future<void> _setGenerateAgentReport(bool value) async {
    if (value == _generateAgentReport) return;
    setState(() => _generateAgentReport = value);
    try {
      await _storage.write(key: 'agentReport', value: value ? 'true' : 'false');
    } on Exception catch (error) {
      _showError(t('无法保存设置：{0}', [error]));
    }
  }

  /// 换拍摄场景。写进设置，下次打开还按这个来。
  Future<void> _setShootingScene(ShootingScene scene) async {
    if (scene == _shootingScene) return;
    setState(() => _shootingScene = scene);
    try {
      await _storage.write(key: 'shootingScene', value: scene.storageKey);
    } on Exception catch (error) {
      _showError(t('无法保存设置：{0}', [error]));
    }
  }

  /// 右上角那枚「翻译」图标：切界面语言。
  ///
  /// 换语言要写存储，所以留在这一层（引导页那一步写的是同一个 key）。语言本身
  /// 是全局的 `ValueNotifier`，赋值那一刻整棵树就重建，不必再 setState。
  Future<void> _pickLanguage() async {
    final picked = await showDialog<AppLanguage>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('界面语言')),
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final language in AppLanguage.values)
              ListTile(
                dense: true,
                // 用这门语言自己的写法称呼它：找「English」的人未必认得「英语」。
                title: Text(language.nativeName),
                trailing: language == appLanguage.value
                    ? const Icon(Icons.check_rounded, color: kMint, size: 20)
                    : null,
                onTap: () => Navigator.of(context).pop(language),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == appLanguage.value) return;
    appLanguage.value = picked;
    try {
      await _storage.write(key: 'language', value: picked.code);
    } on Exception catch (error) {
      _showError(t('无法保存设置：{0}', [error]));
    }
  }

  /// 认出月面之后问用户一句，返回回答。
  ///
  /// 界面不在场时（比如解析被放到后台、用户已经翻到别的地方去了）没有人能
  /// 回答，`_moonQuestion` 就一直挂着；这种情况下 [SkyPipeline] 按「只报告
  /// 月亮」处理——上传是这条路里唯一不可逆的动作，没人看着的时候不能替
  /// 用户做。
  Future<bool> _askAboutMoon(SkyAnalysis analysis) {
    final question = _MoonQuestion(analysis);
    if (mounted) setState(() => _moonQuestion = question);
    return question.completer.future;
  }

  void _answerMoon(bool searchMore) {
    final question = _moonQuestion;
    if (question == null) return;
    setState(() => _moonQuestion = null);
    if (!question.completer.isCompleted) {
      question.completer.complete(searchMore);
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
            onDone: (language) {
              if (navigator.canPop()) navigator.pop();
              unawaited(_finishOnboarding(language));
            },
          ),
        ),
      );
    } on Exception catch (error) {
      _showError(t('无法打开新手引导：{0}', [error]));
    }
  }

  /// 引导结束：存下选的语言、记下「看过了」，然后把右上角那几个图标的说明摆出来。
  ///
  /// 说明单独一步而不是塞进引导的某一页，是因为它要指着**真实界面**上的位置讲；
  /// 画在引导页的插画里，用户回到主页还是认不出哪个图标是哪个。
  Future<void> _finishOnboarding(AppLanguage language) async {
    appLanguage.value = language;
    try {
      await _storage.write(key: 'language', value: language.code);
    } on Exception {
      // 存不下最多是下次启动又回到默认语言，不值得为此打断用户。
    }
    await _markOnboarded();
    if (!mounted) return;
    await _showTopBarHint();
  }

  /// 右上角那几个图标分别是什么。首次看完引导后自动出现，之后可以从「使用引导」
  /// 里再看一遍。
  Future<void> _showTopBarHint() async {
    if (!mounted) return;
    final entries = <({IconData icon, String label, String detail, bool accent})>[
      (
        icon: noxIcon,
        label: t('{0} 助手', [noxName]),
        detail: t('问它这张照片拍到了什么，也能让它保存、改名、删除记录'),
        accent: true,
      ),
      (
        icon: Icons.help_outline_rounded,
        label: t('使用引导'),
        detail: t('重看引导，或者随时回到这里看这份说明'),
        accent: false,
      ),
      (
        icon: Icons.collections_bookmark_outlined,
        label: t('观星仓库'),
        detail: t('保存过的观测都在这里，可以重看、改名、删除'),
        accent: false,
      ),
      (
        icon: Icons.translate_rounded,
        label: t('界面语言'),
        detail: t('中文和英文随时切换，改完立刻生效'),
        accent: false,
      ),
      (
        icon: Icons.tune_rounded,
        label: t('API 设置'),
        detail: t('填模型 Key 才能用 AI 解读；Astrometry.net Key 用于窄视场在线解算'),
        accent: false,
      ),
    ];
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (context) => _TopBarHint(entries: entries),
    );
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
        // 一些相册提供方默认不给完整元数据，导致可读的拍摄时间被丢掉。
        requestFullMetadata: true,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      _setImage(bytes, file.name);
    } catch (error) {
      _showError(t('读取图片失败：{0}', [error]));
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
      if (bytes == null) throw StateError(t('没有读取到图片内容。'));
      if (!mounted) return;
      _setImage(bytes, file.name);
    } catch (error) {
      _showError(t('读取图片失败：{0}', [error]));
    }
  }

  /// 选中一张新图。三个入口（相册、相机、演示图）共用这一处清理逻辑：
  /// 换图就等于把上一张的解析结果全部作废，漏清一项就会出现「这张图的
  /// 坐标配着那张图的星点」这种最难查的错。
  void _setImage(Uint8List bytes, String name, {CaptureMoment? moment}) {
    // 换图之前，正在跑的那次解析要交代清楚。
    //
    // 不能直接把它扔掉：用户可能刚点了「一键解析」就去相册翻下一张，这时
    // 那一次的结果已经算出来一半了。让它按「保存并退出」的同一条路走下去
    // ——继续算，算完自动存进记录。
    final previous = _job;
    if (previous != null && previous.running) {
      if (_moonQuestion != null) _answerMoon(false);
      _jobCenter.detach(previous);
    }
    setState(() {
      _job = null;
      _imageGeneration++;
      _bytes = bytes;
      _filename = name;
      // 拍摄时刻和图片绑在一起：换图就必须重读，否则会出现「这张照片的
      // 时间配着那张照片的星点」，和坐标配错一样难查。历史记录里带回来的
      // 时间由调用方传进来——存的是预览图，重新读 EXIF 是读不到的。
      _moment = moment ?? readCaptureMoment(bytes);
      _solveDuration = null;
      _solvedAt = null;
      _analysis = null;
      _solve = null;
      _explanation = null;
      _agentActivity = const [];
      _error = null;
      _warnings = const [];
      _explaining = false;
      _savedId = null;
      // 编号只在同一张图里有意义，换图必须把选中项清掉，否则新图会在第 10
      // 号位置高亮一颗跟用户完全无关的星。
      _selectedTarget = null;
      _showProcessed = false;
      _showConstellations = true;
      // 换图就把裁剪状态清掉：裁剪框是按**上一张**的构图选的，留下来只会让
      // 新图莫名其妙地少一块。
      _cropping = false;
      _crop = null;
      _resetPanelState();
    });
  }
  Future<void> _pickDemoImage() async {
    // 这张列表必须能滚（见 [DemoPickerSheet]）：条目一多，固定高度的列就会
    // 超出底部卡片的高度，Flutter 在下面画一条黄黑斜纹的溢出条——那就是
    // 用户看到的「黑黄的条带报错」。
    //
    // 高度上限按屏幕给，仍然留出上方一段能看见背景，用户一眼就知道这是个
    // 可以下滑关掉的卡片。
    final choice = await showModalBottomSheet<DemoImage>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      builder: (context) => const DemoPickerSheet(),
    );
    if (choice == null) return;
    try {
      final bytes = await loadDemoImage(choice);
      if (!mounted) return;
      // 演示图里没有 EXIF（入库前裁掉了），时刻随条目一起给；没有就给 null，
      // `_setImage` 会照常去读文件，读不到就是「未读到」。
      _setImage(bytes, '${choice.title}.jpg', moment: choice.moment);
    } catch (error) {
      _showError(t('读取演示图片失败：{0}', [error]));
    }
  }

  /// 一键解析：本地分析 → 本机解算 →（失败且已授权）在线解算 → AI 解读。
  ///
  /// 这条链路是「一键」的：用户只需要点一次。跑哪几步由已配置的 API 决定，
  /// 没配的部分自动跳过，不需要用户先想清楚自己配了什么。
  ///
  /// 真正跑的是 [JobCenter] 里的一次任务，而不是这个方法自己的局部变量。
  /// 页面只是**看着**那个任务——用户随时可以点「保存并退出」走人，任务照跑，
  /// 跑完自动存进观星记录。
  Future<void> _run() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final job = _jobCenter.start(
      bytes: bytes,
      filename: _filename ?? t('未命名'),
      moment: _moment,
      question: _questionController.text,
      mode: _analysisMode,
      generateAgentReport: _generateAgentReport,
      scene: _shootingScene,
    );
    setState(() {
      _error = null;
      _warnings = const [];
      _solve = null;
      _solveDuration = null;
      _solvedAt = null;
      _explanation = null;
      _moonOnly = false;
      // 重新解析出来的是新的一份结果，和之前存过的那条记录不再是一回事，
      // 要能再存一次。
      _savedId = null;
      _selectedTarget = null;
    });
    _attachJob(job);
  }

  /// 界面看着某个任务。图上、进度条、结果全都跟着它走。
  void _attachJob(SkyJob job) {
    _jobCenter.attach(job, _askAboutMoon);
    setState(() {
      _job = job;
      _bytes = job.bytes;
      _filename = job.filename;
      _moment = job.moment;
      _progress = job.progress;
      if (job.outcome != null) _applyOutcome(job.outcome!);
      if (job.error != null) _error = job.error;
    });
  }

  void _applyOutcome(PipelineOutcome outcome) {
    // 换了一份新的测量结果，面板上「哪几组展开着」的默认值可能就变了——
    // 有没有深空天体决定了一进结果页该展开哪一组，见 [_initialCollapsedGroups]。
    // 认身份而不是认内容：进度回调里每次都会走到这里，按内容比就变成每来
    // 一次进度就把用户的展开/收起抹掉一遍。
    final isNewAnalysis = !identical(_analysis, outcome.analysis);
    _analysis = outcome.analysis;
    _solve = outcome.solve;
    if (isNewAnalysis && outcome.solve != null) {
      _solveDuration = outcome.solveDuration;
      _solvedAt = DateTime.now();
    }
    _explanation = outcome.explanation;
    _warnings = outcome.warnings;
    _moonOnly = outcome.moonOnly;
    if (isNewAnalysis) _resetPanelState();
  }

  /// 任务那边有动静了。
  ///
  /// 只处理自己看着的那一个：别的任务（用户已经离开的那些）的进度和结果和
  /// 这一屏没有关系。
  void _onJobsChanged() {
    final job = _job;
    if (job == null || !mounted) return;
    setState(() {
      _progress = job.progress;
      if (job.outcome != null) _applyOutcome(job.outcome!);
      if (job.error != null) _error = job.error;
    });
  }

  /// 「保存并退出」：解析交给后台，这一屏松开手。
  ///
  /// 名字里的「并退出」是字面意思：点完就该回到刚打开 APP 的样子，而不是
  /// 留在工作台上再让用户去点一次「退出」。所以这里和 [_exit] 走同一段
  /// 清场逻辑，唯一的差别是正在跑的那次解析**不掐掉**——它已经答应过用户
  /// 「算完自动存进观星记录」，回到首页会有一条横幅盯着它。
  ///
  /// 这是这个页面唯一一个「还能反悔」的动作——用户走开以后随时可以从首页那
  /// 条横幅回到这次解析，只要它还在跑。
  void _detachJob() {
    final job = _job;
    if (job == null) return;
    if (_moonQuestion != null) _answerMoon(false);
    _jobCenter.detach(job);
    _clearWorkspace();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t('后台运行，自动存进仓库。')),
      ),
    );
  }

  /// 本机记录的一份快照，给 Nox 的上下文用。

  /// 只重跑解读。坐标、测光都是现成的，没必要为了换一句问法重算一遍。
  Future<void> _explain() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final imageGeneration = _imageGeneration;
    final settings = await _readModelSettings();
    if (!mounted || imageGeneration != _imageGeneration) return;
    if (!settings.hasAnyModel) {
      _showError(t('请先在设置中配置至少一个兼容 OpenAI 接口的模型 API Key。'));
      return;
    }
    setState(() {
      _explaining = true;
      _error = null;
      _agentActivity = [];
    });
    try {
      final report = buildAgentReport(analysis, _solve);
      final text = await ModelService.chatWithTools(
        baseUrl: settings.baseUrl,
        lightKey: settings.lightKey,
        lightModel: settings.lightModel,
        strongKey: settings.strongKey,
        strongModel: settings.strongModel,
        report: report,
        question: _questionController.text,
        executeTool: AgentTools(
          report: report,
          loadHistory: () async => (await _ensureHistory()).list(),
          loadSmallBodies: _ensureSmallBodies,
          handleAction: (name, arguments) =>
              _executeAgentAction(name, arguments, analysis, report),
        ).execute,
        onToolCall: (name) {
          if (!mounted || imageGeneration != _imageGeneration) return;
          setState(() => _agentActivity = [
                ..._agentActivity,
                switch (name) {
                  'get_current_report' => t('读取当前分析报告'),
                  'find_catalog_object' => t('查询当前视场天体'),
                  'find_small_body' => t('查询太阳系小天体位置'),
                  'list_observations' => t('读取本机观测摘要'),
                  'save_current_observation' => t('请求保存观测'),
                  'rename_observation' => t('请求重命名观测'),
                  'delete_observation' => t('请求删除观测'),
                  'request_online_solve' => t('请求在线解算'),
                  'propose_non_sky_regions' => t('请求视觉遮罩建议'),
                  _ => t('调用工具：{0}', [name]),
                },
              ]);
        },
      );
      if (mounted && imageGeneration == _imageGeneration) {
        setState(() => _explanation = text);
      }
    } catch (error) {
      if (mounted && imageGeneration == _imageGeneration) {
        _showError(t('模型解读失败：{0}', [error]));
      }
    } finally {
      if (mounted && imageGeneration == _imageGeneration) {
        setState(() => _explaining = false);
      }
    }
  }

  /// 记录类操作：改名、删除。
  ///
  /// 和「当前照片」无关，所以单独拎出来：用户常常是在还没选图的时候想起来
  /// 「上个月那张改个名字」，而这件事本来就不需要照片。
  Future<Object?> _handleArchiveAction(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final id = arguments['observation_id'];
    if (id is! String || !_isSafeObservationId(id)) {
      throw FormatException(t('记录编号无效。'));
    }
    final history = await _ensureHistory();
    final entries = await history.list();
    final entry = entries.where((item) => item.id == id).firstOrNull;
    if (entry == null) throw StateError(t('找不到指定的本机观测记录。'));

    if (name == 'rename_observation') {
      final rawName = arguments['new_name'];
      if (rawName is! String ||
          rawName.trim().isEmpty ||
          rawName.length > 100) {
        throw FormatException(t('新名称不能为空且不能超过 100 个字符。'));
      }
      if (!await _confirmAgentAction(
        t('重命名观测记录'),
        t('将把“{0}”改名为“{1}”。', [entry.name, rawName.trim()]),
      )) {
        return {'renamed': false, 'cancelled': true};
      }
      final renamed = await history.rename(entry, rawName.trim());
      await _refreshHistorySnapshot();
      return {'renamed': true, 'id': renamed.id, 'name': renamed.name};
    }

    if (!await _confirmAgentAction(
      t('删除观测记录'),
      t('将永久删除“{0}”的测量结果和本机预览图，无法恢复；相册里的原图不受影响。', [entry.name]),
    )) {
      return {'deleted': false, 'cancelled': true};
    }
    await history.delete(entry);
    if (mounted && _savedId == entry.id) setState(() => _savedId = null);
    await _refreshHistorySnapshot();
    return {'deleted': true, 'id': entry.id, 'name': entry.name};
  }

  /// 本机记录的一份快照，给 Nox 的上下文用。
  ///
  /// 那份上下文是**同步**取出去的（`NoxBackend.context` 是个普通函数），因为
  /// 它每次发问都要现取，而发问本身已经是异步的了——再为它铺一层异步，只会
  /// 把「记录读不到」变成一条新的失败路径。所以留着最近的一份快照，在打开
  /// Nox、保存、改名、删除之后刷新。
  List<SavedAnalysis> _historySnapshot = const [];

  Future<void> _refreshHistorySnapshot() async {
    try {
      final store = await _ensureHistory();
      final entries = await store.list();
      if (mounted) setState(() => _historySnapshot = entries);
    } catch (_) {
      // 读不到就沿用上一份：Nox 少知道几条记录，总好过整页打不开。
    }
  }

  Future<Object?> _executeAgentAction(
    String name,
    Map<String, Object?> arguments,
    SkyAnalysis? analysis,
    Map<String, Object?> report,
  ) async {
    // 换页面不需要照片，所以在最前面处理。
    if (name == 'open_screen') {
      final screen = arguments['screen'];
      if (screen == 'history') {
        // 先返回结果再换页面：导航会把这一轮的回复冲掉，用户看到的就成了
        // 「什么都没说就跳走了」。
        unawaited(Future<void>.delayed(Duration.zero, _openHistory));
        return {'opened': 'history'};
      }
      if (screen == 'settings') {
        unawaited(Future<void>.delayed(Duration.zero, _settings));
        return {'opened': 'settings'};
      }
      throw FormatException(t('可打开的页面只有 history 和 settings。'));
    }

    // 记录类的操作不需要当前照片——Nox 常常是在「还没选图」的时候被问起
    // 上一个月的记录的。所以这两件事往前挪，不再挂在照片上。
    if (name == 'rename_observation' || name == 'delete_observation') {
      return _handleArchiveAction(name, arguments);
    }

    if (analysis == null) {
      throw StateError(t('这个操作需要有正在看的照片，请先选一张图并解析。'));
    }
    if (!identical(_analysis, analysis)) {
      throw StateError(t('当前照片已更换，请针对新照片重新发送请求。'));
    }
    switch (name) {
      case 'save_current_observation':
        final rawName = arguments['name'];
        if (rawName is! String || rawName.trim().isEmpty || rawName.length > 100) {
          throw FormatException(t('观测名称不能为空且不能超过 100 个字符。'));
        }
        if (_savedId != null) {
          return {'saved': true, 'already_saved': true, 'id': _savedId};
        }
        if (!await _confirmAgentAction(
          t('保存观测记录'),
          t('将把当前测量结果和两张预览图保存到本机观测记录，名称为“{0}”。', [rawName.trim()]),
        )) {
          return {'saved': false, 'cancelled': true};
        }
        _ensureCurrentAnalysis(analysis);
        final history = await _ensureHistory();
        final saved = await history.save(
          name: rawName.trim(),
          analysis: analysis,
          solve: _solve?.withoutRejected(analysis.stars),
          explanation: _explanation,
          capture: _moment?.toMetadata(),
        );
        if (mounted && identical(_analysis, analysis)) {
          setState(() => _savedId = saved.id);
        }
        return {'saved': true, 'id': saved.id, 'name': saved.name};

      case 'rename_observation':
      case 'delete_observation':
        // 已经在 [_handleArchiveAction] 里处理过了，走不到这里。
        throw StateError(t('内部错误：记录操作没有提前分流。'));

      case 'request_online_solve':
        if (_solve != null) {
          return {'solved': true, 'message': t('当前照片已经有天区解算结果。')};
        }
        final key = (await _storage.read(key: 'astrometryKey') ?? '').trim();
        if (key.isEmpty) {
          throw StateError(t('请先在本机 API 设置中填写 Astrometry.net Key。'));
        }
        if (!await _confirmAgentAction(
          t('在线解算天区'),
          t('将把当前照片的分析预览图上传到 Astrometry.net。第三方服务可能留存数据。'),
        )) {
          return {'solved': false, 'cancelled': true};
        }
        _ensureCurrentAnalysis(analysis);
        var solve = await AstrometryService.solve(
          analysis: analysis,
          apiKey: key,
        );
        solve = await (await _ensureWorker()).decorate(solve);
        _ensureCurrentAnalysis(analysis);
        if (mounted) setState(() => _solve = solve);
        report.addAll(buildAgentReport(analysis, solve));
        return buildAgentReport(analysis, solve);

      case 'propose_non_sky_regions':
        final settings = await _readModelSettings();
        if (!settings.hasAnyModel) {
          throw StateError(t('请先在本机 API 设置中填写视觉模型 API Key。'));
        }
        if (!await _confirmAgentAction(
          t('向视觉模型发送照片'),
          t('将把当前照片预览发送到你设置的模型服务：{0}。服务商会收到图像；模型只返回疑似文字/水印区域，不会修改原图。', [settings.baseUrl]),
        )) {
          return {'inspected': false, 'cancelled': true};
        }
        _ensureCurrentAnalysis(analysis);
        final regions = await ModelService.proposeNonSkyRegions(
          baseUrl: settings.baseUrl,
          apiKey: settings.lightKey.isNotEmpty
              ? settings.lightKey
              : settings.strongKey,
          // 用同一个模型做视觉识别，不再单配一个「视觉模型名称」。多一个
          // 输入框的代价是用户要再决定一次「该填哪个」，而这一步的用法本来
          // 就是偶尔一次、还要先确认——把两个模型的名称并排列出来，只会让
          // 人卡在这里去查服务商的模型清单。
          model: settings.lightKey.isNotEmpty
              ? settings.lightModel
              : settings.strongModel,
          imageBase64: base64Encode(analysis.preview),
          imageWidth: analysis.width,
          imageHeight: analysis.height,
        );
        _ensureCurrentAnalysis(analysis);
        if (regions.isEmpty) {
          return {
            'inspected': true,
            'regions': 0,
            'message': t('视觉模型未发现可明确识别的水印或文字覆盖区域。'),
          };
        }
        final boxes = regions
            .map(
              (region) =>
                  '(${(region['x']! * 100).round()}%, ${(region['y']! * 100).round()}%)'
                  ' ${((region['width']! * 100).round())}%×'
                  '${((region['height']! * 100).round())}%',
            )
            .join(t('、'));
        if (!await _confirmMaskApplication(
          analysis,
          regions,
          boxes,
        )) {
          return {'inspected': true, 'applied': false, 'cancelled': true};
        }
        _ensureCurrentAnalysis(analysis);
        final exclusions = regions
            .map(
              (region) => ImageExclusion(
                x: region['x']!,
                y: region['y']!,
                width: region['width']!,
                height: region['height']!,
              ),
            )
            .toList(growable: false);
        final worker = await _ensureWorker();
        final adjustedAnalysis = await worker.analyze(
          analysis.preview,
          exclusions: exclusions,
        );
        final (adjustedSolve, _) = await worker.solveLocal(adjustedAnalysis);
        _ensureCurrentAnalysis(analysis);
        if (mounted) {
          setState(() {
            _analysis = adjustedAnalysis;
            _solve = adjustedSolve;
            _explanation = null;
            _savedId = null;
            _resetPanelState();
          });
        }
        final adjustedReport = buildAgentReport(adjustedAnalysis, adjustedSolve);
        report
          ..clear()
          ..addAll(adjustedReport);
        return {
          'inspected': true,
          'applied': true,
          'regions': regions.length,
          'analysis': adjustedReport,
        };

      default:
        throw ArgumentError.value(name, 'name', t('未知的 Agent 操作'));
    }
  }

  Future<bool> _confirmAgentAction(String title, String message) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t('确认执行')),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _ensureCurrentAnalysis(SkyAnalysis analysis) {
    if (!mounted || !identical(_analysis, analysis)) {
      throw StateError(t('当前照片已更换，请针对新照片重新发送请求。'));
    }
  }

  Future<bool> _confirmMaskApplication(
    SkyAnalysis analysis,
    List<Map<String, double>> regions,
    String labels,
  ) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t('应用视觉遮罩建议')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('红框是模型建议排除的区域：{0}。确认后会重新运行本机分析与解算；原始照片不变。', [labels]),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 320,
                  height: 220,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(analysis.preview, fit: BoxFit.contain),
                      CustomPaint(
                        painter: _MaskPreviewPainter(
                          imageWidth: analysis.width,
                          imageHeight: analysis.height,
                          regions: regions,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t('不应用')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t('应用并重新分析')),
              ),
            ],
          ),
        ) ??
        false;
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
        language: appLanguage.value,
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
      final question = _moonQuestion;
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
                    style: TextStyle(
                      color: progress.moonOnly
                          ? const Color(0xFFE8EEF5)
                          : progress.solvedLocally
                              ? const Color(0xFFFF6B6B)
                              : progress.online
                                  ? const Color(0xFFFFDE77)
                                  : progress.deep
                                      ? const Color(0xFF4C8DFF)
                                      : kMint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SkyProgressBar(
                value: progress.fraction,
                online: progress.online,
                moon: progress.moon,
                moonOnly: progress.moonOnly,
                solvedLocally: progress.solvedLocally,
                deep: progress.deep,
              ),
              if (progress.moonOnly) ...[
                const SizedBox(height: 8),
                Text(
                  t('这次只报月亮，没有解算天区'),
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFFC8D4E4)),
                ),
              ],
              if (progress.solvedLocally) ...[
                const SizedBox(height: 8),
                Text(
                  t('天区已在手机上算出来'),
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFFFF9A9A)),
                ),
              ],
              // 停在这里等用户拍板。
              //
              // 位置就在这次解析的状态下面，而不是弹一个盖住整屏的对话框：
              // 这是个「这次还要不要往下跑」的决定，跟进度条是同一件事的两半，
              // 摆在一起才对得上。而且不挡页面——用户完全可以把它晾着，
              // 先去相册里挑下一张图。
              if (question != null) ...[
                const SizedBox(height: 14),
                _moonQuestionCard(question.analysis),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _detachJob,
                      icon: const Icon(Icons.move_to_inbox_outlined, size: 17),
                      label: Text(t('保存并退出')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final hasResult = _analysis != null;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: hasResult
              ? OutlinedButton.icon(
                  onPressed: _run,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: Text(
                    t('重新解析'),
                    style: const TextStyle(fontSize: 13.5),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                )
              : FilledButton.icon(
                  onPressed: _run,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(t('一键解析')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        _actionRow(analysis: _analysis),
      ],
    );
  }

  /// 认出月面之后的那个岔路口。
  ///
  /// 两句话各自说清后果，因为这正是用户要权衡的东西：往下跑要找别的天体，
  /// 而这张图上月亮亮得离谱、星空那套判据对它没有意义，本机解算基本不会
  /// 成功，多半会把照片送去在线解算——那是一次上传，排队几分钟，而且几乎
  /// 注定失败。不知道这一点的用户会以为「继续」是免费的。
  Widget _moonQuestionCard(SkyAnalysis analysis) {
    final disc = analysis.moonDisc!;
    final uploads = _uploadAllowed && _astrometryKeyPresent;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFDE77).withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFDE77).withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.nightlight_round, size: 18, color: Color(0xFFFFDE77)),
              const SizedBox(width: 8),
              Text(t('这是一个月亮'),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            t('月盘占画面 {0}%，亮面 {1}%。', [(disc.discAreaFraction * 100).toStringAsFixed(2), (disc.illuminatedFraction * 100).toStringAsFixed(1)]),
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: _HelpButton(
              title: t('「继续寻找」会发生什么'),
              message: uploads
                  ? t('会去做星点解算。月亮上没有任何恒星尺度的点源，本机多半解不出来，那时会把预览图上传到 Astrometry.net 排队。')
                  : t('会去做星点解算。月亮上没有任何恒星尺度的点源，本机多半解不出来；没开在线解算的话，这一趟就是白等。'),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _answerMoon(false),
                  child: Text(t('直接报告月亮')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _answerMoon(true),
                  child: Text(t('继续寻找其他天体')),
                ),
              ),
            ],
          ),
        ],
      ),
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
                    ? t('正在保存…')
                    : _savedId == null
                        ? t('保存')
                        : t('已保存'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _running ? null : _exit,
              icon: const Icon(Icons.close_fullscreen_rounded),
              label: Text(t('退出')),
            ),
          ),
        ],
      );

  Future<HistoryStore> _ensureHistory() async =>
      _history ??= await HistoryStore.open();

  /// 内置的太阳系小天体目录，读了就留着。
  ///
  /// 只有 Nox 的 `find_small_body` 用得到它，所以不在启动时读。192 KB 的资源
  /// 解析一次之后一直留着——它是一份静态表，整个进程生命周期内都不会变。
  SmallBodyCatalog? _smallBodyCatalog;

  Future<SmallBodyCatalog> _ensureSmallBodies() async =>
      _smallBodyCatalog ??= await SmallBodyCatalog.load(rootBundle);

  /// 保存当前这一次的解析结果。
  Future<void> _save() async {
    final analysis = _analysis;
    if (analysis == null || _saving) return;
    setState(() => _saving = true);
    try {
      final store = await _ensureHistory();
      // 名字按「拍到了什么 ＋ 哪天拍的」在本机拼出来，重名再加序号。
      //
      // 不去问模型：这里没有任何要「判断」的东西——月亮、行星、主体天体都是
      // 已经算出来的结论，日期是照片自带的。让模型来做这件事，只是把一次确定
      // 的映射换成一次会编的取样，还要联网、要等、要花钱。
      final existing = await store.list();
      final suggested = uniqueObservationName(
        suggestedObservationName(
          analysis: analysis,
          solve: _solve,
          moment: _moment?.local,
          originalFilename: _filename,
        ),
        existing.map((entry) => entry.name),
      );
      final saved = await store.save(
        name: suggested,
        analysis: analysis,
        // 存的是剔除后的解算结果，和屏幕上看到的一致。剔除项本身跟着
        // `analysis.stars` 的 `isRejected` 一起存，重开还能改回来。
        solve: _solve?.withoutRejected(analysis.stars),
        explanation: _explanation,
        capture: _moment?.toMetadata(),
      );
      _savedId = saved.id;
      await _refreshHistorySnapshot();
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('已存为「{0}」', [saved.name]))),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showError(t('保存失败：{0}', [error]));
    }
  }

  /// 「后台还在解析」那条横幅。没有就不显示。
  ///
  /// 它必须存在：用户点了「保存并退出」之后，屏幕上关于这次解析就什么都不剩
  /// 了——不给他一个回来的地方，那个按钮就等于「放弃」。横幅上带着进度和
  /// 名字，点一下就能回到那次解析。
  Widget? _runningJobsNotice() {
    if (_job != null) return null;
    final running = _jobCenter.runningJobs;
    if (running.isEmpty) return null;
    return Card(
      child: Column(
        children: [
          for (final job in running)
            ListTile(
              leading: const Icon(Icons.autorenew_rounded, color: kMint),
              title: Text(
                job.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SkyProgressBar(
                  value: job.fraction,
                  height: 6,
                  online: job.progress?.online ?? false,
                  moon: job.progress?.moon ?? false,
                  moonOnly: job.progress?.moonOnly ?? false,
                  solvedLocally: job.progress?.solvedLocally ?? false,
                ),
              ),
              trailing: Text('${(job.fraction * 100).round()}%'),
              onTap: () => _attachJob(job),
            ),
        ],
      ),
    );
  }

  /// 退出：把当前这张图和它的解析结果清掉，回到刚打开 APP 的样子。
  ///
  /// 已经保存过的记录不受影响——「退出」清的是工作台，不是档案柜。
  void _exit() {
    // 正在跑的解析照旧放着不管：它已经答应过用户「会存进记录」，从这里把
    // 它掐掉等于毁约。
    final previous = _job;
    if (previous != null && previous.running) {
      if (_moonQuestion != null) _answerMoon(false);
      _jobCenter.detach(previous);
    }
    _clearWorkspace();
  }

  /// 把工作台清回「刚打开 APP 的样子」。
  ///
  /// 「退出」和「保存并退出」共用这一段：两者之间唯一的差别是正在跑的那次
  /// 解析留不留着，清场本身必须一模一样。各写一份的话，早晚有一边漏掉一个
  /// 字段，出来的就是「这张图的坐标配着那张图的星点」那种最难查的错。
  void _clearWorkspace() {
    setState(() {
      _job = null;
      _bytes = null;
      _filename = null;
      _moment = null;
      _solveDuration = null;
      _solvedAt = null;
      _analysis = null;
      _solve = null;
      _explanation = null;
      _error = null;
      _warnings = const [];
      _progress = null;
      _moonQuestion = null;
      _savedId = null;
      _selectedTarget = null;
      _showProcessed = false;
      _showConstellations = true;
      _resetPanelState();
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
        // 预览图是重新编码过的，里面没有 EXIF；拍摄时间跟着记录一起存了。
        _moment = captureMomentFromMetadata(entry.capture);
        _solveDuration = null;
        _solvedAt = null;
        _analysis = analysis;
        _solve = entry.solve;
        _explanation = entry.explanation;
        _error = null;
        _warnings = const [];
        _progress = null;
        _savedId = entry.id;
        // 从仓库里翻出来的记录不属于「刚跑完的那一次」，清掉这个开关，
        // 月面那句提示就会用「这是月面链路」那一种说法。判据见 [_isMoonReport]。
        _moonOnly = false;
        _selectedTarget = null;
        _showProcessed = false;
        _showConstellations = true;
        _resetPanelState();
      });
    } catch (error) {
      _showError(t('打开历史记录失败：{0}', [error]));
    }
  }

  /// 打开实时星图。
  ///
  /// 它和「选图解析」是两条独立的入口：实时模式不读相册、不保存照片，也不
  /// 上传任何东西；相机只是取景器，星表和解算都在本机。
  Future<void> _openLiveSky() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const LiveSkyScreen()),
    );
  }

  /// 打开 Nox。
  ///
  /// Nox 和结果页那张「Agent 解读」卡不是一回事，两者都要留着：那张卡问的是
  /// 「这一张照片」，问题和解说贴着照片、跟着照片存进记录；Nox 问的是「这个
  /// 应用」，可以没有当前照片——用户刚打开 APP 想问「我上次拍的那张在哪」
  /// 完全说得通，而这时那张卡根本不存在。
  Future<void> _openNox() async {
    final analysis = _analysis;
    final solve = _solve?.withoutRejected(analysis?.stars ?? const []);
    // 先刷一遍记录快照，否则 Nox 第一次被问「我有几条记录」时会说「没有」。
    await _refreshHistorySnapshot();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => NoxScreen(
          onOpenSettings: () {
            Navigator.of(context).pop();
            _settings();
          },
          backend: NoxBackend(
            loadSettings: _readModelSettings,
            context: () => _noxContext(analysis, solve),
            executeTool: (name, arguments) => AgentTools(
              report: analysis == null
                  ? const {}
                  : buildAgentReport(analysis, solve),
              loadHistory: () async => (await _ensureHistory()).list(),
              loadSmallBodies: _ensureSmallBodies,
              handleAction: (action, args) => _executeAgentAction(
                action,
                args,
                analysis,
                analysis == null
                    ? const {}
                    : buildAgentReport(analysis, solve),
              ),
            ).execute(name, arguments),
          ),
        ),
      ),
    );
  }

  /// 交给 Nox 的上下文。
  ///
  /// 三块：这个应用会什么（进系统提示，见 `noxAppBrief`）、本机存了哪些观测、
  /// 以及当前这张照片算出了什么。历史只放最近若干条的摘要——Nox 需要的是
  /// 「有几条、最近几条是什么」，不是把整个档案柜塞进一次请求里。
  Map<String, Object?> _noxContext(SkyAnalysis? analysis, SolveResult? solve) {
    final entries = _historySnapshot;
    return {
      'app': 'AstroSophy',
      'current_image': analysis == null
          ? null
          : {
              ...buildAgentReport(
                analysis,
                solve,
                moon: moonFactsOf(analysis, _instantOf(_moment)),
              ),
              'filename': _filename,
            },
      'archive': {
        'count': entries.length,
        'recent': [
          for (final entry in entries.take(8))
            {
              'id': entry.id,
              'name': entry.name,
              'saved_at': entry.savedAt.toIso8601String(),
              'constellation': entry.constellation,
              'solved': entry.solve != null,
            },
        ],
      },
      if (analysis == null)
        'note': t('当前没有正在看的照片。用户问「这张」的时候要问清是哪一张，不要去猜当前图片的分析结果。'),
    };
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  /// 右上角那排图标里的一枚。
  ///
  /// 不用裸 `IconButton`：默认尺寸是 48×48，一排四个加上最右边那颗 API 胶囊，
  /// 在 320dp 宽的屏上会把最右边两个（语言、API）挤出屏幕——实测溢出 60px，
  /// 表现是「这两个按钮点不进去」。这里收到 40×44（Material 允许的最小触摸
  /// 目标），一排才放得下。
  Widget _topBarAction({
    required VoidCallback onPressed,
    required String tooltip,
    required IconData icon,
    Widget? iconOverride,
    Color? color,
  }) =>
      IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        iconSize: 22,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
        icon: iconOverride ?? Icon(icon, color: color),
      );

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    // 用户剔除掉的亮点不进报告：星表、测光、摘要和交给模型的读法都以过滤后
    // 的这一份为准。图上仍然画着它们（划掉），所以剔除随时可以反悔。
    final solve = _solve?.withoutRejected(analysis?.stars ?? const []);
    return Scaffold(
      appBar: AppBar(
        actions: [
          _topBarAction(
            onPressed: _openNox,
            tooltip: t('{0} 助手', [noxName]),
            // 只有它是主色：另外几个是「去某个地方」的入口，而这一个是
            // 「叫个人过来」。颜色是同一条信息，不必再用文字说一遍。
            icon: noxIcon,
            iconOverride: const NoxMoonIcon(size: 22),
            color: kMint,
          ),
          _topBarAction(
            onPressed: () => _showOnboarding(),
            tooltip: t('使用引导'),
            icon: Icons.help_outline_rounded,
          ),
          _topBarAction(
            onPressed: _openHistory,
            tooltip: t('观星仓库'),
            icon: Icons.collections_bookmark_outlined,
          ),
          _topBarAction(
            onPressed: _pickLanguage,
            tooltip: t('界面语言：{0}', [appLanguage.value.nativeName]),
            icon: Icons.translate_rounded,
          ),
          // API 设置放在最右、而且不跟前面几个一样只画一个图标：它是这几个里面
          // 唯一一个「不配就用不起来」的入口（模型解读和在线解算都要 Key），
          // 用一个带字的胶囊把它从「随便逛逛」的图标里拎出来。
          Padding(
            padding: const EdgeInsets.only(left: 2, right: 6),
            child: _ApiEntry(onPressed: _settings),
          ),
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
                  'Snap the sky, read the stars.',
                  style: TextStyle(color: Color(0xFFA6B5C8)),
                ),
                const SizedBox(height: 20),
                if (_bytes == null) _emptyPicker() else _imagePreview(),
                // 后台还在跑的解析。放在选图区下面：它是「你刚才交代的那件事
                // 还没完」，而用户回到首页第一眼要找的正是它。
                if (_runningJobsNotice() case final notice?) ...[
                  const SizedBox(height: 10),
                  notice,
                ],
                if (_bytes != null) ...[
                  const SizedBox(height: 10),
                  _captureTimeCard(),
                  const SizedBox(height: 10),
                  _analysisModeCard(),
                ],
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
                  // 顺序按「用户此刻想知道什么」排：这张拍到了什么 → 拍得
                  // 怎么样 → 具体是哪些星 → 装备能拍到多暗。
                  //
                  // 「拍到了什么」放在图片**上面**：那是打开这一屏的第一个
                  // 问题，而看图是接下来才做的事。先给答案，再给证据。
                  _observationCard(analysis, solve),
                  const SizedBox(height: 14),
                  _captureParametersCard(analysis, solve),
                  const SizedBox(height: 14),
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
                  if (solve != null) ...[
                    const SizedBox(height: 12),
                    _finderCard(solve),
                  ],
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
                Positioned(
                  left: 22,
                  bottom: 25,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('今夜，抬头见星。'),
                        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        t('随手拍星，星象自明。'),
                        style: const TextStyle(color: Color(0xFFB2C0D2), fontSize: 12),
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
                  label: Text(t('从相册选择')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filledTonal(
                onPressed: () => _selectImage(ImageSource.camera),
                tooltip: t('拍摄照片'),
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
                label: Text(t('演示图'), style: const TextStyle(fontSize: 12)),
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
          Row(
            children: [
              // 这行原来不设弹性，字一长（320dp 窄屏、或系统大字号）整行就溢出，
              // 紧挨着的那个「？」被挤出屏幕——照看不误，但点不到。给它弹性，
              // 宽裕时尺寸不变，挤的时候让文字先让位。
              Flexible(
                child: Text(
                  t('支持JPG / PNG / TIFF / RAW 格式'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
                ),
              ),
              _HelpButton(
                title: t('能不能读 RAW'),
                message: t('整份 RAW 不解码，只读相机嵌在里面的那张 JPEG 预览——它足够检出星点。读不到就请在相机应用里导出 JPG/PNG。'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openLiveSky,
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: Text(t('实时星图 · 举起手机认星座')),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
        ],
      );

  /// 解析方式 + 拍摄场景 + Agent 报告开关。
  ///
  /// 两段都默认折叠，标题行直接写「已选什么」；展开后是 2×2 的图卡。
  /// 这样结果页上它只占两行，不会把「重新解析」挤成主角。
  Widget _analysisModeCard() {
    final compact = _analysis != null;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ExpansionTile(
            key: ValueKey('mode-section-${compact ? 'result' : 'pick'}'),
            initiallyExpanded: !compact,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: const Icon(Icons.tune_rounded, color: kMint),
            title: Text(
              '${t('解析方式')} · ${_analysisMode.label}',
              style: TextStyle(
                fontSize: compact ? 14 : 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              _analysisMode.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('照片是否出设备、用不用在线服务，都由这一项决定。'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8192A8),
                        height: 1.4,
                      ),
                    ),
                  ),
                  _HelpButton(
                    title: t('四种解析方式'),
                    message: t('本机解析：照片只在本机分析，绝不上传。\n'
                        '云端解析：先把分析预览图上传 Astrometry.net，用在线结果出报告。\n'
                        '本机优先：先本机解算，解不出来才上传。\n'
                        '云端优先：先上传拿坐标，再用本机星历补行星、彗星、矮行星和小行星。\n\n'
                        '在线方式需要先在「API 设置」里填写 Astrometry.net Key 并授权上传。'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _optionGrid([
                for (final mode in SkyAnalysisMode.values)
                  _optionTile(
                    label: mode.label,
                    asset: switch (mode) {
                      SkyAnalysisMode.localOnly => 'assets/ui/analysis_local.jpg',
                      SkyAnalysisMode.onlineOnly => 'assets/ui/analysis_online.jpg',
                      SkyAnalysisMode.localFirst =>
                        'assets/ui/analysis_local_first.jpg',
                      SkyAnalysisMode.onlineFirst =>
                        'assets/ui/analysis_online_first.jpg',
                    },
                    selected: _analysisMode == mode,
                    enabled: !(mode.requiresOnline && !_onlineReady),
                    onTap: () => _setAnalysisMode(mode),
                  ),
              ]),
              if (!_onlineReady) ...[
                const SizedBox(height: 6),
                Text(
                  t('在线解析需要先在「API 设置」里填写 Astrometry.net Key 并授权上传。'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: Color(0xFFFFDE77),
                  ),
                ),
              ],
            ],
          ),
          const Divider(height: 1),
          ExpansionTile(
            key: ValueKey('scene-section-${compact ? 'result' : 'pick'}'),
            initiallyExpanded: false,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            shape: const Border(),
            collapsedShape: const Border(),
            leading: const Icon(Icons.photo_size_select_small, color: kMint),
            title: Text(
              '${t('拍摄场景')} · ${_shootingScene.label}',
              style: TextStyle(
                fontSize: compact ? 14 : 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              _shootingScene.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('用来收窄解算的视场范围；不确定就选「自动」。'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF8192A8),
                        height: 1.4,
                      ),
                    ),
                  ),
                  _HelpButton(
                    title: t('拍摄场景怎么选'),
                    message: t('解算默认在全天、1°–120° 的范围里找。选一个场景会把视场范围收窄到这类照片常见的大小，'
                        '假候选少了，解算也就快了。选错只会让搜索范围不对，不会改坏照片；不确定就选「自动」。'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _optionGrid([
                for (final scene in ShootingScene.values)
                  _optionTile(
                    label: scene.label,
                    asset: switch (scene) {
                      ShootingScene.auto => 'assets/ui/scene_auto.jpg',
                      ShootingScene.wide => 'assets/ui/scene_wide.jpg',
                      ShootingScene.deepSky => 'assets/ui/scene_medium.jpg',
                      ShootingScene.narrow => 'assets/ui/scene_long.jpg',
                    },
                    selected: _shootingScene == scene,
                    onTap: () => _setShootingScene(scene),
                  ),
              ]),
            ],
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: _generateAgentReport,
              onChanged: (value) => _setGenerateAgentReport(value ?? false),
              title: Text(
                t('生成 Agent 分析报告'),
                style: TextStyle(fontSize: compact ? 13 : 14),
              ),
              subtitle: Text(
                t('解析完成后自动让 Agent 写一份解读。'),
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 2×2 的选项网格。四项正好两行，不会因为宽度变化挤成一行。
  Widget _optionGrid(List<Widget> tiles) {
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 8));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: tiles[i]),
            const SizedBox(width: 8),
            Expanded(
              child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox(),
            ),
          ],
        ),
      );
    }
    return Column(children: rows);
  }

  Widget _optionTile({
    required String label,
    required String asset,
    required bool selected,
    required VoidCallback onTap,
    bool enabled = true,
  }) =>
      Opacity(
        opacity: enabled ? 1 : 0.45,
        child: AspectRatio(
          aspectRatio: 1.55,
          child: Material(
            color: const Color(0xFF101C2E),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    asset,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Color(0xFF16263D)),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x22000000), Color(0xDD050A12)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 9,
                    right: 9,
                    bottom: 8,
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ),
                  if (selected)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: kMint,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check,
                          size: 14,
                          color: Color(0xFF061018),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

  /// 拍摄时间那一行。
  ///
  /// 单开一张卡而不是藏进设置：它属于**这一张照片**，换一张图就重读一次，
  /// 用户得在解析之前就看明白这张图有没有时间可用。行星、彗星、小行星都在
  /// 天上走，没有时刻就无从判断画面上多出来的那个亮点是什么——所以读不到
  /// EXIF 时间时，提示可以设置；读到时则允许直接修改。
  Widget _captureTimeCard() {
    final moment = _moment;
    final known = moment != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 18,
              color: known ? kMint : Colors.orangeAccent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    known
                        ? _describeMoment(moment)
                        : t('未能从照片读取拍摄时间'),
                    style: const TextStyle(fontSize: 13.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    known ? _captureNote(moment) : t('是拍行星和小行星的前提'),
                    style: const TextStyle(
                      color: Color(0xFF8192A8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (!known)
              _HelpButton(
                title: t('为什么要拍摄时间'),
                message: t('行星、彗星和小行星的位置随时间变化，没有拍摄时刻就没法判断画面上多出来的那个亮点是什么。时区没读到就按本机时区算。'),
              ),
            TextButton(
              onPressed: _pickCaptureTime,
              child: Text(known ? t('修改时间') : t('设置时间')),
            ),
          ],
        ),
      ),
    );
  }

  static String _describeMoment(CaptureMoment moment) {
    String two(int value) => value.toString().padLeft(2, '0');
    final local = moment.local;
    return t('拍摄时间  {0}-{1}-{2} {3}:{4}', [local.year, two(local.month), two(local.day), two(local.hour), two(local.minute)]);
  }

  static String _momentNote(CaptureMoment moment) {
    final source = t(moment.source.label);
    if (moment.hasKnownOffset) return t('{0}，时区也读到了', [source]);
    // 没读到时区就按本机时区算。手机照片基本就是设备本地时间拍的，这是能
    // 拿到的最接近的假设；报告里会写明这一条是假设，不是读出的事实。
    return t('{0}；按当前时区算', [source]);
  }

  /// 相机型号、光圈、快门、ISO、焦距，读到的才写。
  static String _describeCamera(CaptureMoment moment) => [
        if (moment.device != null) moment.device!,
        if (moment.fNumber != null) moment.fNumber!,
        if (moment.exposure != null) moment.exposure!,
        if (moment.iso != null) 'ISO ${moment.iso}',
        if (moment.focalLength != null) moment.focalLength!,
      ].join(' · ');

  static String _captureNote(CaptureMoment moment) {
    final camera = _describeCamera(moment);
    final note = _momentNote(moment);
    return camera.isEmpty ? note : '$camera · $note';
  }

  /// 让用户修改或设置拍摄时间。
  ///
  /// 日期和时刻分两次问：合成一个对话框要么自己做一套选择器，要么在
  /// Material 的两个标准弹窗之间跳，前者工作量大、后者反而更绕。
  Future<void> _pickCaptureTime() async {
    final now = DateTime.now();
    final current = _moment?.local ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: current.isAfter(now) ? now : current,
      firstDate: DateTime(1990),
      lastDate: now.add(const Duration(days: 1)),
      helpText: t('这张照片是哪天拍的'),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: t('拍摄时刻（当地时间）'),
    );
    if (time == null || !mounted) return;
    final edited = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (_moment != null &&
        _moment!.isManual &&
        _moment!.local.isAtSameMomentAs(edited)) {
      return;
    }
    setState(() {
      _moment = CaptureMoment(
        local: edited,
        // 手填的是「当地时间」，时区仍然未知，和 EXIF 里只有时间没有偏移的
        // 情形走同一条路。
        offset: null,
        source: CaptureTimeSource.manual,
        // 改的只是时间；相机型号、ISO 这些是从 EXIF 读出来的事实，不该跟着
        // 一起丢。
        device: _moment?.device,
        iso: _moment?.iso,
        exposure: _moment?.exposure,
        fNumber: _moment?.fNumber,
        focalLength: _moment?.focalLength,
      );
      // 解算结果里带着「那几个多出来的亮点是什么」的结论，而结论依赖时刻。
      // 时间一改，旧结论就不成立了——留着比清掉更糟，用户会拿一份按旧时间
      // 算出来的判断当事实。所以这里和换图一样作废，提示重新解析。
      if (_analysis != null) {
        _analysis = null;
        _solve = null;
        _explanation = null;
        _warnings = const [];
        _savedId = null;
        _selectedTarget = null;
      }
    });
    if (_bytes != null && !_running) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('拍摄时间已更新，重新解析后会用到它'))),
      );
    }
  }

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
            _filename ?? t('已选图片'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_cropping && !_isRawName(_filename ?? ''))
            CropEditor(
              bytes: _bytes!,
              rect: _crop ?? CropRect.full,
              onChanged: (rect) => setState(() => _crop = rect),
            )
          else
            AspectRatio(
              aspectRatio: 0.82,
              child: _isRawName(_filename ?? '')
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.raw_on, size: 42, color: kMint),
                          const SizedBox(height: 10),
                          Text(t('相机 RAW · 将尝试读取内嵌预览')),
                        ],
                      ),
                    )
                  : Image.memory(
                      _bytes!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, error, __) => Center(
                        child: Text(
                          t('暂不支持此图片格式：{0}', [error]),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _filename ?? t('已选图片'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                if (_cropping) ...[
                  Text(
                    t('拖四个角选范围'),
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFFA6B5C8)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _resetCrop,
                          icon: const Icon(Icons.restart_alt, size: 17),
                          label: Text(t('整幅')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _applyCrop,
                          icon: const Icon(Icons.crop_rounded, size: 17),
                          label: Text(t('应用裁剪')),
                        ),
                      ),
                    ],
                  ),
                ] else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _cropping = true;
                        _crop = CropRect.full;
                      }),
                      icon: const Icon(Icons.crop_rounded, size: 17),
                      label: Text(t('裁剪范围')),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _resetCrop() => setState(() => _crop = CropRect.full);

  /// 按选中的范围裁出新的图片字节，之后的解析只用这一块。
  ///
  /// 换掉的是**当前这张图**，而不是另存一张：用户的意图是「我要分析的是
  /// 这一块」，不是「我多了一张图」。裁剪之后再解析、再保存，记录里存下来
  /// 的也就是裁好的这一块——他拿到的东西和看到的东西是同一个。
  Future<void> _applyCrop() async {
    final bytes = _bytes;
    final crop = _crop;
    if (bytes == null || crop == null) return;
    final cropped = cropImageBytes(bytes, crop);
    if (cropped == null) {
      setState(() => _cropping = false);
      return;
    }
    setState(() => _cropping = false);
    // 裁剪会把嵌入的 EXIF 一起丢掉，所以已经读到的拍摄时刻要显式带过去，
    // 否则裁一刀就把「这张照片几点拍的」丢掉了——而月相和行星位置全靠它。
    _setImage(cropped, _croppedName(_filename) ?? t('裁剪后的图片'), moment: _moment);
  }

  /// 裁剪之后文件名上留个记号，用户能看出这张图动过。保存时记录另按内容
  /// 取名字（见 naming.dart），所以这里只影响显示。
  String? _croppedName(String? name) {
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? t('{0} (裁剪)', [name]) : t('{0} (裁剪)', [name.substring(0, dot)]);
  }

  Widget _diagnosticsCard(SkyAnalysis analysis) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SectionTitle(t('图像诊断'), Icons.monitor_heart_outlined),
                  _HelpButton(
                    title: t('图像指标说明'),
                    message:
                        t('视觉背景指数会受曝光、ISO、白平衡和后期处理影响，不是 SQM 光度或 Bortle 等级。线状候选可能来自拖线、失焦或处理伪影，单张图片不能确认卫星或飞机。'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MetricChip(t('质量'), analysis.quality),
                  MetricChip(t('紧凑点源'), '${analysis.compactSources.length}'),
                  if (analysis.streakCandidates.isNotEmpty)
                    MetricChip(t('线状候选'), '${analysis.streakCandidates.length}'),
                  MetricChip(t('背景噪声'), '${(analysis.noise * 100).toStringAsFixed(1)}%'),
                  MetricChip(t('视觉背景'), '${analysis.backgroundIndex.toStringAsFixed(0)} / 100'),
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
            builder: (context, constraints) => InteractiveViewer(
              transformationController: _viewer,
              // 缩到 1 倍以下没意义——图本来就整个缩在框里，四周是留白；放大
              // 到 8 倍以上也看不出更多东西，只是把像素拉成色块。
              minScale: 1,
              maxScale: 8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 这里的 localPosition 已经是要用的坐标：GestureDetector 在
                // InteractiveViewer 的子树里，命中测试顺着变换矩阵找下来，
                // 缩放和平移都替我们反算过了。再手动 `toScene` 一次等于反算
                // 两遍——图放大两倍，点两倍远的地方才会选中同一颗星，而且不
                // 会报错，只会「点不准」。
                onTapUp: (details) => _selectNearest(
                  details.localPosition,
                  constraints.biggest,
                  analysis,
                ),
                // 图和圆圈一起变换：放大之后圆圈必须跟着放大，否则它指的位置
                // 就不再是它画的那个星点。所以两者放在同一个被变换的子树里，
                // 而不是各自算一遍缩放。
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 历史记录里的图片文件被删掉或损坏时预览是空字节。空字节
                    // 交给 Image.memory 会抛一串英文异常，而这时坐标和星表都
                    // 还是好的——用户该看到的是「图找不到了」，不是报错。
                    if (bytes.isEmpty)
                      const MissingImage()
                    else
                      Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const MissingImage(),
                      ),
                    CustomPaint(
                      painter: DetectedStarsPainter(
                        analysis: analysis,
                        namedStars: _visibleNamedStars(analysis, solve),
                        objects: _visibleDeepSkyObjects(solve),
                        // 运动天体的圆心是检出到的那颗亮点，而星历位置只有
                        // 赤经赤纬，得靠 WCS 现推——所以这两个一起传。
                        bodies: _visibleMovingBodies(solve),
                        wcs: solve?.wcs,
                        arcsecPerPixel: solve?.arcsecPerPixel ?? 0,
                        // 关掉连线时传空表而不是把 painter 换一个：换 painter
                        // 会让整张图重画，而这里只是少画几条线。
                        figures: _visibleConstellationFigures(solve),
                        hidden: _hiddenIndices(analysis, solve),
                        selected: _selectedTarget,
                        selectedObjectName: _selectedDeepSkyName,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(left: 8, top: 8, child: _imageModeToggle()),
          Positioned(right: 8, top: 8, child: _constellationToggle(solve)),
          Positioned(right: 8, top: 44, child: _fullscreenButton(analysis, solve)),
          Positioned(right: 8, top: 80, child: _zoomReset()),
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

  List<ConstellationFigure> _visibleConstellationFigures(SolveResult? solve) =>
      _showConstellations ? solve?.constellationFigures ?? const [] : const [];

  /// 全屏看图。
  ///
  /// 半屏那块图能放的像素就那么多：视场里几十颗星时，编号和名字挤在一起，
  /// 想看清一颗星到底标的哪儿，只能靠捏合放大——而捏合是「看得到但存不下」
  /// 的：想让别人也看到，就得把这张图导出去。
  ///
  /// 所以全屏里配了两件事：整屏看图（自己一套缩放控制器，不影响半屏那块），
  /// 以及导出这张带标注的图。
  Widget _fullscreenButton(SkyAnalysis analysis, SolveResult? solve) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _openFullscreen(analysis, solve),
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.fullscreen, size: 17, color: kMint),
          ),
        ),
      );

  Future<void> _openFullscreen(SkyAnalysis analysis, SolveResult? solve) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => FullscreenImagePage(
          bytes: _showProcessed ? analysis.processedPreview : analysis.preview,
          painter: DetectedStarsPainter(
            analysis: analysis,
            namedStars: _visibleNamedStars(analysis, solve),
            objects: _visibleDeepSkyObjects(solve),
            bodies: _visibleMovingBodies(solve),
            wcs: solve?.wcs,
            arcsecPerPixel: solve?.arcsecPerPixel ?? 0,
            figures: _visibleConstellationFigures(solve),
            hidden: _hiddenIndices(analysis, solve),
            selected: _selectedTarget,
            selectedObjectName: _selectedDeepSkyName,
          ),
          onExport: () => _exportAnnotated(analysis, solve),
        ),
      ),
    );
  }

  /// 导出这张带标注的图，交给系统分享面板。
  ///
  /// 半屏和全屏走的是同一套「当前勾选」：隐去的组、收起的星，导出的图里
  /// 同样没有。用户在屏幕上看到什么，拿到的就是什么。
  Future<void> _exportAnnotated(
    SkyAnalysis analysis,
    SolveResult? solve,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final png = await renderAnnotatedPng(
        analysis: analysis,
        baseImage: _showProcessed ? analysis.processedPreview : analysis.preview,
        namedStars: _visibleNamedStars(analysis, solve),
        objects: _visibleDeepSkyObjects(solve),
        figures: _visibleConstellationFigures(solve),
        bodies: _visibleMovingBodies(solve),
        hidden: _hiddenIndices(analysis, solve),
        wcs: solve?.wcs,
        arcsecPerPixel: solve?.arcsecPerPixel ?? 0,
      );
      final name = suggestedObservationName(
        analysis: analysis,
        solve: solve,
        moment: _moment?.local,
        originalFilename: _filename,
      );
      final file = await saveAnnotatedPng(png, fileName: t('{0} 标注.png', [name]));
      await shareExportedFile(file, text: t('AstroSophy 标注图'));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t('导出失败：{0}', [error]))));
    }
  }

  /// 回到整幅。
  ///
  /// 放大容易，缩回去难：指尖要精确地把比例捏回 1.0 并不顺手，而多数人只是
  /// 想凑近确认一颗星，看完就要退回全图。不给出口的话，用户会一直停在一个
  /// 自己都收不回来的状态里。
  Widget _zoomReset() {
    if (!_isZoomed) return const SizedBox.shrink();
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _viewer.value = Matrix4.identity(),
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(Icons.zoom_out_map, size: 17, color: kMint),
        ),
      ),
    );
  }

  /// 原图 / 处理图切换。
  ///
  /// 处理图扣掉了天空背景、抹掉了非星场区域，星场本身反而看得更清楚；但它
  /// 是加工过的，不能拿来判断「我到底拍到了什么」。所以两张都留着，默认给
  /// 用户看没动过的原图。
  Widget _imageModeToggle() => SegmentedButton<bool>(
        segments: [
          ButtonSegment(value: false, label: Text(t('原图'))),
          ButtonSegment(value: true, label: Text(t('处理图'))),
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

  /// 星座连线的开关。
  ///
  /// 没解算出星座时整个按钮不出现——一个按下去什么也不会发生的开关比没有
  /// 开关更让人困惑。
  Widget _constellationToggle(SolveResult? solve) {
    if (solve == null || solve.constellationFigures.isEmpty) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() => _showConstellations = !_showConstellations),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            _showConstellations ? Icons.polyline : Icons.polyline_outlined,
            size: 17,
            color: _showConstellations ? kMint : const Color(0xFF8192A8),
          ),
        ),
      ),
    );
  }

  /// 图下方那一小块说明：现在选中的是第几号。
  ///
  /// 没选中任何东西时整块不出现。原来这里放着一句「点图中的亮点，或点下方
  /// 列表……」，那是在教一个不用教的动作——图上标着编号、列表紧贴在下面，
  /// 谁都会去点。它占着图的下缘，却一句有效信息都没有。
  /// 选中的读数则必须留：编号把列表和图对上，读数把「对上了什么」说出来。
  Widget _selectionHint(SkyAnalysis analysis, SolveResult? solve) {
    final targets = analysis.numberedTargets;
    final index = _selectedTarget;
    final String text;
    if (_selectedMovingBodyName != null) {
      final body = solve?.movingBodies
          .where((item) => item.name == _selectedMovingBodyName)
          .firstOrNull;
      text = body == null
          ? t('系内天体 · {0}', [_selectedMovingBodyName])
          : t('系内天体 · {0}（{1}）{2}', [body.name, t(body.kind.label), body.magnitude == null ? '' : t(' · 约 {0} 等', [body.magnitude!.toStringAsFixed(1)])]);
    } else if (_selectedDeepSkyName != null) {
      final object = solve?.deepSkyObjects
          .where((item) => item.name == _selectedDeepSkyName)
          .firstOrNull;
      text = t('深空天体 · {0}', [object == null ? _selectedDeepSkyName! : deepSkyCaption(object.name, object.category)]);
    } else if (index == null || index >= targets.length) {
      return const SizedBox.shrink();
    } else {
      final star = targets[index];
      final position =
          t('像素 ({0}, {1})', [star.x.toStringAsFixed(0), star.y.toStringAsFixed(0)]);
      if (star.isRejected) {
        text = t('第 {0} 号 · {1} · 已判为非天体，不计入报告', [index + 1, position]);
      } else {
        final name = _nearestNamed(star, solve?.namedStars ?? const []);
        final what = name?.name ?? (star.isElongated ? t('拉长点源') : t('未匹配点源'));
        text = t('第 {0} 号 · {1} · {2}', [index + 1, what, position]);
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
    setState(() {
      _selectedTarget = best;
      _selectedDeepSkyName = null;
      _selectedMovingBodyName = null;
    });
  }

  /// 图上目标列表。
  ///
  /// 星点分成三组不是为了好看，而是因为这三类东西对用户意味着完全不同的事：
  /// 有名字的回答「我拍到了什么」，没名字的回答「我这套设备能拍到多暗」，
  /// 可疑飞线回答「这张要不要重拍」。深空天体另列一组，按目录名称独立管理。
  ///
  /// 分组只是显示上的事：编号仍然是 [SkyAnalysis.numberedTargets] 的下标，
  /// 图上画的 ⑦ 和列表里的 ⑦ 永远是同一个东西。按组重排编号，这套对应就断了。
  ///
  /// − / + 管的是图上画不画圆圈，不是「算不算数」。绝大多数时候用户想做的
  /// 是「把挡事的那一堆先收起来，好看清剩下几颗」，这跟测量结果没有半点关系。
  /// 全页唯一会动数据的开关长在可疑飞线上（那对 ✓ / ✗）。
  Widget _highlightsCard(SkyAnalysis analysis, SolveResult? solve) {
    final targets = analysis.numberedTargets;
    final groups = _categoriseTargets(targets, solve);
    final deepSkyObjects = _sortedDeepSkyObjects(solve);
    final movingBodies = solve?.movingBodies ?? const <MovingBodySuspicion>[];
    final markableBodies = [
      for (final body in movingBodies)
        if (body.detected) body,
    ];
    // 算一次，往下传：每行都要知道自己画不画，逐行去重算一遍就是 O(n²)，
    // 而这一页的检出点源动辄上千个。
    final hidden = _hiddenIndices(analysis, solve);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: SectionTitle(t('图上目标'), Icons.blur_on_rounded),
                ),
                // 各分组的 − / + 分别管理，这两个一次管全部。
                _batchButton(
                  Icons.remove_circle_outline,
                  t('把图上所有的圆圈都隐去'),
                  hidden.length +
                          _hiddenDeepSkyObjects.length +
                          _hiddenMovingBodies.length <
                      targets.length +
                          deepSkyObjects.length +
                          markableBodies.length,
                  () => _setAllCircles(true, deepSkyObjects, markableBodies),
                ),
                _batchButton(
                  Icons.add_circle_outline,
                  t('把图上所有的圆圈都显示回来'),
                  hidden.isNotEmpty ||
                      _hiddenDeepSkyObjects.isNotEmpty ||
                      _hiddenMovingBodies.isNotEmpty,
                  () => _setAllCircles(false, deepSkyObjects, markableBodies),
                ),
                _HelpButton(
                  title: t('图上目标'),
                  message:
                      t('星点编号与上图里的编号一一对应，点一行就能在图上定位到那一颗；深空天体和系内天体按名称单独管理。双指捏合可以把图放大。放大之后圆圈跟着一起放大。每一行右边的 − 把那一颗的圆圈从图上隐去，+ 显示回来；组标题右边的 − / + 一次管整组，卡片标题右边这两个一次管全部。星点编号颜色表示识别可信度：薄荷绿较高、黄色中等、粉红色较低。图上四类目标用四种记号，互不相同：亮星是薄荷绿实线圆，深空天体是粉色实线圆（大小跟着天体自身的角尺寸），行星和矮行星是琥珀色虚线圆加十字，小行星和彗星是浅蓝色四角框加十字。虚线和方框都在说同一件事：这个位置是算出来的，不是看出来的。隐去只是不画，测量结果、报告和星表匹配一个字都不变。「系内天体」里写着「图上没有对上」的那几条画的是点线圆，位置就是星历算出来的那一个——它们说的是「按星历它在这张照片的这个位置上，但亮度不够，没能在图上认出来」，用的是这里最弱的一种记号。「可疑飞线」那一组另外有一对 ✓ / ✗，用来判断它到底是不是天体——判为 ✗ 的会从测光和报告里排除，但仍在图上和列表里，随时能改回来。拉长的亮点可能是卫星、飞机或赤道仪抖动，也可能是被拖了尾的恒星，单张照片无法确认是哪一种。'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 3, 12, 8),
            child: Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 10.5),
                children: [
                  TextSpan(text: t('颜色置信度：')),
                  TextSpan(
                    text: t('较高 ≥70%'),
                    style: const TextStyle(color: kMint),
                  ),
                  const TextSpan(text: ' · '),
                  TextSpan(
                    text: t('中等 35–69%'),
                    style: const TextStyle(color: Color(0xFFFFDE77)),
                  ),
                  const TextSpan(text: ' · '),
                  TextSpan(
                    text: t('较低 <35%'),
                    style: const TextStyle(color: Color(0xFFFF7B8C)),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: targets.isEmpty && deepSkyObjects.isEmpty && movingBodies.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        // 月面照片上当然「没有检出目标」——那条链路压根不在月面上
                        // 找点源。照直写「没有检出目标」，用户会以为这张图白拍了，
                        // 而其实月盘、亮面占比、相名都算出来了，只是画在图上了。
                        analysis.moonDisc != null
                            ? t('这是月面照片：星点、深空天体和系内天体都不在月面上找。月盘的位置和亮面占比已经标在图上了。')
                            : t('没有检出目标。'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF8192A8)),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 10),
                    children: [
                      _deepSkyGroup(deepSkyObjects, solve),
                      _intraSolarGroup(solve),
                      _targetGroup(
                        id: 'named',
                        title: t('亮星'),
                        icon: Icons.star_outline_rounded,
                        emptyHint: t('没有和星表对上名字的星。'),
                        targets: targets,
                        items: groups.named,
                        hidden: hidden,
                        solve: solve,
                      ),
                      _targetGroup(
                        id: 'unnamed',
                        title: t('未匹配星点'),
                        icon: Icons.blur_on_rounded,
                        emptyHint: t('没有未命名的点源。'),
                        targets: targets,
                        items: groups.unnamed,
                        hidden: hidden,
                        solve: solve,
                      ),
                      _targetGroup(
                        id: 'streaks',
                        title: t('可疑飞线'),
                        icon: Icons.horizontal_rule_rounded,
                        emptyHint: t('没有发现拉长的亮点。'),
                        targets: targets,
                        items: groups.streaks,
                        hidden: hidden,
                        solve: solve,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 分组标题上那个小图标的颜色，和图上画这一类东西时用的颜色一致——
  /// 列表里的「可疑飞线」和图上那些粉色椭圆是同一件事，颜色对上就省掉一次
  /// 解释。
  Color _groupColor(String id) => switch (id) {
        'named' => const Color(0xFFFFDE77),
        'streaks' => const Color(0xFFFF7B8C),
        _ => kMint,
      };

  List<SkyObject> _sortedDeepSkyObjects(SolveResult? solve) {
    final objects = [...?solve?.deepSkyObjects];
    objects.sort(
      (a, b) => (b.angularSizeArcmin ?? -1)
          .compareTo(a.angularSizeArcmin ?? -1),
    );
    return objects;
  }

  /// 图上要画圈的那几个。
  ///
  /// 「太大又没有星等」的那些不传进来（判据见 [DeepSkyEntry.worthMarkingOnImage]）。
  /// 它们在下面的列表里照旧有一行——用户该知道画面里有它——只是图上没有圈，
  /// 所以也就没有「隐去那一个」这件事可做。
  List<SkyObject> _visibleDeepSkyObjects(SolveResult? solve) => [
        for (final object in _sortedDeepSkyObjects(solve))
          if (!_hiddenDeepSkyObjects.contains(object.name) &&
              _worthMarking(object, solve))
            object,
      ];

  /// 图上要画标记的系内天体。
  ///
  /// 「没认出来」的那种（[detected] 为假）也在这里面：它画的是点线圆，位置就是
  /// 星历算出来的那一个。列进这一组是为了让它跟着显隐开关走——用户按了「从图上
  /// 隐去」，两个记号都得消失，否则那个开关只做了一半的事。
  List<MovingBodySuspicion> _visibleMovingBodies(SolveResult? solve) => [
        for (final body in solve?.movingBodies ?? const <MovingBodySuspicion>[])
          if (!_hiddenMovingBodies.contains(body.name)) body,
      ];

  /// 这个天体在图上画不画圈。
  ///
  /// 角尺寸和像场之比要现算：判据用的是「占像场多大」，而不是绝对角分——
  /// 同一个 180′ 的天体，放在 45° 的广角里是个小圈，放在 4° 的视场里就是
  /// 绕着整幅画的一个环，只有相对大小才说明得了它画出来是什么样。
  static bool _worthMarking(SkyObject object, SolveResult? solve) =>
      worthMarkingOnImage(
        sizeArcmin: object.angularSizeArcmin,
        magnitude: object.magnitude,
        fieldOfViewDegrees: solve?.fieldOfViewDegrees ?? 0,
      );

  Widget _deepSkyGroup(List<SkyObject> objects, SolveResult? solve) {
    const id = 'deepSky';
    final collapsed = _collapsedGroups.contains(id);
    final visibleObjects = objects
        .where((object) => !_hiddenDeepSkyObjects.contains(object.name))
        .toList();
    final canHide = visibleObjects.isNotEmpty;
    final canShow = visibleObjects.length < objects.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (!_collapsedGroups.remove(id)) _collapsedGroups.add(id);
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(
              children: [
                Icon(
                  collapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                  color: const Color(0xFF8192A8),
                ),
                const Icon(
                  Icons.public_rounded,
                  size: 15,
                  color: Color(0xFFFF7B8C),
                ),
                if (!canHide && objects.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.visibility_off_outlined,
                    size: 13,
                    color: Color(0xFF8192A8),
                  ),
                ],
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t('深空天体  {0}', [objects.length]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _batchButton(
                  Icons.remove_circle_outline,
                  t('把深空天体的标记从图上隐去'),
                  canHide,
                  () => setState(() {
                    _hiddenDeepSkyObjects.addAll(
                      objects.map((object) => object.name),
                    );
                  }),
                ),
                _batchButton(
                  Icons.add_circle_outline,
                  t('显示全部深空天体标记'),
                  canShow,
                  () => setState(() => _hiddenDeepSkyObjects.clear()),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          if (objects.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 2, 12, 10),
              child: Text(
                t('这片视场没有识别到深空天体。'),
                style: const TextStyle(color: Color(0xFF8192A8), fontSize: 12),
              ),
            )
          else
            for (final object in objects)
              _deepSkyRow(object, solve),
        const Divider(height: 1),
      ],
    );
  }

  Widget _deepSkyRow(SkyObject object, SolveResult? solve) {
    final isHidden = _hiddenDeepSkyObjects.contains(object.name);
    final isSelected = _selectedDeepSkyName == object.name;
    final markable = _worthMarking(object, solve);
    // 「有中文常用名」这件事现在是标题上看得见的：M 16 写成「M 16 鹰状星云」。
    // 之前是拿「名字里有没有汉字」来判的，那对 M 16 这种编号根本不成立——
    // 于是它在列表里是灰的，而报告里却写着鹰状星云。
    final nickname = nicknameOf(object.name);
    final angularSize = object.angularSizeArcmin;
    final details = <String>[
      // 昵称已经写进标题了，副标题里不再重复类型——「鹰状星云 · 星云」是废话。
      if (nickname == null && object.category.isNotEmpty) object.category,
      if (angularSize != null && angularSize > 0)
        angularSize < 1
            ? t('约 {0}″', [(angularSize * 60).round()])
            : angularSize < 60
                ? t('约 {0}′', [angularSize.toStringAsFixed(1)])
                : t('约 {0}°', [(angularSize / 60).toStringAsFixed(2)]),
    ];
    if (angularSize != null && angularSize > 0) {
      final field = solve?.fieldOfViewDegrees ?? 0;
      if (field > 0) {
        final fraction = (angularSize / 60) / field;
        details.add(
          fraction >= 1
              ? t('大于视场对角线')
              : t('约占视场 {0}%', [(fraction * 100).round()]),
        );
      }
    }

    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: const Color(0xFFFF7B8C).withValues(alpha: 0.10),
      onTap: () => setState(() {
        _selectedTarget = null;
        _selectedDeepSkyName = object.name;
        _hiddenDeepSkyObjects.remove(object.name);
      }),
      leading: Icon(
        Icons.public_rounded,
        size: 20,
        color: isHidden
            ? const Color(0xFF8192A8)
            : const Color(0xFFFF7B8C),
      ),
      title: Text(
        deepSkyCaption(object.name, object.category),
        style: TextStyle(
          color: isHidden
              ? const Color(0xFF8192A8)
              : nickname != null
                  ? const Color(0xFFFFDE77)
                  : null,
          fontWeight: nickname != null ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: details.isEmpty
          ? null
          : Text(
              details.join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 「又大又没星等」的天体图上本来就没画圈（判据见
          // [worthMarkingOnImage]），所以这里没有加减号可给——给了一个按下去
          // 什么也不会发生的开关，比没有开关更让人困惑。
          if (markable) ...[            _batchButton(
              Icons.remove_circle_outline,
              t('把 {0} 的标记从图上隐去', [object.name]),
              !isHidden,
              () => setState(() => _hiddenDeepSkyObjects.add(object.name)),
              dense: true,
            ),
            _batchButton(
              Icons.add_circle_outline,
              t('显示 {0} 的标记', [object.name]),
              isHidden,
              () => setState(() => _hiddenDeepSkyObjects.remove(object.name)),
              dense: true,
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                t('弥漫星体'),
                style: const TextStyle(fontSize: 11, color: Color(0xFF8192A8)),
              ),
            ),
        ],
      ),
    );
  }

  /// 系内天体那一组：行星、矮行星、小行星、彗星。
  ///
  /// 规格和 [_deepSkyGroup] 完全一致（同样的折叠、同样的整组隐去、同样逐项
  /// 加减号），位置紧随其后。分开成两组是因为判据不同，而不是因为长相不同：
  /// 深空天体靠「目录里有这个天体、坐标对得上」，系内天体靠「星表里这个位置
  /// 没有星、而且星历说它就在这儿」——后者依赖拍摄时刻，前者不依赖。
  ///
  /// 组里会出现两种条目，两种现在图上都有记号：
  ///
  ///   * 认出来了的——虚线圈或四角框，加一个星历位置的十字；
  ///   * 「画面里还有，但没对上」的——点线圆，位置就是星历算出来的那一个。
  ///
  /// 两种都给 − / +。以前只有前一种有，理由是「图上本来就没画」；现在后一种也
  /// 画了点线圆，再留一个按下去什么也不发生的开关就成了谎话。
  Widget _intraSolarGroup(SolveResult? solve) {
    const id = 'intraSolar';
    final bodies = solve?.movingBodies ?? const <MovingBodySuspicion>[];
    final collapsed = _collapsedGroups.contains(id);
    // 只有真的画在图上的才配叫「可视化」，也才有显隐可谈。坐标不是有限数就没得画
    // （画布上是 NaN，用户什么也看不到），这也顺带把「认出来了」和「没对上」两类
    // 一并收进来——它们的 [MovingBodySuspicion.x] 都是可用的像素坐标。
    final markable = [
      for (final body in bodies)
        if (body.x.isFinite && body.y.isFinite) body,
    ];
    final visible = markable
        .where((body) => !_hiddenMovingBodies.contains(body.name))
        .toList();
    final canHide = visible.isNotEmpty;
    final canShow = visible.length < markable.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (!_collapsedGroups.remove(id)) _collapsedGroups.add(id);
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(
              children: [
                Icon(
                  collapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                  color: const Color(0xFF8192A8),
                ),
                const Icon(
                  Icons.brightness_7_rounded,
                  size: 15,
                  color: Color(0xFFFFAB40),
                ),
                if (!canHide && bodies.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.visibility_off_outlined,
                    size: 13,
                    color: Color(0xFF8192A8),
                  ),
                ],
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t('系内天体  {0}', [bodies.length]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _batchButton(
                  Icons.remove_circle_outline,
                  t('把系内天体的标记从图上隐去'),
                  canHide,
                  () => setState(() {
                    _hiddenMovingBodies.addAll(
                      markable.map((body) => body.name),
                    );
                  }),
                ),
                _batchButton(
                  Icons.add_circle_outline,
                  t('显示全部系内天体标记'),
                  canShow,
                  () => setState(() => _hiddenMovingBodies.clear()),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          if (bodies.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 2, 12, 10),
              child: Text(
                t('无系内天体。'),
                style: const TextStyle(color: Color(0xFF8192A8), fontSize: 12),
              ),
            )
          else
            for (final body in bodies) _intraSolarRow(body),
        const Divider(height: 1),
      ],
    );
  }

  Widget _intraSolarRow(MovingBodySuspicion body) {
    final isHidden = _hiddenMovingBodies.contains(body.name);
    final isSelected = _selectedMovingBodyName == body.name;
    // 行星和矮行星一套颜色，小行星和彗星另一套——和图上那两套记号一一对应，
    // 否则用户在列表里点了一行、到图上找不到对应的是哪个框。
    final accent = body.kind.isMajorPlanet
        ? const Color(0xFFFFAB40)
        : const Color(0xFF7FD8FF);
    final details = <String>[
      t(body.kind.label),
      if (!body.detected)
        t('图上没有对上')
      else if (body.separationArcsec < movingBodyCoincidenceArcsec)
        t('位置重合')
      else
        t('和星历差 {0}″', [body.separationArcsec.round()]),
      if (body.magnitude != null && !body.magnitudeIsRough)
        t('约 {0} 等', [body.magnitude!.toStringAsFixed(1)])
      else if (body.magnitude != null)
        t('亮度大约 {0} 等', [body.magnitude!.round()])
      else
        t('亮度未知'),
      if (body.distanceAu != null)
        t('距地球 {0} AU', [body.distanceAu!.toStringAsFixed(2)]),
      if (body.catalogBuilt != null) t('表建于 {0}', [body.catalogBuilt]),
    ];

    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: accent.withValues(alpha: 0.10),
      onTap: () => setState(() {
        _selectedTarget = null;
        _selectedDeepSkyName = null;
        _selectedMovingBodyName = body.name;
        _hiddenMovingBodies.remove(body.name);
      }),
      leading: Icon(
        body.kind.isMajorPlanet
            ? Icons.brightness_7_rounded
            : Icons.auto_awesome_rounded,
        size: 20,
        color: isHidden ? const Color(0xFF8192A8) : accent,
      ),
      title: Text(
        body.name,
        style: TextStyle(
          color: isHidden ? const Color(0xFF8192A8) : accent,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        details.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _batchButton(
            Icons.remove_circle_outline,
            t('把 {0} 的标记从图上隐去', [body.name]),
            !isHidden,
            () => setState(() => _hiddenMovingBodies.add(body.name)),
            dense: true,
          ),
          _batchButton(
            Icons.add_circle_outline,
            t('显示 {0} 的标记', [body.name]),
            isHidden,
            () => setState(() => _hiddenMovingBodies.remove(body.name)),
            dense: true,
          ),
        ],
      ),
    );
  }

  /// 把编号列表分成三组，每组记着自己在全局编号里的下标。
  ///
  /// 「有没有名字」用的就是图上标注名字的那套判据 [_nearestNamed]，阈值也
  /// 一样。这里刻意不另立标准：图上标着「参宿四」的那颗星，列表里就必须出现
  /// 在「亮星」组，否则用户会以为两边说的不是同一颗。
  _TargetGroups _categoriseTargets(
    List<DetectedStar> targets,
    SolveResult? solve,
  ) {
    final namedStars = solve?.namedStars ?? const <SkyObject>[];
    final named = <_NumberedTarget>[];
    final unnamed = <_NumberedTarget>[];
    final streaks = <_NumberedTarget>[];
    for (var index = 0; index < targets.length; index++) {
      final star = targets[index];
      final target = _NumberedTarget(index, star);
      if (star.isElongated) {
        streaks.add(target);
      } else if (_nearestNamed(star, namedStars) != null) {
        named.add(target);
      } else {
        unnamed.add(target);
      }
    }
    return _TargetGroups(named, unnamed, streaks);
  }

  /// 一组亮点：可折叠的表头、整组的 −/+、展开后的行。
  Widget _targetGroup({
    required String id,
    required String title,
    required IconData icon,
    required String emptyHint,
    required List<DetectedStar> targets,
    required List<_NumberedTarget> items,
    required Set<int> hidden,
    required SolveResult? solve,
  }) {
    final collapsed = _collapsedGroups.contains(id);
    // 一组里只要还剩一颗画着，这组就算「看得见」——用户可以按颗收起来，
    // 收到只剩一颗时组标题不该再显示成整组都隐了。
    final visible = items.any((item) => !hidden.contains(item.number));
    final rejected = items.where((item) => item.star.isRejected).length;
    // 隐去和显示互斥，所以两个按钮里永远只有一个能按。另一个变灰不是坏了，
    // 是「现在就在这个状态上」。
    final canHide = visible && items.isNotEmpty;
    final canShow = items.any((item) => hidden.contains(item.number));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() {
            if (!_collapsedGroups.remove(id)) _collapsedGroups.add(id);
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(
              children: [
                Icon(
                  collapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                  color: const Color(0xFF8192A8),
                ),
                Icon(icon, size: 15, color: _groupColor(id)),
                // 这一组现在在图上看不见，得有个记号。否则用户回到图上找
                // 那几条飞线，会以为是自己看漏了。
                if (!visible) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.visibility_off_outlined,
                    size: 13,
                    color: Color(0xFF8192A8),
                  ),
                ],
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$title  ${items.length}',
                    // 表头上挤着图标和四个按钮，窄一点的手机上留给标题的
                    // 宽度很有限。截断比折成两行好：折行会让三个组标题高低
                    // 不一，看起来像是出了错。
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (rejected > 0)
                  Text(
                    t('已判非天体 {0}', [rejected]),
                    style: const TextStyle(
                      color: Color(0xFF8192A8),
                      fontSize: 11,
                    ),
                  ),
                _batchButton(
                  Icons.remove_circle_outline,
                  t('把这组的圆圈从图上隐去'),
                  canHide,
                  () => _setGroupCircles(id, false, items),
                ),
                _batchButton(
                  Icons.add_circle_outline,
                  t('把这组的圆圈显示回来'),
                  canShow,
                  () => _setGroupCircles(id, true, items),
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(38, 2, 12, 10),
              child: Text(
                emptyHint,
                style: const TextStyle(color: Color(0xFF8192A8), fontSize: 12),
              ),
            )
          else
            for (final item in items)
              _highlightRow(targets, item.number, solve, hidden),
        const Divider(height: 1),
      ],
    );
  }

  /// 图上不该画的编号。
  ///
  /// 分组是显示上的事，而 painter 只认编号，所以这里把「哪几组隐着」和
  /// 「哪几颗单独动过」一起翻译成「哪几个下标不画」。翻译走的是同一套
  /// [_categoriseTargets]——要是另算一遍，就可能隐去一组、图上少画的却是
  /// 另一组。
  ///
  /// 逐项设定压在最上面：分组给的是默认，用户点过的那一颗由他说了算。
  Set<int> _hiddenIndices(SkyAnalysis analysis, SolveResult? solve) {
    final hidden = <int>{
      if (_hiddenGroups.isNotEmpty)
        for (final id in _hiddenGroups)
          for (final item
              in _categoriseTargets(analysis.numberedTargets, solve).of(id))
            item.number,
    };
    return hidden
      ..addAll(_hiddenTargets)
      ..removeAll(_restoredTargets);
  }

  /// 图上要画的那几个「亮星」名字。
  ///
  /// 名字和圆圈是一回事：逐颗收起一颗星时，它的名字一起收。图上留一个名字
  /// 悬在空处、底下却没有点，比不画更让人费解——用户按那颗的减号，要的正
  /// 是「这一处干净了」。整组收起时同样一个名字都不传，这一点没变。
  ///
  /// 配对用的是和 [_categoriseTargets] 同一套近邻判据，所以「这一颗算不算
  /// 有名字」和「它的名字画不画」永远是同一个答案。
  List<SkyObject> _visibleNamedStars(SkyAnalysis analysis, SolveResult? solve) {
    final named = solve?.namedStars ?? const <SkyObject>[];
    if (named.isEmpty) return const [];
    final hidden = _hiddenIndices(analysis, solve);
    if (hidden.isEmpty) return named;
    final targets = analysis.numberedTargets;
    return [
      for (final object in named)
        if (!_namedIsHidden(object, targets, hidden)) object,
    ];
  }

  /// 这个带名字的天体，对应的那颗编号星点现在收起来了吗。
  ///
  /// 反查的是「离它最近的那颗非拉长目标」，和正着分组的判据一样；找不到
  /// 对应编号项（比如排在编号上限之外）时返回 false——没有开关管着它，
  /// 就不该跟着谁一起消失。
  static bool _namedIsHidden(
    SkyObject object,
    List<DetectedStar> targets,
    Set<int> hidden,
  ) {
    var nearest = -1;
    var distance = 10.0;
    for (var index = 0; index < targets.length; index++) {
      final target = targets[index];
      if (target.isElongated) continue;
      final current = math.sqrt(
        math.pow(target.x - object.x, 2) + math.pow(target.y - object.y, 2),
      );
      if (current < distance) {
        distance = current;
        nearest = index;
      }
    }
    return nearest >= 0 && hidden.contains(nearest);
  }

  /// 整组隐去 / 整组显示。
  ///
  /// 顺带清掉这一组的逐项设定：按下去之后组里每一项都该是同一个状态。
  void _setGroupCircles(String id, bool visible, List<_NumberedTarget> items) =>
      setState(() {
        if (visible) {
          _hiddenGroups.remove(id);
        } else {
          _hiddenGroups.add(id);
        }
        for (final item in items) {
          _hiddenTargets.remove(item.number);
          _restoredTargets.remove(item.number);
        }
      });

  /// 一次管全部星点、深空天体和系内天体的标记。
  void _setAllCircles(
    bool hidden,
    List<SkyObject> deepSkyObjects,
    List<MovingBodySuspicion> movingBodies,
  ) =>
      setState(() {
        _hiddenGroups
          ..clear()
          ..addAll(hidden ? groupIds : const <String>[]);
        // 留着逐项设定的话，「全部显示回来」就会漏掉用户之前单独收起来的那
        // 几颗——按钮上是「所有」，那就得真的是所有。
        _hiddenTargets.clear();
        _restoredTargets.clear();
        if (hidden) {
          _hiddenDeepSkyObjects.addAll(
            deepSkyObjects.map((object) => object.name),
          );
          _hiddenMovingBodies.addAll(
            movingBodies.map((body) => body.name),
          );
        } else {
          _hiddenDeepSkyObjects.clear();
          _hiddenMovingBodies.clear();
        }
      });

  /// 单独隐去 / 单独显示一颗。
  ///
  /// 隐去记进 [_hiddenTargets]；显示记进 [_restoredTargets]——它可能正被所属
  /// 分组压着，得有一个比分组更有力的记号才捞得出来。
  void _setTargetCircle(int number, bool visible) => setState(() {
        if (visible) {
          _hiddenTargets.remove(number);
          _restoredTargets.add(number);
        } else {
          _restoredTargets.remove(number);
          _hiddenTargets.add(number);
        }
      });

  Widget _batchButton(
    IconData icon,
    String tooltip,
    bool enabled,
    VoidCallback onTap, {
    bool dense = false,
  }) =>
      IconButton(
        visualDensity: VisualDensity.compact,
        // 行里的两个按钮要和星等文字、对错号挤在一行上，默认那圈内边距太宽。
        padding: dense ? EdgeInsets.zero : null,
        constraints:
            dense ? const BoxConstraints(minWidth: 30, minHeight: 30) : null,
        // 图标小、又只出现一次，没有 tooltip 的话没人知道那个圆圈里的横杠
        // 是「把这一组圈隐去」，也没人分得清它和旁边的加号谁管什么。
        tooltip: tooltip,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: dense ? 18 : 19),
        // 两个图标长得几乎一样，只靠默认那点灰度差别看不出哪个是按得动的：
        // 亮着的那个才是当前能按的。
        color: const Color(0xFFC3D2E4),
        disabledColor: const Color(0xFF44536A),
      );

  Color _confidenceColor(double confidence) => confidence >= 0.7
      ? kMint
      : confidence >= 0.35
          ? const Color(0xFFFFDE77)
          : const Color(0xFFFF7B8C);

  Widget _highlightRow(
    List<DetectedStar> targets,
    int index,
    SolveResult? solve,
    Set<int> hidden,
  ) {
    final star = targets[index];
    final isHidden = hidden.contains(index);
    // 图上没画圈的那些行要一眼看得出来，不然用户翻回图上去找，会以为是自己
    // 看漏了。用的是和「已判非天体」同一套变淡处理：两件事都不是错误，只是
    // 「这一行现在不在图上」。
    final muted = star.isRejected || isHidden;
    final name = _nearestNamed(star, solve?.namedStars ?? const []);
    final confidenceColor = _confidenceColor(star.confidence);
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
      onTap: () => setState(() {
        _selectedTarget = index;
        _selectedDeepSkyName = null;
        // 点一行就是要看那一颗。它现在要是隐着的，顺手把这一颗的圆圈显示
        // 回来——否则「点一行就能在图上定位到那一颗」这个承诺在隐去之后
        // 就是空的。只动这一颗：分组是批量设定，而用户点的是单独一颗。
        _hiddenTargets.remove(index);
        _restoredTargets.add(index);
      }),
      leading: CircleAvatar(
        radius: 15,
        backgroundColor: confidenceColor.withValues(alpha: muted ? 0.08 : 0.16),
        child: Text(
          '${index + 1}',
          style: TextStyle(
            color: confidenceColor,
            fontSize: 12,
          ),
        ),
      ),
      title: Text(
        name?.name ?? (star.isElongated ? t('拉长点源') : t('未匹配点源')),
        style: TextStyle(
          color: muted
              ? const Color(0xFF8192A8)
              : name != null
                  ? const Color(0xFFFFDE77)
                  : null,
          fontWeight: name != null ? FontWeight.w700 : null,
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
          // 对错号只长在可疑飞线上。亮星和亮点是算出来的结论，没有「算不算
          // 数」这回事——给它们一对对错号，等于邀请用户去改一份他从没打算改
          // 的数据，而这正是这一页最不该发生的事。
          if (star.isElongated) ...[
            _judgeButton(
              Icons.check_circle_outline,
              t('判为天体，计入报告'),
              !star.isRejected,
              kMint,
              () => _setRejection(star, false),
            ),
            _judgeButton(
              Icons.cancel_outlined,
              t('判为非天体，不计入报告'),
              star.isRejected,
              const Color(0xFFFF7B8C),
              () => _setRejection(star, true),
            ),
          ],
          // 和组标题上那两个是同一对意思，只是只管这一颗。
          _batchButton(
            Icons.remove_circle_outline,
            t('把这一颗的圆圈从图上隐去'),
            !isHidden,
            () => _setTargetCircle(index, false),
            dense: true,
          ),
          _batchButton(
            Icons.add_circle_outline,
            t('把这一颗的圆圈显示回来'),
            isHidden,
            () => _setTargetCircle(index, true),
            dense: true,
          ),
        ],
      ),
    );
  }

  /// 可疑飞线那一对「对 / 错」。
  ///
  /// 两个都摆出来、点亮其中一个，比一个按来按去的开关好读：用户要看的是
  /// 「我判过没有、判的是哪一边」，而不是「按下去会变成什么」。
  Widget _judgeButton(
    IconData icon,
    String tooltip,
    bool active,
    Color activeColor,
    VoidCallback onTap,
  ) =>
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onTap,
        icon: Icon(icon, size: 19),
        color: active ? activeColor : const Color(0xFF5A6B84),
      );

  String _highlightSubtitle(DetectedStar star, SkyObject? name) {
    final position =
        t('像素 ({0}, {1})', [star.x.toStringAsFixed(0), star.y.toStringAsFixed(0)]);
    if (star.isElongated) {
      return t('长宽比 {0}:1 · 可能是卫星、飞机或抖动 · {1}', [star.axisRatio.toStringAsFixed(1), position]);
    }
    final category =
        name?.category.isNotEmpty == true ? '${name!.category} · ' : '';
    return '$category$position';
  }

  /// 给一条可疑飞线判「是 / 不是天体」。
  ///
  /// 判为不是的，从测光、星表匹配、报告和交给模型的摘要里排除，但仍在图上和
  /// 列表里（颜色变淡），随时能改回来。这是这一页唯一会动数据的开关，所以它
  /// 只长在可疑飞线上。
  void _setRejection(DetectedStar target, bool rejected) {
    final analysis = _analysis;
    if (analysis == null || target.isRejected == rejected) return;
    setState(() {
      _analysis = analysis.withRejection(target, rejected);
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
        title: Text(
          t('亮星与测光'),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          zeroPoint == null
              ? t('尚未标定星等零点，只能比较图内相对亮度')
              : t('Gaia G 近似标定 · 零点 {0}', [zeroPoint.toStringAsFixed(2)]),
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MetricChip(t('可测光点源'), '${stars.length}'),
              MetricChip(t('点源 FWHM'), '${analysis.fwhm.toStringAsFixed(1)} px'),
              if (solve?.magnitudeScatter != null)
                MetricChip(
                  t('标定散布'),
                  t('±{0} 等', [solve!.magnitudeScatter!.toStringAsFixed(2)]),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (stars.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(t('没有可用于恒星测光的紧凑点源。')),
            )
          else
            ...stars.take(8).map((star) {
              final name = _nearestNamed(star, solve?.namedStars ?? const []);
              final error = star.magnitudeError;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(name?.name ?? t('未匹配点源')),
                subtitle: Text(
                  t('孔径通量 {0}{1}', [star.flux.toStringAsFixed(0), error == null ? '' : t(' · 星等误差 ±{0}', [error.toStringAsFixed(2)])]),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  t('Gaia G 是近似标定，不含相机光谱响应、白平衡、饱和与后期处理带来的系统误差，只适合与同一台设备的其他照片比较。'),
                  style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
                ),
              ),
              _HelpButton(
                title: t('测光误差'),
                message:
                    t('星等误差只算了光子噪声和天空背景估计的误差，不包含相机光谱响应、白平衡、饱和、镜头暗角和图像处理造成的系统误差。结果仅供参考。'),
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

  /// 全天星图卡：把中心坐标放到一张全天图上。
  ///
  /// 「RA 05h 35m / Dec −05°」这种写法，熟的人一看就知道是猎户座大星云，
  /// 不熟的人完全没概念。全天图上的一个十字能把这件事一步讲完，而且它是
  /// 纯几何，本机解算和在线解算都能画。
  Widget _finderCard(SolveResult solve) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SectionTitle(t('这片天在哪儿'), Icons.travel_explore),
                  _HelpButton(
                    title: t('全天图怎么看'),
                    message: t('十字是这张照片的中心，黄圈示意视场大小。横轴赤经向左增大，绿线是天赤道。'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              AllSkyFinder(
                centerRa: solve.centerRa,
                centerDec: solve.centerDec,
                fieldOfViewDegrees: solve.fieldOfViewDegrees,
              ),
              const SizedBox(height: 10),
              Text(
                '${formatRa(solve.centerRa)} · ${formatDec(solve.centerDec)}'
                '${solve.fieldOfViewDegrees > 0 ? t('   ·   视场对角 {0}', [formatFieldOfView(solve.fieldOfViewDegrees)]) : ''}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );

  Widget _solveCard(SolveResult? solve) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SectionTitle(t('天区识别'), Icons.public_rounded),
                  _HelpButton(
                    title: t('天区识别与隐私'),
                    message:
                        t('优先在手机本机解算，不上传任何图片。本机解算不出来时，如果已在设置里授权，才会把分析预览图上传到 Astrometry.net。不解算也能查看本机星点与画质分析。'),
                  ),
                ],
              ),
              if (_isMoonReport)
                // 不解释的话，用户看到的就是「没有解开这片天区」——而真相是
                // 这一次压根没去解。同一块屏幕上两种截然不同的意思，必须说清。
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    // 分两句是因为「这一次」在两条路上指的不同的东西：刚跑完
                    // 的那次是用户自己选的；从仓库里翻出来的那条，用户早忘了
                    // 当时点过什么，说「这是月面链路」才对他有用。
                    _moonOnly
                        ? t('这次只报告了月亮，没有解算天区。')
                        : t('这张照片走的是月面链路，没有解算天区。'),
                  ),
                )
              else if (solve == null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(t('解析失败。')),
                )
              else ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    MetricChip(
                      t('解算方式'),
                      solve.source == SolveSource.local ? t('本机离线') : 'Astrometry.net',
                    ),
                    if (solve.constellations.isNotEmpty)
                      MetricChip(t('星座'), solve.constellations.first),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  t('中心 RA {0}  ·  Dec {1}°', [formatRa(solve.centerRa), solve.centerDec.toStringAsFixed(4)]),
                ),
                const SizedBox(height: 6),
                Text(
                  t('像素比例 {0}″/px   ·   视场对角 {1}°', [solve.arcsecPerPixel.toStringAsFixed(2), solve.fieldOfViewDegrees.toStringAsFixed(2)]),
                ),
                const SizedBox(height: 6),
                Text(
                  tn(
                    '匹配 {0} 颗星{1}',
                    solve.matchedCount == 0 ? solve.matchedStars.length : solve.matchedCount,
                    [
                      solve.matchedCount == 0 ? solve.matchedStars.length : solve.matchedCount,
                      solve.rotationDegrees == 0 ? '' : t('   ·   画面旋转 {0}°', [solve.rotationDegrees.toStringAsFixed(1)]),
                    ],
                  ),
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
  /// 用户拍完一张星空，最想知道的是「我拍到了什么」。所以这张卡的第一行
  /// 就是答案：星座，加上画面里认得出的天体——亮星给中文星官名，星团星云
  /// 给「编号 ＋ 中文昵称」。
  ///
  /// 那一段走 Markdown（`buildHeadlineMarkdown`），目的只有一个：让天体名
  /// 有颜色。它是这一屏上唯一需要被「一眼扫到」的信息，而一色到底的文字里
  /// 一行有六个名字，扫起来跟没有一样。
  ///
  /// 下面那排数字是「拍得怎么样」，再下面是各条细节卡。曾经这里还有一段
  /// 总结和一份拍摄建议，都删了：总结和上面那段说的是同一件事，建议则总是
  /// 那几条通用话——占着最好的位置，说的却不是用户此刻最想知道的。
  /// 取主题里那张卡片的形状，只换描边。
  ///
  /// 圆角不在这里写死：主题改了圆角，这里跟着改，两边不会各说各话。
  ShapeBorder _outlinedCard(BorderSide side) {
    final base = Theme.of(context).cardTheme.shape;
    if (base is OutlinedBorder) return base.copyWith(side: side);
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: side,
    );
  }

  /// 拍摄与解算参数表。
  ///
  /// 这一块参考了天文通的结果页：用户上传一张照片之后，最想先确认的是
  /// 「相机到底记下了什么」——型号、光圈、快门、ISO、焦距，以及解算出来的
  /// 赤经赤纬、视场、比例尺。这些值本来散在各张卡里，收进一张两列表格
  /// 才扫得动。
  ///
  /// 读不到的项写「未读到」，不猜一个数；解算那几行只在真解出来时出现。
  Widget _captureParametersCard(SkyAnalysis analysis, SolveResult? solve) {
    final moment = _moment;
    if (moment == null && solve == null) return const SizedBox.shrink();
    final rows = <Widget>[];
    void add(String label, String value) {
      rows.add(_parameterRow(label, value));
    }

    void section() {
      if (rows.isNotEmpty) rows.add(const Divider(height: 20));
    }

    add(t('相机型号'), moment?.device ?? t('未读到'));
    add(t('光圈'), moment?.fNumber ?? t('未读到'));
    add(t('快门'), moment?.exposure ?? t('未读到'));
    add('ISO', moment?.iso ?? t('未读到'));
    add(t('焦距'), moment?.focalLength ?? t('未读到'));
    if (moment != null) {
      section();
      add(t('拍摄时间'), _formatClock(moment.local));
    }
    if (_solvedAt != null) add(t('解算完成'), _formatClock(_solvedAt!));
    if (_solveDuration != null) {
      add(t('解算用时'), _formatSeconds(_solveDuration!));
    }

    if (solve != null) {
      section();
      final scale = solve.arcsecPerPixel;
      final widthDeg = scale > 0 ? analysis.width * scale / 3600 : 0.0;
      final heightDeg = scale > 0 ? analysis.height * scale / 3600 : 0.0;
      final fov = solve.fieldOfViewDegrees;
      add(t('赤经 (RA)'), '${solve.centerRa.toStringAsFixed(4)}°');
      add(t('赤纬 (Dec)'), '${solve.centerDec.toStringAsFixed(4)}°');
      add(t('视场半径'), fov > 0 ? '${(fov / 2).toStringAsFixed(2)}°' : t('未知'));
      add(
        t('视场尺寸'),
        widthDeg > 0 && heightDeg > 0
            ? '${widthDeg.toStringAsFixed(2)} × ${heightDeg.toStringAsFixed(2)}°'
            : t('未知'),
      );
      add(t('像素比例尺'),
          scale > 0 ? '${scale.toStringAsFixed(3)}″/px' : t('未知'));
      add(t('旋转角度'), '${solve.rotationDegrees.toStringAsFixed(2)}°');
      if (widthDeg > 0) {
        // 等效焦距按 36mm 画幅的宽边折算。不知道传感器尺寸时，这是唯一能
        // 从解算结果本身算出来的写法，表头里写明「FF」。
        final focal =
            36 / (2 * math.tan(widthDeg * math.pi / 360));
        add(t('解算焦距'), '≈${focal.toStringAsFixed(1)}mm FF');
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SectionTitle(t('拍摄参数'), Icons.camera_alt_outlined),
              ],
            ),
            const SizedBox(height: 6),
            ...rows,
            if (solve != null) ...[
              const SizedBox(height: 10),
              const Divider(height: 20),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _openLegacySurvey(solve),
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: Text(t('在 Legacy Survey 中查看这片天区')),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                t('打开巡天影像，并叠加这张照片的取景框。'),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Color(0xFF8192A8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _parameterRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontSize: 13, color: Color(0xFF8192A8)),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );

  static String _formatClock(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  static String _formatSeconds(Duration duration) {
    final seconds = duration.inMilliseconds / 1000;
    return seconds >= 60
        ? '${(seconds / 60).toStringAsFixed(1)} min'
        : '${seconds.toStringAsFixed(1)} s';
  }

  Future<void> _openLegacySurvey(SolveResult solve) async {
    // Legacy Survey 没有覆盖全天。M31 这类天区在 DR10 里就是一片黑，直接
    // 打开只会看到「奇怪的背景」。先取一张 128 像素小图看有没有真的像素，
    // 没有就退到 SDSS，再没有就退到全天覆盖的 unWISE 红外。
    var layer = 'ls-dr10';
    var fallbackNote = false;
    for (final candidate in const ['ls-dr10', 'sdss', 'unwise-neo7']) {
      if (await _legacyLayerHasPixels(solve.centerRa, solve.centerDec, candidate)) {
        layer = candidate;
        fallbackNote = candidate != 'ls-dr10';
        break;
      }
    }
    final url = legacySurveyUrl(
      ra: solve.centerRa,
      dec: solve.centerDec,
      fieldOfViewDegrees: solve.fieldOfViewDegrees,
      // 有 WCS 才能在巡天图上画出这张照片的取景框，而不只是钉一个中心点。
      wcs: solve.wcs,
      layer: layer,
      minZoom: 5,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (fallbackNote) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            layer == 'sdss'
                ? t('Legacy Survey 在这片天区没有光学覆盖，已改用 SDSS。')
                : t('Legacy Survey / SDSS 在这片天区没有覆盖，已改用全天覆盖的 unWISE 红外图。'),
          ),
        ),
      );
    }
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      messenger.showSnackBar(
        SnackBar(content: Text(t('未能打开浏览器。链接：{0}', [url]))),
      );
    }
  }

  /// 用 128 像素 cutout 判断某个巡天图层在天区里到底有没有像素。
  ///
  /// Legacy Survey 的 viewer 对没有覆盖的天区仍然返回一张纯黑 JPEG，所以不能
  /// 只看 HTTP 200；必须解出图来量一下最亮值。
  Future<bool> _legacyLayerHasPixels(
    double ra,
    double dec,
    String layer,
  ) async {
    try {
      final uri = Uri.parse(
        'https://www.legacysurvey.org/viewer/jpeg-cutout'
        '?ra=${ra.toStringAsFixed(5)}&dec=${dec.toStringAsFixed(5)}'
        '&layer=$layer&size=128',
      );
      final response =
          await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return false;
      final image = imglib.decodeImage(response.bodyBytes);
      if (image == null) return false;
      var maxLuma = 0.0;
      for (var y = 0; y < image.height; y += 4) {
        for (var x = 0; x < image.width; x += 4) {
          final pixel = image.getPixel(x, y);
          final luma =
              0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b;
          if (luma > maxLuma) maxLuma = luma;
        }
      }
      return maxLuma > 12;
    } on Exception {
      return false;
    }
  }

  Widget _observationCard(SkyAnalysis analysis, SolveResult? solve) {
    final moon = moonFactsOf(analysis, _instantOf(_moment));
    final record = buildObservationRecord(analysis, solve, moon: moon);
    // 在线解算的那一次，这张卡换琥珀色边框并在最前面说清照片去过哪儿。
    //
    // 颜色不是随手挑的：进度条上「琥珀＝照片已经交给在线解算」是同一套语义，
    // 用户在这里认出的是同一个信号。一份天区识别结果从哪来，决定了它可信到什么
    // 程度、以及照片到底出没出过这台设备——这是读这份报告之前就该知道的事，
    // 所以它排在天体名单前面。
    final online = solve?.source == SolveSource.online;
    return Card(
      shape: online
          ? _outlinedCard(const BorderSide(color: kOnlineAmber, width: 1.6))
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionTitle(t('观星记录'), Icons.nights_stay_rounded),
                _HelpButton(
                  title: t('观星记录怎么来的'),
                  message:
                      t('名字、编号、星座、视场这些是星表和解算给的，是事实；亮面占比、点源大小、星等这些是从这张照片本身量出来的，会随曝光、ISO、光圈和后期处理变化。换个晚上、换台机器就不一样，适合和「你自己过去拍的」比，不适合和别人的照片比。'),
                ),
              ],
            ),
            if (online) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.cloud_upload_outlined,
                      size: 15, color: kOnlineAmber),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t('使用 Astrometry.net 在线解算：这张照片的分析预览已上传至 nova.astrometry.net，中心坐标与天体名来自该服务。本机解算没有成功，所以这一次照片出过设备。'),
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: kOnlineAmber,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            MarkdownText(
              buildHeadlineMarkdown(analysis, solve, moon: moon),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                MetricChip(t('画质'), record.quality),
                MetricChip(t('天空背景'), record.skyBrightness),
                // 月面照片不走星点链路，点源 FWHM、星表匹配这些数在这里没有
                // 意义——报出来只会让用户以为测了，其实是零。
                if (record.moon == null)
                  MetricChip(t('点源 FWHM'),
                      '${analysis.fwhm.toStringAsFixed(1)} px'),
                if (solve != null) ...[
                  MetricChip(t('星表匹配'), t('{0} 颗', [record.matchedStars])),
                  MetricChip(t('视场对角'), record.fieldOfView),
                  MetricChip(t('像素比例'), record.scale),
                ],
              ],
            ),
            if (record.brightest != null) ...[
              const SizedBox(height: 10),
              Text(t('画面最亮：{0}', [record.brightest]),
                  style: const TextStyle(fontSize: 13)),
            ],
            if (record.movingBodies.isNotEmpty) ...[
              const SizedBox(height: 12),
              _movingBodiesNotice(record.movingBodies),
            ],
            if (record.moon != null) ...[
              const SizedBox(height: 12),
              _moonBlock(record.moon!),
            ],
          ],
        ),
      ),
    );
  }

  /// 月面那一小块：两个数并排摆出来。
  ///
  /// 「图上量的」和「按时刻算的」是两个独立的数，放在一起才说明问题——它们对得
  /// 上，用户才知道这个亮面占比可信；对不上，界面必须说出来，而不是挑一个报。
  /// 相名只挂在后一个数上：单张照片里相机有没有镜像或翻转是看不出来的，光看图
  /// 说不出是在盈还是在亏。
  Widget _moonBlock(MoonFacts moon) {
    final phaseLabel = moon.phaseName == null
        ? t('填上拍摄时间即可算出相名')
        : '${moon.waxing == true ? t('盈') : t('亏')} · ${moon.phaseName}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: kMint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kMint.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('月面'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              _moonMetric(t('亮面占比（图上量的）'), moon.measuredPercent),
              const SizedBox(width: 12),
              _moonMetric(
                t('亮面占比（按时刻算的）'),
                moon.ephemerisPercent ?? '—',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(phaseLabel, style: const TextStyle(fontSize: 13)),
          if (moon.caution != null) ...[
            const SizedBox(height: 8),
            Text(
              moon.caution!,
              style: const TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }

  Widget _moonMetric(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11.5, color: Color(0xFF8192A8))),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  /// 「疑似运动天体」那一小块。
  ///
  /// 用橙色而不是下面建议清单的薄荷色：这一节说的是**疑似**——是两个条件凑出来
  /// 的推断（星表这一带没星 ＋ 星历位置上有亮点），不是量出来的事实。颜色得跟着
  /// 这份不确定走，不然用户会把它当成和「星表匹配 18 颗」同一档次的东西。
  ///
  /// 那句不确定度说明是这块的一部分，不是可选的点缀：行星识别一旦给错就是错的，
  /// 所以结论和「它凭什么可能不成立」必须同时出现在屏幕上。
  /// 保存过的记录里那一块「疑似运动天体」。
  ///
  /// 两段的说法必须分开：认出来的写「差多少角秒」，没认出来的**不能写差数**
  /// ——那个差数根本不存在，写了就是把「按星历它在这儿」说成「我看见它了」。
  /// 所以名字后面跟的是类别，不是距离：类别是事实，距离是结论。
  Widget _movingBodiesNotice(List<MovingBodyEntry> bodies) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.orangeAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.orangeAccent.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.public_rounded, size: 15, color: Colors.orangeAccent),
                const SizedBox(width: 6),
                Text(
                  t('疑似运动天体'),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final body in bodies)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  t('{0}（{1}）{2}', [body.name, t(body.kind.label), body.describeWithoutName]),
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            const SizedBox(height: 6),
            // movingBodyCaution 现在是 getter（文案要跟着语言走，不能是编译期常量）
            Text(
              movingBodyCaution,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Color(0xFF8192A8),
              ),
            ),
            if (bodies.any((body) => !body.detected)) ...[
              const SizedBox(height: 5),
              Text(
                unidentifiedBodyCaution,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: Color(0xFF8192A8),
                ),
              ),
            ],          ],
        ),
      );

  /// 视场内的恒星表：爱好者熟悉的「一张星表」的样子。
  ///
  /// 用 DataTable 而不是 ListTile：列表适合「挑一条点进去」，表格适合
  /// 「横着比较」。这里要做的事情是后者——哪颗最亮、哪颗离中心最近、
  /// 哪几颗是同一星座的，都需要一眼扫过整列。
  ///
  /// 和「亮星与测光」一样默认折叠：星表是深究时才看的，第一眼要的是
  /// 「拍到了什么」，不是二十行赤经赤纬。
  Widget _starTableCard(SkyAnalysis analysis, SolveResult solve) {
    final rows = buildStarTable(analysis, solve);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: false,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.table_chart_outlined, color: kMint),
        title: Text(
          t('视场内的恒星'),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          t('{0} 颗 · 点开查看星表', [rows.length]),
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
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
              columns: [
                DataColumn(label: Text(t('星名'))),
                DataColumn(label: Text(t('类型'))),
                DataColumn(label: Text(t('星等'))),
                DataColumn(label: Text(t('赤经'))),
                DataColumn(label: Text(t('赤纬'))),
                DataColumn(label: Text(t('图上置信度'))),
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
                                  : _confidenceColor(row.confidence!),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              row.confidence == null
                                  ? t('未检出')
                                  : '${(row.confidence! * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                color: row.confidence == null
                                    ? const Color(0xFF8192A8)
                                    : _confidenceColor(row.confidence!),
                              ),
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
                t('共 {0} 颗，此处显示最亮的 20 颗。', [rows.length]),
                style: const TextStyle(color: Color(0xFF8192A8), fontSize: 11),
              ),
            ),
          if (solve.catalogWarning != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t('名称目录暂不可用：{0}', [solve.catalogWarning]),
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
              ),
            ),
        ],
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionTitle(t('星等分布'), Icons.bar_chart_rounded),
                _HelpButton(
                  title: t('星等分布怎么看'),
                  message:
                      t('横轴是星等，往右越暗；纵轴是落在这个亮度区间的星数。右边最后几根柱子就是你这次的探测极限——再暗一等的星就淹在背景噪声里了。如果分布在最暗那端突然掉到零，说明是设备极限；如果整条分布都在很亮的几档里堆着，多半是曝光不足或天空太亮。'),
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

  /// 画面中的深空天体。
  ///
  /// 只写「M31」是没有用的——用户想知道的是「这是什么、拍得够不够大」。
  /// 所以每条都带上类型、角尺寸和它占像场的比例：同一个星系，占画面 5% 和
  /// 占 80% 是两张完全不同的照片，后者才是「这张是它的特写」。
  Widget _deepSkyCard(SolveResult solve) {
    final entries = buildDeepSkyEntries(solve);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionTitle(t('画面中的深空天体'), Icons.scatter_plot),
                _HelpButton(
                  title: t('深空天体是怎么认出来的'),
                  message:
                      t('这些天体不在本机的亮星表里，是解算出天球坐标之后按目录位置标注的，所以位置可靠、亮度不可靠——延展的星云和星系没有「一个点」的星等。\n\n占像场的比例是天体长轴与像场对角线的比：接近或超过 100% 说明画面只是它的一部分，这张属于特写；只有百分之几说明目标在这套器材下还偏小，可以再上更长的焦距。'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...entries.map(
              (entry) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(deepSkyCaption(entry.name, entry.category)),
                subtitle: Text(
                  [
                    entry.sizeLabel,
                    if (entry.coverageLabel.isNotEmpty) entry.coverageLabel,
                  ].join(t('　·　')),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Icon(
                  entry.isLarge
                      ? Icons.center_focus_strong
                      : Icons.center_focus_weak,
                  color: const Color(0xFFFF7B8C),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agentCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(t('Agent 解读'), Icons.chat_bubble_outline_rounded),
              const SizedBox(height: 10),
              TextField(
                controller: _questionController,
                decoration: InputDecoration(
                  hintText: t('例如：哪些测量结果可靠？'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: _explaining ? null : _explain,
                  child: Text(_explaining ? t('Agent 正在处理…') : t('发送给 Agent')),
                ),
              ),
              if (_agentActivity.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  t('本轮工具调用：{0}', [_agentActivity.join(t('、'))]),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFA6B5C8),
                  ),
                ),
              ],
              if (_explanation != null) ...[
                const SizedBox(height: 12),
                // 模型返回的是 Markdown，交给渲染器排版。之前直接用
                // SelectableText 显示，屏幕上就是一串裸露的 `##` 和 `**`。
                MarkdownText(_explanation!),
              ],
            ],
          ),
        ),
      );
}

/// 一个检出星点，连同它在图上那个编号。
///
/// 编号是 `numberedTargets` 的下标，不是组内序号——分组只改变显示顺序，不能
/// 改变编号，否则图和列表就说不到一块去了。
/// 「试一张演示星图」的底部卡片。
///
/// 内容列成可滚的 [ListView] 而不是固定高度的一摞 ListTile：条目数一多
/// （这张表现在有五张，以后还会加），一摞固定高度的行就会超出底部卡片的
/// 可用高度，Flutter 在下面画一条黄黑斜纹的溢出条。那不是「内容太多」的
/// 提示，而是一块坏掉的界面。
///
/// 抽成独立的 widget 还有一个用处：它能被单独塞进一个矮框里测——溢出这种
/// 事只有在高度真的不够时才复现，靠肉眼看截图是靠不住的。
class DemoPickerSheet extends StatelessWidget {
  const DemoPickerSheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: ListView(
          // 内容少的时候卡片跟着内容收，不要撑满整屏。
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                t('试一张演示星图'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                t('{0} 张真实拍摄的照片', [demoImages.length]),
                style: const TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
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
      );
}

/// 全屏看图：一块可以随便捏合的图，加两个出口。
///
/// 自己一套 [TransformationController]，和半屏那块互不影响——从全屏退出来时
/// 半屏还停在用户离开时的位置，不用重新找。
///
/// 两个按钮：左上角退出全屏（「恢复」到半屏），右上角导出这张带标注的图。
/// 退出按钮放在左上角而不是右上角，是因为右上角要留给导出——用户进全屏多半
/// 就是为了看清一点东西、然后把它存下来，导出是这一屏的**目的**，退出去只是
/// 离开；把按钮按「去哪里」和「干什么」分开摆，比两个挤在一起好认。
class FullscreenImagePage extends StatefulWidget {
  const FullscreenImagePage({
    super.key,
    required this.bytes,
    required this.painter,
    required this.onExport,
  });

  final Uint8List bytes;

  /// 和半屏共用同一个 painter 构造：图上标出来的东西必须**一模一样**，
  /// 否则用户在全屏里看到的是另一张图，导出的又是第三张。
  final DetectedStarsPainter painter;

  final Future<void> Function() onExport;

  @override
  State<FullscreenImagePage> createState() => _FullscreenImagePageState();
}

class _FullscreenImagePageState extends State<FullscreenImagePage> {
  final _viewer = TransformationController();
  bool _exporting = false;

  /// 橡皮擦是否打开。打开后点图上的圆圈或文字就把那一项临时藏起来。
  bool _eraser = false;

  /// 这一次全屏查看里擦掉的标注。只活在当前页，退出即恢复。
  final _erased = <String>{};

  /// 上一次绘制留下的可点选区域（画布坐标）。
  List<AnnotationHitRegion> _regions = const [];

  @override
  void dispose() {
    _viewer.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await widget.onExport();
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _eraseAt(TapUpDetails details) {
    // 后画的盖在前面，命中时也从后往前找：两段标注重叠时，擦掉用户看到的
    // 最上面那一段。
    for (final region in _regions.reversed) {
      if (!region.bounds.contains(details.localPosition)) continue;
      setState(() => _erased.add(region.id));
      return;
    }
  }

  void _resetEraser() => setState(_erased.clear);

  @override
  Widget build(BuildContext context) {
    // 把当前擦除状态交给 painter。`erased` 每次都是新集合，但内容没变时
    // shouldRepaint 会按元素比较，不会白重画。
    final painter = widget.painter.copyWith(
      erased: Set.unmodifiable(_erased),
      onRegions: (regions) => _regions = regions,
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            transformationController: _viewer,
            minScale: 1,
            // 全屏这块比半屏大得多，能放到 12 倍：这里要看清的是单个像素
            // 上的星点，而不是「大概在哪」。
            maxScale: 12,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _eraser ? _eraseAt : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.bytes.isEmpty)
                    const MissingImage()
                  else
                    Image.memory(
                      widget.bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const MissingImage(),
                    ),
                  CustomPaint(painter: painter),
                ],
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            child: SafeArea(child: _roundButton(
              icon: Icons.close_fullscreen,
              tooltip: t('退出全屏'),
              onTap: () => Navigator.of(context).pop(),
            )),
          ),
          Positioned(
            right: 12,
            top: 12,
            child: SafeArea(
              child: Column(
                children: [
                  _roundButton(
                    icon: _exporting ? Icons.hourglass_top : Icons.ios_share,
                    tooltip: t('导出带标注的图'),
                    onTap: _exporting ? null : _export,
                  ),
                  const SizedBox(height: 10),
                  _roundButton(
                    icon: Icons.cleaning_services_outlined,
                    tooltip: _eraser ? t('关闭橡皮擦') : t('橡皮擦'),
                    active: _eraser,
                    onTap: () => setState(() => _eraser = !_eraser),
                  ),
                  if (_erased.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _roundButton(
                      icon: Icons.restore,
                      tooltip: t('恢复已擦除的标注'),
                      onTap: _resetEraser,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_eraser)
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      t('点按圆圈或文字即可擦除；退出全屏后恢复原样。'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12.5, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool active = false,
  }) =>
      Material(
        color: active ? kMint.withValues(alpha: 0.22) : Colors.black54,
        shape: CircleBorder(
          side: active
              ? BorderSide(color: kMint.withValues(alpha: 0.8))
              : BorderSide.none,
        ),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(icon, size: 22, color: kMint),
            ),
          ),
        ),
      );
}

/// 认出月面之后等用户拍板的那一次提问。
class _MoonQuestion {
  _MoonQuestion(this.analysis);

  final SkyAnalysis analysis;

  /// true = 继续寻找其他天体，false = 直接报告月亮。
  final completer = Completer<bool>();
}

/// 一个分组的编号项：在 [SkyAnalysis.numberedTargets] 里的下标，加上它属于哪一组。
class _NumberedTarget {
  const _NumberedTarget(this.number, this.star);

  final int number;
  final DetectedStar star;
}

/// 亮点列表的三个分组。
class _TargetGroups {
  const _TargetGroups(this.named, this.unnamed, this.streaks);

  final List<_NumberedTarget> named;
  final List<_NumberedTarget> unnamed;
  final List<_NumberedTarget> streaks;

  /// 按组名取那一组。组名只在 [AnalysisScreen] 的 `groupIds` 里，
  /// painter 那边只认编号，靠这里来回翻译。
  List<_NumberedTarget> of(String id) => switch (id) {
        'named' => named,
        'unnamed' => unnamed,
        _ => streaks,
      };
}

/// 右上角最右边那个入口：API 设置。
///
/// 故意不跟前面几个一样只画一个图标：这个应用里「填 Key」是唯一一件不配就用不
/// 起来的事（AI 解读和窄视场在线解算都要它），值得占一个字的位置。胶囊形状也
/// 和 AppBar 上那排圆形图标一眼分得开——用户第一次看到就知道它不是「去某个
/// 地方看看」，而是「先去把这事办了」。
class _ApiEntry extends StatelessWidget {
  const _ApiEntry({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: t('API 设置'),
        child: Material(
          color: kMint.withValues(alpha: 0.14),
          shape: StadiumBorder(
            side: BorderSide(color: kMint.withValues(alpha: 0.55)),
          ),
          child: InkWell(
            onTap: onPressed,
            customBorder: const StadiumBorder(),
            child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune_rounded, size: 15, color: kMint),
                  SizedBox(width: 5),
                  // 'API' 是这三门语言里都不用翻译的三个字母，刻意不套 t()。
                  Text(
                    'API',
                    style: TextStyle(
                        fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: kMint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 右上角那排图标分别是什么。
///
/// 摆成一张贴着右上角的卡片，而不是在图标上画一圈高亮：引导页刚关掉时那排图标
/// 才第一次出现在用户眼前，这时该说的是「它们是干什么的」，而不是「请点这里」。
/// 卡片里每一行都用**和 AppBar 上完全相同的图标和文字**，用户回到界面能一一对上。
class _TopBarHint extends StatelessWidget {
  const _TopBarHint({required this.entries});

  final List<({IconData icon, String label, String detail, bool accent})> entries;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topRight,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 56, 12, 16),
            child: Material(
              color: kPanel,
              borderRadius: BorderRadius.circular(18),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 340),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF33455F)),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.north_east_rounded,
                              size: 15, color: kMint),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              t('右上角这几个图标'),
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      for (final entry in entries) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            entry.icon == noxIcon
                                ? const NoxMoonIcon(size: 17)
                                : Icon(
                                    entry.icon,
                                    size: 17,
                                    color: entry.accent
                                        ? kMint
                                        : const Color(0xFF8192A8),
                                  ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.label,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    entry.detail,
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      height: 1.45,
                                      color: Color(0xFFA6B5C8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (entry != entries.last) const SizedBox(height: 9),
                      ],
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(t('知道了')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
        tooltip: t('了解更多'),
        visualDensity: VisualDensity.compact,
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('知道了')),
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
    required this.language,
    required this.storage,
  });

  final ModelSettings current;
  final String astrometryKey;
  final bool allowUpload;
  final AppLanguage language;
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

  /// 快速模板：只预填 Base URL 和型号名，不含 Key。
  ///
  /// 型号名是写死的，会过期——服务商换名字比这个应用发版快。所以界面上那句提示
  /// 明说「请在服务商处核对模型是否仍可用」；填错了也不会静默失败，调用会直接
  /// 报 404 / `resource_not_found_error`。
  ///
  /// 下面每个值都来自各家官方文档，不凭印象写（**2026-10-16 核对**）：
  ///
  ///   * **百炼**：BASE_URL 取「OpenAI 兼容」页那一版。文档现在主推带
  ///     `{WorkspaceId}` 的专属域名，但明确写了原域名可继续使用——模板没法预知
  ///     用户的 WorkspaceId，所以填原域名。型号取官方「推荐模型」表里的
  ///     `qwen3.8-flash`（轻量）与 `qwen3.8-max`（最强推理）。
  ///   * **智谱**：端点取自「快速开始」，型号取自「模型概览」——旗舰 `glm-5.3`，
  ///     轻量 `glm-5.3-flash`。
  ///   * **Kimi**：BASE_URL 取自 chat 接口页，型号取自公开价目表——`kimi-k2.6`
  ///     （轻量，K2 系列）与 `kimi-k3`（K3 系列）。
  ///   * **混元**：BASE_URL 与型号都取自它的「OpenAI 兼容接口」页。那页只给出
  ///     `hunyuan-turbos-latest` 这一个可直接引用的型号名，所以两个槽都填它——
  ///     宁可重复，也不编一个没核对过的名字。该页同时声明混元正在迁往 TokenHub、
  ///     旧控制台将下线，届时应按 TokenHub 的型号表更新。
  static final _apiTemplates = <_AgentApiTemplate>[
    const _AgentApiTemplate(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      lightModel: 'deepseek-chat',
      strongModel: 'deepseek-reasoner',
    ),
    const _AgentApiTemplate(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      lightModel: 'gpt-4.1-mini',
      strongModel: 'gpt-4.1',
    ),
    const _AgentApiTemplate(
      name: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      lightModel: 'deepseek/deepseek-chat',
      strongModel: 'deepseek/deepseek-r1',
    ),
    _AgentApiTemplate(
      name: t('硅基流动'),
      baseUrl: 'https://api.siliconflow.cn/v1',
      lightModel: 'deepseek-ai/DeepSeek-V3',
      strongModel: 'deepseek-ai/DeepSeek-R1',
    ),
    _AgentApiTemplate(
      name: t('阿里云百炼'),
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      lightModel: 'qwen3.8-flash',
      strongModel: 'qwen3.8-max',
    ),
    _AgentApiTemplate(
      name: t('智谱 GLM'),
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      lightModel: 'glm-5.3-flash',
      strongModel: 'glm-5.3',
    ),
    const _AgentApiTemplate(
      name: 'Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      lightModel: 'kimi-k2.6',
      strongModel: 'kimi-k3',
    ),
    _AgentApiTemplate(
      name: t('腾讯混元'),
      baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
      lightModel: 'hunyuan-turbos-latest',
      strongModel: 'hunyuan-turbos-latest',
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
        SnackBar(content: Text(t('请填写有效的模型 Base URL。'))),
      );
      return;
    }
    final values = {
      // 授权是个开关不是密钥，空值也照样写进去。
      'allowUpload': _allowUpload ? 'true' : 'false',
      // 语言不归这一页管：它在主页右上角改（`_pickLanguage`）。这里写的是**当前
      // 的值**，不是本页某次初始化时的快照——否则用户从右上角换完语言、再进来
      // 随便保存一次设置，就会被这一行悄悄改回去。这里保存的是同一个 key，所以
      // 两边不会打架。
      'language': appLanguage.value.code,
      'modelBaseUrl': _baseUrl.text.trim(),
      'lightKey': _lightKey.text.trim(),
      'lightModel': _lightModel.text.trim(),
      'strongKey': _strongKey.text.trim(),
      'strongModel': _strongModel.text.trim(),
      'astrometryKey': _astrometryKey.text.trim(),
    };
    try {
      for (final entry in values.entries) {
        if (entry.key == 'allowUpload' || entry.key == 'language') {
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
          SnackBar(content: Text(t('安全存储设置失败：{0}', [error]))),
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
              SectionTitle(t('本机 API-key 设置'), Icons.lock_outline),
              const SizedBox(height: 14),
              Text(
                t('快速模板'),
                style: const TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: _HelpButton(
                  title: t('模型 API 模板'),
                  message:
                      t('模板仅预填兼容接口的 Base URL 和模型名，不包含 API Key。请在服务商处自行申请 Key，核对模型是否仍可用。填写的密钥保存在本机安全存储，并发送至你配置的模型服务。'),
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
              const SizedBox(height: 12),
              _field(t('模型 API Base URL'), _baseUrl),
              _field(t('轻量模型名称'), _lightModel),
              _field(
                t('轻量模型 API Key'),
                _lightKey,
                secret: true,
                obscure: _obscureLight,
                toggle: () => setState(() => _obscureLight = !_obscureLight),
              ),
              _field(t('强推理模型名称'), _strongModel),
              _field(
                t('强推理模型 API Key'),
                _strongKey,
                secret: true,
                obscure: _obscureStrong,
                toggle: () => setState(() => _obscureStrong = !_obscureStrong),
              ),
              const SizedBox(height: 8),
              // 语言不在这里：它搬到了主页右上角（`_pickLanguage`）。放在设置里
              // 意味着「想换语言」要先进一个写着 API 的页面，而它是唯一一个
              // 改完立刻影响整屏的选项，值得直接摆在看得见的地方。
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
                title: Text(t('允许在必要时把图片上传至 Astrometry.net')),
                subtitle: Text(
                  t('请登录Astrometry.net获取APIKey。'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFFA6B5C8)),
                ),
              ),
              Text(
                t('密钥保存在本地安全存储。'),
                style: const TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
              ),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: Text(t('保存设置')))),
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

class _MaskPreviewPainter extends CustomPainter {
  const _MaskPreviewPainter({
    required this.imageWidth,
    required this.imageHeight,
    required this.regions,
  });

  final int imageWidth;
  final int imageHeight;
  final List<Map<String, double>> regions;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width / imageWidth, size.height / imageHeight);
    final displayedWidth = imageWidth * scale;
    final displayedHeight = imageHeight * scale;
    final offsetX = (size.width - displayedWidth) / 2;
    final offsetY = (size.height - displayedHeight) / 2;
    final fill = Paint()
      ..color = const Color(0x55FF526D)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = const Color(0xFFFF526D)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final region in regions) {
      final rect = Rect.fromLTWH(
        offsetX + region['x']! * displayedWidth,
        offsetY + region['y']! * displayedHeight,
        region['width']! * displayedWidth,
        region['height']! * displayedHeight,
      );
      canvas
        ..drawRect(rect, fill)
        ..drawRect(rect, outline);
    }
  }

  @override
  bool shouldRepaint(_MaskPreviewPainter oldDelegate) =>
      imageWidth != oldDelegate.imageWidth ||
      imageHeight != oldDelegate.imageHeight ||
      !identical(regions, oldDelegate.regions);
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

bool _isSafeObservationId(String id) =>
    RegExp(r'^\d{8}-\d{6}-\d{3}(?:-\d+)?$').hasMatch(id);
