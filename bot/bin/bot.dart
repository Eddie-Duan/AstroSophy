import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:astrosophy_core/analysis.dart';
import 'package:astrosophy_core/catalog.dart';
import 'package:astrosophy_core/deepsky.dart';
import 'package:astrosophy_core/solver.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

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
  final urls = _imageUrls(data['message']);
  if (raw.isEmpty && urls.isEmpty) return;
  stdout.writeln('[$groupId] $raw${urls.isEmpty ? '' : ' [${urls.length} 图]'}');

  if (raw == '/ping' || raw.startsWith('/ping ')) {
    reply(groupId, 'pong · AstroSophy');
    return;
  }
  if (raw == '/help' || raw.startsWith('/help ')) {
    reply(
      groupId,
      'AstroSophy 命令：\n'
      '/ping 检查在线\n'
      '/解析 + 图片 分析星图\n'
      '/月亮 + 图片 月面信息\n'
      '/太阳 + 图片 日面信息\n'
      '/天象 城市 今晚可见天体',
    );
    return;
  }
  if (raw.startsWith('/解析') || raw.startsWith('/月亮') || raw.startsWith('/太阳')) {
    if (urls.isEmpty) {
      reply(groupId, '请把照片和命令放在同一条消息里。');
      return;
    }
    reply(groupId, '收到图片，开始分析…');
    unawaited(_analyzeAndReply(groupId, raw, urls.first, reply));
    return;
  }
  if (raw.startsWith('/天象')) {
    reply(groupId, '天象查询还没接入。');
  }
}

Future<void> _analyzeAndReply(
  int groupId,
  String command,
  String url,
  void Function(int groupId, String text) reply,
) async {
  try {
    final response = await http.get(Uri.parse(url)).timeout(
          const Duration(seconds: 30),
        );
    if (response.statusCode != 200) {
      reply(groupId, '图片下载失败：HTTP ${response.statusCode}');
      return;
    }
    final bytes = response.bodyBytes;
    if (bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
      reply(groupId, '图片为空或超过 25 MB。');
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

List<String> _imageUrls(Object? message) {
  if (message is! List) return const [];
  final urls = <String>[];
  for (final segment in message) {
    if (segment is! Map || segment['type'] != 'image') continue;
    final data = segment['data'];
    if (data is! Map) continue;
    final url = data['url'] ?? data['file'];
    if (url is String && url.startsWith('http')) urls.add(url);
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
