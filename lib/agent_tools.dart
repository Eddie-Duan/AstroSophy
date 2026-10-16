import 'package:astrosophy/history.dart' show SavedAnalysis;
import 'strings.dart';
import 'package:astrosophy/models.dart' show SolveSource;
import 'package:astrosophy/smallbodies.dart'
    show
        SmallBodyCatalog,
        magnitudeOf,
        positionOf,
        smallBodyPhotoLimitMagnitude;

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
    this.loadSmallBodies,
    this.handleAction,
  });

  final Map<String, Object?> report;
  final AgentHistoryLoader loadHistory;
  final AgentActionHandler? handleAction;

  /// 读内置小天体目录。为 null 时 `find_small_body` 不可用。
  ///
  /// 做成回调而不是直接在构造时读：目录只在用户真的问起时才需要，而它要读
  /// 192 KB 的资源文件。不问就不读。
  final Future<SmallBodyCatalog> Function()? loadSmallBodies;

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
          throw FormatException(t('天体名称不能为空且不能超过 120 个字符。'));
        }
        return _findCatalogObjects(query.trim());
      case 'find_small_body':
        _checkArguments(arguments, const {'query'});
        final query = arguments['query'];
        if (query is! String || query.trim().isEmpty || query.length > 120) {
          throw FormatException(t('天体名称不能为空且不能超过 120 个字符。'));
        }
        return _findSmallBody(query.trim());
      case 'list_observations':
        _checkArguments(arguments, const {'limit'});
        final limit = arguments['limit'];
        if (limit is! int || limit < 1 || limit > 20) {
          throw FormatException(t('历史记录数量必须是 1 到 20 之间的整数。'));
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
          throw FormatException(t('需要给出观测记录的 id。'));
        }
        final all = await loadHistory();
        final found = all.where((item) => item.id == id.trim()).firstOrNull;
        if (found == null) {
          throw StateError(t('找不到 id 为 {0} 的本机观测记录。', [id]));
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
          throw FormatException(t('可打开的页面只有 history 和 settings。'));
        }
        final nav = handleAction;
        if (nav == null) {
          throw StateError(t('当前环境未启用此 Agent 操作。'));
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
          throw StateError(t('当前环境未启用此 Agent 操作。'));
        }
        return handler(name, arguments);
      default:
        throw ArgumentError.value(name, 'name', t('未知的 Agent 工具'));
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
    for (final key in const [
      'catalog_stars',
      'deep_sky_objects',
      // 系内天体（行星、矮行星、小行星、彗星）也算「已识别的天体」：用户问
      // 「这张照片里有灶神星吗」，答案就在这一栏里。
      'moving_bodies',
    ]) {
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
      if (matches.isEmpty) 'message': t('当前视场的已识别天体中没有匹配项。'),
      if (matches.length > 12) 'truncated': true,
    };
  }

  /// 一颗小天体现在在哪儿、多亮。
  ///
  /// 和 [report] 里那一栏的区别是**时刻**：报告说的是「拍这张照片的时候」，
  /// 这里说的是「现在」。两者都对，回答的问题不一样，所以返回里写明了
  /// `computed_at`，免得模型把两个混成一个。
  ///
  /// 位置是两体近似，信息量全在「表是哪天建的」上——表越旧越不准。所以
  /// 返回里带上 `catalog_built`，并且明说这件事，不假装它是精确定位。
  Future<Map<String, Object?>> _findSmallBody(String query) async {
    final loader = loadSmallBodies;
    if (loader == null) {
      throw StateError(t('当前环境未启用此 Agent 操作。'));
    }
    final catalog = await loader();
    final body = catalog.find(query);
    if (body == null) {
      return {
        'query': query,
        'found': false,
        'message': t('内置的太阳系小天体目录里没有这一颗。目录里有 16 颗亮小行星、10 颗矮行星和全部 939 颗彗星。'),
      };
    }
    final moment = DateTime.now().toUtc();
    final position = positionOf(body, moment);
    final magnitude = magnitudeOf(body, moment);
    final rough = !body.magnitudeIsReliable;
    return {
      'query': query,
      'found': true,
      'name': body.name,
      'designation': body.designation,
      'kind': t(body.kind.label),
      'computed_at': moment.toIso8601String(),
      if (position != null) 'ra_deg': position.ra,
      if (position != null) 'dec_deg': position.dec,
      if (position != null) 'distance_au': position.distanceAu,
      // 彗星的 k1 八成是 MPC 填的缺省值，算出来的亮度可能差好几等，所以
      // 宁可空着也不把这种数交给模型。
      if (magnitude != null && !rough) 'magnitude': double.parse(magnitude.toStringAsFixed(1)),
      'magnitude_is_rough': rough,
      'catalog_built': catalog.built.isEmpty ? null : catalog.built,
      if (magnitude != null && !rough)
        'photographable_with_a_phone': magnitude <= smallBodyPhotoLimitMagnitude,
      'note': t('位置按两体近似从内置根数表推算（表建于 {0}），离这个日期越远越不准：谷神星三年能偏二十角分。{1}{2}', [catalog.built, rough ? t('这颗彗星的亮度用的是缺省光度参数，只能当个大概。') : '', magnitude != null && !rough && magnitude > smallBodyPhotoLimitMagnitude ? t('它比手机能拍到的极限还暗。') : '']),
    };
  }

  void _checkArguments(
    Map<String, Object?> arguments,
    Set<String> allowed,
  ) {
    final unexpected = arguments.keys.where((key) => !allowed.contains(key));
    if (unexpected.isNotEmpty) {
      throw FormatException(t('工具包含不支持的参数：{0}。', [unexpected.join(', ')]));
    }
  }
}
