import 'dart:math' as math;

import 'orbit.dart';

/// 月相：从拍摄时刻算出来的亮面占比和盈亏。
///
/// 这个文件只做一件事——给月面分析一个**独立于图像**的对照数。从图上量出来的
/// 亮面占比，和从时刻算出来的，是两条互不相干的路径；两个数对得上，结论才
/// 站得住。只有一个的话，用户没法知道错的是哪一个。
///
/// 不从图上判断「盈还是亏」：那要看亮面朝哪一边，而相机的镜像和翻转是未知的
/// （加天顶镜的折射镜是镜像的，牛顿式是旋转的），单张图答不了这个问题。时刻
/// 能答。
class MoonPhase {
  const MoonPhase({
    required this.illuminatedFraction,
    required this.waxing,
  });

  /// 亮面占整个月面的比例，0 = 新月，1 = 满月。
  final double illuminatedFraction;

  /// 盈（亮面在变大）还是亏。
  final bool waxing;

  /// 亮面占比的百分数写法，界面直接用。
  String get fractionLabel =>
      '${(illuminatedFraction * 100).round()}%';

  /// 月相名。
  ///
  /// 光有占比不够：「一半亮」在上弦和下弦是两种样子，中间隔着半个月。所以
  /// 名字必须结合 [waxing] 一起说。
  String get name {
    final k = illuminatedFraction;
    if (k < 0.02) return '新月';
    if (k > 0.98) return '满月';
    if (k < 0.48) return waxing ? '娥眉月' : '残月';
    if (k <= 0.52) return waxing ? '上弦月' : '下弦月';
    return waxing ? '盈凸月' : '亏凸月';
  }
}

/// 算 [moment]（UTC）时刻的月相。
///
/// ## 出处
///
/// Meeus, *Astronomical Algorithms*, 2nd ed.：
///
///   * 三个基本角 D、M、M′ 是第 47 章的 47.2 / 47.3 / 47.4 式（本章只用到
///     这三个，月亮平黄经 47.1 和纬度参数 47.5 在这里用不着）；
///   * 相位角与亮面占比是第 48 章的 48.4 式：`i = 180 − D − 6.289·sin M′ +
///     2.100·sin M − 1.274·sin(2D − M′) − 0.658·sin(2D) − 0.214·sin(2M′) −
///     0.110·sin D`，再取 `k = (1 + cos i) / 2`。
///
/// 48.4 的好处是**不需要两边各自的位置和距离**——那些量本来还要再抄一张
/// 六十项的周期项表，而少抄一张表就少一处抄错的机会。Meeus 说 48.4「准确到
/// 小数点后第二位」，也就是 k 的误差在 0.005 上下；这比一张手机照片能提供的
/// 精度（曝光、饱和、边缘溢出）宽裕得多。
///
/// ## 时间用 UTC 而不是 TT
///
/// 这几个式子的自变量是 TT，而 UTC 与它差 ΔT ≈ 70 秒。月亮的角距一天走
/// 12.2°，70 秒只让相位角动 0.01°，落到 k 上是 1×10⁻⁴——和 48.4 自身的
/// 0.005 差一个半数量级，不值得为它引一份每几年就要更新的闰秒/ΔT 表。
/// 和 `orbit.dart` 里行星那一套的处理一致。
MoonPhase moonPhaseAt(DateTime moment) {
  final t = julianCenturies(julianDay(moment));
  final t2 = t * t;
  final t3 = t2 * t;
  final t4 = t3 * t;

  // Meeus 47.2：月亮平角距（平黄经减去太阳平黄经）。0° 是新月方向，
  // 180° 是满月方向；随时间增大。
  final elongation = _wrapDegrees(
    297.8501921 +
        445267.1114034 * t -
        0.0018819 * t2 +
        t3 / 545868 -
        t4 / 113065000,
  );
  // Meeus 47.3：太阳平近点角。
  final sunAnomaly = _wrapDegrees(
    357.5291092 + 35999.0502909 * t - 0.0001536 * t2 + t3 / 24490000,
  );
  // Meeus 47.4：月亮平近点角。
  final moonAnomaly = _wrapDegrees(
    134.9633964 +
        477198.8675055 * t +
        0.0087414 * t2 +
        t3 / 69699 -
        t4 / 14712000,
  );

  // Meeus 48.4。
  final phaseAngle = 180.0 -
      elongation -
      6.289 * _sinDegrees(moonAnomaly) +
      2.100 * _sinDegrees(sunAnomaly) -
      1.274 * _sinDegrees(2 * elongation - moonAnomaly) -
      0.658 * _sinDegrees(2 * elongation) -
      0.214 * _sinDegrees(2 * moonAnomaly) -
      0.110 * _sinDegrees(elongation);

  // Meeus 48.1。相位角 0° 是满月、180° 是新月。
  final illuminated = (1 + _cosDegrees(phaseAngle)) / 2;

  return MoonPhase(
    illuminatedFraction: illuminated.clamp(0.0, 1.0),
    // 平角距从 0° 走到 180° 是「新月到满月」，也就是盈。
    waxing: elongation < 180,
  );
}

double _sinDegrees(double degrees) => math.sin(degrees * math.pi / 180);

double _cosDegrees(double degrees) => math.cos(degrees * math.pi / 180);

/// 归到 [0, 360)。
double _wrapDegrees(double degrees) {
  final wrapped = degrees % 360;
  return wrapped < 0 ? wrapped + 360 : wrapped;
}
