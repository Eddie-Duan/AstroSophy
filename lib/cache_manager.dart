import 'package:flutter/material.dart';

import 'pipeline.dart';
import 'solver.dart';
import 'strings.dart';
import 'theme.dart';

/// 三层星表索引的缓存管理。
///
/// 现在缓存的是**当前后台 isolate 里的索引**：预处理完这一轮解析就不用再
/// 现建表。它不会跨 App 重启保存，界面里把这句话写明，避免用户误以为落盘了。
class CacheManagerSheet extends StatefulWidget {
  const CacheManagerSheet({super.key, required this.worker});

  final SkyWorker worker;

  @override
  State<CacheManagerSheet> createState() => _CacheManagerSheetState();
}

class _CacheManagerSheetState extends State<CacheManagerSheet> {
  CatalogCacheStatus? _status;
  int? _busy;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await widget.worker.cacheStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('读取缓存状态失败：{0}', [error]))),
      );
    }
  }

  Future<void> _prepare(int level) async {
    setState(() => _busy = level);
    try {
      final status = await widget.worker.prepareCache(level);
      if (!mounted) return;
      setState(() {
        _status = status;
        _busy = null;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('预处理失败：{0}', [error]))),
      );
    }
  }

  Future<void> _prepareAll() async {
    for (final level in const [0, 1, 2]) {
      if (!mounted) return;
      await _prepare(level);
      if (_status == null) return;
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = -1);
    try {
      final status = await widget.worker.clearCache();
      if (!mounted) return;
      setState(() {
        _status = status;
        _busy = null;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _busy = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('清除缓存失败：{0}', [error]))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('缓存管理'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              t('把三层星表索引提前建好，解析时就不用现建表。预处理只在本次 App 运行内有效；重启后需要重新预处理。'),
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Color(0xFFA6B5C8),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _layerRow(0, t('浅层'), t('Hipparcos 亮星'), status?.shallow),
              _layerRow(1, t('中层'), t('Gaia G < 9 补充'), status?.mid),
              _layerRow(2, t('深层'), t('整张 Gaia 星表'), status?.deep),
              const SizedBox(height: 10),
              Text(
                _busy == null
                    ? t('选择某一层单独预处理，或一次预处理全部。')
                    : _busy == -1
                        ? t('正在清除…')
                        : t('正在预处理{0}，深层可能需要一分钟…',
                            [_busy == 0 ? t('浅层') : _busy == 1 ? t('中层') : t('深层')]),
                style: const TextStyle(fontSize: 11, color: Color(0xFF8192A8)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy == null ? _prepareAll : null,
                      icon: const Icon(Icons.download_done, size: 17),
                      label: Text(t('全部预处理')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy == null ? _clear : null,
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: Text(t('清除')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _layerRow(int level, String title, String subtitle, bool? ready) {
    final isBusy = _busy == level;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ready == true ? Icons.check_circle : Icons.radio_button_unchecked,
        color: ready == true ? kMint : const Color(0xFF8192A8),
      ),
      title: Text(title),
      subtitle: Text(
        ready == true ? t('已预处理') : t('未预处理 · {0}', [subtitle]),
        style: const TextStyle(fontSize: 11),
      ),
      trailing: isBusy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: _busy == null && ready != true
                  ? () => _prepare(level)
                  : null,
              child: Text(t('预处理')),
            ),
    );
  }
}
