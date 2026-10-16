import 'package:flutter/material.dart';

import 'strings.dart';
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
        title: Text(t('删除这条记录？')),
        content: Text(
          t('「{0}」的测量结果和两张图片会一起删掉，无法恢复。你手机相册里的原图不受影响。', [entry.name]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3455A)),
            child: Text(t('删除')),
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
          title: Text(t('观星仓库')),
          actions: [
            if (_totalBytes > 0)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(
                    t('占用 {0}', [formatBytes(_totalBytes)]),
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
          child: Text(t('读取历史记录失败：{0}', [_error]), textAlign: TextAlign.center),
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

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.nights_stay_outlined, size: 46, color: Color(0xFF46556B)),
              const SizedBox(height: 14),
              Text(t('还没有保存过观测记录')),
              const SizedBox(height: 8),
              Text(
                t('解析完一张星图之后点「保存」，就能在这里回看。'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF8192A8), fontSize: 12),
              ),
            ],
          ),
        ),
      );

  Widget _card(SavedAnalysis entry) => Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        // 描边颜色就是这一条的结论：解算出来了 / 只检测到星点 / 什么都没算
        // 出来。绿黄红是给一眼扫过用的，角标上的文字才是给认真看的人的——
        // 只靠颜色传达状态，色觉障碍用户就等于没有这个信息。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: outcomeColor(entry.outcome), width: 1.6),
        ),
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
                      left: 6,
                      top: 6,
                      child: _outcomeBadge(entry.outcome),
                    ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Row(
                        children: [
                          _roundButton(
                            Icons.edit_outlined,
                            t('重命名'),
                            () => _rename(entry),
                          ),
                          const SizedBox(width: 6),
                          _roundButton(
                            Icons.delete_outline,
                            t('删除'),
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
                      // 月面照片的点源数恒为零，写出来像是「什么都没拍到」；
                      // 换成那轮月亮的实际读数才说明得了这一条记录是什么。
                      entry.isMoon
                          ? _moonLine(entry)
                          : tn('{0} 个点源 · {1}', entry.starCount,
                              [entry.starCount, entry.quality]),
                      style: const TextStyle(color: Color(0xFFA6B5C8), fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.constellation ?? t(entry.outcome.label),
                      style: TextStyle(
                        color: entry.constellation == null
                            ? outcomeColor(entry.outcome)
                            : kMint,
                        fontSize: 11,
                      ),
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

  /// 月面记录那一行副标题。
  ///
  /// 亮面占比读不出来（老记录里没有月盘数据）时退回「月面照片」四个字，
  /// 不编一个数——这一行是给用户扫一眼用的，编出来的数会被当成量过的结果。
  String _moonLine(SavedAnalysis entry) {
    final fraction = entry.moonIlluminatedFraction;
    if (fraction == null) return t('月面照片 · {0}', [entry.quality]);
    return t('月面 · 亮面约 {0}% · {1}', [(fraction * 100).round(), entry.quality]);
  }

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
        title: Text(t('重命名')),
        content: TextFormField(
          initialValue: entry.name,
          autofocus: true,
          maxLength: 40,
          onChanged: (value) => draft = value,
          onFieldSubmitted: (value) => Navigator.of(context).pop(value),
          decoration: InputDecoration(
            labelText: t('记录名称'),
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(draft),
            child: Text(t('保存')),
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
        SnackBar(content: Text(t('已改名为「{0}」', [name.trim()]))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('重命名失败：{0}', [error]))),
      );
    }
  }

  /// 缩略图左上角的结论角标。
  Widget _outcomeBadge(RecordOutcome outcome) {
    final color = outcomeColor(outcome);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        t(outcome.label),
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
      ),
    );
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

/// 三档结论各自的颜色。
///
/// 挑的不是纯红绿黄：这套配色在深蓝底上要够亮、又能互相区分，同时明度接近，
/// 免得某一种颜色在缩略图上抢戏。绿色没用 `kMint`——它是整个 APP 的主色，
/// 满屏的薄荷绿卡片反而让「成功」不再特别。
Color outcomeColor(RecordOutcome outcome) => switch (outcome) {
      // 月面和「已解算」同一个颜色，理由见 [RecordOutcome.moon]：对用户来说
      // 这两种都是「这条记录有内容」，区别只在角标上的字。
      RecordOutcome.ok || RecordOutcome.moon => const Color(0xFF4FD1A5),
      RecordOutcome.partial => const Color(0xFFE8C36A),
      RecordOutcome.failed => const Color(0xFFE0708A),
    };

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
  if (solve == null) return t('未解算天区');
  return '${entry.constellation ?? t('未知星座')} · ${formatRa(solve.centerRa)}';
}
