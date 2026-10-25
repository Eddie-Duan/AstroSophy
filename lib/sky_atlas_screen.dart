import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'history.dart';
import 'live_sky.dart';
import 'strings.dart';
import 'theme.dart';

/// 和实时星图一样的可拖动、可缩放黑色星图，只是不接相机。
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

  double _centerRa = 0;
  double _centerDec = 20;
  double _fov = 65;
  double _startFov = 65;
  LiveObject? _target;

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
        if (catalog.stars.isNotEmpty) {
          _centerRa = catalog.stars.first.raDegrees;
          _centerDec = catalog.stars.first.decDegrees;
        }
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

  void _pan(double dx, double dy, double width) {
    final degreesPerPixel = _fov / math.max(1, width);
    final cosDec = math.max(0.15, math.cos(_centerDec * math.pi / 180));
    setState(() {
      _centerRa = (_centerRa - dx * degreesPerPixel / cosDec) % 360;
      if (_centerRa < 0) _centerRa += 360;
      _centerDec = (_centerDec + dy * degreesPerPixel).clamp(-88.0, 88.0);
    });
  }

  void _zoom(double scale) {
    setState(() => _fov = (_startFov / scale).clamp(20.0, 140.0));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF02050A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF02050A),
          title: Text(t('星空足迹')),
          actions: [
            IconButton(
              tooltip: t('查询天体'),
              onPressed: _loading || _catalog == null ? null : _openSearch,
              icon: const Icon(Icons.search),
            ),
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
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _startFov = _fov,
            onScaleUpdate: (details) {
              final width = MediaQuery.sizeOf(context).width;
              if (details.pointerCount <= 1) {
                _pan(details.focalPointDelta.dx,
                    details.focalPointDelta.dy, width);
              }
              if (details.scale != 1) _zoom(details.scale);
            },
            child: CustomPaint(
              painter: _AtlasChartPainter(
                stars: catalog.stars,
                deepSky: catalog.deepSky,
                records: _records,
                centerRa: _centerRa,
                centerDec: _centerDec,
                fov: _fov,
                recordedStars: _recordedStars,
                recordedDeepSky: _recordedDeepSky,
                target: _target,
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          top: 8,
          child: _pill(
            '${t('拖动转向 · 双指缩放')}  ·  $solved ${t('次观测')}',
          ),
        ),
        Positioned(
          left: 12,
          bottom: 12,
          right: 12,
          child: Row(
            children: [
              Expanded(child: _legend()),
              const SizedBox(width: 8),
              _pill(
                'RA ${_centerRa.toStringAsFixed(1)}°  Dec ${_centerDec.toStringAsFixed(1)}°',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF29405A)),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 10, color: Color(0xFFA6B5C8)),
        ),
      );

  Widget _legend() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            _legendDot(const Color(0xFFE8EEF5), t('亮星')),
            _legendDot(const Color(0xFF7FD8FF), t('星云')),
            _legendDot(kMint, t('记录过')),
            _legendDot(const Color(0xFFFFB74D), t('取景框')),
          ],
        ),
      );

  Widget _legendDot(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 9.5)),
        ],
      );

  Future<void> _openSearch() async {
    final catalog = _catalog!;
    final controller = TextEditingController();
    final result = await showModalBottomSheet<LiveObject>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPanel,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final query = controller.text.trim().toLowerCase();
          final results = <LiveObject>[];
          if (query.isNotEmpty) {
            for (final object in [...catalog.stars, ...catalog.deepSky]) {
              if (object.name.toLowerCase().contains(query)) {
                results.add(object);
                if (results.length >= 50) break;
              }
            }
          }
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
              ),
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.62,
                child: Column(
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      onChanged: (_) => setSheetState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: t('搜索亮星、星云，例如 仙女座星系 / 织女星'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: results.isEmpty
                          ? Center(
                              child: Text(
                                query.isEmpty
                                    ? t('输入名称查询')
                                    : t('没有找到匹配天体'),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF8192A8),
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (context, index) {
                                final object = results[index];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    object.kind == LiveObjectKind.deepSky
                                        ? Icons.blur_circular
                                        : Icons.star,
                                    size: 17,
                                    color: const Color(0xFF7FD8FF),
                                  ),
                                  title: Text(object.name),
                                  subtitle: Text(
                                    t('{0} · {1} 等', [
                                      object.kind == LiveObjectKind.deepSky
                                          ? t('星云')
                                          : t('亮星'),
                                      object.magnitude.toStringAsFixed(1),
                                    ]),
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                  onTap: () => Navigator.pop(context, object),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _centerRa = result.raDegrees;
      _centerDec = result.decDegrees.clamp(-88.0, 88.0);
      _fov = 30;
      _target = result;
    });
  }

  Future<void> _openList() async {
    final catalog = _catalog!;
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
                    object.kind == LiveObjectKind.deepSky ? t('星云') : t('亮星'),
                    object.magnitude.toStringAsFixed(1),
                  ]),
            style: const TextStyle(fontSize: 10.5),
          ),
          onTap: () {
            Navigator.pop(context);
            setState(() {
              _centerRa = object.raDegrees;
              _centerDec = object.decDegrees.clamp(-88.0, 88.0);
              _fov = 30;
              _target = object;
            });
          },
        );
      },
    );
  }
}

class _AtlasChartPainter extends CustomPainter {
  _AtlasChartPainter({
    required this.stars,
    required this.deepSky,
    required this.records,
    required this.centerRa,
    required this.centerDec,
    required this.fov,
    required this.recordedStars,
    required this.recordedDeepSky,
    required this.target,
  });

  final List<LiveObject> stars;
  final List<LiveObject> deepSky;
  final List<SavedAnalysis> records;
  final double centerRa;
  final double centerDec;
  final double fov;
  final Set<String> recordedStars;
  final Set<String> recordedDeepSky;
  final LiveObject? target;

  @override
  void paint(Canvas canvas, Size size) {
    final basis = _chartBasis();
    Offset? project(double ra, double dec) {
      final point = _spherePoint(ra, dec);
      return basis.project(
        point,
        horizontalFovDegrees: fov,
        viewport: size,
        margin: 0,
      );
    }

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.55
      ..color = const Color(0x22496A8C);
    final step = fov > 80 ? 30.0 : fov > 35 ? 10.0 : 5.0;
    var raStart = (centerRa - fov).floorToDouble();
    raStart = (raStart / step).floorToDouble() * step;
    for (var ra = raStart; ra <= centerRa + fov; ra += step) {
      final previous = <Offset?>[];
      for (var dec = -88.0; dec <= 88.0; dec += 3) {
        previous.add(project(ra, dec));
      }
      _drawPolyline(canvas, previous, grid);
    }
    for (var dec = -80.0; dec <= 80.0; dec += step) {
      final points = <Offset?>[];
      for (var ra = raStart; ra <= centerRa + fov; ra += 3) {
        points.add(project(ra, dec));
      }
      _drawPolyline(canvas, points, grid);
    }

    for (final object in stars) {
      if (object.magnitude > 6.0) continue;
      final point = project(object.raDegrees, object.decDegrees);
      if (point == null) continue;
      final radius = object.magnitude <= 1.5
          ? 2.8
          : object.magnitude <= 3.5
              ? 2.0
              : 1.25;
      final recorded = recordedStars.contains(object.name);
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = recorded
              ? kMint
              : const Color(0xFFE8EEF5).withValues(alpha: 0.85),
      );
      if (recorded) {
        canvas.drawCircle(
          point,
          radius + 3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color = kMint,
        );
      }
      if (object.magnitude <= 2.2) {
        _label(canvas, point + const Offset(4, -10), object.name,
            const Color(0xFFD8E2F0));
      }
    }

    for (final object in deepSky) {
      final point = project(object.raDegrees, object.decDegrees);
      if (point == null) continue;
      final recorded = recordedDeepSky.contains(object.name);
      final color = recorded ? kMint : const Color(0xFF7FD8FF);
      canvas.drawOval(
        Rect.fromCenter(center: point, width: 6, height: 4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.82),
      );
      if (recorded) {
        canvas.drawCircle(
          point,
          5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1
            ..color = kMint,
        );
      }
      if (fov < 50 && object.magnitude <= 10) {
        _label(canvas, point + const Offset(4, -9), object.name,
            const Color(0xFF9FE6FF));
      }
    }

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
          final projected = project(world.$1, world.$2);
          if (projected == null) break;
          corners.add(projected);
        }
      }
      if (corners.length == 4) {
        canvas.drawPath(
          Path()..addPolygon(corners, true),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0xFFFFB74D).withValues(alpha: 0.55),
        );
      }
    }

    if (target != null) {
      final point = project(target!.raDegrees, target!.decDegrees);
      if (point != null) {
        canvas.drawCircle(
          point,
          12,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = const Color(0xFFFFD166),
        );
        _label(canvas, point + const Offset(14, -18), target!.name,
            const Color(0xFFFFD166));
      }
    }

    final center = size.center(Offset.zero);
    final cross = Paint()
      ..strokeWidth = 0.8
      ..color = const Color(0x66A6B5C8);
    canvas.drawLine(
      center - const Offset(8, 0),
      center + const Offset(8, 0),
      cross,
    );
    canvas.drawLine(
      center - const Offset(0, 8),
      center + const Offset(0, 8),
      cross,
    );
  }

  LiveCameraBasis _chartBasis() {
    final ra = centerRa * math.pi / 180;
    final dec = centerDec * math.pi / 180;
    final forward = LiveVec3(
      math.cos(dec) * math.cos(ra),
      math.cos(dec) * math.sin(ra),
      math.sin(dec),
    ).normalized();
    final east = LiveVec3(-math.sin(ra), math.cos(ra), 0).normalized();
    final north = LiveVec3(
      -math.sin(dec) * math.cos(ra),
      -math.sin(dec) * math.sin(ra),
      math.cos(dec),
    ).normalized();
    return LiveCameraBasis(forward: forward, up: north, right: east);
  }

  LiveVec3 _spherePoint(double ra, double dec) {
    final a = ra * math.pi / 180;
    final d = dec * math.pi / 180;
    return LiveVec3(
      math.cos(d) * math.cos(a),
      math.cos(d) * math.sin(a),
      math.sin(d),
    ).normalized();
  }

  void _drawPolyline(Canvas canvas, List<Offset?> points, Paint paint) {
    Offset? previous;
    for (final point in points) {
      if (point != null && previous != null) {
        canvas.drawLine(previous, point, paint);
      }
      previous = point;
    }
  }

  void _label(Canvas canvas, Offset offset, String text, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 9, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 110);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _AtlasChartPainter oldDelegate) =>
      oldDelegate.centerRa != centerRa ||
      oldDelegate.centerDec != centerDec ||
      oldDelegate.fov != fov ||
      oldDelegate.target != target ||
      oldDelegate.records != records;
}
