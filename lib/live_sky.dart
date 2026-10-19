import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

import 'ephemeris.dart';
import 'smallbodies.dart';
import 'strings.dart';

/// 实时星图的纯计算层：星表、坐标变换、传感器姿态、屏幕投影。
///
/// 这里故意不依赖相机/传感器插件，方便单测；界面那一层只负责把相机画面和
/// 这些投影叠在一起。
class LiveVec3 {
  const LiveVec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  static const zero = LiveVec3(0, 0, 0);
  static const up = LiveVec3(0, 0, 1);
  static const north = LiveVec3(0, 1, 0);
  static const east = LiveVec3(1, 0, 0);

  LiveVec3 operator +(LiveVec3 other) =>
      LiveVec3(x + other.x, y + other.y, z + other.z);
  LiveVec3 operator -(LiveVec3 other) =>
      LiveVec3(x - other.x, y - other.y, z - other.z);
  LiveVec3 operator *(double scale) => LiveVec3(x * scale, y * scale, z * scale);

  double dot(LiveVec3 other) => x * other.x + y * other.y + z * other.z;

  LiveVec3 cross(LiveVec3 other) => LiveVec3(
        y * other.z - z * other.y,
        z * other.x - x * other.z,
        x * other.y - y * other.x,
      );

  double get length => math.sqrt(x * x + y * y + z * z);

  LiveVec3 normalized() {
    final length = this.length;
    if (length <= 1e-9 || !length.isFinite) return zero;
    return this * (1 / length);
  }

  LiveVec3 lerp(LiveVec3 target, double t) => this * (1 - t) + target * t;

  @override
  String toString() =>
      'LiveVec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

/// 设备姿态：把「天球 ENU 单位向量」投到相机画面。
class LiveCameraBasis {
  const LiveCameraBasis({
    required this.forward,
    required this.up,
    required this.right,
  });

  /// 相机光轴（后置摄像头朝 -z）在世界 ENU 里的方向。
  final LiveVec3 forward;

  /// 画面「上」在世界 ENU 里的方向，已对 [forward] 正交化。
  final LiveVec3 up;

  /// 画面「右」在世界 ENU 里的方向。
  final LiveVec3 right;

  /// 由加速度计与磁力计估姿态。
  ///
  /// 加速度计在静止时指向「上」（[sensors_plus] 的口径），磁力计的水平
  /// 分量指向磁北。两个向量先归一化，再把磁场里沿重力方向的分量去掉。
  static LiveCameraBasis? fromSensors({
    required LiveVec3 accelerometer,
    required LiveVec3 magnetometer,
  }) {
    final upDevice = accelerometer.normalized();
    if (upDevice.length <= 0) return null;
    final magnetic = magnetometer - upDevice * magnetometer.dot(upDevice);
    final northDevice = magnetic.normalized();
    if (northDevice.length <= 0) return null;
    final eastDevice = northDevice.cross(upDevice).normalized();
    if (eastDevice.length <= 0) return null;

    // 后置摄像头朝设备 -z；画面「上」是设备 +y。
    const cameraDevice = LiveVec3(0, 0, -1);
    const screenUpDevice = LiveVec3(0, 1, 0);
    final forward = LiveVec3(
      cameraDevice.dot(eastDevice),
      cameraDevice.dot(northDevice),
      cameraDevice.dot(upDevice),
    ).normalized();
    var screenUp = LiveVec3(
      screenUpDevice.dot(eastDevice),
      screenUpDevice.dot(northDevice),
      screenUpDevice.dot(upDevice),
    );
    screenUp = (screenUp - forward * screenUp.dot(forward)).normalized();
    final right = forward.cross(screenUp).normalized();
    if (forward.length <= 0 || screenUp.length <= 0 || right.length <= 0) {
      return null;
    }
    return LiveCameraBasis(forward: forward, up: screenUp, right: right);
  }

  /// 绕世界「上」方向转 [degrees] 度。用来做用户方位校准。
  LiveCameraBasis rotatedAroundUp(double degrees) {
    final radians = degrees * math.pi / 180;
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);
    LiveVec3 rotate(LiveVec3 value) => LiveVec3(
          value.x * cosA + value.y * sinA,
          -value.x * sinA + value.y * cosA,
          value.z,
        );
    return LiveCameraBasis(
      forward: rotate(forward).normalized(),
      up: rotate(up).normalized(),
      right: rotate(right).normalized(),
    );
  }

  /// 把天球 ENU 方向投影到屏幕。返回 null 表示在相机背后或画面外。
  Offset? project(
    LiveVec3 enu, {
    required double horizontalFovDegrees,
    required Size viewport,
    double margin = 40,
  }) {
    final z = enu.dot(forward);
    if (z <= 0.02) return null;
    final x = enu.dot(right);
    final y = enu.dot(up);
    final fov = horizontalFovDegrees.clamp(20.0, 140.0) * math.pi / 180;
    final focal = viewport.width / (2 * math.tan(fov / 2));
    final screenX = viewport.width / 2 + focal * x / z;
    final screenY = viewport.height / 2 - focal * y / z;
    if (!screenX.isFinite || !screenY.isFinite) return null;
    if (screenX < -margin ||
        screenY < -margin ||
        screenX > viewport.width + margin ||
        screenY > viewport.height + margin) {
      return null;
    }
    return Offset(screenX, screenY);
  }
}

/// 一次计算里，天体在 ENU 中的单位向量。
class LiveEnuObject {
  const LiveEnuObject(this.object, this.enu);

  final LiveObject object;
  final LiveVec3 enu;
}

/// 实时星图里的一颗星/一个天体。
class LiveObject {
  const LiveObject({
    required this.name,
    required this.raDegrees,
    required this.decDegrees,
    required this.magnitude,
    required this.kind,
    this.sizeArcmin,
    this.hip,
  });

  final String name;
  final double raDegrees;
  final double decDegrees;
  final double magnitude;
  final LiveObjectKind kind;
  final double? sizeArcmin;
  final int? hip;

  LiveObject copyWithName(String name) => LiveObject(
        name: name,
        raDegrees: raDegrees,
        decDegrees: decDegrees,
        magnitude: magnitude,
        kind: kind,
        sizeArcmin: sizeArcmin,
        hip: hip,
      );
}

enum LiveObjectKind { star, deepSky, planet, smallBody }

/// 一条星座连线。
class LiveConstellationSegment {
  const LiveConstellationSegment(this.a, this.b);

  final LiveObject a;
  final LiveObject b;
}

class LiveConstellation {
  const LiveConstellation(this.name, this.segments);

  final String name;
  final List<LiveConstellationSegment> segments;
}

/// 内置亮星/星座/深空目录。进入实时模式时读一次，之后只做投影。
class LiveCatalog {
  LiveCatalog._({
    required this.stars,
    required this.constellations,
    required this.deepSky,
    this.smallBodies,
  });

  final List<LiveObject> stars;
  final List<LiveConstellation> constellations;
  final List<LiveObject> deepSky;
  final SmallBodyCatalog? smallBodies;

  static Future<LiveCatalog> load() async {
    final starsJson = jsonDecode(await rootBundle.loadString('assets/catalog/stars.json'));
    final namesJson = jsonDecode(await rootBundle.loadString('assets/catalog/names.json'));
    final constellationsJson =
        jsonDecode(await rootBundle.loadString('assets/catalog/constellations.json'));
    final deepSkyJson = jsonDecode(await rootBundle.loadString('assets/catalog/deepsky.json'));
    SmallBodyCatalog? smallBodies;
    try {
      smallBodies = await SmallBodyCatalog.load(rootBundle);
    } on Exception {
      smallBodies = null;
    }

    final names = <int, Map<String, dynamic>>{
      for (final entry in (namesJson as Map<String, dynamic>).entries)
        int.tryParse(entry.key) ?? -1: entry.value as Map<String, dynamic>,
    };
    final english = appLanguage.value.code == 'en';
    final stars = <LiveObject>[];
    final byHip = <int, LiveObject>{};
    for (final row in starsJson as List<dynamic>) {
      if (row is! List || row.length < 4) continue;
      final hip = (row[0] as num).toInt();
      final ra = (row[1] as num).toDouble();
      final dec = (row[2] as num).toDouble();
      final magnitude = (row[3] as num).toDouble();
      // 肉眼/手机广角能看到的亮星；再暗的标上去只会糊成一片。
      if (magnitude > 6.4) continue;
      final nameInfo = names[hip];
      final name = _displayName(nameInfo, english) ?? '';
      final star = LiveObject(
        name: name.isEmpty ? 'HIP $hip' : name,
        raDegrees: ra,
        decDegrees: dec,
        magnitude: magnitude,
        kind: LiveObjectKind.star,
        hip: hip,
      );
      stars.add(star);
      byHip[hip] = star;
    }
    stars.sort((a, b) => a.magnitude.compareTo(b.magnitude));

    // 星座表是按 HIP 编号连线的；两边都必须在亮星表里才画得出来。
    final constellations = <LiveConstellation>[];
    for (final entry in (constellationsJson as Map<String, dynamic>).entries) {
      final data = entry.value as Map<String, dynamic>;
      final rawLines = data['lines'];
      if (rawLines is! List) continue;
      final segments = <LiveConstellationSegment>[];
      for (final line in rawLines) {
        if (line is! List || line.length < 2) continue;
        final a = byHip[(line[0] as num).toInt()];
        final b = byHip[(line[1] as num).toInt()];
        if (a == null || b == null) continue;
        segments.add(LiveConstellationSegment(a, b));
      }
      if (segments.isEmpty) continue;
      final name = english
          ? (data['en'] as String? ?? entry.key)
          : (data['zh'] as String? ?? data['en'] as String? ?? entry.key);
      constellations.add(LiveConstellation(name, segments));
    }

    final deepSky = <LiveObject>[];
    for (final row in deepSkyJson as List<dynamic>) {
      if (row is! List || row.length < 4) continue;
      final magnitude = row.length > 5 ? (row[5] as num?)?.toDouble() : null;
      // 深空默认不显示；只留肉眼/小双筒可能看到的，避免几千个标签。
      if (magnitude == null || magnitude > 9.5) continue;
      final size = row.length > 4 ? (row[4] as num?)?.toDouble() : null;
      final name = row[0] as String? ?? '';
      if (name.isEmpty) continue;
      deepSky.add(
        LiveObject(
          name: name,
          raDegrees: (row[1] as num).toDouble(),
          decDegrees: (row[2] as num).toDouble(),
          magnitude: magnitude,
          kind: LiveObjectKind.deepSky,
          sizeArcmin: size,
        ),
      );
    }

    return LiveCatalog._(
      stars: stars,
      constellations: constellations,
      deepSky: deepSky,
      smallBodies: smallBodies,
    );
  }

  static String? _displayName(Map<String, dynamic>? info, bool english) {
    if (info == null) return null;
    final zh = (info['zh'] as String?)?.trim();
    final en = (info['en'] as String?)?.trim();
    final bayer = (info['bayer'] as String?)?.trim();
    if (english) return en?.isNotEmpty == true ? en : zh;
    return zh?.isNotEmpty == true ? zh : (en ?? bayer);
  }

  /// 当前时刻的太阳系天体。小行星/彗星用内置根数，按亮度筛过。
  List<LiveObject> solarSystemAt(DateTime utc) {
    final bodies = <LiveObject>[];
    final sun = sunPosition(utc);
    for (final body in [...predictedBodies(utc), sun]) {
      bodies.add(
        LiveObject(
          name: body.name,
          raDegrees: body.ra,
          decDegrees: body.dec,
          magnitude: body.magnitude ?? -1,
          kind: LiveObjectKind.planet,
        ),
      );
    }
    final catalog = smallBodies;
    if (catalog != null) {
      for (final body in catalog.visibleBodies(
        utc,
        sunRa: sun.ra,
        sunDec: sun.dec,
      )) {
        bodies.add(
          LiveObject(
            name: body.name,
            raDegrees: body.ra,
            decDegrees: body.dec,
            magnitude: body.magnitude ?? 12,
            kind: LiveObjectKind.smallBody,
          ),
        );
      }
    }
    return bodies;
  }
}

// ---------------------------------------------------------------------------
// 天球坐标
// ---------------------------------------------------------------------------

double julianDayUtc(DateTime utc) =>
    utc.millisecondsSinceEpoch / 86400000.0 + 2440587.5;

/// 格林尼治平恒星时（度）。
double greenwichSiderealDegrees(DateTime utc) {
  final jd = julianDayUtc(utc);
  final d = jd - 2451545.0;
  final t = d / 36525.0;
  var value = 280.46061837 +
      360.98564736629 * d +
      0.000387933 * t * t -
      t * t * t / 38710000.0;
  value %= 360;
  if (value < 0) value += 360;
  return value;
}

/// 当地恒星时（度）。
double localSiderealDegrees(DateTime utc, double longitudeDegrees) {
  final value = greenwichSiderealDegrees(utc) + longitudeDegrees;
  return value % 360;
}

/// 赤道坐标 → 地平 ENU 单位向量。
LiveVec3 equatorialToEnu({
  required double raDegrees,
  required double decDegrees,
  required double latitudeDegrees,
  required double localSiderealDegrees,
}) {
  const radians = math.pi / 180;
  final hourAngle = (localSiderealDegrees - raDegrees) * radians;
  final dec = decDegrees * radians;
  final lat = latitudeDegrees * radians;
  final sinDec = math.sin(dec);
  final cosDec = math.cos(dec);
  final sinLat = math.sin(lat);
  final cosLat = math.cos(lat);
  final east = -cosDec * math.sin(hourAngle);
  final north = sinDec * cosLat - cosDec * sinLat * math.cos(hourAngle);
  final up = sinDec * sinLat + cosDec * cosLat * math.cos(hourAngle);
  return LiveVec3(east, north, up);
}

/// 把一批天体换算成当前时刻的 ENU，供每帧快速投影。
List<LiveEnuObject> enuObjects({
  required Iterable<LiveObject> objects,
  required double latitudeDegrees,
  required double localSiderealDegrees,
}) =>
    [
      for (final object in objects)
        LiveEnuObject(
          object,
          equatorialToEnu(
            raDegrees: object.raDegrees,
            decDegrees: object.decDegrees,
            latitudeDegrees: latitudeDegrees,
            localSiderealDegrees: localSiderealDegrees,
          ),
        ),
    ];

/// 天体是否在地平线以上（up > 0）。
bool isAboveHorizon(LiveVec3 enu) => enu.z > 0;

/// 方位角/高度角，调试和 UI 显示用。
(double azimuth, double altitude) enuToAzAlt(LiveVec3 enu) {
  final horizontal = math.sqrt(enu.x * enu.x + enu.y * enu.y);
  var azimuth = math.atan2(enu.x, enu.y) * 180 / math.pi;
  if (azimuth < 0) azimuth += 360;
  final altitude = math.atan2(enu.z, horizontal) * 180 / math.pi;
  return (azimuth, altitude);
}
