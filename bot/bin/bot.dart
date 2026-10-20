import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

/// AstroSophy 的 NapCat / OneBot 11 网关。
///
/// 这一步只负责“连上 QQ、收消息、回消息”，不碰星点分析。等 `astrosophy_core`
/// 从 Flutter 工程里拆出来之后，`/解析` 再调用核心；这样 bot 可以先独立跑通。
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
  final message = data['message'];
  final hasImage = message is List &&
      message.any((segment) =>
          segment is Map && segment['type'] == 'image');
  if (raw.isEmpty && !hasImage) return;
  stdout.writeln('[$groupId] $raw${hasImage ? ' [图片]' : ''}');

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
    if (!hasImage) {
      reply(groupId, '请把照片和命令放在同一条消息里。');
      return;
    }
    // 核心接入点：后续在这里下载图片，交给 astrosophy_core。
    reply(groupId, '收到图片。分析核心还没接入，这一步目前只验证 NapCat 链路。');
    return;
  }
  if (raw.startsWith('/天象')) {
    reply(groupId, '天象查询还没接入。');
  }
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
