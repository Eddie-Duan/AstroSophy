import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'strings.dart';
import 'theme.dart';

/// 实时星图与 Nox 之间的读写接口。
///
/// 实时星图只暴露 [read] / [run]：以后接语音、接大模型时，只要换掉这两个
/// 回调，Nox 的界面和指令不用动。
class LiveNoxBridge {
  const LiveNoxBridge({
    required this.read,
    required this.run,
  });

  final Map<String, Object?> Function() read;
  final Future<String> Function(String command) run;
}

/// 实时星图里的轻量 Nox。文字和语音共用同一个 [LiveNoxBridge]。
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
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  bool _busy = false;
  bool _speechReady = false;
  bool _listening = false;
  bool _speakReplies = true;
  String _heard = '';

  @override
  void initState() {
    super.initState();
    _turns.add((
      text: t('我在。可以打字，也可以点麦克风。'),
      fromUser: false,
    ));
    _initVoice();
  }

  Future<void> _initVoice() async {
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.62);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    final ready = await _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'done' || status == 'notListening') {
          setState(() => _listening = false);
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _listening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('语音识别不可用：{0}', [error.errorMsg]))),
        );
      },
    );
    if (mounted) setState(() => _speechReady = ready);
  }

  @override
  void dispose() {
    _speech.stop();
    _tts.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send({String? preset, bool speak = false}) async {
    final command = (preset ?? _input.text).trim();
    if (command.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _busy = true;
      _heard = '';
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
    if (speak && _speakReplies) await _speak(reply);
  }

  Future<void> _speak(String text) async {
    var spoken = text.replaceAll(RegExp(r'[*_`#]'), '').replaceAll('\n', ' ').trim();
    if (spoken.isEmpty) return;
    // 语音只播结论；模型偶尔超长时，宁可截断也不要让用户站在寒风里听一分钟。
    if (spoken.length > 140) spoken = '${spoken.substring(0, 140)}…';
    await _tts.stop();
    await _tts.speak(spoken);
  }

  Future<void> _startListening() async {
    if (!_speechReady) {
      await _initVoice();
    }
    if (!_speechReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('麦克风或系统语音识别不可用。'))),
      );
      return;
    }
    setState(() {
      _heard = '';
      _listening = true;
    });
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'zh_CN',
        listenFor: const Duration(seconds: 8),
        pauseFor: const Duration(seconds: 2),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
      onResult: (result) {
        if (!mounted) return;
        final words = result.recognizedWords.trim();
        if (words.isEmpty) return;
        setState(() => _heard = words);
        if (result.finalResult) {
          _speech.stop();
          _send(preset: words, speak: true);
        }
      },
    );
  }

  Future<void> _stopListening() async {
    await _speech.stop();
    if (mounted) setState(() => _listening = false);
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
                    t('红光 {0} · 星名 {1}',
                        [snapshot['red'] == true ? '开' : '关', snapshot['labels'] == true ? '开' : '关']),
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF8192A8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_listening || _heard.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _listening ? t('正在听… {0}', [_heard]) : '“$_heard”',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8FE3C8),
                    ),
                  ),
                ),
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
                          label: Text(command, style: const TextStyle(fontSize: 11)),
                          onPressed: _busy ? null : () => _send(preset: command),
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
                  IconButton(
                    tooltip: _listening ? t('停止聆听') : t('语音'),
                    onPressed: _busy
                        ? null
                        : _listening
                            ? _stopListening
                            : _startListening,
                    icon: Icon(
                      _listening ? Icons.mic : Icons.mic_none,
                      color: _listening ? const Color(0xFFFF6B6B) : null,
                    ),
                  ),
                  IconButton(
                    tooltip: _speakReplies ? t('关闭播报') : t('开启播报'),
                    onPressed: () =>
                        setState(() => _speakReplies = !_speakReplies),
                    icon: Icon(
                      _speakReplies
                          ? Icons.volume_up_outlined
                          : Icons.volume_off_outlined,
                    ),
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
