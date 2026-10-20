import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:astrosophy_core/analysis.dart';
import 'package:astrosophy_core/catalog.dart';
import 'package:astrosophy_core/deepsky.dart';
import 'package:astrosophy_core/ephemeris.dart';
import 'package:astrosophy_core/moon.dart';
import 'package:astrosophy_core/orbit.dart';
import 'package:astrosophy_core/solver.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

final _lastRequest = <int, DateTime>{};
Future<void> _queueTail = Future<void>.value();
var _queued = 0;
final _pendingCommands = <String, _PendingCommand>{};
final _pendingImages = <String, _PendingImage>{};
const _pendingTtl = Duration(minutes: 2);

/// AstroSophy 的 NapCat / OneBot 11 网关。
///
/// 真正的星点分析在 `packages/astrosophy_core`（纯 Dart），这里只做 QQ 消息、
/// 图片下载、命令路由和文本回复。
Future<void> main(List<String> args) async {
  final config = BotConfig.load();
  stdout.writeln('AstroSophy bot: ${config.wsUrl}');
  var retry = 1;
  while (true) {
    try {
      await _runSession(config);
      retry = 1;
      stdout.writeln('连接关闭，1 秒后重连…');
    } on Exception catch (error) {
      stdout.writeln('连接失败：$error');
      final wait = Duration(seconds: retry.clamp(1, 30));
      stdout.writeln('${wait.inSeconds} 秒后重试');
      await Future<void>.delayed(wait);
      retry++;
    }
  }
}

Future<void> _runSession(BotConfig config) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse(config.wsUrl),
    headers: config.accessToken.isEmpty
        ? null
        : {'Authorization': 'Bearer ${config.accessToken}'},
  );
  await channel.ready;
  var echo = 0;

  void send(String action, Map<String, Object?> params) {
    channel.sink.add(jsonEncode({
      'action': action,
      'params': params,
      'echo': '${echo++}',
    }));
  }

  void reply(int groupId, String text) {
    send('send_group_msg', {'group_id': groupId, 'message': text});
  }

  final done = Completer<void>();
  channel.stream.listen(
    (event) {
      try {
        final data = jsonDecode(event as String) as Map<String, Object?>;
        _handleEvent(data, config, reply);
      } on Exception catch (error) {
        stdout.writeln('消息解析失败：$error');
      }
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (Object error) {
      stdout.writeln('WebSocket 错误：$error');
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: false,
  );
  await done.future;
  await channel.sink.close();
}

void _handleEvent(
  Map<String, Object?> data,
  BotConfig config,
  void Function(int groupId, String text) reply,
) {
  if (data['post_type'] != 'message') return;
  if (data['message_type'] != 'group') return;
  final groupId = (data['group_id'] as num?)?.toInt();
  if (groupId == null) return;
  if (config.allowedGroups.isNotEmpty &&
      !config.allowedGroups.contains(groupId)) {
    return;
  }
  final raw = (data['raw_message'] as String? ?? '').trim();
  final userId = (data['user_id'] as num?)?.toInt() ?? 0;
  final key = '$groupId:$userId';
  final urls = _imageUrls(data['message']);
  if (raw.isEmpty && urls.isEmpty) return;
  stdout.writeln('[$groupId/$userId] $raw${urls.isEmpty ? '' : ' [${urls.length} 图]'}');

  // 清掉过期的两步操作。
  final now = DateTime.now();
  final pendingCommand = _pendingCommands[key];
  if (pendingCommand != null &&
      now.difference(pendingCommand.createdAt) > _pendingTtl) {
    _pendingCommands.remove(key);
  }
  final pendingImage = _pendingImages[key];
  if (pendingImage != null &&
      now.difference(pendingImage.createdAt) > _pendingTtl) {
    _pendingImages.remove(key);
  }

  if (raw == '/取消') {
    _pendingCommands.remove(key);
    _pendingImages.remove(key);
    reply(groupId, '已取消等待。');
    return;
  }

  if (raw == '/ping' || raw.startsWith('/ping ')) {
    reply(groupId, 'pong · AstroSophy');
    return;
  }
  if (raw == '/help' || raw.startsWith('/help ')) {
    reply(
      groupId,
      'AstroSophy 命令：\n'
      '/解析 然后发图片\n'
      '/月亮 然后发图片\n'
      '/太阳 然后发图片\n'
      '/天象 城市\n'
      '/取消 清除等待中的命令或图片',
    );
    return;
  }
  if (raw.startsWith('/天象')) {
    _replySky(groupId, raw.replaceFirst('/天象', '').trim(), reply);
    return;
  }

  final isImageCommand = raw.startsWith('/解析') ||
      raw.startsWith('/月亮') ||
      raw.startsWith('/太阳');
  if (isImageCommand) {
    final stored = _pendingImages.remove(key);
    final source = urls.isNotEmpty ? urls.first : stored?.url;
    if (source == null) {
      _pendingCommands[key] = _PendingCommand(raw, now);
      reply(groupId, '收到命令。请在 2 分钟内发图片；发 /取消 可撤销。');
      return;
    }
    _pendingCommands.remove(key);
    _submitImage(groupId, raw, source, reply, config);
    return;
  }

  if (urls.isNotEmpty) {
    final pending = _pendingCommands.remove(key);
    if (pending != null) {
      _submitImage(groupId, pending.command, urls.first, reply, config);
      return;
    }
    _pendingImages[key] = _PendingImage(urls.first, now);
    reply(groupId, '收到图片。请发 /解析、/月亮 或 /太阳；2 分钟内有效。');
  }
}

void _submitImage(
  int groupId,
  String command,
  String source,
  void Function(int groupId, String text) reply,
  BotConfig config,
) {
  final now = DateTime.now();
  final last = _lastRequest[groupId];
  if (last != null && now.difference(last).inSeconds < 20) {
    reply(groupId, '刚处理过一条，请等 ${20 - now.difference(last).inSeconds} 秒。');
    return;
  }
  _lastRequest[groupId] = now;
  final ahead = _queued;
  reply(groupId, ahead == 0 ? '收到图片，开始分析…' : '收到图片，前面还有 $ahead 个任务。');
  _enqueue(() => _analyzeAndReply(
        groupId,
        command,
        source,
        reply,
        config.maxImageMb,
      ));
}

class _PendingCommand {
  _PendingCommand(this.command, this.createdAt);

  final String command;
  final DateTime createdAt;
}

class _PendingImage {
  _PendingImage(this.url, this.createdAt);

  final String url;
  final DateTime createdAt;
}

void _enqueue(Future<void> Function() job) {
  _queued++;
  _queueTail = _queueTail.then((_) async {
    _queued--;
    try {
      await job();
    } on Exception catch (error) {
      stdout.writeln('任务失败：$error');
    }
  });
}

Future<void> _analyzeAndReply(
  int groupId,
  String command,
  String url,
  void Function(int groupId, String text) reply,
  int maxImageMb,
) async {
  try {
    final response = await _fetchImage(url).timeout(
          const Duration(seconds: 30),
        );
    final bytes = response;
    if (bytes.isEmpty || bytes.length > maxImageMb * 1024 * 1024) {
      reply(groupId, '图片为空或超过 $maxImageMb MB。');
      return;
    }
    final core = await _loadCore();
    final sun = command.startsWith('/太阳');
    final moon = command.startsWith('/月亮');
    final analysis = SkyAnalysis.analyze(
      bytes,
      detectMoon: moon,
      detectSun: sun,
      profile: StarDetectionProfile.normal,
    );
    if (sun) {
      final disc = analysis.sunDisc;
      reply(
        groupId,
        disc == null
            ? '没有检测到太阳圆盘。拍摄太阳请务必使用合格的太阳滤镜。'
            : '太阳盘面\n'
                '圆心 ${disc.centerX.toStringAsFixed(0)}, ${disc.centerY.toStringAsFixed(0)} px\n'
                '半径 ${disc.radiusPixels.toStringAsFixed(1)} px\n'
                '占画面 ${(disc.discAreaFraction * 100).toStringAsFixed(2)}%\n'
                '暗斑 ${disc.darkSpotCount} 处\n'
                '提醒：拍摄太阳必须使用合格太阳滤镜。',
      );
      return;
    }
    if (moon) {
      final disc = analysis.moonDisc;
      reply(
        groupId,
        disc == null
            ? '没有检测到月面。'
            : '月面\n'
                '圆心 ${disc.centerX.toStringAsFixed(0)}, ${disc.centerY.toStringAsFixed(0)} px\n'
                '半径 ${disc.radiusPixels.toStringAsFixed(1)} px\n'
                '亮面 ${(disc.illuminatedFraction * 100).toStringAsFixed(1)}%',
      );
      return;
    }
    final watch = Stopwatch()..start();
    final solve = core.solver.solve(
      analysis,
      hint: const SolveHint(
        budgetMilliseconds: 20000,
        patchSolve: true,
      ),
    );
    watch.stop();
    if (solve == null) {
      reply(
        groupId,
        '本机没能解开这片天区。\n'
        '检出 ${analysis.stars.length} 个点源，FWHM ${analysis.fwhm.toStringAsFixed(1)} px。\n'
        '可以试试更广的焦段，或在线解算。',
      );
      return;
    }
    reply(
      groupId,
      '解算成功（${watch.elapsed.inSeconds} s）\n'
      '中心 RA ${solve.centerRa.toStringAsFixed(3)}° / Dec ${solve.centerDec.toStringAsFixed(3)}°\n'
      '视场 ${solve.fieldOfViewDegrees.toStringAsFixed(2)}°\n'
      '像素比例 ${solve.arcsecPerPixel.toStringAsFixed(2)}″/px\n'
      '星表匹配 ${solve.matchedCount} 颗',
    );
  } on Exception catch (error) {
    reply(groupId, '分析失败：$error');
  }
}

void _replySky(
  int groupId,
  String city,
  void Function(int groupId, String text) reply,
) {
  final place = _cities[city] ?? _cities['北京']!;
  final utc = DateTime.now().toUtc();
  final jd = julianDay(utc);
  final d = jd - 2451545.0;
  final t = d / 36525.0;
  var gmst = 280.46061837 +
      360.98564736629 * d +
      0.000387933 * t * t -
      t * t * t / 38710000.0;
  gmst %= 360;
  final lst = (gmst + place.$2) % 360;
  final sun = sunPosition(utc);
  final sunAlt = _altitude(sun.ra, sun.dec, place.$1, lst);
  final phase = moonPhaseAt(utc);
  final moon = moonPositionAt(utc);
  final moonAlt = _altitude(moon.raDegrees, moon.decDegrees, place.$1, lst);
  final visible = <String>[];
  for (final body in predictedBodies(utc)) {
    final alt = _altitude(body.ra, body.dec, place.$1, lst);
    if (alt > 5) {
      visible.add('${body.name} 高度 ${alt.toStringAsFixed(0)}°');
    }
  }
  final lines = <String>[
    '天象 · ${place.$3}',
    '月相：${phase.name} ${phase.fractionLabel}'
        '${moonAlt > 0 ? ' · 月亮高度 ${moonAlt.toStringAsFixed(0)}°' : ' · 月亮在地平线下'}',
    '太阳高度：${sunAlt.toStringAsFixed(0)}°${sunAlt > 0 ? '（白天）' : ''}',
    if (visible.isEmpty) '此刻没有亮行星在地平线上。' else '可见行星：${visible.join('、')}',
  ];
  reply(groupId, lines.join('\n'));
}

double _altitude(double ra, double dec, double lat, double lst) {
  const rad = math.pi / 180;
  final hourAngle = (lst - ra) * rad;
  final d = dec * rad;
  final p = lat * rad;
  final sinAlt = math.sin(d) * math.sin(p) +
      math.cos(d) * math.cos(p) * math.cos(hourAngle);
  return math.asin(sinAlt.clamp(-1.0, 1.0)) / rad;
}

const _cities = <String, (double, double, String)>{
  '北京': (39.9042, 116.4074, '北京'),
  '上海': (31.2304, 121.4737, '上海'),
  '广州': (23.1291, 113.2644, '广州'),
  '深圳': (22.5431, 114.0579, '深圳'),
  '成都': (30.5728, 104.0668, '成都'),
  '西安': (34.3416, 108.9398, '西安'),
  '南京': (32.0603, 118.7969, '南京'),
  '杭州': (30.2741, 120.1551, '杭州'),
  '武汉': (30.5928, 114.3055, '武汉'),
  '重庆': (29.5630, 106.5516, '重庆'),
  '天津': (39.3434, 117.3616, '天津'),
  '昆明': (25.0389, 102.7183, '昆明'),
  '拉萨': (29.6520, 91.1721, '拉萨'),
  '乌鲁木齐': (43.8256, 87.6168, '乌鲁木齐'),
  '哈尔滨': (45.8038, 126.5350, '哈尔滨'),
  '三亚': (18.2528, 109.5119, '三亚'),
};

Future<Uint8List> _fetchImage(String source) async {
  if (source.startsWith('http://') || source.startsWith('https://')) {
    final response = await http.get(Uri.parse(source));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(source));
    }
    return response.bodyBytes;
  }
  final uri = Uri.tryParse(source);
  final file = uri != null && uri.scheme == 'file'
      ? File.fromUri(uri)
      : File(source);
  if (!file.existsSync()) {
    throw FileSystemException('图片文件不存在', source);
  }
  return file.readAsBytes();
}

List<String> _imageUrls(Object? message) {
  if (message is! List) return const [];
  final urls = <String>[];
  for (final segment in message) {
    if (segment is! Map || segment['type'] != 'image') continue;
    final data = segment['data'];
    if (data is! Map) continue;
    final url = data['url'] ?? data['file'];
    if (url is String &&
        (url.startsWith('http') ||
            url.startsWith('file://') ||
            File(url).existsSync())) {
      urls.add(url);
    }
  }
  return urls;
}

Future<_Core>? _coreFuture;
Future<_Core> _loadCore() => _coreFuture ??= _createCore();

Future<_Core> _createCore() async {
  final directory = _assetsDirectory();
  if (directory == null) {
    throw StateError('找不到 assets/catalog；设置 ASTRO_ASSETS');
  }
  final catalog = await StarCatalog.loadDirectory(directory);
  final deepSky = await DeepSkyCatalog.loadFile('$directory/deepsky.json');
  final solver = PlateSolver(catalog, deepSky: deepSky)..warmUp();
  return _Core(solver);
}

String? _assetsDirectory() {
  final env = Platform.environment['ASTRO_ASSETS'];
  final candidates = [
    if (env != null) env,
    'assets/catalog',
    '../assets/catalog',
    '../../assets/catalog',
  ];
  for (final path in candidates) {
    if (Directory(path).existsSync()) return path;
  }
  return null;
}

class _Core {
  const _Core(this.solver);

  final PlateSolver solver;
}

class BotConfig {
  const BotConfig({
    required this.wsUrl,
    required this.accessToken,
    required this.botName,
    required this.allowedGroups,
    required this.maxImageMb,
  });

  final String wsUrl;
  final String accessToken;
  final String botName;
  final Set<int> allowedGroups;
  final int maxImageMb;

  static BotConfig load() {
    final path = Platform.environment['ASTRO_BOT_CONFIG'] ?? 'config.json';
    Map<String, Object?> json = const {};
    final file = File(path);
    if (file.existsSync()) {
      json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }
    final envUrl = Platform.environment['NAPCAT_WS'];
    final envToken = Platform.environment['NAPCAT_TOKEN'];
    final groups = <int>{};
    final rawGroups = json['allowedGroups'];
    if (rawGroups is List) {
      for (final item in rawGroups) {
        if (item is num) groups.add(item.toInt());
      }
    }
    return BotConfig(
      wsUrl: envUrl ?? (json['wsUrl'] as String? ?? 'ws://127.0.0.1:3001'),
      accessToken: envToken ?? (json['accessToken'] as String? ?? ''),
      botName: json['botName'] as String? ?? 'AstroSophy',
      allowedGroups: groups,
      maxImageMb: (json['maxImageMb'] as num?)?.toInt() ?? 25,
    );
  }
}
