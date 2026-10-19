import 'dart:math' as math;

import 'strings.dart';
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
  const MoonPhase({    required this.illuminatedFraction,
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
    if (k < 0.02) return t('新月');
    if (k > 0.98) return t('满月');
    if (k < 0.48) return waxing ? t('娥眉月') : t('残月');
    if (k <= 0.52) return waxing ? t('上弦月') : t('下弦月');
    return waxing ? t('盈凸月') : t('亏凸月');
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

/// 月球的地心赤道坐标（度）。实时星图只需要把月亮画在正确的大致位置，
/// 用 Meeus 第 47 章的简化项，误差约 0.2°–0.4°，对广角叠层足够。
class MoonPosition {
  const MoonPosition(this.raDegrees, this.decDegrees);

  final double raDegrees;
  final double decDegrees;
}

MoonPosition moonPositionAt(DateTime moment) {
  final t = julianCenturies(julianDay(moment));
  final lp = _wrapDegrees(218.3164477 +
      481267.88123421 * t -
      0.0015786 * t * t +
      t * t * t / 538841 -
      t * t * t * t / 65194000);
  final d = _wrapDegrees(297.8501921 +
      445267.1114034 * t -
      0.0018819 * t * t +
      t * t * t / 545868 -
      t * t * t * t / 113065000);
  final m = _wrapDegrees(357.5291092 +
      35999.0502909 * t -
      0.0001536 * t * t +
      t * t * t / 24490000);
  final mp = _wrapDegrees(134.9633964 +
      477198.8675055 * t +
      0.0087414 * t * t +
      t * t * t / 69699 -
      t * t * t * t / 14712000);
  final f = _wrapDegrees(93.2720950 +
      483202.0175233 * t -
      0.0036539 * t * t -
      t * t * t / 3526000 +
      t * t * t * t / 863310000);

  final longitude = lp +
      6.289 * _sinDegrees(mp) +
      1.274 * _sinDegrees(2 * d - mp) +
      0.658 * _sinDegrees(2 * d) +
      0.214 * _sinDegrees(2 * mp) -
      0.186 * _sinDegrees(m) -
      0.114 * _sinDegrees(2 * f) +
      0.059 * _sinDegrees(2 * d - 2 * mp) +
      0.057 * _sinDegrees(2 * d - m - mp) +
      0.053 * _sinDegrees(2 * d + mp) +
      0.046 * _sinDegrees(2 * d - m) +
      0.041 * _sinDegrees(m - mp) -
      0.035 * _sinDegrees(d) -
      0.031 * _sinDegrees(m + mp) -
      0.015 * _sinDegrees(2 * f - 2 * d) +
      0.011 * _sinDegrees(2 * d - 4 * mp);
  final latitude = 5.128 * _sinDegrees(f) +
      0.281 * _sinDegrees(mp + f) +
      0.278 * _sinDegrees(mp - f) +
      0.173 * _sinDegrees(2 * d - f) +
      0.055 * _sinDegrees(2 * d - mp + f) +
      0.046 * _sinDegrees(2 * d - mp - f) +
      0.033 * _sinDegrees(2 * d + f) +
      0.017 * _sinDegrees(2 * mp + f);

  final lambda = longitude * math.pi / 180;
  final beta = latitude * math.pi / 180;
  final epsilon = obliquityJ2000 * math.pi / 180;
  final x = math.cos(beta) * math.cos(lambda);
  final y = math.cos(beta) * math.sin(lambda);
  final z = math.sin(beta);
  final ra = math.atan2(
    y * math.cos(epsilon) - z * math.sin(epsilon),
    x,
  );
  final dec = math.asin(
    y * math.sin(epsilon) + z * math.cos(epsilon),
  );
  return MoonPosition(_wrapDegrees(ra * 180 / math.pi), dec * 180 / math.pi);
}

double _sinDegrees(double degrees) => math.sin(degrees * math.pi / 180);

double _cosDegrees(double degrees) => math.cos(degrees * math.pi / 180);

/// 归到 [0, 360)。
double _wrapDegrees(double degrees) {
  final wrapped = degrees % 360;
  return wrapped < 0 ? wrapped + 360 : wrapped;
}
