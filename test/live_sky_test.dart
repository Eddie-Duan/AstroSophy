import 'dart:typed_data';
import 'dart:ui';

import 'package:astrosophy/live_sky.dart';
import 'package:astrosophy/live_star_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置星表能载入亮星、星座和深空', () async {
    final catalog = await LiveCatalog.load();
    expect(catalog.stars.length, greaterThan(1000));
    expect(catalog.constellations, isNotEmpty);
    expect(catalog.stars.first.magnitude, lessThanOrEqualTo(6.4));
    final solar = catalog.solarSystemAt(DateTime.utc(2026, 10, 19, 12));
    final moon = solar.where((body) => body.kind == LiveObjectKind.moon);
    expect(solar.any((body) => body.kind == LiveObjectKind.sun), isTrue);
    expect(moon, hasLength(1));
    expect(moon.first.note, isNotNull);
    expect(moon.first.raDegrees, inInclusiveRange(0, 360));
    expect(moon.first.decDegrees.abs(), lessThanOrEqualTo(90));
  });

  test('从 Y 平面里能找到合成的亮点', () {
    const width = 320;
    const height = 240;
    final y = Uint8List(width * height)..fillRange(0, width * height, 20);
    final points = [
      (40, 40),
      (90, 70),
      (150, 55),
      (210, 90),
      (260, 130),
      (70, 160),
      (130, 190),
      (200, 170),
      (280, 200),
    ];
    for (final point in points) {
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final value = 230 - (dx.abs() + dy.abs()) * 35;
          y[(point.$2 + dy) * width + point.$1 + dx] = value.clamp(0, 255);
        }
      }
    }
    final detections = LiveStarTracker.detect(y, width, height, width);
    expect(detections.length, greaterThanOrEqualTo(points.length - 1));
  });

  test('用已知星表投影生成检测，能解出零修正', () {
    final basis = LiveCameraBasis.fromSensors(
      accelerometer: const LiveVec3(0, 9.8, 0),
      magnetometer: const LiveVec3(0, 0, -30),
    )!;
    const aspect = 0.75;
    const fov = 60.0;
    final viewport = const Size(1, aspect);
    final stars = <LiveEnuObject>[];
    for (var i = 0; i < 10; i++) {
      final enu = LiveVec3(
        -0.18 + i * 0.04,
        1,
        -0.10 + (i % 3) * 0.05,
      ).normalized();
      stars.add(
        LiveEnuObject(
          LiveObject(
            name: 'S$i',
            raDegrees: 0,
            decDegrees: 0,
            magnitude: 2.0,
            kind: LiveObjectKind.star,
            hip: i,
          ),
          enu,
        ),
      );
    }
    final detections = <LiveStarDetection>[];
    for (final star in stars) {
      final point = basis.project(
        star.enu,
        horizontalFovDegrees: fov,
        viewport: viewport,
        margin: 0,
      );
      if (point == null) continue;
      detections.add(
        LiveStarDetection(point.dx, point.dy / aspect, 1),
      );
    }
    final fix = LiveStarTracker.solve(
      detections: detections,
      stars: stars,
      basis: basis,
      fieldOfViewDegrees: fov,
      previewAspect: aspect,
    );
    expect(fix, isNotNull);
    expect(fix!.matches, greaterThanOrEqualTo(6));
    expect(fix.matchedHips, isNotEmpty);
    expect(fix.yawDegrees.abs(), lessThan(3));
    expect(fix.pitchDegrees.abs(), lessThan(3));
    expect(fix.rollDegrees.abs(), lessThan(3));
  });

  test('自动观测条件按太阳高度和月光决定极限星等', () {
    double limit(double sun, double moon, double phase) =>
        LiveSkyVisibility.autoLimit(
          sunAltitude: sun,
          moonAltitude: moon,
          moonPhase: phase,
          hasLocation: true,
        );
    expect(limit(10, 0, 0), 1.5);
    expect(limit(-3, 0, 0), 2.5);
    expect(limit(-8, 0, 0), 4.0);
    expect(limit(-15, 0, 0), 5.0);
    expect(limit(-25, 40, 0.8), 4.5);
    expect(limit(-25, -10, 0.8), 6.0);
  });

  group('实时星图的坐标', () {
    test('J2000 正午的格林尼治恒星时接近 280.46°', () {
      final value = greenwichSiderealDegrees(DateTime.utc(2000, 1, 1, 12));
      expect(value, closeTo(280.46, 0.05));
    });

    test('赤道坐标转地平：天顶就是 up', () {
      final enu = equatorialToEnu(
        raDegrees: 120,
        decDegrees: 40,
        latitudeDegrees: 40,
        localSiderealDegrees: 120,
      );
      expect(enu.z, closeTo(1, 1e-9));
      expect(enu.x.abs(), lessThan(1e-9));
      expect(enu.y.abs(), lessThan(1e-9));
    });

    test('东边地平线：H=-90° 时指向 east', () {
      final enu = equatorialToEnu(
        raDegrees: 0,
        decDegrees: 0,
        latitudeDegrees: 0,
        localSiderealDegrees: -90,
      );
      expect(enu.x, closeTo(1, 1e-9));
      expect(enu.y.abs(), lessThan(1e-9));
      expect(enu.z.abs(), lessThan(1e-9));
    });

    test('方位角/高度角', () {
      final (az, alt) = enuToAzAlt(const LiveVec3(1, 0, 0));
      expect(az, closeTo(90, 1e-9));
      expect(alt, closeTo(0, 1e-9));
    });
  });

  group('姿态与投影', () {
    test('手机竖直、后摄朝北时，画面上方是天顶', () {
      final basis = LiveCameraBasis.fromSensors(
        accelerometer: const LiveVec3(0, 9.8, 0),
        magnetometer: const LiveVec3(0, 0, -30),
      )!;
      expect(basis.forward.x.abs(), lessThan(1e-9));
      expect(basis.forward.y, closeTo(1, 1e-9));
      expect(basis.forward.z.abs(), lessThan(1e-9));
      expect(basis.up.z, closeTo(1, 1e-9));
      expect(basis.right.x, closeTo(1, 1e-9));
    });

    test('正前方的天球点投影到画面中心', () {
      final basis = LiveCameraBasis.fromSensors(
        accelerometer: const LiveVec3(0, 0, 9.8),
        magnetometer: const LiveVec3(0, 30, -20),
      )!;
      final point = basis.project(
        basis.forward,
        horizontalFovDegrees: 60,
        viewport: const Size(400, 300),
      );
      expect(point, isNotNull);
      expect(point!.dx, closeTo(200, 1e-6));
      expect(point.dy, closeTo(150, 1e-6));
    });

    test('相机背后的点不投影', () {
      final basis = LiveCameraBasis.fromSensors(
        accelerometer: const LiveVec3(0, 0, 9.8),
        magnetometer: const LiveVec3(0, 30, -20),
      )!;
      final point = basis.project(
        basis.forward * -1,
        horizontalFovDegrees: 60,
        viewport: const Size(400, 300),
      );
      expect(point, isNull);
    });

    test('绕天顶转 90° 会把北换成东', () {
      final basis = LiveCameraBasis.fromSensors(
        accelerometer: const LiveVec3(0, 9.8, 0),
        magnetometer: const LiveVec3(0, 0, -30),
      )!;
      final rotated = basis.rotatedAroundUp(90);
      expect(rotated.forward.x, closeTo(1, 1e-9));
      expect(rotated.forward.y.abs(), lessThan(1e-9));
    });
  });
}
