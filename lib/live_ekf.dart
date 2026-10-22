import 'dart:math' as math;

/// 轻量误差状态 EKF：估计「IMU 基准姿态」相对星点解算的残差。
///
/// 真正的 VIO 会把绝对姿态、速度和陀螺零偏一起放进状态；这里先把最容易
/// 见效的部分做出来：用 3 个残差角 + 3 个零偏作为状态，陀螺仪继续由原来的
/// 互补滤波推进，星点解算作为观测。这样既不推翻现有姿态链，又能让修正
/// 不再是一帧一帧地硬跳。
class LiveAttitudeEkf {
  static const _stateSize = 6;

  final List<double> _x = List<double>.filled(_stateSize, 0);
  final List<double> _p = List<double>.filled(_stateSize * _stateSize, 0);
  bool _hasMeasurement = false;

  double get yawDegrees => _x[0];
  double get pitchDegrees => _x[1];
  double get rollDegrees => _x[2];
  double get biasX => _x[3];
  double get biasY => _x[4];
  double get biasZ => _x[5];
  bool get hasMeasurement => _hasMeasurement;

  void reset() {
    for (var i = 0; i < _x.length; i++) {
      _x[i] = 0;
    }
    for (var i = 0; i < _p.length; i++) {
      _p[i] = 0;
    }
    for (var i = 0; i < _stateSize; i++) {
      _p[i * _stateSize + i] = 1;
    }
    _hasMeasurement = false;
  }

  LiveAttitudeEkf() {
    reset();
  }

  /// 陀螺零偏随机游走；残差角本身不主动衰减，交给观测拉回。
  void predict(double dt) {
    final q = math.max(0.001, dt.clamp(0.0, 0.2));
    // 姿态残差过程噪声很小；零偏允许缓慢漂移。
    _p[0 * _stateSize + 0] += 0.02 * q;
    _p[1 * _stateSize + 1] += 0.02 * q;
    _p[2 * _stateSize + 2] += 0.02 * q;
    for (var i = 3; i < _stateSize; i++) {
      _p[i * _stateSize + i] += 0.0008 * q;
    }
  }

  /// 星点修正作为观测。`residualPixels` 是归一化画面宽度的残差。
  void update({
    required double yaw,
    required double pitch,
    required double roll,
    required int matches,
    required double residualPixels,
    required double angularSpeed,
  }) {
    final measurementNoise = _measurementVariance(
      matches: matches,
      residualPixels: residualPixels,
      angularSpeed: angularSpeed,
    );
    // H = [I3 0]，观测就是前三个状态。
    final innovation = [yaw - _x[0], pitch - _x[1], roll - _x[2]];
    final s = List<double>.generate(9, (index) {
      final row = index ~/ 3;
      final col = index % 3;
      return _p[row * _stateSize + col] + (row == col ? measurementNoise : 0);
    });
    final inv = _invert3(s);
    if (inv == null) return;

    final gain = List<double>.filled(_stateSize * 3, 0);
    for (var row = 0; row < _stateSize; row++) {
      for (var col = 0; col < 3; col++) {
        var sum = 0.0;
        for (var k = 0; k < 3; k++) {
          sum += _p[row * _stateSize + k] * inv[k * 3 + col];
        }
        gain[row * 3 + col] = sum;
      }
    }

    for (var row = 0; row < _stateSize; row++) {
      var delta = 0.0;
      for (var col = 0; col < 3; col++) {
        delta += gain[row * 3 + col] * innovation[col];
      }
      _x[row] += delta;
    }

    // P = (I - K H) P
    final next = List<double>.filled(_p.length, 0);
    for (var row = 0; row < _stateSize; row++) {
      for (var col = 0; col < _stateSize; col++) {
        var sum = _p[row * _stateSize + col];
        for (var k = 0; k < 3; k++) {
          sum -= gain[row * 3 + k] * _p[k * _stateSize + col];
        }
        next[row * _stateSize + col] = sum;
      }
    }
    for (var i = 0; i < _p.length; i++) {
      _p[i] = next[i];
    }
    _hasMeasurement = true;
  }

  double _measurementVariance({
    required int matches,
    required double residualPixels,
    required double angularSpeed,
  }) {
    // 匹配越多、残差越小，越信星点；快速转动时相机帧已经过期，放宽。
    final base = 0.08 + residualPixels * 6.0;
    final countFactor = 8.0 / math.max(4, matches);
    final motionFactor = 1.0 + angularSpeed * 8.0;
    return (base * countFactor * motionFactor).clamp(0.02, 2.0);
  }

  static List<double>? _invert3(List<double> m) {
    final a = m[0], b = m[1], c = m[2];
    final d = m[3], e = m[4], f = m[5];
    final g = m[6], h = m[7], i = m[8];
    final det = a * (e * i - f * h) -
        b * (d * i - f * g) +
        c * (d * h - e * g);
    if (det.abs() < 1e-12) return null;
    final invDet = 1 / det;
    return [
      (e * i - f * h) * invDet,
      (c * h - b * i) * invDet,
      (b * f - c * e) * invDet,
      (f * g - d * i) * invDet,
      (a * i - c * g) * invDet,
      (c * d - a * f) * invDet,
      (d * h - e * g) * invDet,
      (b * g - a * h) * invDet,
      (a * e - b * d) * invDet,
    ];
  }
}
