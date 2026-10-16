import 'strings.dart';
import 'moving.dart';
import 'orbit.dart';

/// 太阳系主要天体的位置，离线算，不联网。
///
/// 这一层只负责「哪个天体什么时候在哪儿」；「图上那个亮点是不是它」是
/// `moving.dart` 的事，两件事分开是为了让后者能脱离星历单独测。
///
/// ## 根数从哪来
///
/// 下面那张表摘自 JPL 太阳系动力学组的
/// *"Approximate Positions of the Major Planets"*（Standish）**Table 1**，
/// 与页面上的数一一对应，没有换算、没有重新排列。2026-10-15 取。
///
///   * 历元 J2000.0，参考面是 J2000 的**平黄道与平春分点**——和恒星表
///     （Hipparcos / Gaia）同一个参考面，所以两边可以直接比位置；
///   * 单位 au / 度，变率是**每儒略世纪**（36525 天），不是每年；
///   * 有效区间 1800–2050 AD。页面上的 Table 2 覆盖 3000 BC–3000 AD，多出
///     `b·T²` 几项，我们没有用——用得上它的照片还没被拍出来；
///   * 页面把 e 那一列的表头印成 `rad, rad/Cy`，但那一列的数（水星 0.2056、
///     地球 0.0167）就是通常那个无量纲的偏心率，这里按无量纲用。
///
/// 这些数不凭记忆写：同一条搜索摘要里木星的半长轴出现过 `5.20285700` 和
/// `5.20288700` 两种，倾角出现过 `1.84909142`（那是火星的）和 `1.30439695`。
/// 串了列的数写进来，行星位置会偏出几角分到几度，而从计算结果上根本看不出
/// 是哪一位错了——错的根数和错的矩阵会表现成同一个样子。
///
/// **Pluto 不在表里**：页面上有它，但那张表在这个区间内对它的精度只有几十
/// 角秒上下，而且 14 等的亮度在任何手机照片上都拍不到。与其写一个永远用不上
/// 的行，不如缺着——真要用的时候补，而不是顺手抄一个。

/// 一个天体的根数。
class SolarSystemBody {
  const SolarSystemBody({required this.name, required this.elements});

  /// 中文名，直接给用户看。
  final String name;

  final OrbitalElements elements;
}

/// 表里的 EM Bary（地月质心）那一行。
///
/// 地心坐标是所有天体位置减去它得到的，所以它不放在 [solarSystemBodies] 里
/// 当天体用。表里给的是**地月质心**而不是地球中心：差的那点在地心方向上不到
/// 1 角分，对「这个亮点是不是木星」没有影响，所以不做地月质心的拆分。
const OrbitalElements earthMoonBarycentre = OrbitalElements(
  semiMajorAxis: 1.00000261,
  semiMajorAxisRate: 0.00000562,
  eccentricity: 0.01671123,
  eccentricityRate: -0.00004392,
  inclination: -0.00001531,
  inclinationRate: -0.01294668,
  meanLongitude: 100.46457166,
  meanLongitudeRate: 35999.37244981,
  perihelionLongitude: 102.93768193,
  perihelionLongitudeRate: 0.32327364,
  nodeLongitude: 0.0,
  nodeLongitudeRate: 0.0,
);

/// Table 1（1800 AD – 2050 AD）的行，一行一天体，顺序与页面上一致。
List<SolarSystemBody> get solarSystemBodies => [
  SolarSystemBody(
    name: t('水星'),
    elements: const OrbitalElements(
      semiMajorAxis: 0.38709927,
      semiMajorAxisRate: 0.00000037,
      eccentricity: 0.20563593,
      eccentricityRate: 0.00001906,
      inclination: 7.00497902,
      inclinationRate: -0.00594749,
      meanLongitude: 252.25032350,
      meanLongitudeRate: 149472.67411175,
      perihelionLongitude: 77.45779628,
      perihelionLongitudeRate: 0.16047689,
      nodeLongitude: 48.33076593,
      nodeLongitudeRate: -0.12534081,
    ),
  ),
  SolarSystemBody(
    name: t('金星'),
    elements: const OrbitalElements(
      semiMajorAxis: 0.72333566,
      semiMajorAxisRate: 0.00000390,
      eccentricity: 0.00677672,
      eccentricityRate: -0.00004107,
      inclination: 3.39467605,
      inclinationRate: -0.00078890,
      meanLongitude: 181.97909950,
      meanLongitudeRate: 58517.81538729,
      perihelionLongitude: 131.60246718,
      perihelionLongitudeRate: 0.00268329,
      nodeLongitude: 76.67984255,
      nodeLongitudeRate: -0.27769418,
    ),
  ),
  SolarSystemBody(
    name: t('火星'),
    elements: const OrbitalElements(
      semiMajorAxis: 1.52371034,
      semiMajorAxisRate: 0.00001847,
      eccentricity: 0.09339410,
      eccentricityRate: 0.00007882,
      inclination: 1.84969142,
      inclinationRate: -0.00813131,
      meanLongitude: -4.55343205,
      meanLongitudeRate: 19140.30268499,
      perihelionLongitude: -23.94362959,
      perihelionLongitudeRate: 0.44441088,
      nodeLongitude: 49.55953891,
      nodeLongitudeRate: -0.29257343,
    ),
  ),
  SolarSystemBody(
    name: t('木星'),
    elements: const OrbitalElements(
      semiMajorAxis: 5.20288700,
      semiMajorAxisRate: -0.00011607,
      eccentricity: 0.04838624,
      eccentricityRate: -0.00013253,
      inclination: 1.30439695,
      inclinationRate: -0.00183714,
      meanLongitude: 34.39644051,
      meanLongitudeRate: 3034.74612775,
      perihelionLongitude: 14.72847983,
      perihelionLongitudeRate: 0.21252668,
      nodeLongitude: 100.47390909,
      nodeLongitudeRate: 0.20469106,
    ),
  ),
  SolarSystemBody(
    name: t('土星'),
    elements: const OrbitalElements(
      semiMajorAxis: 9.53667594,
      semiMajorAxisRate: -0.00125060,
      eccentricity: 0.05386179,
      eccentricityRate: -0.00050991,
      inclination: 2.48599187,
      inclinationRate: 0.00193609,
      meanLongitude: 49.95424423,
      meanLongitudeRate: 1222.49362201,
      perihelionLongitude: 92.59887831,
      perihelionLongitudeRate: -0.41897216,
      nodeLongitude: 113.66242448,
      nodeLongitudeRate: -0.28867794,
    ),
  ),
  SolarSystemBody(
    name: t('天王星'),
    elements: const OrbitalElements(
      semiMajorAxis: 19.18916464,
      semiMajorAxisRate: -0.00196176,
      eccentricity: 0.04725744,
      eccentricityRate: -0.00004397,
      inclination: 0.77263783,
      inclinationRate: -0.00242939,
      meanLongitude: 313.23810451,
      meanLongitudeRate: 428.48202785,
      perihelionLongitude: 170.95427630,
      perihelionLongitudeRate: 0.40805281,
      nodeLongitude: 74.01692503,
      nodeLongitudeRate: 0.04240589,
    ),
  ),
  SolarSystemBody(
    name: t('海王星'),
    elements: const OrbitalElements(
      semiMajorAxis: 30.06992276,
      semiMajorAxisRate: 0.00026291,
      eccentricity: 0.00859048,
      eccentricityRate: 0.00005105,
      inclination: 1.77004347,
      inclinationRate: 0.00035372,
      meanLongitude: -55.12002969,
      meanLongitudeRate: 218.45945325,
      perihelionLongitude: 44.96476227,
      perihelionLongitudeRate: -0.32241464,
      nodeLongitude: 131.78422574,
      nodeLongitudeRate: -0.00508664,
    ),
  ),
];

/// [moment] 时刻各个天体的地心赤道位置。
List<PredictedBody> predictedBodies(DateTime moment) => [
      for (final body in solarSystemBodies)
        _predict(body, earthMoonBarycentre, moment),
    ];

/// 太阳的地心位置。
///
/// 从同一组根数就能得到：地心看到的太阳方向，就是地球日光心方向的反方向，
/// 所以太阳不需要在表里单占一行。这是这张表少有的「顺手白拿一个天体」的地方
/// ——太阳的照片不少，而它又是最好判准的那个：太阳在哪儿，一年里没有第二颗
/// 亮星能和它抢。
PredictedBody sunPosition(DateTime moment) {
  final centuries = julianCenturies(julianDay(moment));
  final position = heliocentricPosition(earthMoonBarycentre, centuries);
  return _toPredicted(
    t('太阳'),
    PositionVector(-position.x, -position.y, -position.z),
  );
}

PredictedBody _predict(
  SolarSystemBody body,
  OrbitalElements earth,
  DateTime moment,
) {
  final position = geocentricPosition(body.elements, earth, moment);
  return PredictedBody(
    name: body.name,
    ra: position.ra,
    dec: position.dec,
    distanceAu: position.distanceAu,
  );
}

/// 把黄道直角坐标转成地心赤道坐标并包装成 [PredictedBody]。
PredictedBody _toPredicted(String name, PositionVector ecliptic) {
  final equatorial = equatorialFromEcliptic(ecliptic);
  return PredictedBody(
    name: name,
    ra: equatorial.ra,
    dec: equatorial.dec,
    distanceAu: equatorial.distanceAu,
  );
}
