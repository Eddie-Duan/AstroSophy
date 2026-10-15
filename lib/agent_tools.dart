import 'history.dart' show SavedAnalysis;

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
