import 'package:astrosophy/live_ekf.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EKF 会把星点残差收敛到测量值', () {
    final ekf = LiveAttitudeEkf();
    for (var i = 0; i < 12; i++) {
      ekf.predict(0.05);
      ekf.update(
        yaw: 1.2,
        pitch: -0.4,
        roll: 0.1,
        matches: 12,
        residualPixels: 0.005,
        angularSpeed: 0.02,
      );
    }
    expect(ekf.hasMeasurement, isTrue);
    expect(ekf.yawDegrees, closeTo(1.2, 0.25));
    expect(ekf.pitchDegrees, closeTo(-0.4, 0.25));
    expect(ekf.rollDegrees, closeTo(0.1, 0.25));
  });
}
