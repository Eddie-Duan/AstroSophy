import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'ephemeris.dart';
import 'live_nox.dart';
import 'live_sky.dart';
import 'live_star_tracker.dart';
import 'moon.dart';
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
  bool _solveMode = true;
  bool _chartMode = true;
  LiveCameraBasis? _freeBasis;
  double _panYaw = 0;
  double _panPitch = 0;
  bool _showEcliptic = false;
  bool _showCelestialEquator = false;
  bool _showLunarPath = false;
  bool _showGalactic = false;
  bool _showAltAzGrid = false;
  bool _showEquatorialGrid = false;
  bool _showBelowHorizon = false;
  bool _redMode = false;

  static const _fallbackSurveyBasis = LiveCameraBasis(
    forward: LiveVec3.north,
    up: LiveVec3.up,
    right: LiveVec3.east,
  );

  static const _identity = <double>[
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  /// 把画面压成红/黑两色，夜里看屏幕不刺眼。
  ///
  /// 关键是保留亮度差：三通道一起加到红通道，白字仍然亮红、黑底仍然黑，
  /// 不会像单纯抽红通道那样把灰字压成一片深红。
  static const _redFilter = ColorFilter.matrix(<double>[
    0.75, 0.65, 0.60, 0, 0,
    0.02, 0.04, 0.03, 0, 0,
    0.01, 0.02, 0.03, 0, 0,
    0, 0, 0, 1, 0,
  ]);
  LiveSkyVisibility _visibility = LiveSkyVisibility.auto;
  double _starLimit = 5.0;
  double _deepSkyLimit = 8.0;
  double _sunAltitude = 0;
  double _moonAltitude = 0;
  double _moonPhase = 0;

  LiveCatalog? _catalog;
  CameraController? _camera;
  String? _cameraError;
  bool _cameraStarting = false;

  /// 视觉修正后的姿态偏置。锁定时保持不变；重新锁定时清零。
  LiveOrientationFix? _orientationFix;
  bool _locked = false;
  int _matchedStars = 0;
  Set<int> _matchedHips = const {};
  List<LiveEnuObject> _trackedStars = const [];
  LiveObject? _targetObject;
  LiveObject? _calibrationStar;
  double _manualYaw = 0;
  double _manualPitch = 0;
  int _lostFrames = 0;
  DateTime _lastTrackerRun = DateTime.fromMillisecondsSinceEpoch(0);
  bool _streaming = false;
  double _zoom = 1;
  double _zoomStart = 1;
  double _maxZoom = 1;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _ticker;
  Timer? _solarTimer;
  bool _sensorError = false;

  LiveVec3 _accelerometer = const LiveVec3(0, 0, 9.8);
  LiveVec3 _magnetometer = const LiveVec3(0, 1, 0);
  LiveVec3 _gyroscope = LiveVec3.zero;
  LiveVec3 _gyroBias = LiveVec3.zero;
  LiveCameraBasis? _fusedBasis;
  DateTime _lastGyroAt = DateTime.now();
  bool _accelSeen = false;
  bool _magSeen = false;

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
  List<LiveEnuObject> _trackerStars = const [];
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
    _gyroSub?.cancel();
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
      final visibility = await _store.read(key: 'liveVisibility');
      if (!mounted) return;
      setState(() {
        if (lat != null && lon != null) {
          _latitude = lat;
          _longitude = lon;
          _hasLocation = true;
        }
        if (fov != null) _fov = fov.clamp(35.0, 100.0);
        if (offset != null) _headingOffset = offset.clamp(-180.0, 180.0);
        _visibility = LiveSkyVisibility.fromStorage(visibility);
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
        final next = LiveVec3(event.x, event.y, event.z);
        // 加速度计偶尔会甩出一两个尖峰；直接 lerp 进去会让整幅星图跳一下。
        if (next.length < 1 || next.length > 40) return;
        _accelerometer = _accelerometer.lerp(next, 0.14);
        _accelSeen = true;
        _ensureFusedBasis();
        _correctFusedBasis();
      },
      onError: (_) {
        if (mounted) setState(() => _sensorError = true);
      },
      cancelOnError: false,
    );
    _magSub = magnetometerEventStream().listen(
      (event) {
        final next = LiveVec3(event.x, event.y, event.z);
        if (next.length < 1 || next.length > 300) return;
        _magnetometer = _magnetometer.lerp(next, 0.08);
        _magSeen = true;
        _ensureFusedBasis();
        _correctFusedBasis();
      },
      onError: (_) {
        if (mounted) setState(() => _sensorError = true);
      },
      cancelOnError: false,
    );
    _gyroSub = gyroscopeEventStream().listen(
      (event) {
        final now = DateTime.now();
        final dt = (now.difference(_lastGyroAt).inMicroseconds / 1e6)
            .clamp(0.001, 0.08);
        _lastGyroAt = now;
        final raw = LiveVec3(event.x, event.y, event.z);
        // 只在接近静止时慢慢估陀螺零偏；转动时把转动本身当偏置会把方向带歪。
        if (raw.length < 0.25) {
          _gyroBias = _gyroBias.lerp(raw, 0.01);
        }
        final gyro = raw - _gyroBias;
        _gyroscope = gyro;
        if (gyro.length < 0.008) {
          _correctFusedBasis();
          return;
        }
        final basis = _fusedBasis;
        if (basis == null) return;
        final degrees = 180 / math.pi;
        // 陀螺仪是设备坐标：x 右、y 上、z 朝屏幕外。相机 forward=-z；
        // LiveCameraBasis.rotatedAroundUp 的方向约定是反的，所以这里取负号。
        _fusedBasis = basis
            .rotatedAroundRight(gyro.x * dt * degrees)
            .rotatedAroundUp(-gyro.y * dt * degrees)
            .rotatedAroundForward(-gyro.z * dt * degrees);
        _correctFusedBasis();
      },
      onError: (_) {
        if (mounted) setState(() => _sensorError = true);
      },
      cancelOnError: false,
    );
  }

  LiveCameraBasis? _rawSensorBasis() => LiveCameraBasis.fromSensors(
        accelerometer: _accelerometer,
        magnetometer: _magnetometer,
      );

  void _ensureFusedBasis() {
    if (_fusedBasis != null || !_accelSeen || !_magSeen) return;
    _fusedBasis = _rawSensorBasis();
  }

  /// 互补滤波：陀螺仪负责短时转动，加速度计/磁力计用很小的增益慢慢纠偏。
  ///
  /// 增益按角速度自适应：静止时多信一点绝对方向，快速转动时几乎只信陀螺，
  /// 免得磁力计的噪声把已经转过去的画面又拽回来。
  void _correctFusedBasis() {
    final target = _rawSensorBasis();
    final current = _fusedBasis;
    if (target == null) return;
    if (current == null) {
      _fusedBasis = target;
      return;
    }
    final speed = _gyroscope.length;
    final dot = current.forward.dot(target.forward).clamp(-1.0, 1.0);
    final angle = math.acos(dot);
    // 手指/呼吸级的微抖：不要每一帧都去追加速度计的噪声，否则星图会“呼吸”。
    if (speed < 0.02 && angle < 0.008) return;
    final gain = speed > 0.40
        ? 0.010
        : speed > 0.10
            ? 0.035
            : angle > 0.06
                // 方向真的变了（例如从竖屏转到横屏）：快速跟过去，别慢慢爬。
                ? 0.30
                : 0.12;
    final forward = current.forward.lerp(target.forward, gain).normalized();
    if (forward.length <= 0) return;
    var up = current.up.lerp(target.up, gain);
    up = (up - forward * up.dot(forward)).normalized();
    if (up.length <= 0) return;
    final right = forward.cross(up).normalized();
    if (right.length <= 0) return;
    _fusedBasis = LiveCameraBasis(forward: forward, up: up, right: right);
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
    final sun = sunPosition(_now);
    final sunEnu = equatorialToEnu(
      raDegrees: sun.ra,
      decDegrees: sun.dec,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    final moon = moonPositionAt(_now);
    final moonEnu = equatorialToEnu(
      raDegrees: moon.raDegrees,
      decDegrees: moon.decDegrees,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    _sunAltitude = altitudeDegreesOfEnu(sunEnu);
    _moonAltitude = altitudeDegreesOfEnu(moonEnu);
    _moonPhase = moonPhaseAt(_now).illuminatedFraction;
    _starLimit = _visibility == LiveSkyVisibility.auto
        ? LiveSkyVisibility.autoLimit(
            sunAltitude: _sunAltitude,
            moonAltitude: _moonAltitude,
            moonPhase: _moonPhase,
            hasLocation: _hasLocation,
          )
        : _visibility.fixedLimit;
    _deepSkyLimit = _visibility == LiveSkyVisibility.all
        ? 9.5
        : (_starLimit + 2.5).clamp(5.0, 9.5);
    _stars = enuObjects(
      objects: catalog.stars,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    _starEnu = {
      for (final item in _stars)
        if (item.object.hip != null) item.object.hip!: item.enu,
    };
    // 视觉修正只投影当前观测条件下能看到的亮星；星太多会拖慢匹配，
    // 也会把噪声和暗星当成真对应。
    _trackerStars = [
      for (final item in _stars)
        if (item.object.magnitude <= _starLimit) item,
    ];
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
        if (object.kind == LiveObjectKind.planet ||
            object.kind == LiveObjectKind.sun ||
            object.kind == LiveObjectKind.moon)
          object,
    ];
    _smallBodyObjects = [
      for (final object in all)
        if (object.kind == LiveObjectKind.smallBody) object,
    ];
    // 行星、日月、小天体在走；目标设的是它们时，坐标跟着最新星历更新。
    final target = _targetObject;
    if (target != null &&
        target.kind != LiveObjectKind.star &&
        target.kind != LiveObjectKind.deepSky) {
      for (final object in [..._planetObjects, ..._smallBodyObjects]) {
        if (object.name == target.name && object.kind == target.kind) {
          _targetObject = object;
          break;
        }
      }
    }
    _refreshSkyIfNeeded(force: true);
  }

  /// 静止时把相机解出来的修正做一点低通，避免每一帧都“啪”地跳半度。
  LiveOrientationFix _smoothOrientationFix(LiveOrientationFix next) {
    final previous = _orientationFix;
    if (previous == null || _gyroscope.length > 0.10) return next;
    double blend(double from, double to) {
      var delta = to - from;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;
      return from + delta * 0.55;
    }

    return LiveOrientationFix(
      yawDegrees: blend(previous.yawDegrees, next.yawDegrees),
      pitchDegrees: blend(previous.pitchDegrees, next.pitchDegrees),
      rollDegrees: blend(previous.rollDegrees, next.rollDegrees),
      matches: next.matches,
      rotation: next.rotation,
      residual: next.residual,
      matchedHips: next.matchedHips,
    );
  }

  /// 视场中心最近的天体，用来在屏幕下方给一行小字介绍。
  LiveObject? get _centeredObject {
    final camera = _basis();
    if (camera == null) return null;
    final limit = math.cos((_effectiveFov * 0.06).clamp(2.5, 6.0) * math.pi / 180);
    LiveObject? best;
    var bestDot = limit;
    for (final object in [
      ..._stars.map((item) => item.object),
      ..._planets.map((item) => item.object),
      ..._deepSky.map((item) => item.object),
      ..._smallBodyObjects,
    ]) {
      final enu = equatorialToEnu(
        raDegrees: object.raDegrees,
        decDegrees: object.decDegrees,
        latitudeDegrees: _latitude,
        localSiderealDegrees: _sidereal,
      );
      final dot = camera.forward.dot(enu);
      if (dot > bestDot) {
        bestDot = dot;
        best = object;
      }
    }
    return best;
  }

  String _objectType(LiveObject object) => switch (object.kind) {
        LiveObjectKind.star => t('恒星'),
        LiveObjectKind.deepSky => t('深空'),
        LiveObjectKind.planet => t('行星'),
        LiveObjectKind.smallBody => t('小天体'),
        LiveObjectKind.sun => t('太阳'),
        LiveObjectKind.moon => t('月球'),
      };

  LiveCameraBasis? _basis() {
    if (!_solveMode) {
      // 巡天模式：冻结进入时的那套姿态，不再读 IMU；手指拖动只改 yaw/pitch。
      final frozen = _freeBasis ?? _fallbackSurveyBasis;
      return frozen.corrected(
        yawDegrees: _panYaw,
        pitchDegrees: _panPitch,
        rollDegrees: 0,
      );
    }
    final calibrated = _calibratedBasis();
    if (calibrated == null) return null;
    final fix = _orientationFix;
    if (fix == null) return calibrated;
    // 快速转动时相机帧里的修正已经过期，继续套上去会把星图往回拽。
    if (_gyroscope.length > 0.18) return calibrated;
    return calibrated.corrected(
      yawDegrees: fix.yawDegrees,
      pitchDegrees: fix.pitchDegrees,
      rollDegrees: fix.rollDegrees,
    );
  }

  LiveCameraBasis? _calibratedBasis() {
    final raw = _fusedBasis ?? _rawSensorBasis();
    if (raw == null) return null;
    var basis = _headingOffset == 0
        ? raw
        : raw.rotatedAroundUp(_headingOffset);
    if (_manualYaw != 0 || _manualPitch != 0) {
      basis = basis.corrected(
        yawDegrees: _manualYaw,
        pitchDegrees: _manualPitch,
        rollDegrees: 0,
      );
    }
    return basis;
  }

  double get _effectiveFov => (_fov / _zoom).clamp(10.0, 140.0);

  double get _previewAspect {
    final aspect = _camera?.value.aspectRatio ?? 4 / 3;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final value = portrait ? 1 / aspect : aspect;
    return value.isFinite && value > 0 ? value : 4 / 3;
  }

  Future<void> _onCameraFrame(CameraImage image) async {
    if (!_solveMode || !mounted || _catalog == null || image.planes.isEmpty) {
      return;
    }
    // 锁定后再放大，星点会变少、有效视场也变了；这时候继续匹配容易
    // 把已经对好的姿态带偏。保持锁定，交给 IMU 跟随，缩回 1× 再恢复跟踪。
    if (_locked && _zoom > 1.2) return;
    final now = DateTime.now();
    final interval = _locked
        ? const Duration(milliseconds: 400)
        : const Duration(milliseconds: 300);
    if (now.difference(_lastTrackerRun) < interval) return;
    _lastTrackerRun = now;
    if (image.format.group != ImageFormatGroup.yuv420) return;
    final plane = image.planes.first;
    final detections = LiveStarTracker.detect(
      plane.bytes,
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    if (detections.length < 4) {
      _trackingLost();
      return;
    }
    final base = _calibratedBasis();
    if (base == null) return;
    final tracking = _locked && _trackedStars.isNotEmpty;
    final fix = LiveStarTracker.solve(
      detections: detections,
      // 锁定后只跟这几颗已经对上的星；不再拿整张星表重解。
      stars: tracking ? _trackedStars : _trackerStars,
      basis: base,
      fieldOfViewDegrees: _effectiveFov,
      previewAspect: _previewAspect,
      magnitudeLimit: _starLimit,
      minimumMatches: tracking ? 4 : 6,
      rotation: tracking ? _orientationFix?.rotation : null,
    );
    if (fix == null || !mounted) {
      _trackingLost();
      return;
    }
    setState(() {
      _orientationFix = _smoothOrientationFix(fix);
      _matchedStars = fix.matches;
      _lostFrames = 0;
      _matchedHips = fix.matchedHips;
      _trackedStars = [
        for (final star in _trackerStars)
          if (star.object.hip != null &&
              fix.matchedHips.contains(star.object.hip))
            star,
      ];
      if (!_locked && fix.matches >= 8 && fix.residual < 0.03) {
        _locked = true;
      }
    });
  }

  /// 跟丢一小会儿先忍着；连续几帧都对不上才清掉绿色并解锁。
  void _trackingLost() {
    _lostFrames++;
    final threshold = _locked ? 3 : 2;
    if (_lostFrames < threshold) return;
    if (!mounted) return;
    if (!_locked && _matchedHips.isEmpty) {
      _lostFrames = 0;
      return;
    }
    setState(() {
      _lostFrames = 0;
      _matchedHips = const {};
      _trackedStars = const [];
      _matchedStars = 0;
      if (_locked) {
        _locked = false;
        _orientationFix = null;
      }
    });
  }

  Future<void> _restartTracking() async {
    if (!_solveMode) return;
    setState(() {
      _locked = false;
      _orientationFix = null;
      _matchedStars = 0;
      _matchedHips = const {};
      _trackedStars = const [];
      _lostFrames = 0;
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
    if (!_solveMode) return;
    if (_locked) {
      await _restartTracking();
      return;
    }
    setState(() => _locked = true);
  }

  Future<void> _setSolveMode(bool value) async {
    if (value == _solveMode) return;
    final frozen = value ? null : (_basis() ?? _fallbackSurveyBasis);
    setState(() {
      _solveMode = value;
      _freeBasis = frozen;
      _panYaw = 0;
      _panPitch = 0;
      if (!value) {
        _locked = false;
        _orientationFix = null;
        _matchedHips = const {};
        _trackedStars = const [];
        _matchedStars = 0;
        _redMode = false;
      }
    });
    if (value) {
      await _restartTracking();
    } else {
      await _stopStreaming();
    }
  }

  void _setChartMode(bool value) {
    if (value == _chartMode) return;
    setState(() => _chartMode = value);
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

  Future<void> _openSearchSheet() async {
    final controller = TextEditingController();
    var selected = -1;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: kPanel,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.82,
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final results = _searchObjects(controller.text);
          if (selected >= results.length) selected = -1;
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      onChanged: (_) => setSheetState(() => selected = -1),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: t('搜索天体名称，例如 仙女座星系 / 木星 / 月球'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  if (controller.text.trim().isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: Text(
                        t('输入名称后，点一条结果，再点「设置目标」。'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFA6B5C8),
                        ),
                      ),
                    )
                  else if (results.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: Text(
                        t('没有找到这个名字。'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFA6B5C8),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final item = results[index];
                          final below = item.enu.z < 0;
                          final altitude = altitudeDegreesOfEnu(item.enu);
                          final isSelected = selected == index;
                          return ListTile(
                            selected: isSelected,
                            onTap: () => setSheetState(() => selected = index),
                            title: Text(item.object.name),
                            subtitle: Text(
                              below
                                  ? t('{0} · 高度 {1}° · 地平线下，等它升起', [
                                      _kindLabel(item.object.kind),
                                      altitude.toStringAsFixed(1),
                                    ])
                                  : t('{0} · 高度 {1}°', [
                                      _kindLabel(item.object.kind),
                                      altitude.toStringAsFixed(1),
                                    ]),
                              style: TextStyle(
                                fontSize: 11,
                                color: below
                                    ? const Color(0xFFFFDE77)
                                    : const Color(0xFFA6B5C8),
                              ),
                            ),
                            trailing: isSelected
                                ? TextButton(
                                    onPressed: below
                                        ? null
                                        : () {
                                            _setTarget(item.object);
                                            Navigator.pop(context);
                                          },
                                    child: Text(t('设置目标')),
                                  )
                                : null,
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    controller.dispose();
  }

  List<LiveEnuObject> _searchObjects(String query) {
    final text = query.trim().toLowerCase();
    if (text.isEmpty) return const [];
    final seen = <String>{};
    final hits = <LiveEnuObject>[];
    for (final item in [
      ..._stars,
      ..._deepSky,
      ..._planets,
      ..._smallBodies,
    ]) {
      final name = item.object.name.trim();
      if (name.isEmpty || !name.toLowerCase().contains(text)) continue;
      if (!seen.add('${item.object.kind.name}:$name')) continue;
      hits.add(item);
    }
    hits.sort((a, b) {
      final aboveA = a.enu.z >= 0 ? 0 : 1;
      final aboveB = b.enu.z >= 0 ? 0 : 1;
      if (aboveA != aboveB) return aboveA.compareTo(aboveB);
      return a.object.magnitude.compareTo(b.object.magnitude);
    });
    return hits.take(80).toList();
  }

  String _kindLabel(LiveObjectKind kind) => switch (kind) {
        LiveObjectKind.star => t('恒星'),
        LiveObjectKind.deepSky => t('深空'),
        LiveObjectKind.planet => t('行星'),
        LiveObjectKind.smallBody => t('小天体'),
        LiveObjectKind.sun => t('太阳'),
        LiveObjectKind.moon => t('月球'),
      };

  Future<void> _openNox() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kPanel,
      builder: (_) => LiveNoxPanel(
        bridge: LiveNoxBridge(
          read: _noxRead,
          run: _noxRun,
        ),
      ),
    );
  }

  Map<String, Object?> _noxRead() => {
        'red': _redMode,
        'labels': _layers.contains(_LiveLayer.labels),
        'constellations': _layers.contains(_LiveLayer.constellations),
        'galactic': _showGalactic,
        'below': _showBelowHorizon,
        'locked': _locked,
        'mode': _solveMode ? t('解算') : t('巡天'),
      };

  bool _toggleLayer(_LiveLayer layer) {
    final next = !_layers.contains(layer);
    setState(() {
      if (next) {
        _layers.add(layer);
      } else {
        _layers.remove(layer);
      }
    });
    return next;
  }

  Future<String> _noxRun(String command) async {
    final text = command.trim().toLowerCase();
    if (text.isEmpty) return t('说点什么。');
    if (text == '状态' || text.contains('status')) {
      final center = _centeredObject;
      return t('当前{0}，红光{1}，星名{2}；中心附近：{3}。', [
        _solveMode ? t('解算') : t('巡天'),
        _redMode ? t('开') : t('关'),
        _layers.contains(_LiveLayer.labels) ? t('开') : t('关'),
        center?.name ?? t('没有明显天体'),
      ]);
    }
    if (text.contains('红光')) {
      final on = !text.contains('关') && !text.contains('off');
      setState(() => _redMode = on);
      return on ? t('红光模式已开。') : t('红光模式已关。');
    }
    if (text.contains('银河')) {
      setState(() => _showGalactic = !_showGalactic);
      return t('银河{0}。', [_showGalactic ? t('已显示') : t('已隐藏')]);
    }
    if (text.contains('星座')) {
      final on = _toggleLayer(_LiveLayer.constellations);
      return t('星座连线{0}。', [on ? t('已显示') : t('已隐藏')]);
    }
    if (text.contains('星名') || text.contains('标签')) {
      final on = _toggleLayer(_LiveLayer.labels);
      return t('星名{0}。', [on ? t('已显示') : t('已隐藏')]);
    }
    if (text.contains('地平线')) {
      setState(() => _showBelowHorizon = !_showBelowHorizon);
      return t('地平线下天体{0}。',
          [_showBelowHorizon ? t('已显示') : t('已隐藏')]);
    }
    if (text.contains('锁定')) {
      setState(() => _locked = true);
      return t('已锁定当前姿态。');
    }
    if (text.contains('取消目标')) {
      setState(() => _targetObject = null);
      return t('已取消目标。');
    }
    if (text.contains('找') || text.contains('目标')) {
      final query = text
          .replaceAll('找', '')
          .replaceAll('目标', '')
          .replaceAll('搜索', '')
          .trim();
      if (query.isEmpty) return t('要找哪颗星？');
      final all = [
        ..._stars.map((item) => item.object),
        ..._planets.map((item) => item.object),
        ..._deepSky.map((item) => item.object),
        ..._smallBodyObjects,
      ];
      for (final object in all) {
        if (object.name.toLowerCase().contains(query)) {
          setState(() => _targetObject = object);
          return t('目标已设为{0}。', [object.name]);
        }
      }
      return t('没找到「{0}」。', [query]);
    }
    return t('可以试试：状态、红光、银河、星座、星名、地平线、找木星、取消目标。');
  }

  Future<void> _openStarCalibration() async {
    final candidates = <LiveEnuObject>[
      for (final star in _stars)
        if (star.object.hip != null &&
            star.object.magnitude <= 2.5 &&
            !star.object.name.startsWith('HIP ') &&
            star.enu.z > 0)
          star,
      // 月亮也是高精度绝对参考；它不在恒星表里，单独从太阳系列表补进来。
      for (final body in _planets)
        if (body.object.kind == LiveObjectKind.moon && body.enu.z > 0) body,
    ]..sort((a, b) {
        // 月亮永远置顶；其余按亮度从亮到暗，再按高度。
        if (a.object.kind == LiveObjectKind.moon) return -1;
        if (b.object.kind == LiveObjectKind.moon) return 1;
        final byMagnitude = a.object.magnitude.compareTo(b.object.magnitude);
        if (byMagnitude != 0) return byMagnitude;
        return altitudeDegreesOfEnu(b.enu)
            .compareTo(altitudeDegreesOfEnu(a.enu));
      });
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('现在没有足够亮的星可供校准。'))),
      );
      return;
    }
    final selected = await showModalBottomSheet<LiveObject>(
      context: context,
      showDragHandle: true,
      backgroundColor: kPanel,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                t('选择一颗亮星或月亮'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final item in candidates.take(30))
              ListTile(
                title: Text(item.object.name),
                subtitle: Text(
                  item.object.kind == LiveObjectKind.moon
                      ? t('高度 {0}° · 月亮', [
                          altitudeDegreesOfEnu(item.enu).toStringAsFixed(0),
                        ])
                      : t('高度 {0}° · 星等 {1}', [
                          altitudeDegreesOfEnu(item.enu).toStringAsFixed(0),
                          item.object.magnitude.toStringAsFixed(1),
                        ]),
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.center_focus_strong, size: 18),
                onTap: () => Navigator.pop(context, item.object),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _calibrationStar = selected;
      _locked = false;
    });
  }

  void _cancelStarCalibration() {
    setState(() => _calibrationStar = null);
  }

  void _commitStarCalibration() {
    final star = _calibrationStar;
    if (star == null) return;
    final enu = equatorialToEnu(
      raDegrees: star.raDegrees,
      decDegrees: star.decDegrees,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    );
    if (enu.z <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('这颗星现在在地平线下。'))),
      );
      return;
    }
    final oldFix = _orientationFix;
    setState(() => _orientationFix = null);
    final basis = _calibratedBasis();
    if (basis == null) {
      setState(() => _orientationFix = oldFix);
      return;
    }
    final point = basis.project(
      enu,
      horizontalFovDegrees: _effectiveFov,
      viewport: Size(1, _previewAspect),
      margin: 0,
    );
    if (point == null) {
      setState(() => _orientationFix = oldFix);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('先把这颗星放到画面里，再点固定。'))),
      );
      return;
    }
    final dx = point.dx - 0.5;
    final dy = point.dy - _previewAspect / 2;
    final hfov = _effectiveFov;
    final vfov = 2 *
        math.atan(math.tan(hfov * math.pi / 360) / _previewAspect) *
        180 /
        math.pi;
    var yaw = _manualYaw + dx * hfov;
    if (yaw > 180) yaw -= 360;
    if (yaw < -180) yaw += 360;
    setState(() {
      _manualYaw = yaw;
      _manualPitch =
          (_manualPitch - dy * vfov / _previewAspect).clamp(-89.0, 89.0);
      _calibrationStar = null;
      _orientationFix = null;
      _locked = true;
      _trackedStars = const [];
      _matchedHips = const {};
      _matchedStars = 0;
      _lostFrames = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('已用 {0} 校准，继续用星点跟踪校正。', [star.name]))),
    );
  }

  void _setTarget(LiveObject object) {
    setState(() => _targetObject = object);
    final below = equatorialToEnu(
      raDegrees: object.raDegrees,
      decDegrees: object.decDegrees,
      latitudeDegrees: _latitude,
      localSiderealDegrees: _sidereal,
    ).z < 0;
    if (below) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('目标在地平线下，暂时看不到。'))),
      );
    }
  }

  Future<void> _openLayersSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: kPanel,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.78,
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(VoidCallback action) {
            setState(action);
            setSheetState(() {});
          }

          Widget refChip(
            String label,
            Color color,
            bool selected,
            ValueChanged<bool> onChanged,
          ) =>
              FilterChip(
                avatar: CircleAvatar(backgroundColor: color, radius: 5),
                label: Text(label),
                selected: selected,
                onSelected: (value) => update(() => onChanged(value)),
              );

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ExpansionTile(
                  initiallyExpanded: true,
                  leading: const Icon(Icons.layers_outlined, color: kMint),
                  title: Text(t('显示图层')),
                  subtitle: Text(
                    t('恒星、星座、深空、行星、小天体、名称'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in const [
                          (_LiveLayer.stars, '恒星'),
                          (_LiveLayer.constellations, '星座'),
                          (_LiveLayer.deepSky, '深空'),
                          (_LiveLayer.planets, '行星'),
                          (_LiveLayer.smallBodies, '小天体'),
                          (_LiveLayer.labels, '名称'),
                        ])
                          FilterChip(
                            label: Text(t(entry.$2)),
                            selected: _layers.contains(entry.$1),
                            onSelected: (selected) => update(() {
                              if (selected) {
                                _layers.add(entry.$1);
                              } else {
                                _layers.remove(entry.$1);
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                ),
                const Divider(height: 1),
                ExpansionTile(
                  initiallyExpanded: false,
                  leading: const Icon(Icons.visibility_outlined, color: kMint),
                  title: Text(t('观测条件 · {0}', [_visibility.label])),
                  subtitle: Text(
                    _visibility == LiveSkyVisibility.auto
                        ? t('自动 · 极限星等 {0}', [_starLimit.toStringAsFixed(1)])
                        : t('极限星等约 {0}', [_starLimit.toStringAsFixed(1)]),
                    style: const TextStyle(fontSize: 11),
                  ),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final visibility in LiveSkyVisibility.values)
                          ChoiceChip(
                            label: Text(visibility.label),
                            selected: _visibility == visibility,
                            onSelected: (_) {
                              setSheetState(() {});
                              unawaited(_setVisibility(visibility));
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _visibility.description,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.45,
                        color: Color(0xFFA6B5C8),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t('自动会按太阳高度、月光和月相决定；星隐的地方只画亮星，星海才画到 6 等附近。'),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: Color(0xFF8192A8),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 1),
                ExpansionTile(
                  initiallyExpanded: false,
                  leading: const Icon(Icons.blur_circular, color: kMint),
                  title: Text(t('天球参考线')),
                  subtitle: Text(
                    t('黄道、天赤道、白道、银道'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        refChip('黄道', const Color(0xFFFFD54A), _showEcliptic,
                            (value) => _showEcliptic = value),
                        refChip(
                            '天赤道',
                            const Color(0xFFFF5A5A),
                            _showCelestialEquator,
                            (value) => _showCelestialEquator = value),
                        refChip('白道', const Color(0xFFFFFFFF), _showLunarPath,
                            (value) => _showLunarPath = value),
                        refChip('银道', const Color(0xFFB9C6D8), _showGalactic,
                            (value) => _showGalactic = value),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t('四种颜色对应四条天球大圆；只画地平线以上的一段。'),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: Color(0xFF8192A8),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 1),
                ExpansionTile(
                  initiallyExpanded: false,
                  leading: const Icon(Icons.grid_4x4, color: kMint),
                  title: Text(t('坐标网格')),
                  subtitle: Text(
                    t('地平网格、赤道网格'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        refChip('地平网格', const Color(0xFF9FB3CE),
                            _showAltAzGrid, (value) => _showAltAzGrid = value),
                        refChip('赤道网格', const Color(0xFF9FB3CE),
                            _showEquatorialGrid,
                            (value) => _showEquatorialGrid = value),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t('地平网格是高度/方位，赤道网格是赤经/赤纬；网格间隔随缩放自动加密。'),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        color: Color(0xFF8192A8),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 1),
                ExpansionTile(
                  initiallyExpanded: false,
                  leading: const Icon(Icons.vertical_align_bottom, color: kMint),
                  title: Text(t('地平线以下')),
                  subtitle: Text(
                    _showBelowHorizon ? t('已显示地平线下天体') : t('只显示地平线以上'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _showBelowHorizon,
                      onChanged: (value) =>
                          update(() => _showBelowHorizon = value),
                      title: Text(t('显示地平线下天体')),
                      subtitle: Text(
                        t('星点会变暗；地下的参考圈和网格也一起显示。'),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _setVisibility(LiveSkyVisibility visibility) async {
    if (visibility == _visibility) return;
    setState(() {
      _visibility = visibility;
      _refreshSkyIfNeeded(force: true);
    });
    try {
      await _store.write(key: 'liveVisibility', value: visibility.storageKey);
    } on Exception {
      // 存不下最多是下次回到自动。
    }
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
              decoration: InputDecoration(labelText: t('纬度')),
            ),
            TextField(
              controller: lon,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: InputDecoration(labelText: t('经度')),
            ),
            const SizedBox(height: 8),
            Text(
              t('用于推算当地天球；位置只保存在本机。'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF8192A8)),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context, false);
              _initLocation();
            },
            icon: const Icon(Icons.my_location, size: 16),
            label: Text(t('读取当前位置')),
          ),
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
      _manualYaw = 0;
      _manualPitch = 0;
      _calibrationStar = null;
      _fusedBasis = _rawSensorBasis();
    });
    unawaited(_restartTracking());
    await _store.write(key: 'liveFov', value: '$_fov');
    await _store.write(key: 'liveHeadingOffset', value: '$_headingOffset');
  }

  @override
  Widget build(BuildContext context) {
    final basis = _basis();
    final centered = _centeredObject;
    final layers = {..._layers};
    final targetEnu = _targetObject == null
        ? null
        : equatorialToEnu(
            raDegrees: _targetObject!.raDegrees,
            decDegrees: _targetObject!.decDegrees,
            latitudeDegrees: _latitude,
            localSiderealDegrees: _sidereal,
          );
    final targetBelow = targetEnu != null && targetEnu.z < 0;
    final targetInView = targetEnu != null && basis != null
        ? basis.project(
              targetEnu,
              horizontalFovDegrees: _effectiveFov,
              viewport: Size(1, _previewAspect),
              margin: 0,
            ) !=
            null
        : false;
    final targetAltitude =
        targetEnu == null ? 0.0 : altitudeDegreesOfEnu(targetEnu);
    final targetAzimuth = targetEnu == null
        ? 0.0
        : (math.atan2(targetEnu.x, targetEnu.y) * 180 / math.pi + 360) % 360;
    return Scaffold(
      backgroundColor: Colors.black,
      body: ColorFiltered(
        colorFilter: _redMode ? _redFilter : const ColorFilter.matrix(_identity),
        child: Stack(
          fit: StackFit.expand,
          children: [
          Center(
            child: AspectRatio(
              aspectRatio: _previewAspect,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => _zoomStart = _zoom,
                onScaleUpdate: (details) {
                  // 巡天模式：单指拖动星图，不再跟随手机角度。
                  if (!_solveMode && details.pointerCount <= 1) {
                    final width =
                        math.max(1.0, MediaQuery.sizeOf(context).width);
                    final degPerPixel = _effectiveFov / width;
                    setState(() {
                      var yaw =
                          _panYaw - details.focalPointDelta.dx * degPerPixel;
                      // 方位角是圆的，不该在 ±180° 处硬停住。
                      if (yaw > 180) yaw -= 360;
                      if (yaw < -180) yaw += 360;
                      _panYaw = yaw;
                      _panPitch = (_panPitch +
                              details.focalPointDelta.dy * degPerPixel)
                          .clamp(-89.0, 89.0);
                    });
                  }
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
                    if (basis != null && _chartMode)
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
                          starLimit: _starLimit,
                          deepSkyLimit: _deepSkyLimit,
                          latitude: _latitude,
                          sidereal: _sidereal,
                          showEcliptic: _showEcliptic,
                          showCelestialEquator: _showCelestialEquator,
                          showLunarPath: _showLunarPath,
                          showGalactic: _showGalactic,
                          showAltAzGrid: _showAltAzGrid,
                          showEquatorialGrid: _showEquatorialGrid,
                          showBelowHorizon: _showBelowHorizon,
                          matchedHips: _matchedHips,
                          targetEnu: targetEnu,
                          targetName: _targetObject?.name,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
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
                          !_solveMode
                              ? t('巡天模式 · 自由浏览')
                              : !_chartMode
                                  ? (_locked
                                      ? t('纯净模式 · 已锁定 {0} 颗', [_matchedStars])
                                      : t('纯净模式 · 解算中'))
                                  : (_locked
                                      ? t('已锁定 {0} 颗星', [_matchedStars])
                                      : t('校准中 · 已匹配 {0} 颗', [_matchedStars])),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: !_solveMode
                                ? const Color(0xFFA6B5C8)
                                : _locked
                                    ? kMint.withValues(alpha: 0.9)
                                    : const Color(0xFF8192A8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _roundButton(
                    icon: Icons.nightlight_round,
                    tooltip: t('Nox'),
                    onTap: _openNox,
                  ),
                  const SizedBox(width: 8),
                  if (_solveMode) ...[
                    _roundButton(
                      icon: Icons.star_border_rounded,
                      tooltip: t('亮星校准'),
                      onTap: _openStarCalibration,
                    ),
                    const SizedBox(width: 8),
                    _roundButton(
                      icon: _locked ? Icons.lock : Icons.lock_open,
                      tooltip: _locked ? t('重新锁定') : t('锁定当前姿态'),
                      onTap: _toggleLock,
                    ),
                  ],
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
                  const SizedBox(height: 6),
                  _modeSwitches(),
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
          if (centered != null &&
              _targetObject == null &&
              _calibrationStar == null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 58,
              child: SafeArea(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.66),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    t('{0} · {1} · {2} 等 · 高度 {3}°', [
                      centered.name,
                      _objectType(centered),
                      centered.magnitude.toStringAsFixed(1),
                      altitudeDegreesOfEnu(
                        equatorialToEnu(
                          raDegrees: centered.raDegrees,
                          decDegrees: centered.decDegrees,
                          latitudeDegrees: _latitude,
                          localSiderealDegrees: _sidereal,
                        ),
                      ).round(),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFD8E2F0),
                    ),
                  ),
                ),
              ),
            ),
          if (_calibrationStar != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 64,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF6EE7A8).withValues(alpha: 0.7),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.star_border_rounded,
                        size: 20,
                        color: Color(0xFF6EE7A8),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t('校准：{0} · 把它放到中心准星，再点固定', [
                            _calibrationStar!.name,
                          ]),
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.35,
                            color: Color(0xFFD8F5E5),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _commitStarCalibration,
                        child: Text(t('固定')),
                      ),
                      IconButton(
                        onPressed: _cancelStarCalibration,
                        tooltip: t('取消'),
                        icon: const Icon(Icons.close, size: 16),
                        color: const Color(0xFFA6B5C8),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_targetObject != null && _calibrationStar == null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 64,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFFFDE77).withValues(alpha: 0.6),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.gps_fixed,
                        size: 18,
                        color: Color(0xFFFFDE77),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          targetBelow
                              ? t('目标：{0} · 地平线下，高度 {1}°', [
                                  _targetObject!.name,
                                  targetAltitude.toStringAsFixed(1),
                                ])
                              : targetInView
                                  ? t('目标：{0} · 高度 {1}° · 方位 {2}°', [
                                      _targetObject!.name,
                                      targetAltitude.toStringAsFixed(1),
                                      targetAzimuth.toStringAsFixed(0),
                                    ])
                                  : t('目标：{0} · 在视野外，按箭头转动手机', [
                                      _targetObject!.name,
                                    ]),
                          style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.35,
                            color: Color(0xFFFFE9A8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_solveMode) ...[
                    _roundButton(
                      icon: _redMode ? Icons.circle : Icons.circle_outlined,
                      color: const Color(0xFFFF5A5A),
                      tooltip: _redMode ? t('关闭红光模式') : t('红光模式'),
                      onTap: () => setState(() => _redMode = !_redMode),
                    ),
                    const SizedBox(width: 10),
                  ],
                  _roundButton(
                    icon: _targetObject == null ? Icons.search : Icons.close,
                    tooltip: _targetObject == null
                        ? t('搜索天体')
                        : t('取消目标'),
                    onTap: _targetObject == null
                        ? _openSearchSheet
                        : () => setState(() => _targetObject = null),
                  ),
                  const SizedBox(width: 10),
                  _roundButton(
                    icon: Icons.keyboard_arrow_up_rounded,
                    tooltip: t('展开图层与观测条件'),
                    onTap: _openLayersSheet,
                  ),
                ],
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }

  /// 顶部两组独立开关：解算/巡天、星图/纯净。
  Widget _modeSwitches() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.48),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            _switchPill(
              label: t('解算'),
              selected: _solveMode,
              onTap: () => _setSolveMode(true),
            ),
            _switchPill(
              label: t('巡天'),
              selected: !_solveMode,
              onTap: () => _setSolveMode(false),
            ),
            const SizedBox(width: 6),
            _switchPill(
              label: t('星图'),
              selected: _chartMode,
              onTap: () => _setChartMode(true),
            ),
            _switchPill(
              label: t('纯净'),
              selected: !_chartMode,
              onTap: () => _setChartMode(false),
            ),
          ],
        ),
      );

  Widget _switchPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      FilterChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        showCheckmark: false,
      );

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color color = kMint,
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
              child: Icon(icon, size: 20, color: color),
            ),
          ),
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
    required this.starLimit,
    required this.deepSkyLimit,
    required this.latitude,
    required this.sidereal,
    required this.showEcliptic,
    required this.showCelestialEquator,
    required this.showLunarPath,
    required this.showGalactic,
    required this.showAltAzGrid,
    required this.showEquatorialGrid,
    required this.showBelowHorizon,
    required this.matchedHips,
    required this.targetEnu,
    required this.targetName,
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
  final double starLimit;
  final double deepSkyLimit;
  final double latitude;
  final double sidereal;
  final bool showEcliptic;
  final bool showCelestialEquator;
  final bool showLunarPath;
  final bool showGalactic;
  final bool showAltAzGrid;
  final bool showEquatorialGrid;
  final bool showBelowHorizon;
  final Set<int> matchedHips;
  final LiveVec3? targetEnu;
  final String? targetName;
  final bool showStars;
  final bool showConstellations;
  final bool showDeepSky;
  final bool showPlanets;
  final bool showSmallBodies;
  final bool showLabels;

  @override
  void paint(Canvas canvas, Size size) {
    _paintHorizon(canvas, size);
    _paintZenith(canvas, size);
    if (showAltAzGrid) _paintAltAzGrid(canvas, size);
    if (showEquatorialGrid) _paintEquatorialGrid(canvas, size);
    if (showEcliptic) {
      _paintReferenceCircle(canvas, size, _eclipticPoints(), const Color(0xFFFFD54A));
    }
    if (showCelestialEquator) {
      _paintReferenceCircle(
          canvas, size, _celestialEquatorPoints(), const Color(0xFFFF5A5A));
    }
    if (showLunarPath) {
      _paintReferenceCircle(
          canvas, size, _lunarPathPoints(), const Color(0xFFFFFFFF));
    }
    if (showGalactic) {
      _paintReferenceCircle(canvas, size, _galacticPoints(), const Color(0xFFB9C6D8));
    }
    if (showConstellations) _paintConstellations(canvas, size);
    if (showStars) _paintStars(canvas, size);
    if (showDeepSky) _paintDeepSky(canvas, size);
    if (showPlanets) _paintBodies(canvas, size, planets);
    if (showSmallBodies) {
      _paintBodies(canvas, size, smallBodies);
    }
    _paintTarget(canvas, size);
  }

  // ---------- 天球参考圈与坐标网格 ----------

  double get _gridStepDegrees {
    if (fov >= 80) return 30;
    if (fov >= 45) return 15;
    if (fov >= 25) return 10;
    if (fov >= 12) return 5;
    return 2;
  }

  List<LiveVec3> _ringFromEquatorial(
    ({double ra, double dec}) Function(double longitude) convert, {
    double step = 3,
  }) {
    final points = <LiveVec3>[];
    for (var lon = 0.0; lon < 360; lon += step) {
      final eq = convert(lon);
      points.add(
        equatorialToEnu(
          raDegrees: eq.ra,
          decDegrees: eq.dec,
          latitudeDegrees: latitude,
          localSiderealDegrees: sidereal,
        ),
      );
    }
    return points;
  }

  List<LiveVec3> _eclipticPoints() => _ringFromEquatorial(
        (lon) => eclipticToEquatorialDegrees(lon, 0),
      );

  List<LiveVec3> _celestialEquatorPoints() => _ringFromEquatorial(
        (lon) => (ra: lon, dec: 0.0),
      );

  List<LiveVec3> _lunarPathPoints() {
    final node = lunarAscendingNodeDegrees(DateTime.now().toUtc());
    return _ringFromEquatorial(
      (lon) => lunarOrbitToEquatorialDegrees(lon, node),
    );
  }

  List<LiveVec3> _galacticPoints() => _ringFromEquatorial(
        (lon) => galacticToEquatorialDegrees(lon, 0),
      );

  void _paintReferenceCircle(
    Canvas canvas,
    Size size,
    List<LiveVec3> points,
    Color color,
  ) {
    final path = Path();
    var drawing = false;
    for (final enu in points) {
      if (!showBelowHorizon && enu.z < 0) {
        drawing = false;
        continue;
      }
      final point = basis.project(
        enu,
        horizontalFovDegrees: fov,
        viewport: size,
        margin: 80,
      );
      if (point == null) {
        drawing = false;
        continue;
      }
      if (drawing) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        drawing = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: 0.85),
    );
  }

  void _paintPolyline(
    Canvas canvas,
    Size size,
    List<LiveVec3> points,
    Color color,
  ) {
    final path = Path();
    var drawing = false;
    for (final enu in points) {
      if (!showBelowHorizon && enu.z < 0) {
        drawing = false;
        continue;
      }
      final point = basis.project(
        enu,
        horizontalFovDegrees: fov,
        viewport: size,
        margin: 40,
      );
      if (point == null) {
        drawing = false;
        continue;
      }
      if (drawing) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        drawing = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = color,
    );
  }

  void _paintAltAzGrid(Canvas canvas, Size size) {
    final color = const Color(0xFF9FB3CE).withValues(alpha: 0.28);
    final step = _gridStepDegrees;
    final startAlt = showBelowHorizon ? -90.0 : 0.0;
    for (var alt = startAlt; alt <= 90; alt += step) {
      final altRad = alt * math.pi / 180;
      final points = <LiveVec3>[
        for (var az = 0.0; az <= 360; az += 3)
          LiveVec3(
            math.cos(altRad) * math.sin(az * math.pi / 180),
            math.cos(altRad) * math.cos(az * math.pi / 180),
            math.sin(altRad),
          ),
      ];
      _paintPolyline(canvas, size, points, color);
    }
    for (var az = 0.0; az < 360; az += step) {
      final points = <LiveVec3>[
        for (var alt = startAlt; alt <= 90; alt += 3)
          LiveVec3(
            math.cos(alt * math.pi / 180) * math.sin(az * math.pi / 180),
            math.cos(alt * math.pi / 180) * math.cos(az * math.pi / 180),
            math.sin(alt * math.pi / 180),
          ),
      ];
      _paintPolyline(canvas, size, points, color);
    }
  }

  void _paintEquatorialGrid(Canvas canvas, Size size) {
    final color = const Color(0xFF9FB3CE).withValues(alpha: 0.24);
    final step = _gridStepDegrees;
    for (var dec = -80.0; dec <= 80; dec += step) {
      final points = <LiveVec3>[
        for (var ra = 0.0; ra <= 360; ra += 3)
          equatorialToEnu(
            raDegrees: ra,
            decDegrees: dec,
            latitudeDegrees: latitude,
            localSiderealDegrees: sidereal,
          ),
      ];
      _paintPolyline(canvas, size, points, color);
    }
    for (var ra = 0.0; ra < 360; ra += step) {
      final points = <LiveVec3>[
        for (var dec = -85.0; dec <= 85; dec += 3)
          equatorialToEnu(
            raDegrees: ra,
            decDegrees: dec,
            latitudeDegrees: latitude,
            localSiderealDegrees: sidereal,
          ),
      ];
      _paintPolyline(canvas, size, points, color);
    }
  }

  /// 目标高亮：在视野里画准星；不在视野里就在屏幕边缘画箭头。
  void _paintTarget(Canvas canvas, Size size) {
    final enu = targetEnu;
    final name = targetName;
    if (enu == null || name == null || enu.z < 0) return;
    final color = const Color(0xFFFFDE77);
    final point = basis.project(
      enu,
      horizontalFovDegrees: fov,
      viewport: size,
      margin: 0,
    );
    if (point != null) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color;
      canvas.drawCircle(point, 18, paint);
      canvas.drawCircle(
        point,
        24,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.45),
      );
      canvas.drawLine(point - const Offset(26, 0), point - const Offset(12, 0), paint);
      canvas.drawLine(point + const Offset(12, 0), point + const Offset(26, 0), paint);
      canvas.drawLine(point - const Offset(0, 26), point - const Offset(0, 12), paint);
      canvas.drawLine(point + const Offset(0, 12), point + const Offset(0, 26), paint);
      _label(canvas, point + const Offset(28, -10), '目标 · $name', color);
      return;
    }

    // 目标在画面外：用相机右/上基底算它在屏幕上的方向。
    var dx = enu.dot(basis.right);
    var dy = -enu.dot(basis.up);
    final dz = enu.dot(basis.forward);
    if (dz <= 0) {
      // 在身后时，左右转是最短路径；正后方则默认向右转。
      dx = dx.abs() < 0.05 ? 1 : dx.sign;
      dy = 0;
    }
    var direction = Offset(dx, dy);
    if (direction.distance < 1e-4) direction = const Offset(0, -1);
    final unit = direction / direction.distance;
    final center = size.center(Offset.zero);
    final maxX = math.max(1.0, size.width / 2 - 54);
    final maxY = math.max(1.0, size.height / 2 - 54);
    var scale = double.infinity;
    if (unit.dx.abs() > 1e-3) scale = math.min(scale, maxX / unit.dx.abs());
    if (unit.dy.abs() > 1e-3) scale = math.min(scale, maxY / unit.dy.abs());
    if (!scale.isFinite) scale = 0;
    final position = center + unit * scale;
    final angle = math.atan2(unit.dy, unit.dx) + math.pi / 2;
    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.rotate(angle);
    final arrow = Path()
      ..moveTo(0, -17)
      ..lineTo(-11, 9)
      ..lineTo(0, 4)
      ..lineTo(11, 9)
      ..close();
    canvas.drawPath(arrow, Paint()..color = color);
    canvas.restore();
    _label(
      canvas,
      position + const Offset(0, 20),
      dz <= 0 ? '目标在身后 · 转向' : '目标 · $name',
      color,
    );
  }

  /// 地平线和东南西北。实时模式里用户经常把手机举到地平线附近，
  /// 没有这条线就分不清「星在地上还是天上」。
  void _paintHorizon(Canvas canvas, Size size) {
    final emphasis = showBelowHorizon;
    final color = emphasis
        ? const Color(0xFF6EE7A8)
        : Colors.white.withValues(alpha: 0.16);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = emphasis ? 2.4 : 0.9
      ..color = color;
    Offset? previous;
    Offset? labelPoint;
    for (var azimuth = 0; azimuth <= 360; azimuth += 4) {
      final radians = azimuth * math.pi / 180;
      final point = basis.project(
        LiveVec3(math.sin(radians), math.cos(radians), 0),
        horizontalFovDegrees: fov,
        viewport: size,
        margin: 0,
      );
      if (point != null && previous != null) {
        canvas.drawLine(previous, point, paint);
      }
      if (point != null && labelPoint == null) labelPoint = point;
      previous = point;
    }
    if (emphasis && labelPoint != null) {
      _label(
        canvas,
        labelPoint + const Offset(6, -16),
        t('地平线'),
        const Color(0xFF6EE7A8),
      );
    }
    for (final (azimuth, label) in const [
      (0.0, 'N'),
      (90.0, 'E'),
      (180.0, 'S'),
      (270.0, 'W'),
    ]) {
      final radians = azimuth * math.pi / 180;
      final point = basis.project(
        LiveVec3(math.sin(radians), math.cos(radians), 0),
        horizontalFovDegrees: fov,
        viewport: size,
        margin: 0,
      );
      if (point != null) {
        _label(canvas, point + const Offset(4, -16), label,
            Colors.white.withValues(alpha: 0.42));
      }
    }
  }

  /// 天顶标记：绿色圆点 + 加粗圆环，抬头就知道正上方在哪。
  void _paintZenith(Canvas canvas, Size size) {
    final point = basis.project(
      LiveVec3.up,
      horizontalFovDegrees: fov,
      viewport: size,
      margin: 0,
    );
    if (point == null) return;
    const color = Color(0xFF6EE7A8);
    canvas.drawCircle(
      point,
      13,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = color,
    );
    canvas.drawCircle(point, 3.2, Paint()..color = color);
    _label(canvas, point + const Offset(14, -18), t('天顶'), color);
  }

  void _paintStars(Canvas canvas, Size size) {
    for (final item in stars) {
      if (!showBelowHorizon && item.enu.z < 0) continue;
      if (item.object.magnitude > starLimit) continue;
      final point = basis.project(
        item.enu,
        horizontalFovDegrees: fov,
        viewport: size,
      );
      if (point == null) continue;
      final magnitude = item.object.magnitude;
      final belowFactor = item.enu.z < 0 ? 0.35 : 1.0;
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
          alpha: ((0.55 + (5 - magnitude).clamp(0, 4) * 0.1).clamp(0.45, 0.95)) *
              belowFactor,
        ),
      );
      if (item.object.hip != null &&
          matchedHips.contains(item.object.hip)) {
        // 已经和星表对上的星点：绿色点 + 一圈淡绿，跟丢后这一组会消失。
        canvas.drawCircle(
          point,
          radius + 2.4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = kMint.withValues(alpha: 0.95),
        );
        canvas.drawCircle(
          point,
          radius + 0.8,
          Paint()..color = kMint,
        );
      }
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
        if (!showBelowHorizon && (a.z < 0 || b.z < 0)) continue;
        if (segment.a.magnitude > starLimit ||
            segment.b.magnitude > starLimit) {
          continue;
        }
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
      if (!showBelowHorizon && item.enu.z < 0) continue;
      if (item.object.magnitude > deepSkyLimit) continue;
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
  ) {
    for (final item in bodies) {
      if (!showBelowHorizon && item.enu.z < 0) continue;
      final point = basis.project(
        item.enu,
        horizontalFovDegrees: fov,
        viewport: size,
      );
      if (point == null) continue;
      final color = switch (item.object.kind) {
        LiveObjectKind.sun => const Color(0xFFFFC04D),
        LiveObjectKind.moon => const Color(0xFFE8EEF5),
        LiveObjectKind.smallBody => const Color(0xFF7FD8FF),
        _ => const Color(0xFFFFAB40),
      };
      final radius = item.object.kind == LiveObjectKind.sun ||
              item.object.kind == LiveObjectKind.moon
          ? 5.5
          : 4.2;
      if (item.object.kind == LiveObjectKind.moon &&
          item.object.moonIlluminatedFraction != null) {
        _paintMoonDisc(
          canvas,
          point,
          radius + 1,
          item.object.moonIlluminatedFraction!,
          item.object.moonWaxing ?? true,
        );
      } else {
        canvas.drawCircle(point, radius, Paint()..color = color);
        canvas.drawCircle(
          point,
          radius + 2.8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = color.withValues(alpha: 0.8),
        );
      }
      if (showLabels) {
        final text = item.object.note == null ||
                item.object.kind == LiveObjectKind.moon
            ? item.object.name
            : '${item.object.name} · ${item.object.note}';
        _label(canvas, point + const Offset(7, -8), text, color);
      }
    }
  }

  /// 用亮面形状表示月相：白银色是被照亮的部分，深色是暗面。
  void _paintMoonDisc(
    Canvas canvas,
    Offset center,
    double radius,
    double fraction,
    bool waxing,
  ) {
    final lit = const Color(0xFFE8EEF5);
    final dark = const Color(0xFF172033);
    final path = Path()..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.save();
    canvas.clipPath(path);
    canvas.drawCircle(center, radius, Paint()..color = dark);
    final f = fraction.clamp(0.0, 1.0);
    final direction = waxing ? 1.0 : -1.0;
    if (f >= 0.5) {
      canvas.drawCircle(center, radius, Paint()..color = lit);
      final width = math.max(0.4, 2 * radius * (1 - f));
      canvas.drawOval(
        Rect.fromCenter(
          center: center.translate(-direction * radius * 0.85, 0),
          width: width,
          height: radius * 2,
        ),
        Paint()..color = dark,
      );
    } else {
      canvas.drawCircle(
        center.translate(direction * radius * 2 * (1 - f), 0),
        radius,
        Paint()..color = lit,
      );
    }
    canvas.restore();
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = lit.withValues(alpha: 0.75),
    );
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
