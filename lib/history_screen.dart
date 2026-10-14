import 'package:flutter/material.dart';

import 'history.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets.dart';

/// 历史记录列表。
///
/// 这一页只做两件事：把存下来的记录摊开给用户看，以及让他删掉不想要的。
/// 打开某一条时把记录整个 pop 回主界面，由主界面负责切过去——历史页不该
/// 知道主界面长什么样，否则两边的状态迟早会打架。
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.store});

  final HistoryStore store;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<SavedAnalysis>? _entries;
  int _totalBytes = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await widget.store.list();
      final total = await widget.store.totalBytes();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _totalBytes = total;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _confirmDelete(SavedAnalysis entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: Text(
          '「${entry.name}」的测量结果和两张图片会一起删掉，无法恢复。'
          '你手机相册里的原图不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3455A)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.store.delete(entry);
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('观星记录'),
          actions: [
            if (_totalBytes > 0)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    '占用 ${formatBytes(_totalBytes)}',
                    style: const TextStyle(color: Color(0xFF8192A8), fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              const Positioned.fill(child: CustomPaint(painter: StarfieldPainter())),
              _body(),
            ],
          ),
        ),
      );

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('读取历史记录失败：$_error', textAlign: TextAlign.center),
        ),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) return _emptyState();
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.68,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) => _card(entries[index]),
    );
  }

  Widget _emptyState() => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.nights_stay_outlined, size: 46, color: Color(0xFF46556B)),
              SizedBox(height: 14),
              Text('还没有保存过观测记录'),
              SizedBox(height: 8),
              Text(
                '解析完一张星图之后点「保存」，就能在这里回看。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF8192A8), fontSize: 12),
              ),
            ],
          ),
        ),
      );

  Widget _card(SavedAnalysis entry) => Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(entry),
          onLongPress: () => _confirmDelete(entry),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 预览图是分析时缩放过的版本，不是原图——原图在用户自己的
                    // 相册里，这里存一份只是为了让列表能看着图认得出是哪张。
                    Image.file(
                      entry.imageFile,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const MissingImage(compact: true),
                    ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Row(
                        children: [
                          _roundButton(
                            Icons.edit_outlined,
                            '重命名',
                            () => _rename(entry),
                          ),
                          const SizedBox(width: 6),
                          _roundButton(
                            Icons.delete_outline,
                            '删除',
                            () => _confirmDelete(entry),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${entry.starCount} 个点源 · ${entry.quality}',
                      style: const TextStyle(color: Color(0xFFA6B5C8), fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.constellation ?? '未解算',
                      style: const TextStyle(color: kMint, fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatSavedAt(entry.savedAt),
                      style: const TextStyle(color: Color(0xFF8192A8), fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  /// 改名。
  ///
  /// 用 [TextFormField] 的 `initialValue` 而不是自己拿一个 `TextEditingController`：
  /// 对话框的退场动画还没跑完时控件仍然挂在树上，这时候 dispose 掉控制器
  /// 会踩到「用了已释放的控制器」。让 FormField 自己管自己的状态就没这回事。
  Future<void> _rename(SavedAnalysis entry) async {
    var draft = entry.name;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextFormField(
          initialValue: entry.name,
          autofocus: true,
          maxLength: 40,
          onChanged: (value) => draft = value,
          onFieldSubmitted: (value) => Navigator.of(context).pop(value),
          decoration: const InputDecoration(
            labelText: '记录名称',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await widget.store.rename(entry, name);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已改名为「${name.trim()}」')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重命名失败：$error')),
      );
    }
  }

  /// 卡片右上角那排圆形小按钮：改名、删除。共用一套样式，免得两处各写一份
  /// 半透明的黑底圆。
  Widget _roundButton(IconData icon, String tooltip, VoidCallback onTap) =>
      Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(icon, size: 17),
            ),
          ),
        ),
      );
}

/// 「2026-10-14 22:39」。列表里不写秒——同一分钟内保存两条，一眼分不出
/// 也没什么关系，而多两个数字会让日期更难扫。
String formatSavedAt(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// 把星座名和坐标写成一行摘要，历史详情和主界面都用得上。
String describeSavedTarget(SavedAnalysis entry) {
  final solve = entry.solve;
  if (solve == null) return '未解算天区';
  return '${entry.constellation ?? '未知星座'} · ${formatRa(solve.centerRa)}';
}
