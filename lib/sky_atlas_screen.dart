import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'history.dart';
import 'live_sky.dart';
import 'strings.dart';
import 'theme.dart';

/// 全天星图：把内置亮星/星云和本机记录过的目标、历次取景框放在同一个天球上。
class SkyAtlasScreen extends StatefulWidget {
  const SkyAtlasScreen({super.key});

  @override
  State<SkyAtlasScreen> createState() => _SkyAtlasScreenState();
}

class _SkyAtlasScreenState extends State<SkyAtlasScreen> {
  LiveCatalog? _catalog;
  List<SavedAnalysis> _records = const [];
  Set<String> _recordedStars = const {};
  Set<String> _recordedDeepSky = const {};
  Set<String> _recordedMoving = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final catalog = await LiveCatalog.load();
      final history = await HistoryStore.open();
      final records = await history.list();
      final stars = <String>{};
      final deep = <String>{};
      final moving = <String>{};
      for (final record in records) {
        final solve = record.solve;
        if (solve == null) continue;
        for (final star in solve.namedStars) {
          stars.add(star.name);
        }
        for (final object in solve.deepSkyObjects) {
          deep.add(object.name);
        }
        for (final body in solve.movingBodies) {
          moving.add(body.name);
        }
      }
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _records = records;
        _recordedStars = stars;
        _recordedDeepSky = deep;
        _recordedMoving = moving;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  bool _isRecorded(LiveObject object) {
    if (object.kind == LiveObjectKind.star) {
      return _recordedStars.contains(object.name);
    }
    if (object.kind == LiveObjectKind.deepSky) {
      return _recordedDeepSky.contains(object.name);
    }
    return _recordedMoving.contains(object.name);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF050A12),
        appBar: AppBar(
          backgroundColor: const Color(0xFF050A12),
          title: Text(t('我的星空足迹')),
          actions: [
            IconButton(
              tooltip: t('天体列表'),
              onPressed: _loading || _catalog == null ? null : _openList,
              icon: const Icon(Icons.format_list_bulleted),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(t('加载星图失败：{0}', [_error!])),
                    ),
                  )
                : _body(),
      );

  Widget _body() {
    final catalog = _catalog!;
    final solved = _records.where((record) => record.solve != null).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      children: [
        Text(
          t('{0} 次观测 · {1} 个记录目标', [solved, _recordedCount()]),
          style: const TextStyle(fontSize: 12, color: Color(0xFFA6B5C8)),
        ),
        const SizedBox(height: 10),
        AspectRatio(
          aspectRatio: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF0A1422),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF1E3450)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: CustomPaint(
                painter: _AtlasPainter(
                  stars: catalog.stars,
                  deepSky: catalog.deepSky,
                  records: _records,
                  recordedStars: _recordedStars,
                  recordedDeepSky: _recordedDeepSky,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _legend(),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.format_list_bulleted, color: kMint),
            title: Text(t('行星、小行星、亮星、星云')),
            subtitle: Text(
              t('按类别浏览；记录过的目标会打勾。'),
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openList,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          t('球面只画亮星和星云；行星等移动天体随日期变化，只在列表里列当前位置。'),
          style: const TextStyle(fontSize: 10.5, color: Color(0xFF8192A8)),
        ),
      ],
    );
  }

  int _recordedCount() {
    final all = {..._recordedStars, ..._recordedDeepSky, ..._recordedMoving};
    return all.length;
  }

  Widget _legend() => Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          _legendDot(const Color(0xFFE8EEF5), t('亮星')),
          _legendDot(const Color(0xFF7FD8FF), t('星云 / 星系')),
          _legendDot(kMint, t('记录过')),
          _legendDot(const Color(0xFFFFB74D), t('取景框')),
        ],
      );

  Widget _legendDot(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 10.5)),
        ],
      );

  Future<void> _openList() async {
    final catalog = _catalog;
    if (catalog == null) return;
    final now = DateTime.now().toUtc();
    final bodies = catalog.solarSystemAt(now);
    final planets = bodies
        .where((body) => body.kind == LiveObjectKind.planet)
        .toList();
    final smallBodies = bodies
        .where((body) => body.kind == LiveObjectKind.smallBody)
        .toList();
    final stars = [...catalog.stars]
      ..sort((a, b) => a.magnitude.compareTo(b.magnitude));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPanel,
      builder: (context) => SafeArea(
        child: DefaultTabController(
          length: 4,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: '行星'),
                  Tab(text: '小行星'),
                  Tab(text: '亮星'),
                  Tab(text: '星云'),
                ],
              ),
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.55,
                child: TabBarView(
                  children: [
                    _bodyList(planets, compact: true),
                    _bodyList(smallBodies, compact: true),
                    _bodyList(stars.take(100).toList(), compact: false),
                    _bodyList(catalog.deepSky, compact: false),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyList(List<LiveObject> objects, {required bool compact}) {
    if (objects.isEmpty) {
      return const Center(child: Text('这里暂时没有目标。'));
    }
    return ListView.builder(
      itemCount: objects.length,
      itemBuilder: (context, index) {
        final object = objects[index];
        final recorded = _isRecorded(object);
        return ListTile(
          dense: true,
          leading: Icon(
            recorded ? Icons.check_circle : Icons.circle_outlined,
            size: 17,
            color: recorded ? kMint : const Color(0xFF52657C),
          ),
          title: Text(object.name),
          subtitle: Text(
            compact
                ? t('{0} 等', [object.magnitude.toStringAsFixed(1)])
                : t('{0} · {1} 等', [
                    _kindLabel(object.kind),
                    object.magnitude.toStringAsFixed(1),
                  ]),
            style: const TextStyle(fontSize: 10.5),
          ),
        );
      },
    );
  }

  String _kindLabel(LiveObjectKind kind) => switch (kind) {
        LiveObjectKind.star => t('恒星'),
        LiveObjectKind.deepSky => t('深空'),
        LiveObjectKind.planet => t('行星'),
        LiveObjectKind.smallBody => t('小天体'),
        LiveObjectKind.sun => t('太阳'),
        LiveObjectKind.moon => t('月球'),
      };
}

class _AtlasPainter extends CustomPainter {
  _AtlasPainter({
    required this.stars,
    required this.deepSky,
    required this.records,
    required this.recordedStars,
    required this.recordedDeepSky,
  });

  final List<LiveObject> stars;
  final List<LiveObject> deepSky;
  final List<SavedAnalysis> records;
  final Set<String> recordedStars;
  final Set<String> recordedDeepSky;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = math.min(size.width / 4.6, size.height / 2.5);
    Offset project(double ra, double dec) {
      final lon = (ra - 180) * math.pi / 180;
      final lat = dec * math.pi / 180;
      final denominator =
          math.sqrt(1 + math.cos(lat) * math.cos(lon / 2));
      final x = 2 * math.sqrt2 * math.cos(lat) * math.sin(lon / 2) / denominator;
      final y = math.sqrt2 * math.sin(lat) / denominator;
      return center + Offset(x * scale, -y * scale);
    }

    // 天球外轮廓。
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: 4 * math.sqrt2 * scale,
        height: 2 * math.sqrt2 * scale,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF1E3450),
    );

    // 银道带用一条淡色曲线示意。
    final galactic = Path();
    for (var ra = 0; ra <= 360; ra += 3) {
      final point = _galacticPoint(ra.toDouble());
      final projected = project(point.$1, point.$2);
      if (ra == 0) {
        galactic.moveTo(projected.dx, projected.dy);
      } else {
        galactic.lineTo(projected.dx, projected.dy);
      }
    }
    canvas.drawPath(
      galactic,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = const Color(0x2235D6FF),
    );

    for (final object in stars) {
      if (object.magnitude > 6.0) continue;
      final point = project(object.raDegrees, object.decDegrees);
      final radius = object.magnitude <= 1.5
          ? 2.6
          : object.magnitude <= 3.5
              ? 1.8
              : 1.1;
      final recorded = recordedStars.contains(object.name);
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = recorded
              ? kMint
              : const Color(0xFFE8EEF5).withValues(alpha: 0.82),
      );
      if (recorded) {
        canvas.drawCircle(
          point,
          radius + 3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = kMint,
        );
      }
    }

    for (final object in deepSky) {
      final point = project(object.raDegrees, object.decDegrees);
      final recorded = recordedDeepSky.contains(object.name);
      final color = recorded ? kMint : const Color(0xFF7FD8FF);
      canvas.drawOval(
        Rect.fromCenter(center: point, width: 5, height: 3.2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.78),
      );
      if (recorded) {
        canvas.drawCircle(
          point,
          4.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = kMint,
        );
      }
    }

    // 历次取景框：有 WCS 就投四角，没有就按中心 + 视场画一个小框。
    for (final record in records) {
      final solve = record.solve;
      if (solve == null) continue;
      final corners = <Offset>[];
      final wcs = solve.wcs;
      if (wcs != null && wcs.width > 0 && wcs.height > 0) {
        for (final pixel in [
          (0, 0),
          (wcs.width - 1, 0),
          (wcs.width - 1, wcs.height - 1),
          (0, wcs.height - 1),
        ]) {
          final world = wcs.pixelToWorld(pixel.$1.toDouble(), pixel.$2.toDouble());
          corners.add(project(world.$1, world.$2));
        }
      } else if (solve.fieldOfViewDegrees > 0) {
        final half = solve.fieldOfViewDegrees / 2;
        for (final (dx, dy) in const [(-1, -1), (1, -1), (1, 1), (-1, 1)]) {
          corners.add(project(
            solve.centerRa + dx * half,
            (solve.centerDec + dy * half).clamp(-89.0, 89.0).toDouble(),
          ));
        }
      }
      if (corners.length != 4) continue;
      final path = Path()..addPolygon(corners, true);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFFFFB74D).withValues(alpha: 0.55),
      );
    }
  }

  (double, double) _galacticPoint(double longitude) {
    final lon = longitude * math.pi / 180;
    final b = 0.0;
    final ra = math.atan2(
      math.sin(lon) * math.cos(0.5759) -
          math.tan(b) * math.sin(0.5759),
      math.cos(lon),
    );
    final dec = math.asin(
      (math.sin(b) * math.cos(1.0472) +
              math.cos(b) * math.sin(1.0472) * math.sin(lon))
          .clamp(-1.0, 1.0)
          .toDouble(),
    );
    return ((ra * 180 / math.pi + 360) % 360, dec * 180 / math.pi);
  }

  @override
  bool shouldRepaint(covariant _AtlasPainter oldDelegate) =>
      oldDelegate.records != records ||
      oldDelegate.stars != stars ||
      oldDelegate.deepSky != deepSky;
}
