import 'dart:ui';

import 'package:astrosophy/live_sky.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置星表能载入亮星、星座和深空', () async {
    final catalog = await LiveCatalog.load();
    expect(catalog.stars.length, greaterThan(1000));
    expect(catalog.constellations, isNotEmpty);
    expect(catalog.stars.first.magnitude, lessThanOrEqualTo(6.4));
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
