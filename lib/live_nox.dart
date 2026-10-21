import 'package:flutter/material.dart';

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
    this.onVoice,
  });

  final Map<String, Object?> Function() read;
  final Future<String> Function(String command) run;
  final Future<void> Function()? onVoice;
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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _turns.add((
      text: t('我在。可以打字，也可以点麦克风。'),
      fromUser: false,
    ));
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

  Future<void> _voice() async {
    final voice = widget.bridge.onVoice;
    if (voice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('语音接口还没接上。'))),
      );
      return;
    }
    await voice();
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
                          onPressed: _busy ? null : () => _send(command),
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
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.send, size: 18),
                  ),
                  IconButton(
                    tooltip: t('语音'),
                    onPressed: _busy ? null : _voice,
                    icon: const Icon(Icons.mic_none),
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
