import 'dart:math' as math;

/// 开普勒轨道：从一组根数算出天体在某一时刻的地心赤道坐标。
///
/// 这里只有数学，没有数据。根数（[OrbitalElements]）由调用方给，本文件不内置
/// 任何一颗行星的数——那张表有出处，抄错了从结果上看不出来，所以它单独放在
/// `ephemeris.dart` 里，并且注明是从哪儿抄的。
///
/// 参考系约定（和星表对齐，很重要）：
///   * 根数按 J2000.0 的**平黄道与平春分点**给；
///   * 黄道转赤道用 **J2000 的黄赤交角**，不是当日的交角。恒星表（Hipparcos、
///     Gaia）本来就是 J2000 坐标，用当日交角的话行星位置会带上岁差的偏差，
///     而这个偏差在图上就是和恒星对不齐。

/// 一个天体在 J2000 黄道坐标系里的轨道六根数，外加它们每儒略世纪的变率。
///
/// 变率的单位是「每儒略世纪」（36525 天）而不是每年——出处那张表就是这么给的，
/// 换算成年只是多一次除法、多一个写错的机会。
class OrbitalElements {
  const OrbitalElements({
    required this.semiMajorAxis,
    required this.semiMajorAxisRate,
    required this.eccentricity,
    required this.eccentricityRate,
    required this.inclination,
    required this.inclinationRate,
    required this.meanLongitude,
    required this.meanLongitudeRate,
    required this.perihelionLongitude,
    required this.perihelionLongitudeRate,
    required this.nodeLongitude,
    required this.nodeLongitudeRate,
  });

  /// 半长轴，天文单位。
  final double semiMajorAxis;
  final double semiMajorAxisRate;

  /// 偏心率，无量纲。
  final double eccentricity;
  final double eccentricityRate;

  /// 轨道倾角，度。
  final double inclination;
  final double inclinationRate;

  /// 平黄经 L，度。是「平近点角 ＋ 近日点黄经」，不是近点角本身。
  final double meanLongitude;
  final double meanLongitudeRate;

  /// 近日点黄经 ϖ，度。
  final double perihelionLongitude;
  final double perihelionLongitudeRate;

  /// 升交点黄经 Ω，度。
  final double nodeLongitude;
  final double nodeLongitudeRate;
}

/// 一个时刻的三维位置，单位 au。
///
/// 黄道坐标和赤道坐标都用这个类型装：两者的差别只在参考面，字段含义一样
/// （x 指向参考面的春分点、z 指向参考面的北极）。分开定义两个类反而会让
/// 「哪一步用了哪个面」这件事更难看清。
class PositionVector {
  const PositionVector(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get distance => math.sqrt(x * x + y * y + z * z);

  PositionVector operator -(PositionVector other) =>
      PositionVector(x - other.x, y - other.y, z - other.z);
}

/// 一个天体的地心赤道坐标。
class EquatorialPosition {
  const EquatorialPosition({
    required this.ra,
    required this.dec,
    required this.distanceAu,
  });

  /// 赤经，度，0–360。
  final double ra;

  /// 赤纬，度，−90–90。
  final double dec;

  /// 地心距离，天文单位。
  final double distanceAu;
}

/// J2000.0 的黄赤交角，度（IAU 1976）。
const double obliquityJ2000 = 23.4392911111;

/// 从 1970-01-01T00:00:00Z 到 J2000.0 的天数（儒略日 2440587.5 → 2451545.0）。
const double _j2000JulianDay = 2451545.0;

/// 把时刻换成儒略日。
///
/// 不处理闰秒：UTC 与「均匀流逝的时间」之间差的那几十秒，落到行星位置上是
/// 角秒的千分之一量级，而闰秒表每几年就要更新一次——带着它多一个会过期的
/// 依赖，换来的精度这里用不上。
double julianDay(DateTime moment) =>
    2440587.5 + moment.toUtc().millisecondsSinceEpoch / 86400000;

/// 从 J2000.0 起算的儒略世纪数。根数的变率乘的就是这个量。
double julianCenturies(double jd) => (jd - _j2000JulianDay) / 36525;

/// 解 [elements] 在 [centuries]（儒略世纪数）时刻的日光心黄道位置。
PositionVector heliocentricPosition(
  OrbitalElements elements,
  double centuries,
) {
  final semiMajorAxis =
      elements.semiMajorAxis + elements.semiMajorAxisRate * centuries;
  final eccentricity =
      elements.eccentricity + elements.eccentricityRate * centuries;
  final inclination = _radians(
    elements.inclination + elements.inclinationRate * centuries,
  );
  final meanLongitude =
      elements.meanLongitude + elements.meanLongitudeRate * centuries;
  final perihelion =
      elements.perihelionLongitude + elements.perihelionLongitudeRate * centuries;
  final node = elements.nodeLongitude + elements.nodeLongitudeRate * centuries;

  // 平近点角归到 (−180, 180]：开普勒方程的牛顿迭代在这个区间里收敛得最稳。
  final meanAnomaly = _radians(_wrapSigned(meanLongitude - perihelion));
  final eccentricAnomaly = _solveKepler(meanAnomaly, eccentricity);

  // 先在轨道平面里算，x' 轴指向近日点。
  final xOrbital = semiMajorAxis * (math.cos(eccentricAnomaly) - eccentricity);
  final yOrbital = semiMajorAxis *
      math.sqrt(math.max(0, 1 - eccentricity * eccentricity)) *
      math.sin(eccentricAnomaly);

  // 再转进黄道系：绕 z 转近日点幅角、绕 x 转轨道倾角、绕 z 转升交点经度。
  final argument = _radians(perihelion - node);
  final nodeAngle = _radians(node);
  final cosArgument = math.cos(argument);
  final sinArgument = math.sin(argument);
  final cosNode = math.cos(nodeAngle);
  final sinNode = math.sin(nodeAngle);
  final cosInclination = math.cos(inclination);
  final sinInclination = math.sin(inclination);

  return PositionVector(
    (cosArgument * cosNode - sinArgument * sinNode * cosInclination) * xOrbital +
        (-sinArgument * cosNode - cosArgument * sinNode * cosInclination) *
            yOrbital,
    (cosArgument * sinNode + sinArgument * cosNode * cosInclination) * xOrbital +
        (-sinArgument * sinNode + cosArgument * cosNode * cosInclination) *
            yOrbital,
    (sinArgument * sinInclination) * xOrbital +
        (cosArgument * sinInclination) * yOrbital,
  );
}

/// 一个天体在 [moment] 时刻的地心赤道坐标。
///
/// [body] 是天体本身的根数，[earth] 是地月质心的根数（表里给的就是地月质心，
/// 不是地球中心——差的那点在地心方向上不到 1 角分，对「这个亮点是不是木星」
/// 的判断没有影响，所以不展开）。
///
/// 不做光行时改正：光从木星走到地球要 35–50 分钟，这段时间里木星走 10–20 角秒。
/// 判断用的容差是角分量级，这项被容差吃掉了；哪天要把容差收到角秒级，这里
/// 就得改成迭代。
EquatorialPosition geocentricPosition(
  OrbitalElements body,
  OrbitalElements earth,
  DateTime moment, {
  double obliquity = obliquityJ2000,
}) {
  final centuries = julianCenturies(julianDay(moment));
  final relative = heliocentricPosition(body, centuries) -
      heliocentricPosition(earth, centuries);
  return equatorialFromEcliptic(relative, obliquity: obliquity);
}

/// 黄道直角坐标转地心赤道坐标（赤经、赤纬、距离）。
///
/// 太阳的位置就是这么来的：地心看到的太阳方向，等于地球日光心方向的反方向，
/// 所以太阳不需要在根数表里单占一行。
EquatorialPosition equatorialFromEcliptic(
  PositionVector ecliptic, {
  double obliquity = obliquityJ2000,
}) {
  // 绕 x 轴转黄赤交角。
  final cosObliquity = math.cos(_radians(obliquity));
  final sinObliquity = math.sin(_radians(obliquity));
  final x = ecliptic.x;
  final y = ecliptic.y * cosObliquity - ecliptic.z * sinObliquity;
  final z = ecliptic.y * sinObliquity + ecliptic.z * cosObliquity;

  final distance = math.sqrt(x * x + y * y + z * z);
  final ra = _wrapDegrees(math.atan2(y, x) / _radiansPerDegree);
  if (distance == 0) {
    // 正好落在地球上。物理上不会发生，但除法要先挡住。
    return EquatorialPosition(ra: ra, dec: 0, distanceAu: 0);
  }
  final dec = math.asin((z / distance).clamp(-1.0, 1.0)) / _radiansPerDegree;
  return EquatorialPosition(ra: ra, dec: dec, distanceAu: distance);
}

/// 解开普勒方程 E − e·sin E = M，返回偏近点角（弧度）。
///
/// 牛顿迭代。起步值取 M + e·sin M 而不是 M：偏心率大的时候 M 离解太远，
/// 从 M 起步反而可能先跳到别处去。行星里偏心率最大的是水星（0.206），
/// 三到四轮就收敛到机器精度；写成循环到不动而不是固定轮数，是为了同一段
/// 代码以后拿去算彗星（e 可以到 0.99）时还站得住。
double _solveKepler(double meanAnomaly, double eccentricity) {
  var eccentricAnomaly = meanAnomaly + eccentricity * math.sin(meanAnomaly);
  for (var iteration = 0; iteration < 64; iteration++) {
    final residual = eccentricAnomaly -
        eccentricity * math.sin(eccentricAnomaly) -
        meanAnomaly;
    // 斜率在地球轨道那种小偏心率下恒在 1 附近；高偏心率下可能趋近 0，
    // 那时把步长夹住，宁可慢几轮也不要让迭代飞出去。
    final slope = 1 - eccentricity * math.cos(eccentricAnomaly);
    var step = residual / slope;
    if (!step.isFinite) break;
    if (step.abs() > 1.0) step = step.sign * 1.0;
    eccentricAnomaly -= step;
    if (step.abs() < 1e-15) break;
  }
  return eccentricAnomaly;
}

const double _radiansPerDegree = math.pi / 180;

double _radians(double degrees) => degrees * _radiansPerDegree;

/// 归到 [0, 360)。
double _wrapDegrees(double degrees) {
  final wrapped = degrees % 360;
  return wrapped < 0 ? wrapped + 360 : wrapped;
}

/// 归到 (−180, 180]。
double _wrapSigned(double degrees) {
  final wrapped = _wrapDegrees(degrees);
  return wrapped > 180 ? wrapped - 360 : wrapped;
}
