import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'live_sky.dart';
import 'live_star_tracker.dart';
import 'strings.dart';
import 'theme.dart';

/// 实时星图：相机画面 + 手机姿态 + 当地天球，把亮星/星座/深空/行星叠上去。
///
/// 这里做的是**模型驱动的 AR**，不是实时解析相机画面。相机的用途是让用户
/// 看见真实的天空；方向来自加速度计和磁力计，位置来自 GPS，时间来自系统时钟。
/// 因此它不需要联网、不需要上传照片，也不会把相机帧送去做识别。
class LiveSkyScreen extends StatefulWidget {
  const LiveSkyScreen({super.key, this.storage});

  final FlutterSecureStorage? storage;

  @override
  State<LiveSkyScreen> createState() => _LiveSkyScreenState();
}

enum _LiveLayer { stars, constellations, deepSky, planets, smallBodies, labels }

class _LiveSkyScreenState extends State<LiveSkyScreen> {
  final _store = const FlutterSecureStorage();
  final _layers = <_LiveLayer>{
    _LiveLayer.stars,
    _LiveLayer.constellations,
    _LiveLayer.planets,
    _LiveLayer.labels,
  };

  LiveCatalog? _catalog;
  CameraController? _camera;
  String? _cameraError;
  bool _cameraStarting = false;

  /// 视觉修正后的姿态偏置。锁定时保持不变；重新锁定时清零。
  LiveOrientationFix? _orientationFix;
  bool _locked = false;
  int _matchedStars = 0;
  DateTime _lastTrackerRun = DateTime.fromMillisecondsSinceEpoch(0);
  bool _streaming = false;
  double _zoom = 1;
  double _zoomStart = 1;
  double _maxZoom = 1;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  Timer? _ticker;
  Timer? _solarTimer;
  bool _sensorError = false;

  LiveVec3 _accelerometer = const LiveVec3(0, 0, 9.8);
  LiveVec3 _magnetometer = const LiveVec3(0, 1, 0);

  double _latitude = 0;
  double _longitude = 0;
  bool _hasLocation = false;
  String? _locationNote;

  double _headingOffset = 0;
  double _fov = 65;
  DateTime _now = DateTime.now().toUtc();
  String _lastSecond = '';
  String _lastSolarMinute = '';

  List<LiveEnuObject> _stars = const [];
  List<LiveEnuObject> _deepSky = const [];
  List<LiveEnuObject> _planets = const [];
  List<LiveEnuObject> _smallBodies = const [];
  Map<int, LiveVec3> _starEnu = const {};
  double _sidereal = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadCatalog();
    _initCamera();
    _initSensors();
    _initLocation();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {
        _now = DateTime.now().toUtc();
        _refreshSkyIfNeeded();
      });
    });
    _solarTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted || _catalog == null) return;
      final key = _now.toIso8601String().substring(0, 16);
      if (key == _lastSolarMinute) return;
      _lastSolarMinute = key;
      _refreshSolarSystem();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _solarTimer?.cancel();
    _accelSub?.cancel();
    _magSub?.cancel();
    if (_streaming) {
      unawaited(_camera?.stopImageStream().catchError((_) {}));
    }
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final lat = double.tryParse(await _store.read(key: 'liveLatitude') ?? '');
      final lon = double.tryParse(await _store.read(key: 'liveLongitude') ?? '');
      final fov = double.tryParse(await _store.read(key: 'liveFov') ?? '');
      final offset =
          double.tryParse(await _store.read(key: 'liveHeadingOffset') ?? '');
      if (!mounted) return;
      setState(() {
        if (lat != null && lon != null) {
          _latitude = lat;
          _longitude = lon;
          _hasLocation = true;
        }
        if (fov != null) _fov = fov.clamp(35.0, 100.0);
        if (offset != null) _headingOffset = offset.clamp(-180.0, 180.0);
      });
    } on Exception {
      // 读不到就用默认值。
    }
  }

  Future<void> _loadCatalog() async {
    try {
      final catalog = await LiveCatalog.load();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _refreshSolarSystem();
        _refreshSkyIfNeeded(force: true);
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _cameraError = t('星表加载失败：{0}', [error]));
    }
  }

  Future<void> _initCamera() async {
    if (_cameraStarting) return;
    _cameraStarting = true;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _cameraError = t('没有找到可用摄像头'));
        return;
      }
      final selected = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraError = null;
      });
      try {
        final maxZoom = await controller.getMaxZoomLevel();
        if (mounted) setState(() => _maxZoom = math.max(1.0, maxZoom));
      } on CameraException {
        // 变焦能力读不到就保持 1×。
      }
      await controller.startImageStream(_onCameraFrame);
      _streaming = true;
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() => _cameraError = error.description ?? error.code);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _cameraError = '$error');
    } finally {
      _cameraStarting = false;
    }
  }

  void _initSensors() {
    _accelSub = accelerometerEventStream().listen(
      (event) {
        _accelerometer =
            _accelerometer.lerp(LiveVec3(event.x, event.y, event.z), 0.18);
      },
      onError: (_) {
        if (mounted) setState(() => _sensorError = true);
      },
      cancelOnError: false,
    );
    _magSub = magnetometerEventStream().listen(
      (event) {
        _magnetometer =
            _magnetometer.lerp(LiveVec3(event.x, event.y, event.z), 0.10);
      },
      onError: (_) {
        if (mounted) setState(() => _sensorError = true);
      },
      cancelOnError: false,
    );
  }

  Future<void> _initLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _locationNote = t('定位权限未授予，可在右上角手动设置经纬度');
          });
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 12),
        ),
      );
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _hasLocation = true;
        _locationNote = null;
        _refreshSkyIfNeeded(force: true);
      });
      await _store.write(key: 'liveLatitude', value: '${position.latitude}');
      await _store.write(key: 'liveLongitude', value: '${position.longitude}');
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _locationNote = t('定位失败：{0}', [error]));
    }
  }

  void _refreshSkyIfNeeded({bool force = false}) {
    final catalog = _catalog;
    if (catalog == null) return;
    final second = _now.toIso8601String().substring(0, 19);
    if (!force && second == _lastSecond) return;
    _lastSecond = second;
    _sidereal = localSiderealDegrees(_now, _longitude);
    _stars = enuObjects(
      objects: catalog.stars,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    _starEnu = {
      for (final item in _stars)
        if (item.object.hip != null) item.object.hip!: item.enu,
    };
    _deepSky = enuObjects(
      objects: catalog.deepSky,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    _planets = enuObjects(
      objects: _planetObjects,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    _smallBodies = enuObjects(
      objects: _smallBodyObjects,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
  }

  List<LiveObject> _planetObjects = const [];
  List<LiveObject> _smallBodyObjects = const [];

  void _refreshSolarSystem() {
    final catalog = _catalog;
    if (catalog == null) return;
    final all = catalog.solarSystemAt(_now);
    _planetObjects = [
      for (final object in all)
        if (object.kind == LiveObjectKind.planet) object,
    ];
    _smallBodyObjects = [
      for (final object in all)
        if (object.kind == LiveObjectKind.smallBody) object,
    ];
    _refreshSkyIfNeeded(force: true);
  }

  LiveCameraBasis? _basis() {
    final calibrated = _calibratedBasis();
    if (calibrated == null) return null;
    final fix = _orientationFix;
    if (fix == null) return calibrated;
    return calibrated.corrected(
      yawDegrees: fix.yawDegrees,
      pitchDegrees: fix.pitchDegrees,
      rollDegrees: fix.rollDegrees,
    );
  }

  LiveCameraBasis? _calibratedBasis() {
    final raw = LiveCameraBasis.fromSensors(
      accelerometer: _accelerometer,
      magnetometer: _magnetometer,
    );
    if (raw == null) return null;
    return _headingOffset == 0
        ? raw
        : raw.rotatedAroundUp(_headingOffset);
  }

  double get _effectiveFov => (_fov / _zoom).clamp(10.0, 140.0);

  double get _previewAspect {
    final aspect = _camera?.value.aspectRatio ?? 4 / 3;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final value = portrait ? 1 / aspect : aspect;
    return value.isFinite && value > 0 ? value : 4 / 3;
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (!mounted || _locked || _catalog == null || image.planes.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastTrackerRun) <
        const Duration(milliseconds: 300)) {
      return;
    }
    _lastTrackerRun = now;
    if (image.format.group != ImageFormatGroup.yuv420) return;
    final plane = image.planes.first;
    final detections = LiveStarTracker.detect(
      plane.bytes,
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    if (detections.length < 4) return;
    final base = _calibratedBasis();
    if (base == null) return;
    final fix = LiveStarTracker.solve(
      detections: detections,
      stars: _stars,
      basis: base,
      fieldOfViewDegrees: _effectiveFov,
      previewAspect: _previewAspect,
    );
    if (fix == null || !mounted) return;
    setState(() {
      _orientationFix = fix;
      _matchedStars = fix.matches;
      if (fix.matches >= 8) {
        _locked = true;
      }
    });
    if (_locked) unawaited(_stopStreaming());
  }

  Future<void> _stopStreaming() async {
    if (!_streaming) return;
    _streaming = false;
    try {
      await _camera?.stopImageStream();
    } on CameraException {
      // 已经停了就算了。
    }
  }

  Future<void> _restartTracking() async {
    setState(() {
      _locked = false;
      _orientationFix = null;
      _matchedStars = 0;
    });
    final controller = _camera;
    if (controller != null && !_streaming) {
      try {
        await controller.startImageStream(_onCameraFrame);
        _streaming = true;
      } on CameraException catch (error) {
        if (!mounted) return;
        setState(() => _cameraError = error.description ?? error.code);
      }
    }
  }

  Future<void> _toggleLock() async {
    if (_locked) {
      await _restartTracking();
      return;
    }
    setState(() => _locked = true);
    await _stopStreaming();
  }

  Future<void> _applyZoom(double value, double maxZoom) async {
    final controller = _camera;
    if (controller == null) return;
    final next = value.clamp(1.0, math.max(1.0, maxZoom)).toDouble();
    setState(() => _zoom = next);
    try {
      await controller.setZoomLevel(next);
    } on CameraException {
      // 某些机型不支持连续变焦，叠层仍然按光学视场显示。
    }
  }

  Future<void> _editLocation() async {
    final lat = TextEditingController(text: _latitude.toStringAsFixed(5));
    final lon = TextEditingController(text: _longitude.toStringAsFixed(5));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('观测位置')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lat,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Latitude'),
            ),
            TextField(
              controller: lon,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Longitude'),
            ),
            const SizedBox(height: 8),
            Text(
              t('用于推算当地天球；位置只保存在本机。'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF8192A8)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('保存')),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final parsedLat = double.tryParse(lat.text.trim());
    final parsedLon = double.tryParse(lon.text.trim());
    if (parsedLat == null ||
        parsedLon == null ||
        parsedLat.abs() > 90 ||
        parsedLon.abs() > 180) {
      return;
    }
    setState(() {
      _latitude = parsedLat;
      _longitude = parsedLon;
      _hasLocation = true;
      _locationNote = null;
      _orientationFix = null;
      _locked = false;
      _matchedStars = 0;
      _refreshSkyIfNeeded(force: true);
    });
    unawaited(_restartTracking());
    await _store.write(key: 'liveLatitude', value: '$parsedLat');
    await _store.write(key: 'liveLongitude', value: '$parsedLon');
  }

  Future<void> _editCalibration() async {
    var fov = _fov;
    var offset = _headingOffset;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: kPanel,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('画面校准'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t('不同手机的主摄视场不一样。把一颗你认得的亮星拖到它真实的位置，再微调这两个值。'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFFA6B5C8)),
                ),
                const SizedBox(height: 16),
                Text(t('水平视场：{0}°', [fov.round()])),
                Slider(
                  value: fov,
                  min: 35,
                  max: 100,
                  divisions: 65,
                  onChanged: (value) => setSheetState(() => fov = value),
                ),
                Text(t('方位校正：{0}°', [offset.round()])),
                Slider(
                  value: offset,
                  min: -180,
                  max: 180,
                  divisions: 72,
                  onChanged: (value) => setSheetState(() => offset = value),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(t('保存校准')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    setState(() {
      _fov = fov;
      _headingOffset = offset;
      _orientationFix = null;
      _locked = false;
      _matchedStars = 0;
    });
    unawaited(_restartTracking());
    await _store.write(key: 'liveFov', value: '$_fov');
    await _store.write(key: 'liveHeadingOffset', value: '$_headingOffset');
  }

  @override
  Widget build(BuildContext context) {
    final basis = _basis();
    final layers = {..._layers};
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _previewAspect,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => _zoomStart = _zoom,
                onScaleUpdate: (details) {
                  if (details.scale == 1) return;
                  _applyZoom(_zoomStart * details.scale, _maxZoom);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_camera != null)
                      CameraPreview(_camera!)
                    else
                      const ColoredBox(color: Color(0xFF02040A)),
                    if (basis != null)
                      CustomPaint(
                        painter: LiveSkyPainter(
                          stars: _stars,
                          deepSky: _deepSky,
                          planets: _planets,
                          smallBodies: _smallBodies,
                          constellations: _catalog?.constellations ?? const [],
                          starEnu: _starEnu,
                          basis: basis,
                          fov: _effectiveFov,
                          showStars: layers.contains(_LiveLayer.stars),
                          showConstellations:
                              layers.contains(_LiveLayer.constellations),
                          showDeepSky: layers.contains(_LiveLayer.deepSky),
                          showPlanets: layers.contains(_LiveLayer.planets),
                          showSmallBodies:
                              layers.contains(_LiveLayer.smallBodies),
                          showLabels: layers.contains(_LiveLayer.labels),
                        ),
                      ),
                    if (_zoom > 1.01)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 8,
                        child: Center(
                          child: Text(
                            '${_zoom.toStringAsFixed(1)}×',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.72),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // 中心准星：告诉用户手机正指着哪儿。
          IgnorePointer(
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: kMint.withValues(alpha: 0.55)),
                ),
                child: Center(
                  child: Container(
                    width: 3,
                    height: 3,
                    decoration: const BoxDecoration(
                      color: kMint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 8,
            child: SafeArea(
              child: Row(
                children: [
                  _roundButton(
                    icon: Icons.close_fullscreen,
                    tooltip: t('关闭实时星图'),
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('实时星图'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _hasLocation
                              ? '${_latitude.toStringAsFixed(2)}°, ${_longitude.toStringAsFixed(2)}°'
                              : t('未设置位置'),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFA6B5C8),
                          ),
                        ),
                        Text(
                          _locked
                              ? t('已锁定 {0} 颗星', [_matchedStars])
                              : t('校准中 · 已匹配 {0} 颗', [_matchedStars]),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: _locked
                                ? kMint.withValues(alpha: 0.9)
                                : const Color(0xFF8192A8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _roundButton(
                    icon: _locked ? Icons.lock : Icons.lock_open,
                    tooltip: _locked ? t('重新锁定') : t('锁定当前姿态'),
                    onTap: _toggleLock,
                  ),
                  if (_zoom > 1.01) ...[
                    const SizedBox(width: 8),
                    _roundButton(
                      icon: Icons.zoom_out_map,
                      tooltip: t('回到 1×'),
                      onTap: () => _applyZoom(1, _maxZoom),
                    ),
                  ],
                  const SizedBox(width: 8),
                  _roundButton(
                    icon: Icons.my_location,
                    tooltip: t('设置观测位置'),
                    onTap: _editLocation,
                  ),
                  const SizedBox(width: 8),
                  _roundButton(
                    icon: Icons.tune,
                    tooltip: t('画面校准'),
                    onTap: _editCalibration,
                  ),
                ],
              ),
            ),
          ),
          if (_cameraError != null || _sensorError || !_hasLocation)
            Positioned(
              left: 16,
              right: 16,
              bottom: 150,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFFFDE77).withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    _cameraError ??
                        (_sensorError
                            ? t('方向传感器不可用，画面可能不跟随手机转动')
                            : (_locationNote ?? t('请先设置观测位置'))),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Color(0xFFFFDE77),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _layerChip(_LiveLayer.stars, t('恒星')),
                        _layerChip(_LiveLayer.constellations, t('星座')),
                        _layerChip(_LiveLayer.deepSky, t('深空')),
                        _layerChip(_LiveLayer.planets, t('行星')),
                        _layerChip(_LiveLayer.smallBodies, t('小天体')),
                        _layerChip(_LiveLayer.labels, t('名称')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t('举起手机对准天空；方向来自传感器，可按亮星校准。'),
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.68),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) =>
      Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(icon, size: 20, color: kMint),
            ),
          ),
        ),
      );

  Widget _layerChip(_LiveLayer layer, String label) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text(label, style: const TextStyle(fontSize: 11)),
          selected: _layers.contains(layer),
          onSelected: (value) => setState(() {
            if (value) {
              _layers.add(layer);
            } else {
              _layers.remove(layer);
            }
          }),
          visualDensity: VisualDensity.compact,
        ),
      );
}

/// 把星表/星座/行星画到相机画面上。
class LiveSkyPainter extends CustomPainter {
  const LiveSkyPainter({
    required this.stars,
    required this.deepSky,
    required this.planets,
    required this.smallBodies,
    required this.constellations,
    required this.starEnu,
    required this.basis,
    required this.fov,
    required this.showStars,
    required this.showConstellations,
    required this.showDeepSky,
    required this.showPlanets,
    required this.showSmallBodies,
    required this.showLabels,
  });

  final List<LiveEnuObject> stars;
  final List<LiveEnuObject> deepSky;
  final List<LiveEnuObject> planets;
  final List<LiveEnuObject> smallBodies;
  final List<LiveConstellation> constellations;
  final Map<int, LiveVec3> starEnu;
  final LiveCameraBasis basis;
  final double fov;
  final bool showStars;
  final bool showConstellations;
  final bool showDeepSky;
  final bool showPlanets;
  final bool showSmallBodies;
  final bool showLabels;

  @override
  void paint(Canvas canvas, Size size) {
    if (showConstellations) _paintConstellations(canvas, size);
    if (showStars) _paintStars(canvas, size);
    if (showDeepSky) _paintDeepSky(canvas, size);
    if (showPlanets) _paintBodies(canvas, size, planets, const Color(0xFFFFAB40));
    if (showSmallBodies) {
      _paintBodies(canvas, size, smallBodies, const Color(0xFF7FD8FF));
    }
  }

  void _paintStars(Canvas canvas, Size size) {
    for (final item in stars) {
      final point = basis.project(
        item.enu,
        horizontalFovDegrees: fov,
        viewport: size,
      );
      if (point == null) continue;
      final magnitude = item.object.magnitude;
      final radius = magnitude <= 1.0
          ? 3.2
          : magnitude <= 2.5
              ? 2.3
              : magnitude <= 4.5
                  ? 1.5
                  : 1.0;
      canvas.drawCircle(
        point,
        radius,
        Paint()..color = Colors.white.withValues(
          alpha: (0.55 + (5 - magnitude).clamp(0, 4) * 0.1).clamp(0.45, 0.95),
        ),
      );
      if (showLabels && magnitude <= 2.6 && !item.object.name.startsWith('HIP ')) {
        _label(canvas, point + const Offset(5, -8), item.object.name,
            const Color(0xFFFFF3D0));
      }
    }
  }

  void _paintConstellations(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = kMint.withValues(alpha: 0.38);
    for (final constellation in constellations) {
      Offset? last;
      for (final segment in constellation.segments) {
        final a = starEnu[segment.a.hip];
        final b = starEnu[segment.b.hip];
        if (a == null || b == null) continue;
        final pa = basis.project(a, horizontalFovDegrees: fov, viewport: size);
        final pb = basis.project(b, horizontalFovDegrees: fov, viewport: size);
        if (pa == null || pb == null) continue;
        canvas.drawLine(pa, pb, paint);
        last = pa;
      }
      if (showLabels && last != null) {
        _label(canvas, last + const Offset(6, -16), constellation.name,
            kMint.withValues(alpha: 0.78));
      }
    }
  }

  void _paintDeepSky(Canvas canvas, Size size) {
    for (final item in deepSky) {
      final point = basis.project(
        item.enu,
        horizontalFovDegrees: fov,
        viewport: size,
      );
      if (point == null) continue;
      final radius = ((item.object.sizeArcmin ?? 10) / 8).clamp(2.0, 12.0);
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = const Color(0xFFFF7B8C).withValues(alpha: 0.8),
      );
      if (showLabels && item.object.magnitude <= 8.5) {
        _label(canvas, point + const Offset(5, -6), item.object.name,
            const Color(0xFFFFB3C0));
      }
    }
  }

  void _paintBodies(
    Canvas canvas,
    Size size,
    List<LiveEnuObject> bodies,
    Color color,
  ) {
    for (final item in bodies) {
      final point = basis.project(
        item.enu,
        horizontalFovDegrees: fov,
        viewport: size,
      );
      if (point == null) continue;
      canvas.drawCircle(point, 4.2, Paint()..color = color);
      canvas.drawCircle(
        point,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.8),
      );
      if (showLabels) {
        _label(canvas, point + const Offset(7, -8), item.object.name, color);
      }
    }
  }

  void _label(Canvas canvas, Offset offset, String text, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 130);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant LiveSkyPainter oldDelegate) => true;
}
