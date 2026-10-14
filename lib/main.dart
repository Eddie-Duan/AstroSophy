import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';

import 'analysis.dart';
import 'astrometry.dart';
import 'model.dart';
import 'models.dart';
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
  bool _busy = false;
  bool _allowUpload = false;
  bool _solving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showOnboarding(firstLaunch: true));
  }

  Future<void> _showOnboarding({bool firstLaunch = false}) async {
    try {
      if (firstLaunch &&
          await _storage.read(key: 'onboardingComplete') == 'true') {
        return;
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: !firstLaunch,
        builder: (dialogContext) => _OnboardingDialog(
          onFinish: () async {
            try {
              await _storage.write(key: 'onboardingComplete', value: 'true');
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            } on Exception catch (error) {
              _showError('无法保存引导状态：$error');
            }
          },
        ),
      );
    } on Exception catch (error) {
      _showError('无法打开新手引导：$error');
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
      setState(() {
        _bytes = bytes;
        _filename = file.name;
        _analysis = null;
        _solve = null;
        _explanation = null;
        _error = null;
        _allowUpload = false;
      });
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
      setState(() {
        _bytes = bytes;
        _filename = file.name;
        _analysis = null;
        _solve = null;
        _explanation = null;
        _error = null;
        _allowUpload = false;
      });
    } catch (error) {
      _showError('读取图片失败：$error');
    }
  }

  Future<void> _analyze() async {
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _solve = null;
      _explanation = null;
    });
    try {
      final analysis = await compute(analyzeImageBytes, bytes);
      if (!mounted) return;
      setState(() => _analysis = analysis);
    } catch (error) {
      _showError('图片分析失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _solveSky() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final key = (await _storage.read(key: 'astrometryKey') ?? '').trim();
    if (key.isEmpty) {
      _showError('请先在设置中填写 Astrometry.net API Key。');
      return;
    }
    if (!_allowUpload) {
      _showError('请先确认授权将预览图上传至 Astrometry.net。');
      return;
    }
    setState(() {
      _solving = true;
      _error = null;
    });
    try {
      final result = await AstrometryService.solve(
        analysis: analysis,
        apiKey: key,
      );
      if (!mounted) return;
      setState(() => _solve = result);
    } catch (error) {
      _showError('天区解算未完成：$error');
    } finally {
      if (mounted) setState(() => _solving = false);
    }
  }

  Future<void> _explain() async {
    final analysis = _analysis;
    if (analysis == null) return;
    final settings = await _readModelSettings();
    if (settings.lightKey.isEmpty && settings.strongKey.isEmpty) {
      _showError('请先在设置中配置至少一个兼容 OpenAI 接口的模型 API Key。');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final text = await ModelService.explain(
        baseUrl: settings.baseUrl,
        lightKey: settings.lightKey,
        lightModel: settings.lightModel,
        strongKey: settings.strongKey,
        strongModel: settings.strongModel,
        report: _report(analysis, _solve),
        question: _questionController.text,
      );
      if (mounted) setState(() => _explanation = text);
    } catch (error) {
      _showError('模型解读失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, Object?> _report(SkyAnalysis analysis, SolveResult? solve) => {
        'quality': analysis.quality,
        'detected_stars': analysis.compactSources.length,
        'detected_sources': analysis.stars.length,
        'compact_sources': analysis.compactSources.length,
        'elongated_candidates': analysis.streakCandidates.length,
        'noise_fraction': analysis.noise,
        'background_visual_index': analysis.backgroundIndex,
        'diagnostics': analysis.diagnostics,
        'solved': solve != null,
        'center_ra_deg': solve?.centerRa,
        'center_dec_deg': solve?.centerDec,
        'catalog_stars': solve?.namedStars
            .map(
              (object) => {
                'name': object.name,
                'catalog_type': object.category,
                'ra_deg': object.ra,
                'dec_deg': object.dec,
                'gaia_g_magnitude': object.magnitude,
              },
            )
            .toList(),
        'deep_sky_objects': solve?.deepSkyObjects
            .map(
              (object) => {
                'name': object.name,
                'catalog_type': object.category,
                'ra_deg': object.ra,
                'dec_deg': object.dec,
              },
            )
            .toList(),
        'catalog_warning': solve?.catalogWarning,
        'photometry_scatter_mag': solve?.magnitudeScatter,
      };

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
    final form = SettingsForm(
      current: current,
      astrometryKey: astrometryKey,
      storage: _storage,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPanel,
      builder: (_) => form,
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    final solve = _solve;
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
                if (_bytes != null)
                  FilledButton.icon(
                    onPressed: _busy || _solving ? null : _analyze,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_busy ? '正在分析…' : '本地分析星图'),
                  ),
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
                if (analysis != null) ...[
                  const SizedBox(height: 18),
                  _diagnosticsCard(analysis),
                  const SizedBox(height: 12),
                  _starsCard(analysis, solve),
                  const SizedBox(height: 12),
                  _solveCard(solve),
                  if (solve != null) ...[
                    const SizedBox(height: 12),
                    _objectCard(solve),
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
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'JPG / PNG / TIFF · 支持尝试读取相机 RAW 内嵌预览',
            style: TextStyle(color: Color(0xFF8192A8), fontSize: 11),
          ),
        ],
      );

  Widget _imagePreview() => Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 0.82,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _isRawName(_filename ?? '') && _analysis == null
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
                          _analysis?.preview ?? _bytes!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, error, __) => Center(
                            child: Text(
                              '暂不支持此图片格式：$error',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                  if (_analysis != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: DetectedStarsPainter(
                          analysis: _analysis!,
                          namedStars: _solve?.namedStars ?? const [],
                          objects: _solve?.deepSkyObjects ?? const [],
                        ),
                      ),
                    ),
                ],
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

  Widget _starsCard(SkyAnalysis analysis, SolveResult? solve) {
    final stars = [...analysis.compactSources]
      ..sort((first, second) => first.instrumentalMagnitude.compareTo(second.instrumentalMagnitude));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionTitle('亮星与测光', Icons.stars_rounded),
                _HelpButton(
                  title: '星名与测光',
                  message:
                      '未完成天区解算时只显示图内相对亮度，不能确认星名。'
                      'Gaia G 近似标定受相机光谱响应、白平衡、饱和与图像处理影响；'
                      '显示的散布不包含全部系统误差。',
                ),
              ],
            ),
            if (stars.isEmpty && analysis.streakCandidates.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('没有检出可信的紧凑亮点。'),
              )
            else if (stars.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('没有可用于恒星测光的紧凑点源；下方仅列出形态异常候选。'),
              )
            else
              ...stars.take(12).map((star) {
                final name = _nearestNamed(star, solve?.namedStars ?? const []);
                final magnitude = name?.magnitude;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: kMint.withValues(alpha: 0.16),
                    child: Text('${stars.indexOf(star) + 1}', style: const TextStyle(color: kMint)),
                  ),
                  title: Text(
                    name?.name ?? '图内亮点',
                  ),
                  subtitle: Text(
                    '${name?.category.isNotEmpty == true ? '${name!.category} · ' : ''}'
                    '像素 (${star.x.toStringAsFixed(0)}, ${star.y.toStringAsFixed(0)}) · '
                    '${star.confidenceLabel} ${(star.confidence * 100).toStringAsFixed(0)}%',
                  ),
                  trailing: Text(
                    solve?.magnitudeZeroPoint != null && star.confidence >= 0.25
                        ? 'G~${(star.instrumentalMagnitude + solve!.magnitudeZeroPoint!).toStringAsFixed(2)}'
                        : magnitude != null
                            ? '${name!.magnitudeBand} ${magnitude.toStringAsFixed(2)}'
                            : 'Δm ${_relativeMagnitude(star, stars.first).toStringAsFixed(2)}',
                    textAlign: TextAlign.end,
                  ),
                );
              }),
            if (analysis.streakCandidates.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 10, bottom: 4),
                child: Text('线状候选'),
              ),
              ...analysis.streakCandidates.take(6).map(
                    (candidate) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('拉长的亮点'),
                      subtitle: Text('形态比 ${candidate.axisRatio.toStringAsFixed(1)}:1'),
                      trailing: Text(candidate.confidenceLabel),
                    ),
                  ),
            ],
            if (solve?.magnitudeScatter != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Gaia G 近似散布 ±${solve!.magnitudeScatter!.toStringAsFixed(2)} 等',
                      style: const TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
                    ),
                  ),
                  const _HelpButton(
                    title: '测光误差',
                    message:
                        '该散布不包含相机光谱响应、白平衡、饱和、镜头暗角和图像处理造成的系统误差，'
                        '结果仅供参考。',
                  ),
                ],
              ),
          ],
        ),
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
              const SectionTitle('天区识别', Icons.public_rounded),
              if (solve == null) ...[
                const Row(
                  children: [
                    Expanded(child: SizedBox()),
                    _HelpButton(
                      title: '天区解算与隐私',
                      message:
                          '天区解算使用 Astrometry.net 在线服务，会上传分析预览图。'
                          '只有勾选同意后才会发送；取消勾选时不会上传。'
                          '不解算时仍可查看本机星点与画质分析。',
                    ),
                  ],
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowUpload,
                  onChanged: (value) => setState(() => _allowUpload = value ?? false),
                  title: const Text('我同意将预览图上传至 Astrometry.net'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _solving ? null : _solveSky,
                    icon: _solving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.travel_explore),
                    label: Text(_solving ? '正在解算…' : '解算天球位置并匹配星表'),
                  ),
                ),
              ] else ...[
                const SizedBox(height: 10),
                Text(
                  '中心 RA ${formatRa(solve.centerRa)}  ·  Dec ${solve.centerDec.toStringAsFixed(4)}°',
                ),
                const SizedBox(height: 8),
                Text(
                  '视场角比例 ${solve.arcsecPerPixel.toStringAsFixed(2)}″/px'
                  '   ·   Gaia 匹配 ${solve.matchedStars.length} 颗',
                ),
              ],
            ],
          ),
        ),
      );

  Widget _objectCard(SolveResult solve) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('视场中的天体', Icons.auto_awesome_mosaic_rounded),
            const SizedBox(height: 8),
            if (solve.catalogWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '名称目录暂不可用：${solve.catalogWarning}',
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
            if (solve.namedStars.isEmpty && solve.deepSkyObjects.isEmpty)
              const Text('已解算位置，但星表目录暂未返回位于视场内的匹配对象。'),
            ...solve.namedStars.take(15).map(
              (object) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(object.name),
                subtitle: Text(object.category),
                trailing: object.magnitude == null
                    ? null
                    : Text('${object.magnitudeBand} ${object.magnitude!.toStringAsFixed(2)}'),
              ),
            ),
            ...solve.deepSkyObjects.map(
              (object) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(object.name),
                subtitle: Text(object.category),
                trailing: const Icon(Icons.scatter_plot, color: Color(0xFFFF7B8C)),
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
                  onPressed: _busy ? null : _explain,
                  child: const Text('基于测量结果生成解读'),
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

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog({required this.onFinish});

  final VoidCallback onFinish;

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  static const _steps = <({IconData icon, String title, String message})>[
    (
      icon: Icons.photo_library_outlined,
      title: '导入星图',
      message: '选一张星空照片，分析默认在手机本机进行。',
    ),
    (
      icon: Icons.auto_awesome,
      title: '查看结果',
      message: '浏览星点、图像质量与测光；点“？”查看指标说明。',
    ),
    (
      icon: Icons.public_rounded,
      title: '认识天区',
      message: '在线解算和 AI 都是可选功能；上传照片前会单独征求同意。',
    ),
  ];

  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _steps.length - 1) {
      widget.onFinish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Image.asset(
                    'assets/brand/astrosophy_app_icon.png',
                    width: 32,
                    height: 32,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '欢迎使用星鉴',
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '${_page + 1}/${_steps.length}',
                    style: const TextStyle(color: Color(0xFFA6B5C8)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 245,
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _steps.length,
                  onPageChanged: (page) => setState(() => _page = page),
                  itemBuilder: (context, index) {
                    final step = _steps[index];
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(step.icon, size: 58, color: kMint),
                        const SizedBox(height: 18),
                        Text(
                          step.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          step.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFA6B5C8)),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var index = 0; index < _steps.length; index++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: index == _page ? 18 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: index == _page ? kMint : const Color(0xFF46556B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  TextButton(
                    onPressed: widget.onFinish,
                    child: const Text('跳过'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child: Text(_page == _steps.length - 1 ? '开始探索' : '下一步'),
                  ),
                ],
              ),
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
    required this.storage,
  });

  final ModelSettings current;
  final String astrometryKey;
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
      'modelBaseUrl': _baseUrl.text.trim(),
      'lightKey': _lightKey.text.trim(),
      'lightModel': _lightModel.text.trim(),
      'strongKey': _strongKey.text.trim(),
      'strongModel': _strongModel.text.trim(),
      'astrometryKey': _astrometryKey.text.trim(),
    };
    try {
      for (final entry in values.entries) {
        if (entry.value.isEmpty) {
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
              const Text(
                '密钥保存在本机安全存储。模型只接收测量摘要；天区解算会上传预览图。',
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
