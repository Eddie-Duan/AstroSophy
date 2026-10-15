import 'package:astrosophy/history.dart' show SavedAnalysis;
import 'package:astrosophy/models.dart' show SolveSource;

typedef AgentActionHandler = Future<Object?> Function(
  String name,
  Map<String, Object?> arguments,
);

typedef AgentHistoryLoader = Future<List<SavedAnalysis>> Function();

/// Agent 可调用的固定工具。写入与联网操作只经 [handleAction] 交给 App 确认，
/// 没有通用文件、URL 或代码执行入口。
class AgentTools {
  const AgentTools({
    required this.report,
    required this.loadHistory,
    this.handleAction,
  });

  final Map<String, Object?> report;
  final AgentHistoryLoader loadHistory;
  final AgentActionHandler? handleAction;

  Future<Object?> execute(
    String name,
    Map<String, Object?> arguments,
  ) async {
    switch (name) {
      case 'get_current_report':
        _checkArguments(arguments, const {});
        return report;
      case 'find_catalog_object':
        _checkArguments(arguments, const {'query'});
        final query = arguments['query'];
        if (query is! String || query.trim().isEmpty || query.length > 120) {
          throw const FormatException('天体名称不能为空且不能超过 120 个字符。');
        }
        return _findCatalogObjects(query.trim());
      case 'list_observations':
        _checkArguments(arguments, const {'limit'});
        final limit = arguments['limit'];
        if (limit is! int || limit < 1 || limit > 20) {
          throw const FormatException('历史记录数量必须是 1 到 20 之间的整数。');
        }
        final observations = await loadHistory();
        return {
          'count': observations.take(limit).length,
          'observations': [
            for (final item in observations.take(limit))
              {
                'id': item.id,
                'name': item.name,
                'saved_at': item.savedAt.toIso8601String(),
                'quality': item.quality,
                'star_count': item.starCount,
                'constellation': item.constellation,
                'solved': item.solve != null,
                'is_starfield': item.isStarfield,
              },
          ],
        };
      case 'get_observation':
        _checkArguments(arguments, const {'observation_id'});
        final id = arguments['observation_id'];
        if (id is! String || id.trim().isEmpty) {
          throw const FormatException('需要给出观测记录的 id。');
        }
        final all = await loadHistory();
        final found = all.where((item) => item.id == id.trim()).firstOrNull;
        if (found == null) {
          throw StateError('找不到 id 为 $id 的本机观测记录。');
        }
        return _observationDetail(found);
      case 'open_screen':
        // 换页面是纯界面动作：没有副作用、随时能退回来，所以**不用**确认。
        // 把导航也塞进「确认」那套里，会让真正需要确认的那几件事（上传、
        // 删除）显得没那么特殊。
        _checkArguments(arguments, const {'screen'});
        final screen = arguments['screen'];
        if (screen is! String ||
            !const {'history', 'settings'}.contains(screen)) {
          throw const FormatException('可打开的页面只有 history 和 settings。');
        }
        final nav = handleAction;
        if (nav == null) {
          throw StateError('当前环境未启用此 Agent 操作。');
        }
        return nav('open_screen', arguments);
      case 'save_current_observation':
      case 'rename_observation':
      case 'delete_observation':
      case 'request_online_solve':
      case 'propose_non_sky_regions':
        final allowed = switch (name) {
          'save_current_observation' => const {'name'},
          'rename_observation' => const {'observation_id', 'new_name'},
          'delete_observation' => const {'observation_id'},
          _ => const <String>{},
        };
        _checkArguments(arguments, allowed);
        final handler = handleAction;
        if (handler == null) {
          throw StateError('当前环境未启用此 Agent 操作。');
        }
        return handler(name, arguments);
      default:
        throw ArgumentError.value(name, 'name', '未知的 Agent 工具');
    }
  }

  /// 一条观测记录的细读。
  ///
  /// 比 [listObservations] 那种一行摘要多给三样东西：保存下来的那份解读、
  /// 解算出来的坐标与比例尺、以及这条记录当时算没算出天区。用户问「我上周
  /// 那张土星是几点拍的、解出来是什么」时要的就是这些。
  ///
  /// **不给**原始测量数组（几百个星点的坐标）和图片：那些对回答没有帮助，
  /// 却会把上下文一次占满，把真正有用的东西挤出去。
  Map<String, Object?> _observationDetail(SavedAnalysis entry) {
    final solve = entry.solve;
    return {
      'id': entry.id,
      'name': entry.name,
      'saved_at': entry.savedAt.toIso8601String(),
      'quality': entry.quality,
      'star_count': entry.starCount,
      'is_starfield': entry.isStarfield,
      'constellation': entry.constellation,
      'solved': solve != null,
      if (solve != null) 'solve': {
        'center_ra_deg': solve.centerRa,
        'center_dec_deg': solve.centerDec,
        'arcsec_per_pixel': solve.arcsecPerPixel,
        'field_of_view_deg': solve.fieldOfViewDegrees,
        'matched_star_count': solve.matchedCount,
        'source': solve.source == SolveSource.local ? 'local_offline' : 'astrometry_net',
      },
      if (entry.capture != null) 'capture_time': entry.capture!.timestamp,
      'explanation_saved': entry.explanation,
    };
  }

  Map<String, Object?> _findCatalogObjects(String query) {
    final normalized = query.toLowerCase();
    final matches = <Map<String, Object?>>[];
    for (final key in const ['catalog_stars', 'deep_sky_objects']) {
      final rows = report[key];
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        final item = Map<String, Object?>.from(row);
        final name = item['name'];
        if (name is String && name.toLowerCase().contains(normalized)) {
          matches.add(item);
        }
      }
    }
    return {
      'query': query,
      'count': matches.length,
      'objects': matches.take(12).toList(growable: false),
      if (matches.isEmpty) 'message': '当前视场的已识别天体中没有匹配项。',
      if (matches.length > 12) 'truncated': true,
    };
  }

  void _checkArguments(
    Map<String, Object?> arguments,
    Set<String> allowed,
  ) {
    final unexpected = arguments.keys.where((key) => !allowed.contains(key));
    if (unexpected.isNotEmpty) {
      throw FormatException('工具包含不支持的参数：${unexpected.join(', ')}。');
    }
  }
}
