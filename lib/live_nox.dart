import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'strings.dart';
import 'theme.dart';

/// 实时星图与 Nox 之间的读写接口。
///
/// 实时星图只暴露 [read] / [run]：语音、文字和大模型都走同一条命令入口。
class LiveNoxBridge {
  const LiveNoxBridge({
    required this.read,
    required this.run,
  });

  final Map<String, Object?> Function() read;
  final Future<String> Function(String command) run;
}

/// Nox 常驻语音模式。
///
/// 点亮点亮 Nox 图标后开始监听唤醒词“嘿 Nox”；听到之后进入一次命令窗口，
/// 执行完继续回到唤醒监听。超过 [idleTimeout] 没有交互就自动关闭，避免
/// 麦克风一直开着耗电。
class LiveNoxVoiceEngine {
  LiveNoxVoiceEngine({
    required this.onCommand,
    required this.onStateChanged,
    required this.onActiveChanged,
    required this.onError,
    this.idleTimeout = const Duration(minutes: 2),
  });

  final Future<String> Function(String command) onCommand;
  final void Function(String state) onStateChanged;
  final void Function(bool active) onActiveChanged;
  final void Function(String message) onError;
  final Duration idleTimeout;

  final _speech = SpeechToText();
  final _tts = FlutterTts();
  Timer? _restartTimer;
  Timer? _idleTimer;
  bool _active = false;
  bool _paused = false;
  bool _listening = false;
  bool _busy = false;
  bool _transitioning = false;
  bool _onDevice = true;

  bool get active => _active;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    onActiveChanged(true);
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.62);
    await _tts.setPitch(1.0);
    final ready = await _speech.initialize(
      onStatus: _onStatus,
      onError: (error) {
        final message = error.errorMsg;
        // 有 WiFi 也会 network_error：识别服务不在本机，或者服务端不可达。
        // 先试设备端识别；设备端没模型再退回系统在线识别。
        if (_onDevice &&
            (message.contains('network') ||
                message.contains('Network') ||
                message.contains('not available') ||
                message.contains('unavailable'))) {
          _onDevice = false;
          onError(t('设备端语音识别不可用，已尝试切回系统在线识别。'));
          _scheduleRestart();
          return;
        }
        onError(t('语音识别出错：{0}', [message]));
      },
    );
    if (!ready) {
      await stop();
      onError(t('系统语音识别不可用，请检查麦克风权限或语音服务。'));
      return;
    }
    _armIdle();
    await _listenWake();
  }

  Future<void> pause() async {
    _paused = true;
    _restartTimer?.cancel();
    await _speech.stop();
    _listening = false;
  }

  Future<void> resume() async {
    if (!_active) return;
    _paused = false;
    _armIdle();
    await _listenWake();
  }

  Future<void> stop() async {
    _active = false;
    _restartTimer?.cancel();
    _idleTimer?.cancel();
    await _speech.stop();
    await _tts.stop();
    _listening = false;
    onActiveChanged(false);
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () async {
      if (!_active) return;
      await stop();
    });
  }

  void _scheduleRestart() {
    _restartTimer?.cancel();
    _restartTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_active || _paused || _busy || _listening) return;
      _listenWake();
    });
  }

  void _onStatus(String status) {
    _listening = false;
    if (!_active || _paused || _busy || _transitioning) return;
    if (status == 'done' || status == 'notListening') {
      _restartTimer?.cancel();
      _restartTimer = Timer(const Duration(milliseconds: 350), () {
        if (!_active || _paused || _busy || _listening) return;
            _listenWake();
      });
    }
  }

  Future<void> _listenWake() async {
    if (!_active || _paused || _listening) return;
    _listening = true;
    onStateChanged(t('等你说“嘿 Nox”'));
    try {
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: 'zh_CN',
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 6),
          partialResults: true,
          cancelOnError: true,
          onDevice: _onDevice,
          listenMode: ListenMode.confirmation,
        ),
        onResult: (result) {
          if (!result.finalResult) return;
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          final normalized =
              words.toLowerCase().replaceAll(RegExp(r'[\s,，。.!！?？]'), '');
          final match = RegExp(r'(嘿|黑|hey|hi)(nox|诺克斯|nocks)(.*)')
              .firstMatch(normalized);
          if (match == null) return;
          final rest = (match.group(3) ?? '').trim();
          _armIdle();
          if (rest.isNotEmpty) {
            unawaited(_takeCommand(rest));
          } else {
            unawaited(_enterCommand());
          }
        },
      );
    } catch (error) {
      _listening = false;
      if (_onDevice) {
        _onDevice = false;
        onError(t('设备端语音识别不可用，已尝试切回系统在线识别。'));
        _scheduleRestart();
      } else {
        onError(t('无法启动语音识别：{0}', [error]));
      }
    }
  }

  Future<void> _enterCommand() async {
    _transitioning = true;
    await _speech.stop();
    _listening = false;
    _transitioning = false;
    onStateChanged(t('我在，说命令'));
    await _listenCommand();
  }

  Future<void> _takeCommand(String command) async {
    _transitioning = true;
    await _speech.stop();
    _listening = false;
    _transitioning = false;
    await _execute(command);
  }

  Future<void> _listenCommand() async {
    if (!_active || _paused) return;
    _listening = true;
    try {
      await _speech.listen(
        listenOptions: SpeechListenOptions(
          localeId: 'zh_CN',
          listenFor: const Duration(seconds: 8),
          pauseFor: const Duration(seconds: 2),
          partialResults: true,
          cancelOnError: true,
          onDevice: _onDevice,
          listenMode: ListenMode.dictation,
        ),
        onResult: (result) {
          if (!result.finalResult) return;
          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;
          unawaited(_takeCommand(words));
        },
      );
    } catch (error) {
      _listening = false;
      if (_onDevice) {
        _onDevice = false;
        onError(t('设备端语音识别不可用，已尝试切回系统在线识别。'));
        _scheduleRestart();
      } else {
        onError(t('命令识别失败：{0}', [error]));
      }
    }
  }

  Future<void> _execute(String command) async {
    if (_busy) return;
    _busy = true;
    onStateChanged(t('正在处理：{0}', [command]));
    final reply = await onCommand(command);
    await _speak(reply);
    _busy = false;
    _armIdle();
    await _listenWake();
  }

  Future<void> _speak(String text) async {
    var spoken = text
        .replaceAll(RegExp(r'[*_`#]'), '')
        .replaceAll('\n', ' ')
        .trim();
    if (spoken.isEmpty) return;
    if (spoken.length > 140) spoken = '${spoken.substring(0, 140)}…';
    await _tts.stop();
    await _tts.speak(spoken);
  }
}

/// 实时星图里的文字 Nox，语音模式下的辅助输入。
class LiveNoxPanel extends StatefulWidget {
  const LiveNoxPanel({super.key, required this.bridge});

  final LiveNoxBridge bridge;

  @override
  State<LiveNoxPanel> createState() => _LiveNoxPanelState();
}

class _LiveNoxPanelState extends State<LiveNoxPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <({String text, bool fromUser})>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _turns.add((text: t('我在。可以打字，也可以直接说“嘿 Nox”。'), fromUser: false));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final command = (preset ?? _input.text).trim();
    if (command.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _busy = true;
      _turns.add((text: command, fromUser: true));
    });
    _scrollDown();
    final reply = await widget.bridge.run(command);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _turns.add((text: reply, fromUser: false));
    });
    _scrollDown();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.bridge.read();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 6,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: SizedBox(
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.nightlight_round, size: 18, color: kMint),
                  const SizedBox(width: 7),
                  const Text(
                    'Nox',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    t('红光 {0} · 星名 {1}', [
                      snapshot['red'] == true ? t('开') : t('关'),
                      snapshot['labels'] == true ? t('开') : t('关'),
                    ]),
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF8192A8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _turns.length,
                  itemBuilder: (context, index) {
                    final turn = _turns[index];
                    return Align(
                      alignment: turn.fromUser
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: turn.fromUser
                              ? kMint.withValues(alpha: 0.16)
                              : const Color(0xFF1A2636),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          turn.text,
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final command in const [
                      '状态',
                      '红光',
                      '银河',
                      '星座',
                      '星名',
                      '地平线',
                      '锁定',
                      '取消目标',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          label: Text(
                            command,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed:
                              _busy ? null : () => _send(command),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_busy,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: t('问 Nox，例如：找木星'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: t('发送'),
                    onPressed: _busy ? null : () => _send(),
                    icon: const Icon(Icons.send, size: 18),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
