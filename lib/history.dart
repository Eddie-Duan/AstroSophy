import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'analysis.dart';
import 'models.dart';

/// 一条保存下来的观星记录。
///
/// 列表页需要的东西（星数、质量、星座、时间）在存档里单独存了一份，打开
/// 某一条时才把完整的测量结果解出来。原因只有一个：预览图是几十到几百 KB
/// 的 JPEG，历史攒到几十条以后，每次进列表都把全部图片和星点读进内存，
/// 白白吃掉几十兆——而列表页只拿文件路径交给 `Image.file` 懒加载就够了。
class SavedAnalysis {
  const SavedAnalysis({
    required this.id,
    required this.name,
    required this.savedAt,
    required this.quality,
    required this.starCount,
    required this.constellation,
    required this.solve,
    required this.explanation,
    required this.imageFile,
    required this.processedFile,
    required Map<String, Object?> rawAnalysis,
    this.isStarfield = true,
  }) : _rawAnalysis = rawAnalysis;

  final String id;

  /// 原图文件名（或演示图标题），列表里用来辨认「这是哪一张」。
  final String name;

  final DateTime savedAt;
  final String quality;
  final int starCount;

  /// 视场中心所在的星座；没解算时为空。
  final String? constellation;

  final SolveResult? solve;
  final String? explanation;

  /// 预览图（分析时的缩放版原图）。
  final File imageFile;

  /// 处理图（扣除背景、只留星场）。
  final File processedFile;

  final Map<String, Object?> _rawAnalysis;

  /// 存下这一条时，那张图整体看起来是不是星空照片。
  ///
  /// 老记录里没有这个字段（那时候还没存），缺省按「有星点就算星空」兜底，
  /// 见 [_decode]。
  final bool isStarfield;

  /// 这一条算得怎么样。历史列表据此给卡片描边，让用户一眼分出「这张解出来了」
  /// 和「这张什么都没算出来」。
  ///
  /// 分三档而不是两档，是因为中间那一档最容易被误解：星点检测到了、天区没
  /// 解算出来，既不是成功也不是失败，用户需要知道「图有用，只是没定位」。
  RecordOutcome get outcome {
    if (!isStarfield || starCount == 0) return RecordOutcome.failed;
    return solve == null ? RecordOutcome.partial : RecordOutcome.ok;
  }

  /// 把完整的测量结果读出来。
  ///
  /// 要读文件，所以是异步的——列表页不该为了这个付出代价。
  Future<SkyAnalysis> readAnalysis() async {
    return SkyAnalysis.fromJson(
      _rawAnalysis,
      preview: await _readOrEmpty(imageFile),
      processedPreview: await _readOrEmpty(processedFile),
    );
  }

  /// 记录占用的磁盘空间（两张图和一份 JSON）。
  int get byteSize =>
      _sizeOf(imageFile) + _sizeOf(processedFile) + _sizeOf(_jsonFile);

  File get _jsonFile => File(p.join(imageFile.parent.path, '$id.json'));

  static int _sizeOf(File file) => file.existsSync() ? file.lengthSync() : 0;

  static Future<Uint8List> _readOrEmpty(File file) async =>
      file.existsSync() ? await file.readAsBytes() : Uint8List(0);
}

/// 一条记录的解析结果，历史列表用它给卡片描边。
enum RecordOutcome {
  /// 天区解算成功，坐标、星表、测光都有。
  ok('已解算'),

  /// 星点检测成功，但天区没解算出来——图还是有用的，只是不知道拍的是哪儿。
  partial('仅检测到星点'),

  /// 几乎没检出星点，或者那张图根本不像星空照片。
  failed('未能解析');

  const RecordOutcome(this.label);

  final String label;
}

/// 历史记录的读写。
///
/// 目录结构：`{应用文档目录}/astrosophy/saved/` 下每条记录三个文件——
/// `<id>.jpg` 预览图、`<id>_processed.jpg` 处理图、`<id>.json` 全部测量结果。
///
/// **不额外维护一个索引文件**：列表就是把目录列出来、把每份 JSON 读一遍。
/// 索引文件看着省事，但它和真实文件之间迟早会不一致——用户删了一张图却没
/// 删掉索引项，或者写到一半掉电，界面就会显示一条点不开的记录。目录本身
/// 永远不会和自己不一致，慢一点也值得。真到了要优化的时候，正确的做法是
/// 加一份「可以从目录重建」的缓存，而不是让索引变成事实来源。
class HistoryStore {
  HistoryStore._(this.directory);

  final Directory directory;

  /// 打开历史目录，不存在就建。传 [root] 是为了测试能指到临时目录。
  static Future<HistoryStore> open({Directory? root}) async {
    final base = root ?? await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(base.path, 'astrosophy', 'saved'));
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    return HistoryStore._(directory);
  }

  /// 全部记录，最近保存的排在前面。
  ///
  /// 单个文件读坏了不会让整张列表打不开：坏的那条跳过，其余的照常显示。
  /// 一条记录格式出问题就丢掉全部历史，是最糟糕的失败方式。
  Future<List<SavedAnalysis>> list() async {
    if (!directory.existsSync()) return const [];
    final entries = <SavedAnalysis>[];
    await for (final item in directory.list()) {
      if (item is! File || !item.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await item.readAsString());
        if (decoded is! Map) continue;
        entries.add(_decode(Map<String, Object?>.from(decoded), item));
      } catch (_) {
        // 坏掉的那条跳过就好，没必要连累别人。
        continue;
      }
    }
    entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  /// 保存一条记录，返回落盘后的结果。
  ///
  /// 写入顺序是刻意的：先写两张图，最后写 JSON。列表只认 JSON，所以中途
  /// 失败（磁盘满、进程被杀）只会留下一堆没人引用的图片，不会在历史里
  /// 出现一条点开是空的记录。
  Future<SavedAnalysis> save({
    required String name,
    required SkyAnalysis analysis,
    required SolveResult? solve,
    required String? explanation,
    DateTime? savedAt,
  }) async {
    final at = savedAt ?? DateTime.now();
    final id = _availableId(at);

    final imageFile = File(p.join(directory.path, '$id.jpg'));
    final processedFile = File(p.join(directory.path, '${id}_processed.jpg'));
    final jsonFile = File(p.join(directory.path, '$id.json'));

    await imageFile.writeAsBytes(analysis.preview, flush: true);
    await processedFile.writeAsBytes(analysis.processedPreview, flush: true);

    final rawAnalysis = analysis.toJson();
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'id': id,
        'name': name,
        'saved_at': at.toIso8601String(),
        // 列表页要用的几个数字单独存一份，省得为了显示一行摘要去解析整份
        // 测量结果。
        'summary': {
          'quality': analysis.quality,
          'star_count': analysis.compactSources.length,
          'constellation': _firstOrNull(solve?.constellations),
          'solved': solve != null,
          // 星空判定也要留在摘要里：历史列表要分「解算成功 / 只是检测到星点 /
          // 这压根不像星空」三档，而一二档的区别只看 solved，二三档得看它。
          'starfield': analysis.isLikelyStarfield,
        },
        'analysis': rawAnalysis,
        'solve': solve?.toJson(),
        'explanation': explanation,
      }),
      flush: true,
    );

    return SavedAnalysis(
      id: id,
      name: name,
      savedAt: at,
      quality: analysis.quality,
      starCount: analysis.compactSources.length,
      constellation: _firstOrNull(solve?.constellations),
      solve: solve,
      explanation: explanation,
      imageFile: imageFile,
      processedFile: processedFile,
      rawAnalysis: rawAnalysis,
      isStarfield: analysis.isLikelyStarfield,
    );
  }

  /// 改一条记录的名字。
  ///
  /// 只动 JSON 里的 `name` 字段，图片和 id 一概不碰。改名是「我想把它叫成
  /// 什么」，不是「换一条记录」：id 一变，两个图片文件名都得跟着搬，为了
  /// 一个名字去挪几十兆的图，还可能在中途失败时留下半搬完的状态。
  ///
  /// 名字去掉首尾空白后为空就是没改（一条无名的记录在列表里认不出来），
  /// 这时按原样返回，不写盘。
  Future<SavedAnalysis> rename(SavedAnalysis entry, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == entry.name) return entry;

    final jsonFile = File(p.join(directory.path, '${entry.id}.json'));
    final decoded = jsonDecode(await jsonFile.readAsString());
    if (decoded is! Map) throw const FormatException('记录文件格式不对。');
    final json = Map<String, Object?>.from(decoded);
    json['name'] = trimmed;
    // 用和保存时同一个编码器写回：缩进一致，键的顺序也不变，用户拿文件
    // 对比时不会看到一堆无意义的改动。
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      flush: true,
    );

    return SavedAnalysis(
      id: entry.id,
      name: trimmed,
      savedAt: entry.savedAt,
      quality: entry.quality,
      starCount: entry.starCount,
      constellation: entry.constellation,
      solve: entry.solve,
      explanation: entry.explanation,
      imageFile: entry.imageFile,
      processedFile: entry.processedFile,
      rawAnalysis: entry._rawAnalysis,
      // 改个名字不能顺手把「这张解没解出来」也一起丢了，卡片描边的颜色
      // 全靠它。
      isStarfield: entry.isStarfield,
    );
  }

  /// 删除一条记录。图片和 JSON 一起删——只删 JSON 会留下没人认领的图片，
  /// 用户看着「历史空了但存储还是满的」，找不到原因。
  Future<void> delete(SavedAnalysis entry) async {
    for (final file in [
      entry.imageFile,
      entry.processedFile,
      File(p.join(directory.path, '${entry.id}.json')),
    ]) {
      if (file.existsSync()) await file.delete();
    }
  }

  /// 全部记录占用的空间。
  Future<int> totalBytes() async {
    if (!directory.existsSync()) return 0;
    var total = 0;
    await for (final item in directory.list()) {
      if (item is File) total += await item.length();
    }
    return total;
  }

  /// 文件名带上时间，人翻目录的时候能直接看出这是哪一次拍摄。
  /// 同一毫秒里保存两次就往后排一个号——虽然按钮在保存期间是禁用的，
  /// 但这里多做一步几乎不要钱，而撞名意味着两张图互相覆盖。
  String _availableId(DateTime at) {
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${at.year}${two(at.month)}${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}${two(at.second)}'
        '-${at.millisecond.toString().padLeft(3, '0')}';
    var candidate = stamp;
    var suffix = 2;
    while (File(p.join(directory.path, '$candidate.json')).existsSync()) {
      candidate = '$stamp-$suffix';
      suffix++;
    }
    return candidate;
  }

  SavedAnalysis _decode(Map<String, Object?> json, File source) {
    final id =
        json['id'] as String? ?? p.basenameWithoutExtension(source.path);
    final rawAnalysis = json['analysis'];
    if (rawAnalysis is! Map) {
      throw const FormatException('记录缺少测量结果。');
    }
    final summary = json['summary'] is Map
        ? Map<String, Object?>.from(json['summary']! as Map)
        : const <String, Object?>{};
    final solve = json['solve'] is Map
        ? SolveResult.fromJson(Map<String, Object?>.from(json['solve']! as Map))
        : null;
    final parent = source.parent.path;
    final starCount = _asInt(summary['star_count']);
    return SavedAnalysis(
      id: id,
      name: json['name'] as String? ?? '未命名',
      savedAt:
          DateTime.tryParse(json['saved_at'] as String? ?? '') ?? DateTime.now(),
      quality: summary['quality'] as String? ?? '未知',
      starCount: starCount,
      constellation:
          summary['constellation'] as String? ?? _firstOrNull(solve?.constellations),
      solve: solve,
      explanation: json['explanation'] as String?,
      imageFile: File(p.join(parent, '$id.jpg')),
      processedFile: File(p.join(parent, '${id}_processed.jpg')),
      rawAnalysis: Map<String, Object?>.from(rawAnalysis),
      // 这个字段是后加的，早先存下的记录里没有。缺省按「星点数为零才算不是
      // 星空」兜底：老记录里唯一确定的事实就是星点数。
      isStarfield: summary['starfield'] as bool? ?? starCount > 0,
    );
  }
}

String? _firstOrNull(List<String>? values) =>
    values == null || values.isEmpty ? null : values.first;

int _asInt(Object? value) => value is num ? value.round() : 0;

/// 「1.2 MB」这种人话形式的字节数。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
