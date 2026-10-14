import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as imglib;
import 'package:image_picker/image_picker.dart';

const _background = Color(0xFF080E19);
const _panel = Color(0xFF101A2A);
const _mint = Color(0xFF64D9BD);

void main() => runApp(const AstroSophyApp());

class AstroSophyApp extends StatelessWidget {
  const AstroSophyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AstroSophy',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _background,
          colorScheme: const ColorScheme.dark(
            primary: _mint,
            secondary: Color(0xFFFFDE77),
            surface: _panel,
          ),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(backgroundColor: _background),
          cardTheme: CardThemeData(
            color: _panel,
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
      final analysis = await compute(_analyzeImageBytes, bytes);
      if (!mounted) return;
      setState(() => _analysis = analysis);
    } catch (error) {
      _showError('图片分析失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _solve() async {
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
      backgroundColor: _panel,
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
            const Positioned.fill(child: CustomPaint(painter: _StarfieldPainter())),
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
                const Positioned.fill(child: CustomPaint(painter: _OrbitPainter())),
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
                        color: _mint,
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
                              Icon(Icons.raw_on, size: 42, color: _mint),
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
                        painter: _DetectedStarsPainter(
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const _SectionTitle('图像诊断', Icons.monitor_heart_outlined),
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
                  _MetricChip('质量', analysis.quality),
                  _MetricChip('紧凑点源', '${analysis.compactSources.length}'),
                  if (analysis.streakCandidates.isNotEmpty)
                    _MetricChip('线状候选', '${analysis.streakCandidates.length}'),
                  _MetricChip('背景噪声', '${(analysis.noise * 100).toStringAsFixed(1)}%'),
                  _MetricChip('视觉背景', '${analysis.backgroundIndex.toStringAsFixed(0)} / 100'),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const _SectionTitle('亮星与测光', Icons.stars_rounded),
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
                    backgroundColor: _mint.withOpacity(0.16),
                    child: Text('${stars.indexOf(star) + 1}', style: const TextStyle(color: _mint)),
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
                  _HelpButton(
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
              const _SectionTitle('天区识别', Icons.public_rounded),
              if (solve == null) ...[
                Row(
                  children: [
                    const Expanded(child: SizedBox()),
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
                    onPressed: _solving ? null : _solve,
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
            const _SectionTitle('视场中的天体', Icons.auto_awesome_mosaic_rounded),
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
              const _SectionTitle('Agent 解读', Icons.chat_bubble_outline_rounded),
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
                        Icon(step.icon, size: 58, color: _mint),
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
                        color: index == _page ? _mint : const Color(0xFF46556B),
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
              const _SectionTitle('本机 API 设置', Icons.lock_outline),
              const SizedBox(height: 14),
              const Text(
                '快速模板（仅填写接口地址和模型名，不含 API Key）',
                style: TextStyle(color: Color(0xFFA6B5C8), fontSize: 12),
              ),
              Align(
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

class SkyAnalysis {
  const SkyAnalysis({
    required this.width,
    required this.height,
    required this.stars,
    required this.quality,
    required this.background,
    required this.noise,
    required this.backgroundIndex,
    required this.saturatedFraction,
    required this.diagnostics,
    required this.preview,
  });

  final int width;
  final int height;
  final List<DetectedStar> stars;
  final String quality;
  final double background;
  final double noise;
  final double backgroundIndex;
  final double saturatedFraction;
  final List<String> diagnostics;
  final Uint8List preview;

  List<DetectedStar> get streakCandidates =>
      stars.where((star) => star.isElongated).toList(growable: false);

  List<DetectedStar> get compactSources =>
      stars.where((star) => !star.isElongated).toList(growable: false);

  static Future<SkyAnalysis> analyze(Uint8List bytes) async {
    final decoded = _decodeImageOrRawPreview(bytes);
    if (decoded == null) {
      throw const FormatException(
        '无法解码此图片或 RAW 内嵌预览。请在相机应用中导出 JPG/PNG 后重试。',
      );
    }
    final image = decoded.width > 1200 || decoded.height > 1200
        ? decoded.width >= decoded.height
            ? imglib.copyResize(
                decoded,
                width: 1200,
                interpolation: imglib.Interpolation.linear,
              )
            : imglib.copyResize(
                decoded,
                height: 1200,
                interpolation: imglib.Interpolation.linear,
              )
        : decoded;
    final width = image.width;
    final height = image.height;
    final gray = List<double>.filled(width * height, 0);
    var saturated = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final pixel = image.getPixel(x, y);
        final value =
            ((0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b) / 255.0)
                .toDouble();
        gray[y * width + x] = value;
        if (pixel.r >= 250 || pixel.g >= 250 || pixel.b >= 250) saturated++;
      }
    }
    final sampled = <double>[];
    final sampleStep = math.max(1, gray.length ~/ 100000).toInt();
    for (var i = 0; i < gray.length; i += sampleStep) {
      sampled.add(gray[i]);
    }
    sampled.sort();
    final background = sampled[sampled.length ~/ 2];
    final deviations = sampled.map((value) => (value - background).abs()).toList()..sort();
    final noise =
        math.max(1 / 255, 1.4826 * deviations[deviations.length ~/ 2]).toDouble();
    final primaryThreshold =
        math.max(background + 5 * noise, background + 4 / 255).toDouble();
    var stars = _detectStars(gray, width, height, primaryThreshold, noise);
    var compactCount = stars.where((star) => !star.isElongated).length;
    final usedFallback = compactCount < 8;
    if (usedFallback) {
      final retryThreshold =
          math.max(background + 3.5 * noise, background + 3 / 255).toDouble();
      final retryStars = _detectStars(gray, width, height, retryThreshold, noise);
      final retryCompactCount =
          retryStars.where((star) => !star.isElongated).length;
      if (retryCompactCount > compactCount) {
        stars = retryStars;
        compactCount = retryCompactCount;
      }
    }
    final saturatedFraction = saturated / gray.length;
    final diagnostics = <String>[];
    if (usedFallback) {
      diagnostics.add('标准星点阈值检出较少，已自动降低阈值重试；弱点源中可能混入噪声。');
    }
    final streakCount = stars.where((star) => star.isElongated).length;
    final compactSources = stars.where((star) => !star.isElongated).toList();
    if (streakCount > 0) {
      diagnostics.add(
        '发现 $streakCount 个拉长的亮点候选，可能是拖线、失焦或图像处理伪影；'
        '单张照片不能据此确认卫星或飞机，已从恒星匹配和标定测光中排除。',
      );
    }
    if (compactCount < 8) {
      diagnostics.add('检出的紧凑亮点较少；可能曝光不足、虚焦或云雾遮挡。');
    }
    if (noise > 0.06) diagnostics.add('背景噪声偏高，弱星检测和相对亮度测量可靠性下降。');
    if (saturatedFraction > 0.01) diagnostics.add('部分像素接近饱和，亮星核心的亮度信息可能丢失。');
    if (background > 0.38) {
      diagnostics.add('图像背景偏亮；受曝光影响，不能直接换算成 SQM 或 Bortle 等级。');
    }
    if (compactSources.isNotEmpty &&
        compactSources
                    .take(30)
                    .map((star) => star.confidence)
                    .reduce((a, b) => a + b) /
                math.min(30, compactSources.length) <
            0.38) {
      diagnostics.add('点源形态不够集中，可能存在抖动、虚焦或强降噪；测光置信度偏低。');
    }
    if (compactCount < 8) {
      diagnostics.add('拍摄建议：固定设备并重新手动对焦；避开云雾和灯光直射后再试。');
    }
    if (noise > 0.06) {
      diagnostics.add('拍摄建议：优先拍摄多张较短曝光用于后续叠加，避免只提高 ISO。');
    }
    if (saturatedFraction > 0.01) {
      diagnostics.add('拍摄建议：降低曝光或增益，避免亮星核心过曝。');
    }
    if (background > 0.38) {
      diagnostics.add('拍摄建议：若现场天空也明显发亮，可换到更暗地点并缩短单张曝光。');
    }
    final quality = compactCount >= 25 && noise < 0.04 && saturatedFraction < 0.01
        ? '较好'
        : compactCount >= 8
            ? '一般'
            : '较弱';
    if (diagnostics.isEmpty) {
      diagnostics.add('检出紧凑亮点；准确星名仍需可靠的天球坐标解算。');
    }
    return SkyAnalysis(
      width: width,
      height: height,
      stars: stars,
      quality: quality,
      background: background,
      noise: noise,
      backgroundIndex: background * 100,
      saturatedFraction: saturatedFraction,
      diagnostics: diagnostics,
      preview: Uint8List.fromList(imglib.encodeJpg(image, quality: 92)),
    );
  }
}

List<DetectedStar> _detectStars(
  List<double> gray,
  int width,
  int height,
  double threshold,
  double noise,
) {
  final peaks = <(int, int, double)>[];
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final value = gray[y * width + x];
      if (value < threshold) continue;
      var maximum = true;
      for (var dy = -1; dy <= 1 && maximum; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final neighbor = gray[(y + dy) * width + x + dx];
          final before = dy < 0 || (dy == 0 && dx < 0);
          if (value < neighbor || (value == neighbor && before)) {
            maximum = false;
            break;
          }
        }
      }
      if (!maximum) continue;
      peaks.add((x, y, value));
    }
  }
  peaks.sort((first, second) => second.$3.compareTo(first.$3));
  final stars = <DetectedStar>[];
  for (final (x, y, _) in peaks.take(300)) {
    final star = _measure(gray, width, height, x, y, noise);
    if (star != null) stars.add(star);
  }
  stars.sort((first, second) => second.flux.compareTo(first.flux));
  return stars;
}

DetectedStar? _measure(List<double> gray, int width, int height, int x, int y, double noise) {
  final x0 = math.max(0, x - 3).toInt();
  final x1 = math.min(width, x + 4).toInt();
  final y0 = math.max(0, y - 3).toInt();
  final y1 = math.min(height, y + 4).toInt();
  final patch = <double>[];
  for (var py = y0; py < y1; py++) {
    for (var px = x0; px < x1; px++) {
      patch.add(gray[py * width + px]);
    }
  }
  if (patch.length < 25) return null;
  patch.sort();
  final localBackground = patch[patch.length ~/ 2];
  var flux = 0.0;
  var weightedX = 0.0;
  var weightedY = 0.0;
  for (var py = y0; py < y1; py++) {
    for (var px = x0; px < x1; px++) {
      final signal =
          math.max(0, gray[py * width + px] - localBackground).toDouble();
      flux += signal;
      weightedX += signal * px;
      weightedY += signal * py;
    }
  }
  if (flux <= 0) return null;
  final centerX = weightedX / flux;
  final centerY = weightedY / flux;
  var varianceX = 0.0;
  var varianceY = 0.0;
  var covariance = 0.0;
  for (var py = y0; py < y1; py++) {
    for (var px = x0; px < x1; px++) {
      final signal =
          math.max(0, gray[py * width + px] - localBackground).toDouble();
      final dx = px - centerX;
      final dy = py - centerY;
      varianceX += signal * dx * dx;
      varianceY += signal * dy * dy;
      covariance += signal * dx * dy;
    }
  }
  varianceX /= flux;
  varianceY /= flux;
  covariance /= flux;
  final halfTrace = (varianceX + varianceY) / 2;
  final halfDifference = (varianceX - varianceY) / 2;
  final eigenvalueOffset =
      math.sqrt(halfDifference * halfDifference + covariance * covariance);
  final majorVariance = math.max(0, halfTrace + eigenvalueOffset);
  final minorVariance = math.max(0.05, halfTrace - eigenvalueOffset);
  final axisRatio = math.sqrt(majorVariance / minorVariance);
  final spread = varianceX + varianceY;
  final sharpness = 1 / (1 + math.max(0, spread - 1) / 8);
  final snr = flux / math.max(noise * math.sqrt(patch.length), 1e-6);
  final shapePenalty = math.sqrt(math.min(1, 2 / axisRatio));
  final confidence = ((snr / (snr + 8)) * sharpness * shapePenalty)
      .clamp(0.0, 1.0)
      .toDouble();
  return DetectedStar(
    centerX,
    centerY,
    flux,
    -2.5 * math.log(flux) / math.ln10,
    confidence,
    axisRatio,
  );
}

imglib.Image? _decodeImageOrRawPreview(Uint8List bytes) {
  try {
    final decoded = imglib.decodeImage(bytes);
    if (decoded != null) return decoded;
  } on Exception {
    // Camera RAW containers may contain a usable JPEG preview.
  }

  imglib.Image? largestPreview;
  var start = 0;
  var inspected = 0;
  while (start + 3 < bytes.length && inspected < 32) {
    while (start + 1 < bytes.length &&
        !(bytes[start] == 0xFF && bytes[start + 1] == 0xD8)) {
      start++;
    }
    if (start + 1 >= bytes.length) break;
    final jpegStart = start;
    var end = jpegStart + 2;
    while (end + 1 < bytes.length &&
        !(bytes[end] == 0xFF && bytes[end + 1] == 0xD9)) {
      end++;
    }
    if (end + 1 >= bytes.length) break;
    try {
      final preview = imglib.decodeImage(bytes.sublist(jpegStart, end + 2));
      if (preview != null &&
          (largestPreview == null ||
              preview.width * preview.height >
                  largestPreview.width * largestPreview.height)) {
        largestPreview = preview;
      }
    } on Exception {
      // Continue looking for another complete JPEG thumbnail.
    }
    inspected++;
    start = end + 2;
  }
  return largestPreview;
}

Future<SkyAnalysis> _analyzeImageBytes(Uint8List bytes) =>
    SkyAnalysis.analyze(bytes);

class DetectedStar {
  const DetectedStar(
    this.x,
    this.y,
    this.flux,
    this.instrumentalMagnitude,
    this.confidence,
    this.axisRatio,
  );

  final double x;
  final double y;
  final double flux;
  final double instrumentalMagnitude;
  final double confidence;
  final double axisRatio;

  bool get isElongated => axisRatio >= 2.2;

  String get confidenceLabel => confidence >= 0.7
      ? '较可信'
      : confidence >= 0.35
          ? '供参考'
          : '低可信';
}

class SkyObject {
  const SkyObject(
    this.name,
    this.ra,
    this.dec,
    this.category, {
    this.magnitude,
    this.magnitudeBand = 'G',
    this.x = 0,
    this.y = 0,
  });

  final String name;
  final double ra;
  final double dec;
  final String category;
  final double? magnitude;
  final String magnitudeBand;
  final double x;
  final double y;

  SkyObject at(double x, double y) => SkyObject(
        name,
        ra,
        dec,
        category,
        magnitude: magnitude,
        magnitudeBand: magnitudeBand,
        x: x,
        y: y,
      );
}

class GaiaMatch {
  const GaiaMatch({
    required this.sourceId,
    required this.ra,
    required this.dec,
    required this.x,
    required this.y,
    required this.gMagnitude,
  });

  final String sourceId;
  final double ra;
  final double dec;
  final double x;
  final double y;
  final double gMagnitude;
}

class _CatalogObject {
  const _CatalogObject(this.mainId, this.ra, this.dec, this.objectType);

  final String mainId;
  final double ra;
  final double dec;
  final String objectType;

  bool get isStar => const [
        '*',
        'V*',
        'SB*',
        'EB*',
        'LM*',
        'Em*',
        'Y*O',
        'PM*',
        'WD*',
        'BY*',
        'RGB*',
        'HB*',
        'OH*',
      ].any(objectType.startsWith);

  bool get isDeepSky =>
      objectType == 'G' ||
      objectType.startsWith('Cl*') ||
      objectType.startsWith('ClG') ||
      objectType.startsWith('OpC') ||
      objectType.startsWith('GlC') ||
      objectType.startsWith('Neb') ||
      objectType.startsWith('HII') ||
      objectType.startsWith('SNR');
}

class SolveResult {
  const SolveResult({
    required this.centerRa,
    required this.centerDec,
    required this.arcsecPerPixel,
    required this.namedStars,
    required this.deepSkyObjects,
    required this.matchedStars,
    required this.magnitudeZeroPoint,
    required this.magnitudeScatter,
    required this.catalogWarning,
  });

  final double centerRa;
  final double centerDec;
  final double arcsecPerPixel;
  final List<SkyObject> namedStars;
  final List<SkyObject> deepSkyObjects;
  final List<GaiaMatch> matchedStars;
  final double? magnitudeZeroPoint;
  final double? magnitudeScatter;
  final String? catalogWarning;
}

class _Wcs {
  const _Wcs({
    required this.width,
    required this.height,
    required this.crval1,
    required this.crval2,
    required this.crpix1,
    required this.crpix2,
    required this.cd11,
    required this.cd12,
    required this.cd21,
    required this.cd22,
  });

  final int width;
  final int height;
  final double crval1;
  final double crval2;
  final double crpix1;
  final double crpix2;
  final double cd11;
  final double cd12;
  final double cd21;
  final double cd22;

  static _Wcs parse(Uint8List bytes) {
    final values = <String, String>{};
    var offset = 0;
    var ended = false;
    final asciiText = ascii.decode(bytes, allowInvalid: true);
    while (offset + 80 <= asciiText.length && !ended) {
      final card = asciiText.substring(offset, offset + 80);
      offset += 80;
      final key = card.substring(0, 8).trim();
      if (key == 'END') {
        ended = true;
      } else if (card.substring(8, 10) == '= ') {
        values[key] = card.substring(10, 80).split('/').first.trim();
      }
    }
    if (!ended) throw const FormatException('星图解算没有返回有效 FITS 天球坐标。');
    double number(String key) {
      final raw = values[key]?.replaceAll('D', 'E');
      final value = raw == null ? null : double.tryParse(raw);
      if (value == null || !value.isFinite) {
        throw FormatException('解算结果缺少有效的 $key。');
      }
      return value;
    }

    final width = int.tryParse(values['NAXIS1'] ?? '');
    final height = int.tryParse(values['NAXIS2'] ?? '');
    if (width == null || height == null) throw const FormatException('解算结果缺少有效图像尺寸。');
    return _Wcs(
      width: width,
      height: height,
      crval1: number('CRVAL1'),
      crval2: number('CRVAL2'),
      crpix1: number('CRPIX1'),
      crpix2: number('CRPIX2'),
      cd11: number('CD1_1'),
      cd12: number('CD1_2'),
      cd21: number('CD2_1'),
      cd22: number('CD2_2'),
    );
  }

  double get determinant => cd11 * cd22 - cd12 * cd21;
  double get arcsecPerPixel =>
      3600 * math.sqrt((cd11 * cd22 - cd12 * cd21).abs());

  (double, double) get imageCenter =>
      pixelToWorld((width - 1) / 2, (height - 1) / 2);

  (double, double) pixelToWorld(double x, double y) {
    const radians = math.pi / 180;
    final deltaX = x + 1 - crpix1;
    final deltaY = y + 1 - crpix2;
    final xi = (cd11 * deltaX + cd12 * deltaY) * radians;
    final eta = (cd21 * deltaX + cd22 * deltaY) * radians;
    final rho = math.sqrt(xi * xi + eta * eta);
    if (rho == 0) return (crval1 % 360, crval2);
    final c = math.atan(rho);
    final ra0 = crval1 * radians;
    final dec0 = crval2 * radians;
    final dec = math.asin(
      math.cos(c) * math.sin(dec0) +
          eta * math.sin(c) * math.cos(dec0) / rho,
    );
    final ra = ra0 +
        math.atan2(
          xi * math.sin(c),
          rho * math.cos(dec0) * math.cos(c) -
              eta * math.sin(dec0) * math.sin(c),
        );
    return ((ra / radians) % 360, dec / radians);
  }

  (double, double) worldToPixel(double ra, double dec) {
    const radians = math.pi / 180;
    final ra0 = crval1 * radians;
    final dec0 = crval2 * radians;
    final targetRa = ra * radians;
    final targetDec = dec * radians;
    final deltaRa = _wrapRadians(targetRa - ra0);
    final denominator = math.sin(dec0) * math.sin(targetDec) +
        math.cos(dec0) * math.cos(targetDec) * math.cos(deltaRa);
    if (denominator <= 0) return (-1e9, -1e9);
    final xi = math.cos(targetDec) * math.sin(deltaRa) / denominator / radians;
    final eta = (math.cos(dec0) * math.sin(targetDec) -
            math.sin(dec0) * math.cos(targetDec) * math.cos(deltaRa)) /
        denominator /
        radians;
    final dx = (cd22 * xi - cd12 * eta) / determinant;
    final dy = (-cd21 * xi + cd11 * eta) / determinant;
    return (crpix1 + dx - 1, crpix2 + dy - 1);
  }
}

double _wrapRadians(double value) {
  while (value > math.pi) {
    value -= 2 * math.pi;
  }
  while (value < -math.pi) {
    value += 2 * math.pi;
  }
  return value;
}

class AstrometryService {
  static const _api = 'https://nova.astrometry.net/api';

  static Future<SolveResult> solve({
    required SkyAnalysis analysis,
    required String apiKey,
  }) async {
    final client = http.Client();
    try {
      final login = await client.post(
        Uri.parse('$_api/login'),
        body: {'request-json': jsonEncode({'apikey': apiKey})},
      ).timeout(const Duration(seconds: 30));
      final sessionToken = _json(login)['session'];
      if (sessionToken is! String || sessionToken.isEmpty) {
        throw StateError('Astrometry.net 未返回会话令牌，请检查 API Key。');
      }

      final request = http.MultipartRequest('POST', Uri.parse('$_api/upload'))
        ..fields['request-json'] = jsonEncode({
          'session': sessionToken,
          'allow_commercial_use': 'n',
          'allow_modifications': 'n',
          'publicly_visible': 'n',
        })
        ..files.add(http.MultipartFile.fromBytes('file', analysis.preview, filename: 'sky.jpg'));
      final upload = _json(await client.send(request).then(http.Response.fromStream));
      final subId = upload['subid'];
      if (subId == null) throw StateError('天文解算服务未接受图片。');

      final deadline = DateTime.now().add(const Duration(minutes: 4));
      String? jobId;
      while (DateTime.now().isBefore(deadline) && jobId == null) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final response = await client.get(Uri.parse('$_api/submissions/$subId')).timeout(
              const Duration(seconds: 30),
            );
        final jobs = _json(response)['jobs'];
        if (jobs is List) {
          for (final job in jobs) {
            if (job != null) {
              jobId = '$job';
              break;
            }
          }
        }
      }
      if (jobId == null) throw TimeoutException('天区解算排队超时，请稍后再试。');

      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final status = _json(
          await client.get(Uri.parse('$_api/jobs/$jobId')).timeout(
                const Duration(seconds: 30),
              ),
        );
        if (status['status'] == 'failure') {
          throw StateError('星图解算失败：请检查星点数量、拖线和画面遮挡。');
        }
        if (status['status'] == 'success') break;
      }
      final finalStatus = _json(
        await client.get(Uri.parse('$_api/jobs/$jobId')).timeout(
              const Duration(seconds: 30),
            ),
      );
      if (finalStatus['status'] != 'success') {
        throw TimeoutException('星图解算超时，请稍后重试。');
      }
      final fitsResponse = await client
          .get(Uri.parse('https://nova.astrometry.net/wcs_file/$jobId'))
          .timeout(const Duration(seconds: 45));
      if (fitsResponse.statusCode != 200) throw StateError('无法读取天球坐标解算结果。');
      final wcs = _Wcs.parse(fitsResponse.bodyBytes);
      if (wcs.width != analysis.width || wcs.height != analysis.height) {
        throw StateError('解算图像尺寸与本地预览不一致，已停止坐标标注。');
      }
      var gaia = <GaiaMatch>[];
      var simbadObjects = <_CatalogObject>[];
      final catalogWarnings = <String>[];
      try {
        gaia = await _queryGaia(client, wcs, analysis);
      } on Exception catch (error) {
        catalogWarnings.add('Gaia DR3 星表：$error');
      }
      try {
        simbadObjects = await _querySimbad(client, wcs, analysis);
      } on Exception catch (error) {
        catalogWarnings.add('SIMBAD 名称目录：$error');
      }

      final simbadStars =
          simbadObjects.where((object) => object.isStar).toList(growable: false);
      final named = <SkyObject>[];
      final usedDetections = <DetectedStar>{};
      final usedNames = <String>{};
      for (final gaiaStar in gaia) {
        if (named.length >= 60) break;
        final nearest = _nearest(analysis.stars, gaiaStar.x, gaiaStar.y);
        if (nearest == null ||
            nearest.distance > math.max(4, math.min(analysis.width, analysis.height) * 0.004) ||
            !usedDetections.add(nearest.star)) {
          continue;
        }
        final simbadStar = _nearestSimbadStar(
          gaiaStar.ra,
          gaiaStar.dec,
          simbadStars,
        );
        final simbadName =
            simbadStar != null && usedNames.add(simbadStar.mainId)
                ? simbadStar.mainId
                : null;
        named.add(
          SkyObject(
            simbadName ?? 'Gaia DR3 ${gaiaStar.sourceId}',
            gaiaStar.ra,
            gaiaStar.dec,
            simbadStar?.objectType ?? '恒星 · Gaia DR3',
            magnitude: gaiaStar.gMagnitude,
            magnitudeBand: 'G',
            x: nearest.star.x,
            y: nearest.star.y,
          ),
        );
      }
      if (gaia.isEmpty) {
        for (final object in simbadStars) {
          final (x, y) = wcs.worldToPixel(object.ra, object.dec);
          final nearest = _nearest(analysis.stars, x, y);
          if (nearest == null ||
              nearest.distance >
                  math.max(4, math.min(analysis.width, analysis.height) * 0.004) ||
              !usedDetections.add(nearest.star)) {
            continue;
          }
          named.add(
            SkyObject(
              object.mainId,
              object.ra,
              object.dec,
              object.objectType,
              x: nearest.star.x,
              y: nearest.star.y,
            ),
          );
          if (named.length >= 60) break;
        }
      }
      final clusters = <SkyObject>[];
      final knownNames = <String>{};
      for (final object in simbadObjects.where((item) => item.isDeepSky)) {
        if (clusters.length >= 30 || !knownNames.add(object.mainId)) continue;
        final (x, y) = wcs.worldToPixel(object.ra, object.dec);
        if (x >= 0 && x < analysis.width && y >= 0 && y < analysis.height) {
          clusters.add(
            SkyObject(
              object.mainId,
              object.ra,
              object.dec,
              object.objectType,
              x: x,
              y: y,
            ),
          );
        }
      }
      final offsets = <double>[];
      final usedReferenceStars = <DetectedStar>{};
      for (final match in gaia) {
        final nearest = _nearest(analysis.stars, match.x, match.y);
        if (nearest != null &&
            nearest.distance <= 4 &&
            nearest.star.confidence >= 0.25 &&
            usedReferenceStars.add(nearest.star) &&
            match.gMagnitude >= 4 &&
            match.gMagnitude <= 18) {
          offsets.add(match.gMagnitude - nearest.star.instrumentalMagnitude);
        }
      }
      double? zeroPoint;
      double? scatter;
      if (offsets.length >= 5) {
        offsets.sort();
        zeroPoint = _median(offsets);
        final deviations = offsets.map((value) => (value - zeroPoint!).abs()).toList()..sort();
        scatter = 1.4826 * _median(deviations);
      }
      return SolveResult(
        centerRa: wcs.imageCenter.$1,
        centerDec: wcs.imageCenter.$2,
        arcsecPerPixel: wcs.arcsecPerPixel,
        namedStars: named,
        deepSkyObjects: clusters,
        matchedStars: gaia,
        magnitudeZeroPoint: zeroPoint,
        magnitudeScatter: scatter,
        catalogWarning:
            catalogWarnings.isEmpty ? null : catalogWarnings.join('；'),
      );
    } finally {
      client.close();
    }
  }

  static Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('天文服务返回 HTTP ${response.statusCode}。');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) throw const FormatException('天文服务返回格式无效。');
    if (decoded['status'] == 'error') {
      throw StateError('${decoded['errormessage'] ?? '天文服务处理失败。'}');
    }
    return decoded;
  }

  static Future<List<GaiaMatch>> _queryGaia(
    http.Client client,
    _Wcs wcs,
    SkyAnalysis analysis,
  ) async {
    final radiusArcsec = math.max(
      analysis.width,
      analysis.height,
    ) * wcs.arcsecPerPixel * 0.8;
    final radiusDegrees = (radiusArcsec / 3600).clamp(0.05, 5.0).toDouble();
    final center = wcs.imageCenter;
    final adql = 'SELECT TOP 1500 source_id, ra, dec, phot_g_mean_mag '
        'FROM gaiadr3.gaia_source '
        'WHERE 1=CONTAINS(POINT(\'ICRS\',ra,dec), '
        'CIRCLE(\'ICRS\',${center.$1},${center.$2},$radiusDegrees)) '
        'AND phot_g_mean_mag IS NOT NULL ORDER BY phot_g_mean_mag';
    final uri = Uri.https('gea.esac.esa.int', '/tap-server/tap/sync', {
      'REQUEST': 'doQuery',
      'LANG': 'ADQL',
      'FORMAT': 'csv',
      'QUERY': adql,
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw HttpException('Gaia DR3 星表查询返回 HTTP ${response.statusCode}。');
    }
    final lines = const LineSplitter().convert(response.body);
    if (lines.length < 2) return [];
    final result = <GaiaMatch>[];
    for (final line in lines.skip(1)) {
      final columns = _parseCsvRow(line);
      if (columns.length < 4) continue;
      final sourceId = columns[0];
      final ra = double.tryParse(columns[1]);
      final dec = double.tryParse(columns[2]);
      final magnitude = double.tryParse(columns[3]);
      if (sourceId.isEmpty || ra == null || dec == null || magnitude == null) continue;
      final (x, y) = wcs.worldToPixel(ra, dec);
      if (x >= 0 && x < analysis.width && y >= 0 && y < analysis.height) {
        result.add(
          GaiaMatch(
            sourceId: sourceId,
            ra: ra,
            dec: dec,
            x: x,
            y: y,
            gMagnitude: magnitude,
          ),
        );
      }
    }
    return result;
  }

  static Future<List<_CatalogObject>> _querySimbad(
    http.Client client,
    _Wcs wcs,
    SkyAnalysis analysis,
  ) async {
    final center = wcs.imageCenter;
    final radiusDegrees = (math.max(analysis.width, analysis.height) *
                wcs.arcsecPerPixel *
                0.8 /
                3600)
            .clamp(0.05, 5.0)
            .toDouble();
    final adql = 'SELECT TOP 2500 main_id, ra, dec, otype '
        'FROM basic WHERE 1=CONTAINS(POINT(\'ICRS\',ra,dec), '
        'CIRCLE(\'ICRS\',${center.$1},${center.$2},$radiusDegrees))';
    final uri = Uri.https('simbad.cds.unistra.fr', '/simbad/sim-tap/sync', {
      'REQUEST': 'doQuery',
      'LANG': 'ADQL',
      'FORMAT': 'csv',
      'QUERY': adql,
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw HttpException('SIMBAD 名称目录返回 HTTP ${response.statusCode}。');
    }
    final lines = const LineSplitter().convert(response.body);
    if (lines.isEmpty || lines.first.toLowerCase().contains('error')) {
      throw const FormatException('SIMBAD 名称目录无法解析查询结果。');
    }
    final objects = <_CatalogObject>[];
    for (final line in lines.skip(1)) {
      final columns = _parseCsvRow(line);
      if (columns.length < 4) continue;
      final ra = double.tryParse(columns[1]);
      final dec = double.tryParse(columns[2]);
      if (columns[0].isEmpty || ra == null || dec == null) continue;
      objects.add(_CatalogObject(columns[0], ra, dec, columns[3]));
    }
    return objects;
  }

  static _CatalogObject? _nearestSimbadStar(
    double ra,
    double dec,
    List<_CatalogObject> stars,
  ) {
    _CatalogObject? nearest;
    var closestArcsec = 5.0;
    for (final star in stars) {
      final distance = _angularDistanceArcsec(ra, dec, star.ra, star.dec);
      if (distance < closestArcsec) {
        closestArcsec = distance;
        nearest = star;
      }
    }
    return nearest;
  }

  static double _angularDistanceArcsec(
    double ra1,
    double dec1,
    double ra2,
    double dec2,
  ) {
    const radians = math.pi / 180;
    final deltaRa = _wrapRadians((ra1 - ra2) * radians);
    final deltaDec = (dec1 - dec2) * radians;
    final a = math.pow(math.sin(deltaDec / 2), 2) +
        math.cos(dec1 * radians) *
            math.cos(dec2 * radians) *
            math.pow(math.sin(deltaRa / 2), 2);
    return 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0))) / radians * 3600;
  }

  static List<String> _parseCsvRow(String line) {
    final fields = <String>[];
    final field = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final character = line[i];
      if (character == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (character == ',' && !quoted) {
        fields.add(field.toString().trim());
        field.clear();
      } else {
        field.write(character);
      }
    }
    fields.add(field.toString().trim());
    return fields;
  }

  static ({DetectedStar star, double distance})? _nearest(
      List<DetectedStar> stars, double x, double y) {
    final candidates = stars
        .where((star) => !star.isElongated && star.confidence >= 0.15);
    if (candidates.isEmpty) return null;
    DetectedStar? best;
    var distance = double.infinity;
    for (final star in candidates) {
      final current = math.sqrt(math.pow(star.x - x, 2) + math.pow(star.y - y, 2));
      if (current < distance) {
        distance = current;
        best = star;
      }
    }
    return best == null ? null : (star: best, distance: distance);
  }

  static double _median(List<double> sorted) {
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

class ModelSettings {
  const ModelSettings({
    required this.baseUrl,
    required this.lightKey,
    required this.lightModel,
    required this.strongKey,
    required this.strongModel,
  });

  final String baseUrl;
  final String lightKey;
  final String lightModel;
  final String strongKey;
  final String strongModel;
}

class ModelService {
  static Future<String> explain({
    required String baseUrl,
    required String lightKey,
    required String lightModel,
    required String strongKey,
    required String strongModel,
    required Map<String, Object?> report,
    required String question,
  }) async {
    final routeStrong = report['quality'] == '较弱' || report['solved'] == true;
    final models = <(String, String)>[
      if (routeStrong) (strongKey, strongModel) else (lightKey, lightModel),
      if (routeStrong && lightKey.isNotEmpty)
        (lightKey, lightModel)
      else if (!routeStrong && strongKey.isNotEmpty)
        (strongKey, strongModel),
    ];
    final client = http.Client();
    final errors = <String>[];
    try {
      for (final (key, model) in models) {
        if (key.trim().isEmpty || model.trim().isEmpty) continue;
        try {
          final uri = Uri.parse('${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions');
          final response = await client
              .post(
                uri,
                headers: {
                  'Authorization': 'Bearer ${key.trim()}',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({
                  'model': model.trim(),
                  'temperature': 0.3,
                  'messages': [
                    {
                      'role': 'system',
                      'content':
                          '你是面向爱好者的天文图像助手。只依据数据回答，明确区分目录确认、估算和未知；'
                              '不得把视觉背景说成 SQM/Bortle，也不得把仪器星等说成校准视星等。'
                              '简洁使用中文。',
                    },
                    {
                      'role': 'user',
                      'content':
                          '问题：${question.trim().isEmpty ? '请概括照片能确认的天文信息和可靠性。' : question.trim()}\n'
                              '图像分析 JSON：${jsonEncode(report)}',
                    },
                  ],
                }),
              )
              .timeout(const Duration(seconds: 45));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw HttpException('模型 API 返回 HTTP ${response.statusCode}。');
          }
          final decoded = jsonDecode(response.body) as Map<String, dynamic>;
          final content = decoded['choices']?[0]?['message']?['content'];
          if (content is! String || content.trim().isEmpty) {
            throw const FormatException('模型返回内容为空。');
          }
          return content.trim();
        } catch (error) {
          errors.add('$model：$error');
        }
      }
      throw StateError(errors.isEmpty ? '未配置可用模型。' : errors.join('\n'));
    } finally {
      client.close();
    }
  }
}

String formatRa(double degrees) {
  final hours = ((degrees % 360) / 15);
  final h = hours.floor();
  final minutes = (hours - h) * 60;
  final m = minutes.floor();
  final seconds = (minutes - m) * 60;
  return '${h.toString().padLeft(2, '0')}h ${m.toString().padLeft(2, '0')}m ${seconds.toStringAsFixed(1)}s';
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, this.icon);

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: _mint, size: 20),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ],
      );
}

class _MetricChip extends StatelessWidget {
  const _MetricChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF18263A),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('$label  $value', style: const TextStyle(fontSize: 12)),
      );
}

class _OrbitPainter extends CustomPainter {
  const _OrbitPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.75, size.height * 0.46);
    final random = math.Random(42);
    for (var i = 0; i < 46; i++) {
      final point = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = random.nextDouble() * 1.2 + 0.35;
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = Colors.white.withOpacity(random.nextDouble() * 0.38 + 0.08),
      );
    }
    final haloRect = Rect.fromCircle(center: center, radius: 74);
    canvas.drawCircle(
      center,
      75,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF8EF4DC).withOpacity(0.28),
            const Color(0xFF3BAA9C).withOpacity(0.12),
            Colors.transparent,
          ],
        ).createShader(haloRect),
    );
    canvas.drawCircle(
      center,
      43,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFB6F7E5), Color(0xFF49B8AA), Color(0xFF285D78)],
        ).createShader(haloRect),
    );
    final orbit = Paint()
      ..color = const Color(0x8892E8D5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.67,
        height: size.height * 0.44,
      ),
      orbit,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.84,
        height: size.height * 0.68,
      ),
      orbit..color = const Color(0x446C92BB),
    );
    final satellite = Offset(center.dx - size.width * 0.28, center.dy - 29);
    canvas.drawCircle(
      satellite,
      4,
      Paint()..color = const Color(0xFFFFDE77),
    );
    canvas.drawCircle(
      Offset(center.dx + 60, center.dy + 40),
      2.5,
      Paint()..color = const Color(0xFFEC99B3),
    );
    canvas.drawLine(
      Offset(size.width * 0.52, size.height * 0.28),
      Offset(size.width * 0.85, size.height * 0.14),
      Paint()
        ..color = Colors.white.withOpacity(0.48)
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _StarfieldPainter extends CustomPainter {
  const _StarfieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(31);
    for (var index = 0; index < 84; index++) {
      final point = Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );
      final radius = random.nextDouble() * 0.85 + 0.2;
      canvas.drawCircle(
        point,
        radius,
        Paint()..color = const Color(0xFFB8D6E8).withOpacity(random.nextDouble() * 0.2 + 0.025),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DetectedStarsPainter extends CustomPainter {
  const _DetectedStarsPainter({
    required this.analysis,
    required this.namedStars,
    required this.objects,
  });

  final SkyAnalysis analysis;
  final List<SkyObject> namedStars;
  final List<SkyObject> objects;

  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(analysis.width.toDouble(), analysis.height.toDouble()),
      size,
    );
    final destination = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final scaleX = destination.width / analysis.width;
    final scaleY = destination.height / analysis.height;
    final starPaint = Paint()
      ..color = _mint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final labelStyle = const TextStyle(
      color: Color(0xFFFFDE77),
      fontSize: 10,
      fontWeight: FontWeight.w600,
      shadows: [Shadow(color: Colors.black, blurRadius: 5)],
    );

    for (final star in analysis.stars.take(80)) {
      final point = Offset(
        destination.left + star.x * scaleX,
        destination.top + star.y * scaleY,
      );
      canvas.drawCircle(point, 3.5, starPaint);
      for (final named in namedStars) {
        if ((named.x - star.x).abs() < 0.01 &&
            (named.y - star.y).abs() < 0.01) {
          final label = TextPainter(
            text: TextSpan(text: named.name, style: labelStyle),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: destination.width * 0.55);
          label.paint(canvas, point + const Offset(5, -13));
        }
      }
    }

    final objectPaint = Paint()
      ..color = const Color(0xFFFF7B8C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final object in objects) {
      final point = Offset(
        destination.left + object.x * scaleX,
        destination.top + object.y * scaleY,
      );
      canvas.drawCircle(point, 9, objectPaint);
      final label = TextPainter(
        text: TextSpan(text: object.name, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: destination.width * 0.55);
      label.paint(canvas, point + const Offset(10, -7));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectedStarsPainter oldDelegate) =>
      !identical(analysis, oldDelegate.analysis) ||
      !identical(namedStars, oldDelegate.namedStars) ||
      !identical(objects, oldDelegate.objects);
}
